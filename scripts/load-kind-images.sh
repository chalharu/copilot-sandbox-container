#!/usr/bin/env bash
set -euo pipefail

cluster_name=""
image_archive=""
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-docker}"
kind_provider="${KIND_EXPERIMENTAL_PROVIDER:-docker}"
kind_use_sudo="${CONTROL_PLANE_KIND_USE_SUDO:-0}"
workdir=""
declare -a images=()

usage() {
  cat >&2 <<'EOF'
Usage: scripts/load-kind-images.sh --cluster-name <name> [--image-archive <path> | --container-bin <bin> --image <ref> [--image <ref>...]]
EOF
}

cleanup() {
  if [[ -n "${workdir}" ]]; then
    rm -rf "${workdir}"
  fi
}

trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

kind_cmd() {
  if [[ "${kind_use_sudo}" -eq 1 ]]; then
    sudo -n env KIND_EXPERIMENTAL_PROVIDER="${kind_provider}" kind "$@"
  else
    kind "$@"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-name)
      [[ $# -ge 2 ]] || {
        usage
        exit 1
      }
      cluster_name="$2"
      shift 2
      ;;
    --image-archive)
      [[ $# -ge 2 ]] || {
        usage
        exit 1
      }
      image_archive="$2"
      shift 2
      ;;
    --container-bin)
      [[ $# -ge 2 ]] || {
        usage
        exit 1
      }
      container_bin="$2"
      shift 2
      ;;
    --image)
      [[ $# -ge 2 ]] || {
        usage
        exit 1
      }
      images+=("$2")
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

[[ -n "${cluster_name}" ]] || {
  usage
  exit 1
}

if [[ -n "${image_archive}" ]] && [[ "${#images[@]}" -gt 0 ]]; then
  printf 'Cannot combine --image-archive with --image\n' >&2
  exit 1
fi

if [[ -z "${image_archive}" ]] && [[ "${#images[@]}" -eq 0 ]]; then
  printf 'Provide --image-archive or at least one --image\n' >&2
  usage
  exit 1
fi

require_command kind
if [[ "${kind_use_sudo}" -eq 1 ]]; then
  require_command sudo
fi

if [[ -n "${image_archive}" ]]; then
  [[ -f "${image_archive}" ]] || {
    printf 'Missing Kind image archive: %s\n' "${image_archive}" >&2
    exit 1
  }
  kind_cmd load image-archive "${image_archive}" --name "${cluster_name}"
  exit 0
fi

require_command "${container_bin}"
workdir="$(mktemp -d)"

for image in "${images[@]}"; do
  archive_basename="$(printf '%s' "${image}" | tr '/:' '__')"
  archive_path="${workdir}/${archive_basename}.tar"
  "${container_bin}" save --output "${archive_path}" "${image}" >/dev/null
  kind_cmd load image-archive "${archive_path}" --name "${cluster_name}"
done
