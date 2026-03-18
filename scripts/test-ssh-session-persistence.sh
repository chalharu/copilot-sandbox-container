#!/usr/bin/env bash
set -euo pipefail

host="127.0.0.1"
port="2222"
user="copilot"
identity_file=""
session_name=""
marker_path=""
hold_seconds=5
attempts=20
connect_timeout=5
workdir=""
ssh_log=""
marker_token_pre=""
marker_token_post=""
local_screen_session=""
local_screen_pid=""
use_remote_check=1

usage() {
  cat <<'EOF' >&2
usage: scripts/test-ssh-session-persistence.sh --identity <key> --session-name <name> --marker-path <path> [options]

Options:
  --host <host>              SSH target host (default: 127.0.0.1)
  --port <port>              SSH target port (default: 2222)
  --user <user>              SSH target user (default: copilot)
  --identity <path>          SSH private key to use
  --session-name <name>      Expected GNU Screen session name created by login
  --marker-path <path>       Remote file path updated through the interactive SSH session
  --hold-seconds <seconds>   Idle time to keep the SSH session attached before the second probe (default: 5)
  --attempts <count>         Poll/write attempts for the session and marker checks (default: 20)
  --no-remote-check          Skip extra SSH probes and rely on the interactive session itself
EOF
  exit 64
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

cleanup() {
  local exit_status=$?

  trap - EXIT
  if [[ -n "${local_screen_session}" ]]; then
    screen -S "${local_screen_session}" -X quit >/dev/null 2>&1 || true
  fi
  if [[ -n "${local_screen_pid}" ]]; then
    wait "${local_screen_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${workdir}" ]]; then
    rm -rf "${workdir}" >/dev/null 2>&1 || true
  fi
  exit "${exit_status}"
}

run_remote_script() {
  local script="$1"

  ssh "${ssh_opts[@]}" "${user}@${host}" 'CONTROL_PLANE_DISABLE_SESSION_PICKER=1 bash -l -se' <<<"${script}"
}

remote_screen_session_exists() {
  local script

  printf -v script 'set -euo pipefail\nscreen -list 2>/dev/null | grep -q -- %q\n' "${session_name}"
  run_remote_script "${script}" >/dev/null
}

remote_marker_matches() {
  local token="$1"
  local script

  printf -v script 'set -euo pipefail\ntest -f %q\ngrep -qx -- %q %q\n' "${marker_path}" "${token}" "${marker_path}"
  run_remote_script "${script}" >/dev/null
}

print_remote_debug() {
  local script

  printf '%s\n' '--- remote screen ---' >&2
  printf -v script 'set -euo pipefail\nscreen -list 2>/dev/null || true\n'
  run_remote_script "${script}" >&2 || true

  printf '%s\n' '--- remote marker ---' >&2
  printf -v script 'set -euo pipefail\nif [[ -f %q ]]; then cat %q; else printf "<missing>\\n"; fi\n' "${marker_path}" "${marker_path}"
  run_remote_script "${script}" >&2 || true
}

fail() {
  local message="$1"

  printf 'ssh-persistence: %s\n' "${message}" >&2
  if [[ -f "${ssh_log}" ]]; then
    printf '%s\n' '--- ssh log ---' >&2
    tail -n 120 "${ssh_log}" >&2 || true
  fi
  print_remote_debug
  exit 1
}

local_ssh_session_exists() {
  screen -list 2>/dev/null | grep -q -- "[.]${local_screen_session}[[:space:]]"
}

ssh_log_has_prompt() {
  grep -Eq ':[^[:cntrl:]]*[#$][[:space:]]' "${ssh_log}" 2>/dev/null
}

ssh_log_has_token() {
  local token="$1"

  grep -Fq -- "${token}" "${ssh_log}" 2>/dev/null
}

wait_for_screen_session() {
  if [[ "${use_remote_check}" -eq 0 ]]; then
    for _ in $(seq 1 "${attempts}"); do
      if ssh_log_has_prompt; then
        return 0
      fi
      if ! local_ssh_session_exists; then
        fail "interactive SSH exited before reaching a shell prompt"
      fi
      sleep 1
    done

    fail "interactive SSH did not reach a shell prompt within ${attempts} attempts"
  fi
  for _ in $(seq 1 "${attempts}"); do
    if remote_screen_session_exists; then
      return 0
    fi
    if ! local_ssh_session_exists; then
      fail "interactive SSH exited before screen session ${session_name} appeared"
    fi
    sleep 1
  done

  fail "screen session ${session_name} did not appear within ${attempts} attempts"
}

send_probe_command() {
  local token="$1"
  local probe_command=""

  printf -v probe_command 'echo %q > %q' "${token}" "${marker_path}"
  screen -S "${local_screen_session}" -X stuff "${probe_command}" >/dev/null 2>&1
  # GNU Screen expects carriage return here to emulate an actual Enter keypress.
  screen -S "${local_screen_session}" -X stuff $'\r' >/dev/null 2>&1
}

wait_for_marker() {
  local token="$1"
  local label="$2"

  if [[ "${use_remote_check}" -eq 0 ]]; then
    for _ in $(seq 1 "${attempts}"); do
      send_probe_command "${token}"
      sleep 1
      if ssh_log_has_token "${token}"; then
        return 0
      fi
      if ! local_ssh_session_exists; then
        fail "interactive SSH exited before the ${label} probe reached the shell"
      fi
    done

    fail "interactive SSH did not echo the ${label} probe command in the SSH log"
  fi

  for _ in $(seq 1 "${attempts}"); do
    send_probe_command "${token}"
    sleep 1
    if remote_marker_matches "${token}"; then
      return 0
    fi
    if ! local_ssh_session_exists; then
      fail "interactive SSH exited before ${label} marker reached ${marker_path}"
    fi
  done

  fail "interactive SSH did not apply the ${label} marker to ${marker_path}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      [[ $# -ge 2 ]] || usage
      host="$2"
      shift 2
      ;;
    --port)
      [[ $# -ge 2 ]] || usage
      port="$2"
      shift 2
      ;;
    --user)
      [[ $# -ge 2 ]] || usage
      user="$2"
      shift 2
      ;;
    --identity)
      [[ $# -ge 2 ]] || usage
      identity_file="$2"
      shift 2
      ;;
    --session-name)
      [[ $# -ge 2 ]] || usage
      session_name="$2"
      shift 2
      ;;
    --marker-path)
      [[ $# -ge 2 ]] || usage
      marker_path="$2"
      shift 2
      ;;
    --hold-seconds)
      [[ $# -ge 2 ]] || usage
      hold_seconds="$2"
      shift 2
      ;;
    --attempts)
      [[ $# -ge 2 ]] || usage
      attempts="$2"
      shift 2
      ;;
    --no-remote-check)
      use_remote_check=0
      shift
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n "${identity_file}" ]] || usage
[[ -n "${session_name}" ]] || usage
[[ -n "${marker_path}" ]] || usage
[[ -f "${identity_file}" ]] || {
  printf 'Missing SSH identity file: %s\n' "${identity_file}" >&2
  exit 1
}

require_command ssh
require_command screen

workdir="$(mktemp -d)"
ssh_log="${workdir}/ssh.log"
marker_token_pre="ssh-persistence-pre-${RANDOM}-${RANDOM}"
marker_token_post="ssh-persistence-post-${RANDOM}-${RANDOM}"
local_screen_session="ssh-persistence-${RANDOM}-${RANDOM}"

ssh_opts=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o ConnectTimeout="${connect_timeout}"
  -i "${identity_file}"
  -p "${port}"
)

trap cleanup EXIT

printf 'ssh-persistence: opening SSH session to %s@%s:%s\n' "${user}" "${host}" "${port}" >&2
printf -v ssh_command 'exec env TERM=tmux-256color ssh -tt'
for ssh_opt in "${ssh_opts[@]}"; do
  printf -v ssh_command '%s %q' "${ssh_command}" "${ssh_opt}"
done
printf -v ssh_command '%s %q' "${ssh_command}" "${user}@${host}"
printf '#!/usr/bin/env bash\n%s\n' "${ssh_command}" > "${workdir}/run-ssh.sh"
chmod 700 "${workdir}/run-ssh.sh"
screen -DmL -Logfile "${ssh_log}" -S "${local_screen_session}" bash "${workdir}/run-ssh.sh" &
local_screen_pid=$!

wait_for_screen_session
wait_for_marker "${marker_token_pre}" "initial"
sleep "${hold_seconds}"
if ! local_ssh_session_exists; then
  fail "interactive SSH exited during the ${hold_seconds}-second hold period"
fi
wait_for_marker "${marker_token_post}" "post-hold"

if grep -q 'cannot change locale' "${ssh_log}"; then
  fail 'unexpected locale warning during SSH login'
fi

printf 'ssh-persistence: session=%s marker=%s ok\n' "${session_name}" "${marker_path}" >&2
