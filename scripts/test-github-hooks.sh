#!/usr/bin/env bash
set -euo pipefail

control_plane_image="${1:-}"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-podman}"

command -v node >/dev/null 2>&1 || {
  printf 'test-github-hooks.sh: node is required\n' >&2
  exit 1
}

[[ ! -e .github/hooks ]] || {
  printf 'test-github-hooks.sh: .github/hooks should not exist anymore\n' >&2
  exit 1
}

node --test containers/control-plane/hooks/postToolUse/main.test.mjs

if [[ -z "${control_plane_image}" ]]; then
  exit 0
fi

command -v "${container_bin}" >/dev/null 2>&1 || {
  printf 'test-github-hooks.sh: %s is required to inspect the control-plane image\n' "${container_bin}" >&2
  exit 1
}

printf '%s\n' 'test-github-hooks.sh: verifying bundled postToolUse hook in control-plane image' >&2
"${container_bin}" run --rm \
  "${control_plane_image}" \
  bash -lc '
    test -f /usr/local/share/control-plane/hooks/control-plane-hooks.json
    test -f /usr/local/share/control-plane/hooks/postToolUse/main.mjs
    test -f /usr/local/share/control-plane/hooks/postToolUse/linters.json
    test -f /usr/local/share/control-plane/hooks/postToolUse/lib/incremental-files.mjs
    test -f /home/copilot/.copilot/hooks/control-plane-hooks.json
    test -f /home/copilot/.copilot/hooks/postToolUse/main.mjs
    test -f /home/copilot/.copilot/hooks/postToolUse/linters.json
    test -f /home/copilot/.copilot/hooks/postToolUse/lib/incremental-files.mjs
    grep -Fq ".copilot/hooks/postToolUse/main.mjs" /home/copilot/.copilot/hooks/control-plane-hooks.json
    ! grep -Fq ".github/hooks" /home/copilot/.copilot/hooks/control-plane-hooks.json
  '
