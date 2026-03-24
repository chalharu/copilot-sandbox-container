#!/usr/bin/env bash
set -euo pipefail

control_plane_image="${1:?usage: scripts/test-pre-tool-use-policy.sh <control-plane-image>}"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-podman}"
workdir="$(mktemp -d)"
container_name="control-plane-pre-tool-use-policy-test"
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
  "${workdir}/state/copilot/session-state" \
  "${workdir}/workspace"

cat > "${workdir}/pre-tool-use-check.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cd /workspace
git init --quiet
git config user.name test
git config user.email test@example.com

hook_script="${HOME}/.copilot/hooks/preToolUse/main.mjs"
hook_config="${HOME}/.copilot/hooks/preToolUse/deny-rules.json"

test -f "${hook_script}"
test -f "${hook_config}"

run_hook() {
  local payload="$1"
  printf '%s' "${payload}" | node "${hook_script}"
}

commit_deny="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"git commit --no-verify -m \\\"skip\\\"\"}"}')"
printf '%s\n' "${commit_deny}" | jq -e '.permissionDecision == "deny"' >/dev/null
printf '%s\n' "${commit_deny}" | jq -e '.permissionDecisionReason | contains("git commit --no-verify")' >/dev/null

commit_short_deny="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"git commit -n -m \\\"skip\\\"\"}"}')"
printf '%s\n' "${commit_short_deny}" | jq -e '.permissionDecision == "deny"' >/dev/null
printf '%s\n' "${commit_short_deny}" | jq -e '.permissionDecisionReason | contains("git commit --no-verify")' >/dev/null

push_deny="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"git push origin HEAD --no-verify\"}"}')"
printf '%s\n' "${push_deny}" | jq -e '.permissionDecision == "deny"' >/dev/null
printf '%s\n' "${push_deny}" | jq -e '.permissionDecisionReason | contains("git push --no-verify")' >/dev/null

force_deny="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"FOO=1 git -C . push -f origin HEAD\"}"}')"
printf '%s\n' "${force_deny}" | jq -e '.permissionDecision == "deny"' >/dev/null
printf '%s\n' "${force_deny}" | jq -e '.permissionDecisionReason | contains("Force pushes")' >/dev/null

allow_output="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"git push origin HEAD\"}"}')"
test -z "${allow_output}"

mkdir -p .github
cat > .github/pre-tool-use-rules.json <<'JSON'
[
  {
    "toolName": "bash",
    "column": "command",
    "patterns": [
      {
        "patterns": [
          "^git status(?: .+)? --short(?: |$)"
        ],
        "reason": "repo-local policy"
      }
    ]
  }
]
JSON

override_deny="$(run_hook '{"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"git status --short\"}"}')"
printf '%s\n' "${override_deny}" | jq -e '.permissionDecision == "deny"' >/dev/null
printf '%s\n' "${override_deny}" | jq -e '.permissionDecisionReason == "repo-local policy"' >/dev/null
printf '%s\n' 'pre-tool-use-policy-ok'
EOF
chmod 755 "${workdir}/pre-tool-use-check.sh"

printf '%s\n' 'test-pre-tool-use-policy.sh: verifying bundled preToolUse deny policy hook' >&2
set +e
output="$("${container_bin}" run --rm \
  --name "${container_name}" \
  -i \
  "${startup_caps[@]}" \
  -v "${workdir}/state/copilot:/home/copilot/.copilot" \
  -v "${workdir}/workspace:/workspace" \
  -v "${workdir}/pre-tool-use-check.sh:/tmp/pre-tool-use-check.sh:ro" \
  "${control_plane_image}" \
  bash -l -se 2>&1 <<'EOF'
set -euo pipefail
source /home/copilot/.config/control-plane/runtime.env
su -s /bin/bash copilot -lc /tmp/pre-tool-use-check.sh
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
