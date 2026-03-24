#!/usr/bin/env bash
set -euo pipefail

git_hook_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

git_hook_current_branch() {
  git symbolic-ref --quiet --short HEAD 2>/dev/null || true
}

git_hook_is_protected_branch() {
  local branch="${1:-}"
  [[ "${branch}" == "main" || "${branch}" == "master" ]]
}

git_hook_repo_hook_path() {
  local repo_root="$1"
  local hook_name="$2"

  printf '%s\n' "${repo_root}/.github/git-hooks/${hook_name}"
}

git_hook_require_executable_or_absent() {
  local target_path="$1"
  local description="$2"

  if [[ ! -e "${target_path}" ]]; then
    return 1
  fi

  if [[ ! -f "${target_path}" ]]; then
    printf 'Refusing to run non-file %s at %s\n' "${description}" "${target_path}" >&2
    exit 1
  fi

  if [[ ! -x "${target_path}" ]]; then
    printf 'Refusing to run non-executable %s at %s\n' "${description}" "${target_path}" >&2
    exit 1
  fi

  return 0
}

git_hook_run_post_tool_use_linter() {
  local repo_root="$1"
  local hook_root="${COPILOT_HOME:-${HOME}/.copilot}"
  local hook_script="${hook_root}/hooks/postToolUse/main.mjs"

  command -v node >/dev/null 2>&1 || {
    printf 'Global git hooks require node on PATH to run %s\n' "${hook_script}" >&2
    exit 1
  }

  if [[ ! -f "${hook_script}" ]]; then
    printf 'Expected bundled postToolUse hook at %s\n' "${hook_script}" >&2
    exit 1
  fi

  REPO_ROOT="${repo_root}" node --input-type=module <<'EOF' | node "${hook_script}"
process.stdout.write(
  JSON.stringify({
    cwd: process.env.REPO_ROOT,
    toolName: "git-hook",
    toolResult: { resultType: "success" },
  }),
);
EOF
}
