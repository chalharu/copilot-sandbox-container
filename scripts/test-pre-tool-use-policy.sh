#!/usr/bin/env bash
set -euo pipefail

control_plane_image="${1:?usage: scripts/test-pre-tool-use-policy.sh <control-plane-image>}"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-docker}"
workdir="$(mktemp -d)"
container_name="control-plane-pre-tool-use-policy-test"
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

mkdir -p \
  "${workdir}/fake-bin" \
  "${workdir}/state/copilot/session-state" \
  "${workdir}/workspace"

cat > "${workdir}/fake-bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  init)
    mkdir -p .git
    ;;
  config)
    ;;
  rev-parse)
    if [[ "${2:-}" == "--git-dir" ]]; then
      printf '%s\n' .git
    fi
    ;;
  push)
    if [[ " $* " == *" --force-with-lease "* ]]; then
      printf '%s\n' 'fatal: No configured push destination.' >&2
      exit 1
    fi
    ;;
esac
EOF
chmod 755 "${workdir}/fake-bin/git"

cat > "${workdir}/fake-bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "auth" ]] && [[ "${2:-}" == "token" ]]; then
  printf '%s\n' 'gh auth token should have been denied before executing gh' >&2
  exit 99
fi
while IFS= read -r _; do :; done < "${HOME}/.config/gh/hosts.yml"
EOF
chmod 755 "${workdir}/fake-bin/gh"

cat > "${workdir}/pre-tool-use-check.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cd /workspace
git init --quiet
git config user.name test
git config user.email test@example.com

hook_script="${HOME}/.copilot/hooks/preToolUse/main"
hook_config="${HOME}/.copilot/hooks/preToolUse/deny-rules.yaml"
exec_policy_library="${CONTROL_PLANE_EXEC_POLICY_LIBRARY:-}"
exec_policy_rules="${CONTROL_PLANE_EXEC_POLICY_RULES_FILE:-}"
copilot_token_path="${HOME}/.config/control-plane/copilot-github-token"

test -x "${hook_script}"
test -f "${hook_config}"
test -n "${exec_policy_library}"
test -n "${exec_policy_rules}"
test -f "${exec_policy_library}"
test -f "${exec_policy_rules}"
test "${LD_PRELOAD}" = "${exec_policy_library}"

mkdir -p "${HOME}/.config/gh"
export CONTROL_PLANE_COPILOT_GITHUB_TOKEN_FILE="${copilot_token_path}"

# Raw secret mounts stay present, but direct reads are intentionally denied by
# the exec policy. The explicit deny assertions below verify that contract.

run_hook() {
  local payload="$1"
  printf '%s' "${payload}" | "${hook_script}"
}

assert_denied_exec() {
  local expected_reason="$1"
  shift

  local command
  local stderr_file
  local status
  printf -v command '%q ' "$@"
  stderr_file="$(mktemp)"
  set +e
  env \
    LD_PRELOAD="${LD_PRELOAD}" \
    CONTROL_PLANE_EXEC_POLICY_LIBRARY="${CONTROL_PLANE_EXEC_POLICY_LIBRARY}" \
    CONTROL_PLANE_EXEC_POLICY_RULES_FILE="${CONTROL_PLANE_EXEC_POLICY_RULES_FILE}" \
    GIT_CONFIG_GLOBAL="${GIT_CONFIG_GLOBAL}" \
    CONTROL_PLANE_COPILOT_GITHUB_TOKEN_FILE="${CONTROL_PLANE_COPILOT_GITHUB_TOKEN_FILE}" \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
    HOME="${HOME}" \
    PATH="${PATH}" \
    bash -c "${command}" > /dev/null 2>"${stderr_file}"
  status=$?
  set -e

  if [[ "${status}" -eq 0 ]]; then
    printf 'Expected exec-layer policy to deny: %s\n' "$*" >&2
    exit 1
  fi

  grep -Fq 'control-plane exec policy:' "${stderr_file}"
  grep -Fq "${expected_reason}" "${stderr_file}"
  rm -f "${stderr_file}"
}

assert_denied_shell() {
  local expected_reason="$1"
  local shell_command="$2"
  local stderr_file
  local status
  stderr_file="$(mktemp)"
  set +e
  env \
    LD_PRELOAD="${LD_PRELOAD}" \
    CONTROL_PLANE_EXEC_POLICY_LIBRARY="${CONTROL_PLANE_EXEC_POLICY_LIBRARY}" \
    CONTROL_PLANE_EXEC_POLICY_RULES_FILE="${CONTROL_PLANE_EXEC_POLICY_RULES_FILE}" \
    GIT_CONFIG_GLOBAL="${GIT_CONFIG_GLOBAL}" \
    CONTROL_PLANE_COPILOT_GITHUB_TOKEN_FILE="${CONTROL_PLANE_COPILOT_GITHUB_TOKEN_FILE}" \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
    HOME="${HOME}" \
    PATH="${PATH}" \
    bash -c "${shell_command}" > /dev/null 2>"${stderr_file}"
  status=$?
  set -e

  if [[ "${status}" -eq 0 ]]; then
    printf 'Expected exec-layer file-access policy to deny: %s\n' "${shell_command}" >&2
    exit 1
  fi

  grep -Fq 'control-plane exec policy:' "${stderr_file}"
  grep -Fq "${expected_reason}" "${stderr_file}"
  rm -f "${stderr_file}"
}

assert_allowed_shell() {
  local shell_command="$1"
  local stderr_file
  local status
  stderr_file="$(mktemp)"
  set +e
  env \
    LD_PRELOAD="${LD_PRELOAD}" \
    CONTROL_PLANE_EXEC_POLICY_LIBRARY="${CONTROL_PLANE_EXEC_POLICY_LIBRARY}" \
    CONTROL_PLANE_EXEC_POLICY_RULES_FILE="${CONTROL_PLANE_EXEC_POLICY_RULES_FILE}" \
    GIT_CONFIG_GLOBAL="${GIT_CONFIG_GLOBAL}" \
    CONTROL_PLANE_COPILOT_GITHUB_TOKEN_FILE="${CONTROL_PLANE_COPILOT_GITHUB_TOKEN_FILE}" \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
    HOME="${HOME}" \
    PATH="${PATH}" \
    bash -c "${shell_command}" > /dev/null 2>"${stderr_file}"
  status=$?
  set -e

  if grep -Fq 'control-plane exec policy:' "${stderr_file}"; then
    printf 'Did not expect exec-layer file-access policy to deny: %s\n' "${shell_command}" >&2
    cat "${stderr_file}" >&2
    exit 1
  fi
  if [[ "${status}" -ne 0 ]]; then
    printf 'Expected command to remain allowed: %s\n' "${shell_command}" >&2
    cat "${stderr_file}" >&2
    exit 1
  fi

  rm -f "${stderr_file}"
}

commit_deny="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"git commit --no-verify -m \\\"skip\\\"\"}"}')"
printf '%s\n' "${commit_deny}" | jq -e '.permissionDecision == "deny"' >/dev/null
printf '%s\n' "${commit_deny}" | jq -e '.permissionDecisionReason | contains("git commit --no-verify")' >/dev/null

commit_short_deny="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"git commit -n -m \\\"skip\\\"\"}"}')"
printf '%s\n' "${commit_short_deny}" | jq -e '.permissionDecision == "deny"' >/dev/null
printf '%s\n' "${commit_short_deny}" | jq -e '.permissionDecisionReason | contains("git commit --no-verify")' >/dev/null

commit_stacked_short_deny="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"git commit -a -n -m \\\"skip\\\"\"}"}')"
printf '%s\n' "${commit_stacked_short_deny}" | jq -e '.permissionDecision == "deny"' >/dev/null
printf '%s\n' "${commit_stacked_short_deny}" | jq -e '.permissionDecisionReason | contains("git commit --no-verify")' >/dev/null

commit_cluster_deny="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"git commit -nm \\\"skip\\\"\"}"}')"
printf '%s\n' "${commit_cluster_deny}" | jq -e '.permissionDecision == "deny"' >/dev/null
printf '%s\n' "${commit_cluster_deny}" | jq -e '.permissionDecisionReason | contains("git commit --no-verify")' >/dev/null

commit_attached_cluster_deny="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"git commit -mn\"}"}')"
printf '%s\n' "${commit_attached_cluster_deny}" | jq -e '.permissionDecision == "deny"' >/dev/null
printf '%s\n' "${commit_attached_cluster_deny}" | jq -e '.permissionDecisionReason | contains("git commit --no-verify")' >/dev/null

hooks_path_deny="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"git -c core.hooksPath=/tmp/evil commit -m \\\"skip\\\"\"}"}')"
printf '%s\n' "${hooks_path_deny}" | jq -e '.permissionDecision == "deny"' >/dev/null
printf '%s\n' "${hooks_path_deny}" | jq -e '.permissionDecisionReason | contains("core.hooksPath overrides")' >/dev/null

hooks_path_env_deny="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"HOOKS=/tmp/evil git --config-env=core.hooksPath=HOOKS status --short\"}"}')"
printf '%s\n' "${hooks_path_env_deny}" | jq -e '.permissionDecision == "deny"' >/dev/null
printf '%s\n' "${hooks_path_env_deny}" | jq -e '.permissionDecisionReason | contains("core.hooksPath overrides")' >/dev/null

push_deny="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"git push origin HEAD --no-verify\"}"}')"
printf '%s\n' "${push_deny}" | jq -e '.permissionDecision == "deny"' >/dev/null
printf '%s\n' "${push_deny}" | jq -e '.permissionDecisionReason | contains("git push --no-verify")' >/dev/null

force_deny="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"FOO=1 git -C . push -f origin HEAD\"}"}')"
printf '%s\n' "${force_deny}" | jq -e '.permissionDecision == "deny"' >/dev/null
printf '%s\n' "${force_deny}" | jq -e '.permissionDecisionReason | contains("Force pushes")' >/dev/null

force_cluster_deny="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"git push -fn origin HEAD\"}"}')"
printf '%s\n' "${force_cluster_deny}" | jq -e '.permissionDecision == "deny"' >/dev/null
printf '%s\n' "${force_cluster_deny}" | jq -e '.permissionDecisionReason | contains("Force pushes")' >/dev/null

force_with_lease_allow="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"git push --force-with-lease origin HEAD\"}"}')"
test -z "${force_with_lease_allow}"

gh_auth_token_deny="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"gh auth token\"}"}')"
printf '%s\n' "${gh_auth_token_deny}" | jq -e '.permissionDecision == "deny"' >/dev/null
printf '%s\n' "${gh_auth_token_deny}" | jq -e '.permissionDecisionReason | contains("gh auth token")' >/dev/null

gh_pr_merge_deny="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"gh pr merge 123 --squash\"}"}')"
printf '%s\n' "${gh_pr_merge_deny}" | jq -e '.permissionDecision == "deny"' >/dev/null
printf '%s\n' "${gh_pr_merge_deny}" | jq -e '.permissionDecisionReason | contains("gh pr merge")' >/dev/null

gh_api_merge_endpoint_deny="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"gh api --method PUT https://api.github.com/repos/octo-org/octo-repo/pulls/123/merge\"}"}')"
printf '%s\n' "${gh_api_merge_endpoint_deny}" | jq -e '.permissionDecision == "deny"' >/dev/null
printf '%s\n' "${gh_api_merge_endpoint_deny}" | jq -e '.permissionDecisionReason | contains("pull request merge endpoints")' >/dev/null

gh_api_merge_short_deny="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"gh api repos/octo-org/octo-repo/pulls/123/merge\"}"}')"
printf '%s\n' "${gh_api_merge_short_deny}" | jq -e '.permissionDecision == "deny"' >/dev/null
printf '%s\n' "${gh_api_merge_short_deny}" | jq -e '.permissionDecisionReason | contains("pull request merge endpoints")' >/dev/null

gh_pr_view_allow="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"gh pr view 123\"}"}')"
test -z "${gh_pr_view_allow}"

gh_api_pull_allow="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"gh api repos/octo-org/octo-repo/pulls/123\"}"}')"
test -z "${gh_api_pull_allow}"

wrapped_deny="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"bash -lc \\\"git commit --no-verify -m \\\\\\\"skip\\\\\\\"\\\"\"}"}')"
printf '%s\n' "${wrapped_deny}" | jq -e '.permissionDecision == "deny"' >/dev/null
printf '%s\n' "${wrapped_deny}" | jq -e '.permissionDecisionReason | contains("git commit --no-verify")' >/dev/null

allow_output="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"git push -n origin HEAD\"}"}')"
test -z "${allow_output}"

env_override_deny="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"GIT_CONFIG_GLOBAL=/tmp/evil git status --short\"}"}')"
printf '%s\n' "${env_override_deny}" | jq -e '.permissionDecision == "deny"' >/dev/null
printf '%s\n' "${env_override_deny}" | jq -e '.permissionDecisionReason | contains("Protected environment overrides")' >/dev/null

mkdir -p .github
cat > .github/pre-tool-use-rules.yaml <<'YAML'
commandRules:
  - rule: 'git(?:\x00[^\x00]+)*\x00status(?:\x00[^\x00]+)*\x00--short(?:\x00[^\x00]+)*'
    reason: repo-local policy
YAML

override_deny="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"git status --short\"}"}')"
printf '%s\n' "${override_deny}" | jq -e '.permissionDecision == "deny"' >/dev/null
printf '%s\n' "${override_deny}" | jq -e '.permissionDecisionReason == "repo-local policy"' >/dev/null

assert_denied_exec 'git commit --no-verify' git commit --no-verify -m skip
assert_denied_exec 'git commit --no-verify' git commit -- --no-verify
assert_denied_exec 'core.hooksPath overrides are blocked' git -c core.hooksPath=/tmp/evil commit -m skip
assert_denied_exec 'core.hooksPath overrides are blocked' env HOOKS=/tmp/evil git --config-env=core.hooksPath=HOOKS status --short
assert_denied_exec 'Force pushes are blocked' git push -f origin HEAD
assert_denied_exec 'gh auth token is blocked' gh auth token
assert_denied_exec 'gh pr merge is blocked' gh pr merge 123 --squash
assert_denied_exec 'pull request merge endpoints are blocked' gh api --method PUT https://api.github.com/repos/octo-org/octo-repo/pulls/123/merge
assert_denied_exec 'pull request merge endpoints are blocked' gh api repos/octo-org/octo-repo/pulls/123/merge
assert_denied_exec 'Protected environment overrides are blocked' env GIT_CONFIG_GLOBAL=/tmp/evil git status --short
assert_denied_exec 'repo-local policy' git status --short
assert_denied_shell 'CONTROL_PLANE_COPILOT_GITHUB_TOKEN_FILE' 'while IFS= read -r _; do :; done < "${CONTROL_PLANE_COPILOT_GITHUB_TOKEN_FILE}"'
assert_denied_shell '~/.config/gh/hosts.yml' 'while IFS= read -r _; do :; done < "${HOME}/.config/gh/hosts.yml"'
assert_denied_shell '/run/control-plane-auth' 'cat "/run/control-plane-auth/ssh-public-key"'
assert_denied_shell '/run/control-plane-auth' 'cat "/run/control-plane-auth/gh-github-token"'
assert_denied_shell '/run/control-plane-auth' 'cat "/run/control-plane-auth/gh-hosts.yml"'
assert_denied_shell '/run/control-plane-auth' 'cat "/run/control-plane-auth/copilot-github-token"'
assert_allowed_shell '/usr/local/bin/control-plane-copilot'
assert_allowed_shell 'gh auth status'
assert_allowed_shell 'gh pr view 123'
assert_allowed_shell 'gh api repos/octo-org/octo-repo/pulls/123'

cat > /tmp/force-push-wrapper.sh <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
git push -f origin HEAD
WRAPPER
chmod 755 /tmp/force-push-wrapper.sh
assert_denied_exec 'Force pushes are blocked' /tmp/force-push-wrapper.sh

node_stderr="$(mktemp)"
set +e
node <<'NODE' > /dev/null 2>"${node_stderr}"
const { spawnSync } = require("node:child_process");

const result = spawnSync("bash", ["-c", "git push -f origin HEAD"], {
  encoding: "utf8",
  stdio: ["ignore", "ignore", "inherit"],
});

if (result.error) {
  process.stderr.write(`${result.error.code ?? result.error.message}\n`);
  process.exit(1);
}
process.exit(result.status ?? 1);
NODE
node_status=$?
set -e
if [[ "${node_status}" -eq 0 ]]; then
  printf '%s\n' 'Expected Node child-process execution to be denied by exec policy' >&2
  exit 1
fi
grep -Fq 'control-plane exec policy:' "${node_stderr}"
grep -Fq 'Force pushes are blocked' "${node_stderr}"
rm -f "${node_stderr}"

allow_env_stderr="$(mktemp)"
set +e
env \
  LD_PRELOAD="${LD_PRELOAD}" \
  CONTROL_PLANE_EXEC_POLICY_LIBRARY="${CONTROL_PLANE_EXEC_POLICY_LIBRARY}" \
  CONTROL_PLANE_EXEC_POLICY_RULES_FILE="${CONTROL_PLANE_EXEC_POLICY_RULES_FILE}" \
  GIT_CONFIG_GLOBAL="${GIT_CONFIG_GLOBAL}" \
  XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
  HOME="${HOME}" \
  PATH="${PATH}" \
  bash -c 'git rev-parse --git-dir' > /dev/null 2>"${allow_env_stderr}"
allow_env_status=$?
set -e
if grep -Fq 'control-plane exec policy:' "${allow_env_stderr}"; then
  printf '%s\n' 'Did not expect managed GIT_CONFIG_GLOBAL to be denied by exec policy' >&2
  cat "${allow_env_stderr}" >&2
  exit 1
fi
if [[ "${allow_env_status}" -ne 0 ]]; then
  printf '%s\n' 'Expected managed GIT_CONFIG_GLOBAL to remain allowed' >&2
  cat "${allow_env_stderr}" >&2
  exit 1
fi
rm -f "${allow_env_stderr}"

allow_stderr="$(mktemp)"
set +e
env \
  LD_PRELOAD="${LD_PRELOAD}" \
  CONTROL_PLANE_EXEC_POLICY_LIBRARY="${CONTROL_PLANE_EXEC_POLICY_LIBRARY}" \
  CONTROL_PLANE_EXEC_POLICY_RULES_FILE="${CONTROL_PLANE_EXEC_POLICY_RULES_FILE}" \
  GIT_CONFIG_GLOBAL="${GIT_CONFIG_GLOBAL}" \
  XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
  HOME="${HOME}" \
  PATH="${PATH}" \
  bash -c 'git push --force-with-lease origin HEAD' > /dev/null 2>"${allow_stderr}"
allow_status=$?
set -e
if grep -Fq 'control-plane exec policy:' "${allow_stderr}"; then
  printf '%s\n' 'Did not expect --force-with-lease to be denied by exec policy' >&2
  cat "${allow_stderr}" >&2
  exit 1
fi
if [[ "${allow_status}" -eq 0 ]]; then
  printf '%s\n' 'Expected force-with-lease check to fail only because no remote exists in the test repo' >&2
  exit 1
fi
rm -f "${allow_stderr}"

printf '%s\n' 'pre-tool-use-policy-ok'
EOF
chmod 755 "${workdir}/pre-tool-use-check.sh"

printf '%s\n' 'test-pre-tool-use-policy.sh: verifying bundled preToolUse and exec policy deny paths' >&2
set +e
output="$("${container_bin}" run --rm \
  --name "${container_name}" \
  "${control_plane_run_user[@]}" \
  -i \
  "${startup_caps[@]}" \
  -v "${workdir}/state/copilot:/home/copilot/.copilot" \
  -v "${workdir}/workspace:/workspace" \
  -v "${workdir}/pre-tool-use-check.sh:/tmp/pre-tool-use-check.sh:ro" \
  -v "${workdir}/fake-bin:/tmp/fake-bin:ro" \
"${control_plane_image}" \
  bash -l -se 2>&1 <<'EOF'
set -euo pipefail
env -u LD_PRELOAD bash -se <<'EOF_SETUP'
set -euo pipefail
install -d -o copilot -g copilot /home/copilot/.config/gh
install -d -o copilot -g copilot /home/copilot/.config/control-plane
install -d -o copilot -g copilot /run/control-plane-auth/..data
printf '%s\n' 'copilot-secret-token' > /home/copilot/.config/control-plane/copilot-github-token
cat > /home/copilot/.config/gh/hosts.yml <<'YAML'
github.com:
  oauth_token: managed-gh-token
  user: managed-bot
YAML
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestMountedKey mounted@test' > /run/control-plane-auth/..data/ssh-public-key
printf '%s\n' 'mounted-gh-token' > /run/control-plane-auth/..data/gh-github-token
cat > /run/control-plane-auth/..data/gh-hosts.yml <<'YAML'
github.com:
  oauth_token: mounted-gh-token
  user: mounted-bot
YAML
printf '%s\n' 'mounted-copilot-token' > /run/control-plane-auth/..data/copilot-github-token
ln -s ..data/ssh-public-key /run/control-plane-auth/ssh-public-key
ln -s ..data/gh-github-token /run/control-plane-auth/gh-github-token
ln -s ..data/gh-hosts.yml /run/control-plane-auth/gh-hosts.yml
ln -s ..data/copilot-github-token /run/control-plane-auth/copilot-github-token
chown copilot:copilot \
  /home/copilot/.config/control-plane/copilot-github-token \
  /run/control-plane-auth/..data/ssh-public-key \
  /run/control-plane-auth/..data/gh-github-token \
  /run/control-plane-auth/..data/gh-hosts.yml \
  /run/control-plane-auth/..data/copilot-github-token
chmod 600 \
  /home/copilot/.config/control-plane/copilot-github-token \
  /run/control-plane-auth/..data/ssh-public-key \
  /run/control-plane-auth/..data/gh-github-token \
  /run/control-plane-auth/..data/gh-hosts.yml \
  /run/control-plane-auth/..data/copilot-github-token
chown copilot:copilot /home/copilot/.config/gh/hosts.yml
chmod 600 /home/copilot/.config/gh/hosts.yml
rm -f \
  /usr/local/bin/control-plane-copilot \
  /usr/bin/gh
cat > /usr/local/bin/control-plane-copilot <<'EOF_COPILOT'
#!/usr/bin/env bash
set -euo pipefail
while IFS= read -r _; do :; done < "${CONTROL_PLANE_COPILOT_GITHUB_TOKEN_FILE}"
EOF_COPILOT
cat > /usr/bin/gh <<'EOF_GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "auth" ]] && [[ "${2:-}" == "token" ]]; then
  printf '%s\n' 'gh auth token should have been denied before executing gh' >&2
  exit 99
fi
while IFS= read -r _; do :; done < "${HOME}/.config/gh/hosts.yml"
EOF_GH
chmod 755 \
  /usr/local/bin/control-plane-copilot \
  /usr/bin/gh
EOF_SETUP
source /home/copilot/.config/control-plane/runtime.env
su -s /bin/bash copilot -lc 'export PATH="${PATH}:/tmp/fake-bin"; /tmp/pre-tool-use-check.sh'
EOF
)"
status=$?
set -e

if [[ "${status}" -ne 0 ]]; then
  printf 'Expected bundled preToolUse deny policy hook to succeed\n' >&2
  printf '%s\n' "${output}" >&2
  exit 1
fi

grep -qx 'pre-tool-use-policy-ok' <<<"${output}"
