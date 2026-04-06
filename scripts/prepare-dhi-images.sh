#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"

dockerfile_path="${CONTROL_PLANE_DHI_SCAN_DOCKERFILE:-${script_dir}/../containers/control-plane/Dockerfile}"
dhi_images=()
temporary_docker_config=""

require_command docker
require_command awk
load_control_plane_runtime_env
dockerhub_username="${DOCKERHUB_USERNAME:-}"
dockerhub_token="${DOCKERHUB_TOKEN:-}"

cleanup() {
  if [[ -n "${temporary_docker_config}" ]]; then
    rm -rf "${temporary_docker_config}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

[[ -f "${dockerfile_path}" ]] || {
  printf 'Missing Dockerfile: %s\n' "${dockerfile_path}" >&2
  exit 1
}

while IFS= read -r image; do
  if [[ -n "${image}" ]]; then
    dhi_images+=("${image}")
  fi
done < <(awk '$1 == "FROM" && $2 ~ /^dhi\.io\// { print $2 }' "${dockerfile_path}" | LC_ALL=C sort -u)

if [[ "${#dhi_images[@]}" -eq 0 ]]; then
  printf 'No DHI images found in %s\n' "${dockerfile_path}" >&2
  exit 0
fi

ensure_dhi_auth() {
  local auth_b64=""

  if [[ -n "${DOCKER_CONFIG:-}" ]] && [[ -f "${DOCKER_CONFIG}/config.json" ]]; then
    return
  fi

  if [[ -z "${dockerhub_username}" ]] && [[ -z "${dockerhub_token}" ]]; then
    return 0
  fi

  : "${dockerhub_username:?DOCKERHUB_USERNAME is required when DOCKERHUB_TOKEN is set}"
  : "${dockerhub_token:?DOCKERHUB_TOKEN is required when DOCKERHUB_USERNAME is set}"

  temporary_docker_config="$(mktemp -d)"
  export DOCKER_CONFIG="${temporary_docker_config}"
  auth_b64="$(printf '%s' "${dockerhub_username}:${dockerhub_token}" | base64 | tr -d '\n')"
  cat > "${DOCKER_CONFIG}/config.json" <<EOF
{"auths":{"dhi.io":{"auth":"${auth_b64}"}}}
EOF
  chmod 600 "${DOCKER_CONFIG}/config.json"
}

pull_image_with_retry() {
  local image="$1"
  local max_attempts=5
  local attempt output

  for attempt in $(seq 1 "${max_attempts}"); do
    if output="$(docker pull "${image}" 2>&1)"; then
      return 0
    fi

    printf '%s\n' "${output}" >&2

    case "${output}" in
      *"unauthorized"*|*"denied"*)
        if [[ -z "${dockerhub_username}" ]] && [[ -z "${dockerhub_token}" ]]; then
          printf '%s\n' \
            'DHI auth is not configured. Set DOCKERHUB_USERNAME/DOCKERHUB_TOKEN or preconfigure Docker auth before running this script.' \
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

ensure_dhi_auth
for image in "${dhi_images[@]}"; do
  if ! docker image inspect "${image}" >/dev/null 2>&1; then
    if ! pull_image_with_retry "${image}" >/dev/null; then
      printf 'Failed to prepare DHI image: %s\n' "${image}" >&2
      exit 1
    fi
  fi
done
