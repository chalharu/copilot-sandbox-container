#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  k8s-rust.sh <fmt-check|check|clippy|build|test>
  k8s-rust.sh -- <command> [args...]

Run Rust commands in a control-plane Kubernetes job with persistent cargo and
rustup caches under /workspace/cache. The clone, target directory, temp files,
and local sccache state always live on ephemeral storage under /var/tmp so the
shared workspace PVC only carries the minimum reusable Rust toolchain data.
When the runtime exposes an S3-backed sccache endpoint, this helper writes an
SCCACHE_CONF so shared cache objects stay in the object store instead.
USAGE
}

die() {
  printf 'k8s-rust.sh: %s\n' "$*" >&2
  exit 64
}

slugify() {
  printf '%s' "$1" | tr '/:@' '---' | tr -cs '[:alnum:]._-' '-'
}

read_secret_file() {
  local path="$1"
  local value

  [[ -f "${path}" ]] || die "secret file not found: ${path}"
  value="$(tr -d '\r\n' < "${path}")"
  [[ -n "${value}" ]] || die "secret file must not be empty: ${path}"
  printf '%s' "${value}"
}

[[ $# -gt 0 ]] || {
  usage
  exit 64
}

case "$1" in
  fmt-check)
    shift
    [[ $# -eq 0 ]] || die "fmt-check does not accept extra arguments"
    cmd=(cargo fmt --all --check)
    ;;
  check)
    shift
    [[ $# -eq 0 ]] || die "check does not accept extra arguments"
    cmd=(cargo check --workspace --all-targets)
    ;;
  clippy)
    shift
    [[ $# -eq 0 ]] || die "clippy does not accept extra arguments"
    cmd=(cargo clippy --workspace --all-targets -- -D warnings)
    ;;
  build)
    shift
    [[ $# -eq 0 ]] || die "build does not accept extra arguments"
    cmd=(cargo build --workspace)
    ;;
  test)
    shift
    [[ $# -eq 0 ]] || die "test does not accept extra arguments"
    cmd=(cargo test --workspace --all-targets)
    ;;
  --)
    shift
    [[ $# -gt 0 ]] || die "-- must be followed by a command"
    cmd=("$@")
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    die "unknown preset: $1"
    ;;
esac

command -v control-plane-run >/dev/null 2>&1 || die "control-plane-run is required"

runtime_env="${CONTROL_PLANE_RUNTIME_ENV_FILE:-${HOME:-/home/copilot}/.config/control-plane/runtime.env}"
[[ -f "${runtime_env}" ]] || die "runtime env file not found: ${runtime_env}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
control_plane_tmp_root="${CONTROL_PLANE_TMP_ROOT:-/var/tmp/control-plane}"
outer_tmp_dir="${TMPDIR:-${control_plane_tmp_root}/tmp-$(id -u)}"
mkdir -p "${outer_tmp_dir}"
chmod 700 "${outer_tmp_dir}" 2>/dev/null || true
export TMPDIR="${outer_tmp_dir}"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "${repo_root}" ]] || die "run this script from inside the repository"
install_sccache_script_path="${script_dir}/install-sccache.sh"
[[ -f "${install_sccache_script_path}" ]] || die "install-sccache.sh not found: ${install_sccache_script_path}"
install_sccache_script="$(cat "${install_sccache_script_path}")"
install_cargo_llvm_cov_script_path="${script_dir}/install-cargo-llvm-cov.sh"
[[ -f "${install_cargo_llvm_cov_script_path}" ]] || die "install-cargo-llvm-cov.sh not found: ${install_cargo_llvm_cov_script_path}"
install_cargo_llvm_cov_script="$(cat "${install_cargo_llvm_cov_script_path}")"

repo_name="$(basename "${repo_root}")"
branch="${K8S_RUST_BRANCH:-$(git branch --show-current)}"
[[ -n "${branch}" ]] || die "K8S_RUST_BRANCH is required when HEAD is detached"

repo_url="${K8S_RUST_REMOTE_URL:-$(git -C "${repo_root}" remote get-url origin)}"
[[ -n "${repo_url}" ]] || die "could not determine origin URL"
namespace="${CONTROL_PLANE_K8S_NAMESPACE:-}"
[[ -n "${namespace}" ]] || die "CONTROL_PLANE_K8S_NAMESPACE must be set"
sccache_version="${SCCACHE_VERSION:-0.14.0}"
sccache_release_base_url="${SCCACHE_RELEASE_BASE_URL:-https://github.com/mozilla/sccache/releases/download}"
sccache_bootstrap_jobs="${SCCACHE_BOOTSTRAP_JOBS:-1}"
sccache_bucket="${SCCACHE_BUCKET:-}"
sccache_endpoint="${SCCACHE_ENDPOINT:-}"
sccache_region="${SCCACHE_REGION:-garage}"
sccache_s3_use_ssl="${SCCACHE_S3_USE_SSL:-false}"
sccache_s3_key_prefix="${SCCACHE_S3_KEY_PREFIX:-sccache/}"
aws_access_key_id_file="${AWS_ACCESS_KEY_ID_FILE:-}"
aws_secret_access_key_file="${AWS_SECRET_ACCESS_KEY_FILE:-}"
aws_access_key_id="${AWS_ACCESS_KEY_ID:-}"
aws_secret_access_key="${AWS_SECRET_ACCESS_KEY:-}"
sccache_s3_requested=0
sccache_s3_enabled=0
cargo_llvm_cov_version="${CARGO_LLVM_COV_VERSION:-0.8.5}"
cargo_llvm_cov_release_base_url="${CARGO_LLVM_COV_RELEASE_BASE_URL:-https://github.com/taiki-e/cargo-llvm-cov/releases}"
enable_cargo_llvm_cov=0
if [[ "${#cmd[@]}" -ge 2 && "${cmd[0]}" == "cargo" && "${cmd[1]}" == "llvm-cov" ]]; then
  enable_cargo_llvm_cov=1
fi

if [[ -n "${SCCACHE_BUCKET:-}" || -n "${SCCACHE_ENDPOINT:-}" || -n "${SCCACHE_REGION:-}" || -n "${SCCACHE_S3_USE_SSL:-}" || -n "${SCCACHE_S3_KEY_PREFIX:-}" || -n "${aws_access_key_id_file}" || -n "${aws_secret_access_key_file}" ]]; then
  sccache_s3_requested=1
fi

case "${sccache_s3_use_ssl}" in
  true|false)
    ;;
  *)
    die "SCCACHE_S3_USE_SSL must be true or false"
    ;;
esac

if [[ -n "${aws_access_key_id_file}" && -n "${aws_access_key_id}" ]]; then
  die "set either AWS_ACCESS_KEY_ID or AWS_ACCESS_KEY_ID_FILE, not both"
fi
if [[ -n "${aws_secret_access_key_file}" && -n "${aws_secret_access_key}" ]]; then
  die "set either AWS_SECRET_ACCESS_KEY or AWS_SECRET_ACCESS_KEY_FILE, not both"
fi
if [[ -n "${aws_access_key_id_file}" ]]; then
  aws_access_key_id="$(read_secret_file "${aws_access_key_id_file}")"
fi
if [[ -n "${aws_secret_access_key_file}" ]]; then
  aws_secret_access_key="$(read_secret_file "${aws_secret_access_key_file}")"
fi

if [[ "${sccache_s3_requested}" -eq 1 ]]; then
  [[ -n "${sccache_bucket}" ]] || die "SCCACHE_BUCKET is required when S3-backed sccache is configured"
  [[ -n "${sccache_endpoint}" ]] || die "SCCACHE_ENDPOINT is required when S3-backed sccache is configured"
  [[ -n "${aws_access_key_id}" ]] || die "AWS_ACCESS_KEY_ID or AWS_ACCESS_KEY_ID_FILE is required when S3-backed sccache is configured"
  [[ -n "${aws_secret_access_key}" ]] || die "AWS_SECRET_ACCESS_KEY or AWS_SECRET_ACCESS_KEY_FILE is required when S3-backed sccache is configured"
  sccache_s3_enabled=1
fi

branch_key="$(slugify "${branch}")"
repo_key="$(slugify "${repo_name}")"
branch_key="${branch_key#-}"
branch_key="${branch_key%-}"
repo_key="${repo_key#-}"
repo_key="${repo_key%-}"
[[ -n "${branch_key}" ]] || branch_key=branch
[[ -n "${repo_key}" ]] || repo_key=repo

image="${RUST_CONTAINER_IMAGE:-docker.io/rust:1.94.0-bookworm}"
timeout="${K8S_RUST_TIMEOUT:-7200s}"

tmpenv="$(mktemp "${TMPDIR%/}/k8s-rust-runtime-env.XXXXXX")"
trap 'rm -f "${tmpenv}"' EXIT
cp "${runtime_env}" "${tmpenv}"
tmpenv_updated="$(mktemp "${TMPDIR%/}/k8s-rust-runtime-env-updated.XXXXXX")"
trap 'rm -f "${tmpenv}" "${tmpenv_updated}"' EXIT
sed 's/^CONTROL_PLANE_JOB_SERVICE_ACCOUNT=.*/CONTROL_PLANE_JOB_SERVICE_ACCOUNT=/' "${tmpenv}" > "${tmpenv_updated}"
mv "${tmpenv_updated}" "${tmpenv}"

repo_url_q="$(printf '%q' "${repo_url}")"
branch_q="$(printf '%q' "${branch}")"
repo_key_q="$(printf '%q' "${repo_key}")"
branch_key_q="$(printf '%q' "${branch_key}")"
sccache_version_q="$(printf '%q' "${sccache_version}")"
sccache_release_base_url_q="$(printf '%q' "${sccache_release_base_url}")"
sccache_bootstrap_jobs_q="$(printf '%q' "${sccache_bootstrap_jobs}")"
sccache_bucket_q="$(printf '%q' "${sccache_bucket}")"
sccache_endpoint_q="$(printf '%q' "${sccache_endpoint}")"
sccache_region_q="$(printf '%q' "${sccache_region}")"
sccache_s3_use_ssl_q="$(printf '%q' "${sccache_s3_use_ssl}")"
sccache_s3_key_prefix_q="$(printf '%q' "${sccache_s3_key_prefix}")"
aws_access_key_id_q="$(printf '%q' "${aws_access_key_id}")"
aws_secret_access_key_q="$(printf '%q' "${aws_secret_access_key}")"
sccache_s3_enabled_q="$(printf '%q' "${sccache_s3_enabled}")"
cargo_llvm_cov_version_q="$(printf '%q' "${cargo_llvm_cov_version}")"
cargo_llvm_cov_release_base_url_q="$(printf '%q' "${cargo_llvm_cov_release_base_url}")"
enable_cargo_llvm_cov_q="$(printf '%q' "${enable_cargo_llvm_cov}")"

job_script="$(cat <<EOF2
set -eu
repo_url=${repo_url_q}
branch=${branch_q}
repo_key=${repo_key_q}
branch_key=${branch_key_q}
sccache_version=${sccache_version_q}
sccache_release_base_url=${sccache_release_base_url_q}
sccache_bootstrap_jobs=${sccache_bootstrap_jobs_q}
sccache_bucket=${sccache_bucket_q}
sccache_endpoint=${sccache_endpoint_q}
sccache_region=${sccache_region_q}
sccache_s3_use_ssl=${sccache_s3_use_ssl_q}
sccache_s3_key_prefix=${sccache_s3_key_prefix_q}
aws_access_key_id=${aws_access_key_id_q}
aws_secret_access_key=${aws_secret_access_key_q}
sccache_s3_enabled=${sccache_s3_enabled_q}
cargo_llvm_cov_version=${cargo_llvm_cov_version_q}
cargo_llvm_cov_release_base_url=${cargo_llvm_cov_release_base_url_q}
enable_cargo_llvm_cov=${enable_cargo_llvm_cov_q}
cache_root=/workspace/cache/\${repo_key}/\${branch_key}
ephemeral_root=/var/tmp/containerized-rust/\${repo_key}/\${branch_key}
src_root=\"\${ephemeral_root}/src\"
tmp_dir=\"\${ephemeral_root}/tmp\"
cargo_home=\"\${cache_root}/cargo\"
rustup_home=\"\${cache_root}/rustup\"
sccache_dir=\"\${ephemeral_root}/sccache\"
sccache_conf=\"\${tmp_dir}/sccache-client.toml\"
target_dir=\"\${ephemeral_root}/target\"
mkdir -p \"\${tmp_dir}\" \"\${cargo_home}\" \"\${rustup_home}\" \"\${sccache_dir}\" \"\${target_dir}\"
export TMPDIR=\"\${tmp_dir}\"
if [ ! -x \"\${cargo_home}/bin/cargo\" ]; then
  cp -a /usr/local/cargo/. \"\${cargo_home}/\"
fi
if [ ! -d \"\${rustup_home}/toolchains\" ]; then
  cp -a /usr/local/rustup/. \"\${rustup_home}/\"
fi
export CARGO_HOME=\"\${cargo_home}\"
export RUSTUP_HOME=\"\${rustup_home}\"
export PATH=\"\${CARGO_HOME}/bin:\${PATH}\"
export CARGO_TARGET_DIR=\"\${target_dir}\"
export SCCACHE_DIR=\"\${sccache_dir}\"
if [ \"\${sccache_s3_enabled}\" = \"1\" ]; then
  cat > \"\${sccache_conf}\" <<EOF3
[cache]
type = "s3"

[cache.s3]
bucket = \"\${sccache_bucket}\"
endpoint = \"\${sccache_endpoint}\"
region = \"\${sccache_region}\"
use_ssl = \${sccache_s3_use_ssl}
key_prefix = \"\${sccache_s3_key_prefix}\"
EOF3
  export AWS_ACCESS_KEY_ID=\"\${aws_access_key_id}\"
  export AWS_SECRET_ACCESS_KEY=\"\${aws_secret_access_key}\"
  export SCCACHE_CONF=\"\${sccache_conf}\"
else
  export SCCACHE_CACHE_SIZE=\"\${SCCACHE_CACHE_SIZE:-10G}\"
fi
export CARGO_INCREMENTAL=0
export CARGO_TERM_PROGRESS_WHEN=never
rm -rf \"\${src_root}\"
git clone --branch \"\${branch}\" --depth 1 \"\${repo_url}\" \"\${src_root}\"
cd \"\${src_root}\"
cat > \"\${tmp_dir}/install-sccache.sh\" <<'INSTALL_SCCACHE'
${install_sccache_script}
INSTALL_SCCACHE
chmod 0755 \"\${tmp_dir}/install-sccache.sh\"
cat > \"\${tmp_dir}/install-cargo-llvm-cov.sh\" <<'INSTALL_CARGO_LLVM_COV'
${install_cargo_llvm_cov_script}
INSTALL_CARGO_LLVM_COV
chmod 0755 \"\${tmp_dir}/install-cargo-llvm-cov.sh\"
rustfmt --version >/dev/null 2>&1 || rustup component add rustfmt >\"\${tmp_dir}/rustfmt.log\" 2>&1
rustfmt --version >/dev/null 2>&1 || { cat \"\${tmp_dir}/rustfmt.log\" >&2; exit 1; }
cargo clippy --version >/dev/null 2>&1 || rustup component add clippy >\"\${tmp_dir}/clippy.log\" 2>&1
cargo clippy --version >/dev/null 2>&1 || { cat \"\${tmp_dir}/clippy.log\" >&2; exit 1; }
export SCCACHE_VERSION=\"\${sccache_version}\"
export SCCACHE_RELEASE_BASE_URL=\"\${sccache_release_base_url}\"
export SCCACHE_BOOTSTRAP_JOBS=\"\${sccache_bootstrap_jobs}\"
sh \"\${tmp_dir}/install-sccache.sh\"
if [ \"\${enable_cargo_llvm_cov}\" = \"1\" ]; then
  export CARGO_LLVM_COV_VERSION=\"\${cargo_llvm_cov_version}\"
  export CARGO_LLVM_COV_RELEASE_BASE_URL=\"\${cargo_llvm_cov_release_base_url}\"
  sh \"\${tmp_dir}/install-cargo-llvm-cov.sh\"
  rustup component list --installed | grep -Eq \"^llvm-tools\" || rustup component add llvm-tools-preview >\"\${tmp_dir}/llvm-tools.log\" 2>&1
  rustup component list --installed | grep -Eq \"^llvm-tools\" || { cat \"\${tmp_dir}/llvm-tools.log\" >&2; exit 1; }
fi
export RUSTC_WRAPPER=\"\${CARGO_HOME}/bin/sccache\"
if \"\$@\"; then
  status=0
else
  status=\$?
fi
sccache --show-stats || true
exit \"\${status}\"
EOF2
)"

CONTROL_PLANE_RUNTIME_ENV_FILE="${tmpenv}" \
control-plane-run \
  --mode auto \
  --execution-hint long \
  --namespace "${namespace}" \
  --timeout "${timeout}" \
  --image "${image}" \
  -- sh -c "${job_script}" sh "${cmd[@]}"
