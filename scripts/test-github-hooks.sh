#!/usr/bin/env bash
set -euo pipefail

control_plane_image="${1:-}"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-docker}"
control_plane_run_user=(--user 0:0)
# renovate: datasource=docker depName=docker.io/library/rust versioning=docker
rust_test_image="${CONTROL_PLANE_RUST_TEST_IMAGE:-docker.io/library/rust:1.94.1-bookworm@sha256:fdb91abf3cb33f1ebc84a76461d2472fd8cf606df69c181050fa7474bade2895}"

command -v node >/dev/null 2>&1 || {
  printf 'test-github-hooks.sh: node is required\n' >&2
  exit 1
}

command -v "${container_bin}" >/dev/null 2>&1 || {
  printf 'test-github-hooks.sh: %s is required\n' "${container_bin}" >&2
  exit 1
}

[[ ! -e .github/hooks ]] || {
  printf 'test-github-hooks.sh: .github/hooks should not exist anymore\n' >&2
  exit 1
}

printf '%s\n' 'test-github-hooks.sh: verifying Rust-backed hook helpers' >&2
"${container_bin}" run --rm \
  "${control_plane_run_user[@]}" \
  -i \
  -v "${PWD}:/workspace" \
  -w /workspace/containers/control-plane/runtime-tools \
  --entrypoint sh \
  "${rust_test_image}" \
  -c 'cargo test'

printf '%s\n' 'test-github-hooks.sh: verifying remaining git hook tests' >&2
node --test \
  containers/control-plane/hooks/git/main.test.mjs

if [[ -z "${control_plane_image}" ]]; then
  exit 0
fi

printf '%s\n' 'test-github-hooks.sh: verifying bundled hooks in control-plane image' >&2
"${container_bin}" run --rm \
  "${control_plane_run_user[@]}" \
  -i \
  "${control_plane_image}" \
  bash -l -se <<'EOF'
set -euo pipefail
test -f /usr/local/share/control-plane/hooks/hooks.json
test -x /usr/local/share/control-plane/hooks/audit/main
test -x /usr/local/share/control-plane/hooks/preToolUse/main
test -x /usr/local/share/control-plane/hooks/preToolUse/exec-forward
test -f /usr/local/share/control-plane/hooks/preToolUse/deny-rules.yaml
test -f /usr/local/lib/libcontrol_plane_exec_policy.so
test -x /usr/local/share/control-plane/hooks/git/pre-commit
test -x /usr/local/share/control-plane/hooks/git/pre-push
test -f /usr/local/share/control-plane/hooks/git/lib/common.sh
test -x /usr/local/share/control-plane/hooks/postToolUse/main
test -x /usr/local/share/control-plane/hooks/postToolUse/control-plane-rust.sh
test -f /usr/local/share/control-plane/hooks/postToolUse/linters.json
test -x /usr/local/share/control-plane/hooks/sessionEnd/cleanup
test -x /usr/local/bin/control-plane-exec-api
test -x /usr/local/bin/control-plane-exec-api-launcher
test -x /usr/local/bin/control-plane-runtime-tool
test -x /usr/local/bin/control-plane-session-exec
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
test -x /home/copilot/.copilot/hooks/audit/main
test -x /home/copilot/.copilot/hooks/preToolUse/main
test -x /home/copilot/.copilot/hooks/preToolUse/exec-forward
test -f /home/copilot/.copilot/hooks/preToolUse/deny-rules.yaml
test -f /usr/local/lib/libcontrol_plane_exec_policy.so
test -x /home/copilot/.copilot/hooks/git/pre-commit
test -x /home/copilot/.copilot/hooks/git/pre-push
test -f /home/copilot/.copilot/hooks/git/lib/common.sh
test -x /home/copilot/.copilot/hooks/postToolUse/main
test -x /home/copilot/.copilot/hooks/postToolUse/control-plane-rust.sh
test -f /home/copilot/.copilot/hooks/postToolUse/linters.json
test -x /home/copilot/.copilot/hooks/sessionEnd/cleanup
grep -Fqx '    hooksPath = /usr/local/share/control-plane/hooks/git' "${GIT_CONFIG_GLOBAL}"
test "$(grep -Fc '    helper = !gh auth git-credential' "${GIT_CONFIG_GLOBAL}")" -eq 2
grep -Fq "COPILOT_HOME" /home/copilot/.copilot/hooks/hooks.json
grep -Fq "hooks/audit/main" /home/copilot/.copilot/hooks/hooks.json
grep -Fq "hooks/preToolUse/main" /home/copilot/.copilot/hooks/hooks.json
grep -Fq "hooks/preToolUse/exec-forward" /home/copilot/.copilot/hooks/hooks.json
grep -Fq "hooks/postToolUse/main" /home/copilot/.copilot/hooks/hooks.json
grep -Fq "hooks/postToolUse/control-plane-rust.sh" /usr/local/share/control-plane/hooks/postToolUse/linters.json
grep -Fq "hooks/sessionEnd/cleanup" /home/copilot/.copilot/hooks/hooks.json
! grep -Fq "powershell" /home/copilot/.copilot/hooks/hooks.json
! grep -Fq "auditAnalysis" /home/copilot/.copilot/hooks/hooks.json
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
