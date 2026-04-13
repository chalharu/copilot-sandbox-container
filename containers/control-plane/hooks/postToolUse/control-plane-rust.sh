#!/usr/bin/env bash
set -euo pipefail

runtime_config_file="${CONTROL_PLANE_RUNTIME_ENV_FILE:-${HOME:-/home/${USER:-copilot}}/.config/control-plane/runtime.env}"
if [[ -f "${runtime_config_file}" ]]; then
  # shellcheck disable=SC1090
  source "${runtime_config_file}"
fi

usage() {
  cat <<'USAGE'
Usage:
  control-plane-rust.sh <fmt|fmt-check|check|clippy-fix|clippy|build|test> [PATH ...]

Run the requested cargo command across the affected Rust crates shipped under
containers/control-plane/. When no paths are provided, every shipped crate runs.
USAGE
}

die() {
  printf 'control-plane-rust.sh: %s\n' "$*" >&2
  exit 64
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

find_repo_root() {
  if command -v git >/dev/null 2>&1; then
    git rev-parse --show-toplevel 2>/dev/null && return 0
  fi

  pwd
}

repo_root="$(find_repo_root)"
control_plane_tree="${repo_root}/containers/control-plane"
workspace_manifest="${control_plane_tree}/Cargo.toml"
[[ -d "${control_plane_tree}" ]] || die "run this hook from the repository root"

load_all_manifests() {
  local manifest

  manifests=()
  if [[ -f "${workspace_manifest}" ]]; then
    manifests=("${workspace_manifest}")
    return 0
  fi
  while IFS= read -r manifest; do
    manifests+=("${manifest}")
  done < <(
    find "${control_plane_tree}" -mindepth 2 -maxdepth 2 -name Cargo.toml -print \
      | LC_ALL=C sort
  )
  [[ "${#manifests[@]}" -gt 0 ]] || die "no Cargo.toml files found under containers/control-plane"
}

normalize_candidate_path() {
  local candidate="$1"

  if [[ "${candidate}" = /* ]]; then
    printf '%s\n' "${candidate}"
  else
    printf '%s\n' "${repo_root}/${candidate}"
  fi
}

manifest_for_path() {
  local candidate="$1"
  local path
  local search_dir
  local parent

  path="$(normalize_candidate_path "${candidate}")"
  [[ "${path}" == "${control_plane_tree}" || "${path}" == "${control_plane_tree}/"* ]] || return 1
  if [[ "${path}" == "${workspace_manifest}" ]]; then
    printf '%s\n' "${workspace_manifest}"
    return 0
  fi
  if [[ -d "${path}" ]]; then
    search_dir="${path}"
  else
    search_dir="$(dirname "${path}")"
  fi

  while :; do
    if [[ -f "${search_dir}/Cargo.toml" ]]; then
      printf '%s\n' "${search_dir}/Cargo.toml"
      return 0
    fi
    [[ "${search_dir}" == "${control_plane_tree}" ]] && return 1
    parent="$(dirname "${search_dir}")"
    [[ "${parent}" != "${search_dir}" ]] || return 1
    search_dir="${parent}"
  done
}

collect_target_manifests() {
  local changed_path
  local manifest

  load_all_manifests
  if [[ "$#" -eq 0 ]]; then
    printf '%s\n' "${manifests[@]}"
    return 0
  fi

  declare -A seen=()
  for changed_path in "$@"; do
    manifest="$(manifest_for_path "${changed_path}" || true)"
    if [[ -n "${manifest}" ]] && [[ -z "${seen["${manifest}"]+x}" ]]; then
      seen["${manifest}"]=1
      printf '%s\n' "${manifest}"
    fi
  done
}

cargo_target_dir() {
  printf '%s\n' "${CONTROL_PLANE_RUST_TARGET_DIR:-${CARGO_TARGET_DIR:-${CONTROL_PLANE_TMP_ROOT:-/var/tmp/control-plane}/cargo-target}}"
}

resolved_cargo_args() {
  local manifest="$1"

  command_args=("${cargo_args[@]}")
  [[ "${manifest}" == "${workspace_manifest}" ]] || return 0

  case "${preset}" in
    fmt|fmt-check)
      ;;
    check)
      command_args=(check --workspace --all-targets)
      ;;
    clippy-fix)
      command_args=(clippy --workspace --fix --allow-dirty --allow-staged --all-targets)
      ;;
    clippy)
      command_args=(clippy --workspace --all-targets -- -D warnings)
      ;;
    build)
      command_args=(build --workspace)
      ;;
    test)
      command_args=(test --workspace --all-targets)
      ;;
  esac
}

[[ $# -ge 1 ]] || {
  usage
  exit 64
}

preset="$1"
shift

case "${preset}" in
  fmt)
    cargo_args=(fmt --all)
    ;;
  fmt-check)
    cargo_args=(fmt --all --check)
    ;;
  check)
    cargo_args=(check --all-targets)
    ;;
  clippy-fix)
    cargo_args=(clippy --fix --allow-dirty --allow-staged --all-targets)
    ;;
  clippy)
    cargo_args=(clippy --all-targets -- -D warnings)
    ;;
  build)
    cargo_args=(build)
    ;;
  test)
    cargo_args=(test --all-targets)
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    die "unknown preset: ${preset}"
    ;;
esac

remote_image="${CONTROL_PLANE_RUST_HOOK_IMAGE:-${CONTROL_PLANE_JOB_TRANSFER_IMAGE:-}}"
use_remote=0
if [[ -n "${remote_image}" ]] && command -v control-plane-run >/dev/null 2>&1; then
  use_remote=1
fi

preset_requires_toolchain=0
case "${preset}" in
  fmt|fmt-check)
    ;;
  *)
    preset_requires_toolchain=1
    ;;
esac

run_local_cargo() {
  local manifest="$1"
  local crate_dir
  local target_dir

  crate_dir="$(dirname "${manifest}")"
  require_command cargo
  resolved_cargo_args "${manifest}"
  target_dir="$(cargo_target_dir)"
  (
    cd "${crate_dir}"
    CARGO_TARGET_DIR="${target_dir}" cargo "${command_args[@]}"
  )
}

run_remote_cargo() {
  local manifest="$1"
  local crate_dir
  local crate_relative
  local remote_dir
  local remote_command
  local target_dir

  crate_dir="$(dirname "${manifest}")"
  crate_relative="${crate_dir#"${repo_root}/"}"
  remote_dir="/workspace/${crate_relative}"
  resolved_cargo_args "${manifest}"
  target_dir="$(cargo_target_dir)"

  printf -v remote_command 'export CARGO_TARGET_DIR=%q && cd %q && cargo' "${target_dir}" "${remote_dir}"
  for cargo_arg in "${command_args[@]}"; do
    printf -v remote_command '%s %q' "${remote_command}" "${cargo_arg}"
  done

  control-plane-run \
    --image "${remote_image}" \
     -- bash -lc "${remote_command}"
}

require_local_build_toolchain() {
  [[ "${preset_requires_toolchain}" -eq 1 ]] || return 0
  command -v cc >/dev/null 2>&1 && command -v pkg-config >/dev/null 2>&1 && return 0
  die "local ${preset} needs cc and pkg-config; set CONTROL_PLANE_RUST_HOOK_IMAGE to run heavy cargo work in a separate image"
}

mapfile -t manifests < <(collect_target_manifests "$@")
if [[ "${#manifests[@]}" -eq 0 ]]; then
  printf '%s\n' 'control-plane-rust: no affected control-plane Rust crates' >&2
  exit 0
fi

for manifest in "${manifests[@]}"; do
  crate_dir="$(dirname "${manifest}")"
  printf 'control-plane-rust: %s\n' "${crate_dir#"${repo_root}/"}" >&2
  if [[ "${use_remote}" -eq 1 ]]; then
    run_remote_cargo "${crate_dir}"
  else
    require_local_build_toolchain
    run_local_cargo "${crate_dir}"
  fi
done
