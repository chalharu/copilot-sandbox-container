#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"

container_bin=""
# renovate: datasource=docker depName=ghcr.io/renovatebot/renovate versioning=docker
renovate_image="${CONTROL_PLANE_RENOVATE_IMAGE:-ghcr.io/renovatebot/renovate:43.59.3}"
base_dir=""
log_file=""

cleanup() {
  local cleanup_container_bin="${container_bin:-}"
  local cleanup_renovate_image="${renovate_image:-}"
  local cleanup_base_dir="${base_dir:-}"
  local cleanup_log_file="${log_file:-}"

  if [[ -n "${cleanup_container_bin}" ]] && command -v "${cleanup_container_bin}" >/dev/null 2>&1 && [[ -d "${cleanup_base_dir}" ]]; then
    "${cleanup_container_bin}" run --rm \
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

"${container_bin}" run --rm \
  -v "${PWD}:/workspace:ro" \
  -w /workspace \
  --entrypoint renovate-config-validator \
  "${renovate_image}" \
  --strict --no-global /workspace/renovate.json5

if ! "${container_bin}" run --rm \
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
  >"${log_file}" 2>&1; then
  cat "${log_file}" >&2
  exit 1
fi

expected_dependencies=(
  "actions/cache"
  "actions/checkout"
  "azure/setup-kubectl"
  "dhi.io/python"
  "engineerd/setup-kind"
  "ghcr.io/biomejs/biome"
  "ghcr.io/renovatebot/renovate"
  "hadolint/hadolint"
  "koalaman/shellcheck"
  "yamllint"
)

for dependency in "${expected_dependencies[@]}"; do
  if ! grep -F "${dependency}" "${log_file}" >/dev/null; then
    printf 'Renovate local dry run did not report expected dependency: %s\n' "${dependency}" >&2
    cat "${log_file}" >&2
    exit 1
  fi
done
