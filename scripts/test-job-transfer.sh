#!/usr/bin/env bash
set -euo pipefail

runtime_config_file="${CONTROL_PLANE_RUNTIME_ENV_FILE:-${HOME:-/home/${USER:-copilot}}/.config/control-plane/runtime.env}"
if [[ -f "${runtime_config_file}" ]]; then
  # shellcheck disable=SC1090
  source "${runtime_config_file}"
fi

execution_plane_image="${1:?usage: scripts/test-job-transfer.sh <execution-plane-image> [job-namespace]}"
job_namespace="${2:-${CONTROL_PLANE_JOB_NAMESPACE:-${CONTROL_PLANE_K8S_NAMESPACE:-default}}}"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/control-plane-job-transfer-test.XXXXXX")"
success_job_name=""
conflict_job_name=""
conflict_transfer_id=""

cleanup() {
  if [[ -n "${success_job_name}" ]]; then
    kubectl delete job --namespace "${job_namespace}" "${success_job_name}" --ignore-not-found >/dev/null 2>&1 || true
  fi
  if [[ -n "${conflict_job_name}" ]]; then
    kubectl delete job --namespace "${job_namespace}" "${conflict_job_name}" --ignore-not-found >/dev/null 2>&1 || true
  fi
  if [[ -n "${conflict_transfer_id}" ]]; then
    control-plane-job-transfer release-access --transfer-id "${conflict_transfer_id}" --remove-transfer-dir >/dev/null 2>&1 || true
  fi
  rm -rf "${workdir}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

require_command kubectl
require_command k8s-job-start
require_command k8s-job-wait
require_command control-plane-job-transfer

job_transfer_root="${CONTROL_PLANE_JOB_TRANSFER_ROOT:-${TMPDIR:-/tmp}/job-transfers}"

printf '%s\n' 'job-transfer-test: verifying large mount-file transfer and write-back' >&2
success_source="${workdir}/large-transfer.txt"
dd if=/dev/zero of="${success_source}" bs=1048576 count=1 status=none
success_job_name="ci-job-transfer-success-$(date +%s)-$RANDOM"
success_job_name="${success_job_name,,}"
success_job_name="${success_job_name//[^a-z0-9-]/-}"
success_job_name="${success_job_name:0:63}"
success_job_name="${success_job_name%-}"
success_job_script="$(cat <<'EOF'
set -euo pipefail
input_path=/var/run/control-plane/job-inputs/inputs/large-transfer.txt
test "$(wc -c < "${input_path}")" -gt 900000
printf "\nlarge-transfer-updated\n" >> "${input_path}"
EOF
)"

k8s-job-start \
  --namespace "${job_namespace}" \
  --job-name "${success_job_name}" \
  --image "${execution_plane_image}" \
  --mount-file "${success_source}:inputs/large-transfer.txt" \
  -- /usr/local/bin/execution-plane-smoke exec bash -lc "${success_job_script}" >/dev/null

success_transfer_id="$(kubectl get job --namespace "${job_namespace}" "${success_job_name}" -o jsonpath='{.metadata.annotations.control-plane\.github\.io/job-transfer-id}')"
success_transfer_secret="$(kubectl get job --namespace "${job_namespace}" "${success_job_name}" -o jsonpath='{.metadata.annotations.control-plane\.github\.io/job-transfer-secret}')"
k8s-job-wait --namespace "${job_namespace}" --job-name "${success_job_name}" --timeout 180s

if ! grep -Fqx 'large-transfer-updated' <(tail -n 1 "${success_source}"); then
  printf 'Expected large mount-file write-back to update %s\n' "${success_source}" >&2
  cat "${success_source}" >&2
  exit 1
fi
if kubectl get secret --namespace "${job_namespace}" "${success_transfer_secret}" >/dev/null 2>&1; then
  printf 'Expected transfer Secret %s to be deleted after successful write-back\n' "${success_transfer_secret}" >&2
  exit 1
fi
if [[ -e "${job_transfer_root%/}/${success_transfer_id}" ]]; then
  printf 'Expected transfer staging directory %s to be removed after successful finalize\n' "${job_transfer_root%/}/${success_transfer_id}" >&2
  find "${job_transfer_root%/}/${success_transfer_id}" -maxdepth 3 -print >&2 || true
  exit 1
fi

printf '%s\n' 'job-transfer-test: verifying conflict-safe write-back' >&2
conflict_source="${workdir}/conflict-transfer.txt"
printf '%s\n' 'base-value' > "${conflict_source}"
conflict_job_name="ci-job-transfer-conflict-$(date +%s)-$RANDOM"
conflict_job_name="${conflict_job_name,,}"
conflict_job_name="${conflict_job_name//[^a-z0-9-]/-}"
conflict_job_name="${conflict_job_name:0:63}"
conflict_job_name="${conflict_job_name%-}"
conflict_job_script="$(cat <<'EOF'
set -euo pipefail
input_path=/var/run/control-plane/job-inputs/inputs/conflict-transfer.txt
sleep 5
printf "%s\n" "job-side-change" >> "${input_path}"
EOF
)"

k8s-job-start \
  --namespace "${job_namespace}" \
  --job-name "${conflict_job_name}" \
  --image "${execution_plane_image}" \
  --mount-file "${conflict_source}:inputs/conflict-transfer.txt" \
  -- /usr/local/bin/execution-plane-smoke exec bash -lc "${conflict_job_script}" >/dev/null

conflict_transfer_id="$(kubectl get job --namespace "${job_namespace}" "${conflict_job_name}" -o jsonpath='{.metadata.annotations.control-plane\.github\.io/job-transfer-id}')"
conflict_transfer_secret="$(kubectl get job --namespace "${job_namespace}" "${conflict_job_name}" -o jsonpath='{.metadata.annotations.control-plane\.github\.io/job-transfer-secret}')"
printf '%s\n' 'external-side-change' >> "${conflict_source}"

set +e
k8s-job-wait --namespace "${job_namespace}" --job-name "${conflict_job_name}" --timeout 180s
conflict_wait_status=$?
set -e
if [[ "${conflict_wait_status}" -eq 0 ]]; then
  printf 'Expected conflicting write-back to fail the Job\n' >&2
  kubectl logs "job/${conflict_job_name}" --namespace "${job_namespace}" --all-containers=true >&2 || true
  exit 1
fi

if grep -Fq 'job-side-change' "${conflict_source}"; then
  printf 'Expected conflicting write-back to keep the local source unchanged by the Job\n' >&2
  cat "${conflict_source}" >&2
  exit 1
fi
grep -Fq 'external-side-change' "${conflict_source}"
if kubectl get secret --namespace "${job_namespace}" "${conflict_transfer_secret}" >/dev/null 2>&1; then
  printf 'Expected transfer Secret %s to be deleted after conflict handling\n' "${conflict_transfer_secret}" >&2
  exit 1
fi
conflict_transfer_dir="${job_transfer_root%/}/${conflict_transfer_id}"
if [[ ! -f "${conflict_transfer_dir}/conflicts.txt" ]]; then
  printf 'Expected conflict report at %s/conflicts.txt\n' "${conflict_transfer_dir}" >&2
  find "${conflict_transfer_dir}" -maxdepth 3 -print >&2 || true
  exit 1
fi
grep -Fq 'conflict inputs/conflict-transfer.txt' "${conflict_transfer_dir}/conflicts.txt"
if ! kubectl logs "job/${conflict_job_name}" --namespace "${job_namespace}" --all-containers=true 2>/dev/null | grep -Fq 'detected 1 conflict'; then
  printf 'Expected conflict log in Job output for %s\n' "${conflict_job_name}" >&2
  kubectl logs "job/${conflict_job_name}" --namespace "${job_namespace}" --all-containers=true >&2 || true
  exit 1
fi

printf '%s\n' 'job-transfer-test: SSH/rclone transfer regressions ok' >&2
