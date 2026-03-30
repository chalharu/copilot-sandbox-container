#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"
yamllint_dockerfile="${CONTROL_PLANE_YAMLLINT_DOCKERFILE:-${script_dir}/../containers/yamllint/Dockerfile}"
dhi_images=()
temporary_auth_file=""

require_command podman
require_command awk
load_control_plane_runtime_env
dockerhub_username="${DOCKERHUB_USERNAME:-}"
dockerhub_token="${DOCKERHUB_TOKEN:-}"

cleanup() {
  if [[ -n "${temporary_auth_file}" ]]; then
    rm -f "${temporary_auth_file}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

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

ensure_dhi_auth() {
  if [[ -n "${REGISTRY_AUTH_FILE:-}" ]]; then
    [[ -f "${REGISTRY_AUTH_FILE}" ]] || {
      printf 'REGISTRY_AUTH_FILE does not exist: %s\n' "${REGISTRY_AUTH_FILE}" >&2
      exit 1
    }
    return
  fi

  if [[ -z "${dockerhub_username}" ]] && [[ -z "${dockerhub_token}" ]]; then
    return 0
  fi

  : "${dockerhub_username:?DOCKERHUB_USERNAME is required when DOCKERHUB_TOKEN is set}"
  : "${dockerhub_token:?DOCKERHUB_TOKEN is required when DOCKERHUB_USERNAME is set}"

  temporary_auth_file="$(mktemp)"
  write_registry_auth_file "${temporary_auth_file}" dhi.io "${dockerhub_username}" "${dockerhub_token}"
  export REGISTRY_AUTH_FILE="${temporary_auth_file}"
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

    case "${output}" in
      *"authenticating creds"*|*"Requesting bearer token"*|*"unauthorized"*|*"denied"*)
        if [[ -z "${REGISTRY_AUTH_FILE:-}" ]] && [[ -z "${dockerhub_username}" ]] && [[ -z "${dockerhub_token}" ]]; then
          printf '%s\n' \
            'DHI auth is not configured. Set DOCKERHUB_USERNAME/DOCKERHUB_TOKEN or preconfigure Podman auth before running this script.' \
            >&2
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
    ensure_dhi_auth
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
