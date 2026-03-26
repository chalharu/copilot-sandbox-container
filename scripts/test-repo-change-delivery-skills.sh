#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
external_skills_manifest="${repo_root}/containers/control-plane/config/external-skills.yaml"
git_skills_manifest_installer_bin="${repo_root}/containers/control-plane/bin/install-git-skills-from-manifest"
git_skills_manifest_parser_js="${repo_root}/containers/control-plane/bin/external-skills-manifest-to-tsv.mjs"
git_skills_manifest_installer="${script_dir}/install-git-skills-from-manifest.sh"
legacy_external_skills_ref_file="${repo_root}/containers/control-plane/config/anthropic-skills.ref"
legacy_doc_coauthor_skill_dir="${repo_root}/.github/skills/doc-coauthoring"
legacy_yamllint_skill_dir="${repo_root}/.github/skills/containerized-yamllint-ops"
yamllint_skill_dir="${repo_root}/containers/control-plane/skills/containerized-yamllint-ops"
yamllint_skill_file="${yamllint_skill_dir}/SKILL.md"
yamllint_script_file="${yamllint_skill_dir}/scripts/podman-yamllint.sh"
repo_skill_dir="${repo_root}/.github/skills/pr-fix-workflow"
repo_skill_file="${repo_skill_dir}/SKILL.md"
repo_reference_file="${repo_skill_dir}/references/validation-and-delivery.md"
legacy_skill_creator_dir="${repo_root}/.github/skills/skill-creator"
repo_git_commit_dir="${repo_root}/.github/skills/git-commit"
generic_skill_dir="${repo_root}/containers/control-plane/skills/repo-change-delivery"
generic_skill_file="${generic_skill_dir}/SKILL.md"
rust_skill_dir="${repo_root}/containers/control-plane/skills/containerized-rust-ops"
rust_skill_file="${rust_skill_dir}/SKILL.md"
rust_runtime_reference_file="${rust_skill_dir}/references/runtime-quirks.md"
rust_podman_script_file="${rust_skill_dir}/scripts/podman-rust.sh"
rust_k8s_script_file="${rust_skill_dir}/scripts/k8s-rust.sh"
legacy_rust_sccache_image_dockerfile="${rust_skill_dir}/assets/sccache-image/Dockerfile"
sccache_image_dockerfile="${repo_root}/containers/sccache/Dockerfile"
audit_analysis_skill_dir="${repo_root}/containers/control-plane/skills/audit-log-analysis"
audit_analysis_skill_file="${audit_analysis_skill_dir}/SKILL.md"
audit_analysis_script_file="${audit_analysis_skill_dir}/scripts/audit-analysis.mjs"
commit_skill_dir="${repo_root}/containers/control-plane/skills/git-commit"
commit_skill_file="${commit_skill_dir}/SKILL.md"
pull_request_skill_dir="${repo_root}/containers/control-plane/skills/pull-request-workflow"
pull_request_skill_file="${pull_request_skill_dir}/SKILL.md"
control_plane_ops_skill_file="${repo_root}/containers/control-plane/skills/control-plane-operations/SKILL.md"
bundled_reference_file="${repo_root}/containers/control-plane/skills/control-plane-operations/references/skills.md"
dockerfile_path="${repo_root}/containers/control-plane/Dockerfile"
entrypoint_path="${repo_root}/containers/control-plane/bin/control-plane-entrypoint"
control_plane_image="${CONTROL_PLANE_IMAGE_TAG:-localhost/control-plane:test}"
package_dir="$(mktemp -d)"
external_skill_dir="${package_dir}/external-skills"
doc_coauthor_skill_dir="${external_skill_dir}/doc-coauthoring"
doc_coauthor_skill_file="${doc_coauthor_skill_dir}/SKILL.md"
skill_creator_dir="${external_skill_dir}/skill-creator"
skill_creator_skill_file="${skill_creator_dir}/SKILL.md"
skill_creator_license_file="${skill_creator_dir}/LICENSE.txt"
doc_coauthor_package_file="${package_dir}/doc-coauthoring.skill"
yamllint_package_file="${package_dir}/containerized-yamllint-ops.skill"
repo_package_file="${package_dir}/pr-fix-workflow.skill"
skill_creator_package_file="${package_dir}/skill-creator.skill"
generic_package_file="${package_dir}/repo-change-delivery.skill"
rust_package_file="${package_dir}/containerized-rust-ops.skill"
audit_analysis_package_file="${package_dir}/audit-log-analysis.skill"
commit_package_file="${package_dir}/git-commit.skill"
pull_request_package_file="${package_dir}/pull-request-workflow.skill"
backtick='`'

# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"

toolchain="$(detect_build_test_toolchain)"
container_bin="$(container_runtime_for_toolchain "${toolchain}")"
yamllint_image="${CONTROL_PLANE_YAMLLINT_IMAGE_TAG:-localhost/yamllint:test}"
sccache_image="${CONTROL_PLANE_SCCACHE_IMAGE_TAG:-localhost/sccache:test}"

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
    "${yamllint_image}" \
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
    "${yamllint_image}" \
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

printf '%s\n' 'repo-change-delivery-skills-test: fetching pinned upstream skills' >&2
"${git_skills_manifest_installer}" "${external_skills_manifest}" "${external_skill_dir}"

printf '%s\n' 'repo-change-delivery-skills-test: checking skill files' >&2
assert_file_present "${external_skills_manifest}"
assert_file_present "${git_skills_manifest_installer_bin}"
assert_file_present "${git_skills_manifest_parser_js}"
assert_file_present "${git_skills_manifest_installer}"
assert_file_present "${doc_coauthor_skill_file}"
assert_file_present "${yamllint_skill_file}"
assert_file_present "${yamllint_script_file}"
assert_file_present "${repo_skill_file}"
assert_file_present "${repo_reference_file}"
assert_file_present "${skill_creator_skill_file}"
assert_file_present "${skill_creator_license_file}"
assert_file_present "${generic_skill_file}"
assert_file_present "${rust_skill_file}"
assert_file_present "${rust_runtime_reference_file}"
assert_file_present "${rust_podman_script_file}"
assert_file_present "${rust_k8s_script_file}"
assert_file_present "${audit_analysis_skill_file}"
assert_file_present "${audit_analysis_script_file}"
assert_file_present "${sccache_image_dockerfile}"
assert_file_present "${commit_skill_file}"
assert_file_present "${pull_request_skill_file}"
assert_file_present "${control_plane_ops_skill_file}"
assert_file_present "${bundled_reference_file}"
assert_file_present "${dockerfile_path}"
assert_file_present "${entrypoint_path}"
assert_file_absent "${legacy_external_skills_ref_file}"
assert_file_absent "${legacy_doc_coauthor_skill_dir}"
assert_file_absent "${legacy_skill_creator_dir}"
assert_file_absent "${script_dir}/fetch-anthropic-skills.sh"
assert_file_absent "${script_dir}/install-git-skill.sh"
assert_file_absent "${repo_git_commit_dir}"
assert_file_absent "${legacy_yamllint_skill_dir}"
assert_file_absent "${legacy_rust_sccache_image_dockerfile}"
assert_file_absent "${repo_root}/containers/garage"
assert_file_absent "${generic_skill_dir}/scripts/example.py"
assert_file_absent "${generic_skill_dir}/references/api_reference.md"
assert_file_absent "${generic_skill_dir}/assets/example_asset.txt"

assert_file_contains "${doc_coauthor_skill_file}" 'name: doc-coauthoring'
assert_file_contains "${external_skills_manifest}" 'repository: https://github.com/anthropics/skills'
assert_file_contains "${external_skills_manifest}" 'skills/doc-coauthoring'
assert_file_contains "${external_skills_manifest}" 'skills/skill-creator'
assert_file_contains "${external_skills_manifest}" 'currentValue=main'
assert_file_contains "${git_skills_manifest_installer_bin}" 'depName=js-yaml'
assert_file_contains "${git_skills_manifest_installer_bin}" "npm exec --yes --package \"js-yaml@\${js_yaml_version}\""
assert_file_not_contains "${git_skills_manifest_installer_bin}" "awk '"
assert_file_contains "${yamllint_skill_file}" 'name: containerized-yamllint-ops'
assert_file_contains "${yamllint_skill_file}" 'containers/control-plane/skills/containerized-yamllint-ops/scripts/podman-yamllint.sh'
assert_file_contains "${yamllint_skill_file}" 'localhost/yamllint:test'
assert_file_contains "${skill_creator_skill_file}" 'name: skill-creator'
assert_file_contains "${generic_skill_file}" 'name: repo-change-delivery'
assert_file_contains "${generic_skill_file}" 'full implementation loop'
assert_file_contains "${generic_skill_file}" 'non-main branch'
assert_file_contains "${generic_skill_file}" 'repo-local delivery or validation skill'
assert_file_contains "${generic_skill_file}" "\`git-commit\` and \`pull-request-workflow\`"
assert_file_not_contains "${generic_skill_file}" 'CONTROL_PLANE_TOOLCHAIN=podman'
assert_file_not_contains "${generic_skill_file}" '.github/workflows/control-plane-ci.yml'
assert_file_not_contains "${generic_skill_file}" './scripts/test-k8s-job.sh'
assert_file_contains "${rust_skill_file}" 'name: containerized-rust-ops'
assert_file_contains "${rust_skill_file}" 'containers/sccache/Dockerfile'
assert_file_contains "${rust_skill_file}" 'dxflrs/garage:v2.2.0'
assert_file_contains "${rust_podman_script_file}" '/containers/sccache'
assert_file_contains "${rust_podman_script_file}" 'sccache.context-sha256'
assert_file_contains "${rust_podman_script_file}" 'CONTAINERIZED_RUST_CONTAINER_BIN'
assert_file_contains "${rust_podman_script_file}" "\"\${container_cmd[@]}\" cp \"\${container_id}:/usr/local/bin/sccache\" \"\${sccache_binary}\""
assert_file_contains "${rust_podman_script_file}" "-w \"\${workdir_container}\""
assert_file_not_contains "${rust_podman_script_file}" 'assets/sccache-image'
assert_file_not_contains "${rust_podman_script_file}" '--entrypoint cat'
assert_file_not_contains "${rust_skill_file}" '.github/skills/containerized-rust-ops'
assert_file_not_contains "${rust_skill_file}" 'assets/sccache-image/Dockerfile'
assert_file_contains "${rust_runtime_reference_file}" 'containers/sccache/'
assert_file_contains "${rust_runtime_reference_file}" 'dxflrs/garage:v2.2.0'
assert_file_not_contains "${rust_runtime_reference_file}" 'assets/sccache-image/'
assert_file_not_contains "${rust_runtime_reference_file}" '.copilot-cache'
assert_file_contains "${audit_analysis_skill_file}" 'name: audit-log-analysis'
assert_file_contains "${audit_analysis_skill_file}" 'wrapping up a task'
assert_file_contains "${audit_analysis_script_file}" 'automation_candidates'
assert_file_contains "${audit_analysis_script_file}" 'controlPlane.auditAnalysis'

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
assert_file_not_contains "${repo_reference_file}" 'install-git-skill.sh'
assert_file_not_contains "${repo_reference_file}" 'install-git-skills-from-manifest.sh'

assert_file_contains "${control_plane_ops_skill_file}" 'scripts/install-git-skills-from-manifest.sh'
assert_file_not_contains "${control_plane_ops_skill_file}" '.github/skills/skill-creator/scripts/package_skill.py'

assert_file_contains "${bundled_reference_file}" "${backtick}containerized-yamllint-ops${backtick}"
assert_file_contains "${bundled_reference_file}" "${backtick}containerized-rust-ops${backtick}"
assert_file_contains "${bundled_reference_file}" "${backtick}audit-log-analysis${backtick}"
assert_file_contains "${bundled_reference_file}" "${backtick}doc-coauthoring${backtick}"
assert_file_contains "${bundled_reference_file}" "${backtick}git-commit${backtick}"
assert_file_contains "${bundled_reference_file}" "${backtick}pull-request-workflow${backtick}"
assert_file_contains "${bundled_reference_file}" "${backtick}skill-creator${backtick}"
assert_file_contains "${bundled_reference_file}" 'scripts/install-git-skills-from-manifest.sh'
assert_file_not_contains "${bundled_reference_file}" '.github/skills/skill-creator/scripts/package_skill.py'

assert_file_contains "${dockerfile_path}" 'config/external-skills.yaml'
assert_file_contains "${dockerfile_path}" 'install-git-skills-from-manifest'
assert_file_contains "${dockerfile_path}" 'external-skills-manifest-to-tsv.mjs'
assert_file_not_contains "${dockerfile_path}" 'ANTHROPIC_SKILLS_REPOSITORY'
assert_file_not_contains "${dockerfile_path}" 'DOC_COAUTHORING_SKILL_PATH'
assert_file_not_contains "${dockerfile_path}" 'SKILL_CREATOR_SKILL_PATH'
assert_file_not_contains "${dockerfile_path}" 'config/anthropic-skills.ref'
assert_file_contains "${entrypoint_path}" 'install_bundled_control_plane_skills'
assert_file_contains "${entrypoint_path}" "for source_dir in \"\${bundled_skills_dir}\"/*; do"

printf '%s\n' 'repo-change-delivery-skills-test: validating and packaging skills' >&2
build_image_for_toolchain "${toolchain}" "${yamllint_image}" containers/yamllint
build_image_for_toolchain "${toolchain}" "${sccache_image}" containers/sccache
build_image_for_toolchain "${toolchain}" "${control_plane_image}" containers/control-plane

run_skill_creator_python scripts.quick_validate /opt/external-skills/doc-coauthoring
run_skill_creator_python scripts.quick_validate /workspace/containers/control-plane/skills/containerized-yamllint-ops
run_skill_creator_python scripts.quick_validate /workspace/containers/control-plane/skills/repo-change-delivery
run_skill_creator_python scripts.quick_validate /workspace/containers/control-plane/skills/containerized-rust-ops
run_skill_creator_python scripts.quick_validate /workspace/containers/control-plane/skills/audit-log-analysis
run_skill_creator_python scripts.quick_validate /workspace/containers/control-plane/skills/git-commit
run_skill_creator_python scripts.quick_validate /workspace/containers/control-plane/skills/pull-request-workflow
run_skill_creator_python scripts.quick_validate /workspace/.github/skills/pr-fix-workflow
run_skill_creator_python scripts.quick_validate /opt/external-skills/skill-creator

package_skill_to_host /opt/external-skills/doc-coauthoring "${doc_coauthor_package_file}"
package_skill_to_host /workspace/containers/control-plane/skills/containerized-yamllint-ops "${yamllint_package_file}"
package_skill_to_host /workspace/.github/skills/pr-fix-workflow "${repo_package_file}"
package_skill_to_host /opt/external-skills/skill-creator "${skill_creator_package_file}"
package_skill_to_host /workspace/containers/control-plane/skills/repo-change-delivery "${generic_package_file}"
package_skill_to_host /workspace/containers/control-plane/skills/containerized-rust-ops "${rust_package_file}"
package_skill_to_host /workspace/containers/control-plane/skills/audit-log-analysis "${audit_analysis_package_file}"
package_skill_to_host /workspace/containers/control-plane/skills/git-commit "${commit_package_file}"
package_skill_to_host /workspace/containers/control-plane/skills/pull-request-workflow "${pull_request_package_file}"

assert_file_present "${doc_coauthor_package_file}"
assert_file_present "${yamllint_package_file}"
assert_file_present "${generic_package_file}"
assert_file_present "${rust_package_file}"
assert_file_present "${audit_analysis_package_file}"
assert_file_present "${commit_package_file}"
assert_file_present "${pull_request_package_file}"
assert_file_present "${repo_package_file}"
assert_file_present "${skill_creator_package_file}"

# shellcheck disable=SC2016
"${container_bin}" run --rm --entrypoint bash "${control_plane_image}" -lc '
set -euo pipefail
doc_root=/usr/local/share/control-plane/skills/doc-coauthoring
skill_creator_root=/usr/local/share/control-plane/skills/skill-creator
audit_analysis_root=/usr/local/share/control-plane/skills/audit-log-analysis
test -r "$doc_root/SKILL.md"
grep -Fqx "name: doc-coauthoring" "$doc_root/SKILL.md"
test -r "$skill_creator_root/SKILL.md"
test -r "$skill_creator_root/LICENSE.txt"
grep -Fqx "name: skill-creator" "$skill_creator_root/SKILL.md"
test -r "$audit_analysis_root/SKILL.md"
test -r "$audit_analysis_root/scripts/audit-analysis.mjs"
grep -Fqx "name: audit-log-analysis" "$audit_analysis_root/SKILL.md"'

printf '%s\n' 'repo-change-delivery-skills-test: skills ok' >&2
