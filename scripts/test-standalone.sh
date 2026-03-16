#!/usr/bin/env bash
set -euo pipefail

control_plane_image="${1:?usage: scripts/test-standalone.sh <control-plane-image> <execution-plane-image>}"
execution_plane_image="${2:?usage: scripts/test-standalone.sh <control-plane-image> <execution-plane-image>}"
ssh_port="${CONTROL_PLANE_TEST_SSH_PORT:-2222}"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-podman}"
container_name="control-plane-standalone-test"
workdir="$(mktemp -d)"
state_root="${workdir}/state"
ssh_key="${workdir}/id_ed25519"
container_env=()

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

ssh_opts=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o IdentitiesOnly=yes
  -i "${ssh_key}"
  -p "${ssh_port}"
)

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
    --name "${container_name}"
    -p "127.0.0.1:${ssh_port}:2222"
    -e SSH_PUBLIC_KEY="$(cat "${ssh_key}.pub")"
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
    "${control_plane_image}"
  )

  "${container_bin}" "${run_args[@]}" >/dev/null
}

require_command "${container_bin}"
require_command ssh
require_command ssh-keygen
require_command ssh-keyscan

mkdir -p "${state_root}/copilot" "${state_root}/gh" "${state_root}/ssh" "${state_root}/ssh-host-keys" "${state_root}/workspace"
ssh-keygen -q -t ed25519 -N '' -f "${ssh_key}"

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
command -v buildah
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
test "${EDITOR}" = "vim"
test "${VISUAL}" = "vim"
test "${BUILDAH_ISOLATION}" = "chroot"
test "${GH_PAGER}" = "cat"
test -f /home/copilot/.copilot/skills/control-plane-operations/SKILL.md
test -f /home/copilot/.copilot/skills/control-plane-operations/references/control-plane-run.md
grep -q "^copilot:" /etc/subuid
grep -q "^copilot:" /etc/subgid
EOF

ssh_bash <<'EOF'
set -euo pipefail
test "${EDITOR}" = "vim"
test "${VISUAL}" = "vim"
test "${BUILDAH_ISOLATION}" = "chroot"
test "${GH_PAGER}" = "cat"
mkdir -p ~/.copilot ~/.config/gh /workspace
echo standalone > ~/.copilot/state.txt
echo gh > ~/.config/gh/state.txt
echo ssh > ~/.ssh/state.txt
screen -T screen-256color -dmS smoke-session sh -lc 'printf "%s\n" "$TERM" > /workspace/screen-term.txt; echo screen-ok > /workspace/screen.txt; sleep 30'
EOF

if ! wait_for_screen_term smoke-session /workspace/screen-term.txt; then
  ssh_bash <<'EOF' >&2 || true
set -euo pipefail
screen -list || true
cat /workspace/screen-term.txt || true
EOF
  printf 'Expected smoke-session to report a screen-256color TERM variant\n' >&2
  exit 1
fi

ssh_bash <<EOF
set -euo pipefail
cat > /tmp/fake-podman <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$@" > /tmp/fake-podman.log
INNER
chmod +x /tmp/fake-podman
CONTROL_PLANE_PODMAN_BIN=/tmp/fake-podman control-plane-run --mode auto --execution-hint short --workspace /workspace --image ${execution_plane_image} -- /usr/local/bin/execution-plane-smoke write-marker /workspace/podman-auto.txt short
grep -q '^run$' /tmp/fake-podman.log
grep -q '${execution_plane_image}' /tmp/fake-podman.log
grep -q '/workspace:/workspace' /tmp/fake-podman.log
EOF

first_host_fingerprint="$(ssh_host_fingerprint)"

"${container_bin}" rm -f "${container_name}" >/dev/null
start_container
wait_for_ssh

second_host_fingerprint="$(ssh_host_fingerprint)"
[[ "${first_host_fingerprint}" == "${second_host_fingerprint}" ]]

ssh_bash <<'EOF'
set -euo pipefail
test -f ~/.copilot/state.txt
test -f ~/.config/gh/state.txt
test -f ~/.ssh/state.txt
test -f /workspace/screen.txt
EOF

"${container_bin}" rm -f "${container_name}" >/dev/null
container_env=(-e CONTROL_PLANE_SESSION_SELECTION=new:auto-login)
start_container
wait_for_ssh

TERM=tmux-256color ssh -tt "${ssh_opts[@]}" copilot@127.0.0.1 </dev/null >"${workdir}/ssh-login.log" 2>&1 &
interactive_ssh_pid=$!
if ! wait_for_screen_session auto-login; then
  printf 'Expected auto-login screen session to be created during SSH login\n' >&2
  cat "${workdir}/ssh-login.log" >&2 || true
  exit 1
fi

kill "${interactive_ssh_pid}" >/dev/null 2>&1 || true
wait "${interactive_ssh_pid}" 2>/dev/null || true
