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

read_file_with_container_runtime() {
  local container_bin="$1"
  local helper_image="$2"
  local file_path="$3"
  local mounted_path="${4:-/run/control-plane-runtime/secret}"
  local bridge_runtime="${container_bin}"
  local value=""

  [[ -f "${file_path}" ]] || {
    printf 'Secret file does not exist: %s\n' "${file_path}" >&2
    return 1
  }

  if [[ "${bridge_runtime}" != "podman" ]] \
    && [[ "${bridge_runtime}" != "docker" ]] \
    && command -v podman >/dev/null 2>&1; then
    bridge_runtime="podman"
  fi

  case "${bridge_runtime}" in
    podman|docker)
      "${bridge_runtime}" run --rm \
        --user 0:0 \
        -v "${file_path}:${mounted_path}:ro" \
        --entrypoint cat \
        "${helper_image}" \
        "${mounted_path}"
      ;;
    *)
      IFS= read -r value < "${file_path}" || true
      printf '%s' "${value}"
      ;;
  esac
}

docker_runtime_available() {
  command -v docker >/dev/null 2>&1 \
    && docker info >/dev/null 2>&1
}

running_inside_control_plane_image() {
  [[ -x /usr/local/bin/control-plane-entrypoint ]] \
    && [[ -x /usr/local/bin/control-plane-run ]]
}

report_missing_build_test_toolchain() {
  printf 'Missing supported build/test toolchain. Provide a working docker buildx environment, or podman with image build support and a usable rootless runtime.\n' >&2

  if running_inside_control_plane_image; then
    printf '%s\n' \
      'This control-plane image includes the Podman/Kind toolchain used by scripts/lint.sh and scripts/build-test.sh, but nested containers still depend on the outer host or Kubernetes securityContext.' \
      'When running on Kubernetes, prefer the sample least-privilege SSH/Copilot deployment and route execution through Kubernetes Jobs or GitHub Actions by default.' \
      'The image already provisions /etc/subuid and /etc/subgid for the copilot user, but those files alone cannot override host/runtime restrictions on nested user namespaces, /dev/fuse, or other local Podman requirements.' \
      >&2
  fi
}

podman_reports_userns_failure() {
  local output="$1"

  {
    grep -Fq 'newuidmap' <<<"${output}" && grep -Fq 'Operation not permitted' <<<"${output}";
  } || {
    grep -Fq 'newgidmap' <<<"${output}" && grep -Fq 'Operation not permitted' <<<"${output}";
  } || grep -Fqi 'cannot set user namespace' <<<"${output}" \
    || grep -Fq 'cannot clone: Operation not permitted' <<<"${output}" \
    || grep -Fq 'cannot re-exec process' <<<"${output}"
}

report_podman_runtime_failure() {
  local output="$1"

  if podman_reports_userns_failure "${output}"; then
    printf '%s\n' \
      'Podman is installed but unusable in this environment: rootless user-namespace setup is blocked.' \
      'On Linux 5.12+, SETFCAP is also required to map UID 0 in a new user namespace, but re-adding capabilities inside the nested container is not sufficient by itself.' \
      'Entries in /etc/subuid and /etc/subgid inside the nested container are not enough; the outer host/runtime still has to allow user namespaces, newuidmap/newgidmap, and the required seccomp/sysctl settings.' \
      'Even privileged Pods can still fail here when the outer host/runtime blocks nested user namespaces.' \
      'Use the sample SSH/Copilot plus Kubernetes Job path, or fall back to GitHub Actions / a host runner. If you must run local Podman in-cluster, the outer runtime still needs to permit nested user namespaces and related helpers.' \
      >&2
  fi
}

podman_runtime_available() {
  local output

  command -v podman >/dev/null 2>&1 || return 1

  if output="$(podman info 2>&1)"; then
    return 0
  fi

  report_podman_runtime_failure "${output}"
  return 1
}

docker_build_toolchain_available() {
  docker_runtime_available \
    && docker buildx version >/dev/null 2>&1
}

podman_build_toolchain_available() {
  podman_runtime_available \
    && podman build --help >/dev/null 2>&1
}

container_runtime_for_toolchain() {
  case "$1" in
    docker)
      printf 'docker\n'
      ;;
    podman)
      printf 'podman\n'
      ;;
    *)
      printf 'Unsupported toolchain: %s\n' "$1" >&2
      exit 1
      ;;
  esac
}

build_command_for_toolchain() {
  case "$1" in
    docker)
      printf 'docker\n'
      ;;
    podman)
      if command -v buildah >/dev/null 2>&1 && ! prefer_podman_remote_build; then
        printf 'buildah\n'
      else
        printf 'podman\n'
      fi
      ;;
    *)
      printf 'Unsupported toolchain: %s\n' "$1" >&2
      exit 1
      ;;
  esac
}

build_context_hash() {
  local context_dir="$1"

  [[ -d "${context_dir}" ]] || {
    printf 'Build context directory not found: %s\n' "${context_dir}" >&2
    exit 1
  }
  require_command tar
  require_command sha256sum

  tar \
    --sort=name \
    --mtime='UTC 1970-01-01' \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    -cf - \
    -C "${context_dir}" \
    . \
    | sha256sum \
    | awk '{print $1}'
}

build_context_hash_label_key() {
  printf '%s\n' 'io.github.chalharu.control-plane.build-context-sha256'
}

image_context_hash_for_toolchain() {
  local toolchain="$1"
  local image_tag="$2"
  local label_key="$3"
  local container_bin

  container_bin="$(container_runtime_for_toolchain "${toolchain}")"
  "${container_bin}" image inspect --format "{{ index .Config.Labels \"${label_key}\" }}" "${image_tag}" 2>/dev/null
}

prefer_podman_remote_build() {
  [[ -n "${CONTAINER_HOST:-}" ]] \
    || [[ -n "${DOCKER_HOST:-}" ]] \
    || [[ "${CONTROL_PLANE_LOCAL_PODMAN_MODE:-}" == "rootful-service" ]]
}

detect_container_runtime() {
  load_control_plane_runtime_env

  local requested_runtime="${CONTROL_PLANE_CONTAINER_BIN:-}"
  local requested_toolchain="${CONTROL_PLANE_TOOLCHAIN:-}"

  if [[ -n "${requested_runtime}" ]]; then
    case "${requested_runtime}" in
      docker)
        docker_runtime_available || {
          printf 'Requested docker runtime is not usable in this environment.\n' >&2
          exit 1
        }
        ;;
      podman)
        podman_runtime_available || {
          printf 'Requested podman runtime is not usable in this environment.\n' >&2
          exit 1
        }
        ;;
      *)
        require_command "${requested_runtime}"
        ;;
    esac
    printf '%s\n' "${requested_runtime}"
    return
  fi

  case "${requested_toolchain}" in
    docker)
      docker_runtime_available || {
        printf 'Requested docker toolchain is not usable in this environment.\n' >&2
        exit 1
      }
      printf 'docker\n'
      return
      ;;
    podman)
      podman_runtime_available || {
        printf 'Requested podman toolchain is not usable in this environment.\n' >&2
        exit 1
      }
      printf 'podman\n'
      return
      ;;
    '')
      ;;
    *)
      printf 'Unsupported CONTROL_PLANE_TOOLCHAIN: %s\n' "${requested_toolchain}" >&2
      exit 1
      ;;
  esac

  if docker_runtime_available; then
    printf 'docker\n'
    return
  fi

  if podman_runtime_available; then
    printf 'podman\n'
    return
  fi

  printf 'Missing supported container runtime. Provide a working docker daemon, or podman with a usable rootless user namespace environment.\n' >&2
  exit 1
}

detect_build_test_toolchain() {
  load_control_plane_runtime_env

  local requested_toolchain="${CONTROL_PLANE_TOOLCHAIN:-}"

  case "${requested_toolchain}" in
    docker)
      docker_build_toolchain_available || {
        printf 'Docker toolchain requires a working docker CLI with buildx support.\n' >&2
        report_missing_build_test_toolchain
        exit 1
      }
      printf 'docker\n'
      return
      ;;
    podman)
      podman_build_toolchain_available || {
        printf 'Podman toolchain requires podman with image build support and a usable rootless runtime.\n' >&2
        report_missing_build_test_toolchain
        exit 1
      }
      printf 'podman\n'
      return
      ;;
    '')
      ;;
    *)
      printf 'Unsupported CONTROL_PLANE_TOOLCHAIN: %s\n' "${requested_toolchain}" >&2
      exit 1
      ;;
  esac

  if docker_build_toolchain_available; then
    printf 'docker\n'
    return
  fi

  if podman_build_toolchain_available; then
    printf 'podman\n'
    return
  fi

  report_missing_build_test_toolchain
  exit 1
}

build_image_for_toolchain() {
  local toolchain="$1"
  local image_tag="$2"
  local context_dir="$3"
  local build_isolation=""
  local build_bin=""
  local context_hash=""
  local context_hash_label_key=""
  local existing_context_hash=""

  load_control_plane_runtime_env
  build_isolation="${CONTROL_PLANE_PODMAN_BUILD_ISOLATION:-}"
  if [[ -z "${build_isolation}" ]] && [[ "${CONTROL_PLANE_LOCAL_PODMAN_MODE:-}" == "rootful-service" ]]; then
    build_isolation="chroot"
  fi
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
      docker buildx build --load \
        --label "${context_hash_label_key}=${context_hash}" \
        -t "${image_tag}" \
        "${context_dir}"
      ;;
    podman)
      if [[ "${build_bin}" == "buildah" ]]; then
        if [[ -n "${build_isolation}" ]] && [[ -z "${BUILDAH_ISOLATION:-}" ]]; then
          BUILDAH_ISOLATION="${build_isolation}" buildah bud \
            --label "${context_hash_label_key}=${context_hash}" \
            --tag "${image_tag}" \
            "${context_dir}"
        else
          buildah bud \
            --label "${context_hash_label_key}=${context_hash}" \
            --tag "${image_tag}" \
            "${context_dir}"
        fi
      else
        if [[ -n "${build_isolation}" ]]; then
          podman build \
            --isolation="${build_isolation}" \
            --label "${context_hash_label_key}=${context_hash}" \
            --tag "${image_tag}" \
            "${context_dir}"
        else
          podman build \
            --label "${context_hash_label_key}=${context_hash}" \
            --tag "${image_tag}" \
            "${context_dir}"
        fi
      fi
      ;;
    *)
      printf 'Unsupported toolchain: %s\n' "${toolchain}" >&2
      exit 1
      ;;
  esac
}
