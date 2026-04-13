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
  -e CARGO_TARGET_DIR=/var/tmp/control-plane/cargo-target \
  -v "${rust_cache_home_dir}:/control-plane-rust-home" \
  -v "${rust_cache_target_dir}:/var/tmp/control-plane/cargo-target" \
  -v "${PWD}:/workspace" \
  -w /workspace \
  "${rust_test_image}" \
  bash -lc "export PATH=/usr/local/cargo/bin:\$PATH \
    && rm -rf /tmp/control-plane-workspace \
    && mkdir -p /tmp/control-plane-workspace \
    && cp /workspace/containers/control-plane/Cargo.toml /tmp/control-plane-workspace/Cargo.toml \
    && cp /workspace/containers/control-plane/Cargo.lock /tmp/control-plane-workspace/Cargo.lock \
    && cp -R /workspace/containers/control-plane/exec-api /tmp/control-plane-workspace/exec-api \
    && cp -R /workspace/containers/control-plane/exec-policy-preload /tmp/control-plane-workspace/exec-policy-preload \
    && cp -R /workspace/containers/control-plane/runtime-tools /tmp/control-plane-workspace/runtime-tools \
    && cd /tmp/control-plane-workspace \
    && cargo chef prepare --recipe-path /var/tmp/control-plane/cargo-target/exec-api-recipe.json \
    && cargo chef cook --locked --recipe-path /var/tmp/control-plane/cargo-target/exec-api-recipe.json -p control-plane-exec-api \
    && cargo test --locked -p control-plane-exec-api"
