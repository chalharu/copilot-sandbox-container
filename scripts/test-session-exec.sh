#!/usr/bin/env bash
set -euo pipefail

command -v node >/dev/null 2>&1 || {
  printf 'test-session-exec.sh: node is required\n' >&2
  exit 1
}

bash containers/control-plane/skills/containerized-rust-ops/scripts/podman-rust.sh \
  -- \
  cargo test --manifest-path containers/control-plane/exec-api/Cargo.toml

node --test containers/control-plane/bin/control-plane-session-exec.test.mjs
