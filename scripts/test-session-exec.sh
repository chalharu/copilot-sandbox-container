#!/usr/bin/env bash
set -euo pipefail

command -v node >/dev/null 2>&1 || {
  printf 'test-session-exec.sh: node is required\n' >&2
  exit 1
}

node --test \
  containers/control-plane/bin/control-plane-session-exec.test.mjs \
  containers/control-plane/bin/control-plane-exec-api.test.mjs
