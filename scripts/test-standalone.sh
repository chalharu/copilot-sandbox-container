#!/usr/bin/env bash
set -euo pipefail

control_plane_image="${1:?usage: scripts/test-standalone.sh <control-plane-image> <execution-plane-image>}"
execution_plane_image="${2:?usage: scripts/test-standalone.sh <control-plane-image> <execution-plane-image>}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ssh_port="${CONTROL_PLANE_TEST_SSH_PORT:-2222}"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-podman}"
container_name="control-plane-standalone-test"
workdir="$(mktemp -d)"
state_root="${workdir}/state"
ssh_key="${workdir}/id_ed25519"
control_plane_run_user=(--user 0:0)
container_env=()
host_network_ssh=0
custom_sshd_config=""
ssh_opts=()

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

read_runtime_var() {
  local var_name="$1"
  local runtime_env_file="${CONTROL_PLANE_RUNTIME_ENV_FILE:-${HOME:-/home/${USER:-copilot}}/.config/control-plane/runtime.env}"

  [[ -f "${runtime_env_file}" ]] || return 1
  sed -n "s/^${var_name}=//p" "${runtime_env_file}" | head -n 1
}

prepare_host_network_ssh() {
  local runtime_mode=""
  local default_network=""

  runtime_mode="$(read_runtime_var CONTROL_PLANE_LOCAL_PODMAN_MODE || true)"
  default_network="$(read_runtime_var CONTROL_PLANE_PODMAN_DEFAULT_NETWORK || true)"

  [[ "${container_bin}" == "podman" ]] || return 0
  [[ "${runtime_mode}" == "rootful-service" ]] || return 0
  [[ "${default_network}" == "host" ]] || return 0

  host_network_ssh=1
  if [[ "${ssh_port}" == "2222" ]]; then
    ssh_port="${CONTROL_PLANE_TEST_HOST_NETWORK_SSH_PORT:-22222}"
  fi
  custom_sshd_config="${workdir}/sshd_config"
  sed \
    -e "s/^Port .*/Port ${ssh_port}/" \
    "${script_dir}/../containers/control-plane/config/sshd_config" \
    > "${custom_sshd_config}"
  printf 'standalone-test: using host-network SSH fallback on port %s\n' "${ssh_port}" >&2
}

set_ssh_opts() {
  ssh_opts=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o IdentitiesOnly=yes
    -o SetEnv=LC_ALL=en_US.UTF8
    -i "${ssh_key}"
    -p "${ssh_port}"
  )
}

ssh_cmd() {
  # shellcheck disable=SC2029
  ssh "${ssh_opts[@]}" copilot@127.0.0.1 "$@"
}

ssh_bash() {
  ssh "${ssh_opts[@]}" copilot@127.0.0.1 'bash -l -se'
}

wait_for_ssh() {
  local _
  for _ in $(seq 1 30); do
    if ssh_cmd true >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  printf 'Timed out waiting for SSH on port %s\n' "${ssh_port}" >&2
  exit 1
}

wait_for_screen_session() {
  local target_session="$1"
  local attempts="${2:-15}"
  local _

  for _ in $(seq 1 "${attempts}"); do
    if ssh_bash <<EOF >/dev/null 2>&1
set -euo pipefail
screen -list | grep -q -- '${target_session}'
EOF
    then
      return 0
    fi
    sleep 1
  done

  return 1
}

wait_for_screen_term() {
  local target_session="$1"
  local term_file="$2"
  local expected_term_pattern="${3:-screen-256color(-bce)?}"
  local attempts="${4:-15}"
  local remote_command
  local _

  printf -v remote_command 'TARGET_SESSION=%q TERM_FILE=%q EXPECTED_TERM_PATTERN=%q bash -l -se' \
    "${target_session}" "${term_file}" "${expected_term_pattern}"

  for _ in $(seq 1 "${attempts}"); do
    # shellcheck disable=SC2029
    if ssh "${ssh_opts[@]}" copilot@127.0.0.1 "${remote_command}" <<'EOF' >/dev/null 2>&1
set -euo pipefail
screen -list | grep -q -- "${TARGET_SESSION}"
grep -Eq -- "^(${EXPECTED_TERM_PATTERN})$" "${TERM_FILE}"
EOF
    then
      return 0
    fi
    sleep 1
  done

  return 1
}

wait_for_remote_grep() {
  local remote_pattern="$1"
  local remote_path="$2"
  local attempts="${3:-15}"
  local remote_command
  local _

  printf -v remote_command 'REMOTE_PATTERN=%q REMOTE_PATH=%q bash -l -se' \
    "${remote_pattern}" "${remote_path}"

  for _ in $(seq 1 "${attempts}"); do
    # shellcheck disable=SC2029
    if ssh "${ssh_opts[@]}" copilot@127.0.0.1 "${remote_command}" <<'EOF' >/dev/null 2>&1
set -euo pipefail
grep -Eq -- "${REMOTE_PATTERN}" "${REMOTE_PATH}"
EOF
    then
      return 0
    fi
    sleep 1
  done

  return 1
}

ssh_host_fingerprint() {
  local fingerprint

  fingerprint="$(ssh-keyscan -p "${ssh_port}" 127.0.0.1 2>/dev/null | ssh-keygen -lf - | awk '/ED25519/ { print $2; exit }')"
  [[ -n "${fingerprint}" ]] || {
    printf 'Unable to read SSH host key fingerprint on port %s\n' "${ssh_port}" >&2
    exit 1
  }

  printf '%s\n' "${fingerprint}"
}

start_container() {
  local run_args=(
    run -d --rm
    "${control_plane_run_user[@]}"
    --name "${container_name}"
    --cap-add AUDIT_WRITE
    -e SSH_PUBLIC_KEY="$(cat "${ssh_key}.pub")"
  )

  if [[ "${host_network_ssh}" -eq 1 ]]; then
    # The host-network fallback only activates when the outer podman wrapper already
    # defaults local runs to `--network=host`; adding it again makes raw Podman reject
    # the run as multiple network selections.
    :
  else
    run_args+=(--network bridge -p "127.0.0.1:${ssh_port}:2222")
  fi

  if ((${#container_env[@]} > 0)); then
    run_args+=("${container_env[@]}")
  fi

  run_args+=(
    -v "${state_root}/copilot:/home/copilot/.copilot"
    -v "${state_root}/gh:/home/copilot/.config/gh"
    -v "${state_root}/ssh:/home/copilot/.ssh"
    -v "${state_root}/ssh-host-keys:/var/lib/control-plane/ssh-host-keys"
    -v "${state_root}/workspace:/workspace"
  )

  if [[ "${host_network_ssh}" -eq 1 ]]; then
    run_args+=(-v "${custom_sshd_config}:/etc/ssh/sshd_config:ro")
  fi

  run_args+=("${control_plane_image}")

  "${container_bin}" "${run_args[@]}" >/dev/null
}

require_command "${container_bin}"
require_command ssh
require_command ssh-keygen
require_command ssh-keyscan

mkdir -p "${state_root}/copilot" "${state_root}/gh" "${state_root}/ssh" "${state_root}/ssh-host-keys" "${state_root}/workspace"
ssh-keygen -q -t ed25519 -N '' -f "${ssh_key}"
prepare_host_network_ssh
set_ssh_opts

start_container
wait_for_ssh

"${container_bin}" exec "${container_name}" bash -l -se <<'EOF'
set -euo pipefail
command -v node
command -v npm
npm ls -g @github/copilot --depth=0 | grep -q "@github/copilot@"
command -v git
command -v gh
command -v kubectl
command -v podman
command -v docker
command -v kind
docker --version >/dev/null
command -v sshd
command -v screen
command -v vim
command -v control-plane-run
command -v control-plane-session
command -v k8s-job-start
command -v k8s-job-wait
command -v k8s-job-pod
command -v k8s-job-logs
command -v k8s-job-run
test "$(TERM=xterm-256color tput colors)" -ge 256
test "$(TERM=screen-256color tput colors)" -ge 256
test "$(TERM=tmux-256color tput colors)" -ge 256
printf '%s\n' "${LANG}" | grep -qi 'utf-8'
locale -a | grep -Eqi '^en_US\.utf-?8$'
locale -a | grep -Eqi '^ja_JP\.utf-?8$'
test "${EDITOR}" = "vim"
test "${VISUAL}" = "vim"
test "${GH_PAGER}" = "cat"
test -f /home/copilot/.copilot/skills/control-plane-operations/SKILL.md
test -f /home/copilot/.copilot/skills/control-plane-operations/references/control-plane-run.md
test -f /home/copilot/.copilot/skills/containerized-yamllint-ops/SKILL.md
test -f /home/copilot/.copilot/skills/repo-change-delivery/SKILL.md
grep -q "^copilot:" /etc/subuid
grep -q "^copilot:" /etc/subgid
grep -qx 'cgroup_manager = "cgroupfs"' /home/copilot/.config/containers/containers.conf
grep -qx 'events_logger = "file"' /home/copilot/.config/containers/containers.conf
expected_driver=""
expected_state_dir=""
expected_state_root="/var/tmp/control-plane/rootless-podman"
if [[ -e /dev/fuse ]]; then
  expected_driver=overlay
else
  expected_driver=vfs
fi
expected_state_dir="${expected_state_root}/${expected_driver}"
test "$(readlink /home/copilot/.copilot/containers)" = "${expected_state_root}"
test "$(readlink /home/copilot/.local/share/containers)" = "${expected_state_dir}"
grep -qx "graphroot = \"${expected_state_dir}/storage\"" /home/copilot/.config/containers/storage.conf
grep -qx "runroot = \"/run/user/1000/${expected_driver}/containers/storage\"" /home/copilot/.config/containers/storage.conf
if [[ "${expected_driver}" == "overlay" ]]; then
  grep -qx 'driver = "overlay"' /home/copilot/.config/containers/storage.conf
  grep -qx 'mount_program = "/usr/bin/fuse-overlayfs"' /home/copilot/.config/containers/storage.conf
else
  grep -qx 'driver = "vfs"' /home/copilot/.config/containers/storage.conf
  ! grep -q 'mount_program' /home/copilot/.config/containers/storage.conf
fi
test -d "${expected_state_dir}/storage/${expected_driver}"
test -d "${expected_state_dir}/storage/volumes"
EOF

ssh_bash <<'EOF'
set -euo pipefail
printf '%s\n' "${LANG}" | grep -qi 'utf-8'
test "${LC_ALL}" = "en_US.UTF8"
locale charmap | grep -qx 'UTF-8'
test "${EDITOR}" = "vim"
test "${VISUAL}" = "vim"
test "${GH_PAGER}" = "cat"
mkdir -p ~/.copilot ~/.config/gh /workspace
echo standalone > ~/.copilot/state.txt
echo gh > ~/.config/gh/state.txt
echo ssh > ~/.ssh/state.txt
screen -T screen-256color -dmS smoke-session sh -lc 'printf "%s\n" "$TERM" > /workspace/screen-term.txt; printf "日本語★\n" > /workspace/screen-utf8.txt; echo screen-ok > /workspace/screen.txt; sleep 30'
EOF

printf '%s\n' 'standalone-test: verifying login TERM fallback' >&2
if ! TERM=bogusterm ssh -tt "${ssh_opts[@]}" copilot@127.0.0.1 \
  "CONTROL_PLANE_DISABLE_SESSION_PICKER=1 bash -lic 'printf \"%s\n\" \"\$TERM\" > /workspace/login-term.txt; tput colors > /workspace/login-colors.txt'" \
  </dev/null >"${workdir}/ssh-login-term.log" 2>&1; then
  cat "${workdir}/ssh-login-term.log" >&2 || true
  printf 'Expected login shell TERM fallback to succeed over SSH\n' >&2
  exit 1
fi
if ! ssh_bash <<'EOF'
set -euo pipefail
grep -Eq '^(xterm-256color|xterm)$' /workspace/login-term.txt
awk 'NR == 1 { exit !($1 >= 8) }' /workspace/login-colors.txt
EOF
then
  ssh_bash <<'EOF' >&2 || true
set -euo pipefail
cat /workspace/login-term.txt || true
cat /workspace/login-colors.txt || true
EOF
  printf 'Expected login shell TERM fallback files to report a usable terminal\n' >&2
  exit 1
fi
printf '%s\n' 'standalone-test: login TERM fallback ok' >&2

printf '%s\n' 'standalone-test: verifying login TERM upgrade to 256 colors' >&2
if ! TERM=xterm-color ssh -tt "${ssh_opts[@]}" copilot@127.0.0.1 \
  "CONTROL_PLANE_DISABLE_SESSION_PICKER=1 bash -lic 'printf \"%s\n\" \"\$TERM\" > /workspace/login-term-upgrade.txt; tput colors > /workspace/login-term-upgrade-colors.txt'" \
  </dev/null >"${workdir}/ssh-login-term-upgrade.log" 2>&1; then
  cat "${workdir}/ssh-login-term-upgrade.log" >&2 || true
  printf 'Expected login shell TERM upgrade to succeed over SSH\n' >&2
  exit 1
fi
if ! ssh_bash <<'EOF'
set -euo pipefail
grep -qx 'xterm-256color' /workspace/login-term-upgrade.txt
awk 'NR == 1 { exit !($1 >= 256) }' /workspace/login-term-upgrade-colors.txt
EOF
then
  ssh_bash <<'EOF' >&2 || true
set -euo pipefail
cat /workspace/login-term-upgrade.txt || true
cat /workspace/login-term-upgrade-colors.txt || true
EOF
  printf 'Expected login TERM upgrade files to report xterm-256color with 256 colors\n' >&2
  exit 1
fi
printf '%s\n' 'standalone-test: login TERM upgrade ok' >&2

utf8_roundtrip="$(ssh_bash <<'EOF'
set -euo pipefail
printf '日本語★\n'
EOF
)"
[[ "${utf8_roundtrip}" == "日本語★" ]]

if ! wait_for_screen_term smoke-session /workspace/screen-term.txt; then
  ssh_bash <<'EOF' >&2 || true
set -euo pipefail
screen -list || true
cat /workspace/screen-term.txt || true
cat /workspace/screen-utf8.txt || true
EOF
  printf 'Expected smoke-session to report a screen-256color TERM variant\n' >&2
  exit 1
fi

if ! wait_for_remote_grep '^日本語★$' /workspace/screen-utf8.txt; then
  ssh_bash <<'EOF' >&2 || true
set -euo pipefail
cat /workspace/screen-term.txt || true
cat /workspace/screen-utf8.txt || true
cat /workspace/screen.txt || true
EOF
  printf 'Expected smoke-session to persist UTF-8 screen output\n' >&2
  exit 1
fi

if ! wait_for_remote_grep '^screen-ok$' /workspace/screen.txt; then
  ssh_bash <<'EOF' >&2 || true
set -euo pipefail
cat /workspace/screen-term.txt || true
cat /workspace/screen-utf8.txt || true
cat /workspace/screen.txt || true
EOF
  printf 'Expected smoke-session to persist screen status output\n' >&2
  exit 1
fi

printf '%s\n' 'standalone-test: screen output ready' >&2

printf '%s\n' 'standalone-test: verifying session picker fallback' >&2
if ! TERM=tmux-256color ssh -tt "${ssh_opts[@]}" copilot@127.0.0.1 \
  "CONTROL_PLANE_SESSION_SELECTION=9999 bash -lic 'printf \"%s\n\" fallback-shell-ok'" \
  </dev/null >"${workdir}/ssh-picker-fallback.log" 2>&1; then
  cat "${workdir}/ssh-picker-fallback.log" >&2 || true
  printf 'Expected SSH login to fall back to a shell when the session picker fails\n' >&2
  exit 1
fi
if ! grep -q 'fallback-shell-ok' "${workdir}/ssh-picker-fallback.log"; then
  printf 'Expected fallback-shell-ok marker in standalone SSH fallback log\n' >&2
  cat "${workdir}/ssh-picker-fallback.log" >&2 || true
  exit 1
fi
if ! grep -q 'session picker failed; continuing with the login shell' "${workdir}/ssh-picker-fallback.log"; then
  printf 'Expected session picker fallback warning in standalone SSH fallback log\n' >&2
  cat "${workdir}/ssh-picker-fallback.log" >&2 || true
  exit 1
fi
printf '%s\n' 'standalone-test: session picker fallback ok' >&2

printf '%s\n' 'standalone-test: verifying picker menu options' >&2
if ! ssh_bash <<'EOF'
set -euo pipefail
screen -T screen-256color -dmS shell bash -lc 'sleep 30'
EOF
then
  printf 'Expected shell session fixture for picker menu test\n' >&2
  exit 1
fi
set +e
printf '9999\n' | TERM=tmux-256color ssh -tt "${ssh_opts[@]}" copilot@127.0.0.1 \
  "control-plane-session --select" >"${workdir}/ssh-picker-menu.log" 2>&1
picker_menu_status=$?
set -e
if [[ "${picker_menu_status}" -eq 0 ]]; then
  printf 'Expected picker menu probe to fail on invalid selection\n' >&2
  cat "${workdir}/ssh-picker-menu.log" >&2 || true
  exit 1
fi
if ! grep -Fq 'Copilot (/workspace, --yolo)' "${workdir}/ssh-picker-menu.log"; then
  printf 'Expected picker menu to show the Copilot option when only shell sessions exist\n' >&2
  cat "${workdir}/ssh-picker-menu.log" >&2 || true
  exit 1
fi
printf '%s\n' 'standalone-test: picker menu shows Copilot option' >&2

printf '%s\n' 'standalone-test: starting fake podman checks' >&2
if ! ssh_bash <<EOF
set -euo pipefail
printf 'small input\n' > /workspace/job-input.txt
printf 'colon input\n' > '/workspace/job:input.txt'
cat > /tmp/fake-podman-success <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'fake success stderr' >&2
printf '%s\n' "\$@" > /tmp/fake-podman-success.log
INNER
chmod +x /tmp/fake-podman-success
timeout 10s bash -lc 'CONTROL_PLANE_PODMAN_BIN=/tmp/fake-podman-success control-plane-podman info' \
  >/tmp/fake-podman-success.stdout 2>/tmp/fake-podman-success.stderr
grep -qx 'info' /tmp/fake-podman-success.log
grep -q 'fake success stderr' /tmp/fake-podman-success.stderr
cat > /tmp/fake-podman <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "pull" ]]; then
  printf '%s\n' 'WARN[0000] "/" is not a shared mount, this could cause issues or missing mounts with rootless containers' >&2
  printf '%s\n' 'cannot clone: Operation not permitted' >&2
  printf '%s\n' 'ERRO[0000] invalid internal status, try resetting the pause process with "/usr/bin/podman system migrate": cannot re-exec process' >&2
  exit 125
fi
printf '%s\n' "\$@" > /tmp/fake-podman.log
INNER
chmod +x /tmp/fake-podman
CONTROL_PLANE_PODMAN_BIN=/tmp/fake-podman control-plane-run --mode auto --execution-hint short --workspace /workspace --mount-file /workspace/job-input.txt:inputs/job-input.txt --image ${execution_plane_image} -- /usr/local/bin/execution-plane-smoke write-marker /workspace/podman-auto.txt short
grep -q '^run$' /tmp/fake-podman.log
grep -q '${execution_plane_image}' /tmp/fake-podman.log
grep -q '/workspace:/workspace' /tmp/fake-podman.log
grep -Eq ':/var/run/control-plane/job-inputs:ro$' /tmp/fake-podman.log
CONTROL_PLANE_PODMAN_BIN=/tmp/fake-podman control-plane-run --mode auto --execution-hint short --workspace /workspace --mount-file '/workspace/job:input.txt' --image ${execution_plane_image} -- /usr/local/bin/execution-plane-smoke write-marker /workspace/podman-auto-colon.txt short
grep -Eq ':/var/run/control-plane/job-inputs:ro$' /tmp/fake-podman.log
set +e
fake_podman_output="\$(CONTROL_PLANE_PODMAN_BIN=/tmp/fake-podman control-plane-podman pull quay.io/example/test:latest 2>&1)"
fake_podman_status=\$?
set -e
printf '%s\n' "\${fake_podman_output}" > /tmp/fake-podman-pull.log
if [[ "\${fake_podman_status}" -eq 0 ]]; then
  printf 'Expected fake control-plane-podman pull to fail\n' >&2
  exit 1
fi
grep -q 'cannot clone: Operation not permitted' /tmp/fake-podman-pull.log
grep -q 'rootless Podman is blocked by the outer runtime' /tmp/fake-podman-pull.log
grep -q 'SETFCAP' /tmp/fake-podman-pull.log
grep -q 'CONTROL_PLANE_RUN_MODE=k8s-job' /tmp/fake-podman-pull.log
cat > /tmp/fake-podman-migrate <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
state_file=/tmp/fake-podman-migrate-state
if [[ "\${1:-}" == "system" ]] && [[ "\${2:-}" == "migrate" ]]; then
  : > "\${state_file}"
  exit 0
fi
if [[ "\${1:-}" == "pull" ]]; then
  if [[ ! -f "\${state_file}" ]]; then
    printf '%s\n' 'ERRO[0000] invalid internal status, try resetting the pause process with "/usr/bin/podman system migrate": cannot re-exec process' >&2
    exit 125
  fi
  printf '%s\n' "\$@" > /tmp/fake-podman-migrate.log
  exit 0
fi
printf '%s\n' "\$@" > /tmp/fake-podman-migrate.log
INNER
chmod +x /tmp/fake-podman-migrate
set +e
fake_migrate_output="\$(CONTROL_PLANE_PODMAN_BIN=/tmp/fake-podman-migrate control-plane-podman pull quay.io/example/test:latest 2>&1)"
fake_migrate_status=\$?
set -e
printf '%s\n' "\${fake_migrate_output}" > /tmp/fake-podman-migrate-output.log
if [[ "\${fake_migrate_status}" -ne 0 ]]; then
  printf 'Expected control-plane-podman to recover after podman system migrate\n' >&2
  exit 1
fi
grep -q '^pull$' /tmp/fake-podman-migrate.log
grep -q '^quay.io/example/test:latest$' /tmp/fake-podman-migrate.log
grep -q 'detected stale rootless Podman state' /tmp/fake-podman-migrate-output.log
grep -q 'repaired the local Podman state' /tmp/fake-podman-migrate-output.log
EOF
then
  ssh_bash <<'EOF' >&2 || true
set -euo pipefail
cat /tmp/fake-podman.log || true
cat /tmp/fake-podman-success.log || true
cat /tmp/fake-podman-success.stderr || true
cat /tmp/fake-podman-pull.log || true
cat /tmp/fake-podman-migrate.log || true
cat /tmp/fake-podman-migrate-output.log || true
ls -l /workspace || true
EOF
  printf 'Expected fake podman control-plane-run checks to succeed\n' >&2
  exit 1
fi
printf '%s\n' 'standalone-test: fake podman checks done' >&2

printf '%s\n' 'standalone-test: verifying actual podman run returns' >&2
if ! ssh_bash <<'EOF'
set -euo pipefail
actual_podman_status=success
set +e
timeout 20s podman info --format '{{.Store.GraphDriverName}}' >/tmp/actual-podman-info.log 2>&1
info_status=$?
timeout 20s podman unshare true >/tmp/actual-podman-unshare.log 2>&1
unshare_status=$?
set -e
if [[ "${info_status}" -ne 0 ]] || [[ "${unshare_status}" -ne 0 ]]; then
  if grep -Eiq 'cannot clone: Operation not permitted|cannot re-exec process|cannot set user namespace|creating new namespace.*Operation not permitted|newuidmap.*Operation not permitted|newgidmap.*Operation not permitted' /tmp/actual-podman-info.log /tmp/actual-podman-unshare.log; then
    actual_podman_status=blocked
  else
    exit 1
  fi
fi
if [[ "${actual_podman_status}" == "success" ]]; then
  timeout 30s podman pull docker.io/library/hello-world:latest >/tmp/actual-podman-pull.log 2>&1
  timeout 20s podman run --rm --network=none docker.io/library/hello-world:latest >/tmp/actual-podman-run.log 2>&1
  grep -q 'Hello from Docker!' /tmp/actual-podman-run.log
fi
printf '%s\n' "${actual_podman_status}" > /tmp/actual-podman-status.txt
EOF
then
  ssh_bash <<'EOF' >&2 || true
set -euo pipefail
cat /tmp/actual-podman-status.txt || true
cat /tmp/actual-podman-info.log || true
cat /tmp/actual-podman-unshare.log || true
cat /tmp/actual-podman-pull.log || true
cat /tmp/actual-podman-run.log || true
podman ps -a || true
EOF
  printf 'Expected actual podman pull/run to complete without hanging in standalone mode\n' >&2
  exit 1
fi
actual_podman_status="$(ssh_bash <<'EOF'
set -euo pipefail
cat /tmp/actual-podman-status.txt
EOF
)"
actual_podman_status="$(printf '%s' "${actual_podman_status}" | tr -d '\r\n')"
if [[ "${actual_podman_status}" == "success" ]]; then
  printf '%s\n' 'standalone-test: actual podman run returns' >&2
else
  printf '%s\n' 'standalone-test: local podman is blocked by the outer runtime; skipping attached run regression in standalone mode' >&2
fi

first_host_fingerprint="$(ssh_host_fingerprint)"

"${container_bin}" rm -f "${container_name}" >/dev/null
start_container
wait_for_ssh

second_host_fingerprint="$(ssh_host_fingerprint)"
[[ "${first_host_fingerprint}" == "${second_host_fingerprint}" ]]

printf '%s\n' 'standalone-test: checking persisted state after restart' >&2
if ! ssh_bash <<'EOF'
set -euo pipefail
test -f ~/.copilot/state.txt
test -f ~/.config/gh/state.txt
test -f ~/.ssh/state.txt
test -f /workspace/screen.txt
EOF
then
  ssh_bash <<'EOF' >&2 || true
set -euo pipefail
ls -la ~/.copilot || true
ls -la ~/.config/gh || true
ls -la ~/.ssh || true
ls -la /workspace || true
cat /workspace/screen-term.txt || true
cat /workspace/screen-utf8.txt || true
cat /workspace/screen.txt || true
EOF
  printf 'Expected control-plane state to persist after restart\n' >&2
  exit 1
fi
printf '%s\n' 'standalone-test: persisted state looks good' >&2

set +e
missing_caps_output="$("${container_bin}" run --rm "${control_plane_run_user[@]}" --cap-drop ALL "${control_plane_image}" 2>&1)"
missing_caps_status=$?
set -e
printf '%s\n' 'standalone-test: checking cap-drop diagnostics' >&2
if [[ "${missing_caps_status}" -eq 0 ]]; then
  printf 'Expected cap-drop ALL container startup to fail\n' >&2
  printf '%s\n' "${missing_caps_output}" >&2
  exit 1
fi
if ! grep -q 'Missing Linux capabilities for control-plane startup' <<<"${missing_caps_output}"; then
  printf 'Expected missing capability diagnostic in cap-drop ALL output\n' >&2
  printf '%s\n' "${missing_caps_output}" >&2
  exit 1
fi
if ! grep -q 'AUDIT_WRITE' <<<"${missing_caps_output}"; then
  printf 'Expected AUDIT_WRITE in cap-drop ALL output\n' >&2
  printf '%s\n' "${missing_caps_output}" >&2
  exit 1
fi
if ! grep -q 'SYS_CHROOT' <<<"${missing_caps_output}"; then
  printf 'Expected SYS_CHROOT in cap-drop ALL output\n' >&2
  printf '%s\n' "${missing_caps_output}" >&2
  exit 1
fi
printf '%s\n' 'standalone-test: cap-drop diagnostics look good' >&2

"${container_bin}" rm -f "${container_name}" >/dev/null
container_env=(-e CONTROL_PLANE_SESSION_SELECTION=new:auto-login)
start_container
wait_for_ssh

printf '%s\n' 'standalone-test: starting auto-login ssh flow' >&2
"${script_dir}/test-ssh-session-persistence.sh" \
  --identity "${ssh_key}" \
  --port "${ssh_port}" \
  --session-name auto-login \
  --marker-path /workspace/standalone-auto-login-marker.txt
printf '%s\n' 'standalone-test: auto-login session ready' >&2
printf '%s\n' 'standalone-test: auto-login locale ok' >&2

"${container_bin}" rm -f "${container_name}" >/dev/null
container_env=(
  -e CONTROL_PLANE_COPILOT_BIN=/workspace/test-copilot
  -e CONTROL_PLANE_COPILOT_SESSION=picker-copilot
  -e CONTROL_PLANE_SESSION_SELECTION=copilot
  -e "CONTROL_PLANE_GIT_USER_NAME=Picker Test User"
  -e CONTROL_PLANE_GIT_USER_EMAIL=picker@example.com
  -e COPILOT_GITHUB_TOKEN=picker-token
)
start_container
wait_for_ssh

printf '%s\n' 'standalone-test: preparing copilot picker state' >&2
if ! ssh_bash <<'EOF'
set -euo pipefail
test -z "${COPILOT_GITHUB_TOKEN:-}"
test "$(git config --global user.name)" = "Picker Test User"
test "$(git config --global user.email)" = "picker@example.com"
mapfile -t github_helpers < <(git config --global --get-all credential.https://github.com.helper)
test "${#github_helpers[@]}" -eq 2
test -z "${github_helpers[0]}"
test "${github_helpers[1]}" = "!/usr/bin/gh auth git-credential"
mapfile -t gist_helpers < <(git config --global --get-all credential.https://gist.github.com.helper)
test "${#gist_helpers[@]}" -eq 2
test -z "${gist_helpers[0]}"
test "${gist_helpers[1]}" = "!/usr/bin/gh auth git-credential"
cat > /workspace/test-copilot <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
pwd > /workspace/copilot-picker-pwd.txt
printf '%s\n' "$@" > /workspace/copilot-picker-args.txt
printenv COPILOT_GITHUB_TOKEN > /workspace/copilot-picker-token.txt
sleep 30
INNER
chmod +x /workspace/test-copilot

screen -T screen-256color -dmS picker-copilot bash -lc 'sleep 30'
session_id=""
for _ in $(seq 1 15); do
  session_id="$(screen -list 2>/dev/null | awk '/picker-copilot/ && !/\(Dead/ { print $1; exit }')"
  if [[ -n "${session_id}" ]]; then
    break
  fi
  sleep 1
done
test -n "${session_id}"
kill -9 "${session_id%%.*}"
for _ in $(seq 1 15); do
  if screen -list 2>/dev/null | grep -Eq 'picker-copilot.*\(Dead'; then
    break
  fi
  sleep 1
done
screen -list 2>/dev/null | grep -Eq 'picker-copilot.*\(Dead'
if control-plane-session --list | grep -q 'picker-copilot'; then
  printf 'Dead picker-copilot session leaked into control-plane-session --list\n' >&2
  exit 1
fi
EOF
then
  ssh_bash <<'EOF' >&2 || true
set -euo pipefail
git config --global --list || true
screen -list || true
control-plane-session --list || true
ls -la /workspace || true
EOF
  printf 'Expected Copilot picker preconditions to be configured correctly\n' >&2
  exit 1
fi
printf '%s\n' 'standalone-test: copilot picker state prepared' >&2

printf '%s\n' 'standalone-test: starting copilot ssh flow' >&2
TERM=tmux-256color ssh -tt "${ssh_opts[@]}" copilot@127.0.0.1 </dev/null >"${workdir}/ssh-copilot.log" 2>&1 &
copilot_ssh_pid=$!
if ! ssh_bash <<'EOF'
set -euo pipefail
for _ in $(seq 1 15); do
  if [[ -f /workspace/copilot-picker-pwd.txt ]] && [[ -f /workspace/copilot-picker-args.txt ]]; then
    break
  fi
  sleep 1
done
test -f /workspace/copilot-picker-pwd.txt
test -f /workspace/copilot-picker-args.txt
test -f /workspace/copilot-picker-token.txt
if screen -list 2>/dev/null | grep -Eq 'picker-copilot.*\(Dead'; then
  printf 'Expected stale picker-copilot session to be wiped before creating a new one\n' >&2
  exit 1
fi
grep -qx '/workspace' /workspace/copilot-picker-pwd.txt
grep -qx -- '--secret-env-vars=COPILOT_GITHUB_TOKEN' /workspace/copilot-picker-args.txt
grep -qx -- '--yolo' /workspace/copilot-picker-args.txt
grep -qx 'picker-token' /workspace/copilot-picker-token.txt
EOF
then
  printf 'Expected Copilot picker option to create picker-copilot session during SSH login\n' >&2
  cat "${workdir}/ssh-copilot.log" >&2 || true
  exit 1
fi
printf '%s\n' 'standalone-test: copilot ssh flow ready' >&2

kill "${copilot_ssh_pid}" >/dev/null 2>&1 || true
wait "${copilot_ssh_pid}" 2>/dev/null || true
if ! grep -Fq 'Starting Copilot session picker-copilot in /workspace...' "${workdir}/ssh-copilot.log"; then
  printf 'Expected Copilot SSH login to print a startup banner before attaching Screen\n' >&2
  cat "${workdir}/ssh-copilot.log" >&2 || true
  exit 1
fi
if grep -q 'cannot change locale' "${workdir}/ssh-copilot.log"; then
  printf 'Unexpected locale warning during Copilot SSH login\n' >&2
  cat "${workdir}/ssh-copilot.log" >&2 || true
  exit 1
fi
printf '%s\n' 'standalone-test: copilot ssh banner ok' >&2
