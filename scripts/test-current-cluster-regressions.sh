#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"

runtime_config_file="${CONTROL_PLANE_RUNTIME_ENV_FILE:-${HOME:-/home/${USER:-copilot}}/.config/control-plane/runtime.env}"
namespace_file="/var/run/secrets/kubernetes.io/serviceaccount/namespace"
ssh_port="${CONTROL_PLANE_SSH_PORT:-2222}"
session_name="current-cluster-regression-$$"
fast_exec_session_key=""
workdir="$(mktemp -d)"
runtime_backup="${workdir}/runtime.env.bak"
authorized_keys_backup="${workdir}/authorized_keys.bak"

cleanup() {
  if [[ -f "${runtime_backup}" ]]; then
    cp "${runtime_backup}" "${runtime_config_file}" >/dev/null 2>&1 || true
    chmod 600 "${runtime_config_file}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${fast_exec_session_key}" ]]; then
    control-plane-session-exec cleanup --session-key "${fast_exec_session_key}" >/dev/null 2>&1 || true
  fi
  if [[ -f "${authorized_keys_backup}" ]]; then
    cp "${authorized_keys_backup}" "${authorized_keys_path}" >/dev/null 2>&1 || true
    chmod 600 "${authorized_keys_path}" >/dev/null 2>&1 || true
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
load_control_plane_runtime_env
authorized_keys_path="${HOME:-/home/${USER:-copilot}}/.config/control-plane/ssh-auth/authorized_keys"

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
  printf '%s\n' 'current-cluster-test: use scripts/test-k8s-sample-storage-layout.sh plus scripts/test-standalone.sh or scripts/test-kind.sh for pre-deploy validation, then re-run this script after updating the cluster image'
  exit 0
fi

printf 'current-cluster-test: pod=%s/%s image=%s\n' "${namespace}" "${pod_name}" "${pod_image}" >&2

# Keep this live-cluster path focused on behavior that only a running control-plane
# Pod can validate. Static skill packaging and local Podman flows already have
# coverage in the standard regression suite.
printf '%s\n' 'current-cluster-test: verifying interactive SSH Copilot session reuse' >&2
cp "${runtime_config_file}" "${runtime_backup}"
cp "${authorized_keys_path}" "${authorized_keys_backup}"
cat > "${workdir}/fake-copilot-shell" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec bash -il
EOF
chmod 700 "${workdir}/fake-copilot-shell"
printf '\nCONTROL_PLANE_COPILOT_SESSION=%s\n' "${session_name}" >> "${runtime_config_file}"
printf '\nCONTROL_PLANE_COPILOT_BIN=%s\n' "${workdir}/fake-copilot-shell" >> "${runtime_config_file}"
ssh-keygen -q -t ed25519 -N '' -f "${workdir}/id_ed25519" >/dev/null
cat "${workdir}/id_ed25519.pub" >> "${authorized_keys_path}"
chmod 600 "${authorized_keys_path}"
if [[ "${CONTROL_PLANE_FAST_EXECUTION_ENABLED:-0}" == "1" ]]; then
  printf '%s\n' 'current-cluster-test: priming fast exec pod before SSH reconnect probe' >&2
  fast_exec_session_key="current-cluster-ssh-reconnect"
  control-plane-session-exec cleanup --session-key "${fast_exec_session_key}" >/dev/null 2>&1 || true
  control-plane-session-exec prepare --session-key "${fast_exec_session_key}" >/dev/null
  reconnect_command_base64="$(printf '%s' 'printf current-cluster-fast-exec > /tmp/current-cluster-fast-exec.txt' | base64 | tr -d '\n')"
  control-plane-session-exec proxy --session-key "${fast_exec_session_key}" --cwd /workspace --command-base64 "${reconnect_command_base64}" >/dev/null
fi
"${script_dir}/test-ssh-session-persistence.sh" \
  --identity "${workdir}/id_ed25519" \
  --port "${ssh_port}" \
  --session-name "${session_name}" \
  --marker-path /tmp/current-cluster-ssh-marker.txt

kubectl exec --namespace "${namespace}" "${pod_name}" -c control-plane -- bash -lc \
  "set -euo pipefail; \
   test -L /etc/ssh/ssh_host_ed25519_key; \
   test -L /etc/ssh/ssh_host_ed25519_key.pub; \
   test \"\$(readlink /etc/ssh/ssh_host_ed25519_key)\" = '/run/control-plane/ssh-host-keys/ssh_host_ed25519_key'; \
   test \"\$(readlink /etc/ssh/ssh_host_ed25519_key.pub)\" = '/run/control-plane/ssh-host-keys/ssh_host_ed25519_key.pub'; \
   test \"\$(env -u LD_PRELOAD stat -c '%a %U %G' /run/control-plane/ssh-host-keys)\" = '700 root root'; \
   test \"\$(env -u LD_PRELOAD stat -c '%a %U %G' /run/control-plane/ssh-host-keys/ssh_host_ed25519_key)\" = '600 root root'; \
   test \"\$(env -u LD_PRELOAD stat -c '%a %U %G' /run/control-plane/ssh-host-keys/ssh_host_ed25519_key.pub)\" = '644 root root'"

cp "${runtime_backup}" "${runtime_config_file}"
chmod 600 "${runtime_config_file}"
cp "${authorized_keys_backup}" "${authorized_keys_path}"
chmod 600 "${authorized_keys_path}"

printf '%s\n' 'current-cluster-test: ssh-interactive=ok'
printf '%s\n' 'current-cluster-test: current cluster regressions ok' >&2
