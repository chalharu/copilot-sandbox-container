#!/usr/bin/env bash
set -euo pipefail

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

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "${repo_root}" ]] || die "run this script from inside the repository"

manifests=()
while IFS= read -r manifest; do
  manifests+=("${manifest}")
done < <(
  find "${repo_root}/containers/control-plane" -mindepth 2 -maxdepth 2 -name Cargo.toml -print \
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

for manifest in "${manifests[@]}"; do
  crate_dir="$(dirname "${manifest}")"
  printf 'control-plane-rust: %s\n' "${crate_dir#${repo_root}/}" >&2
  (
    cd "${crate_dir}"
    cargo "${cargo_args[@]}"
  )
done
