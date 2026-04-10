#!/usr/bin/env bash

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

control_plane_runtime_env_file() {
  printf '%s\n' "${CONTROL_PLANE_RUNTIME_ENV_FILE:-${HOME:-/home/${USER:-copilot}}/.config/control-plane/runtime.env}"
}

load_control_plane_runtime_env() {
  local runtime_config_file

  runtime_config_file="$(control_plane_runtime_env_file)"
  [[ -f "${runtime_config_file}" ]] || return 0

  set -a
  # shellcheck disable=SC1090
  source "${runtime_config_file}"
  set +a
}

docker_runtime_available() {
  command -v docker >/dev/null 2>&1 \
    && docker info >/dev/null 2>&1
}

docker_build_toolchain_available() {
  docker_runtime_available \
    && docker buildx version >/dev/null 2>&1
}

buildkitd_build_toolchain_available() {
  command -v docker >/dev/null 2>&1 \
    && docker buildx version >/dev/null 2>&1 \
    && command -v kubectl >/dev/null 2>&1
}

toolchain_supports_container_runtime() {
  case "$1" in
    docker)
      return 0
      ;;
    buildkitd)
      return 1
      ;;
    *)
      printf 'Unsupported toolchain: %s\n' "$1" >&2
      exit 1
      ;;
  esac
}

container_runtime_for_toolchain() {
  case "$1" in
    docker)
      printf 'docker\n'
      ;;
    buildkitd)
      printf '%s\n' 'Buildkitd toolchain does not provide a local container runtime.' >&2
      exit 1
      ;;
    *)
      printf 'Unsupported toolchain: %s\n' "$1" >&2
      exit 1
      ;;
  esac
}

build_command_for_toolchain() {
  case "$1" in
    docker|buildkitd)
      printf 'docker\n'
      ;;
    *)
      printf 'Unsupported toolchain: %s\n' "$1" >&2
      exit 1
      ;;
  esac
}

detect_container_runtime() {
  load_control_plane_runtime_env

  local requested_runtime="${CONTROL_PLANE_CONTAINER_BIN:-}"
  local requested_toolchain="${CONTROL_PLANE_TOOLCHAIN:-}"

  if [[ -n "${requested_runtime}" ]]; then
    [[ "${requested_runtime}" == "docker" ]] || {
      printf 'Unsupported CONTROL_PLANE_CONTAINER_BIN: %s\n' "${requested_runtime}" >&2
      exit 1
    }
    docker_runtime_available || {
      printf 'Requested docker runtime is not usable in this environment.\n' >&2
      exit 1
    }
    printf 'docker\n'
    return
  fi

  case "${requested_toolchain}" in
    docker|'')
      ;;
    *)
      printf 'Unsupported CONTROL_PLANE_TOOLCHAIN: %s\n' "${requested_toolchain}" >&2
      exit 1
      ;;
  esac

  docker_runtime_available || {
    printf 'Missing supported container runtime. Provide a working docker daemon.\n' >&2
    exit 1
  }
  printf 'docker\n'
}

detect_build_test_toolchain() {
  load_control_plane_runtime_env

  case "${CONTROL_PLANE_TOOLCHAIN:-}" in
    docker|'')
      ;;
    buildkitd)
      buildkitd_build_toolchain_available || {
        printf 'Buildkitd toolchain requires docker buildx and kubectl.\n' >&2
        exit 1
      }
      printf 'buildkitd\n'
      return
      ;;
    *)
      printf 'Unsupported CONTROL_PLANE_TOOLCHAIN: %s\n' "${CONTROL_PLANE_TOOLCHAIN}" >&2
      exit 1
      ;;
  esac

  docker_build_toolchain_available || {
    printf 'Docker toolchain requires a working docker CLI with buildx support.\n' >&2
    exit 1
  }

  printf 'docker\n'
}

build_context_hash() {
  local context_dir="$1"

  [[ -d "${context_dir}" ]] || {
    printf 'Build context directory not found: %s\n' "${context_dir}" >&2
    exit 1
  }
  require_command find
  require_command sort
  require_command tar
  require_command sha256sum

  (
    cd "${context_dir}" || exit
    find . \
      \( -path './.git' -o -path '*/target' \) -prune -o \
      \( -type f -o -type l \) -print0 \
      | LC_ALL=C sort -z \
      | tar \
          --null \
          --no-recursion \
          --sort=name \
          --mtime='UTC 1970-01-01' \
          --owner=0 \
          --group=0 \
          --numeric-owner \
          -cf - \
          --files-from -
  ) | sha256sum | awk '{print $1}'
}

build_context_hash_label_key() {
  printf '%s\n' 'io.github.chalharu.control-plane.build-context-sha256'
}

build_context_hash_label_key_for_target() {
  local target_name="$1"

  printf '%s.%s\n' "$(build_context_hash_label_key)" "${target_name}"
}

image_context_hash_for_toolchain() {
  local toolchain="$1"
  local image_tag="$2"
  local label_key="$3"
  local container_bin

  case "${toolchain}" in
    docker)
      container_bin="$(container_runtime_for_toolchain "${toolchain}")"
      "${container_bin}" image inspect --format "{{ index .Config.Labels \"${label_key}\" }}" "${image_tag}" 2>/dev/null
      ;;
    buildkitd)
      local stamp_path

      stamp_path="$(buildkitd_context_stamp_path "${image_tag}" "${label_key}")"
      [[ -f "${stamp_path}" ]] && cat "${stamp_path}"
      ;;
    *)
      printf 'Unsupported toolchain: %s\n' "${toolchain}" >&2
      exit 1
      ;;
  esac
}

buildkitd_namespace() {
  load_control_plane_runtime_env

  if [[ -n "${CONTROL_PLANE_BUILDKIT_NAMESPACE:-}" ]]; then
    printf '%s\n' "${CONTROL_PLANE_BUILDKIT_NAMESPACE}"
    return
  fi
  if [[ -n "${CONTROL_PLANE_JOB_NAMESPACE:-}" ]]; then
    printf '%s\n' "${CONTROL_PLANE_JOB_NAMESPACE}"
    return
  fi
  if [[ -r /var/run/secrets/kubernetes.io/serviceaccount/namespace ]]; then
    cat /var/run/secrets/kubernetes.io/serviceaccount/namespace
    return
  fi

  printf 'default\n'
}

buildkitd_image() {
  printf '%s\n' "${CONTROL_PLANE_BUILDKIT_IMAGE:-docker.io/moby/buildkit:rootless}"
}

buildkitd_service_port() {
  printf '%s\n' "${CONTROL_PLANE_BUILDKIT_SERVICE_PORT:-1234}"
}

buildkitd_start_timeout() {
  printf '%s\n' "${CONTROL_PLANE_BUILDKIT_START_TIMEOUT:-180s}"
}

buildkitd_service_account() {
  if [[ -n "${CONTROL_PLANE_BUILDKIT_SERVICE_ACCOUNT:-}" ]]; then
    printf '%s\n' "${CONTROL_PLANE_BUILDKIT_SERVICE_ACCOUNT}"
    return
  fi
  printf '%s\n' "${CONTROL_PLANE_JOB_SERVICE_ACCOUNT:-}"
}

buildkitd_state_root() {
  printf '%s\n' "${CONTROL_PLANE_BUILDKIT_STATE_ROOT:-${TMPDIR:-/tmp}/control-plane-buildkitd}"
}

buildkitd_context_stamp_path() {
  local image_tag="$1"
  local label_key="$2"
  local state_root
  local stamp_id

  require_command sha256sum
  state_root="$(buildkitd_state_root)"
  mkdir -p "${state_root}"
  stamp_id="$(printf '%s\0%s' "${image_tag}" "${label_key}" | sha256sum | awk '{print $1}')"
  printf '%s/%s.context-sha256\n' "${state_root}" "${stamp_id}"
}

record_image_context_hash_for_toolchain() {
  local toolchain="$1"
  local image_tag="$2"
  local label_key="$3"
  local context_hash="$4"

  case "${toolchain}" in
    docker)
      return 0
      ;;
    buildkitd)
      local stamp_path

      stamp_path="$(buildkitd_context_stamp_path "${image_tag}" "${label_key}")"
      printf '%s\n' "${context_hash}" > "${stamp_path}"
      ;;
    *)
      printf 'Unsupported toolchain: %s\n' "${toolchain}" >&2
      exit 1
      ;;
  esac
}

buildx_local_cache_dir_for_context() {
  local context_dir="$1"
  local cache_root="${CONTROL_PLANE_BUILDX_CACHE_ROOT:-}"
  local context_path

  [[ -n "${cache_root}" ]] || {
    printf '%s\n' ''
    return 0
  }

  require_command sha256sum
  context_path="$(cd "${context_dir}" && pwd -P)"
  printf '%s/%s\n' "${cache_root}" "$(printf '%s' "${context_path}" | sha256sum | awk '{print $1}')"
}

prepare_buildx_local_cache() {
  local context_dir="$1"
  local args_name="$2"
  local cache_dir_name="$3"
  local new_cache_dir_name="$4"
  local cache_root="${CONTROL_PLANE_BUILDX_CACHE_ROOT:-}"
  local cache_dir_value
  local new_cache_dir_value
  local -n args_ref="${args_name}"

  if [[ -z "${cache_root}" ]]; then
    printf -v "${cache_dir_name}" '%s' ''
    printf -v "${new_cache_dir_name}" '%s' ''
    return 0
  fi

  cache_dir_value="$(buildx_local_cache_dir_for_context "${context_dir}")"
  new_cache_dir_value="${cache_dir_value}-new"
  mkdir -p "${cache_root}" "${cache_dir_value}"
  rm -rf "${new_cache_dir_value}"
  args_ref+=(--cache-from "type=local,src=${cache_dir_value}" --cache-to "type=local,dest=${new_cache_dir_value},mode=max")
  printf -v "${cache_dir_name}" '%s' "${cache_dir_value}"
  printf -v "${new_cache_dir_name}" '%s' "${new_cache_dir_value}"
}

finalize_buildx_local_cache() {
  local cache_dir="$1"
  local new_cache_dir="$2"

  [[ -n "${cache_dir}" ]] || return 0
  [[ -d "${new_cache_dir}" ]] || return 0

  rm -rf "${cache_dir}"
  mv "${new_cache_dir}" "${cache_dir}"
}

rust_container_cache_dir_for_scope() {
  local cache_scope="$1"
  local cache_root="${CONTROL_PLANE_RUST_CONTAINER_CACHE_ROOT:-}"

  [[ -n "${cache_root}" ]] || {
    printf '%s\n' ''
    return 0
  }

  require_command sha256sum
  printf '%s/%s\n' "${cache_root}" "$(printf '%s' "${cache_scope}" | sha256sum | awk '{print $1}')"
}

prepare_rust_container_cache() {
  local cache_scope="$1"
  local home_dir_name="$2"
  local target_dir_name="$3"
  local temp_root_name="$4"
  local cache_dir
  local home_dir
  local target_dir
  local temp_root=''

  cache_dir="$(rust_container_cache_dir_for_scope "${cache_scope}")"
  if [[ -n "${cache_dir}" ]]; then
    home_dir="${cache_dir}/home"
    target_dir="${cache_dir}/target"
  else
    temp_root="$(mktemp -d)"
    home_dir="${temp_root}/home"
    target_dir="${temp_root}/target"
  fi

  mkdir -p "${home_dir}/.cargo" "${target_dir}"
  printf -v "${home_dir_name}" '%s' "${home_dir}"
  printf -v "${target_dir_name}" '%s' "${target_dir}"
  printf -v "${temp_root_name}" '%s' "${temp_root}"
}

buildkitd_resource_name() {
  local seed="$1"
  local suffix

  require_command sha256sum
  suffix="$(printf '%s\n%s\n%s\n' "${seed}" "$$" "${RANDOM}" | sha256sum | awk '{print substr($1, 1, 12)}')"
  printf 'control-plane-buildkitd-%s\n' "${suffix}"
}

buildkitd_remote_addr() {
  local service_name="$1"
  local namespace="$2"
  local port

  port="$(buildkitd_service_port)"
  printf 'tcp://%s.%s.svc.cluster.local:%s\n' "${service_name}" "${namespace}" "${port}"
}

buildkitd_cleanup_resources() {
  local builder_name="$1"
  local service_name="$2"
  local pod_name="$3"
  local namespace="$4"

  docker buildx rm -f "${builder_name}" >/dev/null 2>&1 || true
  kubectl delete service "${service_name}" -n "${namespace}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete pod "${pod_name}" -n "${namespace}" --ignore-not-found >/dev/null 2>&1 || true
}

buildkitd_create_resources() {
  local builder_name="$1"
  local service_name="$2"
  local pod_name="$3"
  local namespace="$4"
  local port="$5"
  local image="$6"
  local service_account="$7"
  local service_account_yaml=''

  if [[ -n "${service_account}" ]]; then
    service_account_yaml="  serviceAccountName: ${service_account}"
  fi

  if ! cat <<EOF | kubectl create -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: ${pod_name}
spec:
  restartPolicy: Never
${service_account_yaml}
  containers:
    - name: buildkitd
      image: ${image}
      args:
        - --addr
        - tcp://0.0.0.0:${port}
        - --oci-worker-no-process-sandbox
      ports:
        - containerPort: ${port}
          name: grpc
      readinessProbe:
        tcpSocket:
          port: ${port}
        periodSeconds: 2
      securityContext:
        seccompProfile:
          type: Unconfined
        appArmorProfile:
          type: Unconfined
EOF
  then
    buildkitd_cleanup_resources "${builder_name}" "${service_name}" "${pod_name}" "${namespace}"
    return 1
  fi

  if ! cat <<EOF | kubectl create -f - >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: ${service_name}
  namespace: ${namespace}
spec:
  selector:
    app.kubernetes.io/name: ${pod_name}
  ports:
    - name: grpc
      port: ${port}
      targetPort: ${port}
EOF
  then
    buildkitd_cleanup_resources "${builder_name}" "${service_name}" "${pod_name}" "${namespace}"
    return 1
  fi

  if ! kubectl wait -n "${namespace}" --for=condition=Ready "pod/${pod_name}" --timeout="$(buildkitd_start_timeout)" >/dev/null; then
    kubectl describe pod "${pod_name}" -n "${namespace}" >&2 || true
    kubectl logs "${pod_name}" -n "${namespace}" --tail=100 >&2 || true
    buildkitd_cleanup_resources "${builder_name}" "${service_name}" "${pod_name}" "${namespace}"
    return 1
  fi
}

buildkitd_prepare_remote_builder() {
  local seed="$1"
  local namespace
  local port
  local image
  local service_account
  local resource_name
  local pod_name
  local service_name
  local builder_name

  namespace="$(buildkitd_namespace)"
  port="$(buildkitd_service_port)"
  image="$(buildkitd_image)"
  service_account="$(buildkitd_service_account)"
  resource_name="$(buildkitd_resource_name "${seed}")"
  pod_name="${resource_name}"
  service_name="${resource_name}"
  builder_name="${resource_name}"

  if ! buildkitd_create_resources "${builder_name}" "${service_name}" "${pod_name}" "${namespace}" "${port}" "${image}" "${service_account}"; then
    return 1
  fi
  if ! docker buildx create \
    --name "${builder_name}" \
    --use \
    --driver remote \
    "$(buildkitd_remote_addr "${service_name}" "${namespace}")" \
    >/dev/null; then
    buildkitd_cleanup_resources "${builder_name}" "${service_name}" "${pod_name}" "${namespace}"
    return 1
  fi

  printf '%s\t%s\t%s\t%s\n' "${builder_name}" "${service_name}" "${pod_name}" "${namespace}"
}

build_image_for_toolchain() {
  local toolchain="$1"
  local image_tag="$2"
  local context_dir="$3"
  local build_bin
  local context_hash
  local context_hash_label_key
  local existing_context_hash
  local cache_dir=""
  local new_cache_dir=""
  local buildx_args=()

  build_bin="$(build_command_for_toolchain "${toolchain}")"
  context_hash="$(build_context_hash "${context_dir}")"
  context_hash_label_key="$(build_context_hash_label_key)"
  existing_context_hash="$(image_context_hash_for_toolchain "${toolchain}" "${image_tag}" "${context_hash_label_key}" || true)"

  if [[ -n "${existing_context_hash}" ]] && [[ "${existing_context_hash}" == "${context_hash}" ]]; then
    printf 'Reusing %s; build context unchanged\n' "${image_tag}" >&2
    return 0
  fi

  case "${toolchain}" in
    docker)
      prepare_buildx_local_cache "${context_dir}" buildx_args cache_dir new_cache_dir
      "${build_bin}" buildx build --load \
        "${buildx_args[@]}" \
        --label "${context_hash_label_key}=${context_hash}" \
        -t "${image_tag}" \
        "${context_dir}"
      finalize_buildx_local_cache "${cache_dir}" "${new_cache_dir}"
      ;;
    buildkitd)
      local builder_name
      local service_name
      local pod_name
      local namespace
      local cleanup_line
      local build_rc=0

      if ! cleanup_line="$(buildkitd_prepare_remote_builder "${image_tag}")"; then
        return 1
      fi
      IFS=$'\t' read -r builder_name service_name pod_name namespace <<<"${cleanup_line}"
      set +e
      "${build_bin}" buildx build \
        --builder "${builder_name}" \
        --output "type=image,name=${image_tag},push=false" \
        --label "${context_hash_label_key}=${context_hash}" \
        "${context_dir}"
      build_rc=$?
      set -e
      if [[ "${build_rc}" -eq 0 ]]; then
        record_image_context_hash_for_toolchain "${toolchain}" "${image_tag}" "${context_hash_label_key}" "${context_hash}"
      fi
      buildkitd_cleanup_resources "${builder_name}" "${service_name}" "${pod_name}" "${namespace}"
      if [[ "${build_rc}" -ne 0 ]]; then
        return "${build_rc}"
      fi
      ;;
    *)
      printf 'Unsupported toolchain: %s\n' "${toolchain}" >&2
      return 1
      ;;
  esac
}

build_image_target_for_toolchain() {
  local toolchain="$1"
  local image_tag="$2"
  local context_dir="$3"
  local target_name="$4"
  local build_bin
  local context_hash
  local context_hash_label_key
  local existing_context_hash
  local cache_dir=""
  local new_cache_dir=""
  local buildx_args=()

  build_bin="$(build_command_for_toolchain "${toolchain}")"
  context_hash="$(build_context_hash "${context_dir}")"
  context_hash_label_key="$(build_context_hash_label_key_for_target "${target_name}")"
  existing_context_hash="$(image_context_hash_for_toolchain "${toolchain}" "${image_tag}" "${context_hash_label_key}" || true)"

  if [[ -n "${existing_context_hash}" ]] && [[ "${existing_context_hash}" == "${context_hash}" ]]; then
    printf 'Reusing %s; build context unchanged for target %s\n' "${image_tag}" "${target_name}" >&2
    return 0
  fi

  case "${toolchain}" in
    docker)
      prepare_buildx_local_cache "${context_dir}" buildx_args cache_dir new_cache_dir
      "${build_bin}" buildx build --load \
        "${buildx_args[@]}" \
        --target "${target_name}" \
        --label "${context_hash_label_key}=${context_hash}" \
        -t "${image_tag}" \
        "${context_dir}"
      finalize_buildx_local_cache "${cache_dir}" "${new_cache_dir}"
      ;;
    buildkitd)
      local builder_name
      local service_name
      local pod_name
      local namespace
      local cleanup_line
      local build_rc=0

      if ! cleanup_line="$(buildkitd_prepare_remote_builder "${image_tag}-${target_name}")"; then
        return 1
      fi
      IFS=$'\t' read -r builder_name service_name pod_name namespace <<<"${cleanup_line}"
      set +e
      "${build_bin}" buildx build \
        --builder "${builder_name}" \
        --output "type=image,name=${image_tag},push=false" \
        --target "${target_name}" \
        --label "${context_hash_label_key}=${context_hash}" \
        "${context_dir}"
      build_rc=$?
      set -e
      if [[ "${build_rc}" -eq 0 ]]; then
        record_image_context_hash_for_toolchain "${toolchain}" "${image_tag}" "${context_hash_label_key}" "${context_hash}"
      fi
      buildkitd_cleanup_resources "${builder_name}" "${service_name}" "${pod_name}" "${namespace}"
      if [[ "${build_rc}" -ne 0 ]]; then
        return "${build_rc}"
      fi
      ;;
    *)
      printf 'Unsupported toolchain: %s\n' "${toolchain}" >&2
      return 1
      ;;
  esac
}
