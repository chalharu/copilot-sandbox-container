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
    if [[ "${2:-}" == "--get-regexp" ]] && [[ "${3:-}" == "^remote\\..*\\.url$" ]]; then
      if [[ -f .git/test-remote-origin ]]; then
        printf 'remote.origin.url %s\n' "$(cat .git/test-remote-origin)"
      fi
    fi
    ;;
  remote)
    if [[ "${2:-}" == "add" ]] && [[ -n "${3:-}" ]] && [[ -n "${4:-}" ]]; then
      mkdir -p .git
      printf '%s\n' "${4}" > ".git/test-remote-${3}"
    fi
    ;;
  rev-parse)
    if [[ "${2:-}" == "--show-toplevel" ]]; then
      pwd
    elif [[ "${2:-}" == "--git-dir" ]]; then
      printf '%s\n' .git
    fi
    ;;
esac
EOF
chmod 755 "${workdir}/fake-bin/git"

cat > "${workdir}/audit-check.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cd /workspace
git init --quiet
git config user.name test
git config user.email test@example.com
git remote add origin https://example.com/demo/repo.git
audit_shell_pid="$$"

test "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" = "/home/copilot/.copilot/session-state/audit/audit-log.db"
test "${CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS}" = "8"
test "$(stat -c '%a %U %G' /home/copilot/.copilot/session-state/audit)" = '700 copilot copilot'

cat <<'JSON' | node "${HOME}/.copilot/hooks/audit/main.mjs" sessionStart
{"timestamp":1704614400000,"cwd":"/workspace","source":"new","initialPrompt":"bootstrap"}
JSON

cat <<'JSON' | node "${HOME}/.copilot/hooks/audit/main.mjs" userPromptSubmitted
{"timestamp":1704614500000,"cwd":"/workspace","prompt":"Fix audit logging"}
JSON

cat <<'JSON' | node "${HOME}/.copilot/hooks/audit/main.mjs" preToolUse
{"timestamp":1704614600000,"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"printf hello\",\"description\":\"demo\"}"}
JSON

cat <<'JSON' | node "${HOME}/.copilot/hooks/audit/main.mjs" postToolUse
{"timestamp":1704614700000,"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"printf hello\",\"description\":\"demo\"}","toolResult":{"resultType":"success","textResultForLlm":"ok"}}
JSON

test -f "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}"
test "$(stat -c '%a %U %G' "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}")" = '600 copilot copilot'

sqlite3 "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" "SELECT COUNT(*) FROM audit_events;" | grep -qx '4'
sqlite3 "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" "SELECT repo_path FROM audit_events WHERE event_type = 'sessionStart';" | grep -qx '/workspace'
sqlite3 "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" "SELECT git_remotes_json FROM audit_events WHERE event_type = 'sessionStart';" | grep -Fq 'https://example.com/demo/repo.git'
sqlite3 "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" "SELECT initial_prompt FROM audit_events WHERE event_type = 'sessionStart';" | grep -qx 'bootstrap'
sqlite3 "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" "SELECT user_prompt FROM audit_events WHERE event_type = 'userPromptSubmitted';" | grep -qx 'Fix audit logging'
sqlite3 "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" "SELECT tool_name FROM audit_events WHERE event_type = 'preToolUse';" | grep -qx 'bash'
sqlite3 "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" "SELECT tool_args_json FROM audit_events WHERE event_type = 'preToolUse';" | grep -Fq '"command":"printf hello"'
sqlite3 "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" "SELECT tool_result_type FROM audit_events WHERE event_type = 'postToolUse';" | grep -qx 'success'
sqlite3 "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" "SELECT tool_result_text FROM audit_events WHERE event_type = 'postToolUse';" | grep -qx 'ok'
sqlite3 "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" "SELECT COUNT(*) FROM audit_events WHERE ppid = ${audit_shell_pid};" | grep -qx '4'

cat <<'JSON' | node "${HOME}/.copilot/hooks/audit/main.mjs" preToolUse
{"timestamp":1704614800000,"cwd":"/workspace","toolName":"bash","toolArgs":"{\"command\":\"printf second\"}"}
JSON

cat <<'JSON' | node "${HOME}/.copilot/hooks/audit/main.mjs" preToolUse
{"timestamp":1704614900000,"cwd":"/workspace","toolName":"view","toolArgs":"{\"path\":\"/workspace/README.md\"}"}
JSON

cat <<'JSON' | node "${HOME}/.copilot/hooks/audit/main.mjs" postToolUse
{"timestamp":1704615000000,"cwd":"/workspace","toolName":"view","toolArgs":"{\"path\":\"/workspace/README.md\"}","toolResult":{"resultType":"success","textResultForLlm":"view ok"}}
JSON

cat <<'JSON' | node "${HOME}/.copilot/hooks/audit/main.mjs" preToolUse
{"timestamp":1704615100000,"cwd":"/workspace","toolName":"rg","toolArgs":"{\"pattern\":\"audit\"}"}
JSON

cat <<'JSON' | node "${HOME}/.copilot/hooks/audit/main.mjs" postToolUse
{"timestamp":1704615200000,"cwd":"/workspace","toolName":"rg","toolArgs":"{\"pattern\":\"audit\"}","toolResult":{"resultType":"success","textResultForLlm":"rg ok"}}
JSON

cat <<'JSON' | node "${HOME}/.copilot/hooks/audit/main.mjs" preToolUse
{"timestamp":1704615300000,"cwd":"/workspace","toolName":"git","toolArgs":"{\"args\":[\"status\",\"--short\"]}"}
JSON

sqlite3 "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" "SELECT COUNT(*) FROM audit_events;" | grep -qx '7'
sqlite3 "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" "SELECT COUNT(*) FROM audit_events WHERE event_type = 'sessionStart';" | grep -qx '0'
sqlite3 "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" "SELECT COUNT(*) FROM audit_events WHERE event_type = 'userPromptSubmitted';" | grep -qx '0'
sqlite3 "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" "SELECT MIN(created_at_ms) FROM audit_events;" | grep -qx '1704614700000'
sqlite3 "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" "SELECT MAX(created_at_ms) FROM audit_events;" | grep -qx '1704615300000'
sqlite3 "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" "SELECT event_type FROM audit_events ORDER BY created_at_ms ASC, id ASC LIMIT 1;" | grep -qx 'postToolUse'
sqlite3 "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" "SELECT tool_name FROM audit_events ORDER BY created_at_ms DESC, id DESC LIMIT 1;" | grep -qx 'git'
sqlite3 "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" "SELECT COUNT(*) FROM audit_events WHERE ppid = ${audit_shell_pid};" | grep -qx '7'

cat <<'JSON' | node "${HOME}/.copilot/hooks/audit/main.mjs" preToolUse
{"timestamp":1704614300000,"cwd":"/workspace","toolName":"history-replayed-pre","toolArgs":"{\"command\":\"printf replay-pre\"}"}
JSON

cat <<'JSON' | node "${HOME}/.copilot/hooks/audit/main.mjs" postToolUse
{"timestamp":1704614300100,"cwd":"/workspace","toolName":"history-replayed-post","toolArgs":"{\"command\":\"printf replay-post\"}","toolResult":{"resultType":"success","textResultForLlm":"replayed ok"}}
JSON

sqlite3 "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" "SELECT COUNT(*) FROM audit_events;" | grep -qx '6'
sqlite3 "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" "SELECT COUNT(*) FROM audit_events WHERE tool_name = 'history-replayed-post';" | grep -qx '1'
sqlite3 "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" "SELECT created_at_ms FROM audit_events WHERE tool_name = 'history-replayed-post';" | grep -qx '1704614300100'
sqlite3 "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" "SELECT COUNT(*) FROM audit_events WHERE ppid = ${audit_shell_pid};" | grep -qx '6'
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
  -v "${workdir}/fake-bin:/tmp/fake-bin:ro" \
  "${control_plane_image}" \
  bash -l -se 2>&1 <<'EOF'
set -euo pipefail
export PATH="/tmp/fake-bin:${PATH}"
source /home/copilot/.config/control-plane/runtime.env
test "${CONTROL_PLANE_AUDIT_LOG_DB_PATH}" = "/home/copilot/.copilot/session-state/audit/audit-log.db"
test "${CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS}" = "8"
su -s /bin/bash copilot -lc 'export PATH="/tmp/fake-bin:${PATH}"; /tmp/audit-check.sh'
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
