#!/usr/bin/env bash

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

docker_build_toolchain_available() {
  command -v docker >/dev/null 2>&1 \
    && docker buildx version >/dev/null 2>&1 \
    && docker info >/dev/null 2>&1
}

podman_build_toolchain_available() {
  command -v podman >/dev/null 2>&1 \
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
    require_command "${requested_runtime}"
    printf '%s\n' "${requested_runtime}"
    return
  fi

  case "${requested_toolchain}" in
    docker)
      require_command docker
      printf 'docker\n'
      return
      ;;
    podman)
      require_command podman
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

  if command -v docker >/dev/null 2>&1; then
    printf 'docker\n'
    return
  fi

  if command -v podman >/dev/null 2>&1; then
    printf 'podman\n'
    return
  fi

  printf 'Missing supported container runtime. Install docker or podman.\n' >&2
  exit 1
}

detect_build_test_toolchain() {
  local requested_toolchain="${CONTROL_PLANE_TOOLCHAIN:-}"

  case "${requested_toolchain}" in
    docker)
      docker_build_toolchain_available || {
        printf 'Docker toolchain requires a working docker CLI with buildx support.\n' >&2
        exit 1
      }
      printf 'docker\n'
      return
      ;;
    podman)
      podman_build_toolchain_available || {
        printf 'Podman toolchain requires podman with image build support.\n' >&2
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

  printf 'Missing supported build/test toolchain. Provide a working docker buildx environment, or install podman with image build support.\n' >&2
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
