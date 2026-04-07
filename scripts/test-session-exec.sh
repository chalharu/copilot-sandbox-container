#!/usr/bin/env bash
set -euo pipefail

command -v node >/dev/null 2>&1 || {
  printf 'test-session-exec.sh: node is required\n' >&2
  exit 1
}

container_bin="${CONTROL_PLANE_CONTAINER_BIN:-docker}"
control_plane_image="${CONTROL_PLANE_IMAGE_TAG:-localhost/control-plane:test}"
rust_test_image="${CONTROL_PLANE_RUST_TEST_IMAGE_TAG:-${control_plane_image}}"

command -v "${container_bin}" >/dev/null 2>&1 || {
  printf 'test-session-exec.sh: %s is required\n' "${container_bin}" >&2
  exit 1
}

"${container_bin}" run --rm --user 0:0 \
  -v "${PWD}:/workspace" \
  -w /workspace \
  "${rust_test_image}" \
  bash -lc "export PATH=/usr/local/cargo/bin:\$PATH CARGO_TARGET_DIR=/tmp/control-plane-rust-target/exec-api-test && cargo test --manifest-path containers/control-plane/exec-api/Cargo.toml"

node --test containers/control-plane/bin/control-plane-session-exec.test.mjs
