#!/usr/bin/env bash
set -euo pipefail

control_plane_image="${1:?usage: scripts/test-audit-logging.sh <control-plane-image>}"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-docker}"
workdir="$(mktemp -d)"
container_name="control-plane-audit-logging-test"
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
require_command git

mkdir -p \
  "${workdir}/state/copilot/session-state" \
  "${workdir}/workspace"

git -C "${workdir}/workspace" init --quiet
git -C "${workdir}/workspace" config user.name test
git -C "${workdir}/workspace" config user.email test@example.com
git -C "${workdir}/workspace" remote add origin https://example.com/demo/repo.git

cat > "${workdir}/audit-check.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cd /workspace
audit_shell_pid="$$"

test "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" = "/home/copilot/.copilot/session-state/audit/audit-log.db"
test "${CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS}" = "8"
test "$(stat -c '%a %U %G' /home/copilot/.copilot/session-state/audit)" = '700 copilot copilot'

query_db() {
  python3 - "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" "$1" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
try:
    row = connection.execute(sys.argv[2]).fetchone()
finally:
    connection.close()

value = "" if row is None or row[0] is None else row[0]
print(value)
PY
}

cat <<'JSON' | "${HOME}/.copilot/hooks/audit/main" sessionStart
{"timestamp":1704614400000,"cwd":"/workspace","source":"new","initialPrompt":"bootstrap"}
JSON

cat <<'JSON' | "${HOME}/.copilot/hooks/audit/main" userPromptSubmitted
{"timestamp":1704614500000,"cwd":"/workspace","prompt":"Fix audit logging"}
JSON

cat <<'JSON' | "${HOME}/.copilot/hooks/audit/main" preToolUse
{"timestamp":1704614600000,"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"printf hello\",\"description\":\"demo\"}"}
JSON

cat <<'JSON' | "${HOME}/.copilot/hooks/audit/main" postToolUse
{"timestamp":1704614700000,"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"printf hello\",\"description\":\"demo\"}","toolResult":{"resultType":"success","textResultForLlm":"ok"}}
JSON

test -f "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}"
test "$(stat -c '%a %U %G' "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}")" = '600 copilot copilot'

query_db "SELECT COUNT(*) FROM audit_events;" | grep -qx '4'
query_db "SELECT repo_path FROM audit_events WHERE event_type = 'sessionStart';" | grep -Eq '^/workspace/?$'
query_db "SELECT git_remotes_json FROM audit_events WHERE event_type = 'sessionStart';" | grep -Fq 'https://example.com/demo/repo.git'
query_db "SELECT initial_prompt FROM audit_events WHERE event_type = 'sessionStart';" | grep -qx 'bootstrap'
query_db "SELECT user_prompt FROM audit_events WHERE event_type = 'userPromptSubmitted';" | grep -qx 'Fix audit logging'
query_db "SELECT tool_name FROM audit_events WHERE event_type = 'preToolUse';" | grep -qx 'bash'
query_db "SELECT tool_args_json FROM audit_events WHERE event_type = 'preToolUse';" | grep -Fq '"command":"printf hello"'
query_db "SELECT tool_result_type FROM audit_events WHERE event_type = 'postToolUse';" | grep -qx 'success'
query_db "SELECT tool_result_text FROM audit_events WHERE event_type = 'postToolUse';" | grep -qx 'ok'
query_db "SELECT COUNT(*) FROM audit_events WHERE ppid = ${audit_shell_pid};" | grep -qx '4'

cat <<'JSON' | "${HOME}/.copilot/hooks/audit/main" preToolUse
{"timestamp":1704614800000,"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"printf second\"}"}
JSON

cat <<'JSON' | "${HOME}/.copilot/hooks/audit/main" preToolUse
{"timestamp":1704614900000,"cwd":"/workspace","toolName":"view","toolArgs":"{\"path\":\"/workspace/README.md\"}"}
JSON

cat <<'JSON' | "${HOME}/.copilot/hooks/audit/main" postToolUse
{"timestamp":1704615000000,"cwd":"/workspace","toolName":"view","toolArgs":"{\"path\":\"/workspace/README.md\"}","toolResult":{"resultType":"success","textResultForLlm":"view ok"}}
JSON

cat <<'JSON' | "${HOME}/.copilot/hooks/audit/main" preToolUse
{"timestamp":1704615100000,"cwd":"/workspace","toolName":"rg","toolArgs":"{\"pattern\":\"audit\"}"}
JSON

cat <<'JSON' | "${HOME}/.copilot/hooks/audit/main" postToolUse
{"timestamp":1704615200000,"cwd":"/workspace","toolName":"rg","toolArgs":"{\"pattern\":\"audit\"}","toolResult":{"resultType":"success","textResultForLlm":"rg ok"}}
JSON

cat <<'JSON' | "${HOME}/.copilot/hooks/audit/main" preToolUse
{"timestamp":1704615300000,"cwd":"/workspace","toolName":"git","toolArgs":"{\"args\":[\"status\",\"--short\"]}"}
JSON

query_db "SELECT COUNT(*) FROM audit_events;" | grep -qx '7'
query_db "SELECT COUNT(*) FROM audit_events WHERE event_type = 'sessionStart';" | grep -qx '0'
query_db "SELECT COUNT(*) FROM audit_events WHERE event_type = 'userPromptSubmitted';" | grep -qx '0'
query_db "SELECT MIN(created_at_ms) FROM audit_events;" | grep -qx '1704614700000'
query_db "SELECT MAX(created_at_ms) FROM audit_events;" | grep -qx '1704615300000'
query_db "SELECT event_type FROM audit_events ORDER BY created_at_ms ASC, id ASC LIMIT 1;" | grep -qx 'postToolUse'
query_db "SELECT tool_name FROM audit_events ORDER BY created_at_ms DESC, id DESC LIMIT 1;" | grep -qx 'git'
query_db "SELECT COUNT(*) FROM audit_events WHERE ppid = ${audit_shell_pid};" | grep -qx '7'

cat <<'JSON' | "${HOME}/.copilot/hooks/audit/main" preToolUse
{"timestamp":1704614300000,"cwd":"/workspace","toolName":"history-replayed-pre","toolArgs":"{\"command\":\"printf replay-pre\"}"}
JSON

cat <<'JSON' | "${HOME}/.copilot/hooks/audit/main" postToolUse
{"timestamp":1704614300100,"cwd":"/workspace","toolName":"history-replayed-post","toolArgs":"{\"command\":\"printf replay-post\"}","toolResult":{"resultType":"success","textResultForLlm":"replayed ok"}}
JSON

query_db "SELECT COUNT(*) FROM audit_events;" | grep -qx '6'
query_db "SELECT COUNT(*) FROM audit_events WHERE tool_name = 'history-replayed-post';" | grep -qx '1'
query_db "SELECT created_at_ms FROM audit_events WHERE tool_name = 'history-replayed-post';" | grep -qx '1704614300100'
query_db "SELECT COUNT(*) FROM audit_events WHERE ppid = ${audit_shell_pid};" | grep -qx '6'
printf '%s\n' 'audit-logging-ok'
EOF
chmod 755 "${workdir}/audit-check.sh"

printf '%s\n' 'test-audit-logging.sh: verifying SQLite-backed audit logging hook' >&2
set +e
output="$("${container_bin}" run --rm \
  --name "${container_name}" \
  "${control_plane_run_user[@]}" \
  -i \
  "${startup_caps[@]}" \
  -e CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS=8 \
  -v "${workdir}/state/copilot:/home/copilot/.copilot" \
  -v "${workdir}/workspace:/workspace" \
  -v "${workdir}/audit-check.sh:/tmp/audit-check.sh:ro" \
  "${control_plane_image}" \
  bash -l -se 2>&1 <<'EOF'
set -euo pipefail
source /home/copilot/.config/control-plane/runtime.env
test "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" = "/home/copilot/.copilot/session-state/audit/audit-log.db"
test "${CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS}" = "8"
su -s /bin/bash copilot -lc /tmp/audit-check.sh
EOF
)"
status=$?
set -e

if [[ "${status}" -ne 0 ]]; then
  printf 'Expected SQLite-backed audit logging hook to succeed\n' >&2
  printf '%s\n' "${output}" >&2
  exit 1
fi

grep -qx 'audit-logging-ok' <<<"${output}"
