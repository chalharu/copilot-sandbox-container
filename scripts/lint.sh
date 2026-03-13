#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"

container_bin="$(detect_container_runtime)"
hadolint_image="${CONTROL_PLANE_HADOLINT_IMAGE:-hadolint/hadolint:latest-debian}"
shellcheck_image="${CONTROL_PLANE_SHELLCHECK_IMAGE:-koalaman/shellcheck:stable}"
dockerfiles=()
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

while IFS= read -r dockerfile; do
  dockerfiles+=("/workspace/${dockerfile}")
done < <(find containers -name Dockerfile -print | LC_ALL=C sort)

while IFS= read -r script_file; do
  shellcheck_targets+=("/workspace/${script_file}")
done < <(find scripts -name '*.sh' -print | LC_ALL=C sort)

if [[ "${#dockerfiles[@]}" -eq 0 ]]; then
  printf 'No Dockerfiles found under containers/\n' >&2
  exit 1
fi

printf 'Using %s for lint container execution\n' "${container_bin}"
"${container_bin}" run --rm -v "${PWD}:/workspace:ro" "${hadolint_image}" hadolint "${dockerfiles[@]}"
"${container_bin}" run --rm -v "${PWD}:/workspace:ro" "${shellcheck_image}" -x -P /workspace "${shellcheck_targets[@]}"
