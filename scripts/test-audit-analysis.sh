#!/usr/bin/env bash
set -euo pipefail

control_plane_image="${1:?usage: scripts/test-audit-analysis.sh <control-plane-image>}"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-podman}"
workdir="$(mktemp -d)"
container_name="control-plane-audit-analysis-test"
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

cat > "${workdir}/audit-analysis-check.sh" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail

cd /workspace
git init --quiet
git config user.name test
git config user.email test@example.com
git remote add origin https://example.com/demo/repo.git

cat > "${HOME}/.copilot/config.json" <<'JSON'
{
  "telemetry": false,
  "controlPlane": {
    "auditAnalysis": {
      "enabled": true,
      "targetRepository": {
        "url": "https://example.com/chalharu/copilot-sandbox-container"
      },
      "minimumEvidenceCount": 2,
      "considerationThreshold": 1,
      "repeatThreshold": 2
    }
  }
}
JSON

emit_event() {
  local event_type="$1"
  local payload="$2"
  printf '%s' "${payload}" | node "${HOME}/.copilot/hooks/audit/main.mjs" "${event_type}"
}

emit_event sessionStart '{"timestamp":1704614400000,"cwd":"/workspace","source":"new","initialPrompt":"bootstrap"}'
emit_event userPromptSubmitted '{"timestamp":1704614500000,"cwd":"/workspace","prompt":"still seeing audit hook errors, please fix the audit log flow"}'
emit_event preToolUse '{"timestamp":1704614600000,"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"node audit-hook-check.mjs --mode initial\"}"}'
emit_event postToolUse '{"timestamp":1704614700000,"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"node audit-hook-check.mjs --mode initial\"}","toolResult":{"resultType":"error","textResultForLlm":"error: missing audit config"}}'
emit_event userPromptSubmitted '{"timestamp":1704614800000,"cwd":"/workspace","prompt":"again, audit hook still fails after the last fix"}'
emit_event preToolUse '{"timestamp":1704614900000,"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"node audit-hook-check.mjs --mode retry --config ~/.copilot/config.json\"}"}'
emit_event postToolUse '{"timestamp":1704615000000,"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"node audit-hook-check.mjs --mode retry --config ~/.copilot/config.json\"}","toolResult":{"resultType":"success","textResultForLlm":"audit config repaired"}}'
emit_event preToolUse '{"timestamp":1704615100000,"cwd":"/workspace","toolName":"rg","toolArgs":"{\"pattern\":\"audit hook\",\"path\":\"/workspace\"}"}'
emit_event postToolUse '{"timestamp":1704615200000,"cwd":"/workspace","toolName":"rg","toolArgs":"{\"pattern\":\"audit hook\",\"path\":\"/workspace\"}","toolResult":{"resultType":"success","textResultForLlm":"rg ok"}}'
emit_event preToolUse '{"timestamp":1704615300000,"cwd":"/workspace","toolName":"rg","toolArgs":"{\"pattern\":\"audit hook\",\"path\":\"/workspace\"}"}'
emit_event postToolUse '{"timestamp":1704615400000,"cwd":"/workspace","toolName":"rg","toolArgs":"{\"pattern\":\"audit hook\",\"path\":\"/workspace\"}","toolResult":{"resultType":"success","textResultForLlm":"rg ok"}}'

node "${HOME}/.copilot/hooks/auditAnalysis/main.mjs" agentStop

analysis_db="${HOME}/.copilot/session-state/audit/audit-analysis.db"
status_json="$(node "${HOME}/.copilot/skills/audit-log-analysis/scripts/audit-analysis.mjs" status --json --no-refresh)"

test -f "${analysis_db}"
sqlite3 "${analysis_db}" 'SELECT COUNT(*) FROM analysis_patterns;' | grep -Eq '^[1-9][0-9]*$'
sqlite3 "${analysis_db}" 'SELECT COUNT(*) FROM automation_candidates;' | grep -Eq '^[1-9][0-9]*$'
sqlite3 "${analysis_db}" 'SELECT trigger_source FROM analysis_runs ORDER BY id DESC LIMIT 1;' | grep -qx 'agentStop'

printf '%s\n' "${status_json}" | jq -e '.config.targetRepositoryUrl == "https://example.com/chalharu/copilot-sandbox-container"' >/dev/null
printf '%s\n' "${status_json}" | jq -e '.patternCounts["user-feedback"] >= 2' >/dev/null
printf '%s\n' "${status_json}" | jq -e '.patternCounts["error-resolution"] >= 1' >/dev/null
printf '%s\n' "${status_json}" | jq -e '.patternCounts["repeated-processing"] >= 1' >/dev/null
printf '%s\n' "${status_json}" | jq -e '.candidates | map(.candidateType) | index("command") != null' >/dev/null
printf '%s\n' "${status_json}" | jq -e '.candidates | map(.candidateType) | index("skill") != null' >/dev/null
printf '%s\n' "${status_json}" | jq -e '.candidates | map(.candidateType) | index("agent") != null' >/dev/null
printf '%s\n' 'audit-analysis-ok'
INNER
chmod 755 "${workdir}/audit-analysis-check.sh"

printf '%s\n' 'test-audit-analysis.sh: verifying audit analysis hook and bundled skill' >&2
set +e
output="$("${container_bin}" run --rm \
  --name "${container_name}" \
  -i \
  "${startup_caps[@]}" \
  -v "${workdir}/state/copilot:/home/copilot/.copilot" \
  -v "${workdir}/workspace:/workspace" \
  -v "${workdir}/audit-analysis-check.sh:/tmp/audit-analysis-check.sh:ro" \
  "${control_plane_image}" \
  bash -l -se 2>&1 <<'OUTER'
set -euo pipefail
source /home/copilot/.config/control-plane/runtime.env
su -s /bin/bash copilot -lc /tmp/audit-analysis-check.sh
OUTER
)"
status=$?
set -e

if [[ "${status}" -ne 0 ]]; then
  printf 'Expected audit analysis hook to succeed\n' >&2
  printf '%s\n' "${output}" >&2
  exit 1
fi

grep -qx 'audit-analysis-ok' <<<"${output}"
