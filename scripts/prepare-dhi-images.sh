#!/usr/bin/env bash
set -euo pipefail

cache_dir="${CONTROL_PLANE_DHI_CACHE_DIR:-${HOME}/.cache/control-plane/dhi-images}"
dhi_images=(
  # renovate: datasource=docker depName=dhi.io/python versioning=docker
  "dhi.io/python:3-alpine3.23-dev"
  # renovate: datasource=docker depName=dhi.io/python versioning=docker
  "dhi.io/python:3-alpine3.23"
)

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

require_command podman

mkdir -p "${cache_dir}"

logged_in=0

login_dhi() {
  if (( logged_in )); then
    return
  fi

  : "${DOCKERHUB_USERNAME:?DOCKERHUB_USERNAME is required to pull uncached DHI images}"
  : "${DOCKERHUB_TOKEN:?DOCKERHUB_TOKEN is required to pull uncached DHI images}"
  printf '%s' "${DOCKERHUB_TOKEN}" | podman login dhi.io -u "${DOCKERHUB_USERNAME}" --password-stdin >/dev/null
  logged_in=1
}

for image in "${dhi_images[@]}"; do
  archive_path="${cache_dir}/$(printf '%s' "${image}" | tr '/:' '__').oci.tar"

  if ! podman image exists "${image}"; then
    if [[ -f "${archive_path}" ]]; then
      if ! podman load --input "${archive_path}" >/dev/null; then
        rm -f "${archive_path}"
      fi
    fi

    if ! podman image exists "${image}"; then
      login_dhi
      podman pull "${image}" >/dev/null
    fi
  fi

  if ! podman image exists "${image}"; then
    printf 'Failed to prepare DHI image: %s\n' "${image}" >&2
    exit 1
  fi

  if [[ ! -f "${archive_path}" ]]; then
    podman save --format oci-archive --output "${archive_path}" "${image}" >/dev/null
  fi
done
