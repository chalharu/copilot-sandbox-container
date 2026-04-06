#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
control_plane_image="${CONTROL_PLANE_IMAGE_TAG:-localhost/control-plane:test}"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-docker}"
manifest_path="$(realpath "${1:?usage: scripts/install-git-skills-from-manifest.sh <manifest-path> <destination-root>}")"
destination_root="$(realpath -m "${2:?usage: scripts/install-git-skills-from-manifest.sh <manifest-path> <destination-root>}")"
runtime_tools_target_dir="${repo_root}/target/runtime-tools-host"
runtime_tools_bin="${runtime_tools_target_dir}/release/control-plane-runtime-tool"

command -v "${container_bin}" >/dev/null 2>&1 || {
  printf 'Missing required command: %s\n' "${container_bin}" >&2
  exit 1
}

mkdir -p "${runtime_tools_target_dir}"

"${container_bin}" run --rm \
  --user "$(id -u):$(id -g)" \
  -e CARGO_TARGET_DIR=/workspace/target/runtime-tools-host \
  -v "${repo_root}:/workspace" \
  -w /workspace/containers/control-plane/runtime-tools \
  --entrypoint sh \
  "${control_plane_image}" \
  -c 'cargo build --release'

exec "${runtime_tools_bin}" install-git-skills-from-manifest "${manifest_path}" "${destination_root}"
