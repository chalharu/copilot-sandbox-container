#!/usr/bin/env bash
set -euo pipefail

control_plane_image="${1:-}"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-podman}"

command -v node >/dev/null 2>&1 || {
  printf 'test-github-hooks.sh: node is required\n' >&2
  exit 1
}

[[ ! -e .github/hooks ]] || {
  printf 'test-github-hooks.sh: .github/hooks should not exist anymore\n' >&2
  exit 1
}

node --test \
  containers/control-plane/hooks/audit/main.test.mjs \
  containers/control-plane/hooks/postToolUse/main.test.mjs \
  containers/control-plane/hooks/git/main.test.mjs

if [[ -z "${control_plane_image}" ]]; then
  exit 0
fi

command -v "${container_bin}" >/dev/null 2>&1 || {
  printf 'test-github-hooks.sh: %s is required to inspect the control-plane image\n' "${container_bin}" >&2
  exit 1
}

printf '%s\n' 'test-github-hooks.sh: verifying bundled hooks in control-plane image' >&2
"${container_bin}" run --rm \
  -i \
  "${control_plane_image}" \
  bash -l -se <<'EOF'
set -euo pipefail
test -f /usr/local/share/control-plane/hooks/hooks.json
test -f /usr/local/share/control-plane/hooks/audit/main.mjs
test -f /usr/local/share/control-plane/hooks/auditAnalysis/main.mjs
test -x /usr/local/share/control-plane/hooks/git/pre-commit
test -x /usr/local/share/control-plane/hooks/git/pre-push
test -f /usr/local/share/control-plane/hooks/git/lib/common.sh
test -f /usr/local/share/control-plane/hooks/postToolUse/main.mjs
test -f /usr/local/share/control-plane/hooks/postToolUse/linters.json
test -f /usr/local/share/control-plane/hooks/postToolUse/lib/incremental-files.mjs
test "${COPILOT_HOME}" = /var/lib/control-plane/managed-runtime/copilot-home
test "${GIT_CONFIG_GLOBAL}" = /var/lib/control-plane/managed-runtime/gitconfig
test -L /home/copilot/.copilot/hooks
test "$(readlink /home/copilot/.copilot/hooks)" = /usr/local/share/control-plane/hooks
test -L /home/copilot/.gitconfig
test "$(readlink /home/copilot/.gitconfig)" = "${GIT_CONFIG_GLOBAL}"
test "$(stat -c '%a %U %G' "${COPILOT_HOME}")" = "755 root root"
test "$(stat -c '%a %U %G' "${COPILOT_HOME}/hooks/hooks.json")" = "644 root root"
test "$(stat -c '%a %U %G' "${GIT_CONFIG_GLOBAL}")" = "644 root root"
test -f /home/copilot/.copilot/hooks/hooks.json
test -f /home/copilot/.copilot/hooks/audit/main.mjs
test -f /home/copilot/.copilot/hooks/auditAnalysis/main.mjs
test -x /home/copilot/.copilot/hooks/git/pre-commit
test -x /home/copilot/.copilot/hooks/git/pre-push
test -f /home/copilot/.copilot/hooks/git/lib/common.sh
test -f /home/copilot/.copilot/hooks/postToolUse/main.mjs
test -f /home/copilot/.copilot/hooks/postToolUse/linters.json
test -f /home/copilot/.copilot/hooks/postToolUse/lib/incremental-files.mjs
git config --global --get core.hooksPath | grep -qx /usr/local/share/control-plane/hooks/git
grep -Fq "COPILOT_HOME" /home/copilot/.copilot/hooks/hooks.json
grep -Fq "hooks/audit/main.mjs" /home/copilot/.copilot/hooks/hooks.json
grep -Fq "hooks/auditAnalysis/main.mjs" /home/copilot/.copilot/hooks/hooks.json
grep -Fq "hooks/postToolUse/main.mjs" /home/copilot/.copilot/hooks/hooks.json
! grep -Fq ".github/hooks" /home/copilot/.copilot/hooks/hooks.json
if su -s /bin/bash copilot -lc "printf tamper >> \"${GIT_CONFIG_GLOBAL}\"" 2>/dev/null; then
  printf "%s\n" "Expected managed git config to be read-only for the copilot user" >&2
  exit 1
fi
if su -s /bin/bash copilot -lc "printf tamper >> \"${COPILOT_HOME}/hooks/hooks.json\"" 2>/dev/null; then
  printf "%s\n" "Expected managed Copilot hooks to be read-only for the copilot user" >&2
  exit 1
fi
EOF
