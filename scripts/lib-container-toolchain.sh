#!/usr/bin/env bash

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
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
      'This control-plane image keeps Podman for execution-plane workflows, but scripts/lint.sh and scripts/build-test.sh still require a host or CI build runner.' \
      'Run those validation entry points in GitHub Actions, or from a host with Docker Buildx or rootless Podman.' \
      >&2
  fi
}

report_podman_runtime_failure() {
  local output="$1"

  if grep -Fq 'newuidmap' <<<"${output}" && grep -Fq 'Operation not permitted' <<<"${output}"; then
    printf '%s\n' \
      "Podman is installed but unusable in this environment: nested user namespace setup is blocked (\`newuidmap\` failed)." \
      'Use a working Docker buildx daemon, or run the workflow in GitHub Actions / on a container host that supports rootless user namespaces.' \
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
      if command -v buildah >/dev/null 2>&1; then
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

detect_container_runtime() {
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

  case "${toolchain}" in
    docker)
      docker buildx build --load -t "${image_tag}" "${context_dir}"
      ;;
    podman)
      if command -v buildah >/dev/null 2>&1; then
        buildah bud --tag "${image_tag}" "${context_dir}"
      else
        podman build --tag "${image_tag}" "${context_dir}"
      fi
      ;;
    *)
      printf 'Unsupported toolchain: %s\n' "${toolchain}" >&2
      exit 1
      ;;
  esac
}
