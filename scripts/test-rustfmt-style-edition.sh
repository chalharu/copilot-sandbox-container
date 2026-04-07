#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-docker}"
control_plane_image="${CONTROL_PLANE_IMAGE_TAG:-localhost/control-plane:test}"

printf '%s\n' 'rustfmt-style-edition-test: verifying repository-root rustfmt picks up style_edition 2024' >&2
"${container_bin}" run --rm --user 0:0 \
  -v "${repo_root}:/workspace" \
  -w /workspace \
  "${control_plane_image}" \
  bash -lc 'rustfmt --check containers/control-plane/exec-policy-preload/src/shell.rs'

printf '%s\n' 'rustfmt-style-edition-test: verifying crate-local cargo fmt still passes' >&2
"${container_bin}" run --rm --user 0:0 \
  -v "${repo_root}:/workspace" \
  -w /workspace/containers/control-plane/exec-policy-preload \
  "${control_plane_image}" \
  bash -lc 'cargo fmt --all --check'
