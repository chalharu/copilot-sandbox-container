#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  podman-rust.sh <fmt|fmt-check|check|clippy-fix|clippy|build|test>
  podman-rust.sh -- <command> [args...]

Run Rust commands inside docker.io/rust:1.94.0-bookworm with disk-backed
TMPDIR state, a dedicated sccache cache, an ephemeral target directory, and a
cached sccache helper image bundled with this skill.
USAGE
}

die() {
  printf 'podman-rust.sh: %s\n' "$*" >&2
  exit 64
}

slugify() {
  printf '%s' "$1" | tr '/:@' '---' | tr -cs '[:alnum:]._-' '-'
}

build_context_hash() {
  local context_dir="$1"

  tar \
    --sort=name \
    --mtime='UTC 1970-01-01' \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    -cf - \
    -C "${context_dir}" \
    . \
    | sha256sum \
    | awk '{print $1}'
}

[[ $# -gt 0 ]] || {
  usage
  exit 64
}

image="${RUST_CONTAINER_IMAGE:-docker.io/rust:1.94.0-bookworm}"
podman_cmd=(env -u CONTAINER_HOST -u DOCKER_HOST podman)
case "$1" in
  fmt)
    shift
    [[ $# -eq 0 ]] || die "fmt does not accept extra arguments"
    cmd=(cargo fmt --all)
    ;;
  fmt-check)
    shift
    [[ $# -eq 0 ]] || die "fmt-check does not accept extra arguments"
    cmd=(cargo fmt --all --check)
    ;;
  check)
    shift
    [[ $# -eq 0 ]] || die "check does not accept extra arguments"
    cmd=(cargo check --workspace --all-targets)
    ;;
  clippy-fix)
    shift
    [[ $# -eq 0 ]] || die "clippy-fix does not accept extra arguments"
    cmd=(cargo clippy --fix --allow-dirty --allow-staged --workspace --all-targets)
    ;;
  clippy)
    shift
    [[ $# -eq 0 ]] || die "clippy does not accept extra arguments"
    cmd=(cargo clippy --workspace --all-targets -- -D warnings)
    ;;
  build)
    shift
    [[ $# -eq 0 ]] || die "build does not accept extra arguments"
    cmd=(cargo build --workspace)
    ;;
  test)
    shift
    [[ $# -eq 0 ]] || die "test does not accept extra arguments"
    cmd=(cargo test --workspace --all-targets)
    ;;
  --)
    shift
    [[ $# -gt 0 ]] || die "-- must be followed by a command"
    cmd=("$@")
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    die "unknown preset: $1"
    ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_root="$(cd "${script_dir}/.." && pwd)"
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "${repo_root}" ]] || die "run this script from inside a Git repository"
repo_key="$(slugify "$(basename "${repo_root}")")"
repo_key="${repo_key#-}"
repo_key="${repo_key%-}"
[[ -n "${repo_key}" ]] || repo_key=workspace

control_plane_tmp_root="${CONTROL_PLANE_TMP_ROOT:-/var/tmp/control-plane}"
base_tmp_root="${CONTAINERIZED_RUST_TMP_ROOT:-${TMPDIR:-${control_plane_tmp_root}/tmp-$(id -u)}}"
state_root="${CONTAINERIZED_RUST_STATE_ROOT:-${base_tmp_root%/}/containerized-rust/${repo_key}}"
toolchain_root="${CONTAINERIZED_RUST_TOOLCHAIN_ROOT:-${state_root}/toolchain}"
rustup_cache="${CONTAINERIZED_RUST_RUSTUP_DIR:-${toolchain_root}/rustup}"
cargo_cache="${CONTAINERIZED_RUST_CARGO_DIR:-${toolchain_root}/cargo}"
target_cache="${CONTAINERIZED_RUST_TARGET_DIR:-${state_root}/target}"
tool_tmp_dir="${CONTAINERIZED_RUST_WORK_TMPDIR:-${state_root}/tmp}"
sccache_cache="${CONTAINERIZED_RUST_SCCACHE_DIR:-${control_plane_tmp_root}/sccache/${repo_key}}"
sccache_image="${CONTAINERIZED_SCCACHE_IMAGE:-localhost/sccache:test}"
sccache_image_context="${CONTAINERIZED_SCCACHE_IMAGE_CONTEXT:-${skill_root}/assets/sccache-image}"
sccache_image_label='io.github.chalharu.containerized-rust.sccache-context-sha256'

mkdir -p "${base_tmp_root}" "${tool_tmp_dir}" "${rustup_cache}" "${cargo_cache}" "${target_cache}" "${sccache_cache}"
chmod 700 "${tool_tmp_dir}" 2>/dev/null || true
export TMPDIR="${tool_tmp_dir}"

sccache_version="${SCCACHE_VERSION:-0.14.0}"
cargo_llvm_cov_version="${CARGO_LLVM_COV_VERSION:-0.8.5}"
cargo_llvm_cov_release_base_url="${CARGO_LLVM_COV_RELEASE_BASE_URL:-https://github.com/taiki-e/cargo-llvm-cov/releases}"
enable_cargo_llvm_cov=0
if [[ "${#cmd[@]}" -ge 2 && "${cmd[0]}" == "cargo" && "${cmd[1]}" == "llvm-cov" ]]; then
  enable_cargo_llvm_cov=1
fi

bootstrap_toolchain() {
  if [[ -x "${cargo_cache}/bin/cargo" ]]; then
    return
  fi

  "${podman_cmd[@]}" run --rm -i \
    -v "${rustup_cache}:/host-rustup" \
    -v "${cargo_cache}:/host-cargo" \
    "${image}" \
    sh -c 'cp -R /usr/local/rustup/. /host-rustup/ && cp -R /usr/local/cargo/. /host-cargo/'
}

ensure_sccache_image() {
  local context_hash
  local existing_hash

  [[ -d "${sccache_image_context}" ]] || die "missing sccache image context: ${sccache_image_context}"
  context_hash="$(build_context_hash "${sccache_image_context}")"
  existing_hash="$("${podman_cmd[@]}" image inspect --format "{{ index .Config.Labels \"${sccache_image_label}\" }}" "${sccache_image}" 2>/dev/null || true)"
  if [[ -n "${existing_hash}" ]] && [[ "${existing_hash}" == "${context_hash}" ]]; then
    return
  fi

  "${podman_cmd[@]}" build \
    --label "${sccache_image_label}=${context_hash}" \
    --build-arg "SCCACHE_VERSION=${sccache_version}" \
    --tag "${sccache_image}" \
    "${sccache_image_context}"
}

install_sccache_from_image() {
  if [[ -x "${cargo_cache}/bin/sccache" ]]; then
    return
  fi

  ensure_sccache_image
  mkdir -p "${cargo_cache}/bin"
  "${podman_cmd[@]}" run --rm --entrypoint cat "${sccache_image}" /usr/local/bin/sccache > "${cargo_cache}/bin/sccache"
  chmod 0755 "${cargo_cache}/bin/sccache"
}

ensure_tools() {
  "${podman_cmd[@]}" run --rm -i \
    -e CARGO_LLVM_COV_VERSION="${cargo_llvm_cov_version}" \
    -e CARGO_LLVM_COV_RELEASE_BASE_URL="${cargo_llvm_cov_release_base_url}" \
    -e ENABLE_CARGO_LLVM_COV="${enable_cargo_llvm_cov}" \
    -v "${rustup_cache}:/usr/local/rustup" \
    -v "${cargo_cache}:/usr/local/cargo" \
    -v "${tool_tmp_dir}:/var/tmp/containerized-rust" \
    -v "${script_dir}:/skill-scripts:ro" \
    "${image}" \
    sh -c '
      set -eu
      export CARGO_HOME=/usr/local/cargo
      export RUSTUP_HOME=/usr/local/rustup
      export PATH=/usr/local/cargo/bin:$PATH
      export TMPDIR=/var/tmp/containerized-rust
      mkdir -p "${TMPDIR}"
      rustfmt --version >/dev/null 2>&1 || rustup component add rustfmt >"${TMPDIR}/rustfmt.log" 2>&1
      rustfmt --version >/dev/null 2>&1 || { cat "${TMPDIR}/rustfmt.log" >&2; exit 1; }
      cargo clippy --version >/dev/null 2>&1 || rustup component add clippy >"${TMPDIR}/clippy.log" 2>&1
      cargo clippy --version >/dev/null 2>&1 || { cat "${TMPDIR}/clippy.log" >&2; exit 1; }
      if [ "${ENABLE_CARGO_LLVM_COV:-0}" = "1" ]; then
        sh /skill-scripts/install-cargo-llvm-cov.sh
        rustup component list --installed | grep -Eq "^llvm-tools" || rustup component add llvm-tools-preview >"${TMPDIR}/llvm-tools.log" 2>&1
        rustup component list --installed | grep -Eq "^llvm-tools" || { cat "${TMPDIR}/llvm-tools.log" >&2; exit 1; }
      fi
    '
}

bootstrap_toolchain
install_sccache_from_image
ensure_tools

"${podman_cmd[@]}" run --rm -i \
  -e CARGO_TERM_PROGRESS_WHEN=never \
  -v "${repo_root}:/workspace" \
  -w /workspace \
  -v "${rustup_cache}:/usr/local/rustup" \
  -v "${cargo_cache}:/usr/local/cargo" \
  -v "${target_cache}:/workspace/target" \
  -v "${sccache_cache}:/var/cache/sccache" \
  -v "${tool_tmp_dir}:/var/tmp/containerized-rust" \
  "${image}" \
  sh -c '
    set -eu
    export CARGO_HOME=/usr/local/cargo
    export RUSTUP_HOME=/usr/local/rustup
    export PATH=/usr/local/cargo/bin:$PATH
    export CARGO_TARGET_DIR=/workspace/target
    export SCCACHE_DIR=/var/cache/sccache
    export SCCACHE_CACHE_SIZE="${SCCACHE_CACHE_SIZE:-10G}"
    export RUSTC_WRAPPER=/usr/local/cargo/bin/sccache
    export CARGO_INCREMENTAL=0
    export TMPDIR=/var/tmp/containerized-rust
    mkdir -p "${TMPDIR}" "${SCCACHE_DIR}" "${CARGO_TARGET_DIR}"
    if "$@"; then
      status=0
    else
      status=$?
    fi
    sccache --show-stats || true
    exit "${status}"
  ' sh "${cmd[@]}"
