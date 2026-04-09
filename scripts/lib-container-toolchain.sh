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

container_runtime_for_toolchain() {
  case "$1" in
    docker)
      printf 'docker\n'
      ;;
    *)
      printf 'Unsupported toolchain: %s\n' "$1" >&2
      exit 1
      ;;
  esac
}

build_command_for_toolchain() {
  container_runtime_for_toolchain "$1"
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

  container_bin="$(container_runtime_for_toolchain "${toolchain}")"
  "${container_bin}" image inspect --format "{{ index .Config.Labels \"${label_key}\" }}" "${image_tag}" 2>/dev/null
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
    *)
      printf 'Unsupported toolchain: %s\n' "${toolchain}" >&2
      exit 1
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
    *)
      printf 'Unsupported toolchain: %s\n' "${toolchain}" >&2
      exit 1
      ;;
  esac
}
