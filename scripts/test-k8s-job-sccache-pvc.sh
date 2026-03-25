#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
job_start_path="${script_dir}/../containers/control-plane/bin/k8s-job-start"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/control-plane-k8s-job-sccache.XXXXXX")"

cleanup() {
  rm -rf "${workdir}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fake_bin="${workdir}/fake-bin"
mkdir -p "${fake_bin}"

cat > "${fake_bin}/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

capture_path="${CAPTURED_MANIFEST_PATH:?}"
if [[ "${1:-}" != "create" ]] || [[ "${2:-}" != "-f" ]] || [[ "${3:-}" != "-" ]]; then
  printf 'unexpected kubectl invocation: %s\n' "$*" >&2
  exit 1
fi

cat > "${capture_path}"
EOF
chmod +x "${fake_bin}/kubectl"

export PATH="${fake_bin}:${PATH}"
runtime_env="${workdir}/runtime.env"
: > "${runtime_env}"

assert_contains() {
  local path="$1"
  local expected="$2"

  grep -Fq "${expected}" "${path}" || {
    printf 'Expected manifest %s to contain: %s\n' "${path}" "${expected}" >&2
    exit 1
  }
}

assert_absent() {
  local path="$1"
  local unexpected="$2"

  if grep -Fq "${unexpected}" "${path}"; then
    printf 'Did not expect manifest %s to contain: %s\n' "${path}" "${unexpected}" >&2
    exit 1
  fi
}

printf '%s\n' 'k8s-job-sccache-pvc-test: verifying control-plane namespace fallback' >&2
fallback_manifest="${workdir}/fallback-job.yaml"
env -i \
  PATH="${PATH}" \
  HOME="${HOME}" \
  USER="${USER:-copilot}" \
  CAPTURED_MANIFEST_PATH="${fallback_manifest}" \
  CONTROL_PLANE_RUNTIME_ENV_FILE="${runtime_env}" \
  CONTROL_PLANE_K8S_NAMESPACE=control-plane-ns \
  CONTROL_PLANE_SCCACHE_PVC=control-plane-sccache-pvc \
  CONTROL_PLANE_SCCACHE_MOUNT_PATH=/workspace/cache/sccache \
  "${job_start_path}" --namespace control-plane-ns --image docker.io/library/bash:latest -- /bin/true >/dev/null
assert_contains "${fallback_manifest}" "claimName: 'control-plane-sccache-pvc'"
assert_contains "${fallback_manifest}" "mountPath: '/workspace/cache/sccache'"

printf '%s\n' 'k8s-job-sccache-pvc-test: verifying non-control-plane namespaces stay opt-in' >&2
isolated_manifest="${workdir}/isolated-job.yaml"
env -i \
  PATH="${PATH}" \
  HOME="${HOME}" \
  USER="${USER:-copilot}" \
  CAPTURED_MANIFEST_PATH="${isolated_manifest}" \
  CONTROL_PLANE_RUNTIME_ENV_FILE="${runtime_env}" \
  CONTROL_PLANE_K8S_NAMESPACE=control-plane-ns \
  CONTROL_PLANE_SCCACHE_PVC=control-plane-sccache-pvc \
  CONTROL_PLANE_SCCACHE_MOUNT_PATH=/workspace/cache/sccache \
  "${job_start_path}" --namespace other-ns --image docker.io/library/bash:latest -- /bin/true >/dev/null
assert_absent "${isolated_manifest}" "claimName: 'control-plane-sccache-pvc'"
assert_absent "${isolated_manifest}" "mountPath: '/workspace/cache/sccache'"

printf '%s\n' 'k8s-job-sccache-pvc-test: verifying explicit job overrides' >&2
override_manifest="${workdir}/override-job.yaml"
env -i \
  PATH="${PATH}" \
  HOME="${HOME}" \
  USER="${USER:-copilot}" \
  CAPTURED_MANIFEST_PATH="${override_manifest}" \
  CONTROL_PLANE_RUNTIME_ENV_FILE="${runtime_env}" \
  CONTROL_PLANE_K8S_NAMESPACE=control-plane-ns \
  CONTROL_PLANE_SCCACHE_PVC=control-plane-sccache-pvc \
  CONTROL_PLANE_JOB_SCCACHE_PVC=job-sccache-pvc \
  CONTROL_PLANE_JOB_SCCACHE_MOUNT_PATH=/var/cache/sccache \
  "${job_start_path}" --namespace other-ns --image docker.io/library/bash:latest -- /bin/true >/dev/null
assert_contains "${override_manifest}" "claimName: 'job-sccache-pvc'"
assert_contains "${override_manifest}" "mountPath: '/var/cache/sccache'"

printf '%s\n' 'k8s-job-sccache-pvc-test: helper wiring ok' >&2
