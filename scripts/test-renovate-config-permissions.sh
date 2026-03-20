#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-podman}"
workdir="$(mktemp -d)"
repo_copy="${workdir}/repo"

cleanup() {
  rm -rf "${workdir}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

require_command "${container_bin}"

printf '%s\n' 'renovate-config-permissions-test: verifying validation works from a restrictive workspace mount' >&2
mkdir -p "${repo_copy}"
cp -a "${repo_root}/." "${repo_copy}"
chmod 700 "${repo_copy}"

(
  cd "${repo_copy}"
  CONTROL_PLANE_CONTAINER_BIN="${container_bin}" ./scripts/validate-renovate-config.sh
)
