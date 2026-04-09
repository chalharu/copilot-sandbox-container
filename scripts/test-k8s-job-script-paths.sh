#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
job_script_path="${script_dir}/test-k8s-job.sh"

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

printf '%s\n' 'k8s-job-script-test: verifying repo-relative asset paths' >&2
assert_file_contains "${job_script_path}" 'repo_root="$(cd "${script_dir}/.." && pwd)"'
assert_file_contains "${job_script_path}" 'control_plane_root="${repo_root}/containers/control-plane"'
assert_file_contains "${job_script_path}" '--from-file=control-plane-entrypoint="${control_plane_root}/bin/control-plane-entrypoint"'
assert_file_contains "${job_script_path}" '--from-file=profile-control-plane-env.sh="${control_plane_root}/config/profile-control-plane-env.sh"'
assert_file_contains "${job_script_path}" '--from-file=repo-change-delivery-skill.md="${control_plane_root}/skills/repo-change-delivery/SKILL.md"'
assert_file_not_contains "${job_script_path}" '/workspace/containers/control-plane/'
