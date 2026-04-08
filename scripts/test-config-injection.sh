#!/usr/bin/env bash
set -euo pipefail

control_plane_image="${1:?usage: scripts/test-config-injection.sh <control-plane-image>}"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-docker}"
workdir="$(mktemp -d)"
container_name="control-plane-config-injection-test"
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

prepare_state_tree() {
  local prefix="$1"

  mkdir -p \
    "${workdir}/${prefix}/state/copilot" \
    "${workdir}/${prefix}/state/gh" \
    "${workdir}/${prefix}/state/ssh" \
    "${workdir}/${prefix}/state/ssh-host-keys" \
    "${workdir}/${prefix}/state/workspace" \
    "${workdir}/${prefix}/auth" \
    "${workdir}/${prefix}/config"
}

require_command "${container_bin}"

printf '%s\n' 'config-injection-test: verifying Copilot merge and Secret-backed gh hosts injection' >&2
prepare_state_tree file-backed
cat > "${workdir}/file-backed/state/copilot/config.json" <<'EOF'
{
  "chat": {
    "editor": "vim",
    "theme": "dark"
  },
  "nested": {
    "keep": 1,
    "replace": {
      "fromBase": true
    },
    "array": [
      "base"
    ]
  }
}
EOF
cat > "${workdir}/file-backed/state/gh/hosts.yml" <<'EOF'
github.com:
  oauth_token: stale-state-token
  git_protocol: https
EOF
cat > "${workdir}/file-backed/config/copilot-config.json" <<'EOF'
{
  "chat": {
    "theme": "light"
  },
  "nested": {
    "replace": {
      "fromOverlay": true
    },
    "array": [
      "overlay"
    ]
  },
  "topLevelOverlay": "configmap"
}
EOF
cat > "${workdir}/file-backed/auth/gh-hosts.yml" <<'EOF'
github.com:
  oauth_token: secret-hosts-token
  git_protocol: ssh
  user: secret-bot
EOF
printf '%s' 'unused-secret-fallback-token' > "${workdir}/file-backed/auth/gh-github-token"
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILegacyConfigInjectionKey legacy-config-injection' > "${workdir}/file-backed/state/ssh/authorized_keys"
printf '%s\n' legacy-rsa-private > "${workdir}/file-backed/state/ssh-host-keys/ssh_host_rsa_key"
printf '%s\n' legacy-rsa-public > "${workdir}/file-backed/state/ssh-host-keys/ssh_host_rsa_key.pub"
printf '%s\n' legacy-ecdsa-private > "${workdir}/file-backed/state/ssh-host-keys/ssh_host_ecdsa_key"
printf '%s\n' legacy-ecdsa-public > "${workdir}/file-backed/state/ssh-host-keys/ssh_host_ecdsa_key.pub"

set +e
file_backed_output="$("${container_bin}" run --rm \
  --name "${container_name}" \
  "${control_plane_run_user[@]}" \
  -i \
  "${startup_caps[@]}" \
  -e SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForConfigInjection control-plane-config-injection' \
  -e COPILOT_CONFIG_JSON_FILE=/var/run/control-plane-config/copilot-config.json \
  -e GH_HOSTS_YML_FILE=/var/run/control-plane-auth/gh-hosts.yml \
  -e GH_GITHUB_TOKEN_FILE=/var/run/control-plane-auth/gh-github-token \
  -v "${workdir}/file-backed/state/copilot:/home/copilot/.copilot" \
  -v "${workdir}/file-backed/state/gh:/home/copilot/.config/gh" \
  -v "${workdir}/file-backed/state/ssh:/home/copilot/.ssh" \
  -v "${workdir}/file-backed/state/ssh-host-keys:/var/lib/control-plane/ssh-host-keys" \
  -v "${workdir}/file-backed/state/workspace:/workspace" \
  -v "${workdir}/file-backed/auth:/var/run/control-plane-auth:ro" \
  -v "${workdir}/file-backed/config:/var/run/control-plane-config:ro" \
  "${control_plane_image}" \
  bash -l -se 2>&1 <<'EOF'
set -euo pipefail
test "${COPILOT_HOME}" = '/var/lib/control-plane/managed-runtime/copilot-home'
test "${GIT_CONFIG_GLOBAL}" = '/var/lib/control-plane/managed-runtime/gitconfig'
test "$(stat -c '%a %U %G' /home/copilot/.copilot/config.json)" = '600 copilot copilot'
test "$(stat -c '%a %U %G' /home/copilot/.config/gh/hosts.yml)" = '600 copilot copilot'
test "$(stat -c '%a %U %G' "${COPILOT_HOME}")" = '755 root root'
test "$(stat -c '%a %U %G' "${COPILOT_HOME}/hooks/hooks.json")" = '644 root root'
test "$(stat -c '%a %U %G' "${GIT_CONFIG_GLOBAL}")" = '644 root root'
test -L /home/copilot/.copilot/hooks
test "$(readlink /home/copilot/.copilot/hooks)" = '/usr/local/share/control-plane/hooks'
test -L /home/copilot/.gitconfig
test "$(readlink /home/copilot/.gitconfig)" = "${GIT_CONFIG_GLOBAL}"
test "$(stat -c '%a %U %G' /var/lib/control-plane/ssh-host-keys)" = '711 root root'
test "$(stat -c '%a %U %G' /var/lib/control-plane/ssh-host-keys/ssh_host_ed25519_key)" = '600 root root'
test "$(stat -c '%a %U %G' /var/lib/control-plane/ssh-host-keys/ssh_host_ed25519_key.pub)" = '644 root root'
test "$(stat -c '%a %U %G' /run/control-plane/ssh-host-keys)" = '700 root root'
test "$(stat -c '%a %U %G' /run/control-plane/ssh-host-keys/ssh_host_ed25519_key)" = '600 root root'
test "$(stat -c '%a %U %G' /run/control-plane/ssh-host-keys/ssh_host_ed25519_key.pub)" = '644 root root'
! test -e /var/lib/control-plane/ssh-host-keys/ssh_host_rsa_key
! test -e /var/lib/control-plane/ssh-host-keys/ssh_host_ecdsa_key
! test -e /var/lib/control-plane/ssh-host-keys/ssh_host_rsa_key.pub
! test -e /var/lib/control-plane/ssh-host-keys/ssh_host_ecdsa_key.pub
test -L /etc/ssh/ssh_host_ed25519_key
test -L /etc/ssh/ssh_host_ed25519_key.pub
test "$(readlink /etc/ssh/ssh_host_ed25519_key)" = '/run/control-plane/ssh-host-keys/ssh_host_ed25519_key'
test "$(readlink /etc/ssh/ssh_host_ed25519_key.pub)" = '/run/control-plane/ssh-host-keys/ssh_host_ed25519_key.pub'
grep -Fxq 'HostKey /etc/ssh/ssh_host_ed25519_key' /etc/ssh/sshd_config
grep -Fxq 'AuthorizedKeysFile .config/control-plane/ssh-auth/authorized_keys' /etc/ssh/sshd_config
! grep -Fq 'HostKey /etc/ssh/ssh_host_rsa_key' /etc/ssh/sshd_config
! grep -Fq 'HostKey /etc/ssh/ssh_host_ecdsa_key' /etc/ssh/sshd_config
test "$(stat -Lc '%a %U %G' /home/copilot/.config/control-plane/ssh-auth/authorized_keys)" = '600 copilot copilot'
grep -Fqx 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILegacyConfigInjectionKey legacy-config-injection' /home/copilot/.config/control-plane/ssh-auth/authorized_keys
test -L /home/copilot/.config/control-plane/ssh-auth/authorized_keys
test "$(readlink /home/copilot/.config/control-plane/ssh-auth/authorized_keys)" = '../../../.ssh/authorized_keys'
! test -L /home/copilot/.ssh/authorized_keys
grep -Fqx 'CONTROL_PLANE_AUTHORIZED_KEYS_PATH=/home/copilot/.config/control-plane/ssh-auth/authorized_keys' /home/copilot/.config/control-plane/runtime.env
grep -Fqx 'CONTROL_PLANE_RUNTIME_HOST_KEY_DIR=/run/control-plane/ssh-host-keys' /home/copilot/.config/control-plane/runtime.env
grep -Fqx 'CONTROL_PLANE_EXEC_POLICY_LIBRARY=/usr/local/lib/libcontrol_plane_exec_policy.so' /home/copilot/.config/control-plane/runtime.env
grep -Fqx 'CONTROL_PLANE_EXEC_POLICY_RULES_FILE=/usr/local/share/control-plane/hooks/preToolUse/deny-rules.yaml' /home/copilot/.config/control-plane/runtime.env
grep -Fqx 'LD_PRELOAD=/usr/local/lib/libcontrol_plane_exec_policy.so' /home/copilot/.config/control-plane/runtime.env
grep -Fqx '    hooksPath = /usr/local/share/control-plane/hooks/git' "${GIT_CONFIG_GLOBAL}"
test "$(grep -Fc '    helper = !gh auth git-credential' "${GIT_CONFIG_GLOBAL}")" -eq 2
if su -s /bin/bash copilot -lc "printf tamper >> \"${GIT_CONFIG_GLOBAL}\"" 2>/dev/null; then
  printf '%s\n' 'Expected managed global git config to be read-only for the Copilot user' >&2
  exit 1
fi
if su -s /bin/bash copilot -lc "printf tamper >> \"${COPILOT_HOME}/hooks/hooks.json\"" 2>/dev/null; then
  printf '%s\n' 'Expected managed Copilot hooks to be read-only for the Copilot user' >&2
  exit 1
fi
su -s /bin/bash copilot -lc 'test -r /var/lib/control-plane/ssh-host-keys/ssh_host_ed25519_key.pub'
if su -s /bin/bash copilot -lc 'test -r /var/lib/control-plane/ssh-host-keys/ssh_host_ed25519_key'; then
  printf '%s\n' 'Expected Copilot user to be unable to read the private SSH host key' >&2
  exit 1
fi
if su -s /bin/bash copilot -lc 'test -r /run/control-plane/ssh-host-keys/ssh_host_ed25519_key'; then
  printf '%s\n' 'Expected Copilot user to be unable to read the runtime SSH host key copy' >&2
  exit 1
fi
su -s /bin/bash copilot -lc 'test "${CONTROL_PLANE_EXEC_POLICY_LIBRARY}" = /usr/local/lib/libcontrol_plane_exec_policy.so'
su -s /bin/bash copilot -lc 'test "${CONTROL_PLANE_EXEC_POLICY_RULES_FILE}" = /usr/local/share/control-plane/hooks/preToolUse/deny-rules.yaml'
su -s /bin/bash copilot -lc 'test "${LD_PRELOAD}" = /usr/local/lib/libcontrol_plane_exec_policy.so'
cat > /tmp/fake-copilot <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${LD_PRELOAD:-missing}"
FAKE
chmod 755 /tmp/fake-copilot
copilot_ld_preload="$(su -s /bin/bash copilot -lc 'CONTROL_PLANE_COPILOT_BIN=/tmp/fake-copilot control-plane-copilot')"
grep -qx '/usr/local/lib/libcontrol_plane_exec_policy.so' <<<"${copilot_ld_preload}"
jq -e '.chat.editor == "vim"' /home/copilot/.copilot/config.json >/dev/null
jq -e '.chat.theme == "light"' /home/copilot/.copilot/config.json >/dev/null
jq -e '.nested.keep == 1' /home/copilot/.copilot/config.json >/dev/null
jq -e '.nested.replace.fromBase == true and .nested.replace.fromOverlay == true' /home/copilot/.copilot/config.json >/dev/null
jq -e '.nested.array == ["overlay"]' /home/copilot/.copilot/config.json >/dev/null
jq -e '.topLevelOverlay == "configmap"' /home/copilot/.copilot/config.json >/dev/null
grep -Fqx '  git_protocol: ssh' /home/copilot/.config/gh/hosts.yml
printf '%s\n' file-backed-ok
EOF
)"
file_backed_status=$?
set -e

if [[ "${file_backed_status}" -ne 0 ]]; then
  printf 'Expected file-backed gh hosts injection and Copilot config merge to succeed\n' >&2
  printf '%s\n' "${file_backed_output}" >&2
  exit 1
fi
grep -qx 'file-backed-ok' <<<"${file_backed_output}"

printf '%s\n' 'config-injection-test: verifying Copilot merge works with single-file config mounts' >&2
prepare_state_tree file-mounted
cat > "${workdir}/file-mounted/state/copilot-config.json" <<'EOF'
{
  "chat": {
    "editor": "vim",
    "theme": "dark"
  },
  "nested": {
    "keep": 1,
    "replace": {
      "fromBase": true
    },
    "array": [
      "base"
    ]
  }
}
EOF
cat > "${workdir}/file-mounted/config/copilot-config.json" <<'EOF'
{
  "chat": {
    "theme": "light"
  },
  "nested": {
    "replace": {
      "fromOverlay": true
    },
    "array": [
      "overlay"
    ]
  },
  "topLevelOverlay": "single-file-mount"
}
EOF
cat > "${workdir}/file-mounted/auth/gh-hosts.yml" <<'EOF'
github.com:
  oauth_token: single-file-secret-token
  git_protocol: ssh
EOF

set +e
file_mounted_output="$("${container_bin}" run --rm \
  --name "${container_name}" \
  "${control_plane_run_user[@]}" \
  -i \
  "${startup_caps[@]}" \
  -e SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForConfigInjection control-plane-config-injection' \
  -e COPILOT_CONFIG_JSON_FILE=/var/run/control-plane-config/copilot-config.json \
  -e GH_HOSTS_YML_FILE=/var/run/control-plane-auth/gh-hosts.yml \
  -v "${workdir}/file-mounted/state/copilot-config.json:/home/copilot/.copilot/config.json" \
  -v "${workdir}/file-mounted/state/gh:/home/copilot/.config/gh" \
  -v "${workdir}/file-mounted/state/ssh:/home/copilot/.ssh" \
  -v "${workdir}/file-mounted/state/ssh-host-keys:/var/lib/control-plane/ssh-host-keys" \
  -v "${workdir}/file-mounted/state/workspace:/workspace" \
  -v "${workdir}/file-mounted/auth:/var/run/control-plane-auth:ro" \
  -v "${workdir}/file-mounted/config:/var/run/control-plane-config:ro" \
  "${control_plane_image}" \
  bash -l -se 2>&1 <<'EOF'
set -euo pipefail
test "$(stat -c '%a %U %G' /home/copilot/.copilot/config.json)" = '600 copilot copilot'
jq -e '.chat.editor == "vim"' /home/copilot/.copilot/config.json >/dev/null
jq -e '.chat.theme == "light"' /home/copilot/.copilot/config.json >/dev/null
jq -e '.nested.keep == 1' /home/copilot/.copilot/config.json >/dev/null
jq -e '.nested.replace.fromBase == true and .nested.replace.fromOverlay == true' /home/copilot/.copilot/config.json >/dev/null
jq -e '.nested.array == ["overlay"]' /home/copilot/.copilot/config.json >/dev/null
jq -e '.topLevelOverlay == "single-file-mount"' /home/copilot/.copilot/config.json >/dev/null
printf '%s\n' file-mounted-ok
EOF
)"
file_mounted_status=$?
set -e

if [[ "${file_mounted_status}" -ne 0 ]]; then
  printf 'Expected Copilot config merge to succeed when config.json is a single-file mount\n' >&2
  printf '%s\n' "${file_mounted_output}" >&2
  exit 1
fi
grep -qx 'file-mounted-ok' <<<"${file_mounted_output}"

printf '%s\n' 'config-injection-test: verifying empty single-file config mounts fail clearly' >&2
prepare_state_tree empty-file-mounted
: > "${workdir}/empty-file-mounted/state/copilot-config.json"
cat > "${workdir}/empty-file-mounted/config/copilot-config.json" <<'EOF'
{
  "chat": {
    "theme": "light"
  }
}
EOF

set +e
empty_file_mounted_output="$("${container_bin}" run --rm \
  --name "${container_name}" \
  "${control_plane_run_user[@]}" \
  -i \
  "${startup_caps[@]}" \
  -e SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForConfigInjection control-plane-config-injection' \
  -e COPILOT_CONFIG_JSON_FILE=/var/run/control-plane-config/copilot-config.json \
  -v "${workdir}/empty-file-mounted/state/copilot-config.json:/home/copilot/.copilot/config.json" \
  -v "${workdir}/empty-file-mounted/state/gh:/home/copilot/.config/gh" \
  -v "${workdir}/empty-file-mounted/state/ssh:/home/copilot/.ssh" \
  -v "${workdir}/empty-file-mounted/state/ssh-host-keys:/var/lib/control-plane/ssh-host-keys" \
  -v "${workdir}/empty-file-mounted/state/workspace:/workspace" \
  -v "${workdir}/empty-file-mounted/config:/var/run/control-plane-config:ro" \
  "${control_plane_image}" \
  bash -l -se 2>&1 <<'EOF'
set -euo pipefail
printf '%s\n' unexpected-success
EOF
)"
empty_file_mounted_status=$?
set -e

if [[ "${empty_file_mounted_status}" -eq 0 ]]; then
  printf 'Expected empty single-file config mount to fail validation\n' >&2
  printf '%s\n' "${empty_file_mounted_output}" >&2
  exit 1
fi
grep -Fq 'Expected existing Copilot config at /home/copilot/.copilot/config.json to contain a single top-level JSON object' <<<"${empty_file_mounted_output}"

printf '%s\n' 'config-injection-test: verifying gh token Secret generates hosts.yml when no file override exists' >&2
prepare_state_tree token-backed
cat > "${workdir}/token-backed/state/gh/hosts.yml" <<'EOF'
github.com:
  oauth_token: stale-generated-token
  git_protocol: ssh
EOF
printf '%s' 'generated-secret-token' > "${workdir}/token-backed/auth/gh-github-token"

set +e
token_backed_output="$("${container_bin}" run --rm \
  --name "${container_name}" \
  "${control_plane_run_user[@]}" \
  -i \
  "${startup_caps[@]}" \
  -e SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForConfigInjection control-plane-config-injection' \
  -e GH_GITHUB_TOKEN_FILE=/var/run/control-plane-auth/gh-github-token \
  -v "${workdir}/token-backed/state/copilot:/home/copilot/.copilot" \
  -v "${workdir}/token-backed/state/gh:/home/copilot/.config/gh" \
  -v "${workdir}/token-backed/state/ssh:/home/copilot/.ssh" \
  -v "${workdir}/token-backed/state/ssh-host-keys:/var/lib/control-plane/ssh-host-keys" \
  -v "${workdir}/token-backed/state/workspace:/workspace" \
  -v "${workdir}/token-backed/auth:/var/run/control-plane-auth:ro" \
  "${control_plane_image}" \
  bash -l -se 2>&1 <<'EOF'
set -euo pipefail
test "$(stat -c '%a %U %G' /home/copilot/.config/gh/hosts.yml)" = '600 copilot copilot'
grep -Fqx '    git_protocol: https' /home/copilot/.config/gh/hosts.yml
printf '%s\n' token-backed-ok
EOF
)"
token_backed_status=$?
set -e

if [[ "${token_backed_status}" -ne 0 ]]; then
  printf 'Expected gh token Secret to render ~/.config/gh/hosts.yml\n' >&2
  printf '%s\n' "${token_backed_output}" >&2
  exit 1
fi
grep -qx 'token-backed-ok' <<<"${token_backed_output}"

printf '%s\n' 'config-injection-test: verifying authorized_keys cleanup works with directory mounts' >&2
mkdir -p "${workdir}/authorized-keys-cleanup/ssh-auth" "${workdir}/authorized-keys-cleanup/transfers/cleanup-test"
cat > "${workdir}/authorized-keys-cleanup/ssh-auth/authorized_keys" <<'EOF'
# BEGIN cleanup-marker
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICleanupEphemeralKey cleanup-ephemeral
# END cleanup-marker
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICleanupKeeperKey cleanup-keeper
EOF
cat > "${workdir}/authorized-keys-cleanup/transfers/cleanup-test/manifest.json" <<'EOF'
{
  "authorized_key_marker": "cleanup-marker"
}
EOF

set +e
authorized_keys_cleanup_output="$("${container_bin}" run --rm \
  --name "${container_name}" \
  "${control_plane_run_user[@]}" \
  -i \
  "${startup_caps[@]}" \
  -e CONTROL_PLANE_JOB_TRANSFER_ROOT=/tmp/job-transfers \
  -v "${workdir}/authorized-keys-cleanup/ssh-auth:/home/copilot/.config/control-plane/ssh-auth" \
  -v "${workdir}/authorized-keys-cleanup/transfers:/tmp/job-transfers" \
  "${control_plane_image}" \
  bash -l -se 2>&1 <<'EOF'
set -euo pipefail
control-plane-job-transfer release-access --transfer-id cleanup-test --remove-transfer-dir
test -L /home/copilot/.ssh/authorized_keys
test "$(readlink /home/copilot/.ssh/authorized_keys)" = '../.config/control-plane/ssh-auth/authorized_keys'
grep -Fqx 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICleanupKeeperKey cleanup-keeper' /home/copilot/.config/control-plane/ssh-auth/authorized_keys
! grep -Fq 'cleanup-marker' /home/copilot/.config/control-plane/ssh-auth/authorized_keys
! grep -Fq 'cleanup-ephemeral' /home/copilot/.config/control-plane/ssh-auth/authorized_keys
test ! -e /tmp/job-transfers/cleanup-test
printf '%s\n' authorized-keys-cleanup-ok
EOF
)"
authorized_keys_cleanup_status=$?
set -e

if [[ "${authorized_keys_cleanup_status}" -ne 0 ]]; then
  printf 'Expected authorized_keys cleanup to work when the ssh-auth directory is mounted directly\n' >&2
  printf '%s\n' "${authorized_keys_cleanup_output}" >&2
  exit 1
fi
grep -qx 'authorized-keys-cleanup-ok' <<<"${authorized_keys_cleanup_output}"

printf '%s\n' 'config-injection-test: verifying ssh-auth mount upgrades fallback symlink state' >&2
prepare_state_tree ssh-auth-upgrade
mkdir -p "${workdir}/ssh-auth-upgrade/state/ssh-auth"
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIUpgradeLegacyKey upgrade-legacy' > "${workdir}/ssh-auth-upgrade/state/ssh/authorized_keys"
ln -s ../../../.ssh/authorized_keys "${workdir}/ssh-auth-upgrade/state/ssh-auth/authorized_keys"

set +e
ssh_auth_upgrade_output="$("${container_bin}" run --rm \
  --name "${container_name}" \
  "${control_plane_run_user[@]}" \
  -i \
  "${startup_caps[@]}" \
  -e SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIUpgradeInjectedKey upgrade-injected' \
  -v "${workdir}/ssh-auth-upgrade/state/copilot:/home/copilot/.copilot" \
  -v "${workdir}/ssh-auth-upgrade/state/gh:/home/copilot/.config/gh" \
  -v "${workdir}/ssh-auth-upgrade/state/ssh-auth:/home/copilot/.config/control-plane/ssh-auth" \
  -v "${workdir}/ssh-auth-upgrade/state/ssh:/home/copilot/.ssh" \
  -v "${workdir}/ssh-auth-upgrade/state/ssh-host-keys:/var/lib/control-plane/ssh-host-keys" \
  -v "${workdir}/ssh-auth-upgrade/state/workspace:/workspace" \
  "${control_plane_image}" \
  bash -l -se 2>&1 <<'EOF'
set -euo pipefail
! test -L /home/copilot/.config/control-plane/ssh-auth/authorized_keys
test -L /home/copilot/.ssh/authorized_keys
test "$(readlink /home/copilot/.ssh/authorized_keys)" = '../.config/control-plane/ssh-auth/authorized_keys'
grep -Fqx 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIUpgradeLegacyKey upgrade-legacy' /home/copilot/.config/control-plane/ssh-auth/authorized_keys
grep -Fqx 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIUpgradeInjectedKey upgrade-injected' /home/copilot/.config/control-plane/ssh-auth/authorized_keys
printf '%s\n' ssh-auth-upgrade-ok
EOF
)"
ssh_auth_upgrade_status=$?
set -e

if [[ "${ssh_auth_upgrade_status}" -ne 0 ]]; then
  printf 'Expected ssh-auth directory mounts to upgrade fallback symlink state safely\n' >&2
  printf '%s\n' "${ssh_auth_upgrade_output}" >&2
  exit 1
fi
grep -qx 'ssh-auth-upgrade-ok' <<<"${ssh_auth_upgrade_output}"

printf '%s\n' 'config-injection-test: verifying ssh-auth mounts accept legacy authorized_keys file mounts' >&2
prepare_state_tree legacy-file-mount-upgrade
mkdir -p "${workdir}/legacy-file-mount-upgrade/state/ssh-auth"
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINewAuthMountKey new-auth-mounted' > "${workdir}/legacy-file-mount-upgrade/state/ssh-auth/authorized_keys"
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILegacyFileMountKey legacy-file-mount' > "${workdir}/legacy-file-mount-upgrade/authorized_keys"

set +e
legacy_file_mount_upgrade_output="$("${container_bin}" run --rm \
  --name "${container_name}" \
  "${control_plane_run_user[@]}" \
  -i \
  "${startup_caps[@]}" \
  -e SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILegacyFileMountInjectedKey legacy-file-mount-injected' \
  -v "${workdir}/legacy-file-mount-upgrade/state/copilot:/home/copilot/.copilot" \
  -v "${workdir}/legacy-file-mount-upgrade/state/gh:/home/copilot/.config/gh" \
  -v "${workdir}/legacy-file-mount-upgrade/state/ssh-auth:/home/copilot/.config/control-plane/ssh-auth" \
  -v "${workdir}/legacy-file-mount-upgrade/authorized_keys:/home/copilot/.ssh/authorized_keys" \
  -v "${workdir}/legacy-file-mount-upgrade/state/ssh-host-keys:/var/lib/control-plane/ssh-host-keys" \
  -v "${workdir}/legacy-file-mount-upgrade/state/workspace:/workspace" \
  "${control_plane_image}" \
  bash -l -se 2>&1 <<'EOF'
set -euo pipefail
test -L /home/copilot/.config/control-plane/ssh-auth/authorized_keys
test "$(readlink /home/copilot/.config/control-plane/ssh-auth/authorized_keys)" = '../../../.ssh/authorized_keys'
! test -L /home/copilot/.ssh/authorized_keys
test "$(stat -Lc '%a %U %G' /home/copilot/.ssh/authorized_keys)" = '600 copilot copilot'
grep -Fqx 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINewAuthMountKey new-auth-mounted' /home/copilot/.config/control-plane/ssh-auth/authorized_keys
grep -Fqx 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILegacyFileMountKey legacy-file-mount' /home/copilot/.config/control-plane/ssh-auth/authorized_keys
grep -Fqx 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILegacyFileMountInjectedKey legacy-file-mount-injected' /home/copilot/.config/control-plane/ssh-auth/authorized_keys
printf '%s\n' legacy-file-mount-upgrade-ok
EOF
)"
legacy_file_mount_upgrade_status=$?
set -e

if [[ "${legacy_file_mount_upgrade_status}" -ne 0 ]]; then
  printf 'Expected ssh-auth mounts to accept legacy authorized_keys file mounts during upgrade\n' >&2
  printf '%s\n' "${legacy_file_mount_upgrade_output}" >&2
  exit 1
fi
grep -qx 'legacy-file-mount-upgrade-ok' <<<"${legacy_file_mount_upgrade_output}"

printf '%s\n' 'config-injection-test: verifying direct ssh-auth file mounts stay authoritative' >&2
prepare_state_tree direct-ssh-auth-file-mounted
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDirectAuthFileKey direct-auth-file' > "${workdir}/direct-ssh-auth-file-mounted/authorized_keys"

set +e
direct_ssh_auth_file_output="$("${container_bin}" run --rm \
  --name "${container_name}" \
  "${control_plane_run_user[@]}" \
  -i \
  "${startup_caps[@]}" \
  -e SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDirectAuthInjectedKey direct-auth-injected' \
  -v "${workdir}/direct-ssh-auth-file-mounted/state/copilot:/home/copilot/.copilot" \
  -v "${workdir}/direct-ssh-auth-file-mounted/state/gh:/home/copilot/.config/gh" \
  -v "${workdir}/direct-ssh-auth-file-mounted/authorized_keys:/home/copilot/.config/control-plane/ssh-auth/authorized_keys" \
  -v "${workdir}/direct-ssh-auth-file-mounted/state/ssh:/home/copilot/.ssh" \
  -v "${workdir}/direct-ssh-auth-file-mounted/state/ssh-host-keys:/var/lib/control-plane/ssh-host-keys" \
  -v "${workdir}/direct-ssh-auth-file-mounted/state/workspace:/workspace" \
  "${control_plane_image}" \
  bash -l -se 2>&1 <<'EOF'
set -euo pipefail
! test -L /home/copilot/.config/control-plane/ssh-auth/authorized_keys
test -L /home/copilot/.ssh/authorized_keys
test "$(readlink /home/copilot/.ssh/authorized_keys)" = '../.config/control-plane/ssh-auth/authorized_keys'
grep -Fqx 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDirectAuthFileKey direct-auth-file' /home/copilot/.config/control-plane/ssh-auth/authorized_keys
grep -Fqx 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDirectAuthInjectedKey direct-auth-injected' /home/copilot/.config/control-plane/ssh-auth/authorized_keys
printf '%s\n' direct-ssh-auth-file-ok
EOF
)"
direct_ssh_auth_file_status=$?
set -e

if [[ "${direct_ssh_auth_file_status}" -ne 0 ]]; then
  printf 'Expected direct ssh-auth authorized_keys file mounts to stay authoritative\n' >&2
  printf '%s\n' "${direct_ssh_auth_file_output}" >&2
  exit 1
fi
grep -qx 'direct-ssh-auth-file-ok' <<<"${direct_ssh_auth_file_output}"

printf '%s\n' 'config-injection-test: verifying direct ssh-auth file mounts support cleanup' >&2
prepare_state_tree direct-ssh-auth-file-cleanup
mkdir -p "${workdir}/direct-ssh-auth-file-cleanup/transfers/cleanup-test"
cat > "${workdir}/direct-ssh-auth-file-cleanup/authorized_keys" <<'EOF'
# BEGIN cleanup-marker
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDirectFileCleanupEphemeralKey direct-file-cleanup-ephemeral
# END cleanup-marker
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDirectFileCleanupKeeperKey direct-file-cleanup-keeper
EOF
cat > "${workdir}/direct-ssh-auth-file-cleanup/transfers/cleanup-test/manifest.json" <<'EOF'
{
  "authorized_key_marker": "cleanup-marker"
}
EOF

set +e
direct_ssh_auth_file_cleanup_output="$("${container_bin}" run --rm \
  --name "${container_name}" \
  "${control_plane_run_user[@]}" \
  -i \
  "${startup_caps[@]}" \
  -e CONTROL_PLANE_JOB_TRANSFER_ROOT=/tmp/job-transfers \
  -v "${workdir}/direct-ssh-auth-file-cleanup/state/copilot:/home/copilot/.copilot" \
  -v "${workdir}/direct-ssh-auth-file-cleanup/state/gh:/home/copilot/.config/gh" \
  -v "${workdir}/direct-ssh-auth-file-cleanup/authorized_keys:/home/copilot/.config/control-plane/ssh-auth/authorized_keys" \
  -v "${workdir}/direct-ssh-auth-file-cleanup/state/ssh:/home/copilot/.ssh" \
  -v "${workdir}/direct-ssh-auth-file-cleanup/state/ssh-host-keys:/var/lib/control-plane/ssh-host-keys" \
  -v "${workdir}/direct-ssh-auth-file-cleanup/state/workspace:/workspace" \
  -v "${workdir}/direct-ssh-auth-file-cleanup/transfers:/tmp/job-transfers" \
  "${control_plane_image}" \
  bash -l -se 2>&1 <<'EOF'
set -euo pipefail
control-plane-job-transfer release-access --transfer-id cleanup-test --remove-transfer-dir
grep -Fqx 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDirectFileCleanupKeeperKey direct-file-cleanup-keeper' /home/copilot/.config/control-plane/ssh-auth/authorized_keys
! grep -Fq 'cleanup-marker' /home/copilot/.config/control-plane/ssh-auth/authorized_keys
! grep -Fq 'direct-file-cleanup-ephemeral' /home/copilot/.config/control-plane/ssh-auth/authorized_keys
test ! -e /tmp/job-transfers/cleanup-test
printf '%s\n' direct-ssh-auth-file-cleanup-ok
EOF
)"
direct_ssh_auth_file_cleanup_status=$?
set -e

if [[ "${direct_ssh_auth_file_cleanup_status}" -ne 0 ]]; then
  printf 'Expected direct ssh-auth authorized_keys file mounts to support cleanup\n' >&2
  printf '%s\n' "${direct_ssh_auth_file_cleanup_output}" >&2
  exit 1
fi
grep -qx 'direct-ssh-auth-file-cleanup-ok' <<<"${direct_ssh_auth_file_cleanup_output}"

printf '%s\n' 'config-injection-test: verifying full runtime config mounts keep ssh-auth authoritative' >&2
prepare_state_tree runtime-config-mounted
mkdir -p "${workdir}/runtime-config-mounted/runtime-config"

set +e
runtime_config_mount_output="$("${container_bin}" run --rm \
  --name "${container_name}" \
  "${control_plane_run_user[@]}" \
  -i \
  "${startup_caps[@]}" \
  -e SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIRuntimeConfigMountKey runtime-config-mounted' \
  -v "${workdir}/runtime-config-mounted/state/copilot:/home/copilot/.copilot" \
  -v "${workdir}/runtime-config-mounted/state/gh:/home/copilot/.config/gh" \
  -v "${workdir}/runtime-config-mounted/runtime-config:/home/copilot/.config/control-plane" \
  -v "${workdir}/runtime-config-mounted/state/ssh:/home/copilot/.ssh" \
  -v "${workdir}/runtime-config-mounted/state/ssh-host-keys:/var/lib/control-plane/ssh-host-keys" \
  -v "${workdir}/runtime-config-mounted/state/workspace:/workspace" \
  "${control_plane_image}" \
  bash -l -se 2>&1 <<'EOF'
set -euo pipefail
! test -L /home/copilot/.config/control-plane/ssh-auth/authorized_keys
test -L /home/copilot/.ssh/authorized_keys
test "$(readlink /home/copilot/.ssh/authorized_keys)" = '../.config/control-plane/ssh-auth/authorized_keys'
grep -Fqx 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIRuntimeConfigMountKey runtime-config-mounted' /home/copilot/.config/control-plane/ssh-auth/authorized_keys
printf '%s\n' runtime-config-mounted-ok
EOF
)"
runtime_config_mount_status=$?
set -e

if [[ "${runtime_config_mount_status}" -ne 0 ]]; then
  printf 'Expected full runtime config mounts to keep ssh-auth authoritative\n' >&2
  printf '%s\n' "${runtime_config_mount_output}" >&2
  exit 1
fi
grep -qx 'runtime-config-mounted-ok' <<<"${runtime_config_mount_output}"

printf '%s\n' 'config-injection-test: config injection regressions ok' >&2
