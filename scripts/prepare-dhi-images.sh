#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cache_dir="${CONTROL_PLANE_DHI_CACHE_DIR:-${HOME}/.cache/control-plane/dhi-images}"
yamllint_dockerfile="${CONTROL_PLANE_YAMLLINT_DOCKERFILE:-${script_dir}/../containers/yamllint/Dockerfile}"
dhi_images=()

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

require_command podman
require_command awk

if [[ ! -f "${yamllint_dockerfile}" ]]; then
  printf 'Missing yamllint Dockerfile: %s\n' "${yamllint_dockerfile}" >&2
  exit 1
fi

while IFS= read -r image; do
  if [[ -n "${image}" ]]; then
    dhi_images+=("${image}")
  fi
done < <(
  awk '$1 == "FROM" && $2 ~ /^dhi\.io\// { print $2 }' "${yamllint_dockerfile}" | LC_ALL=C sort -u
)

if [[ "${#dhi_images[@]}" -eq 0 ]]; then
  printf 'No DHI images found in %s\n' "${yamllint_dockerfile}" >&2
  exit 1
fi

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

pull_image_with_retry() {
  local image="$1"
  local max_attempts=5
  local attempt output

  for attempt in $(seq 1 "${max_attempts}"); do
    if output="$(podman pull "${image}" 2>&1)"; then
      return 0
    fi

    printf '%s\n' "${output}" >&2

    if [[ "${attempt}" -eq "${max_attempts}" ]]; then
      return 1
    fi

    printf 'Retrying DHI pull (%s/%s): %s\n' "$((attempt + 1))" "${max_attempts}" "${image}" >&2
    sleep 5
  done
}

for image in "${dhi_images[@]}"; do
  archive_path="${cache_dir}/$(printf '%s' "${image}" | tr '/:' '__').oci.tar"

  if ! podman image exists "${image}"; then
    if [[ -f "${archive_path}" ]]; then
      if ! podman load --input "${archive_path}" >/dev/null; then
        printf 'Cached DHI image archive is unusable, removing %s and repulling\n' "${archive_path}" >&2
        rm -f "${archive_path}"
      fi
    fi

    if ! podman image exists "${image}"; then
      login_dhi
      pull_image_with_retry "${image}" >/dev/null
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
