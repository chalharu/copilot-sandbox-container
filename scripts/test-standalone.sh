#!/usr/bin/env bash
set -euo pipefail

control_plane_image="${1:?usage: scripts/test-standalone.sh <control-plane-image> <execution-plane-image>}"
: "${2:?usage: scripts/test-standalone.sh <control-plane-image> <execution-plane-image>}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ssh_port="${CONTROL_PLANE_TEST_SSH_PORT:-2222}"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-docker}"
container_name="control-plane-standalone-test"
workdir="$(mktemp -d)"
state_root="${workdir}/state"
ssh_key="${workdir}/id_ed25519"
control_plane_run_user=(--user 0:0)
container_env=()
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
    --network bridge -p "127.0.0.1:${ssh_port}:2222"
  )

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

  run_args+=("${control_plane_image}")

  "${container_bin}" "${run_args[@]}" >/dev/null
}

require_command "${container_bin}"
require_command ssh
require_command ssh-keygen
require_command ssh-keyscan

mkdir -p "${state_root}/copilot" "${state_root}/gh" "${state_root}/ssh" "${state_root}/ssh-host-keys" "${state_root}/workspace"
ssh-keygen -q -t ed25519 -N '' -f "${ssh_key}"
set_ssh_opts

start_container
wait_for_ssh

"${container_bin}" exec "${container_name}" bash -l -se <<'EOF'
set -euo pipefail
command -v node
command -v npm
npm ls -g @github/copilot --depth=0 | grep -q "@github/copilot@"
! command -v git >/dev/null 2>&1
! command -v gh >/dev/null 2>&1
command -v kubectl
command -v kind
command -v yamllint
command -v control-plane-exec-api
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
test -f /home/copilot/.copilot/skills/repo-change-delivery/SKILL.md
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
test -f "${GIT_CONFIG_GLOBAL}"
grep -Fqx '    hooksPath = /usr/local/share/control-plane/hooks/git' "${GIT_CONFIG_GLOBAL}"
grep -Fqx '    name = Picker Test User' "${GIT_CONFIG_GLOBAL}"
grep -Fqx '    email = picker@example.com' "${GIT_CONFIG_GLOBAL}"
test "$(grep -Fc '    helper = !gh auth git-credential' "${GIT_CONFIG_GLOBAL}")" -eq 2
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
cat "${GIT_CONFIG_GLOBAL}" || true
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
