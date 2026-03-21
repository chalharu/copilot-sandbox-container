#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
doc_coauthor_skill_dir="${repo_root}/.github/skills/doc-coauthoring"
doc_coauthor_skill_file="${doc_coauthor_skill_dir}/SKILL.md"
repo_skill_dir="${repo_root}/.github/skills/pr-fix-workflow"
repo_skill_file="${repo_skill_dir}/SKILL.md"
repo_reference_file="${repo_skill_dir}/references/validation-and-delivery.md"
skill_creator_dir="${repo_root}/.github/skills/skill-creator"
skill_creator_skill_file="${skill_creator_dir}/SKILL.md"
skill_creator_license_file="${skill_creator_dir}/LICENSE.txt"
repo_git_commit_dir="${repo_root}/.github/skills/git-commit"
generic_skill_dir="${repo_root}/containers/control-plane/skills/repo-change-delivery"
generic_skill_file="${generic_skill_dir}/SKILL.md"
commit_skill_dir="${repo_root}/containers/control-plane/skills/git-commit"
commit_skill_file="${commit_skill_dir}/SKILL.md"
pull_request_skill_dir="${repo_root}/containers/control-plane/skills/pull-request-workflow"
pull_request_skill_file="${pull_request_skill_dir}/SKILL.md"
bundled_reference_file="${repo_root}/containers/control-plane/skills/control-plane-operations/references/skills.md"
dockerfile_path="${repo_root}/containers/control-plane/Dockerfile"
entrypoint_path="${repo_root}/containers/control-plane/bin/control-plane-entrypoint"
package_dir="$(mktemp -d)"
doc_coauthor_package_file="${package_dir}/doc-coauthoring.skill"
repo_package_file="${package_dir}/pr-fix-workflow.skill"
skill_creator_package_file="${package_dir}/skill-creator.skill"
generic_package_file="${package_dir}/repo-change-delivery.skill"
commit_package_file="${package_dir}/git-commit.skill"
pull_request_package_file="${package_dir}/pull-request-workflow.skill"

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

assert_file_not_contains() {
  local path="$1"
  local unexpected="$2"

  if grep -Fq "${unexpected}" "${path}"; then
    printf 'Did not expect %s to contain: %s\n' "${path}" "${unexpected}" >&2
    exit 1
  fi
}

package_skill_to_host() {
  local skill_path="$1"
  local package_path="$2"

  "${container_bin}" run --rm --user "$(id -u):$(id -g)" \
    -e PYTHONDONTWRITEBYTECODE=1 \
    -v "${repo_root}:/workspace" \
    -w /workspace/.github/skills/skill-creator/scripts \
    --entrypoint python3 \
    "${yamllint_image}" \
    -c 'import pathlib, subprocess, sys
skill_dir = pathlib.Path(sys.argv[1])
out_dir = pathlib.Path("/tmp") / f"{skill_dir.name}-package"
out_dir.mkdir(parents=True, exist_ok=True)
subprocess.run(
    ["python3", "package_skill.py", str(skill_dir), str(out_dir)],
    check=True,
    stdout=sys.stderr,
    stderr=sys.stderr,
)
sys.stdout.buffer.write((out_dir / f"{skill_dir.name}.skill").read_bytes())' \
    "${skill_path}" \
    > "${package_path}"
}

require_command "${container_bin}"

printf '%s\n' 'repo-change-delivery-skills-test: checking skill files' >&2
assert_file_present "${doc_coauthor_skill_file}"
assert_file_present "${repo_skill_file}"
assert_file_present "${repo_reference_file}"
assert_file_present "${skill_creator_skill_file}"
assert_file_present "${skill_creator_license_file}"
assert_file_present "${generic_skill_file}"
assert_file_present "${commit_skill_file}"
assert_file_present "${pull_request_skill_file}"
assert_file_present "${bundled_reference_file}"
assert_file_present "${dockerfile_path}"
assert_file_present "${entrypoint_path}"
assert_file_absent "${repo_git_commit_dir}"
assert_file_absent "${generic_skill_dir}/scripts/example.py"
assert_file_absent "${generic_skill_dir}/references/api_reference.md"
assert_file_absent "${generic_skill_dir}/assets/example_asset.txt"

assert_file_contains "${doc_coauthor_skill_file}" 'name: doc-coauthoring'
assert_file_contains "${skill_creator_skill_file}" 'name: skill-creator'
assert_file_contains "${generic_skill_file}" 'name: repo-change-delivery'
assert_file_contains "${generic_skill_file}" 'full implementation loop'
assert_file_contains "${generic_skill_file}" 'non-main branch'
assert_file_contains "${generic_skill_file}" 'repo-local delivery or validation skill'
assert_file_contains "${generic_skill_file}" "\`git-commit\` and \`pull-request-workflow\`"
assert_file_not_contains "${generic_skill_file}" 'CONTROL_PLANE_TOOLCHAIN=podman'
assert_file_not_contains "${generic_skill_file}" '.github/workflows/control-plane-ci.yml'
assert_file_not_contains "${generic_skill_file}" './scripts/test-k8s-job.sh'

assert_file_contains "${commit_skill_file}" 'name: git-commit'
assert_file_contains "${commit_skill_file}" 'Conventional Commits'
assert_file_not_contains "${commit_skill_file}" 'mcp_io_github_'

assert_file_contains "${pull_request_skill_file}" 'name: pull-request-workflow'
assert_file_contains "${pull_request_skill_file}" 'Never open a duplicate pull request'
assert_file_contains "${pull_request_skill_file}" 'Push local commits before creating or refreshing the PR'
assert_file_contains "${pull_request_skill_file}" 'Prefer non-interactive GitHub operations'

assert_file_contains "${repo_skill_file}" 'name: pr-fix-workflow'
assert_file_contains "${repo_skill_file}" 'repo-change-delivery'
assert_file_contains "${repo_skill_file}" 'CONTROL_PLANE_TOOLCHAIN=podman'
assert_file_contains "${repo_skill_file}" 'references/validation-and-delivery.md'
assert_file_not_contains "${repo_skill_file}" 'Commit only on a non-main branch'
assert_file_not_contains "${repo_skill_file}" "After each commit, \`git fetch origin main\`"

assert_file_contains "${repo_reference_file}" './scripts/test-repo-change-delivery-skills.sh'
assert_file_contains "${repo_reference_file}" 'CONTROL_PLANE_TOOLCHAIN=podman ./scripts/lint.sh'
assert_file_contains "${repo_reference_file}" 'CONTROL_PLANE_TOOLCHAIN=podman ./scripts/build-test.sh'
assert_file_contains "${repo_reference_file}" './scripts/test-k8s-job.sh'
assert_file_contains "${repo_reference_file}" './scripts/test-current-cluster-regressions.sh'
assert_file_contains "${repo_reference_file}" '.github/workflows/control-plane-ci.yml'
assert_file_not_contains "${repo_reference_file}" 'git fetch origin main'

assert_file_contains "${bundled_reference_file}" "\`git-commit\`"
assert_file_contains "${bundled_reference_file}" "\`pull-request-workflow\`"

assert_file_contains "${dockerfile_path}" 'COPY skills/ /usr/local/share/control-plane/skills/'
assert_file_contains "${entrypoint_path}" 'install_bundled_control_plane_skills'
assert_file_contains "${entrypoint_path}" "for source_dir in \"\${bundled_skills_dir}\"/*; do"

printf '%s\n' 'repo-change-delivery-skills-test: validating and packaging skills' >&2
build_image_for_toolchain "${toolchain}" "${yamllint_image}" containers/yamllint

"${container_bin}" run --rm --user "$(id -u):$(id -g)" \
  -e PYTHONDONTWRITEBYTECODE=1 \
  -v "${repo_root}:/workspace" \
  -w /workspace/.github/skills/skill-creator/scripts \
  --entrypoint python3 \
  "${yamllint_image}" \
  quick_validate.py /workspace/.github/skills/doc-coauthoring

"${container_bin}" run --rm --user "$(id -u):$(id -g)" \
  -e PYTHONDONTWRITEBYTECODE=1 \
  -v "${repo_root}:/workspace" \
  -w /workspace/.github/skills/skill-creator/scripts \
  --entrypoint python3 \
  "${yamllint_image}" \
  quick_validate.py /workspace/containers/control-plane/skills/repo-change-delivery

"${container_bin}" run --rm --user "$(id -u):$(id -g)" \
  -e PYTHONDONTWRITEBYTECODE=1 \
  -v "${repo_root}:/workspace" \
  -w /workspace/.github/skills/skill-creator/scripts \
  --entrypoint python3 \
  "${yamllint_image}" \
  quick_validate.py /workspace/containers/control-plane/skills/git-commit

"${container_bin}" run --rm --user "$(id -u):$(id -g)" \
  -e PYTHONDONTWRITEBYTECODE=1 \
  -v "${repo_root}:/workspace" \
  -w /workspace/.github/skills/skill-creator/scripts \
  --entrypoint python3 \
  "${yamllint_image}" \
  quick_validate.py /workspace/containers/control-plane/skills/pull-request-workflow

"${container_bin}" run --rm --user "$(id -u):$(id -g)" \
  -e PYTHONDONTWRITEBYTECODE=1 \
  -v "${repo_root}:/workspace" \
  -w /workspace/.github/skills/skill-creator/scripts \
  --entrypoint python3 \
  "${yamllint_image}" \
  quick_validate.py /workspace/.github/skills/pr-fix-workflow

"${container_bin}" run --rm --user "$(id -u):$(id -g)" \
  -v "${repo_root}:/workspace" \
  -w /workspace/.github/skills/skill-creator/scripts \
  --entrypoint python3 \
  "${yamllint_image}" \
  quick_validate.py /workspace/.github/skills/skill-creator

package_skill_to_host /workspace/.github/skills/doc-coauthoring "${doc_coauthor_package_file}"
package_skill_to_host /workspace/.github/skills/pr-fix-workflow "${repo_package_file}"
package_skill_to_host /workspace/.github/skills/skill-creator "${skill_creator_package_file}"
package_skill_to_host /workspace/containers/control-plane/skills/repo-change-delivery "${generic_package_file}"
package_skill_to_host /workspace/containers/control-plane/skills/git-commit "${commit_package_file}"
package_skill_to_host /workspace/containers/control-plane/skills/pull-request-workflow "${pull_request_package_file}"

assert_file_present "${doc_coauthor_package_file}"
assert_file_present "${generic_package_file}"
assert_file_present "${commit_package_file}"
assert_file_present "${pull_request_package_file}"
assert_file_present "${repo_package_file}"
assert_file_present "${skill_creator_package_file}"
printf '%s\n' 'repo-change-delivery-skills-test: skills ok' >&2
