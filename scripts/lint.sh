#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"

toolchain="$(detect_build_test_toolchain)"
container_bin="$(container_runtime_for_toolchain "${toolchain}")"
build_bin="$(build_command_for_toolchain "${toolchain}")"
hadolint_image="${CONTROL_PLANE_HADOLINT_IMAGE:-hadolint/hadolint:latest-debian}"
shellcheck_image="${CONTROL_PLANE_SHELLCHECK_IMAGE:-koalaman/shellcheck:stable}"
yamllint_image="${CONTROL_PLANE_YAMLLINT_IMAGE_TAG:-localhost/yamllint:test}"
yamllint_config="${CONTROL_PLANE_YAMLLINT_CONFIG:-/workspace/.yamllint}"
dockerfiles=()
yaml_files=()
shellcheck_targets=(
  /workspace/containers/control-plane/bin/control-plane-podman
  /workspace/containers/control-plane/bin/control-plane-screen
  /workspace/containers/control-plane/bin/control-plane-entrypoint
  /workspace/containers/control-plane/bin/control-plane-run
  /workspace/containers/control-plane/bin/control-plane-session
  /workspace/containers/control-plane/bin/k8s-job-start
  /workspace/containers/control-plane/bin/k8s-job-wait
  /workspace/containers/control-plane/bin/k8s-job-pod
  /workspace/containers/control-plane/bin/k8s-job-logs
  /workspace/containers/control-plane/bin/k8s-job-run
  /workspace/containers/control-plane/config/profile-control-plane-env.sh
  /workspace/containers/execution-plane-smoke/execution-plane-smoke
)

require_command "${container_bin}"
require_command "${build_bin}"

while IFS= read -r dockerfile; do
  dockerfiles+=("/workspace/${dockerfile}")
done < <(find containers -name Dockerfile -print | LC_ALL=C sort)

while IFS= read -r yaml_file; do
  yaml_files+=("/workspace/${yaml_file}")
done < <(find . -type f \( -name '*.yml' -o -name '*.yaml' \) -print | LC_ALL=C sort)

while IFS= read -r script_file; do
  shellcheck_targets+=("/workspace/${script_file}")
done < <(find scripts -name '*.sh' -print | LC_ALL=C sort)

if [[ "${#dockerfiles[@]}" -eq 0 ]]; then
  printf 'No Dockerfiles found under containers/\n' >&2
  exit 1
fi

if [[ "${#yaml_files[@]}" -eq 0 ]]; then
  printf 'No YAML files found in repository\n' >&2
  exit 1
fi

printf 'Using %s toolchain for lint\n' "${toolchain}"
build_image_for_toolchain "${toolchain}" "${yamllint_image}" containers/yamllint
"${container_bin}" run --rm -v "${PWD}:/workspace:ro" "${hadolint_image}" hadolint "${dockerfiles[@]}"
"${container_bin}" run --rm -v "${PWD}:/workspace:ro" "${shellcheck_image}" -x -P /workspace "${shellcheck_targets[@]}"
"${container_bin}" run --rm -v "${PWD}:/workspace:ro" "${yamllint_image}" -c "${yamllint_config}" "${yaml_files[@]}"
