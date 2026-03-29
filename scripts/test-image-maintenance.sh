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
podman_log="${workdir}/podman.log"
label_store="${workdir}/podman-label"
workflow_path="${repo_root}/.github/workflows/control-plane-ci.yml"
renovate_config_path="${repo_root}/renovate.json5"
sccache_dockerfile_path="${repo_root}/containers/sccache/Dockerfile"
mkdir -p "${context_dir}" "${fake_bin_dir}"
cat > "${context_dir}/Dockerfile" <<'EOF'
FROM docker.io/library/busybox:1.37.0
RUN printf '%s\n' base > /image.txt
EOF

cat > "${fake_bin_dir}/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${TEST_IMAGE_MAINTENANCE_PODMAN_LOG:?}"

if [[ "$#" -ge 2 ]] && [[ "$1" == "image" ]] && [[ "$2" == "inspect" ]]; then
  if [[ -f "${TEST_IMAGE_MAINTENANCE_LABEL_STORE:?}" ]]; then
    cat "${TEST_IMAGE_MAINTENANCE_LABEL_STORE:?}"
    exit 0
  fi
  exit 1
fi

if [[ "$#" -ge 1 ]] && [[ "$1" == "build" ]]; then
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
    printf 'missing --label in fake podman build\n' >&2
    exit 1
  }
  printf '%s\n' "${label_value}" > "${TEST_IMAGE_MAINTENANCE_LABEL_STORE:?}"
  exit 0
fi

printf 'unexpected fake podman invocation: %s\n' "$*" >&2
exit 1
EOF
chmod +x "${fake_bin_dir}/podman"

export PATH="${fake_bin_dir}:${PATH}"
export TEST_IMAGE_MAINTENANCE_PODMAN_LOG="${podman_log}"
export TEST_IMAGE_MAINTENANCE_LABEL_STORE="${label_store}"
export CONTROL_PLANE_LOCAL_PODMAN_MODE=rootful-service

printf '%s\n' 'image-maintenance-test: verifying unchanged build contexts are reused' >&2
first_hash="$(build_context_hash "${context_dir}")"
build_image_for_toolchain podman localhost/image-maintenance:test "${context_dir}"
grep -Fq "build --isolation=chroot --label $(build_context_hash_label_key)=${first_hash} --tag localhost/image-maintenance:test ${context_dir}" "${podman_log}"

build_lines_before="$(grep -c '^build ' "${podman_log}")"
build_image_for_toolchain podman localhost/image-maintenance:test "${context_dir}"
build_lines_after="$(grep -c '^build ' "${podman_log}")"
[[ "${build_lines_before}" -eq "${build_lines_after}" ]]

printf '%s\n' 'image-maintenance-test: verifying changed build contexts trigger rebuilds' >&2
printf '%s\n' 'RUN printf "%s\n" changed >> /image.txt' >> "${context_dir}/Dockerfile"
second_hash="$(build_context_hash "${context_dir}")"
build_image_for_toolchain podman localhost/image-maintenance:test "${context_dir}"
[[ "${first_hash}" != "${second_hash}" ]]
grep -Fq "build --isolation=chroot --label $(build_context_hash_label_key)=${second_hash} --tag localhost/image-maintenance:test ${context_dir}" "${podman_log}"

printf '%s\n' 'image-maintenance-test: verifying helper image release wiring' >&2
assert_file_contains "${sccache_dockerfile_path}" 'FROM docker.io/library/alpine:3.23.3@sha256:25109184c71bdad752c8312a8623239686a9a2071e8825f20acb8f2198c3f659 AS fetcher'
assert_file_contains "${sccache_dockerfile_path}" 'FROM scratch'
assert_file_contains "${sccache_dockerfile_path}" 'COPY --from=fetcher /out/ /'
assert_file_contains "${sccache_dockerfile_path}" 'USER 65532:65532'
assert_file_contains "${sccache_dockerfile_path}" 'ENTRYPOINT ["/usr/local/bin/sccache"]'

helper_image_changes_block="$(job_block helper-image-changes)"
publish_block="$(job_block publish-architecture-images)"
manifest_block="$(job_block publish-manifests)"

[[ -n "${helper_image_changes_block}" ]] || {
  printf 'Expected helper-image-changes job in %s\n' "${workflow_path}" >&2
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

assert_block_contains "${helper_image_changes_block}" 'fetch-depth: 0' 'helper-image-changes job block'
assert_block_contains "${helper_image_changes_block}" "yamllint_changed=\"\$(changed_in_range containers/yamllint)\"" 'helper-image-changes job block'
assert_block_contains "${helper_image_changes_block}" "sccache_changed=\"\$(changed_in_range containers/sccache)\"" 'helper-image-changes job block'
assert_block_contains "${helper_image_changes_block}" "printf 'yamllint_changed=%s\\n' \"\${yamllint_changed}\" >> \"\${GITHUB_OUTPUT}\"" 'helper-image-changes job block'
assert_block_contains "${helper_image_changes_block}" "printf 'sccache_changed=%s\\n' \"\${sccache_changed}\" >> \"\${GITHUB_OUTPUT}\"" 'helper-image-changes job block'

assert_block_contains "${publish_block}" '- helper-image-changes' 'publish-architecture-images job block'
assert_block_contains "${publish_block}" "if: needs.helper-image-changes.outputs.yamllint_changed == 'true'" 'publish-architecture-images job block'
assert_block_contains "${publish_block}" "if: needs.helper-image-changes.outputs.sccache_changed == 'true'" 'publish-architecture-images job block'
assert_block_contains "${publish_block}" "PUBLISH_YAMLLINT: \${{ needs.helper-image-changes.outputs.yamllint_changed }}" 'publish-architecture-images job block'
assert_block_contains "${publish_block}" "PUBLISH_SCCACHE: \${{ needs.helper-image-changes.outputs.sccache_changed }}" 'publish-architecture-images job block'
assert_block_contains "${publish_block}" "if [[ \"\${PUBLISH_YAMLLINT}\" == \"true\" ]]; then" 'publish-architecture-images job block'
assert_block_contains "${publish_block}" "if [[ \"\${PUBLISH_SCCACHE}\" == \"true\" ]]; then" 'publish-architecture-images job block'

assert_block_contains "${manifest_block}" '- helper-image-changes' 'publish-manifests job block'
assert_block_contains "${manifest_block}" "PUBLISH_YAMLLINT: \${{ needs.helper-image-changes.outputs.yamllint_changed }}" 'publish-manifests job block'
assert_block_contains "${manifest_block}" "PUBLISH_SCCACHE: \${{ needs.helper-image-changes.outputs.sccache_changed }}" 'publish-manifests job block'
assert_block_contains "${manifest_block}" "if [[ \"\${PUBLISH_YAMLLINT}\" == \"true\" ]]; then" 'publish-manifests job block'
assert_block_contains "${manifest_block}" "if [[ \"\${PUBLISH_SCCACHE}\" == \"true\" ]]; then" 'publish-manifests job block'

assert_file_contains "${workflow_path}" 'podman build --tag localhost/sccache:test containers/sccache'
assert_file_contains "${workflow_path}" "GHCR_SCCACHE_IMAGE: ghcr.io/\${{ github.repository }}/sccache"
assert_file_contains "${workflow_path}" "podman tag localhost/sccache:test \"\${GHCR_SCCACHE_IMAGE}:\${GITHUB_SHA}-\${IMAGE_ARCH}\""
assert_file_contains "${workflow_path}" "podman push \"\${GHCR_SCCACHE_IMAGE}:\${{ steps.image_versions.outputs.sccache_component_tag }}-\${IMAGE_ARCH}\""
assert_file_contains "${workflow_path}" "create_manifest \"localhost/sccache:manifest-latest\" \"\${GHCR_SCCACHE_IMAGE}:latest\""
assert_file_contains "${workflow_path}" "create_manifest \"localhost/sccache:manifest-version\" \"\${GHCR_SCCACHE_IMAGE}:\${{ steps.image_versions.outputs.sccache_component_tag }}\""
assert_file_matches "${workflow_path}" '^[[:space:]]+- sccache$'
assert_file_contains "${renovate_config_path}" '/^containers\\/(control-plane|yamllint|sccache)\\/Dockerfile$/'
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

printf '%s\n' 'image-maintenance-test: verifying GHCR cleanup keeps tagged images' >&2
assert_file_contains "${workflow_path}" 'delete-only-untagged-versions: '\''true'\'''

printf '%s\n' 'image-maintenance-test: maintenance workflows ok' >&2
