#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
workflow_path="${repo_root}/.github/workflows/control-plane-ci.yml"
build_test_path="${script_dir}/build-test.sh"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

job_block() {
  local job_name="$1"

  awk -v start="  ${job_name}:" '
    $0 == start {
      printing = 1
    }
    printing && $0 != start && $0 ~ /^  [a-z0-9-]+:$/ {
      exit
    }
    printing {
      print
    }
  ' "${workflow_path}"
}

assert_file_contains() {
  local path="$1"
  local expected="$2"

  grep -Fq -- "${expected}" "${path}" || {
    printf 'Expected %s to contain: %s\n' "${path}" "${expected}" >&2
    exit 1
  }
}

assert_block_contains() {
  local block="$1"
  local expected="$2"
  local description="$3"

  grep -Fq -- "${expected}" <<<"${block}" || {
    printf 'Expected %s to contain: %s\n' "${description}" "${expected}" >&2
    printf '%s\n' "${block}" >&2
    exit 1
  }
}

assert_block_not_contains() {
  local block="$1"
  local unexpected="$2"
  local description="$3"

  if grep -Fq -- "${unexpected}" <<<"${block}"; then
    printf 'Did not expect %s to contain: %s\n' "${description}" "${unexpected}" >&2
    printf '%s\n' "${block}" >&2
    exit 1
  fi
}

require_command awk
require_command grep

printf '%s\n' 'ci-workflow-test: verifying build-test group support' >&2
assert_file_contains "${build_test_path}" 'Usage: scripts/build-test.sh [--build-only] [--skip-image-build] [--group all|smoke|regressions|kind|kind-session|kind-jobs|kind-jobs-core|kind-jobs-transfer]'
assert_file_contains "${build_test_path}" 'all|smoke|regressions|kind|kind-session|kind-jobs|kind-jobs-core|kind-jobs-transfer)'
assert_file_contains "${build_test_path}" 'run_kind_group session'
assert_file_contains "${build_test_path}" 'run_kind_group jobs'
assert_file_contains "${build_test_path}" 'run_kind_group jobs-core'
assert_file_contains "${build_test_path}" 'run_kind_group jobs-transfer'

printf '%s\n' 'ci-workflow-test: verifying workflow fan-out wiring' >&2
integration_block="$(job_block integration)"
integration_smoke_block="$(job_block integration-smoke)"
integration_regressions_block="$(job_block integration-regressions)"
integration_kind_session_block="$(job_block integration-kind-session)"
integration_kind_jobs_block="$(job_block integration-kind-jobs)"
integration_kind_jobs_transfer_block="$(job_block integration-kind-jobs-transfer)"
publish_block="$(job_block publish-architecture-images)"

[[ -n "${integration_block}" ]] || {
  printf 'Expected integration job in %s\n' "${workflow_path}" >&2
  exit 1
}
[[ -n "${integration_smoke_block}" ]] || {
  printf 'Expected integration-smoke job in %s\n' "${workflow_path}" >&2
  exit 1
}
[[ -n "${integration_regressions_block}" ]] || {
  printf 'Expected integration-regressions job in %s\n' "${workflow_path}" >&2
  exit 1
}
[[ -n "${integration_kind_session_block}" ]] || {
  printf 'Expected integration-kind-session job in %s\n' "${workflow_path}" >&2
  exit 1
}
[[ -n "${integration_kind_jobs_block}" ]] || {
  printf 'Expected integration-kind-jobs job in %s\n' "${workflow_path}" >&2
  exit 1
}
[[ -n "${integration_kind_jobs_transfer_block}" ]] || {
  printf 'Expected integration-kind-jobs-transfer job in %s\n' "${workflow_path}" >&2
  exit 1
}
[[ -n "${publish_block}" ]] || {
  printf 'Expected publish-architecture-images job in %s\n' "${workflow_path}" >&2
  exit 1
}

assert_block_not_contains "${integration_block}" 'needs: lint' 'integration job block'
assert_block_contains "${integration_smoke_block}" 'Load integration images' 'integration-smoke job block'
assert_block_contains "${integration_smoke_block}" 'podman load -i downloaded-images/control-plane-images.tar' 'integration-smoke job block'
assert_block_contains "${integration_regressions_block}" 'Load integration images' 'integration-regressions job block'
assert_block_contains "${integration_regressions_block}" 'podman load -i downloaded-images/control-plane-images.tar' 'integration-regressions job block'
assert_block_contains "${integration_kind_session_block}" 'skipClusterCreation: true' 'integration-kind-session job block'
assert_block_not_contains "${integration_kind_session_block}" 'Load integration images' 'integration-kind-session job block'
assert_block_contains "${integration_kind_session_block}" 'CONTROL_PLANE_KIND_IMAGE_ARCHIVE: downloaded-images/control-plane-images.tar' 'integration-kind-session job block'
assert_block_contains "${integration_kind_session_block}" './scripts/build-test.sh --skip-image-build --group kind-session' 'integration-kind-session job block'
assert_block_contains "${integration_kind_jobs_block}" 'skipClusterCreation: true' 'integration-kind-jobs job block'
assert_block_not_contains "${integration_kind_jobs_block}" 'Load integration images' 'integration-kind-jobs job block'
assert_block_contains "${integration_kind_jobs_block}" 'CONTROL_PLANE_KIND_IMAGE_ARCHIVE: downloaded-images/control-plane-images.tar' 'integration-kind-jobs job block'
assert_block_contains "${integration_kind_jobs_block}" './scripts/build-test.sh --skip-image-build --group kind-jobs-core' 'integration-kind-jobs job block'
assert_block_contains "${integration_kind_jobs_transfer_block}" 'skipClusterCreation: true' 'integration-kind-jobs-transfer job block'
assert_block_not_contains "${integration_kind_jobs_transfer_block}" 'Load integration images' 'integration-kind-jobs-transfer job block'
assert_block_contains "${integration_kind_jobs_transfer_block}" 'CONTROL_PLANE_KIND_IMAGE_ARCHIVE: downloaded-images/control-plane-images.tar' 'integration-kind-jobs-transfer job block'
assert_block_contains "${integration_kind_jobs_transfer_block}" './scripts/build-test.sh --skip-image-build --group kind-jobs-transfer' 'integration-kind-jobs-transfer job block'
assert_block_contains "${publish_block}" '- lint' 'publish-architecture-images job block'
assert_block_contains "${publish_block}" '- integration-kind-session' 'publish-architecture-images job block'
assert_block_contains "${publish_block}" '- integration-kind-jobs' 'publish-architecture-images job block'
assert_block_contains "${publish_block}" '- integration-kind-jobs-transfer' 'publish-architecture-images job block'

if grep -Fqx '  integration-kind:' "${workflow_path}"; then
  printf 'Did not expect legacy integration-kind job to remain in %s\n' "${workflow_path}" >&2
  exit 1
fi

printf '%s\n' 'ci-workflow-test: workflow fan-out ok' >&2
