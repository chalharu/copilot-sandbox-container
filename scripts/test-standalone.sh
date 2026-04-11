#!/usr/bin/env bash
set -euo pipefail

control_plane_image="${1:?usage: scripts/test-standalone.sh <control-plane-image>}"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-docker}"
container_name="control-plane-standalone-test"
workdir="$(mktemp -d)"
state_root="${workdir}/state"
control_plane_run_user=(--user 0:0)
container_cap_flags=(
  --cap-add CHOWN
  --cap-add DAC_OVERRIDE
  --cap-add FOWNER
  --cap-add SETGID
  --cap-add SETUID
)
container_privilege_flags=()
container_start_flags=()
web_backend_pid_file="/tmp/control-plane-web.pid"

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

configure_container_runtime() {
  if "${container_bin}" --version 2>/dev/null | grep -qi '^podman version'; then
    container_cap_flags=()
    container_privilege_flags=(--privileged)
    container_start_flags=(--no-healthcheck)
  fi
}

start_container() {
  "${container_bin}" run -d --rm \
    "${control_plane_run_user[@]}" \
    --name "${container_name}" \
    "${container_cap_flags[@]}" \
    "${container_privilege_flags[@]}" \
    "${container_start_flags[@]}" \
    -e CONTROL_PLANE_ACP_PORT=3000 \
    -e CONTROL_PLANE_WEB_PORT=8080 \
    -e SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestStandaloneKey control-plane-standalone' \
    -v "${state_root}/copilot:/home/copilot/.copilot" \
    -v "${state_root}/gh:/home/copilot/.config/gh" \
    -v "${state_root}/ssh-auth:/home/copilot/.config/control-plane/ssh-auth" \
    -v "${state_root}/ssh:/home/copilot/.ssh" \
    -v "${state_root}/ssh-host-keys:/var/lib/control-plane/ssh-host-keys" \
    -v "${state_root}/workspace:/workspace" \
    "${control_plane_image}" >/dev/null
}

wait_for_acp() {
  local _
  for _ in $(seq 1 30); do
    if "${container_bin}" exec "${container_name}" bash -lc ":</dev/tcp/127.0.0.1/\${CONTROL_PLANE_ACP_PORT:-3000}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  printf 'Timed out waiting for Copilot ACP to listen on port 3000\n' >&2
  "${container_bin}" logs "${container_name}" >&2 || true
  exit 1
}

start_web_backend() {
  "${container_bin}" exec -d "${container_name}" bash -lc '
    set -euo pipefail
    /usr/local/bin/control-plane-entrypoint /usr/local/bin/control-plane-web-backend >/tmp/control-plane-web.log 2>&1 &
    echo $! > '"${web_backend_pid_file}"'
    wait
  ' >/dev/null
}

wait_for_web_backend() {
  local _
  for _ in $(seq 1 30); do
    if "${container_bin}" exec "${container_name}" bash -lc ":</dev/tcp/127.0.0.1/\${CONTROL_PLANE_WEB_PORT:-8080}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  printf 'Timed out waiting for web backend to listen on port 8080\n' >&2
  "${container_bin}" exec "${container_name}" bash -lc 'cat /tmp/control-plane-web.log' >&2 || true
  exit 1
}

require_command "${container_bin}"
configure_container_runtime

mkdir -p \
  "${state_root}/copilot" \
  "${state_root}/gh" \
  "${state_root}/ssh-auth" \
  "${state_root}/ssh" \
  "${state_root}/ssh-host-keys" \
  "${state_root}/workspace"

start_container
wait_for_acp

printf '%s\n' 'standalone-test: checking default ACP startup and bundled tools' >&2
"${container_bin}" exec "${container_name}" bash -l -se <<'EOF'
set -euo pipefail
command -v node
command -v npm
npm ls -g @github/copilot --depth=0 | grep -q "@github/copilot@"
command -v git
! command -v gh >/dev/null 2>&1
! command -v curl >/dev/null 2>&1
! command -v sqlite3 >/dev/null 2>&1
! command -v cpulimit >/dev/null 2>&1
! command -v gcc >/dev/null 2>&1
! command -v pkg-config >/dev/null 2>&1
command -v vim
command -v kubectl
command -v kind
command -v cargo
command -v yamllint
command -v control-plane-copilot
command -v control-plane-web-backend
command -v control-plane-exec-api
command -v control-plane-run
command -v control-plane-session
command -v k8s-job-start
command -v k8s-job-wait
command -v k8s-job-pod
command -v k8s-job-logs
command -v control-plane-job-transfer
command -v screen
printf '%s\n' "${LANG}" | grep -qi 'utf-8'
test -f /home/copilot/.copilot/skills/repo-change-delivery/SKILL.md
test -f /usr/local/share/control-plane/web-frontend/index.html
grep -q '^CONTROL_PLANE_ACP_PORT=3000$' /home/copilot/.config/control-plane/runtime.env
pgrep -af -- 'copilot.*--acp.*--port 3000'
EOF

printf '%s\n' 'standalone-test: checking web backend health and frontend serving' >&2
start_web_backend
wait_for_web_backend
"${container_bin}" exec "${container_name}" node - <<'EOF'
const http = require('http');

function get(path) {
  return new Promise((resolve, reject) => {
    http.get({ host: '127.0.0.1', port: 8080, path }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => resolve({ status: res.statusCode, body }));
    }).on('error', reject);
  });
}

(async () => {
  const health = await get('/healthz');
  if (health.status !== 200 || health.body.trim() !== 'ok') {
    throw new Error(`unexpected /healthz response: ${health.status} ${health.body}`);
  }
  const index = await get('/');
  if (index.status !== 200 || !index.body.includes('<div id="root"></div>')) {
    throw new Error(`unexpected / response: ${index.status}`);
  }
})().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
EOF

printf '%s\n' 'standalone-test: seeding persisted state' >&2
"${container_bin}" exec "${container_name}" bash -l -se <<'EOF'
set -euo pipefail
su -s /bin/bash copilot <<'INNER'
set -euo pipefail
mkdir -p ~/.copilot ~/.config/gh ~/.ssh /workspace
printf '%s\n' standalone > ~/.copilot/state.txt
printf '%s\n' gh > ~/.config/gh/state.txt
printf '%s\n' ssh > ~/.ssh/state.txt
printf '日本語★\n' > /workspace/screen-utf8.txt
printf '%s\n' screen-ok > /workspace/screen.txt
INNER
EOF

"${container_bin}" exec "${container_name}" bash -l -se <<'EOF'
set -euo pipefail
su -s /bin/bash copilot <<'INNER'
set -euo pipefail
grep -qx '日本語★' /workspace/screen-utf8.txt
grep -qx 'screen-ok' /workspace/screen.txt
INNER
EOF

first_host_fingerprint="$("${container_bin}" exec "${container_name}" bash -lc "sha256sum /run/control-plane/ssh-host-keys/ssh_host_ed25519_key.pub | cut -d' ' -f1")"

"${container_bin}" rm -f "${container_name}" >/dev/null
start_container
wait_for_acp

second_host_fingerprint="$("${container_bin}" exec "${container_name}" bash -lc "sha256sum /run/control-plane/ssh-host-keys/ssh_host_ed25519_key.pub | cut -d' ' -f1")"
[[ "${first_host_fingerprint}" == "${second_host_fingerprint}" ]]

printf '%s\n' 'standalone-test: checking runtime SSH host key staging after restart' >&2
"${container_bin}" exec "${container_name}" bash -l -se <<'EOF'
set -euo pipefail
test -L /etc/ssh/ssh_host_ed25519_key
test -L /etc/ssh/ssh_host_ed25519_key.pub
test "$(readlink /etc/ssh/ssh_host_ed25519_key)" = '/run/control-plane/ssh-host-keys/ssh_host_ed25519_key'
test "$(readlink /etc/ssh/ssh_host_ed25519_key.pub)" = '/run/control-plane/ssh-host-keys/ssh_host_ed25519_key.pub'
test "$(env -u LD_PRELOAD stat -c '%a %U %G' /run/control-plane/ssh-host-keys)" = '700 root root'
test "$(env -u LD_PRELOAD stat -c '%a %U %G' /run/control-plane/ssh-host-keys/ssh_host_ed25519_key)" = '600 root root'
test "$(env -u LD_PRELOAD stat -c '%a %U %G' /run/control-plane/ssh-host-keys/ssh_host_ed25519_key.pub)" = '644 root root'
EOF

printf '%s\n' 'standalone-test: checking persisted state after restart' >&2
"${container_bin}" exec "${container_name}" bash -l -se <<'EOF'
set -euo pipefail
su -s /bin/bash copilot <<'INNER'
set -euo pipefail
test -f ~/.copilot/state.txt
test -f ~/.config/gh/state.txt
test -s ~/.config/control-plane/ssh-auth/authorized_keys
test -f ~/.ssh/state.txt
test -f /workspace/screen.txt
INNER
EOF

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
if ! grep -q 'CHOWN' <<<"${missing_caps_output}" || ! grep -q 'SETUID' <<<"${missing_caps_output}"; then
  printf 'Expected non-SSH startup capabilities in cap-drop ALL output\n' >&2
  printf '%s\n' "${missing_caps_output}" >&2
  exit 1
fi
if ! grep -q 'Non-SSH startup still needs CHOWN,DAC_OVERRIDE,FOWNER,SETGID,SETUID' <<<"${missing_caps_output}"; then
  printf 'Expected non-SSH capability guidance in cap-drop ALL output\n' >&2
  printf '%s\n' "${missing_caps_output}" >&2
  exit 1
fi

printf '%s\n' 'standalone-test: ACP/web smoke ok' >&2
