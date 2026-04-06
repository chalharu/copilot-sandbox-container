#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  podman-yamllint.sh [path ...]

Run yamllint directly from the bundled control-plane toolchain. When no paths are
given, the script lints every YAML file tracked under the repository.
USAGE
}

die() {
  printf 'podman-yamllint.sh: %s\n' "$*" >&2
  exit 64
}

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "${repo_root}" ]] || die "run this script from inside the repository"

yamllint_config="${CONTROL_PLANE_YAMLLINT_CONFIG:-${repo_root}/.yamllint}"
targets=()

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

if [[ $# -eq 0 ]]; then
  while IFS= read -r yaml_file; do
    targets+=("${repo_root}/${yaml_file#./}")
  done < <(
    cd "${repo_root}"
    find . -type f \( -name '*.yml' -o -name '*.yaml' \) -print | LC_ALL=C sort
  )
else
  local_path=""
  for local_path in "$@"; do
    if [[ "${local_path}" == /* ]]; then
      [[ "${local_path}" == "${repo_root}"/* ]] || die "absolute path must stay under ${repo_root}: ${local_path}"
      targets+=("${local_path}")
      continue
    fi

    targets+=("${repo_root}/${local_path#./}")
  done
fi

[[ "${#targets[@]}" -gt 0 ]] || die "no YAML files found"

exec yamllint -c "${yamllint_config}" "${targets[@]}"
