#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"

toolchain="$(detect_build_test_toolchain)"
container_bin="$(container_runtime_for_toolchain "${toolchain}")"
rust_test_image="${CONTROL_PLANE_RUST_TEST_IMAGE_TAG:-localhost/control-plane-rust-toolchain:test}"
rust_test_target="${CONTROL_PLANE_RUST_TEST_TARGET:-rust-toolchain}"

require_command "${container_bin}"
build_image_target_for_toolchain "${toolchain}" "${rust_test_image}" containers/control-plane "${rust_test_target}"

# The control-plane image build still runs the runtime-tools unit tests, including
# session_exec_command coverage. Keep this dedicated script focused on the
# exec-api integration test surface that the image build does not exercise.
printf '%s\n' 'test-session-exec.sh: verifying exec-api integration coverage' >&2
"${container_bin}" run --rm --user 0:0 \
  -v "${PWD}:/workspace" \
  -w /workspace \
  "${rust_test_image}" \
  bash -lc "export PATH=/usr/local/cargo/bin:\$PATH CARGO_TARGET_DIR=/tmp/control-plane-rust-target/exec-api-test && cargo test --manifest-path containers/control-plane/exec-api/Cargo.toml"
