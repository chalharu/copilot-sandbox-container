#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
# Resolve the repo's .github/skills symlink to the canonical on-disk path.
skill_dir="$(cd "${repo_root}/.github/skills/pr-fix-workflow" && pwd -P)"
skill_file="${skill_dir}/SKILL.md"
reference_file="${skill_dir}/references/validation-and-delivery.md"
package_dir="$(mktemp -d)"

# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"

toolchain="$(detect_build_test_toolchain)"
container_bin="$(container_runtime_for_toolchain "${toolchain}")"
yamllint_image="${CONTROL_PLANE_YAMLLINT_IMAGE_TAG:-localhost/yamllint:test}"

cleanup() {
  rm -rf "${package_dir}"
}
trap cleanup EXIT

assert_file_present() {
  local path="$1"

  [[ -f "${path}" ]] || {
    printf 'Expected file: %s\n' "${path}" >&2
    exit 1
  }
}

assert_file_absent() {
  local path="$1"

  [[ ! -e "${path}" ]] || {
    printf 'Did not expect path: %s\n' "${path}" >&2
    exit 1
  }
}

assert_file_contains() {
  local path="$1"
  local expected="$2"

  grep -Fq "${expected}" "${path}" || {
    printf 'Expected %s to contain: %s\n' "${path}" "${expected}" >&2
    exit 1
  }
}

require_command "${container_bin}"

printf '%s\n' 'pr-fix-workflow-skill-test: checking skill files' >&2
assert_file_present "${skill_file}"
assert_file_present "${reference_file}"
assert_file_absent "${skill_dir}/scripts/example.py"
assert_file_absent "${skill_dir}/references/api_reference.md"
assert_file_absent "${skill_dir}/assets/example_asset.txt"

assert_file_contains "${skill_file}" 'name: pr-fix-workflow'
assert_file_contains "${skill_file}" 'sub-agents'
assert_file_contains "${skill_file}" 'git-commit'
assert_file_contains "${skill_file}" 'origin/main'
assert_file_contains "${skill_file}" 'podman'
assert_file_contains "${skill_file}" 'kubectl'
assert_file_contains "${skill_file}" 'GitHub Actions'
assert_file_contains "${skill_file}" 'references/validation-and-delivery.md'

assert_file_contains "${reference_file}" 'CONTROL_PLANE_TOOLCHAIN=podman ./scripts/lint.sh'
assert_file_contains "${reference_file}" 'CONTROL_PLANE_TOOLCHAIN=podman ./scripts/build-test.sh'
assert_file_contains "${reference_file}" './scripts/test-k8s-job.sh'
assert_file_contains "${reference_file}" '.github/workflows/control-plane-ci.yml'
assert_file_contains "${reference_file}" 'quick_validate.py'
assert_file_contains "${reference_file}" 'package_skill.py'

printf '%s\n' 'pr-fix-workflow-skill-test: validating and packaging skill' >&2
build_image_for_toolchain "${toolchain}" "${yamllint_image}" containers/yamllint
"${container_bin}" run --rm --user "$(id -u):$(id -g)" \
  -v "${repo_root}:/workspace" \
  -w /workspace/.github/skills/skill-creator/scripts \
  --entrypoint python3 \
  "${yamllint_image}" \
  quick_validate.py "${skill_dir}"

"${container_bin}" run --rm --user "$(id -u):$(id -g)" \
  -v "${repo_root}:/workspace" \
  -v "${package_dir}:${package_dir}" \
  -w /workspace/.github/skills/skill-creator/scripts \
  --entrypoint python3 \
  "${yamllint_image}" \
  package_skill.py "${skill_dir}" "${package_dir}"

assert_file_present "${package_dir}/pr-fix-workflow.skill"
printf '%s\n' 'pr-fix-workflow-skill-test: skill ok' >&2
