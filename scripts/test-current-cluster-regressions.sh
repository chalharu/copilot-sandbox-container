#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"

runtime_config_file="${CONTROL_PLANE_RUNTIME_ENV_FILE:-${HOME:-/home/${USER:-copilot}}/.config/control-plane/runtime.env}"
namespace_file="/var/run/secrets/kubernetes.io/serviceaccount/namespace"
ssh_port="${CONTROL_PLANE_SSH_PORT:-2222}"
build_probe_image="${CONTROL_PLANE_BUILD_PROBE_IMAGE:-localhost/current-cluster-build-probe:test}"
session_name="current-cluster-regression"
workdir="$(mktemp -d)"
runtime_backup="${workdir}/runtime.env.bak"
authorized_keys_backup="${workdir}/authorized_keys.bak"
interactive_ssh_pid=""

cleanup() {
  if [[ -n "${interactive_ssh_pid}" ]]; then
    kill "${interactive_ssh_pid}" >/dev/null 2>&1 || true
    wait "${interactive_ssh_pid}" 2>/dev/null || true
  fi
  if [[ -f "${runtime_backup}" ]]; then
    cp "${runtime_backup}" "${runtime_config_file}" >/dev/null 2>&1 || true
    chmod 600 "${runtime_config_file}" >/dev/null 2>&1 || true
  fi
  if [[ -f "${authorized_keys_backup}" ]]; then
    cp "${authorized_keys_backup}" "${HOME}/.ssh/authorized_keys" >/dev/null 2>&1 || true
    chmod 600 "${HOME}/.ssh/authorized_keys" >/dev/null 2>&1 || true
  fi
  podman rmi -f "${build_probe_image}" >/dev/null 2>&1 || true
  rm -rf "${workdir}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

require_command kubectl
require_command podman
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

load_control_plane_runtime_env

printf '%s\n' 'current-cluster-test: verifying bundled skill readability' >&2
skill_root="${HOME}/.copilot/skills/control-plane-operations"
test ! -L "${skill_root}"
test -r "${skill_root}/SKILL.md"
test -x "${skill_root}/references"
test -r "${skill_root}/references/control-plane-run.md"
test -r "${skill_root}/references/skills.md"
printf '%s\n' 'current-cluster-test: skill-read=ok'

printf '%s\n' 'current-cluster-test: verifying local podman build defaults' >&2
build_context="${workdir}/build-context"
mkdir -p "${build_context}"
cat > "${build_context}/Dockerfile" <<'EOF'
FROM docker.io/library/busybox:1.37.0
RUN printf '%s\n' build-ok > /build-ok.txt
EOF
build_image_for_toolchain podman "${build_probe_image}" "${build_context}"
build_probe_output="$(podman run --rm "${build_probe_image}" cat /build-ok.txt)"
grep -qx 'build-ok' <<<"${build_probe_output}"
printf '%s\n' 'current-cluster-test: podman-build=ok'

printf '%s\n' 'current-cluster-test: verifying interactive SSH auto-login' >&2
cp "${runtime_config_file}" "${runtime_backup}"
cp "${HOME}/.ssh/authorized_keys" "${authorized_keys_backup}"
printf '\nCONTROL_PLANE_SESSION_SELECTION=new:%s\n' "${session_name}" >> "${runtime_config_file}"
ssh-keygen -q -t ed25519 -N '' -f "${workdir}/id_ed25519" >/dev/null
cat "${workdir}/id_ed25519.pub" >> "${HOME}/.ssh/authorized_keys"
chmod 600 "${HOME}/.ssh/authorized_keys"

TERM=tmux-256color ssh -tt \
  -i "${workdir}/id_ed25519" \
  -p "${ssh_port}" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o BatchMode=yes \
  copilot@127.0.0.1 \
  </dev/null >"${workdir}/ssh.log" 2>&1 &
interactive_ssh_pid=$!

for _ in $(seq 1 15); do
  if screen -list 2>/dev/null | grep -q -- "${session_name}"; then
    break
  fi
  if ! kill -0 "${interactive_ssh_pid}" 2>/dev/null; then
    break
  fi
  sleep 1
done

screen -list 2>/dev/null | grep -q -- "${session_name}"
kill -0 "${interactive_ssh_pid}"

kill "${interactive_ssh_pid}" >/dev/null 2>&1 || true
wait "${interactive_ssh_pid}" 2>/dev/null || true
interactive_ssh_pid=""

cp "${runtime_backup}" "${runtime_config_file}"
chmod 600 "${runtime_config_file}"
cp "${authorized_keys_backup}" "${HOME}/.ssh/authorized_keys"
chmod 600 "${HOME}/.ssh/authorized_keys"

if grep -q 'cannot change locale' "${workdir}/ssh.log"; then
  printf 'Unexpected locale warning during interactive SSH login\n' >&2
  cat "${workdir}/ssh.log" >&2 || true
  exit 1
fi

printf '%s\n' 'current-cluster-test: ssh-interactive=ok'
printf '%s\n' 'current-cluster-test: current cluster regressions ok' >&2
