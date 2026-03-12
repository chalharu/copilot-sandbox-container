#!/usr/bin/env bash
set -euo pipefail

control_plane_image="${1:?usage: scripts/test-standalone.sh <control-plane-image> <execution-plane-image>}"
execution_plane_image="${2:?usage: scripts/test-standalone.sh <control-plane-image> <execution-plane-image>}"
ssh_port="${CONTROL_PLANE_TEST_SSH_PORT:-2222}"
container_name="control-plane-standalone-test"
workdir="$(mktemp -d)"
state_root="${workdir}/state"
ssh_key="${workdir}/id_ed25519"

cleanup() {
  docker rm -f "${container_name}" >/dev/null 2>&1 || true
  rm -rf "${workdir}"
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
  ssh "${ssh_opts[@]}" copilot@127.0.0.1 'bash -se'
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

start_container() {
  docker run -d --rm             --name "${container_name}"             -p "127.0.0.1:${ssh_port}:2222"             -e SSH_PUBLIC_KEY="$(cat "${ssh_key}.pub")"             -v "${state_root}/copilot:/home/copilot/.copilot"             -v "${state_root}/gh:/home/copilot/.config/gh"             -v "${state_root}/ssh:/home/copilot/.ssh"             -v "${state_root}/workspace:/workspace"             "${control_plane_image}" >/dev/null
}

require_command docker
require_command ssh
require_command ssh-keygen

mkdir -p "${state_root}/copilot" "${state_root}/gh" "${state_root}/ssh" "${state_root}/workspace"
ssh-keygen -q -t ed25519 -N '' -f "${ssh_key}"

start_container
wait_for_ssh

docker exec "${container_name}" bash -lc 'set -euo pipefail
  command -v node
  command -v npm
  npm ls -g @github/copilot-cli --depth=0 | grep -q "@github/copilot-cli@"
  command -v git
  command -v gh
  command -v kubectl
  command -v podman
  command -v docker
  command -v sshd
  command -v screen
  command -v control-plane-run
  command -v control-plane-session
  command -v k8s-job-start
  command -v k8s-job-wait
  command -v k8s-job-pod
  command -v k8s-job-logs
  command -v k8s-job-run
  grep -q "^copilot:" /etc/subuid
  grep -q "^copilot:" /etc/subgid
'

ssh_bash <<'EOF'
set -euo pipefail
mkdir -p ~/.copilot ~/.config/gh /workspace
echo standalone > ~/.copilot/state.txt
echo gh > ~/.config/gh/state.txt
echo ssh > ~/.ssh/state.txt
screen -dmS smoke-session sh -lc 'echo screen-ok > /workspace/screen.txt; sleep 30'
EOF

sleep 2
ssh_bash <<'EOF'
set -euo pipefail
screen -list | grep -q smoke-session
EOF

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

docker rm -f "${container_name}" >/dev/null
start_container
wait_for_ssh

ssh_bash <<'EOF'
set -euo pipefail
test -f ~/.copilot/state.txt
test -f ~/.config/gh/state.txt
test -f ~/.ssh/state.txt
test -f /workspace/screen.txt
EOF
