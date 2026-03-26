#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"

toolchain="$(detect_build_test_toolchain)"
container_bin="$(container_runtime_for_toolchain "${toolchain}")"
build_bin="$(build_command_for_toolchain "${toolchain}")"
control_plane_image="${CONTROL_PLANE_IMAGE_TAG:-localhost/control-plane:test}"
execution_plane_image="${EXECUTION_PLANE_IMAGE_TAG:-localhost/execution-plane-smoke:test}"
cluster_name="${CONTROL_PLANE_KIND_CLUSTER_NAME:-control-plane-ci}"
kind_provider="${KIND_EXPERIMENTAL_PROVIDER:-${container_bin}}"
build_only=0
skip_image_build=0
test_group="all"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/build-test.sh [--build-only] [--skip-image-build] [--group all|smoke|regressions|kind|kind-session|kind-jobs|kind-jobs-core|kind-jobs-transfer]
EOF
}

run_smoke_group() {
  CONTROL_PLANE_CONTAINER_BIN="${container_bin}" \
    "${script_dir}/test-standalone.sh" "${control_plane_image}" "${execution_plane_image}"

  CONTROL_PLANE_CONTAINER_BIN="${container_bin}" \
    "${script_dir}/test-config-injection.sh" "${control_plane_image}"

  CONTROL_PLANE_CONTAINER_BIN="${container_bin}" \
    "${script_dir}/test-entrypoint-capabilities.sh" "${control_plane_image}"
}

run_regressions_group() {
  CONTROL_PLANE_CONTAINER_BIN="${container_bin}" \
    "${script_dir}/test-regressions.sh" "${control_plane_image}"

  CONTROL_PLANE_CONTAINER_BIN="${container_bin}" \
    "${script_dir}/test-renovate-config-permissions.sh"

  CONTROL_PLANE_CONTAINER_BIN="${container_bin}" \
    "${script_dir}/test-podman-startup.sh" "${control_plane_image}"

  CONTROL_PLANE_CONTAINER_BIN="${container_bin}" \
    "${script_dir}/test-k8s-sample-storage-layout.sh"

  CONTROL_PLANE_CONTAINER_BIN="${container_bin}" \
    "${script_dir}/test-k8s-rust-s3-backend.sh"

  CONTROL_PLANE_CONTAINER_BIN="${container_bin}" \
    "${script_dir}/test-k8s-job-wait.sh"

  CONTROL_PLANE_CONTAINER_BIN="${container_bin}" \
    "${script_dir}/test-garage-bootstrap.sh"

  CONTROL_PLANE_CONTAINER_BIN="${container_bin}" \
    "${script_dir}/test-kind-image-loading.sh"

  CONTROL_PLANE_CONTAINER_BIN="${container_bin}" \
    "${script_dir}/test-ci-workflow-parallelization.sh"

  CONTROL_PLANE_CONTAINER_BIN="${container_bin}" \
    "${script_dir}/test-github-hooks.sh" "${control_plane_image}"

  CONTROL_PLANE_CONTAINER_BIN="${container_bin}" \
    "${script_dir}/test-pre-tool-use-policy.sh" "${control_plane_image}"

  CONTROL_PLANE_CONTAINER_BIN="${container_bin}" \
    "${script_dir}/test-audit-logging.sh" "${control_plane_image}"

  CONTROL_PLANE_CONTAINER_BIN="${container_bin}" \
    "${script_dir}/test-audit-analysis.sh" "${control_plane_image}"

  CONTROL_PLANE_CONTAINER_BIN="${container_bin}" \
    "${script_dir}/test-image-maintenance.sh"

  CONTROL_PLANE_CONTAINER_BIN="${container_bin}" \
    "${script_dir}/test-repo-change-delivery-skills.sh"
}

run_kind_group() {
  local kind_test_group="${1:-all}"

  KIND_EXPERIMENTAL_PROVIDER="${kind_provider}" \
    CONTROL_PLANE_CONTAINER_BIN="${container_bin}" \
    CONTROL_PLANE_KIND_TEST_GROUP="${kind_test_group}" \
    "${script_dir}/test-kind.sh" "${control_plane_image}" "${execution_plane_image}" "${cluster_name}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only)
      build_only=1
      shift
      ;;
    --skip-image-build)
      skip_image_build=1
      shift
      ;;
    --group)
      [[ $# -ge 2 ]] || {
        usage
        exit 1
      }
      test_group="$2"
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

if [[ -n "${CONTROL_PLANE_CONTAINER_BIN:-}" ]] && [[ "${CONTROL_PLANE_CONTAINER_BIN}" != "${container_bin}" ]]; then
  printf 'CONTROL_PLANE_CONTAINER_BIN=%s conflicts with %s toolchain\n' "${CONTROL_PLANE_CONTAINER_BIN}" "${toolchain}" >&2
  exit 1
fi

case "${test_group}" in
  all|smoke|regressions|kind|kind-session|kind-jobs|kind-jobs-core|kind-jobs-transfer)
    ;;
  *)
    printf 'Unsupported build/test group: %s\n' "${test_group}" >&2
    usage
    exit 1
    ;;
esac

if [[ "${build_only}" -eq 1 ]] && [[ "${skip_image_build}" -eq 1 ]]; then
  printf 'Cannot combine --build-only with --skip-image-build\n' >&2
  exit 1
fi

require_command "${build_bin}"
require_command "${container_bin}"

printf 'Using %s toolchain for build/test\n' "${toolchain}"
if [[ "${skip_image_build}" -eq 0 ]]; then
  build_image_for_toolchain "${toolchain}" "${control_plane_image}" containers/control-plane
  build_image_for_toolchain "${toolchain}" "${execution_plane_image}" containers/execution-plane-smoke
fi

if [[ "${build_only}" -eq 1 ]]; then
  exit 0
fi

require_command ssh
require_command ssh-keygen

if [[ "${test_group}" == "kind" ]] || [[ "${test_group}" == "kind-session" ]] || [[ "${test_group}" == "kind-jobs" ]] || [[ "${test_group}" == "kind-jobs-core" ]] || [[ "${test_group}" == "kind-jobs-transfer" ]] || [[ "${test_group}" == "all" ]]; then
  require_command kind
  require_command kubectl
fi

case "${test_group}" in
  all)
    run_smoke_group
    run_regressions_group
    run_kind_group
    ;;
  smoke)
    run_smoke_group
    ;;
  regressions)
    run_regressions_group
    ;;
  kind)
    run_kind_group
    ;;
  kind-session)
    run_kind_group session
    ;;
  kind-jobs)
    run_kind_group jobs
    ;;
  kind-jobs-core)
    run_kind_group jobs-core
    ;;
  kind-jobs-transfer)
    run_kind_group jobs-transfer
    ;;
esac
