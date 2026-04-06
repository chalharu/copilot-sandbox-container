#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
workdir="$(mktemp -d)"

# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"

cleanup() {
  rm -rf "${workdir}"
}
trap cleanup EXIT

assert_file_contains() {
  local path="$1"
  local expected="$2"

  grep -Fq -- "${expected}" "${path}" || {
    printf 'Expected %s to contain: %s\n' "${path}" "${expected}" >&2
    exit 1
  }
}

assert_file_matches() {
  local path="$1"
  local expected_pattern="$2"

  grep -Eq -- "${expected_pattern}" "${path}" || {
    printf 'Expected %s to match: %s\n' "${path}" "${expected_pattern}" >&2
    exit 1
  }
}

assert_file_not_matches() {
  local path="$1"
  local unexpected_pattern="$2"

  if grep -Eq -- "${unexpected_pattern}" "${path}"; then
    printf 'Did not expect %s to match: %s\n' "${path}" "${unexpected_pattern}" >&2
    exit 1
  fi
}

assert_file_not_contains() {
  local path="$1"
  local unexpected="$2"

  if grep -Fq -- "${unexpected}" "${path}"; then
    printf 'Did not expect %s to contain: %s\n' "${path}" "${unexpected}" >&2
    exit 1
  fi
}

assert_line_order() {
  local path="$1"
  local earlier="$2"
  local later="$3"
  local earlier_line
  local later_line

  earlier_line="$(grep -nF -- "${earlier}" "${path}" | head -n 1 | cut -d: -f1 || true)"
  later_line="$(grep -nF -- "${later}" "${path}" | head -n 1 | cut -d: -f1 || true)"

  if [[ -z "${earlier_line}" ]] || [[ -z "${later_line}" ]] || [[ "${later_line}" -le "${earlier_line}" ]]; then
    printf 'Expected %s to contain %s before %s\n' "${path}" "${earlier}" "${later}" >&2
    exit 1
  fi
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

context_dir="${workdir}/context"
fake_bin_dir="${workdir}/fake-bin"
docker_log="${workdir}/docker.log"
label_store="${workdir}/docker-label"
workflow_path="${repo_root}/.github/workflows/control-plane-ci.yml"
renovate_config_path="${repo_root}/renovate.json5"
sccache_dockerfile_path="${repo_root}/containers/sccache/Dockerfile"
legacy_execution_plane_go_dockerfile_path="${repo_root}/containers/execution-plane-go/Dockerfile"
legacy_execution_plane_node_dockerfile_path="${repo_root}/containers/execution-plane-node/Dockerfile"
legacy_execution_plane_python_dockerfile_path="${repo_root}/containers/execution-plane-python/Dockerfile"
legacy_execution_plane_rust_dockerfile_path="${repo_root}/containers/execution-plane-rust/Dockerfile"
legacy_yamllint_dockerfile_path="${repo_root}/containers/yamllint/Dockerfile"
mkdir -p "${context_dir}" "${fake_bin_dir}"
cat > "${context_dir}/Dockerfile" <<'EOF'
FROM docker.io/library/busybox:1.37.0
RUN printf '%s\n' base > /image.txt
EOF

cat > "${fake_bin_dir}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${TEST_IMAGE_MAINTENANCE_DOCKER_LOG:?}"

if [[ "$#" -ge 2 ]] && [[ "$1" == "image" ]] && [[ "$2" == "inspect" ]]; then
  if [[ -f "${TEST_IMAGE_MAINTENANCE_LABEL_STORE:?}" ]]; then
    cat "${TEST_IMAGE_MAINTENANCE_LABEL_STORE:?}"
    exit 0
  fi
  exit 1
fi

if [[ "$#" -ge 2 ]] && [[ "$1" == "buildx" ]] && [[ "$2" == "build" ]]; then
  label_value=""
  previous=""
  for arg in "$@"; do
    if [[ "${previous}" == "--label" ]]; then
      label_value="${arg#*=}"
      break
    fi
    previous="${arg}"
  done
  [[ -n "${label_value}" ]] || {
    printf 'missing --label in fake docker buildx build\n' >&2
    exit 1
  }
  printf '%s\n' "${label_value}" > "${TEST_IMAGE_MAINTENANCE_LABEL_STORE:?}"
  exit 0
fi

printf 'unexpected fake docker invocation: %s\n' "$*" >&2
exit 1
EOF
chmod +x "${fake_bin_dir}/docker"

export PATH="${fake_bin_dir}:${PATH}"
export TEST_IMAGE_MAINTENANCE_DOCKER_LOG="${docker_log}"
export TEST_IMAGE_MAINTENANCE_LABEL_STORE="${label_store}"

printf '%s\n' 'image-maintenance-test: verifying unchanged build contexts are reused' >&2
first_hash="$(build_context_hash "${context_dir}")"
build_image_for_toolchain docker localhost/image-maintenance:test "${context_dir}"
grep -Fq "buildx build --load --label $(build_context_hash_label_key)=${first_hash} -t localhost/image-maintenance:test ${context_dir}" "${docker_log}"

build_lines_before="$(grep -c '^buildx build ' "${docker_log}")"
build_image_for_toolchain docker localhost/image-maintenance:test "${context_dir}"
build_lines_after="$(grep -c '^buildx build ' "${docker_log}")"
[[ "${build_lines_before}" -eq "${build_lines_after}" ]]

printf '%s\n' 'image-maintenance-test: verifying changed build contexts trigger rebuilds' >&2
printf '%s\n' 'RUN printf "%s\n" changed >> /image.txt' >> "${context_dir}/Dockerfile"
second_hash="$(build_context_hash "${context_dir}")"
build_image_for_toolchain docker localhost/image-maintenance:test "${context_dir}"
[[ "${first_hash}" != "${second_hash}" ]]
grep -Fq "buildx build --load --label $(build_context_hash_label_key)=${second_hash} -t localhost/image-maintenance:test ${context_dir}" "${docker_log}"

printf '%s\n' 'image-maintenance-test: verifying helper image release wiring' >&2
assert_file_contains "${sccache_dockerfile_path}" 'FROM docker.io/library/alpine:3.23.3@sha256:25109184c71bdad752c8312a8623239686a9a2071e8825f20acb8f2198c3f659 AS fetcher'
assert_file_contains "${sccache_dockerfile_path}" 'FROM scratch'
assert_file_contains "${sccache_dockerfile_path}" 'COPY --from=fetcher /out/ /'
assert_file_contains "${sccache_dockerfile_path}" 'USER 65532:65532'
assert_file_contains "${sccache_dockerfile_path}" 'ENTRYPOINT ["/usr/local/bin/sccache"]'

printf '%s\n' 'image-maintenance-test: verifying legacy helper images were removed' >&2
[[ ! -e "${legacy_execution_plane_go_dockerfile_path}" ]]
[[ ! -e "${legacy_execution_plane_node_dockerfile_path}" ]]
[[ ! -e "${legacy_execution_plane_python_dockerfile_path}" ]]
[[ ! -e "${legacy_execution_plane_rust_dockerfile_path}" ]]
[[ ! -e "${legacy_yamllint_dockerfile_path}" ]]

sccache_changes_block="$(job_block sccache-changes)"
publish_block="$(job_block publish-architecture-images)"
manifest_block="$(job_block publish-manifests)"

[[ -n "${sccache_changes_block}" ]] || {
  printf 'Expected sccache-changes job in %s\n' "${workflow_path}" >&2
  exit 1
}
[[ -n "${publish_block}" ]] || {
  printf 'Expected publish-architecture-images job in %s\n' "${workflow_path}" >&2
  exit 1
}
[[ -n "${manifest_block}" ]] || {
  printf 'Expected publish-manifests job in %s\n' "${workflow_path}" >&2
  exit 1
}

assert_block_contains "${sccache_changes_block}" 'fetch-depth: 0' 'sccache-changes job block'
assert_block_contains "${sccache_changes_block}" "sccache_changed=\"\$(changed_in_range containers/sccache)\"" 'sccache-changes job block'
assert_block_contains "${sccache_changes_block}" "printf 'sccache_changed=%s\\n' \"\${sccache_changed}\"" 'sccache-changes job block'

assert_block_contains "${publish_block}" '- sccache-changes' 'publish-architecture-images job block'
assert_block_contains "${publish_block}" "if: needs.sccache-changes.outputs.sccache_changed == 'true'" 'publish-architecture-images job block'
assert_block_contains "${publish_block}" "PUBLISH_SCCACHE: \${{ needs.sccache-changes.outputs.sccache_changed }}" 'publish-architecture-images job block'
assert_block_contains "${publish_block}" "CONTROL_PLANE_COMPONENT_TAG: \${{ steps.image_versions.outputs.control_plane_component_tag }}" 'publish-architecture-images job block'
assert_block_contains "${publish_block}" "SCCACHE_COMPONENT_TAG: \${{ steps.image_versions.outputs.sccache_component_tag }}" 'publish-architecture-images job block'
assert_block_contains "${publish_block}" "if [[ \"\${PUBLISH_SCCACHE}\" == \"true\" ]]; then" 'publish-architecture-images job block'

assert_block_contains "${manifest_block}" '- sccache-changes' 'publish-manifests job block'
assert_block_contains "${manifest_block}" "PUBLISH_SCCACHE: \${{ needs.sccache-changes.outputs.sccache_changed }}" 'publish-manifests job block'
assert_block_contains "${manifest_block}" "CONTROL_PLANE_COMPONENT_TAG: \${{ steps.image_versions.outputs.control_plane_component_tag }}" 'publish-manifests job block'
assert_block_contains "${manifest_block}" "SCCACHE_COMPONENT_TAG: \${{ steps.image_versions.outputs.sccache_component_tag }}" 'publish-manifests job block'
assert_block_contains "${manifest_block}" "if [[ \"\${PUBLISH_SCCACHE}\" == \"true\" ]]; then" 'publish-manifests job block'

assert_file_contains "${workflow_path}" 'docker buildx build --load --tag localhost/sccache:test containers/sccache'
assert_file_contains "${workflow_path}" "GHCR_SCCACHE_IMAGE: ghcr.io/\${{ github.repository }}/sccache"
assert_file_contains "${workflow_path}" "docker tag localhost/sccache:test \"\${GHCR_SCCACHE_IMAGE}:\${GITHUB_SHA}-\${IMAGE_ARCH}\""
assert_file_contains "${workflow_path}" "docker push \"\${GHCR_SCCACHE_IMAGE}:\${SCCACHE_COMPONENT_TAG}-\${IMAGE_ARCH}\""
assert_file_contains "${workflow_path}" "create_manifest \"\${GHCR_SCCACHE_IMAGE}:latest\""
assert_file_contains "${workflow_path}" "create_manifest \"\${GHCR_SCCACHE_IMAGE}:\${SCCACHE_COMPONENT_TAG}\""
assert_file_matches "${workflow_path}" '^[[:space:]]+- sccache$'
assert_file_contains "${renovate_config_path}" '/^containers\\/(control-plane|sccache)\\/Dockerfile$/'
assert_file_contains "${renovate_config_path}" 'separateMultipleMajor: true'
assert_file_contains "${renovate_config_path}" 'separateMultipleMinor: true'
assert_file_contains "${renovate_config_path}" '"{{{depNameSanitized}}}{{#if newVersion}}__v{{{newVersion}}}{{/if}}{{#if newDigestShort}}__d{{{newDigestShort}}}{{/if}}",'
assert_file_not_contains "${renovate_config_path}" '__{{updateType}}'
assert_file_not_contains "${workflow_path}" 'garage_changed'
assert_file_not_contains "${workflow_path}" 'garage_bootstrap_changed'
assert_file_not_matches "${workflow_path}" 'containers/garage([[:space:]/]|$)'
assert_file_not_contains "${workflow_path}" 'containers/garage-bootstrap'
assert_file_not_contains "${workflow_path}" 'GHCR_GARAGE_IMAGE'
assert_file_not_contains "${workflow_path}" 'GHCR_GARAGE_BOOTSTRAP_IMAGE'
assert_file_not_contains "${workflow_path}" 'PUBLISH_GARAGE:'
assert_file_not_contains "${workflow_path}" 'PUBLISH_GARAGE_BOOTSTRAP'
assert_file_not_contains "${workflow_path}" 'garage_component_tag'
assert_file_not_contains "${workflow_path}" 'garage_bootstrap_component_tag'
assert_file_not_contains "${workflow_path}" 'localhost/garage:test'
assert_file_not_contains "${workflow_path}" 'localhost/garage-bootstrap:test'
assert_file_not_matches "${workflow_path}" '^[[:space:]]+- garage$'
assert_file_not_matches "${workflow_path}" '^[[:space:]]+- garage-bootstrap$'
assert_file_not_contains "${renovate_config_path}" 'garage-bootstrap'
assert_file_not_contains "${workflow_path}" 'helper-image-changes'
assert_file_not_contains "${workflow_path}" 'yamllint_changed'
assert_file_not_contains "${workflow_path}" 'GHCR_YAMLLINT_IMAGE'
assert_file_not_contains "${workflow_path}" 'localhost/yamllint:test'
assert_file_not_contains "${renovate_config_path}" 'yamllint'

printf '%s\n' 'image-maintenance-test: verifying GHCR cleanup keeps tagged images' >&2
assert_file_contains "${workflow_path}" 'delete-only-untagged-versions: '\''true'\'''

printf '%s\n' 'image-maintenance-test: maintenance workflows ok' >&2
