#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"

container_bin="$(detect_container_runtime)"
hadolint_image="${CONTROL_PLANE_HADOLINT_IMAGE:-hadolint/hadolint:latest-debian}"
dockerfiles=()

require_command "${container_bin}"
require_command shellcheck

while IFS= read -r dockerfile; do
  dockerfiles+=("/workspace/${dockerfile}")
done < <(find containers -name Dockerfile -print | LC_ALL=C sort)

if [[ "${#dockerfiles[@]}" -eq 0 ]]; then
  printf 'No Dockerfiles found under containers/\n' >&2
  exit 1
fi

printf 'Using %s for lint container execution\n' "${container_bin}"
"${container_bin}" run --rm -v "${PWD}:/workspace:ro" "${hadolint_image}" hadolint "${dockerfiles[@]}"

shellcheck \
  containers/control-plane/bin/control-plane-podman \
  containers/control-plane/bin/control-plane-screen \
  containers/control-plane/bin/control-plane-entrypoint \
  containers/control-plane/bin/control-plane-run \
  containers/control-plane/bin/control-plane-session \
  containers/control-plane/bin/k8s-job-start \
  containers/control-plane/bin/k8s-job-wait \
  containers/control-plane/bin/k8s-job-pod \
  containers/control-plane/bin/k8s-job-logs \
  containers/control-plane/bin/k8s-job-run \
  containers/control-plane/config/profile-control-plane-env.sh \
  containers/execution-plane-smoke/execution-plane-smoke \
  scripts/*.sh
