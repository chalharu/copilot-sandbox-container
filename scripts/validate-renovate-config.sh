#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"

container_bin="$(detect_container_runtime)"
# renovate: datasource=docker depName=ghcr.io/renovatebot/renovate versioning=docker
renovate_image="${CONTROL_PLANE_RENOVATE_IMAGE:-ghcr.io/renovatebot/renovate:43.59.3}"
base_dir="$(mktemp -d)"
log_file="$(mktemp)"

cleanup() {
  rm -rf "${base_dir}"
  rm -f "${log_file}"
}
trap cleanup EXIT

require_command "${container_bin}"

"${container_bin}" run --rm \
  -v "${PWD}:/workspace:ro" \
  -w /workspace \
  --entrypoint renovate-config-validator \
  "${renovate_image}" \
  --strict --no-global /workspace/renovate.json5

"${container_bin}" run --rm \
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
