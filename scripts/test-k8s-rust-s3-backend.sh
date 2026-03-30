#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper_path="${script_dir}/../containers/control-plane/skills/containerized-rust-ops/scripts/k8s-rust.sh"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/control-plane-k8s-rust-s3-backend.XXXXXX")"

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

printf '%s\n' 'k8s-rust-s3-backend-test: verifying local-cache fallback wiring' >&2
local_script="${workdir}/local-job-script.sh"
run_helper "${local_script}"
assert_contains "${local_script}" 'branch=test-branch'
assert_contains "${local_script}" 'repo_url=https://example.com/chalharu/copilot-sandbox-container.git'
assert_contains "${local_script}" 'sccache_s3_enabled=0'
assert_contains "${local_script}" 'sccache_dir='
assert_contains "${local_script}" "\${ephemeral_root}/sccache"
assert_contains "${local_script}" 'src_root="${ephemeral_root}/src"'
assert_contains "${local_script}" 'cargo_home="${cache_root}/cargo"'
assert_not_contains "${local_script}" 'src_root=\"${ephemeral_root}/src\"'
assert_not_contains "${local_script}" "\${cache_root}/sccache"
assert_contains "${local_script}" 'SCCACHE_CACHE_SIZE:-10G'

printf '%s\n' 'k8s-rust-s3-backend-test: verifying S3 wiring' >&2
access_key_id_path="${workdir}/access-key-id"
secret_access_key_path="${workdir}/secret-access-key"
printf '%s\n' 'sample-access-key-id' > "${access_key_id_path}"
printf '%s\n' 'sample-secret-access-key' > "${secret_access_key_path}"
s3_script="${workdir}/s3-job-script.sh"
run_helper "${s3_script}" \
  SCCACHE_BUCKET=control-plane-sccache \
  SCCACHE_ENDPOINT=http://garage-s3.control-plane.svc.cluster.local:3900 \
  SCCACHE_REGION=garage \
  SCCACHE_S3_USE_SSL=false \
  SCCACHE_S3_KEY_PREFIX=sccache/ \
  AWS_ACCESS_KEY_ID_FILE="${access_key_id_path}" \
  AWS_SECRET_ACCESS_KEY_FILE="${secret_access_key_path}"
assert_contains "${s3_script}" 'sccache_s3_enabled=1'
assert_contains "${s3_script}" 'sccache_bucket=control-plane-sccache'
assert_contains "${s3_script}" 'sccache_endpoint=http://garage-s3.control-plane.svc.cluster.local:3900'
assert_contains "${s3_script}" 'sccache_region=garage'
assert_contains "${s3_script}" 'sccache_s3_use_ssl=false'
assert_contains "${s3_script}" 'sccache_s3_key_prefix=sccache/'
assert_contains "${s3_script}" 'aws_access_key_id=sample-access-key-id'
assert_contains "${s3_script}" 'aws_secret_access_key=sample-secret-access-key'
assert_contains "${s3_script}" "\${ephemeral_root}/sccache"
assert_contains "${s3_script}" 'if "$@"; then'
assert_not_contains "${s3_script}" 'if \"$@\"; then'
assert_contains "${s3_script}" '[cache.s3]'
assert_not_contains "${s3_script}" '[cache]'
assert_not_contains "${s3_script}" 'type = "s3"'
assert_contains "${s3_script}" 'bucket = '
assert_contains "${s3_script}" "\${sccache_bucket}"
assert_contains "${s3_script}" 'endpoint = '
assert_contains "${s3_script}" "\${sccache_endpoint}"
assert_contains "${s3_script}" 'region = '
assert_contains "${s3_script}" "\${sccache_region}"
assert_contains "${s3_script}" 'use_ssl = '
assert_contains "${s3_script}" "\${sccache_s3_use_ssl}"
assert_contains "${s3_script}" 'key_prefix = '
assert_contains "${s3_script}" "\${sccache_s3_key_prefix}"
assert_contains "${s3_script}" 'no_credentials = false'
assert_contains "${s3_script}" 'export AWS_ACCESS_KEY_ID='
assert_contains "${s3_script}" 'export AWS_SECRET_ACCESS_KEY='
assert_contains "${s3_script}" 'export SCCACHE_CONF='

printf '%s\n' 'k8s-rust-s3-backend-test: helper wiring ok' >&2
