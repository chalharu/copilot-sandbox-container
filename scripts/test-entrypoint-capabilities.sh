#!/usr/bin/env bash
set -euo pipefail

control_plane_image="${1:?usage: scripts/test-entrypoint-capabilities.sh <control-plane-image>}"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-docker}"
control_plane_run_user=(--user 0:0)

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

require_command "${container_bin}"

printf '%s\n' 'entrypoint-capability-test: verifying default non-root startup reports runtime requirement' >&2
set +e
default_user_output="$("${container_bin}" run --rm "${control_plane_image}" 2>&1)"
default_user_status=$?
set -e

if [[ "${default_user_status}" -eq 0 ]]; then
  printf 'Expected default image startup to fail without an explicit root user override\n' >&2
  exit 1
fi
if ! grep -Fq 'control-plane-entrypoint must start as root' <<<"${default_user_output}"; then
  printf 'Expected default startup diagnostic to explain the root requirement\n' >&2
  printf '%s\n' "${default_user_output}" >&2
  exit 1
fi
if ! grep -Fq -- '--user 0:0' <<<"${default_user_output}" || ! grep -Fq 'runAsUser: 0' <<<"${default_user_output}"; then
  printf 'Expected default startup diagnostic to mention the supported root overrides\n' >&2
  printf '%s\n' "${default_user_output}" >&2
  exit 1
fi

printf '%s\n' 'entrypoint-capability-test: verifying non-sshd command starts without AUDIT_WRITE' >&2
set +e
non_sshd_output="$("${container_bin}" run --rm \
  "${control_plane_run_user[@]}" \
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
  "${control_plane_run_user[@]}" \
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
