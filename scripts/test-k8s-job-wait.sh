#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
job_wait_path="${script_dir}/../containers/control-plane/bin/k8s-job-wait"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/control-plane-job-wait-test.XXXXXX")"

cleanup() {
  rm -rf "${workdir}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fake_bin="${workdir}/fake-bin"
mkdir -p "${fake_bin}"

cat > "${fake_bin}/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != "get" ]] || [[ "${2:-}" != "job" ]]; then
  printf 'unexpected kubectl invocation: %s\n' "$*" >&2
  exit 1
fi

job_name="${3:-}"
case "${job_name}" in
  complete-job)
    printf '%s\n' 'Complete=True'
    ;;
  failed-job)
    printf '%s\n' 'Failed=True'
    ;;
  pending-job)
    ;;
  *)
    printf 'unexpected job name: %s\n' "${job_name}" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${fake_bin}/kubectl"

export PATH="${fake_bin}:${PATH}"

printf '%s\n' 'k8s-job-wait-test: verifying completed job exits immediately' >&2
complete_start_ns="$(date +%s%N)"
"${job_wait_path}" --namespace test --job-name complete-job --timeout 5s
complete_elapsed_ms="$(( ($(date +%s%N) - complete_start_ns) / 1000000 ))"
if (( complete_elapsed_ms > 2000 )); then
  printf 'Expected complete-job to exit quickly, took %sms\n' "${complete_elapsed_ms}" >&2
  exit 1
fi

printf '%s\n' 'k8s-job-wait-test: verifying failed job exits immediately' >&2
failed_start_ns="$(date +%s%N)"
set +e
failed_output="$("${job_wait_path}" --namespace test --job-name failed-job --timeout 5s 2>&1)"
failed_status=$?
set -e
failed_elapsed_ms="$(( ($(date +%s%N) - failed_start_ns) / 1000000 ))"
if [[ "${failed_status}" -ne 1 ]]; then
  printf 'Expected failed-job to exit 1, got %s\n' "${failed_status}" >&2
  printf '%s\n' "${failed_output}" >&2
  exit 1
fi
grep -Fq 'k8s-job-wait: job failed-job failed' <<<"${failed_output}"
if (( failed_elapsed_ms > 2000 )); then
  printf 'Expected failed-job to fail quickly, took %sms\n' "${failed_elapsed_ms}" >&2
  exit 1
fi

printf '%s\n' 'k8s-job-wait-test: verifying pending job still times out' >&2
pending_start_ns="$(date +%s%N)"
set +e
pending_output="$("${job_wait_path}" --namespace test --job-name pending-job --timeout 2s 2>&1)"
pending_status=$?
set -e
pending_elapsed_ms="$(( ($(date +%s%N) - pending_start_ns) / 1000000 ))"
if [[ "${pending_status}" -ne 124 ]]; then
  printf 'Expected pending-job to time out with 124, got %s\n' "${pending_status}" >&2
  printf '%s\n' "${pending_output}" >&2
  exit 1
fi
grep -Fq 'k8s-job-wait: timed out waiting for job pending-job' <<<"${pending_output}"
if (( pending_elapsed_ms < 1500 )) || (( pending_elapsed_ms > 5000 )); then
  printf 'Expected pending-job timeout around 2s, took %sms\n' "${pending_elapsed_ms}" >&2
  exit 1
fi

printf '%s\n' 'k8s-job-wait-test: helper semantics ok' >&2
