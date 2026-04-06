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
  control-plane-rust.sh <fmt|fmt-check|check|clippy-fix|clippy|build|test>

Run the requested cargo command across every Rust crate shipped under
containers/control-plane/.
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
[[ -d "${control_plane_tree}" ]] || die "run this hook from the repository root"

manifests=()
while IFS= read -r manifest; do
  manifests+=("${manifest}")
done < <(
  find "${control_plane_tree}" -mindepth 2 -maxdepth 2 -name Cargo.toml -print \
    | LC_ALL=C sort
)

[[ "${#manifests[@]}" -gt 0 ]] || die "no Cargo.toml files found under containers/control-plane"
[[ $# -eq 1 ]] || {
  usage
  exit 64
}

case "$1" in
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
    die "unknown preset: $1"
    ;;
esac

remote_image="${CONTROL_PLANE_RUST_HOOK_IMAGE:-${CONTROL_PLANE_JOB_TRANSFER_IMAGE:-}}"
use_remote=0
if [[ -n "${remote_image}" ]] && command -v control-plane-run >/dev/null 2>&1; then
  use_remote=1
fi

run_local_cargo() {
  local crate_dir="$1"

  require_command cargo
  (
    cd "${crate_dir}"
    cargo "${cargo_args[@]}"
  )
}

run_remote_cargo() {
  local crate_dir="$1"
  local crate_relative="${crate_dir#"${repo_root}/"}"
  local remote_dir="/workspace/${crate_relative}"
  local remote_command

  printf -v remote_command 'cd %q && cargo' "${remote_dir}"
  for cargo_arg in "${cargo_args[@]}"; do
    printf -v remote_command '%s %q' "${remote_command}" "${cargo_arg}"
  done

  control-plane-run \
    --image "${remote_image}" \
    -- bash -lc "${remote_command}"
}

for manifest in "${manifests[@]}"; do
  crate_dir="$(dirname "${manifest}")"
  printf 'control-plane-rust: %s\n' "${crate_dir#"${repo_root}/"}" >&2
  if [[ "${use_remote}" -eq 1 ]]; then
    run_remote_cargo "${crate_dir}"
  else
    run_local_cargo "${crate_dir}"
  fi
done
