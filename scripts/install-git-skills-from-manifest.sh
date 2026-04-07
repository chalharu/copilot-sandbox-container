#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
control_plane_image="${CONTROL_PLANE_IMAGE_TAG:-localhost/control-plane:test}"
rust_build_image="${CONTROL_PLANE_RUST_BUILD_IMAGE_TAG:-${control_plane_image}}"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-docker}"
manifest_path="$(realpath "${1:?usage: scripts/install-git-skills-from-manifest.sh <manifest-path> <destination-root>}")"
destination_root="$(realpath -m "${2:?usage: scripts/install-git-skills-from-manifest.sh <manifest-path> <destination-root>}")"
runtime_tools_target_dir="$(mktemp -d)"
runtime_tools_home_dir="$(mktemp -d)"
runtime_tools_bin="${runtime_tools_target_dir}/release/control-plane-runtime-tool"

cleanup() {
  rm -rf "${runtime_tools_target_dir}"
  rm -rf "${runtime_tools_home_dir}"
}

trap cleanup EXIT

command -v "${container_bin}" >/dev/null 2>&1 || {
  printf 'Missing required command: %s\n' "${container_bin}" >&2
  exit 1
}

"${container_bin}" run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME=/runtime-tools-home \
  -e CARGO_HOME=/runtime-tools-home/.cargo \
  -e CARGO_TARGET_DIR=/runtime-tools-target \
  -v "${repo_root}:/workspace" \
  -v "${runtime_tools_home_dir}:/runtime-tools-home" \
  -v "${runtime_tools_target_dir}:/runtime-tools-target" \
  -w /workspace/containers/control-plane/runtime-tools \
  --entrypoint sh \
  "${rust_build_image}" \
  -c 'cargo build --release'

"${runtime_tools_bin}" install-git-skills-from-manifest "${manifest_path}" "${destination_root}"
