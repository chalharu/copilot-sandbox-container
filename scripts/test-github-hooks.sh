#!/usr/bin/env bash
set -euo pipefail

command -v node >/dev/null 2>&1 || {
  printf 'test-github-hooks.sh: node is required\n' >&2
  exit 1
}

node --test .github/hooks/postToolUse/main.test.mjs
