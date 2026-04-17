#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
external_skills_manifest="${repo_root}/containers/control-plane/config/external-skills.yaml"
git_skills_runtime_manifest="${repo_root}/containers/control-plane/runtime-tools/Cargo.toml"
git_skills_runtime_dispatch="${repo_root}/containers/control-plane/runtime-tools/src/invocation.rs"
git_skills_manifest_installer="${script_dir}/install-git-skills-from-manifest.sh"
legacy_external_skills_ref_file="${repo_root}/containers/control-plane/config/anthropic-skills.ref"
legacy_doc_coauthor_skill_dir="${repo_root}/.github/skills/doc-coauthoring"
legacy_skill_creator_dir="${repo_root}/.github/skills/skill-creator"
legacy_yamllint_skill_dir="${repo_root}/.github/skills/containerized-yamllint-ops"
repo_skill_dir="${repo_root}/.github/skills/pr-fix-workflow"
repo_skill_file="${repo_skill_dir}/SKILL.md"
repo_reference_file="${repo_skill_dir}/references/validation-and-delivery.md"
repo_git_commit_dir="${repo_root}/.github/skills/git-commit"
generic_skill_dir="${repo_root}/containers/control-plane/skills/repo-change-delivery"
generic_skill_file="${generic_skill_dir}/SKILL.md"
commit_skill_dir="${repo_root}/containers/control-plane/skills/git-commit"
commit_skill_file="${commit_skill_dir}/SKILL.md"
pull_request_skill_dir="${repo_root}/containers/control-plane/skills/pull-request-workflow"
pull_request_skill_file="${pull_request_skill_dir}/SKILL.md"
removed_rust_skill_dir="${repo_root}/containers/control-plane/skills/containerized-rust-ops"
removed_yamllint_skill_dir="${repo_root}/containers/control-plane/skills/containerized-yamllint-ops"
removed_control_plane_ops_dir="${repo_root}/containers/control-plane/skills/control-plane-operations"
removed_audit_analysis_dir="${repo_root}/containers/control-plane/skills/audit-log-analysis"
dockerfile_path="${repo_root}/containers/control-plane/Dockerfile"
entrypoint_path="${repo_root}/containers/control-plane/bin/control-plane-entrypoint"
control_plane_image="${CONTROL_PLANE_IMAGE_TAG:-localhost/control-plane:test}"
package_dir="$(mktemp -d)"
external_skill_dir="${package_dir}/external-skills"
doc_coauthor_skill_dir="${external_skill_dir}/doc-coauthoring"
doc_coauthor_skill_file="${doc_coauthor_skill_dir}/SKILL.md"
frontend_design_skill_dir="${external_skill_dir}/frontend-design"
frontend_design_skill_file="${frontend_design_skill_dir}/SKILL.md"
frontend_design_license_file="${frontend_design_skill_dir}/LICENSE.txt"
skill_creator_dir="${external_skill_dir}/skill-creator"
skill_creator_skill_file="${skill_creator_dir}/SKILL.md"
skill_creator_license_file="${skill_creator_dir}/LICENSE.txt"
doc_coauthor_package_file="${package_dir}/doc-coauthoring.skill"
frontend_design_package_file="${package_dir}/frontend-design.skill"
repo_package_file="${package_dir}/pr-fix-workflow.skill"
skill_creator_package_file="${package_dir}/skill-creator.skill"
generic_package_file="${package_dir}/repo-change-delivery.skill"
commit_package_file="${package_dir}/git-commit.skill"
pull_request_package_file="${package_dir}/pull-request-workflow.skill"

# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"

toolchain="$(detect_build_test_toolchain)"
container_bin="$(container_runtime_for_toolchain "${toolchain}")"

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

assert_path_absent() {
  local path="$1"

  [[ ! -e "${path}" ]] || {
    printf 'Did not expect path: %s\n' "${path}" >&2
    exit 1
  }
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

run_skill_creator_python() {
  "${container_bin}" run --rm --user "$(id -u):$(id -g)" \
    -e PYTHONDONTWRITEBYTECODE=1 \
    -v "${repo_root}:/workspace" \
    -v "${external_skill_dir}:/opt/external-skills:ro" \
    -w /opt/external-skills/skill-creator \
    --entrypoint python3 \
    "${control_plane_image}" \
    -m "$@"
}

package_skill_to_host() {
  local skill_path="$1"
  local package_path="$2"

  "${container_bin}" run --rm --user "$(id -u):$(id -g)" \
    -e PYTHONDONTWRITEBYTECODE=1 \
    -v "${repo_root}:/workspace" \
    -v "${external_skill_dir}:/opt/external-skills:ro" \
    -w /opt/external-skills/skill-creator \
    --entrypoint python3 \
    "${control_plane_image}" \
    -c 'import pathlib, subprocess, sys
skill_dir = pathlib.Path(sys.argv[1])
out_dir = pathlib.Path("/tmp") / f"{skill_dir.name}-package"
out_dir.mkdir(parents=True, exist_ok=True)
subprocess.run(
    ["python3", "-m", "scripts.package_skill", str(skill_dir), str(out_dir)],
    check=True,
    stdout=sys.stderr,
    stderr=sys.stderr,
)
sys.stdout.buffer.write((out_dir / f"{skill_dir.name}.skill").read_bytes())' \
    "${skill_path}" \
    > "${package_path}"
}

require_command "${container_bin}"
build_image_for_toolchain "${toolchain}" "${control_plane_image}" containers/control-plane

printf '%s\n' 'repo-change-delivery-skills-test: fetching pinned upstream skills' >&2
"${git_skills_manifest_installer}" "${external_skills_manifest}" "${external_skill_dir}"

printf '%s\n' 'repo-change-delivery-skills-test: checking skill files' >&2
assert_file_present "${external_skills_manifest}"
assert_file_present "${git_skills_runtime_manifest}"
assert_file_present "${git_skills_runtime_dispatch}"
assert_file_present "${git_skills_manifest_installer}"
assert_file_present "${doc_coauthor_skill_file}"
assert_file_present "${frontend_design_skill_file}"
assert_file_present "${frontend_design_license_file}"
assert_file_present "${repo_skill_file}"
assert_file_present "${repo_reference_file}"
assert_file_present "${skill_creator_skill_file}"
assert_file_present "${skill_creator_license_file}"
assert_file_present "${generic_skill_file}"
assert_file_present "${commit_skill_file}"
assert_file_present "${pull_request_skill_file}"
assert_file_present "${dockerfile_path}"
assert_file_present "${entrypoint_path}"
assert_path_absent "${legacy_external_skills_ref_file}"
assert_path_absent "${legacy_doc_coauthor_skill_dir}"
assert_path_absent "${legacy_skill_creator_dir}"
assert_path_absent "${repo_git_commit_dir}"
assert_path_absent "${legacy_yamllint_skill_dir}"
assert_path_absent "${removed_rust_skill_dir}"
assert_path_absent "${removed_yamllint_skill_dir}"
assert_path_absent "${removed_control_plane_ops_dir}"
assert_path_absent "${removed_audit_analysis_dir}"
assert_path_absent "${script_dir}/fetch-anthropic-skills.sh"
assert_path_absent "${script_dir}/install-git-skill.sh"
assert_path_absent "${repo_root}/containers/control-plane/bin/install-git-skills-from-manifest"
assert_path_absent "${repo_root}/containers/control-plane/bin/external-skills-manifest-to-tsv.mjs"

assert_file_contains "${doc_coauthor_skill_file}" 'name: doc-coauthoring'
assert_file_contains "${external_skills_manifest}" 'repository: https://github.com/anthropics/skills'
assert_file_contains "${external_skills_manifest}" 'repository: https://github.com/anthropics/claude-code'
assert_file_contains "${external_skills_manifest}" 'skills/doc-coauthoring'
assert_file_contains "${external_skills_manifest}" 'plugins/frontend-design/skills/frontend-design'
assert_file_contains "${external_skills_manifest}" 'skills/skill-creator'
assert_file_contains "${external_skills_manifest}" 'currentValue=main'
assert_file_contains "${git_skills_manifest_installer}" '/usr/local/bin/control-plane-runtime-tool'
assert_file_not_contains "${git_skills_manifest_installer}" 'cargo build --release'
assert_file_not_contains "${git_skills_manifest_installer}" 'CONTROL_PLANE_RUST_BUILD_IMAGE_TAG'
assert_file_contains "${git_skills_runtime_dispatch}" '"install-git-skills-from-manifest"'
assert_file_not_contains "${git_skills_runtime_dispatch}" 'js-yaml'
assert_file_contains "${frontend_design_skill_file}" 'name: frontend-design'
assert_file_contains "${skill_creator_skill_file}" 'name: skill-creator'
assert_file_contains "${generic_skill_file}" 'name: repo-change-delivery'
assert_file_contains "${generic_skill_file}" 'full implementation loop'
assert_file_contains "${generic_skill_file}" 'Perform pre-implementation investigation in this skill'
assert_file_contains "${generic_skill_file}" 'investigate requirements in this skill'
assert_file_contains "${generic_skill_file}" 'reuse it instead of restarting from scratch'
assert_file_contains "${generic_skill_file}" 'standalone investigation-only requests'
assert_file_contains "${generic_skill_file}" 'Do not skip this by immediately handing work to an implementation-focused sub-agent.'
assert_file_contains "${generic_skill_file}" 'prefer an implementation-focused agent'
assert_file_contains "${generic_skill_file}" 'non-main branch'
assert_file_contains "${generic_skill_file}" "\`git-commit\` and \`pull-request-workflow\`"
assert_file_contains "${generic_skill_file}" 'review-coordinator-agent'
assert_file_not_contains "${generic_skill_file}" 'CONTROL_PLANE_TOOLCHAIN=podman'
assert_file_contains "${commit_skill_file}" 'name: git-commit'
assert_file_contains "${commit_skill_file}" 'Conventional Commits'
assert_file_contains "${pull_request_skill_file}" 'name: pull-request-workflow'
assert_file_contains "${pull_request_skill_file}" 'Never open a duplicate pull request'
assert_file_contains "${repo_skill_file}" 'name: pr-fix-workflow'
assert_file_contains "${repo_skill_file}" './scripts/build-test.sh'
assert_file_not_contains "${repo_skill_file}" './scripts/lint.sh'
assert_file_contains "${repo_reference_file}" './scripts/test-repo-change-delivery-skills.sh'
assert_file_contains "${repo_reference_file}" './scripts/test-k8s-job.sh'
assert_file_contains "${repo_reference_file}" '.github/workflows/control-plane-ci.yml'
assert_file_contains "${repo_reference_file}" 'linter-service'
assert_file_not_contains "${repo_reference_file}" './scripts/lint.sh'
assert_file_contains "${dockerfile_path}" 'config/external-skills.yaml'
assert_file_contains "${dockerfile_path}" 'runtime-tools-builder'
assert_file_contains "${dockerfile_path}" '/usr/local/bin/install-git-skills-from-manifest'
assert_file_not_contains "${dockerfile_path}" 'external-skills-manifest-to-tsv.mjs'
assert_file_contains "${entrypoint_path}" 'install_bundled_control_plane_skills'

printf '%s\n' 'repo-change-delivery-skills-test: validating and packaging skills' >&2
run_skill_creator_python scripts.quick_validate /opt/external-skills/doc-coauthoring
run_skill_creator_python scripts.quick_validate /opt/external-skills/frontend-design
run_skill_creator_python scripts.quick_validate /workspace/containers/control-plane/skills/repo-change-delivery
run_skill_creator_python scripts.quick_validate /workspace/containers/control-plane/skills/git-commit
run_skill_creator_python scripts.quick_validate /workspace/containers/control-plane/skills/pull-request-workflow
run_skill_creator_python scripts.quick_validate /workspace/.github/skills/pr-fix-workflow
run_skill_creator_python scripts.quick_validate /opt/external-skills/skill-creator

package_skill_to_host /opt/external-skills/doc-coauthoring "${doc_coauthor_package_file}"
package_skill_to_host /opt/external-skills/frontend-design "${frontend_design_package_file}"
package_skill_to_host /workspace/.github/skills/pr-fix-workflow "${repo_package_file}"
package_skill_to_host /opt/external-skills/skill-creator "${skill_creator_package_file}"
package_skill_to_host /workspace/containers/control-plane/skills/repo-change-delivery "${generic_package_file}"
package_skill_to_host /workspace/containers/control-plane/skills/git-commit "${commit_package_file}"
package_skill_to_host /workspace/containers/control-plane/skills/pull-request-workflow "${pull_request_package_file}"

assert_file_present "${doc_coauthor_package_file}"
assert_file_present "${frontend_design_package_file}"
assert_file_present "${generic_package_file}"
assert_file_present "${commit_package_file}"
assert_file_present "${pull_request_package_file}"
assert_file_present "${repo_package_file}"
assert_file_present "${skill_creator_package_file}"

printf '%s\n' 'repo-change-delivery-skills-test: verifying bundled skills in image' >&2
# shellcheck disable=SC2016
"${container_bin}" run --rm \
  --entrypoint bash "${control_plane_image}" -lc '
set -euo pipefail
doc_root=/usr/local/share/control-plane/skills/doc-coauthoring
frontend_design_root=/usr/local/share/control-plane/skills/frontend-design
skill_creator_root=/usr/local/share/control-plane/skills/skill-creator
generic_root=/usr/local/share/control-plane/skills/repo-change-delivery
commit_root=/usr/local/share/control-plane/skills/git-commit
pull_request_root=/usr/local/share/control-plane/skills/pull-request-workflow
test -r "$doc_root/SKILL.md"
grep -Fqx "name: doc-coauthoring" "$doc_root/SKILL.md"
test -r "$frontend_design_root/SKILL.md"
test -r "$frontend_design_root/LICENSE.txt"
grep -Fqx "name: frontend-design" "$frontend_design_root/SKILL.md"
test -r "$skill_creator_root/SKILL.md"
test -r "$skill_creator_root/LICENSE.txt"
grep -Fqx "name: skill-creator" "$skill_creator_root/SKILL.md"
test -r "$generic_root/SKILL.md"
test -r "$commit_root/SKILL.md"
test -r "$pull_request_root/SKILL.md"
! test -e /usr/local/share/control-plane/skills/containerized-rust-ops
! test -e /usr/local/share/control-plane/skills/containerized-yamllint-ops
! test -e /usr/local/share/control-plane/skills/control-plane-operations
! test -e /usr/local/share/control-plane/skills/audit-log-analysis'

printf '%s\n' 'repo-change-delivery-skills-test: skills ok' >&2
