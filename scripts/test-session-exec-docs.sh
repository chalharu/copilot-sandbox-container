#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
runtime_doc_path="${repo_root}/docs/reference/control-plane-runtime.md"
knowledge_doc_path="${repo_root}/docs/explanation/knowledge.md"
cookbook_path="${repo_root}/docs/how-to-guides/cookbook.md"

assert_file_contains() {
  local path="$1"
  local expected="$2"

  grep -Fq -- "${expected}" "${path}" || {
    printf 'Expected %s to contain: %s\n' "${path}" "${expected}" >&2
    exit 1
  }
}

assert_file_not_contains() {
  local path="$1"
  local unexpected="$2"

  if grep -Fq -- "${unexpected}" "${path}"; then
    printf 'Did not expect %s to contain: %s\n' "${path}" "${unexpected}" >&2
    exit 1
  fi
}

printf '%s\n' 'session-exec-docs-test: verifying proxy helper stays internal in docs' >&2
assert_file_not_contains "${runtime_doc_path}" "Copilot CLI の \`bash\` tool を \`control-plane-session-exec proxy\` へ書き換えます。"
assert_file_contains "${runtime_doc_path}" "Copilot CLI の \`bash\` tool 自体はそのまま使います。"
assert_file_contains "${runtime_doc_path}" "agent が \`bash\` tool からこの helper を直接呼ぶ想定はありません。"
assert_file_contains "${knowledge_doc_path}" '内部 helper の'
assert_file_contains "${knowledge_doc_path}" "\`control-plane-session-exec proxy\` はこの経路でだけ使います。"
assert_file_contains "${knowledge_doc_path}" 'tool から直接呼ぶ想定はありません。'
assert_file_contains "${cookbook_path}" "\`control-plane-session-exec proxy\` はこの自動委譲の内部"
assert_file_contains "${cookbook_path}" "helper です。operator や agent が \`bash\` tool から直接呼びません。"
printf '%s\n' 'session-exec-docs-test: docs ok' >&2
