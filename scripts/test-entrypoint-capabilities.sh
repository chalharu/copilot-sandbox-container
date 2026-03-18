#!/usr/bin/env bash
set -euo pipefail

control_plane_image="${1:?usage: scripts/test-entrypoint-capabilities.sh <control-plane-image>}"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-podman}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

require_command "${container_bin}"

printf '%s\n' 'entrypoint-capability-test: verifying non-sshd command starts without AUDIT_WRITE' >&2
set +e
non_sshd_output="$("${container_bin}" run --rm \
  --cap-drop AUDIT_WRITE \
  "${control_plane_image}" \
  bash -lc 'printf "%s\n" startup-ok' 2>&1)"
non_sshd_status=$?
set -e

if [[ "${non_sshd_status}" -ne 0 ]]; then
  printf 'Expected non-sshd entrypoint command to start without AUDIT_WRITE\n' >&2
  printf '%s\n' "${non_sshd_output}" >&2
  exit 1
fi
grep -qx 'startup-ok' <<<"${non_sshd_output}"

printf '%s\n' 'entrypoint-capability-test: verifying direct sshd startup still requires AUDIT_WRITE' >&2
set +e
sshd_output="$("${container_bin}" run --rm \
  --cap-drop AUDIT_WRITE \
  "${control_plane_image}" 2>&1)"
sshd_status=$?
set -e

if [[ "${sshd_status}" -eq 0 ]]; then
  printf 'Expected direct sshd startup to fail without AUDIT_WRITE\n' >&2
  printf '%s\n' "${sshd_output}" >&2
  exit 1
fi
if ! grep -q 'Missing Linux capabilities for control-plane startup: AUDIT_WRITE' <<<"${sshd_output}"; then
  printf 'Expected direct sshd startup diagnostic to name AUDIT_WRITE\n' >&2
  printf '%s\n' "${sshd_output}" >&2
  exit 1
fi

printf '%s\n' 'entrypoint-capability-test: command gating looks good' >&2
