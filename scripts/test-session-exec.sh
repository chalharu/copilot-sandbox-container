#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"

toolchain="$(detect_build_test_toolchain)"
container_bin="$(container_runtime_for_toolchain "${toolchain}")"
rust_test_image="${CONTROL_PLANE_RUST_TEST_IMAGE_TAG:-localhost/control-plane-rust-toolchain:test}"
rust_test_target="${CONTROL_PLANE_RUST_TEST_TARGET:-rust-toolchain}"
rust_cache_scope="${CONTROL_PLANE_RUST_CONTAINER_CACHE_SCOPE:-control-plane-rust-regressions}"
rust_cache_home_dir=''
rust_cache_target_dir=''
rust_cache_temp_root=''

cleanup() {
  [[ -z "${rust_cache_temp_root}" ]] || rm -rf "${rust_cache_temp_root}"
}
trap cleanup EXIT

require_command "${container_bin}"
prepare_rust_container_cache "${rust_cache_scope}" rust_cache_home_dir rust_cache_target_dir rust_cache_temp_root
build_image_target_for_toolchain "${toolchain}" "${rust_test_image}" containers/control-plane "${rust_test_target}"

# The control-plane image build still runs the runtime-tools unit tests, including
# session_exec_command coverage. Keep this dedicated script focused on the
# exec-api integration test surface that the image build does not exercise.
printf '%s\n' 'test-session-exec.sh: verifying exec-api integration coverage' >&2
"${container_bin}" run --rm --user "$(id -u):$(id -g)" \
  -e HOME=/control-plane-rust-home \
  -e CARGO_HOME=/control-plane-rust-home/.cargo \
  -e CARGO_TARGET_DIR=/control-plane-rust-target \
  -v "${rust_cache_home_dir}:/control-plane-rust-home" \
  -v "${rust_cache_target_dir}:/control-plane-rust-target" \
  -v "${PWD}:/workspace" \
  -w /workspace \
  "${rust_test_image}" \
  bash -lc "export PATH=/usr/local/cargo/bin:\$PATH && cargo test --manifest-path containers/control-plane/exec-api/Cargo.toml"
