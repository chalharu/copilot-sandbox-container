#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  podman-yamllint.sh [path ...]

Run yamllint through this repository's pinned containers/yamllint image. When no
paths are given, the script lints every YAML file tracked under the repository.
USAGE
}

die() {
  printf 'podman-yamllint.sh: %s\n' "$*" >&2
  exit 64
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "${script_dir}" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "${repo_root}" ]] || die "run this script from inside the repository"

# shellcheck source=scripts/lib-container-toolchain.sh
source "${repo_root}/scripts/lib-container-toolchain.sh"

toolchain="$(detect_build_test_toolchain)"
container_bin="$(container_runtime_for_toolchain "${toolchain}")"
yamllint_image="${CONTROL_PLANE_YAMLLINT_IMAGE_TAG:-localhost/yamllint:test}"
yamllint_config="${CONTROL_PLANE_YAMLLINT_CONFIG:-/workspace/.yamllint}"
workspace_access_user="0:0"
targets=()

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

if [[ $# -eq 0 ]]; then
  while IFS= read -r yaml_file; do
    targets+=("/workspace/${yaml_file#./}")
  done < <(
    cd "${repo_root}"
    find . -type f \( -name '*.yml' -o -name '*.yaml' \) -print | LC_ALL=C sort
  )
else
  local_path=""
  for local_path in "$@"; do
    if [[ "${local_path}" == /* ]]; then
      [[ "${local_path}" == "${repo_root}"/* ]] || die "absolute path must stay under ${repo_root}: ${local_path}"
      targets+=("/workspace/${local_path#"${repo_root}/"}")
      continue
    fi

    targets+=("/workspace/${local_path#./}")
  done
fi

[[ "${#targets[@]}" -gt 0 ]] || die "no YAML files found"

build_image_for_toolchain "${toolchain}" "${yamllint_image}" "${repo_root}/containers/yamllint"

exec "${container_bin}" run --rm \
  --user "${workspace_access_user}" \
  -v "${repo_root}:/workspace:ro" \
  "${yamllint_image}" \
  -c "${yamllint_config}" \
  "${targets[@]}"
