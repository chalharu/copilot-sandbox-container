#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper_path="${script_dir}/../containers/control-plane/skills/containerized-rust-ops/scripts/k8s-rust.sh"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/control-plane-k8s-rust-sccache-dist.XXXXXX")"

cleanup() {
  rm -rf "${workdir}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fake_bin="${workdir}/fake-bin"
mkdir -p "${fake_bin}"

cat > "${fake_bin}/control-plane-run" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

args_path="${CAPTURED_CONTROL_PLANE_RUN_ARGS:?}"
script_path="${CAPTURED_CONTROL_PLANE_RUN_SCRIPT:?}"
previous=""

: > "${args_path}"
: > "${script_path}"

for arg in "$@"; do
  printf '%s\0' "${arg}" >> "${args_path}"
  if [[ "${previous}" == "-c" ]]; then
    printf '%s' "${arg}" > "${script_path}"
  fi
  previous="${arg}"
done

[[ -s "${script_path}" ]] || {
  printf 'missing captured job script\n' >&2
  exit 1
}
EOF
chmod +x "${fake_bin}/control-plane-run"

runtime_env="${workdir}/runtime.env"
: > "${runtime_env}"

assert_contains() {
  local path="$1"
  local expected="$2"

  grep -Fq -- "${expected}" "${path}" || {
    printf 'Expected %s to contain: %s\n' "${path}" "${expected}" >&2
    exit 1
  }
}

assert_not_contains() {
  local path="$1"
  local unexpected="$2"

  if grep -Fq -- "${unexpected}" "${path}"; then
    printf 'Did not expect %s to contain: %s\n' "${path}" "${unexpected}" >&2
    exit 1
  fi
}

run_helper() {
  local script_capture_path="$1"
  shift

  env -i \
    PATH="${fake_bin}:${PATH}" \
    HOME="${HOME}" \
    USER="${USER:-copilot}" \
    K8S_RUST_BRANCH=test-branch \
    K8S_RUST_REMOTE_URL=https://example.com/chalharu/copilot-sandbox-container.git \
    CONTROL_PLANE_RUNTIME_ENV_FILE="${runtime_env}" \
    CONTROL_PLANE_K8S_NAMESPACE=control-plane-ns \
    CAPTURED_CONTROL_PLANE_RUN_ARGS="${workdir}/control-plane-run.args" \
    CAPTURED_CONTROL_PLANE_RUN_SCRIPT="${script_capture_path}" \
    "$@" \
    "${helper_path}" build >/dev/null
}

printf '%s\n' 'k8s-rust-sccache-dist-test: verifying local-cache fallback wiring' >&2
local_script="${workdir}/local-job-script.sh"
run_helper "${local_script}"
assert_contains "${local_script}" 'branch=test-branch'
assert_contains "${local_script}" 'repo_url=https://example.com/chalharu/copilot-sandbox-container.git'
assert_contains "${local_script}" 'sccache_dist_enabled=0'
assert_contains "${local_script}" 'sccache_dir='
assert_contains "${local_script}" "\${ephemeral_root}/sccache"
assert_not_contains "${local_script}" "\${cache_root}/sccache"
assert_contains "${local_script}" 'SCCACHE_CACHE_SIZE:-10G'

printf '%s\n' 'k8s-rust-sccache-dist-test: verifying dist-client wiring' >&2
client_token_path="${workdir}/client-token"
printf '%s\n' 'dist-client-token' > "${client_token_path}"
dist_script="${workdir}/dist-job-script.sh"
run_helper "${dist_script}" \
  SCCACHE_DIST_SCHEDULER_URL=http://sccache-dist.control-plane.svc.cluster.local:10600 \
  SCCACHE_DIST_CLIENT_TOKEN_FILE="${client_token_path}"
assert_contains "${dist_script}" 'sccache_dist_enabled=1'
assert_contains "${dist_script}" 'sccache_dist_scheduler_url=http://sccache-dist.control-plane.svc.cluster.local:10600'
assert_contains "${dist_script}" 'sccache_dist_client_token=dist-client-token'
assert_contains "${dist_script}" "\${ephemeral_root}/sccache"
assert_contains "${dist_script}" '[dist]'
assert_contains "${dist_script}" 'scheduler_url = '
assert_contains "${dist_script}" "\${sccache_dist_scheduler_url}"
assert_contains "${dist_script}" 'cache_dir = '
assert_contains "${dist_script}" "\${sccache_dist_client_cache}"
assert_contains "${dist_script}" 'toolchain_cache_size = '
assert_contains "${dist_script}" "\${sccache_dist_client_toolchain_cache_size}"
assert_contains "${dist_script}" 'token = '
assert_contains "${dist_script}" "\${sccache_dist_client_token}"
assert_contains "${dist_script}" 'export SCCACHE_CONF='

printf '%s\n' 'k8s-rust-sccache-dist-test: helper wiring ok' >&2
