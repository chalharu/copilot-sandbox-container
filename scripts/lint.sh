#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"

toolchain="$(detect_build_test_toolchain)"
container_bin="$(container_runtime_for_toolchain "${toolchain}")"
build_bin="$(build_command_for_toolchain "${toolchain}")"
# renovate: datasource=docker depName=docker.io/hadolint/hadolint versioning=docker
hadolint_image="${CONTROL_PLANE_HADOLINT_IMAGE:-docker.io/hadolint/hadolint:v2.14.0-debian@sha256:158cd0184dcaa18bd8ec20b61f4c1cabdf8b32a592d062f57bdcb8e4c1d312e2}"
# renovate: datasource=docker depName=docker.io/koalaman/shellcheck versioning=docker
shellcheck_image="${CONTROL_PLANE_SHELLCHECK_IMAGE:-docker.io/koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d}"
# renovate: datasource=docker depName=ghcr.io/biomejs/biome versioning=docker
biome_image="${CONTROL_PLANE_BIOME_IMAGE:-ghcr.io/biomejs/biome:2.4.10@sha256:0cae9ce4269bbf99116d5b8593d71eca111b650d8a269b0e8ce3d58f6a257256}"
# renovate: datasource=docker depName=docker.io/library/node versioning=docker
markdownlint_node_image="${CONTROL_PLANE_MARKDOWNLINT_NODE_IMAGE:-docker.io/library/node:24.14.1-bookworm-slim@sha256:06e5c9f86bfa0aaa7163cf37a5eaa8805f16b9acb48e3f85645b09d459fc2a9f}"
# renovate: datasource=npm depName=markdownlint-cli2
markdownlint_version="${CONTROL_PLANE_MARKDOWNLINT_VERSION:-0.22.0}"
markdownlint_cache_volume="${CONTROL_PLANE_MARKDOWNLINT_CACHE_VOLUME:-control-plane-markdownlint-cache}"
control_plane_image="${CONTROL_PLANE_IMAGE_TAG:-localhost/control-plane:test}"
yamllint_config="${CONTROL_PLANE_YAMLLINT_CONFIG:-/workspace/.yamllint}"
# Use container root so restrictive workspace mounts remain readable.
workspace_access_user="0:0"
rust_lint_script="${script_dir}/../containers/control-plane/skills/containerized-rust-ops/scripts/podman-rust.sh"
dockerfiles=()
yaml_files=()
markdown_files=()
rust_workspace_dirs=()
shellcheck_targets=(
  /workspace/containers/control-plane/bin/control-plane-copilot
  /workspace/containers/control-plane/bin/control-plane-exec-api-launcher
  /workspace/containers/control-plane/bin/control-plane-screen
  /workspace/containers/control-plane/bin/control-plane-entrypoint
  /workspace/containers/control-plane/bin/control-plane-session-exec
  /workspace/containers/control-plane/hooks/git/pre-commit
  /workspace/containers/control-plane/hooks/git/pre-push
  /workspace/containers/control-plane/hooks/git/lib/common.sh
  /workspace/containers/control-plane/bin/control-plane-job-transfer
  /workspace/containers/control-plane/bin/control-plane-run
  /workspace/containers/control-plane/bin/control-plane-session
  /workspace/containers/control-plane/bin/k8s-job-start
  /workspace/containers/control-plane/bin/k8s-job-wait
  /workspace/containers/control-plane/bin/k8s-job-pod
  /workspace/containers/control-plane/bin/k8s-job-logs
  /workspace/containers/control-plane/bin/k8s-job-run
  /workspace/containers/control-plane/config/profile-control-plane-env.sh
  /workspace/containers/execution-plane-smoke/execution-plane-smoke
)
lint_log_dir="$(mktemp -d)"
lint_job_names=()
lint_job_pids=()

cleanup() {
  rm -rf "${lint_log_dir}"
}
trap cleanup EXIT

run_rust_lint() {
  local runtime="$1"
  local workspace_dir

  shift

  for workspace_dir in "$@"; do
    (
      cd "${workspace_dir}"
      CONTAINERIZED_RUST_CONTAINER_BIN="${runtime}" bash "${rust_lint_script}" fmt-check
      CONTAINERIZED_RUST_CONTAINER_BIN="${runtime}" bash "${rust_lint_script}" clippy
    )
  done
}

run_lint_job() {
  local name="$1"
  local log_path="${lint_log_dir}/${name}.log"

  shift
  "$@" >"${log_path}" 2>&1 &
  lint_job_names+=("${name}")
  lint_job_pids+=("$!")
}

wait_for_lint_jobs() {
  local failed=0
  local index

  for index in "${!lint_job_pids[@]}"; do
    if ! wait "${lint_job_pids[$index]}"; then
      failed=1
      printf 'Lint step failed: %s\n' "${lint_job_names[$index]}" >&2
      cat "${lint_log_dir}/${lint_job_names[$index]}.log" >&2
    fi
  done

  [[ "${failed}" -eq 0 ]]
}

require_command "${container_bin}"
require_command "${build_bin}"

while IFS= read -r dockerfile; do
  dockerfiles+=("/workspace/${dockerfile}")
done < <(find containers -name Dockerfile -print | LC_ALL=C sort)

while IFS= read -r yaml_file; do
  yaml_files+=("/workspace/${yaml_file}")
done < <(find . -type f \( -name '*.yml' -o -name '*.yaml' \) -print | LC_ALL=C sort)

while IFS= read -r markdown_file; do
  markdown_files+=("/workspace/${markdown_file#./}")
done < <(
  find . \
    -type f -name '*.md' -print | LC_ALL=C sort
)

while IFS= read -r script_file; do
  shellcheck_targets+=("/workspace/${script_file}")
done < <(find scripts -name '*.sh' -print | LC_ALL=C sort)

while IFS= read -r cargo_manifest; do
  rust_workspace_dirs+=("$(dirname "${cargo_manifest}")")
done < <(find "${repo_root}/containers" -name Cargo.toml -print | LC_ALL=C sort)

if [[ "${#dockerfiles[@]}" -eq 0 ]]; then
  printf 'No Dockerfiles found under containers/\n' >&2
  exit 1
fi

if [[ "${#yaml_files[@]}" -eq 0 ]]; then
  printf 'No YAML files found in repository\n' >&2
  exit 1
fi

if [[ "${#markdown_files[@]}" -eq 0 ]]; then
  printf 'No Markdown files found in repository\n' >&2
  exit 1
fi

printf 'Using %s toolchain for lint\n' "${toolchain}"
# Biome ignores .json5 when traversing repository paths, so validate renovate.json5
# through stdin and discard the normalized output once parsing succeeds.
"${container_bin}" run --rm -i --entrypoint biome "${biome_image}" check --formatter-enabled=false --write --stdin-file-path=renovate.json5 < renovate.json5 >/dev/null
CONTROL_PLANE_CONTAINER_BIN="${container_bin}" "${script_dir}/validate-renovate-config.sh"
build_image_for_toolchain "${toolchain}" "${control_plane_image}" containers/control-plane
if [[ "${#rust_workspace_dirs[@]}" -gt 0 ]]; then
  printf '%s\n' 'Running hadolint, shellcheck, yamllint, markdownlint, and Rust fmt/clippy in parallel' >&2
else
  printf '%s\n' 'Running hadolint, shellcheck, yamllint, and markdownlint in parallel' >&2
fi

run_lint_job hadolint \
  "${container_bin}" run --rm --user "${workspace_access_user}" -v "${PWD}:/workspace:ro" "${hadolint_image}" hadolint "${dockerfiles[@]}"

run_lint_job shellcheck \
  "${container_bin}" run --rm --user "${workspace_access_user}" -v "${PWD}:/workspace:ro" "${shellcheck_image}" -x -P /workspace "${shellcheck_targets[@]}"

run_lint_job yamllint \
  "${container_bin}" run --rm --user "${workspace_access_user}" --entrypoint yamllint \
    -v "${PWD}:/workspace:ro" "${control_plane_image}" -c "${yamllint_config}" "${yaml_files[@]}"

run_lint_job markdownlint \
  "${container_bin}" run --rm --user "${workspace_access_user}" \
    -e NPM_CONFIG_CACHE=/tmp/npm-cache \
    -e NPM_CONFIG_UPDATE_NOTIFIER=false \
    -v "${markdownlint_cache_volume}:/tmp/npm-cache" \
    -v "${PWD}:/workspace:ro" \
    -w /workspace \
    "${markdownlint_node_image}" \
    npx --yes "markdownlint-cli2@${markdownlint_version}" "${markdown_files[@]}"

if [[ "${#rust_workspace_dirs[@]}" -gt 0 ]]; then
  run_lint_job rust \
    run_rust_lint "${container_bin}" "${rust_workspace_dirs[@]}"
fi

wait_for_lint_jobs
