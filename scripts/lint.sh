#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"

toolchain="$(detect_build_test_toolchain)"
container_bin="$(container_runtime_for_toolchain "${toolchain}")"
build_bin="$(build_command_for_toolchain "${toolchain}")"
# renovate: datasource=docker depName=docker.io/hadolint/hadolint versioning=docker
hadolint_image="${CONTROL_PLANE_HADOLINT_IMAGE:-docker.io/hadolint/hadolint:v2.14.0-debian@sha256:158cd0184dcaa18bd8ec20b61f4c1cabdf8b32a592d062f57bdcb8e4c1d312e2}"
# renovate: datasource=docker depName=docker.io/koalaman/shellcheck versioning=docker
shellcheck_image="${CONTROL_PLANE_SHELLCHECK_IMAGE:-docker.io/koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d}"
# renovate: datasource=docker depName=ghcr.io/biomejs/biome versioning=docker
biome_image="${CONTROL_PLANE_BIOME_IMAGE:-ghcr.io/biomejs/biome:2.4.8@sha256:b387446dd5528d2c2b5554678b49c29016a925dd4e94f383b07be4ace81e3c46}"
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
# Biome ignores .json5 when traversing repository paths, so validate renovate.json5
# through stdin and discard the normalized output once parsing succeeds.
"${container_bin}" run --rm -i --entrypoint biome "${biome_image}" check --formatter-enabled=false --write --stdin-file-path=renovate.json5 < renovate.json5 >/dev/null
CONTROL_PLANE_CONTAINER_BIN="${container_bin}" "${script_dir}/validate-renovate-config.sh"
if [[ "${toolchain}" == "podman" ]]; then
  "${script_dir}/prepare-dhi-images.sh"
fi
build_image_for_toolchain "${toolchain}" "${yamllint_image}" containers/yamllint
"${container_bin}" run --rm -v "${PWD}:/workspace:ro" "${hadolint_image}" hadolint "${dockerfiles[@]}"
"${container_bin}" run --rm -v "${PWD}:/workspace:ro" "${shellcheck_image}" -x -P /workspace "${shellcheck_targets[@]}"
"${container_bin}" run --rm -v "${PWD}:/workspace:ro" "${yamllint_image}" -c "${yamllint_config}" "${yaml_files[@]}"
