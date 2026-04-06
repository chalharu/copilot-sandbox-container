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
require_command ssh-keygen

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
control_skill_root=\"\$HOME/.copilot/skills/control-plane-operations\"
yamllint_skill_root=\"\$HOME/.copilot/skills/containerized-yamllint-ops\"
doc_coauthor_skill_root=\"\$HOME/.copilot/skills/doc-coauthoring\"
delivery_skill_root=\"\$HOME/.copilot/skills/repo-change-delivery\"
commit_skill_root=\"\$HOME/.copilot/skills/git-commit\"
pull_request_skill_root=\"\$HOME/.copilot/skills/pull-request-workflow\"
skill_creator_skill_root=\"\$HOME/.copilot/skills/skill-creator\"
test ! -L \"\$control_skill_root\"
test -r \"\$control_skill_root/SKILL.md\"
test -x \"\$control_skill_root/references\"
test -r \"\$control_skill_root/references/control-plane-run.md\"
test -r \"\$control_skill_root/references/skills.md\"
test ! -L \"\$yamllint_skill_root\"
test -r \"\$yamllint_skill_root/SKILL.md\"
grep -Fqx \"name: containerized-yamllint-ops\" \"\$yamllint_skill_root/SKILL.md\"
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

printf '%s\n' 'regression-test: verifying runtime env preserves sccache settings for login shells' >&2
mkdir -p \
  "${workdir}/runtime-env-state/copilot" \
  "${workdir}/runtime-env-state/gh" \
  "${workdir}/runtime-env-state/ssh" \
  "${workdir}/runtime-env-state/ssh-host-keys" \
  "${workdir}/runtime-env-state/workspace" \
  "${workdir}/runtime-env-state/garage-sccache-auth"
printf '%s' 'sample-access-key-id' > "${workdir}/runtime-env-state/garage-sccache-auth/access-key-id"
printf '%s' 'sample-secret-access-key' > "${workdir}/runtime-env-state/garage-sccache-auth/secret-access-key"

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
  -v "${workdir}/runtime-env-state/garage-sccache-auth:/var/run/garage-sccache-auth:ro" \
  "${control_plane_image}" \
  bash -lc "set -euo pipefail
su -l -s /bin/bash copilot -c 'set -euo pipefail
runtime_env=\"\$HOME/.config/control-plane/runtime.env\"
grep -Fqx \"SCCACHE_BUCKET=control-plane-sccache\" \"\$runtime_env\"
grep -Fqx \"SCCACHE_ENDPOINT=http://garage-s3.control-plane.svc.cluster.local:3900\" \"\$runtime_env\"
grep -Fqx \"SCCACHE_REGION=garage\" \"\$runtime_env\"
grep -Fqx \"SCCACHE_S3_USE_SSL=false\" \"\$runtime_env\"
grep -Fqx \"SCCACHE_S3_KEY_PREFIX=sccache/\" \"\$runtime_env\"
grep -Fqx \"SCCACHE_CACHE_SIZE=4G\" \"\$runtime_env\"
grep -Fqx \"AWS_ACCESS_KEY_ID_FILE=/var/run/garage-sccache-auth/access-key-id\" \"\$runtime_env\"
grep -Fqx \"AWS_SECRET_ACCESS_KEY_FILE=/var/run/garage-sccache-auth/secret-access-key\" \"\$runtime_env\"
[[ \"\${SCCACHE_BUCKET:-}\" == \"control-plane-sccache\" ]]
[[ \"\${SCCACHE_ENDPOINT:-}\" == \"http://garage-s3.control-plane.svc.cluster.local:3900\" ]]
[[ \"\${SCCACHE_REGION:-}\" == \"garage\" ]]
[[ \"\${SCCACHE_S3_USE_SSL:-}\" == \"false\" ]]
[[ \"\${SCCACHE_S3_KEY_PREFIX:-}\" == \"sccache/\" ]]
[[ \"\${SCCACHE_CACHE_SIZE:-}\" == \"4G\" ]]
[[ \"\${AWS_ACCESS_KEY_ID_FILE:-}\" == \"/var/run/garage-sccache-auth/access-key-id\" ]]
[[ \"\${AWS_SECRET_ACCESS_KEY_FILE:-}\" == \"/var/run/garage-sccache-auth/secret-access-key\" ]]
[[ -r \"\${AWS_ACCESS_KEY_ID_FILE}\" ]]
[[ -r \"\${AWS_SECRET_ACCESS_KEY_FILE}\" ]]
printf \"%s\n\" runtime-env-sccache-ok'" 2>&1)"
runtime_env_status=$?
set -e

if [[ "${runtime_env_status}" -ne 0 ]]; then
  printf 'Expected control-plane startup to preserve sccache settings in runtime.env\n' >&2
  printf '%s\n' "${runtime_env_output}" >&2
  exit 1
fi
grep -qx 'runtime-env-sccache-ok' <<<"${runtime_env_output}"

expected_dhi_auth="$(printf '%s' 'test-user:test-token' | base64 | tr -d '\n')"

printf '%s\n' 'regression-test: verifying startup materializes DHI auth without exposing secret files' >&2
mkdir -p \
  "${workdir}/runtime-dhi-auth-state/copilot" \
  "${workdir}/runtime-dhi-auth-state/gh" \
  "${workdir}/runtime-dhi-auth-state/ssh" \
  "${workdir}/runtime-dhi-auth-state/ssh-host-keys" \
  "${workdir}/runtime-dhi-auth-state/workspace" \
  "${workdir}/runtime-dhi-auth-state/control-plane-auth"
printf '%s' 'test-user' > "${workdir}/runtime-dhi-auth-state/control-plane-auth/dockerhub-username"
printf '%s' 'test-token' > "${workdir}/runtime-dhi-auth-state/control-plane-auth/dockerhub-token"

set +e
runtime_dhi_auth_output="$("${container_bin}" run --rm \
  --name "${container_name}" \
  "${control_plane_run_user[@]}" \
  "${startup_caps[@]}" \
  -e SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForRegressionOnly control-plane-regression' \
  -e DOCKERHUB_USERNAME_FILE=/var/run/control-plane-auth/dockerhub-username \
  -e DOCKERHUB_TOKEN_FILE=/var/run/control-plane-auth/dockerhub-token \
  -v "${workdir}/runtime-dhi-auth-state/copilot:/home/copilot/.copilot" \
  -v "${workdir}/runtime-dhi-auth-state/gh:/home/copilot/.config/gh" \
  -v "${workdir}/runtime-dhi-auth-state/ssh:/home/copilot/.ssh" \
  -v "${workdir}/runtime-dhi-auth-state/ssh-host-keys:/var/lib/control-plane/ssh-host-keys" \
  -v "${workdir}/runtime-dhi-auth-state/workspace:/workspace" \
  -v "${workdir}/runtime-dhi-auth-state/control-plane-auth:/var/run/control-plane-auth:ro" \
  "${control_plane_image}" \
  bash -lc "set -euo pipefail
runtime_env=/home/copilot/.config/control-plane/runtime.env
auth_file=\"/run/user/\$(id -u copilot)/containers/auth.json\"
! grep -q '^DOCKERHUB_' \"\$runtime_env\"
! grep -q '^REGISTRY_AUTH_FILE=' \"\$runtime_env\"
test -r \"\$auth_file\"
grep -Fq '\"dhi.io\"' \"\$auth_file\"
grep -Fq '\"auth\":\"${expected_dhi_auth}\"' \"\$auth_file\"
su -l -s /bin/bash copilot -c 'set -euo pipefail
set -a
source \"\$HOME/.config/control-plane/runtime.env\"
set +a
stderr_file=\"\$(mktemp)\"
if cat \"\${XDG_RUNTIME_DIR}/containers/auth.json\" >/dev/null 2>\"\${stderr_file}\"; then
  printf \"%s\n\" \"Expected direct registry auth.json read to be denied\" >&2
  exit 1
fi
grep -Fq \"control-plane exec policy:\" \"\${stderr_file}\"
grep -Fq \"registry auth.json\" \"\${stderr_file}\"
rm -f \"\${stderr_file}\"'
printf '%s\n' runtime-dhi-auth-ok" 2>&1)"
runtime_dhi_auth_status=$?
set -e

if [[ "${runtime_dhi_auth_status}" -ne 0 ]]; then
  printf 'Expected control-plane startup to materialize DHI auth without exposing secret file paths\n' >&2
  printf '%s\n' "${runtime_dhi_auth_output}" >&2
  exit 1
fi
grep -qx 'runtime-dhi-auth-ok' <<<"${runtime_dhi_auth_output}"

printf '%s\n' 'regression-test: verifying secretless DHI auth handling' >&2
mkdir -p "${workdir}/fake-bin"
cat > "${workdir}/fake-bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log_dir="${TEST_REGRESSION_LOG_DIR:?}"
case "${1:-}" in
  run)
    printf '%s\n' "$*" >> "${log_dir}/run.args"
    shift
    entrypoint=""
    image=""
    envs=()
    while [[ "$#" -gt 0 ]]; do
      case "${1:-}" in
        --rm)
          shift
          ;;
        --user|--entrypoint|-v|-e|-w)
          case "${1:-}" in
            --entrypoint)
              entrypoint="${2:-}"
              ;;
            -e)
              envs+=("${2:-}")
              ;;
          esac
          shift 2
          ;;
        --*)
          shift
          ;;
        *)
          image="${1:-}"
          shift
          break
          ;;
      esac
    done
    case "${entrypoint}" in
      renovate-config-validator)
        printf '%s\n' "${envs[@]}" > "${log_dir}/renovate-validator.env"
        exit 0
        ;;
      renovate)
        printf '%s\n' "${envs[@]}" > "${log_dir}/renovate.env"
        cat <<'RENOVATE'
@github/copilot
actions/download-artifact
actions/checkout
actions/upload-artifact
azure/setup-kubectl
busybox
dhi.io/python
docker.io/library/node
engineerd/setup-kind
ghcr.io/biomejs/biome
ghcr.io/renovatebot/renovate
hadolint/hadolint
koalaman/shellcheck
markdownlint-cli2
mozilla/sccache
yamllint
RENOVATE
        exit 0
        ;;
      sh)
        exit 0
        ;;
    esac
    printf 'unexpected fake docker run invocation: image=%s args=%s\n' "${image}" "$*" >&2
    exit 1
    ;;
esac
printf 'unexpected fake docker command: %s\n' "$*" >&2
exit 1
EOF
chmod +x "${workdir}/fake-bin/docker"

PATH="${workdir}/fake-bin:${PATH}" \
  TEST_REGRESSION_LOG_DIR="${workdir}" \
  CONTROL_PLANE_RUNTIME_ENV_FILE=/dev/null \
  CONTROL_PLANE_CONTAINER_BIN=docker \
  DOCKERHUB_USERNAME=test-user \
  DOCKERHUB_TOKEN=test-token \
  DOCKERHUB_USERNAME_FILE="${workdir}/missing-username" \
  DOCKERHUB_TOKEN_FILE="${workdir}/missing-token" \
  "${script_dir}/validate-renovate-config.sh"

grep -Fqx 'RENOVATE_HOST_RULES=[{"matchHost":"dhi.io","username":"test-user","password":"test-token"}]' "${workdir}/renovate.env"

printf '%s\n' 'regression-test: verifying k8s-job-start expands transfer env in rclone config' >&2
mkdir -p "${workdir}/k8s-home/.ssh" "${workdir}/k8s-host-keys"
printf '%s\n' 'k8s transfer input' > "${workdir}/k8s-transfer-input.txt"
ssh-keygen -q -t ed25519 -N '' -f "${workdir}/k8s-host-keys/ssh_host_ed25519_key" >/dev/null
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
  CONTROL_PLANE_HOST_KEY_DIR="${workdir}/k8s-host-keys" \
  CONTROL_PLANE_JOB_TRANSFER_IMAGE=localhost/control-plane:test \
  TEST_REGRESSION_K8S_MANIFEST_PATH="${workdir}/k8s-job-manifest.yaml" \
  TEST_REGRESSION_K8S_SECRET_ARGS_PATH="${workdir}/k8s-job-secret.args" \
  "${control_plane_bin_dir}/k8s-job-start" \
  --namespace control-plane-ci-jobs \
  --job-name regression-transfer-job \
  --image localhost/execution-plane-smoke:test \
  --mount-file "${workdir}/k8s-transfer-input.txt:inputs/k8s-transfer-input.txt" \
  -- true >/dev/null

grep -qx 'create' "${workdir}/k8s-job-secret.args"
grep -qx 'secret' "${workdir}/k8s-job-secret.args"
grep -qx 'generic' "${workdir}/k8s-job-secret.args"
if grep -Fq '<<RCLONE' "${workdir}/k8s-job-manifest.yaml"; then
  printf 'Expected k8s-job-start to render rclone.conf with printf, not heredocs\n' >&2
  grep -n 'RCLONE' "${workdir}/k8s-job-manifest.yaml" >&2 || true
  exit 1
fi
if [[ "$(grep -Fc "printf 'host = %s\\n' \"\${CONTROL_PLANE_TRANSFER_HOST}\"" "${workdir}/k8s-job-manifest.yaml")" -ne 2 ]]; then
  printf 'Expected both transfer containers to format the rclone host with printf\n' >&2
  grep -n 'rclone.conf\|host = %s\|user = %s\|port = %s' "${workdir}/k8s-job-manifest.yaml" >&2 || true
  exit 1
fi
grep -Fq "printf 'user = %s\\n' \"\${CONTROL_PLANE_TRANSFER_USER}\"" "${workdir}/k8s-job-manifest.yaml"
grep -Fq "printf 'port = %s\\n' \"\${CONTROL_PLANE_TRANSFER_PORT}\"" "${workdir}/k8s-job-manifest.yaml"
if [[ "$(grep -Fc -- '--transfers 1' "${workdir}/k8s-job-manifest.yaml")" -ne 2 ]]; then
  printf 'Expected both transfer containers to serialize rclone transfers\n' >&2
  grep -n 'rclone_flags\|transfers 1\|checkers 1\|sftp-disable-concurrent' "${workdir}/k8s-job-manifest.yaml" >&2 || true
  exit 1
fi
if [[ "$(grep -Fc -- '--checkers 1' "${workdir}/k8s-job-manifest.yaml")" -ne 2 ]]; then
  printf 'Expected both transfer containers to serialize rclone checkers\n' >&2
  grep -n 'rclone_flags\|transfers 1\|checkers 1\|sftp-disable-concurrent' "${workdir}/k8s-job-manifest.yaml" >&2 || true
  exit 1
fi
if [[ "$(grep -Fc -- '--sftp-disable-concurrent-reads' "${workdir}/k8s-job-manifest.yaml")" -ne 2 ]]; then
  printf 'Expected both transfer containers to disable concurrent SFTP reads\n' >&2
  grep -n 'rclone_flags\|transfers 1\|checkers 1\|sftp-disable-concurrent' "${workdir}/k8s-job-manifest.yaml" >&2 || true
  exit 1
fi
if [[ "$(grep -Fc -- '--sftp-disable-concurrent-writes' "${workdir}/k8s-job-manifest.yaml")" -ne 2 ]]; then
  printf 'Expected both transfer containers to disable concurrent SFTP writes\n' >&2
  grep -n 'rclone_flags\|transfers 1\|checkers 1\|sftp-disable-concurrent' "${workdir}/k8s-job-manifest.yaml" >&2 || true
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
  CONTROL_PLANE_HOST_KEY_DIR="${workdir}/k8s-host-keys" \
  TEST_REGRESSION_K8S_MANIFEST_PATH="${workdir}/k8s-job-multiline-manifest.yaml" \
  TEST_REGRESSION_K8S_SECRET_ARGS_PATH="${workdir}/k8s-job-multiline-secret.args" \
  "${control_plane_bin_dir}/k8s-job-start" \
  --namespace control-plane-ci-jobs \
  --job-name regression-multiline-command-job \
  --image localhost/execution-plane-smoke:test \
  -- bash -lc $'printf line-one\nprintf line-two' >/dev/null

assert_multiline_command_block "${workdir}/k8s-job-multiline-manifest.yaml" '|-'

PATH="${workdir}/fake-bin:${control_plane_bin_dir}:${PATH}" \
  HOME="${workdir}/k8s-home" \
  CONTROL_PLANE_RUNTIME_ENV_FILE=/dev/null \
  CONTROL_PLANE_HOST_KEY_DIR="${workdir}/k8s-host-keys" \
  TEST_REGRESSION_K8S_MANIFEST_PATH="${workdir}/k8s-job-multiline-trailing-manifest.yaml" \
  TEST_REGRESSION_K8S_SECRET_ARGS_PATH="${workdir}/k8s-job-multiline-trailing-secret.args" \
  "${control_plane_bin_dir}/k8s-job-start" \
  --namespace control-plane-ci-jobs \
  --job-name regression-multiline-command-trailing-job \
  --image localhost/execution-plane-smoke:test \
  -- bash -lc $'printf line-one\nprintf line-two\n' >/dev/null

assert_multiline_command_block "${workdir}/k8s-job-multiline-trailing-manifest.yaml" '|+'

set +e
newline_transfer_output="$(
  PATH="${workdir}/fake-bin:${control_plane_bin_dir}:${PATH}" \
    HOME="${workdir}/k8s-home" \
    CONTROL_PLANE_RUNTIME_ENV_FILE=/dev/null \
    CONTROL_PLANE_HOST_KEY_DIR="${workdir}/k8s-host-keys" \
    CONTROL_PLANE_JOB_TRANSFER_IMAGE=localhost/control-plane:test \
    CONTROL_PLANE_JOB_TRANSFER_HOST=$'control-plane.example\nmalicious' \
    TEST_REGRESSION_K8S_MANIFEST_PATH="${workdir}/should-not-exist.yaml" \
    TEST_REGRESSION_K8S_SECRET_ARGS_PATH="${workdir}/should-not-exist.args" \
    "${control_plane_bin_dir}/k8s-job-start" \
    --namespace control-plane-ci-jobs \
    --job-name regression-transfer-job-invalid \
    --image localhost/execution-plane-smoke:test \
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

printf '%s\n' 'regression-test: verifying Copilot launcher applies CPU cap, nice, and secret env injection' >&2
cat > "${workdir}/fake-bin/cpulimit" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "${TEST_REGRESSION_LOG_DIR:?}/cpulimit.args"
[[ "${1:-}" == "-f" ]]
[[ "${2:-}" == "-q" ]]
[[ "${3:-}" == "-l" ]]
shift 4
[[ "${1:-}" == "--" ]]
shift
exec "$@"
EOF
chmod +x "${workdir}/fake-bin/cpulimit"

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
  local CONTROL_PLANE_COPILOT_CPU_LIMIT_PERCENT=55
  local CONTROL_PLANE_COPILOT_NICE_LEVEL=7
  export PATH TEST_REGRESSION_LOG_DIR CONTROL_PLANE_RUNTIME_ENV_FILE
  export CONTROL_PLANE_COPILOT_BIN CONTROL_PLANE_COPILOT_GITHUB_TOKEN_FILE
  export CONTROL_PLANE_COPILOT_CPU_LIMIT_PERCENT CONTROL_PLANE_COPILOT_NICE_LEVEL
  "${script_dir}/../containers/control-plane/bin/control-plane-copilot"
}

run_copilot_launcher_test

grep -qx -- '-f' "${workdir}/cpulimit.args"
grep -qx -- '-q' "${workdir}/cpulimit.args"
grep -qx -- '-l' "${workdir}/cpulimit.args"
grep -qx '55' "${workdir}/cpulimit.args"
grep -qx -- '--' "${workdir}/cpulimit.args"
grep -qx 'nice' "${workdir}/cpulimit.args"
grep -qx -- '-n' "${workdir}/nice.args"
grep -qx '7' "${workdir}/nice.args"
grep -qx -- '--yolo' "${workdir}/copilot.args"
grep -qx -- '--secret-env-vars=COPILOT_GITHUB_TOKEN' "${workdir}/copilot.args"
grep -qx 'COPILOT_GITHUB_TOKEN=copilot-token-for-test' "${workdir}/copilot.env"

printf '%s\n' 'regression-test: targeted regressions ok' >&2
