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

context_dir="${workdir}/context"
fake_bin_dir="${workdir}/fake-bin"
podman_log="${workdir}/podman.log"
label_store="${workdir}/podman-label"
workflow_path="${repo_root}/.github/workflows/control-plane-ci.yml"
renovate_config_path="${repo_root}/renovate.json5"
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

printf '%s\n' 'image-maintenance-test: verifying sccache helper image release wiring' >&2
assert_file_contains "${workflow_path}" 'podman build --tag localhost/sccache:test containers/control-plane/skills/containerized-rust-ops/assets/sccache-image'
assert_file_contains "${workflow_path}" "GHCR_SCCACHE_IMAGE: ghcr.io/\${{ github.repository }}/sccache"
assert_file_contains "${workflow_path}" "podman tag localhost/sccache:test \"\${GHCR_SCCACHE_IMAGE}:\${GITHUB_SHA}-\${IMAGE_ARCH}\""
assert_file_contains "${workflow_path}" "podman push \"\${GHCR_SCCACHE_IMAGE}:\${{ steps.image_versions.outputs.sccache_component_tag }}-\${IMAGE_ARCH}\""
assert_file_contains "${workflow_path}" "create_manifest \"localhost/sccache:manifest-latest\" \"\${GHCR_SCCACHE_IMAGE}:latest\""
assert_file_contains "${workflow_path}" "create_manifest \"localhost/sccache:manifest-version\" \"\${GHCR_SCCACHE_IMAGE}:\${{ steps.image_versions.outputs.sccache_component_tag }}\""
assert_file_matches "${workflow_path}" '^[[:space:]]+- sccache$'
assert_file_contains "${renovate_config_path}" '/^containers\\/control-plane\\/skills\\/containerized-rust-ops\\/assets\\/sccache-image\\/Dockerfile$/'

printf '%s\n' 'image-maintenance-test: verifying GHCR cleanup keeps tagged images' >&2
assert_file_contains "${workflow_path}" 'delete-only-untagged-versions: '\''true'\'''

printf '%s\n' 'image-maintenance-test: maintenance workflows ok' >&2
