#!/usr/bin/env bash
set -euo pipefail

control_plane_image="${CONTROL_PLANE_IMAGE_TAG:-localhost/control-plane:test}"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-docker}"
manifest_path="$(realpath "${1:?usage: scripts/install-git-skills-from-manifest.sh <manifest-path> <destination-root>}")"
destination_root="$(realpath -m "${2:?usage: scripts/install-git-skills-from-manifest.sh <manifest-path> <destination-root>}")"
manifest_dir="$(dirname "${manifest_path}")"
manifest_name="$(basename "${manifest_path}")"
destination_parent="$(dirname "${destination_root}")"
destination_name="$(basename "${destination_root}")"

command -v "${container_bin}" >/dev/null 2>&1 || {
  printf 'Missing required command: %s\n' "${container_bin}" >&2
  exit 1
}

mkdir -p "${destination_root}"

"${container_bin}" run --rm \
  --user "$(id -u):$(id -g)" \
  -v "${manifest_dir}:/control-plane-manifest:ro" \
  -v "${destination_parent}:/control-plane-destination" \
  --entrypoint /usr/local/bin/control-plane-runtime-tool \
  "${control_plane_image}" \
  install-git-skills-from-manifest \
  "/control-plane-manifest/${manifest_name}" \
  "/control-plane-destination/${destination_name}"
