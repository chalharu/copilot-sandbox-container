#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"

runtime_config_file="${CONTROL_PLANE_RUNTIME_ENV_FILE:-${HOME:-/home/${USER:-copilot}}/.config/control-plane/runtime.env}"
namespace_file="/var/run/secrets/kubernetes.io/serviceaccount/namespace"
ssh_port="${CONTROL_PLANE_SSH_PORT:-2222}"
session_name="current-cluster-regression-$$"
workdir="$(mktemp -d)"
runtime_backup="${workdir}/runtime.env.bak"
authorized_keys_backup="${workdir}/authorized_keys.bak"

cleanup() {
  if [[ -f "${runtime_backup}" ]]; then
    cp "${runtime_backup}" "${runtime_config_file}" >/dev/null 2>&1 || true
    chmod 600 "${runtime_config_file}" >/dev/null 2>&1 || true
  fi
  if [[ -f "${authorized_keys_backup}" ]]; then
    cp "${authorized_keys_backup}" "${HOME}/.ssh/authorized_keys" >/dev/null 2>&1 || true
    chmod 600 "${HOME}/.ssh/authorized_keys" >/dev/null 2>&1 || true
  fi
  rm -rf "${workdir}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

require_command kubectl
require_command screen
require_command ssh
require_command ssh-keygen
require_command git

[[ -f "${runtime_config_file}" ]] || {
  printf 'Missing control-plane runtime env: %s\n' "${runtime_config_file}" >&2
  exit 1
}

namespace="${CONTROL_PLANE_K8S_NAMESPACE:-default}"
if [[ -f "${namespace_file}" ]]; then
  namespace="$(cat "${namespace_file}")"
fi
pod_name="$(hostname)"
pod_image="$(kubectl get pod "${pod_name}" -n "${namespace}" -o jsonpath='{.spec.containers[?(@.name=="control-plane")].image}')"
[[ -n "${pod_image}" ]] || {
  printf 'Unable to detect current control-plane image from %s/%s\n' "${namespace}" "${pod_name}" >&2
  exit 1
}

workspace_head="$(git -C "${script_dir}/.." rev-parse HEAD)"
workspace_dirty=0
if ! git -C "${script_dir}/.." diff --quiet --no-ext-diff || ! git -C "${script_dir}/.." diff --cached --quiet --no-ext-diff; then
  workspace_dirty=1
fi
if [[ "${workspace_dirty}" -eq 1 ]] || [[ "${pod_image}" != *":${workspace_head}" ]]; then
  printf 'current-cluster-test: skipping live-pod verification because running image (%s) does not match workspace HEAD (%s)\n' "${pod_image}" "${workspace_head}" >&2
  if [[ "${workspace_dirty}" -eq 1 ]]; then
    printf '%s\n' 'current-cluster-test: workspace has uncommitted changes, so the running image cannot represent the current code yet' >&2
  fi
  printf '%s\n' 'current-cluster-test: use scripts/test-k8s-job.sh for pre-deploy validation and re-run this script after updating the cluster image'
  exit 0
fi

printf 'current-cluster-test: pod=%s/%s image=%s\n' "${namespace}" "${pod_name}" "${pod_image}" >&2

# Keep this live-cluster path focused on behavior that only a running control-plane
# Pod can validate. Static skill packaging and local Podman flows already have
# coverage in the standard regression suite.
printf '%s\n' 'current-cluster-test: verifying interactive SSH auto-login' >&2
cp "${runtime_config_file}" "${runtime_backup}"
cp "${HOME}/.ssh/authorized_keys" "${authorized_keys_backup}"
printf '\nCONTROL_PLANE_SESSION_SELECTION=new:%s\n' "${session_name}" >> "${runtime_config_file}"
ssh-keygen -q -t ed25519 -N '' -f "${workdir}/id_ed25519" >/dev/null
cat "${workdir}/id_ed25519.pub" >> "${HOME}/.ssh/authorized_keys"
chmod 600 "${HOME}/.ssh/authorized_keys"
"${script_dir}/test-ssh-session-persistence.sh" \
  --identity "${workdir}/id_ed25519" \
  --port "${ssh_port}" \
  --session-name "${session_name}" \
  --marker-path /tmp/current-cluster-ssh-marker.txt

cp "${runtime_backup}" "${runtime_config_file}"
chmod 600 "${runtime_config_file}"
cp "${authorized_keys_backup}" "${HOME}/.ssh/authorized_keys"
chmod 600 "${HOME}/.ssh/authorized_keys"

printf '%s\n' 'current-cluster-test: ssh-interactive=ok'
printf '%s\n' 'current-cluster-test: current cluster regressions ok' >&2
