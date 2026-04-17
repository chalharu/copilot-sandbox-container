#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
workflow_path="${repo_root}/.github/workflows/control-plane-ci.yml"
build_test_path="${script_dir}/build-test.sh"
kind_test_path="${script_dir}/test-kind.sh"

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

assert_file_not_contains() {
  local path="$1"
  local unexpected="$2"

  if grep -Fq -- "${unexpected}" "${path}"; then
    printf 'Did not expect %s to contain: %s\n' "${path}" "${unexpected}" >&2
    exit 1
  fi
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

assert_block_contains_one_of() {
  local block="$1"
  local description="$2"
  shift 2

  local expected
  for expected in "$@"; do
    if grep -Fq -- "${expected}" <<<"${block}"; then
      return 0
    fi
  done

  printf 'Expected %s to contain one of:\n' "${description}" >&2
  printf '  %s\n' "$@" >&2
  printf '%s\n' "${block}" >&2
  exit 1
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
assert_file_contains "${kind_test_path}" "if [[ \"\${kind_test_group}\" == \"all\" ]] || [[ \"\${kind_test_group}\" == \"session\" ]]; then"
assert_file_contains "${kind_test_path}" '  all|session|jobs|jobs-core|jobs-transfer)'
assert_file_contains "${kind_test_path}" 'fast_execution_image="${CONTROL_PLANE_TEST_FAST_EXECUTION_IMAGE:-${control_plane_image}}"'

printf '%s\n' 'ci-workflow-test: verifying workflow fan-out wiring' >&2
integration_amd64_block="$(job_block integration-amd64)"
integration_arm64_block="$(job_block integration-arm64)"
integration_smoke_amd64_block="$(job_block integration-smoke-amd64)"
integration_smoke_arm64_block="$(job_block integration-smoke-arm64)"
integration_regressions_block="$(job_block integration-regressions)"
integration_kind_session_block="$(job_block integration-kind-session)"
integration_kind_jobs_block="$(job_block integration-kind-jobs)"
integration_kind_jobs_transfer_block="$(job_block integration-kind-jobs-transfer)"
publish_block="$(job_block publish-architecture-images)"

if grep -Fqx '  lint:' "${workflow_path}"; then
  printf 'Did not expect lint job to remain in %s\n' "${workflow_path}" >&2
  exit 1
fi

[[ -n "${integration_amd64_block}" ]] || {
  printf 'Expected integration-amd64 job in %s\n' "${workflow_path}" >&2
  exit 1
}
[[ -n "${integration_arm64_block}" ]] || {
  printf 'Expected integration-arm64 job in %s\n' "${workflow_path}" >&2
  exit 1
}
[[ -n "${integration_smoke_amd64_block}" ]] || {
  printf 'Expected integration-smoke-amd64 job in %s\n' "${workflow_path}" >&2
  exit 1
}
[[ -n "${integration_smoke_arm64_block}" ]] || {
  printf 'Expected integration-smoke-arm64 job in %s\n' "${workflow_path}" >&2
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

assert_file_contains "${workflow_path}" '  pull_request:'
assert_file_contains "${workflow_path}" '    paths:'
assert_file_contains "${workflow_path}" "      - '**'"
assert_file_contains "${workflow_path}" "      - '!**/*.md'"
assert_file_contains "${workflow_path}" "      - 'containers/control-plane/skills/**/SKILL.md'"
assert_file_contains "${workflow_path}" '  push:'
assert_file_not_contains "${workflow_path}" './scripts/ci-changes-require-build.sh'
if grep -Fqx '  changes:' "${workflow_path}"; then
  printf 'Did not expect changes job in %s\n' "${workflow_path}" >&2
  exit 1
fi
if grep -Fqx '  integration:' "${workflow_path}"; then
  printf 'Did not expect legacy integration job in %s\n' "${workflow_path}" >&2
  exit 1
fi
if grep -Fqx '  integration-smoke:' "${workflow_path}"; then
  printf 'Did not expect legacy integration-smoke job in %s\n' "${workflow_path}" >&2
  exit 1
fi
if grep -Fqx '  publish-manifests:' "${workflow_path}"; then
  printf 'Did not expect publish-manifests job to remain in %s\n' "${workflow_path}" >&2
  exit 1
fi
if grep -Fqx '  cleanup-packages:' "${workflow_path}"; then
  printf 'Did not expect cleanup-packages job to remain in %s\n' "${workflow_path}" >&2
  exit 1
fi

assert_block_contains "${integration_amd64_block}" 'name: Integration Images (x64)' 'integration-amd64 job block'
assert_block_contains "${integration_amd64_block}" 'runs-on: ubuntu-24.04' 'integration-amd64 job block'
assert_block_contains "${integration_amd64_block}" 'path: /tmp/control-plane-buildx-cache-amd64' 'integration-amd64 job block'
assert_block_contains "${integration_amd64_block}" 'CONTROL_PLANE_BUILDX_CACHE_ROOT: /tmp/control-plane-buildx-cache-amd64' 'integration-amd64 job block'
assert_block_contains "${integration_amd64_block}" 'name: control-plane-images-amd64' 'integration-amd64 job block'
assert_block_contains "${integration_amd64_block}" 'docker/setup-buildx-action@4d04d5d9486b7bd6fa91e7baf45bbb4f8b9deedd' 'integration-amd64 job block'
assert_block_contains "${integration_amd64_block}" 'driver: docker-container' 'integration-amd64 job block'

assert_block_contains "${integration_arm64_block}" 'name: Integration Images (aarch64)' 'integration-arm64 job block'
assert_block_contains "${integration_arm64_block}" 'runs-on: ubuntu-24.04-arm' 'integration-arm64 job block'
assert_block_contains "${integration_arm64_block}" 'path: /tmp/control-plane-buildx-cache-arm64' 'integration-arm64 job block'
assert_block_contains "${integration_arm64_block}" 'CONTROL_PLANE_BUILDX_CACHE_ROOT: /tmp/control-plane-buildx-cache-arm64' 'integration-arm64 job block'
assert_block_contains "${integration_arm64_block}" 'name: control-plane-images-arm64' 'integration-arm64 job block'
assert_block_contains_one_of \
  "${integration_arm64_block}" \
  'integration-arm64 job block' \
  'docker/setup-buildx-action@4d04d5d9486b7bd6fa91e7baf45bbb4f8b9deedd' \
  '*setup-buildx'
assert_block_contains_one_of \
  "${integration_arm64_block}" \
  'integration-arm64 job block' \
  'driver: docker-container' \
  '*setup-buildx'

assert_block_contains "${integration_smoke_amd64_block}" 'runs-on: ubuntu-24.04' 'integration-smoke-amd64 job block'
assert_block_not_contains "${integration_smoke_amd64_block}" 'strategy:' 'integration-smoke-amd64 job block'
assert_block_contains "${integration_smoke_amd64_block}" 'needs: integration-amd64' 'integration-smoke-amd64 job block'
assert_block_not_contains "${integration_smoke_amd64_block}" 'needs: integration-arm64' 'integration-smoke-amd64 job block'
assert_block_contains "${integration_smoke_amd64_block}" 'name: control-plane-images-amd64' 'integration-smoke-amd64 job block'
assert_block_contains "${integration_smoke_amd64_block}" 'Load integration images' 'integration-smoke-amd64 job block'
assert_block_contains "${integration_smoke_amd64_block}" 'docker load -i downloaded-images/control-plane-images.tar' 'integration-smoke-amd64 job block'

assert_block_contains "${integration_smoke_arm64_block}" 'runs-on: ubuntu-24.04-arm' 'integration-smoke-arm64 job block'
assert_block_not_contains "${integration_smoke_arm64_block}" 'strategy:' 'integration-smoke-arm64 job block'
assert_block_contains "${integration_smoke_arm64_block}" 'needs: integration-arm64' 'integration-smoke-arm64 job block'
assert_block_not_contains "${integration_smoke_arm64_block}" 'needs: integration-amd64' 'integration-smoke-arm64 job block'
assert_block_contains "${integration_smoke_arm64_block}" 'name: control-plane-images-arm64' 'integration-smoke-arm64 job block'
assert_block_contains_one_of \
  "${integration_smoke_arm64_block}" \
  'integration-smoke-arm64 job block' \
  'Load integration images' \
  '*load-integration-images'
assert_block_contains_one_of \
  "${integration_smoke_arm64_block}" \
  'integration-smoke-arm64 job block' \
  'docker load -i downloaded-images/control-plane-images.tar' \
  '*load-integration-images'

# shellcheck disable=SC2016
assert_block_contains "${integration_regressions_block}" 'path: /tmp/control-plane-buildx-cache-amd64' 'integration-regressions job block'
# shellcheck disable=SC2016
assert_block_contains "${integration_regressions_block}" 'path: /tmp/control-plane-rust-regression-cache' 'integration-regressions job block'
assert_block_contains "${integration_regressions_block}" 'docker/setup-buildx-action@4d04d5d9486b7bd6fa91e7baf45bbb4f8b9deedd' 'integration-regressions job block'
assert_block_contains "${integration_regressions_block}" 'driver: docker-container' 'integration-regressions job block'
# shellcheck disable=SC2016
assert_block_contains "${integration_regressions_block}" 'CONTROL_PLANE_BUILDX_CACHE_ROOT: /tmp/control-plane-buildx-cache-amd64' 'integration-regressions job block'
# shellcheck disable=SC2016
assert_block_contains "${integration_regressions_block}" 'CONTROL_PLANE_RUST_CONTAINER_CACHE_ROOT: /tmp/control-plane-rust-regression-cache' 'integration-regressions job block'
assert_block_contains "${integration_regressions_block}" 'runs-on: ubuntu-24.04' 'integration-regressions job block'
assert_block_contains "${integration_regressions_block}" 'needs: integration-amd64' 'integration-regressions job block'
assert_block_not_contains "${integration_regressions_block}" 'needs: integration-arm64' 'integration-regressions job block'
assert_block_not_contains "${integration_regressions_block}" 'strategy:' 'integration-regressions job block'
assert_block_contains "${integration_regressions_block}" 'name: control-plane-images-amd64' 'integration-regressions job block'
assert_block_contains_one_of \
  "${integration_regressions_block}" \
  'integration-regressions job block' \
  'Load integration images' \
  '*load-integration-images'
assert_block_contains_one_of \
  "${integration_regressions_block}" \
  'integration-regressions job block' \
  'docker load -i downloaded-images/control-plane-images.tar' \
  '*load-integration-images'
assert_block_contains "${integration_kind_session_block}" 'runs-on: ubuntu-24.04' 'integration-kind-session job block'
assert_block_contains "${integration_kind_session_block}" 'needs: integration-amd64' 'integration-kind-session job block'
assert_block_not_contains "${integration_kind_session_block}" 'needs: integration-arm64' 'integration-kind-session job block'
assert_block_not_contains "${integration_kind_session_block}" 'strategy:' 'integration-kind-session job block'
assert_block_contains "${integration_kind_session_block}" 'skipClusterCreation: true' 'integration-kind-session job block'
assert_block_not_contains "${integration_kind_session_block}" 'Load integration images' 'integration-kind-session job block'
assert_block_contains "${integration_kind_session_block}" '*download-integration-images-amd64' 'integration-kind-session job block'
assert_block_contains "${integration_kind_session_block}" 'CONTROL_PLANE_KIND_IMAGE_ARCHIVE: downloaded-images/control-plane-images.tar' 'integration-kind-session job block'
assert_block_contains "${integration_kind_session_block}" './scripts/build-test.sh --skip-image-build --group kind-session' 'integration-kind-session job block'
assert_block_contains "${integration_kind_jobs_block}" 'runs-on: ubuntu-24.04' 'integration-kind-jobs job block'
assert_block_contains "${integration_kind_jobs_block}" 'needs: integration-amd64' 'integration-kind-jobs job block'
assert_block_not_contains "${integration_kind_jobs_block}" 'needs: integration-arm64' 'integration-kind-jobs job block'
assert_block_not_contains "${integration_kind_jobs_block}" 'strategy:' 'integration-kind-jobs job block'
assert_block_contains_one_of \
  "${integration_kind_jobs_block}" \
  'integration-kind-jobs job block' \
  'skipClusterCreation: true' \
  '*setup-kind'
assert_block_not_contains "${integration_kind_jobs_block}" 'Load integration images' 'integration-kind-jobs job block'
assert_block_contains "${integration_kind_jobs_block}" '*download-integration-images-amd64' 'integration-kind-jobs job block'
assert_block_contains "${integration_kind_jobs_block}" 'CONTROL_PLANE_KIND_IMAGE_ARCHIVE: downloaded-images/control-plane-images.tar' 'integration-kind-jobs job block'
assert_block_contains "${integration_kind_jobs_block}" './scripts/build-test.sh --skip-image-build --group kind-jobs-core' 'integration-kind-jobs job block'
assert_block_contains "${integration_kind_jobs_transfer_block}" 'runs-on: ubuntu-24.04' 'integration-kind-jobs-transfer job block'
assert_block_contains "${integration_kind_jobs_transfer_block}" 'needs: integration-amd64' 'integration-kind-jobs-transfer job block'
assert_block_not_contains "${integration_kind_jobs_transfer_block}" 'needs: integration-arm64' 'integration-kind-jobs-transfer job block'
assert_block_not_contains "${integration_kind_jobs_transfer_block}" 'strategy:' 'integration-kind-jobs-transfer job block'
assert_block_contains_one_of \
  "${integration_kind_jobs_transfer_block}" \
  'integration-kind-jobs-transfer job block' \
  'skipClusterCreation: true' \
  '*setup-kind'
assert_block_not_contains "${integration_kind_jobs_transfer_block}" 'Load integration images' 'integration-kind-jobs-transfer job block'
assert_block_contains "${integration_kind_jobs_transfer_block}" '*download-integration-images-amd64' 'integration-kind-jobs-transfer job block'
assert_block_contains "${integration_kind_jobs_transfer_block}" 'CONTROL_PLANE_KIND_IMAGE_ARCHIVE: downloaded-images/control-plane-images.tar' 'integration-kind-jobs-transfer job block'
assert_block_contains "${integration_kind_jobs_transfer_block}" './scripts/build-test.sh --skip-image-build --group kind-jobs-transfer' 'integration-kind-jobs-transfer job block'
assert_block_not_contains "${publish_block}" '- lint' 'publish-architecture-images job block'
assert_block_contains "${publish_block}" 'name: Publish Architecture Images' 'publish-architecture-images job block'
assert_block_contains "${publish_block}" 'runs-on: ubuntu-24.04' 'publish-architecture-images job block'
assert_block_not_contains "${publish_block}" 'strategy:' 'publish-architecture-images job block'
assert_block_contains "${publish_block}" '- integration-smoke-amd64' 'publish-architecture-images job block'
assert_block_contains "${publish_block}" '- integration-smoke-arm64' 'publish-architecture-images job block'
assert_block_contains "${publish_block}" '- integration-regressions' 'publish-architecture-images job block'
assert_block_contains "${publish_block}" '- integration-kind-session' 'publish-architecture-images job block'
assert_block_contains "${publish_block}" '- integration-kind-jobs' 'publish-architecture-images job block'
assert_block_contains "${publish_block}" '- integration-kind-jobs-transfer' 'publish-architecture-images job block'
assert_block_contains "${publish_block}" 'name: control-plane-images-amd64' 'publish-architecture-images job block'
assert_block_contains "${publish_block}" 'path: downloaded-images/amd64' 'publish-architecture-images job block'
assert_block_contains "${publish_block}" 'name: control-plane-images-arm64' 'publish-architecture-images job block'
assert_block_contains "${publish_block}" 'path: downloaded-images/arm64' 'publish-architecture-images job block'

if grep -Fqx '  integration-kind:' "${workflow_path}"; then
  printf 'Did not expect legacy integration-kind job to remain in %s\n' "${workflow_path}" >&2
  exit 1
fi

printf '%s\n' 'ci-workflow-test: workflow fan-out ok' >&2
