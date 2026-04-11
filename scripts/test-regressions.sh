#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
control_plane_bin_dir="${script_dir}/../containers/control-plane/bin"
control_plane_image="${1:?usage: scripts/test-regressions.sh <control-plane-image>}"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-docker}"
workdir="$(mktemp -d)"
container_name="control-plane-regression-test"
control_plane_run_user=(--user 0:0)
startup_caps=(
  --cap-add AUDIT_WRITE
  --cap-add CHOWN
  --cap-add DAC_OVERRIDE
  --cap-add FOWNER
  --cap-add SETGID
  --cap-add SETUID
  --cap-add SYS_CHROOT
)

cleanup() {
  "${container_bin}" rm -f "${container_name}" >/dev/null 2>&1 || true
  if [[ -d "${workdir}" ]]; then
    "${container_bin}" run --rm \
      --user 0:0 \
      -v "${workdir}:/cleanup" \
      --entrypoint sh \
      "${control_plane_image}" \
      -c 'find /cleanup -mindepth 1 -depth -delete' >/dev/null 2>&1 || true
  fi
  rm -rf "${workdir}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

require_command "${container_bin}"
require_command awk

# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"

assert_multiline_command_block() {
  local manifest_path="$1"
  local expected_header="$2"

  if ! awk -v expected_header="${expected_header}" '
    /- '\''-lc'\''/ { saw_lc = 1; next }
    saw_lc && $0 ~ /^[[:space:]]+- / {
      block_header = $0
      sub(/^[[:space:]]+- /, "", block_header)
      if (block_header == expected_header) {
        saw_block = 1
        next
      }
      exit 1
    }
    saw_block && $0 ~ /^[[:space:]]+printf line-one$/ { saw_line_one = 1; content_lines++; next }
    saw_block && $0 ~ /^[[:space:]]+printf line-two$/ { saw_line_two = 1; content_lines++; next }
    saw_block && $0 ~ /^[[:space:]]+$/ { blank_lines++; content_lines++; next }
    saw_block && $0 ~ /^[[:space:]]+resources:$/ { saw_resources = 1; next }
    END {
      exit !(saw_block && saw_line_one && saw_line_two && saw_resources && content_lines == 2 && blank_lines == 0)
    }
  ' "${manifest_path}"; then
    printf 'Expected multiline execution command args to render with YAML block header %s\n' "${expected_header}" >&2
    awk '/- '\''-lc'\''/,/resources:/' "${manifest_path}" >&2 || true
    exit 1
  fi
}

printf '%s\n' 'regression-test: verifying broken overlay symlink startup handling' >&2
mkdir -p \
  "${workdir}/state/copilot/containers/overlay/storage/overlay/l" \
  "${workdir}/state/gh" \
  "${workdir}/state/ssh" \
  "${workdir}/state/ssh-host-keys" \
  "${workdir}/state/workspace"
ln -s /nonexistent/overlay-target "${workdir}/state/copilot/containers/overlay/storage/overlay/l/BROKENLINK"

set +e
broken_symlink_output="$("${container_bin}" run --rm \
  --name "${container_name}" \
  "${control_plane_run_user[@]}" \
  "${startup_caps[@]}" \
  -e SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForRegressionOnly control-plane-regression' \
  -v "${workdir}/state/copilot:/home/copilot/.copilot" \
  -v "${workdir}/state/gh:/home/copilot/.config/gh" \
  -v "${workdir}/state/ssh:/home/copilot/.ssh" \
  -v "${workdir}/state/ssh-host-keys:/var/lib/control-plane/ssh-host-keys" \
  -v "${workdir}/state/workspace:/workspace" \
  "${control_plane_image}" \
  bash -lc 'printf "%s\n" startup-ok' 2>&1)"
broken_symlink_status=$?
set -e

if [[ "${broken_symlink_status}" -ne 0 ]]; then
  printf 'Expected control-plane startup to ignore broken overlay symlinks\n' >&2
  printf '%s\n' "${broken_symlink_output}" >&2
  exit 1
fi
if grep -q 'cannot dereference' <<<"${broken_symlink_output}"; then
  printf 'Unexpected chown dereference failure with broken overlay symlink\n' >&2
  printf '%s\n' "${broken_symlink_output}" >&2
  exit 1
fi
grep -qx 'startup-ok' <<<"${broken_symlink_output}"

printf '%s\n' 'regression-test: verifying bundled skill sync keeps bundled skills readable' >&2
mkdir -p \
  "${workdir}/skill-state/copilot" \
  "${workdir}/skill-state/gh" \
  "${workdir}/skill-state/ssh" \
  "${workdir}/skill-state/ssh-host-keys" \
  "${workdir}/skill-state/workspace"

set +e
skill_output="$("${container_bin}" run --rm \
  --name "${container_name}" \
  "${control_plane_run_user[@]}" \
  "${startup_caps[@]}" \
  -e SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForRegressionOnly control-plane-regression' \
  -v "${workdir}/skill-state/copilot:/home/copilot/.copilot" \
  -v "${workdir}/skill-state/gh:/home/copilot/.config/gh" \
  -v "${workdir}/skill-state/ssh:/home/copilot/.ssh" \
  -v "${workdir}/skill-state/ssh-host-keys:/var/lib/control-plane/ssh-host-keys" \
  -v "${workdir}/skill-state/workspace:/workspace" \
  "${control_plane_image}" \
  bash -lc "set -euo pipefail
su -s /bin/bash copilot -c 'set -euo pipefail
doc_coauthor_skill_root=\"\$HOME/.copilot/skills/doc-coauthoring\"
delivery_skill_root=\"\$HOME/.copilot/skills/repo-change-delivery\"
commit_skill_root=\"\$HOME/.copilot/skills/git-commit\"
pull_request_skill_root=\"\$HOME/.copilot/skills/pull-request-workflow\"
skill_creator_skill_root=\"\$HOME/.copilot/skills/skill-creator\"
test ! -L \"\$doc_coauthor_skill_root\"
test -r \"\$doc_coauthor_skill_root/SKILL.md\"
grep -Fqx \"name: doc-coauthoring\" \"\$doc_coauthor_skill_root/SKILL.md\"
test ! -L \"\$delivery_skill_root\"
test -r \"\$delivery_skill_root/SKILL.md\"
grep -Fqx \"name: repo-change-delivery\" \"\$delivery_skill_root/SKILL.md\"
test ! -L \"\$commit_skill_root\"
test -r \"\$commit_skill_root/SKILL.md\"
grep -Fqx \"name: git-commit\" \"\$commit_skill_root/SKILL.md\"
test ! -L \"\$pull_request_skill_root\"
test -r \"\$pull_request_skill_root/SKILL.md\"
grep -Fqx \"name: pull-request-workflow\" \"\$pull_request_skill_root/SKILL.md\"
test ! -L \"\$skill_creator_skill_root\"
test -r \"\$skill_creator_skill_root/SKILL.md\"
test -r \"\$skill_creator_skill_root/LICENSE.txt\"
grep -Fqx \"name: skill-creator\" \"\$skill_creator_skill_root/SKILL.md\"
printf \"%s\n\" bundled-skills-ok'" 2>&1)"
skill_status=$?
set -e

if [[ "${skill_status}" -ne 0 ]]; then
  printf 'Expected bundled skills to remain readable after startup sync\n' >&2
  printf '%s\n' "${skill_output}" >&2
  exit 1
fi
grep -qx 'bundled-skills-ok' <<<"${skill_output}"

printf '%s\n' 'regression-test: verifying runtime env omits retired sccache settings' >&2
mkdir -p \
  "${workdir}/runtime-env-state/copilot" \
  "${workdir}/runtime-env-state/gh" \
  "${workdir}/runtime-env-state/ssh" \
  "${workdir}/runtime-env-state/ssh-host-keys" \
  "${workdir}/runtime-env-state/workspace"

set +e
runtime_env_output="$("${container_bin}" run --rm \
  --name "${container_name}" \
  "${control_plane_run_user[@]}" \
  "${startup_caps[@]}" \
  -e SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForRegressionOnly control-plane-regression' \
  -e SCCACHE_BUCKET=control-plane-sccache \
  -e SCCACHE_ENDPOINT=http://garage-s3.control-plane.svc.cluster.local:3900 \
  -e SCCACHE_REGION=garage \
  -e SCCACHE_S3_USE_SSL=false \
  -e SCCACHE_S3_KEY_PREFIX=sccache/ \
  -e SCCACHE_CACHE_SIZE=4G \
  -e AWS_ACCESS_KEY_ID_FILE=/var/run/garage-sccache-auth/access-key-id \
  -e AWS_SECRET_ACCESS_KEY_FILE=/var/run/garage-sccache-auth/secret-access-key \
  -v "${workdir}/runtime-env-state/copilot:/home/copilot/.copilot" \
  -v "${workdir}/runtime-env-state/gh:/home/copilot/.config/gh" \
  -v "${workdir}/runtime-env-state/ssh:/home/copilot/.ssh" \
  -v "${workdir}/runtime-env-state/ssh-host-keys:/var/lib/control-plane/ssh-host-keys" \
  -v "${workdir}/runtime-env-state/workspace:/workspace" \
  "${control_plane_image}" \
  bash -lc "set -euo pipefail
su -l -s /bin/bash copilot -c 'set -euo pipefail
runtime_env=\"\$HOME/.config/control-plane/runtime.env\"
! grep -Eq \"^(SCCACHE_|AWS_ACCESS_KEY_ID_FILE=|AWS_SECRET_ACCESS_KEY_FILE=)\" \"\$runtime_env\"
[[ -z \"\${SCCACHE_BUCKET:-}\" ]]
[[ -z \"\${SCCACHE_ENDPOINT:-}\" ]]
[[ -z \"\${SCCACHE_REGION:-}\" ]]
[[ -z \"\${SCCACHE_S3_USE_SSL:-}\" ]]
[[ -z \"\${SCCACHE_S3_KEY_PREFIX:-}\" ]]
[[ -z \"\${SCCACHE_CACHE_SIZE:-}\" ]]
[[ -z \"\${AWS_ACCESS_KEY_ID_FILE:-}\" ]]
[[ -z \"\${AWS_SECRET_ACCESS_KEY_FILE:-}\" ]]
printf \"%s\n\" runtime-env-no-sccache-ok'" 2>&1)"
runtime_env_status=$?
set -e

if [[ "${runtime_env_status}" -ne 0 ]]; then
  printf 'Expected control-plane startup to omit retired sccache settings from runtime.env\n' >&2
  printf '%s\n' "${runtime_env_output}" >&2
  exit 1
fi
grep -qx 'runtime-env-no-sccache-ok' <<<"${runtime_env_output}"

printf '%s\n' 'regression-test: verifying runtime env preserves fast execution startup script' >&2
mkdir -p \
  "${workdir}/runtime-fast-exec-env-state/copilot" \
  "${workdir}/runtime-fast-exec-env-state/gh" \
  "${workdir}/runtime-fast-exec-env-state/ssh" \
  "${workdir}/runtime-fast-exec-env-state/ssh-host-keys" \
  "${workdir}/runtime-fast-exec-env-state/workspace"

set +e
runtime_fast_exec_env_output="$("${container_bin}" run --rm \
  --name "${container_name}" \
  "${control_plane_run_user[@]}" \
  "${startup_caps[@]}" \
  -e SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForRegressionOnly control-plane-regression' \
  -e 'CONTROL_PLANE_FAST_EXECUTION_STARTUP_SCRIPT=printf runtime-startup-ok' \
  -v "${workdir}/runtime-fast-exec-env-state/copilot:/home/copilot/.copilot" \
  -v "${workdir}/runtime-fast-exec-env-state/gh:/home/copilot/.config/gh" \
  -v "${workdir}/runtime-fast-exec-env-state/ssh:/home/copilot/.ssh" \
  -v "${workdir}/runtime-fast-exec-env-state/ssh-host-keys:/var/lib/control-plane/ssh-host-keys" \
  -v "${workdir}/runtime-fast-exec-env-state/workspace:/workspace" \
  "${control_plane_image}" \
  bash -lc "set -euo pipefail
su -l -s /bin/bash copilot -c 'set -euo pipefail
runtime_env=\"\$HOME/.config/control-plane/runtime.env\"
grep -q \"^CONTROL_PLANE_FAST_EXECUTION_STARTUP_SCRIPT=\" \"\$runtime_env\"
[[ \"\${CONTROL_PLANE_FAST_EXECUTION_STARTUP_SCRIPT:-}\" == \"printf runtime-startup-ok\" ]]
printf \"%s\n\" runtime-fast-exec-startup-ok'" 2>&1)"
runtime_fast_exec_env_status=$?
set -e

if [[ "${runtime_fast_exec_env_status}" -ne 0 ]]; then
  printf 'Expected control-plane startup to preserve fast execution startup script in runtime.env\n' >&2
  printf '%s\n' "${runtime_fast_exec_env_output}" >&2
  exit 1
fi
grep -qx 'runtime-fast-exec-startup-ok' <<<"${runtime_fast_exec_env_output}"

printf '%s\n' 'regression-test: verifying startup omits legacy registry auth surfaces' >&2
mkdir -p \
  "${workdir}/runtime-legacy-surface-state/copilot" \
  "${workdir}/runtime-legacy-surface-state/gh" \
  "${workdir}/runtime-legacy-surface-state/ssh" \
  "${workdir}/runtime-legacy-surface-state/ssh-host-keys" \
  "${workdir}/runtime-legacy-surface-state/workspace"

set +e
runtime_legacy_surface_output="$("${container_bin}" run --rm \
  --name "${container_name}" \
  "${control_plane_run_user[@]}" \
  "${startup_caps[@]}" \
  -e SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForRegressionOnly control-plane-regression' \
  -v "${workdir}/runtime-legacy-surface-state/copilot:/home/copilot/.copilot" \
  -v "${workdir}/runtime-legacy-surface-state/gh:/home/copilot/.config/gh" \
  -v "${workdir}/runtime-legacy-surface-state/ssh:/home/copilot/.ssh" \
  -v "${workdir}/runtime-legacy-surface-state/ssh-host-keys:/var/lib/control-plane/ssh-host-keys" \
  -v "${workdir}/runtime-legacy-surface-state/workspace:/workspace" \
  "${control_plane_image}" \
  bash -lc "set -euo pipefail
runtime_env=/home/copilot/.config/control-plane/runtime.env
auth_file=\"/run/user/\$(id -u copilot)/containers/auth.json\"
! grep -q '^CONTROL_PLANE_RUN_MODE=' \"\$runtime_env\"
! grep -q '^DOCKERHUB_' \"\$runtime_env\"
! grep -q '^REGISTRY_AUTH_FILE=' \"\$runtime_env\"
test ! -e \"\$auth_file\"
printf '%s\n' runtime-legacy-surface-ok" 2>&1)"
runtime_legacy_surface_status=$?
set -e

if [[ "${runtime_legacy_surface_status}" -ne 0 ]]; then
  printf 'Expected control-plane startup to omit legacy registry auth surfaces\n' >&2
  printf '%s\n' "${runtime_legacy_surface_output}" >&2
  exit 1
fi
grep -qx 'runtime-legacy-surface-ok' <<<"${runtime_legacy_surface_output}"

printf '%s\n' 'regression-test: verifying k8s-job-start renders HTTP transfer helpers' >&2
mkdir -p "${workdir}/fake-bin"
mkdir -p "${workdir}/k8s-home"
printf '%s\n' 'k8s transfer input' > "${workdir}/k8s-transfer-input.txt"
cat > "${workdir}/fake-bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
manifest_path="${TEST_REGRESSION_K8S_MANIFEST_PATH:?}"
secret_args_path="${TEST_REGRESSION_K8S_SECRET_ARGS_PATH:?}"
case "${1:-}" in
  create)
    if [[ "${2:-}" == "secret" ]] && [[ "${3:-}" == "generic" ]]; then
      printf '%s\n' "$@" > "${secret_args_path}"
      exit 0
    fi
    if [[ "${2:-}" == "-f" ]] && [[ "${3:-}" == "-" ]]; then
      cat > "${manifest_path}"
      exit 0
    fi
    ;;
esac
printf 'unexpected fake kubectl command: %s\n' "$*" >&2
exit 1
EOF
chmod +x "${workdir}/fake-bin/kubectl"
PATH="${workdir}/fake-bin:${control_plane_bin_dir}:${PATH}" \
  HOME="${workdir}/k8s-home" \
  CONTROL_PLANE_RUNTIME_ENV_FILE=/dev/null \
  CONTROL_PLANE_JOB_TRANSFER_IMAGE=localhost/control-plane:test \
  TEST_REGRESSION_K8S_MANIFEST_PATH="${workdir}/k8s-job-manifest.yaml" \
  TEST_REGRESSION_K8S_SECRET_ARGS_PATH="${workdir}/k8s-job-secret.args" \
  "${control_plane_bin_dir}/k8s-job-start" \
  --namespace control-plane-ci-jobs \
  --job-name regression-transfer-job \
  --image localhost/control-plane:test \
  --mount-file "${workdir}/k8s-transfer-input.txt:inputs/k8s-transfer-input.txt" \
  -- true >/dev/null

grep -qx 'create' "${workdir}/k8s-job-secret.args"
grep -qx 'secret' "${workdir}/k8s-job-secret.args"
grep -qx 'generic' "${workdir}/k8s-job-secret.args"
grep -Fq -- '--from-literal=transfer-token=' "${workdir}/k8s-job-secret.args"
if grep -Fq 'rclone' "${workdir}/k8s-job-manifest.yaml"; then
  printf 'Expected k8s-job-start to avoid rclone-based job transfer wiring\n' >&2
  grep -n 'rclone' "${workdir}/k8s-job-manifest.yaml" >&2 || true
  exit 1
fi
if grep -Fq 'CONTROL_PLANE_TRANSFER_HOST' "${workdir}/k8s-job-manifest.yaml" \
  || grep -Fq 'CONTROL_PLANE_TRANSFER_PORT' "${workdir}/k8s-job-manifest.yaml" \
  || grep -Fq 'CONTROL_PLANE_TRANSFER_USER' "${workdir}/k8s-job-manifest.yaml"; then
  printf 'Expected k8s-job-start to collapse transfer config into CONTROL_PLANE_TRANSFER_URL\n' >&2
  grep -n 'CONTROL_PLANE_TRANSFER_' "${workdir}/k8s-job-manifest.yaml" >&2 || true
  exit 1
fi
grep -Fq 'curl -fsSL' "${workdir}/k8s-job-manifest.yaml"
grep -Fq -- '--fail-with-body' "${workdir}/k8s-job-manifest.yaml"
grep -Fq "\"\${CONTROL_PLANE_TRANSFER_URL}/input.tar\"" "${workdir}/k8s-job-manifest.yaml"
grep -Fq "\"\${CONTROL_PLANE_TRANSFER_URL}/output.tar\"" "${workdir}/k8s-job-manifest.yaml"
grep -Fq "\"\${CONTROL_PLANE_TRANSFER_URL}/finalize\"" "${workdir}/k8s-job-manifest.yaml"
grep -Fq "\"\${CONTROL_PLANE_TRANSFER_URL}/release\"" "${workdir}/k8s-job-manifest.yaml"
if ! grep -Fq 'curl -fsS' "${workdir}/k8s-job-manifest.yaml"; then
  printf 'Expected job-transfer-sync to use curl for HTTP transfer callbacks\n' >&2
  grep -n 'curl -fsS\|kubectl get pod\|jsonpath=' "${workdir}/k8s-job-manifest.yaml" >&2 || true
  exit 1
fi
grep -Fq "kubectl get pod \"\${pod_name}\" --namespace \"\${namespace}\" -o jsonpath=" "${workdir}/k8s-job-manifest.yaml"
grep -Fq ".status.containerStatuses[?(@.name==\"execution\")].state.terminated.exitCode" "${workdir}/k8s-job-manifest.yaml"
if grep -Fq '--transfers 1' "${workdir}/k8s-job-manifest.yaml"; then
  printf 'Expected HTTP transfer wiring to drop rclone transfer flags\n' >&2
  grep -n 'transfers 1\|checkers 1\|sftp-disable-concurrent' "${workdir}/k8s-job-manifest.yaml" >&2 || true
  exit 1
fi
if grep -Fq -- '--checkers 1' "${workdir}/k8s-job-manifest.yaml"; then
  printf 'Expected HTTP transfer wiring to drop rclone checker flags\n' >&2
  exit 1
fi
if grep -Fq -- '--sftp-disable-concurrent-reads' "${workdir}/k8s-job-manifest.yaml"; then
  printf 'Expected HTTP transfer wiring to drop SFTP read flags\n' >&2
  exit 1
fi
if grep -Fq -- '--sftp-disable-concurrent-writes' "${workdir}/k8s-job-manifest.yaml"; then
  printf 'Expected HTTP transfer wiring to drop SFTP write flags\n' >&2
  exit 1
fi
grep -Fq 'name: CONTROL_PLANE_JOB_RUN_AS_UID' "${workdir}/k8s-job-manifest.yaml"
grep -Fq 'name: CONTROL_PLANE_JOB_RUN_AS_GID' "${workdir}/k8s-job-manifest.yaml"
grep -A1 'name: CONTROL_PLANE_JOB_RUN_AS_UID' "${workdir}/k8s-job-manifest.yaml" | grep -Fq "value: '1000'"
grep -A1 'name: CONTROL_PLANE_JOB_RUN_AS_GID' "${workdir}/k8s-job-manifest.yaml" | grep -Fq "value: '1000'"
grep -Fq 'runAsUser: 0' "${workdir}/k8s-job-manifest.yaml"
grep -Fq 'runAsGroup: 1000' "${workdir}/k8s-job-manifest.yaml"
grep -Fq -- '- CHOWN' "${workdir}/k8s-job-manifest.yaml"
grep -Fq -- '- FOWNER' "${workdir}/k8s-job-manifest.yaml"
grep -Fq "chown -R \"\${CONTROL_PLANE_JOB_RUN_AS_UID}:\${CONTROL_PLANE_JOB_RUN_AS_GID}\" \"\${CONTROL_PLANE_JOB_INPUT_MOUNT_PATH}\"" "${workdir}/k8s-job-manifest.yaml"
grep -Fq "chmod -R u+rwX \"\${CONTROL_PLANE_JOB_INPUT_MOUNT_PATH}\"" "${workdir}/k8s-job-manifest.yaml"
if ! grep -A12 'name: job-transfer-sync' "${workdir}/k8s-job-manifest.yaml" | grep -Fq 'runAsUser: 0'; then
  printf 'Expected job-transfer-sync to run as root so it can read the 0400 transfer Secret\n' >&2
  grep -A20 'name: job-transfer-sync' "${workdir}/k8s-job-manifest.yaml" >&2 || true
  exit 1
fi
if ! grep -A12 'name: job-transfer-sync' "${workdir}/k8s-job-manifest.yaml" | grep -Fq 'allowPrivilegeEscalation: false'; then
  printf 'Expected job-transfer-sync to disable privilege escalation\n' >&2
  grep -A20 'name: job-transfer-sync' "${workdir}/k8s-job-manifest.yaml" >&2 || true
  exit 1
fi

PATH="${workdir}/fake-bin:${control_plane_bin_dir}:${PATH}" \
  HOME="${workdir}/k8s-home" \
  CONTROL_PLANE_RUNTIME_ENV_FILE=/dev/null \
  TEST_REGRESSION_K8S_MANIFEST_PATH="${workdir}/k8s-job-multiline-manifest.yaml" \
  TEST_REGRESSION_K8S_SECRET_ARGS_PATH="${workdir}/k8s-job-multiline-secret.args" \
  "${control_plane_bin_dir}/k8s-job-start" \
  --namespace control-plane-ci-jobs \
  --job-name regression-multiline-command-job \
  --image localhost/control-plane:test \
  -- bash -lc $'printf line-one\nprintf line-two' >/dev/null

assert_multiline_command_block "${workdir}/k8s-job-multiline-manifest.yaml" '|-'

PATH="${workdir}/fake-bin:${control_plane_bin_dir}:${PATH}" \
  HOME="${workdir}/k8s-home" \
  CONTROL_PLANE_RUNTIME_ENV_FILE=/dev/null \
  TEST_REGRESSION_K8S_MANIFEST_PATH="${workdir}/k8s-job-multiline-trailing-manifest.yaml" \
  TEST_REGRESSION_K8S_SECRET_ARGS_PATH="${workdir}/k8s-job-multiline-trailing-secret.args" \
  "${control_plane_bin_dir}/k8s-job-start" \
  --namespace control-plane-ci-jobs \
  --job-name regression-multiline-command-trailing-job \
  --image localhost/control-plane:test \
  -- bash -lc $'printf line-one\nprintf line-two\n' >/dev/null

assert_multiline_command_block "${workdir}/k8s-job-multiline-trailing-manifest.yaml" '|+'

set +e
newline_transfer_output="$(
  PATH="${workdir}/fake-bin:${control_plane_bin_dir}:${PATH}" \
    HOME="${workdir}/k8s-home" \
    CONTROL_PLANE_RUNTIME_ENV_FILE=/dev/null \
    CONTROL_PLANE_JOB_TRANSFER_IMAGE=localhost/control-plane:test \
    CONTROL_PLANE_JOB_TRANSFER_HOST=$'control-plane.example\nmalicious' \
    TEST_REGRESSION_K8S_MANIFEST_PATH="${workdir}/should-not-exist.yaml" \
    TEST_REGRESSION_K8S_SECRET_ARGS_PATH="${workdir}/should-not-exist.args" \
    "${control_plane_bin_dir}/k8s-job-start" \
    --namespace control-plane-ci-jobs \
    --job-name regression-transfer-job-invalid \
    --image localhost/control-plane:test \
    --mount-file "${workdir}/k8s-transfer-input.txt:inputs/k8s-transfer-input.txt" \
    -- true 2>&1
)"
newline_transfer_status=$?
set -e

if [[ "${newline_transfer_status}" -eq 0 ]]; then
  printf 'Expected k8s-job-start to reject multiline transfer host values\n' >&2
  exit 1
fi
grep -Fq 'CONTROL_PLANE_JOB_TRANSFER_HOST must not contain newlines' <<<"${newline_transfer_output}"

printf '%s\n' 'regression-test: verifying Copilot launcher applies nice and secret env injection' >&2
cat > "${workdir}/fake-bin/nice" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "${TEST_REGRESSION_LOG_DIR:?}/nice.args"
[[ "${1:-}" == "-n" ]]
shift 2
exec "$@"
EOF
chmod +x "${workdir}/fake-bin/nice"

cat > "${workdir}/fake-bin/copilot" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'COPILOT_GITHUB_TOKEN=%s\n' "${COPILOT_GITHUB_TOKEN:-}" > "${TEST_REGRESSION_LOG_DIR:?}/copilot.env"
printf '%s\n' "$@" > "${TEST_REGRESSION_LOG_DIR:?}/copilot.args"
exit 0
EOF
chmod +x "${workdir}/fake-bin/copilot"
printf '%s' 'copilot-token-for-test' > "${workdir}/copilot-token"

run_copilot_launcher_test() {
  local PATH="${workdir}/fake-bin:${PATH}"
  local TEST_REGRESSION_LOG_DIR="${workdir}"
  local CONTROL_PLANE_RUNTIME_ENV_FILE=/dev/null
  local CONTROL_PLANE_COPILOT_BIN=copilot
  local CONTROL_PLANE_COPILOT_GITHUB_TOKEN_FILE="${workdir}/copilot-token"
  local CONTROL_PLANE_COPILOT_NICE_LEVEL=7
  export PATH TEST_REGRESSION_LOG_DIR CONTROL_PLANE_RUNTIME_ENV_FILE
  export CONTROL_PLANE_COPILOT_BIN CONTROL_PLANE_COPILOT_GITHUB_TOKEN_FILE
  export CONTROL_PLANE_COPILOT_NICE_LEVEL
  "${script_dir}/../containers/control-plane/bin/control-plane-copilot"
}

run_copilot_launcher_test

grep -qx -- '-n' "${workdir}/nice.args"
grep -qx '7' "${workdir}/nice.args"
grep -qx -- '--yolo' "${workdir}/copilot.args"
grep -qx -- '--secret-env-vars=COPILOT_GITHUB_TOKEN' "${workdir}/copilot.args"
grep -qx 'COPILOT_GITHUB_TOKEN=copilot-token-for-test' "${workdir}/copilot.env"

printf '%s\n' 'regression-test: targeted regressions ok' >&2
