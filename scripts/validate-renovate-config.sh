#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"

container_bin=""
# renovate: datasource=docker depName=ghcr.io/renovatebot/renovate versioning=docker
renovate_image="${CONTROL_PLANE_RENOVATE_IMAGE:-ghcr.io/renovatebot/renovate:43.85.0@sha256:6110c2838f2df7842154dbaad5561131ad29f58dfa2ccaeec4df8cba14d6de20}"
base_dir=""
log_file=""
# Use container root so restrictive workspace mounts remain readable across
# Docker, rootful Podman, and rootless Podman.
workspace_access_user="0:0"
renovate_env=()
dockerhub_username="${DOCKERHUB_USERNAME:-}"
dockerhub_token="${DOCKERHUB_TOKEN:-}"

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "${value}"
}

cleanup() {
  local cleanup_container_bin="${container_bin:-}"
  local cleanup_renovate_image="${renovate_image:-}"
  local cleanup_base_dir="${base_dir:-}"
  local cleanup_log_file="${log_file:-}"

  if [[ -n "${cleanup_container_bin}" ]] && command -v "${cleanup_container_bin}" >/dev/null 2>&1 && [[ -d "${cleanup_base_dir}" ]]; then
    "${cleanup_container_bin}" run --rm \
      --user "${workspace_access_user}" \
      -v "${cleanup_base_dir}:/tmp/renovate-base" \
      --entrypoint sh \
      "${cleanup_renovate_image}" \
      -c 'rm -rf /tmp/renovate-base/* /tmp/renovate-base/.[!.]* /tmp/renovate-base/..?* 2>/dev/null || true' \
      >/dev/null 2>&1 || true
  fi

  if [[ -n "${cleanup_base_dir}" ]]; then
    rm -rf "${cleanup_base_dir}" >/dev/null 2>&1 || true
  fi

  if [[ -n "${cleanup_log_file}" ]]; then
    rm -f "${cleanup_log_file}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

container_bin="$(detect_container_runtime)"
base_dir="$(mktemp -d)"
log_file="$(mktemp)"

# Renovate runs as a non-root UID, so the mounted cache directory must be
# writable even when executed through rootless Podman in GitHub Actions.
chmod 0777 "${base_dir}"

require_command "${container_bin}"

if [[ -z "${dockerhub_username}" ]] && [[ -n "${DOCKERHUB_USERNAME_FILE:-}" ]]; then
  [[ -f "${DOCKERHUB_USERNAME_FILE}" ]] || {
    printf 'DOCKERHUB_USERNAME_FILE does not exist: %s\n' "${DOCKERHUB_USERNAME_FILE}" >&2
    exit 1
  }
  IFS= read -r dockerhub_username < "${DOCKERHUB_USERNAME_FILE}" || true
fi

if [[ -z "${dockerhub_token}" ]] && [[ -n "${DOCKERHUB_TOKEN_FILE:-}" ]]; then
  [[ -f "${DOCKERHUB_TOKEN_FILE}" ]] || {
    printf 'DOCKERHUB_TOKEN_FILE does not exist: %s\n' "${DOCKERHUB_TOKEN_FILE}" >&2
    exit 1
  }
  IFS= read -r dockerhub_token < "${DOCKERHUB_TOKEN_FILE}" || true
fi

if [[ -n "${dockerhub_username}" ]] && [[ -n "${dockerhub_token}" ]]; then
  printf -v renovate_host_rules '[{"matchHost":"dhi.io","username":"%s","password":"%s"}]' \
    "$(json_escape "${dockerhub_username}")" \
    "$(json_escape "${dockerhub_token}")"
  renovate_env+=(-e "RENOVATE_HOST_RULES=${renovate_host_rules}")
fi

"${container_bin}" run --rm \
  --user "${workspace_access_user}" \
  -v "${PWD}:/workspace:ro" \
  -w /workspace \
  --entrypoint renovate-config-validator \
  "${renovate_image}" \
  --strict --no-global /workspace/renovate.json5

renovate_status=0

set +e
"${container_bin}" run --rm \
  --user "${workspace_access_user}" \
  "${renovate_env[@]}" \
  -e LOG_LEVEL=debug \
  -e RENOVATE_CONFIG_FILE=/workspace/renovate.json5 \
  -e RENOVATE_BASE_DIR=/tmp/renovate-base \
  -v "${base_dir}:/tmp/renovate-base" \
  -v "${PWD}:/workspace:ro" \
  -w /workspace \
  --entrypoint renovate \
  "${renovate_image}" \
  --platform=local \
  --dry-run=full \
  --onboarding=false \
  --repository-cache=reset \
  >"${log_file}" 2>&1
renovate_status=$?
set -e

if [[ "${renovate_status}" -ne 0 ]]; then
  if grep -Fq 'Cannot sync git when platform=local' "${log_file}" \
    && ! grep -Eq 'Package lookup failures|Request failed with status code|Failed to look up docker package' "${log_file}"; then
    printf '%s\n' \
      'Renovate local dry-run hit the known platform=local git sync limitation; validating the captured dependency report instead.' \
      >&2
  else
    cat "${log_file}" >&2
    exit 1
  fi
fi

expected_dependencies=(
  "@github/copilot"
  "actions/download-artifact"
  "actions/checkout"
  "actions/upload-artifact"
  "azure/setup-kubectl"
  "busybox"
  "dhi.io/python"
  "docker.io/library/node"
  "engineerd/setup-kind"
  "ghcr.io/biomejs/biome"
  "ghcr.io/renovatebot/renovate"
  "hadolint/hadolint"
  "koalaman/shellcheck"
  "markdownlint-cli2"
  "mozilla/sccache"
  "yamllint"
)

for dependency in "${expected_dependencies[@]}"; do
  if ! grep -F "${dependency}" "${log_file}" >/dev/null; then
    printf 'Renovate local dry run did not report expected dependency: %s\n' "${dependency}" >&2
    cat "${log_file}" >&2
    exit 1
  fi
done
