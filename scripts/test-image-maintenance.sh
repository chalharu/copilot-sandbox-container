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
buildkit_context_dir="${workdir}/buildkit-context"
fake_bin_dir="${workdir}/fake-bin"
docker_log="${workdir}/docker.log"
kubectl_log="${workdir}/kubectl.log"
kubectl_create_count="${workdir}/kubectl-create-count"
label_store="${workdir}/docker-label"
workflow_path="${repo_root}/.github/workflows/control-plane-ci.yml"
renovate_config_path="${repo_root}/renovate.json5"
validate_renovate_script_path="${repo_root}/scripts/validate-renovate-config.sh"
biome_image_helper_path="${repo_root}/scripts/lib-biome-hook-image.sh"
git_skills_manifest_installer_path="${repo_root}/scripts/install-git-skills-from-manifest.sh"
session_exec_test_path="${repo_root}/scripts/test-session-exec.sh"
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
mkdir -p "${buildkit_context_dir}"
cat > "${buildkit_context_dir}/Dockerfile" <<'EOF'
FROM docker.io/library/busybox:1.37.0
RUN printf '%s\n' buildkit > /image.txt
EOF

cat > "${fake_bin_dir}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${TEST_IMAGE_MAINTENANCE_DOCKER_LOG:?}"

if [[ "$#" -ge 1 ]] && [[ "$1" == "info" ]]; then
  exit "${TEST_IMAGE_MAINTENANCE_DOCKER_INFO_EXIT_CODE:-0}"
fi

if [[ "$#" -ge 2 ]] && [[ "$1" == "buildx" ]] && [[ "$2" == "version" ]]; then
  printf '%s\n' 'github.com/docker/buildx test'
  exit 0
fi

if [[ "$#" -ge 2 ]] && [[ "$1" == "image" ]] && [[ "$2" == "inspect" ]]; then
  if [[ -f "${TEST_IMAGE_MAINTENANCE_LABEL_STORE:?}" ]]; then
    cat "${TEST_IMAGE_MAINTENANCE_LABEL_STORE:?}"
    exit 0
  fi
  exit 1
fi

if [[ "$#" -ge 2 ]] && [[ "$1" == "buildx" ]] && [[ "$2" == "create" ]]; then
  exit 0
fi

if [[ "$#" -ge 2 ]] && [[ "$1" == "buildx" ]] && [[ "$2" == "rm" ]]; then
  exit 0
fi

if [[ "$#" -ge 2 ]] && [[ "$1" == "buildx" ]] && [[ "$2" == "build" ]]; then
  label_value=""
  cache_to=""
  previous=""
  for arg in "$@"; do
    if [[ "${previous}" == "--label" ]]; then
      label_value="${arg#*=}"
    elif [[ "${previous}" == "--cache-to" ]]; then
      cache_to="${arg}"
    fi
    previous="${arg}"
  done
  [[ -n "${label_value}" ]] || {
    printf 'missing --label in fake docker buildx build\n' >&2
    exit 1
  }
  if [[ -n "${cache_to}" ]]; then
    cache_to_dir="${cache_to#type=local,dest=}"
    cache_to_dir="${cache_to_dir%%,*}"
    mkdir -p "${cache_to_dir}"
  fi
  printf '%s\n' "${label_value}" > "${TEST_IMAGE_MAINTENANCE_LABEL_STORE:?}"
  exit 0
fi

printf 'unexpected fake docker invocation: %s\n' "$*" >&2
exit 1
EOF
chmod +x "${fake_bin_dir}/docker"

cat > "${fake_bin_dir}/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${TEST_IMAGE_MAINTENANCE_KUBECTL_LOG:?}"

if [[ "$#" -ge 3 ]] && [[ "$1" == "create" ]] && [[ "$2" == "-f" ]] && [[ "$3" == "-" ]]; then
  cat >/dev/null
  create_count=0
  if [[ -f "${TEST_IMAGE_MAINTENANCE_KUBECTL_CREATE_COUNT_FILE:?}" ]]; then
    create_count="$(cat "${TEST_IMAGE_MAINTENANCE_KUBECTL_CREATE_COUNT_FILE:?}")"
  fi
  create_count="$((create_count + 1))"
  printf '%s\n' "${create_count}" > "${TEST_IMAGE_MAINTENANCE_KUBECTL_CREATE_COUNT_FILE:?}"
  if [[ -n "${TEST_IMAGE_MAINTENANCE_KUBECTL_FAIL_CREATE_NUMBER:-}" ]] && [[ "${create_count}" -eq "${TEST_IMAGE_MAINTENANCE_KUBECTL_FAIL_CREATE_NUMBER}" ]]; then
    exit 1
  fi
  exit 0
fi

if [[ "$#" -ge 1 ]] && [[ "$1" == "wait" ]]; then
  exit 0
fi

if [[ "$#" -ge 1 ]] && [[ "$1" == "delete" ]]; then
  exit 0
fi

if [[ "$#" -ge 1 ]] && [[ "$1" == "logs" ]]; then
  printf '%s\n' 'fake buildkitd logs'
  exit 0
fi

if [[ "$#" -ge 1 ]] && [[ "$1" == "describe" ]]; then
  printf '%s\n' 'fake buildkitd describe'
  exit 0
fi

printf 'unexpected fake kubectl invocation: %s\n' "$*" >&2
exit 1
EOF
chmod +x "${fake_bin_dir}/kubectl"

export PATH="${fake_bin_dir}:${PATH}"
export TEST_IMAGE_MAINTENANCE_DOCKER_LOG="${docker_log}"
export TEST_IMAGE_MAINTENANCE_KUBECTL_LOG="${kubectl_log}"
export TEST_IMAGE_MAINTENANCE_KUBECTL_CREATE_COUNT_FILE="${kubectl_create_count}"
export TEST_IMAGE_MAINTENANCE_LABEL_STORE="${label_store}"
export TEST_IMAGE_MAINTENANCE_DOCKER_INFO_EXIT_CODE=0
unset CONTROL_PLANE_BUILDX_CACHE_ROOT
unset CONTROL_PLANE_RUST_CONTAINER_CACHE_ROOT
unset CONTROL_PLANE_BUILDKIT_STATE_ROOT

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

printf '%s\n' 'image-maintenance-test: verifying local buildx cache wiring' >&2
: > "${docker_log}"
rm -f "${label_store}"
export CONTROL_PLANE_BUILDX_CACHE_ROOT="${workdir}/buildx-cache"
build_image_for_toolchain docker localhost/image-maintenance-cache:test "${context_dir}"
cache_dir="$(buildx_local_cache_dir_for_context "${context_dir}")"
grep -Fq -- "--cache-from type=local,src=${cache_dir} --cache-to type=local,dest=${cache_dir}-new,mode=max" "${docker_log}"
[[ -d "${cache_dir}" ]]
[[ ! -e "${cache_dir}-new" ]]
unset CONTROL_PLANE_BUILDX_CACHE_ROOT

printf '%s\n' 'image-maintenance-test: verifying buildkitd remote helper wiring and reuse' >&2
: > "${docker_log}"
: > "${kubectl_log}"
export CONTROL_PLANE_BUILDKIT_STATE_ROOT="${workdir}/buildkitd-state"
buildkit_first_hash="$(build_context_hash "${buildkit_context_dir}")"
build_image_for_toolchain buildkitd localhost/image-maintenance-buildkitd:test "${buildkit_context_dir}"
grep -Fq "buildx create --name" "${docker_log}"
grep -Fq "buildx build --builder" "${docker_log}"
grep -Fq -- "--output type=image,name=localhost/image-maintenance-buildkitd:test,push=false" "${docker_log}"
grep -Fq -- "--label $(build_context_hash_label_key)=${buildkit_first_hash}" "${docker_log}"
grep -Fq "create -f -" "${kubectl_log}"
grep -Fq "wait -n $(buildkitd_namespace) --for=condition=Ready" "${kubectl_log}"
buildkit_build_lines_before="$(grep -c '^buildx build ' "${docker_log}")"
build_image_for_toolchain buildkitd localhost/image-maintenance-buildkitd:test "${buildkit_context_dir}"
buildkit_build_lines_after="$(grep -c '^buildx build ' "${docker_log}")"
[[ "${buildkit_build_lines_before}" -eq "${buildkit_build_lines_after}" ]]

printf '%s\n' 'image-maintenance-test: verifying buildkitd rebuilds changed contexts' >&2
printf '%s\n' 'RUN printf "%s\n" changed >> /image.txt' >> "${buildkit_context_dir}/Dockerfile"
buildkit_second_hash="$(build_context_hash "${buildkit_context_dir}")"
build_image_for_toolchain buildkitd localhost/image-maintenance-buildkitd:test "${buildkit_context_dir}"
[[ "${buildkit_first_hash}" != "${buildkit_second_hash}" ]]
grep -Fq -- "--label $(build_context_hash_label_key)=${buildkit_second_hash}" "${docker_log}"

printf '%s\n' 'image-maintenance-test: verifying buildkitd cleans up partial create failures' >&2
: > "${kubectl_log}"
: > "${kubectl_create_count}"
export TEST_IMAGE_MAINTENANCE_KUBECTL_FAIL_CREATE_NUMBER=2
failed_buildkit_image='localhost/image-maintenance-buildkitd-fail:test'
if build_image_for_toolchain buildkitd "${failed_buildkit_image}" "${buildkit_context_dir}"; then
  printf '%s\n' 'Expected buildkitd build to fail when service creation fails' >&2
  exit 1
fi
unset TEST_IMAGE_MAINTENANCE_KUBECTL_FAIL_CREATE_NUMBER
assert_file_matches "${kubectl_log}" '^delete service control-plane-buildkitd-[a-f0-9]+ -n '
assert_file_matches "${kubectl_log}" '^delete pod control-plane-buildkitd-[a-f0-9]+ -n '

printf '%s\n' 'image-maintenance-test: verifying build-test build-only falls back to buildkitd' >&2
: > "${docker_log}"
: > "${kubectl_log}"
export CONTROL_PLANE_BUILDKIT_STATE_ROOT="${workdir}/buildkitd-build-test-state"
export TEST_IMAGE_MAINTENANCE_DOCKER_INFO_EXIT_CODE=1
export CONTROL_PLANE_CONTAINER_BIN=docker
unset CONTROL_PLANE_TOOLCHAIN
build_test_output="$("${repo_root}/scripts/build-test.sh" --build-only 2>&1)"
grep -Fq "Using buildkitd toolchain for build/test" <<<"${build_test_output}"
grep -Fq "buildx create --name" "${docker_log}"
grep -Fq "buildx build --builder" "${docker_log}"
grep -Fq "create -f -" "${kubectl_log}"
export TEST_IMAGE_MAINTENANCE_DOCKER_INFO_EXIT_CODE=0
unset CONTROL_PLANE_CONTAINER_BIN
unset CONTROL_PLANE_BUILDKIT_STATE_ROOT

printf '%s\n' 'image-maintenance-test: verifying rust container cache wiring' >&2
export CONTROL_PLANE_RUST_CONTAINER_CACHE_ROOT="${workdir}/rust-cache"
rust_cache_home_dir=''
rust_cache_target_dir=''
rust_cache_temp_root=''
prepare_rust_container_cache control-plane-rust-regressions rust_cache_home_dir rust_cache_target_dir rust_cache_temp_root
rust_cache_dir="$(rust_container_cache_dir_for_scope control-plane-rust-regressions)"
[[ "${rust_cache_home_dir}" == "${rust_cache_dir}/home" ]]
[[ "${rust_cache_target_dir}" == "${rust_cache_dir}/target" ]]
[[ -d "${rust_cache_home_dir}/.cargo" ]]
[[ -d "${rust_cache_target_dir}" ]]
[[ -z "${rust_cache_temp_root}" ]]
unset CONTROL_PLANE_RUST_CONTAINER_CACHE_ROOT

rust_temp_home_dir=''
rust_temp_target_dir=''
rust_temp_root=''
prepare_rust_container_cache control-plane-rust-regressions rust_temp_home_dir rust_temp_target_dir rust_temp_root
[[ -n "${rust_temp_root}" ]]
[[ "${rust_temp_home_dir}" == "${rust_temp_root}/home" ]]
[[ "${rust_temp_target_dir}" == "${rust_temp_root}/target" ]]
[[ -d "${rust_temp_home_dir}/.cargo" ]]
[[ -d "${rust_temp_target_dir}" ]]

printf '%s\n' 'image-maintenance-test: verifying retired helper image contexts were removed' >&2
[[ ! -e "${sccache_dockerfile_path}" ]]
[[ ! -e "${validate_renovate_script_path}" ]]

printf '%s\n' 'image-maintenance-test: verifying legacy helper images were removed' >&2
[[ ! -e "${legacy_execution_plane_go_dockerfile_path}" ]]
[[ ! -e "${legacy_execution_plane_node_dockerfile_path}" ]]
[[ ! -e "${legacy_execution_plane_python_dockerfile_path}" ]]
[[ ! -e "${legacy_execution_plane_rust_dockerfile_path}" ]]
[[ ! -e "${legacy_yamllint_dockerfile_path}" ]]

publish_block="$(job_block publish-architecture-images)"
manifest_block="$(job_block publish-manifests)"
[[ -n "${publish_block}" ]] || {
  printf 'Expected publish-architecture-images job in %s\n' "${workflow_path}" >&2
  exit 1
}
[[ -n "${manifest_block}" ]] || {
  printf 'Expected publish-manifests job in %s\n' "${workflow_path}" >&2
  exit 1
}

assert_block_contains "${publish_block}" "CONTROL_PLANE_COMPONENT_TAG: \${{ steps.image_versions.outputs.control_plane_component_tag }}" 'publish-architecture-images job block'

assert_block_contains "${manifest_block}" "CONTROL_PLANE_COMPONENT_TAG: \${{ steps.image_versions.outputs.control_plane_component_tag }}" 'publish-manifests job block'
assert_file_contains "${renovate_config_path}" '/^containers\\/control-plane\\/Dockerfile$/'
assert_file_contains "${renovate_config_path}" '/^scripts\\/(lint|test-github-hooks|lib-biome-hook-image)\\.sh$/'
assert_file_contains "${renovate_config_path}" '/^(deploy\\/helm\\/control-plane\\/values\\.yaml|deploy\\/kubernetes\\/control-plane\\.example\\/common\\/configmap-control-plane-env\\.yaml)$/'
assert_file_contains "${renovate_config_path}" 'CONTROL_PLANE_BIOME_HOOK_IMAGE'
assert_file_contains "${renovate_config_path}" 'separateMultipleMajor: true'
assert_file_contains "${renovate_config_path}" 'separateMultipleMinor: true'
assert_file_contains "${renovate_config_path}" '"{{{depNameSanitized}}}{{#if newVersion}}__v{{{newVersion}}}{{/if}}{{#if newDigestShort}}__d{{{newDigestShort}}}{{/if}}",'
assert_file_not_contains "${renovate_config_path}" '__{{updateType}}'
assert_file_not_contains "${renovate_config_path}" 'validate-renovate-config'
assert_file_not_contains "${renovate_config_path}" 'containers\\/control-plane\\/bin\\/install-git-skills-from-manifest'
assert_file_not_contains "${renovate_config_path}" 'mozilla/sccache'
assert_file_contains "${biome_image_helper_path}" 'depName=ghcr.io/biomejs/biome'
assert_file_not_contains "${workflow_path}" 'sccache-changes'
assert_file_not_contains "${workflow_path}" 'containers/sccache'
assert_file_not_contains "${workflow_path}" 'GHCR_SCCACHE_IMAGE'
assert_file_contains "${session_exec_test_path}" 'cargo chef prepare'
assert_file_contains "${session_exec_test_path}" 'cargo chef cook'
assert_file_contains "${git_skills_manifest_installer_path}" '/usr/local/bin/control-plane-runtime-tool'
assert_file_not_contains "${git_skills_manifest_installer_path}" 'cargo build --release'
assert_file_contains "${workflow_path}" 'path: /tmp/control-plane-rust-regression-cache'
assert_file_contains "${repo_root}/containers/control-plane/Dockerfile" 'FROM cargo-chef AS rust-toolchain'
assert_file_not_contains "${workflow_path}" 'SCCACHE_COMPONENT_TAG'
assert_file_not_contains "${workflow_path}" 'PUBLISH_SCCACHE'
assert_file_not_matches "${workflow_path}" '^[[:space:]]+- sccache$'
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
assert_file_not_contains "${workflow_path}" '- sccache'

printf '%s\n' 'image-maintenance-test: verifying rclone checksum source follows the Renovate-managed version' >&2
assert_file_contains "${repo_root}/containers/control-plane/Dockerfile" "rclone_download_root=\"https://downloads.rclone.org/\${RCLONE_VERSION}\""
assert_file_contains "${repo_root}/containers/control-plane/Dockerfile" "curl -fsSLo /tmp/rclone-SHA256SUMS \"\${rclone_download_root}/SHA256SUMS\""
assert_file_not_contains "${repo_root}/containers/control-plane/Dockerfile" 'rclone_sha256='

printf '%s\n' 'image-maintenance-test: verifying GHCR cleanup keeps tagged images' >&2
assert_file_contains "${workflow_path}" 'delete-only-untagged-versions: '\''true'\'''

printf '%s\n' 'image-maintenance-test: maintenance workflows ok' >&2
