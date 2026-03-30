#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"
yamllint_dockerfile="${CONTROL_PLANE_YAMLLINT_DOCKERFILE:-${script_dir}/../containers/yamllint/Dockerfile}"
dhi_images=()
dockerhub_username="${DOCKERHUB_USERNAME:-}"
dockerhub_token="${DOCKERHUB_TOKEN:-}"
# renovate: datasource=docker depName=ghcr.io/renovatebot/renovate versioning=docker
auth_helper_image="${CONTROL_PLANE_DOCKERHUB_AUTH_HELPER_IMAGE:-ghcr.io/renovatebot/renovate:43.99.0@sha256:aae697086b93427dcde46eb92e08e334b018946ce19339bf044ce971ca1626e2}"

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

if [[ -z "${dockerhub_username}" ]] && [[ -n "${DOCKERHUB_USERNAME_FILE:-}" ]]; then
  [[ -f "${DOCKERHUB_USERNAME_FILE}" ]] || {
    printf 'DOCKERHUB_USERNAME_FILE does not exist: %s\n' "${DOCKERHUB_USERNAME_FILE}" >&2
    exit 1
  }
  IFS= read -r dockerhub_username < "${DOCKERHUB_USERNAME_FILE}" || true
fi

if [[ -z "${dockerhub_token}" ]] && [[ -n "${DOCKERHUB_TOKEN_FILE:-}" ]]; then
  dockerhub_token="$(read_file_with_container_runtime \
    podman \
    "${auth_helper_image}" \
    "${DOCKERHUB_TOKEN_FILE}" \
    /run/control-plane/dockerhub-token)"
fi

logged_in=0

login_dhi() {
  if (( logged_in )); then
    return
  fi

  : "${dockerhub_username:?DOCKERHUB_USERNAME or DOCKERHUB_USERNAME_FILE is required to pull uncached DHI images}"
  : "${dockerhub_token:?DOCKERHUB_TOKEN or DOCKERHUB_TOKEN_FILE is required to pull uncached DHI images}"
  local max_attempts=5
  local attempt

  for attempt in $(seq 1 "${max_attempts}"); do
    if printf '%s' "${dockerhub_token}" | podman login dhi.io -u "${dockerhub_username}" --password-stdin >/dev/null; then
      logged_in=1
      return 0
    fi

    if [[ "${attempt}" -eq "${max_attempts}" ]]; then
      return 1
    fi

    printf 'Retrying DHI login (%s/%s)\n' "$((attempt + 1))" "${max_attempts}" >&2
    sleep 5
  done
}

pull_image_with_retry() {
  local image="$1"
  local max_attempts=5
  local attempt output

  if ! login_dhi; then
    printf 'DHI login failed after retries: %s\n' "${image}" >&2
    return 1
  fi

  for attempt in $(seq 1 "${max_attempts}"); do
    if output="$(podman pull "${image}" 2>&1)"; then
      return 0
    fi

    printf '%s\n' "${output}" >&2

    case "${output}" in
      *"authenticating creds"*|*"Requesting bearer token"*|*"unauthorized"*|*"denied"*)
        logged_in=0
        if ! login_dhi; then
          printf 'DHI login failed after retries: %s\n' "${image}" >&2
          return 1
        fi
        ;;
    esac

    if [[ "${attempt}" -eq "${max_attempts}" ]]; then
      return 1
    fi

    printf 'Retrying DHI pull (%s/%s): %s\n' "$((attempt + 1))" "${max_attempts}" "${image}" >&2
    sleep 5
  done
}

# Podman cannot reliably restore digest-pinned DHI images from local archives,
# so keep the preparation step as a direct pull with retries.
for image in "${dhi_images[@]}"; do
  if ! podman image exists "${image}"; then
    if ! pull_image_with_retry "${image}" >/dev/null; then
      printf 'Failed to prepare DHI image: %s\n' "${image}" >&2
      exit 1
    fi
  fi

  if ! podman image exists "${image}"; then
    printf 'Failed to prepare DHI image: %s\n' "${image}" >&2
    exit 1
  fi
done
