#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-docker}"
rust_lint_script="${repo_root}/containers/control-plane/skills/containerized-rust-ops/scripts/podman-rust.sh"

printf '%s\n' 'rustfmt-style-edition-test: verifying repository-root rustfmt picks up style_edition 2024' >&2
(
  cd "${repo_root}"
  CONTAINERIZED_RUST_CONTAINER_BIN="${container_bin}" \
    bash "${rust_lint_script}" -- rustfmt --check containers/control-plane/exec-policy-preload/src/shell.rs
)

printf '%s\n' 'rustfmt-style-edition-test: verifying crate-local cargo fmt still passes' >&2
(
  cd "${repo_root}/containers/control-plane/exec-policy-preload"
  CONTAINERIZED_RUST_CONTAINER_BIN="${container_bin}" \
    bash "../skills/containerized-rust-ops/scripts/podman-rust.sh" fmt-check
)
