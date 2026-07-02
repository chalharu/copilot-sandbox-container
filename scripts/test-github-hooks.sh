#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
# shellcheck source=scripts/lib-biome-hook-image.sh
source "${script_dir}/lib-biome-hook-image.sh"
control_plane_image="${1:-}"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-docker}"
control_plane_run_user=(--user 0:0)
host_uid="$(id -u)"
host_gid="$(id -g)"
# renovate: datasource=docker depName=docker.io/library/rust versioning=docker
rust_test_image="${CONTROL_PLANE_RUST_TEST_IMAGE:-docker.io/library/rust:1.96.1-bookworm@sha256:a339861ae23e9abb272cea45dfafde21760d2ce6577a70f8a926153677902663}"

cleanup_runtime_tool_target_dir() {
  [[ -n "${runtime_tool_target_dir:-}" ]] || return 0
  [[ -e "${runtime_tool_target_dir}" ]] || return 0

  rm -rf "${runtime_tool_target_dir}" 2>/dev/null && return 0

  if command -v "${container_bin}" >/dev/null 2>&1; then
    "${container_bin}" run --rm \
      "${control_plane_run_user[@]}" \
      -v "${runtime_tool_target_dir}:/var/tmp/control-plane/cargo-target" \
      --entrypoint sh \
      "${rust_test_image}" \
      -c 'find /var/tmp/control-plane/cargo-target -mindepth 1 -exec rm -rf -- {} +' \
      >/dev/null 2>&1 || true
  fi

  rm -rf "${runtime_tool_target_dir}" 2>/dev/null || true
}

runtime_tool_target_root="${CONTROL_PLANE_TMP_ROOT:-/var/tmp/control-plane}"
mkdir -p "${runtime_tool_target_root}"
runtime_tool_target_dir="$(mktemp -d "${runtime_tool_target_root}/github-hooks-target.XXXXXX")"
trap cleanup_runtime_tool_target_dir EXIT

command -v node >/dev/null 2>&1 || {
  printf 'test-github-hooks.sh: node is required\n' >&2
  exit 1
}

command -v "${container_bin}" >/dev/null 2>&1 || {
  printf 'test-github-hooks.sh: %s is required\n' "${container_bin}" >&2
  exit 1
}

[[ ! -e .github/hooks ]] || {
  printf 'test-github-hooks.sh: .github/hooks should not exist anymore\n' >&2
  exit 1
}

# The control-plane image build already runs runtime-tools cargo tests in the
# runtime-tools-builder stage. Build only the local binary that the git hook
# node tests expect, then keep this regression focused on hook wiring.
printf '%s\n' 'test-github-hooks.sh: building runtime-tool binary for git hook tests' >&2
"${container_bin}" run --rm \
  "${control_plane_run_user[@]}" \
  -i \
  -e CARGO_TARGET_DIR=/var/tmp/control-plane/cargo-target \
  -v "${runtime_tool_target_dir}:/var/tmp/control-plane/cargo-target" \
  -v "${PWD}:/workspace" \
  -w /workspace/containers/control-plane \
  --entrypoint sh \
  "${rust_test_image}" \
  -c "cargo build --locked -p control-plane-runtime-tools --bin control-plane-runtime-tool; build_status=\$?; chown -R ${host_uid}:${host_gid} /var/tmp/control-plane/cargo-target || true; exit \$build_status"

printf '%s\n' 'test-github-hooks.sh: verifying remaining git hook tests' >&2
export CONTROL_PLANE_RUNTIME_TOOL_BIN="${runtime_tool_target_dir}/debug/control-plane-runtime-tool"
node --test \
  containers/control-plane/hooks/git/main.test.mjs

printf '%s\n' 'test-github-hooks.sh: verifying control-plane-biome wrapper' >&2
(
  set -euo pipefail

  workdir="$(mktemp -d)"
  trap 'rm -rf "${workdir}"' EXIT

  repo_dir="${workdir}/repo"
  bin_dir="${workdir}/bin"
  remote_log="${workdir}/remote.log"
  local_log="${workdir}/local.log"
  npx_log="${workdir}/npx.log"
  mkdir -p "${repo_dir}/src" "${bin_dir}"

  printf 'node_modules/\n' > "${repo_dir}/.gitignore"
  printf '{\n  "files": {\n    "ignoreUnknown": true,\n    "includes": ["**/*.ts"]\n  }\n}\n' > "${repo_dir}/biome.jsonc"
  printf 'export const value = 1;\n' > "${repo_dir}/src/index.ts"

  cat > "${bin_dir}/control-plane-run" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "${TEST_WRAPPER_LOG}"
exit "${TEST_REMOTE_STATUS:-0}"
EOF
  chmod 755 "${bin_dir}/control-plane-run"

  (
    cd "${repo_dir}"
    TEST_WRAPPER_LOG="${remote_log}" \
      PATH="${bin_dir}:/usr/bin:/bin" \
      CONTROL_PLANE_BIOME_HOOK_IMAGE="${biome_hook_image}" \
      CONTROL_PLANE_JOB_INPUT_MOUNT_PATH='/job-inputs' \
      "${repo_root}/containers/control-plane/bin/control-plane-biome" check --write src/index.ts
  )

  grep -Fqx -- '--image' "${remote_log}"
  grep -Fqx "${biome_hook_image}" "${remote_log}"
  grep -Fqx -- '--input-mount-path' "${remote_log}"
  grep -Fqx '/job-inputs' "${remote_log}"
  grep -Fqx -- '--mount-file' "${remote_log}"
  grep -Fqx "${repo_dir}/src/index.ts:src/index.ts" "${remote_log}"
  grep -Fqx "${repo_dir}/biome.jsonc:biome.jsonc" "${remote_log}"
  grep -Fqx "${repo_dir}/.gitignore:.gitignore" "${remote_log}"
  grep -Fqx 'cd /job-inputs && exec /usr/local/bin/biome check --write src/index.ts' "${remote_log}"

  cat > "${bin_dir}/biome" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'biome %s\n' "$*" > "${TEST_WRAPPER_LOG}"
EOF
  chmod 755 "${bin_dir}/biome"

  (
    cd "${repo_dir}"
    TEST_WRAPPER_LOG="${local_log}" \
      PATH="${bin_dir}:/usr/bin:/bin" \
      CONTROL_PLANE_BIOME_HOOK_IMAGE='' \
      "${repo_root}/containers/control-plane/bin/control-plane-biome" check --write src/index.ts
  )
  grep -Fqx 'biome check --write src/index.ts' "${local_log}"

  remote_fallback_stderr="${workdir}/remote-fallback.stderr"
  : > "${local_log}"
  (
    cd "${repo_dir}"
    TEST_REMOTE_STATUS=75 \
      TEST_WRAPPER_LOG="${local_log}" \
      PATH="${bin_dir}:/usr/bin:/bin" \
      CONTROL_PLANE_BIOME_HOOK_IMAGE="${biome_hook_image}" \
      CONTROL_PLANE_JOB_INPUT_MOUNT_PATH='/job-inputs' \
      "${repo_root}/containers/control-plane/bin/control-plane-biome" check --write src/index.ts
  ) > /dev/null 2> "${remote_fallback_stderr}"
  grep -Fqx 'biome check --write src/index.ts' "${local_log}"
  grep -Fq 'control-plane-biome: remote execution is unavailable (exit 75); falling back to local execution' "${remote_fallback_stderr}"

  remote_missing_stderr="${workdir}/remote-missing.stderr"
  : > "${local_log}"
  (
    cd "${repo_dir}"
    TEST_REMOTE_STATUS=127 \
      TEST_WRAPPER_LOG="${local_log}" \
      PATH="${bin_dir}:/usr/bin:/bin" \
      CONTROL_PLANE_BIOME_HOOK_IMAGE="${biome_hook_image}" \
      CONTROL_PLANE_JOB_INPUT_MOUNT_PATH='/job-inputs' \
      "${repo_root}/containers/control-plane/bin/control-plane-biome" check --write src/index.ts
  ) > /dev/null 2> "${remote_missing_stderr}"
  grep -Fqx 'biome check --write src/index.ts' "${local_log}"
  grep -Fq 'control-plane-biome: remote execution is unavailable (exit 127); falling back to local execution' "${remote_missing_stderr}"

  : > "${local_log}"
  remote_failure_stderr="${workdir}/remote-failure.stderr"
  set +e
  (
    cd "${repo_dir}"
    TEST_REMOTE_STATUS=9 \
      TEST_WRAPPER_LOG="${remote_log}" \
      PATH="${bin_dir}:/usr/bin:/bin" \
      CONTROL_PLANE_BIOME_HOOK_IMAGE="${biome_hook_image}" \
      CONTROL_PLANE_JOB_INPUT_MOUNT_PATH='/job-inputs' \
      "${repo_root}/containers/control-plane/bin/control-plane-biome" check --write src/index.ts
  ) > /dev/null 2> "${remote_failure_stderr}"
  remote_status=$?
  set -e
  [[ "${remote_status}" -eq 9 ]]
  [[ ! -s "${local_log}" ]]
  if grep -Fq 'falling back to local execution' "${remote_failure_stderr}"; then
    exit 1
  fi

  : > "${local_log}"
  remote_config_stderr="${workdir}/remote-config.stderr"
  set +e
  (
    cd "${repo_dir}"
    TEST_REMOTE_STATUS=64 \
      TEST_WRAPPER_LOG="${remote_log}" \
      PATH="${bin_dir}:/usr/bin:/bin" \
      CONTROL_PLANE_BIOME_HOOK_IMAGE="${biome_hook_image}" \
      CONTROL_PLANE_JOB_INPUT_MOUNT_PATH='/job-inputs' \
      "${repo_root}/containers/control-plane/bin/control-plane-biome" check --write src/index.ts
  ) > /dev/null 2> "${remote_config_stderr}"
  remote_status=$?
  set -e
  [[ "${remote_status}" -eq 64 ]]
  [[ ! -s "${local_log}" ]]
  if grep -Fq 'falling back to local execution' "${remote_config_stderr}"; then
    exit 1
  fi

  rm -f "${bin_dir}/biome"
  cat > "${bin_dir}/npx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'npx %s\n' "$*" > "${TEST_WRAPPER_LOG}"
EOF
  chmod 755 "${bin_dir}/npx"

  (
    cd "${repo_dir}"
    TEST_WRAPPER_LOG="${npx_log}" \
      PATH="${bin_dir}:/usr/bin:/bin" \
      CONTROL_PLANE_BIOME_HOOK_IMAGE='' \
      "${repo_root}/containers/control-plane/bin/control-plane-biome" check --write src/index.ts
  )
  grep -Fqx 'npx --yes @biomejs/biome check --write src/index.ts' "${npx_log}"

  rm -f "${bin_dir}/npx"
  restricted_local_bin="${workdir}/restricted-local-bin"
  mkdir -p "${restricted_local_bin}"
  ln -s "$(command -v bash)" "${restricted_local_bin}/bash"
  missing_local_stderr="${workdir}/missing-local.stderr"
  (
    cd "${repo_dir}"
    PATH="${restricted_local_bin}" \
      CONTROL_PLANE_BIOME_HOOK_IMAGE='' \
      "${repo_root}/containers/control-plane/bin/control-plane-biome" check --write src/index.ts
  ) > /dev/null 2> "${missing_local_stderr}"
  grep -Fq 'control-plane-biome: skipping hook step because local biome tooling is unavailable; install biome or npx, or set CONTROL_PLANE_BIOME_HOOK_IMAGE' "${missing_local_stderr}"
)

printf '%s\n' 'test-github-hooks.sh: verifying Rust hook remote fallback' >&2
(
  set -euo pipefail

  workdir="$(mktemp -d)"
  trap 'rm -rf "${workdir}"' EXIT

  repo_dir="${workdir}/repo"
  bin_dir="${workdir}/bin"
  cargo_log="${workdir}/cargo.log"
  remote_log="${workdir}/remote.log"
  mkdir -p "${repo_dir}/src" "${bin_dir}"
  git -C "${repo_dir}" init -q

  cat > "${repo_dir}/Cargo.toml" <<'EOF'
[package]
name = "test-root-crate"
version = "0.1.0"
edition = "2024"
EOF
  cat > "${repo_dir}/src/main.rs" <<'EOF'
fn main() {}
EOF

  cat > "${bin_dir}/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s\n' "${PWD}" "$*" >> "${TEST_CARGO_LOG}"
EOF
  chmod 755 "${bin_dir}/cargo"

  cat > "${bin_dir}/control-plane-run" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "${TEST_WRAPPER_LOG}"
if [[ -n "${TEST_REMOTE_STDOUT:-}" ]]; then
  printf '%b' "${TEST_REMOTE_STDOUT}"
fi
if [[ -n "${TEST_REMOTE_STDERR:-}" ]]; then
  printf '%b' "${TEST_REMOTE_STDERR}" >&2
fi
exit "${TEST_REMOTE_STATUS:-0}"
EOF
  chmod 755 "${bin_dir}/control-plane-run"

  remote_fallback_stderr="${workdir}/remote-fallback.stderr"
  (
    cd "${repo_dir}"
    TEST_CARGO_LOG="${cargo_log}" \
      TEST_WRAPPER_LOG="${remote_log}" \
      TEST_REMOTE_STATUS=75 \
      PATH="${bin_dir}:/usr/bin:/bin" \
      CONTROL_PLANE_RUNTIME_ENV_FILE=/dev/null \
      CONTROL_PLANE_RUST_HOOK_IMAGE="${biome_hook_image}" \
      CONTROL_PLANE_JOB_TRANSFER_IMAGE='' \
      bash "${repo_root}/containers/control-plane/hooks/postToolUse/control-plane-rust.sh" \
        fmt src/main.rs
  ) > /dev/null 2> "${remote_fallback_stderr}"
  grep -Fqx "${repo_dir}|fmt --all" "${cargo_log}"
  grep -Fq 'control-plane-rust: remote execution is unavailable (exit 75); falling back to local execution' "${remote_fallback_stderr}"

  remote_missing_stderr="${workdir}/remote-missing.stderr"
  : > "${cargo_log}"
  (
    cd "${repo_dir}"
    TEST_CARGO_LOG="${cargo_log}" \
      TEST_WRAPPER_LOG="${remote_log}" \
      TEST_REMOTE_STATUS=127 \
      PATH="${bin_dir}:/usr/bin:/bin" \
      CONTROL_PLANE_RUNTIME_ENV_FILE=/dev/null \
      CONTROL_PLANE_RUST_HOOK_IMAGE="${biome_hook_image}" \
      CONTROL_PLANE_JOB_TRANSFER_IMAGE='' \
      bash "${repo_root}/containers/control-plane/hooks/postToolUse/control-plane-rust.sh" \
        fmt src/main.rs
  ) > /dev/null 2> "${remote_missing_stderr}"
  grep -Fqx "${repo_dir}|fmt --all" "${cargo_log}"
  grep -Fq 'control-plane-rust: remote execution is unavailable (exit 127); falling back to local execution' "${remote_missing_stderr}"

  : > "${cargo_log}"
  remote_override_stdout="${workdir}/remote-override.stdout"
  remote_override_stderr="${workdir}/remote-override.stderr"
  (
    cd "${repo_dir}"
    TEST_CARGO_LOG="${cargo_log}" \
      TEST_WRAPPER_LOG="${remote_log}" \
      TEST_REMOTE_STATUS=0 \
      PATH="${bin_dir}:/usr/bin:/bin" \
      CONTROL_PLANE_RUNTIME_ENV_FILE=/dev/null \
      CONTROL_PLANE_WORKSPACE_MOUNT_PATH='/workspace/core' \
      CONTROL_PLANE_RUST_HOOK_IMAGE="${biome_hook_image}" \
      CONTROL_PLANE_JOB_TRANSFER_IMAGE='' \
      bash "${repo_root}/containers/control-plane/hooks/postToolUse/control-plane-rust.sh" \
        fmt src/main.rs
  ) > "${remote_override_stdout}" 2> "${remote_override_stderr}"
  grep -Fq 'cd /workspace/core && cargo fmt --all' "${remote_log}"
  [[ ! -s "${cargo_log}" ]]
  grep -Fqx 'control-plane-rust: .' "${remote_override_stderr}"
  if grep -Fq 'falling back to local execution' "${remote_override_stderr}"; then
    exit 1
  fi

  : > "${cargo_log}"
  remote_failure_stderr="${workdir}/remote-failure.stderr"
  set +e
  (
    cd "${repo_dir}"
    TEST_CARGO_LOG="${cargo_log}" \
      TEST_WRAPPER_LOG="${remote_log}" \
      TEST_REMOTE_STATUS=9 \
      PATH="${bin_dir}:/usr/bin:/bin" \
      CONTROL_PLANE_RUNTIME_ENV_FILE=/dev/null \
      CONTROL_PLANE_RUST_HOOK_IMAGE="${biome_hook_image}" \
      CONTROL_PLANE_JOB_TRANSFER_IMAGE='' \
      bash "${repo_root}/containers/control-plane/hooks/postToolUse/control-plane-rust.sh" \
        fmt src/main.rs
  ) > /dev/null 2> "${remote_failure_stderr}"
  remote_status=$?
  set -e
  [[ "${remote_status}" -eq 9 ]]
  [[ ! -s "${cargo_log}" ]]
  if grep -Fq 'falling back to local execution' "${remote_failure_stderr}"; then
    exit 1
  fi

  : > "${cargo_log}"
  remote_config_stderr="${workdir}/remote-config.stderr"
  set +e
  (
    cd "${repo_dir}"
    TEST_CARGO_LOG="${cargo_log}" \
      TEST_WRAPPER_LOG="${remote_log}" \
      TEST_REMOTE_STATUS=64 \
      PATH="${bin_dir}:/usr/bin:/bin" \
      CONTROL_PLANE_RUNTIME_ENV_FILE=/dev/null \
      CONTROL_PLANE_RUST_HOOK_IMAGE="${biome_hook_image}" \
      CONTROL_PLANE_JOB_TRANSFER_IMAGE='' \
      bash "${repo_root}/containers/control-plane/hooks/postToolUse/control-plane-rust.sh" \
        fmt src/main.rs
  ) > /dev/null 2> "${remote_config_stderr}"
  remote_status=$?
  set -e
  [[ "${remote_status}" -eq 64 ]]
  [[ ! -s "${cargo_log}" ]]
  if grep -Fq 'falling back to local execution' "${remote_config_stderr}"; then
    exit 1
  fi

  restricted_bin="${workdir}/restricted-bin"
  mkdir -p "${restricted_bin}"
  ln -s "$(command -v bash)" "${restricted_bin}/bash"
  ln -s /usr/bin/dirname "${restricted_bin}/dirname"
  ln -s /usr/bin/find "${restricted_bin}/find"
  ln -s /usr/bin/grep "${restricted_bin}/grep"
  ln -s /usr/bin/sort "${restricted_bin}/sort"
  missing_local_stderr="${workdir}/missing-local.stderr"
  (
    cd "${repo_dir}"
    PATH="${restricted_bin}" \
      CONTROL_PLANE_RUNTIME_ENV_FILE=/dev/null \
      CONTROL_PLANE_RUST_HOOK_IMAGE='' \
      CONTROL_PLANE_JOB_TRANSFER_IMAGE='' \
      bash "${repo_root}/containers/control-plane/hooks/postToolUse/control-plane-rust.sh" \
        clippy-fix src/main.rs
  ) > /dev/null 2> "${missing_local_stderr}"
  grep -Fq 'control-plane-rust.sh: skipping hook step because local clippy-fix needs cc and pkg-config; set CONTROL_PLANE_RUST_HOOK_IMAGE to run heavy cargo work in a separate image' "${missing_local_stderr}"
)

printf '%s\n' 'test-github-hooks.sh: verifying k8s-job-run preserves failed pod exit codes' >&2
(
  set -euo pipefail

  workdir="$(mktemp -d)"
  trap 'rm -rf "${workdir}"' EXIT

  bin_dir="${workdir}/bin"
  stdout_log="${workdir}/stdout.log"
  stderr_log="${workdir}/stderr.log"
  mkdir -p "${bin_dir}"

  ln -s "$(command -v bash)" "${bin_dir}/bash"
  ln -s "$(command -v tr)" "${bin_dir}/tr"

  cat > "${bin_dir}/k8s-job-start" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'failed-job\n'
EOF
  chmod 755 "${bin_dir}/k8s-job-start"

  cat > "${bin_dir}/k8s-job-wait" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 1
EOF
  chmod 755 "${bin_dir}/k8s-job-wait"

  cat > "${bin_dir}/k8s-job-pod" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'failed-pod\n'
EOF
  chmod 755 "${bin_dir}/k8s-job-pod"

  cat > "${bin_dir}/k8s-job-logs" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'job logs\n'
EOF
  chmod 755 "${bin_dir}/k8s-job-logs"

  cat > "${bin_dir}/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "get" && "$2" == "pod" ]]; then
  printf '127'
  exit 0
fi
if [[ "$1" == "delete" && "$2" == "job" ]]; then
  exit 0
fi
printf 'unexpected kubectl invocation: %s\n' "$*" >&2
exit 1
EOF
  chmod 755 "${bin_dir}/kubectl"

  set +e
  PATH="${bin_dir}" \
    "${repo_root}/containers/control-plane/bin/k8s-job-run" \
      --namespace demo \
      --image example.invalid/control-plane:latest \
      -- printf 'ignored\n' \
      > "${stdout_log}" 2> "${stderr_log}"
  status=$?
  set -e

  [[ "${status}" -eq 127 ]]
  grep -Fqx 'job logs' "${stdout_log}"
  if grep -Fq 'k8s-job-run:' "${stderr_log}"; then
    exit 1
  fi

  cat > "${bin_dir}/k8s-job-logs" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'job logs\n'
exit 1
EOF
  chmod 755 "${bin_dir}/k8s-job-logs"
  stdout_log_fail="${workdir}/stdout-log-fail.log"
  stderr_log_fail="${workdir}/stderr-log-fail.log"
  set +e
  PATH="${bin_dir}" \
    "${repo_root}/containers/control-plane/bin/k8s-job-run" \
      --namespace demo \
      --image example.invalid/control-plane:latest \
      -- printf 'ignored\n' \
      > "${stdout_log_fail}" 2> "${stderr_log_fail}"
  status=$?
  set -e
  [[ "${status}" -eq 127 ]]
  grep -Fqx 'job logs' "${stdout_log_fail}"
  ! grep -Fq 'k8s-job-run:' "${stderr_log_fail}"
)

printf '%s\n' 'test-github-hooks.sh: verifying Rust hook Cargo.lock routing' >&2
(
  set -euo pipefail

  workdir="$(mktemp -d)"
  trap 'rm -rf "${workdir}"' EXIT

  repo_dir="${workdir}/repo"
  bin_dir="${workdir}/bin"
  cargo_log="${workdir}/cargo.log"
  mkdir -p "${repo_dir}/containers/control-plane/exec-api" "${bin_dir}"
  git -C "${repo_dir}" init -q

  cat > "${repo_dir}/containers/control-plane/Cargo.toml" <<'EOF'
[workspace]
members = ["exec-api"]
resolver = "3"
EOF
  cat > "${repo_dir}/containers/control-plane/exec-api/Cargo.toml" <<'EOF'
[package]
name = "test-exec-api"
version = "0.1.0"
edition = "2024"
EOF
  touch "${repo_dir}/containers/control-plane/Cargo.lock"

  cat > "${bin_dir}/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s\n' "${PWD}" "$*" >> "${TEST_CARGO_LOG}"
EOF
  chmod 755 "${bin_dir}/cargo"

  (
    cd "${repo_dir}"
    TEST_CARGO_LOG="${cargo_log}" \
      PATH="${bin_dir}:/usr/bin:/bin" \
      CONTROL_PLANE_RUNTIME_ENV_FILE=/dev/null \
      CONTROL_PLANE_RUST_HOOK_IMAGE='' \
      CONTROL_PLANE_JOB_TRANSFER_IMAGE='' \
      bash "${repo_root}/containers/control-plane/hooks/postToolUse/control-plane-rust.sh" \
        fmt containers/control-plane/Cargo.lock
  )

  grep -Fqx "${repo_dir}/containers/control-plane|fmt --all" "${cargo_log}"
)

printf '%s\n' 'test-github-hooks.sh: verifying Rust hook workspace member routing' >&2
(
  set -euo pipefail

  workdir="$(mktemp -d)"
  trap 'rm -rf "${workdir}"' EXIT

  repo_dir="${workdir}/repo"
  bin_dir="${workdir}/bin"
  cargo_log="${workdir}/cargo.log"
  mkdir -p "${repo_dir}/containers/control-plane/exec-api/src" "${bin_dir}"
  git -C "${repo_dir}" init -q

  cat > "${repo_dir}/containers/control-plane/Cargo.toml" <<'EOF'
[workspace]
members = ["exec-api"]
resolver = "3"
EOF
  cat > "${repo_dir}/containers/control-plane/exec-api/Cargo.toml" <<'EOF'
[package]
name = "test-exec-api"
version = "0.1.0"
edition = "2024"
EOF
  cat > "${repo_dir}/containers/control-plane/exec-api/src/lib.rs" <<'EOF'
pub fn value() -> i32 { 1 }
EOF

  cat > "${bin_dir}/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s\n' "${PWD}" "$*" >> "${TEST_CARGO_LOG}"
EOF
  chmod 755 "${bin_dir}/cargo"

  (
    cd "${repo_dir}"
    TEST_CARGO_LOG="${cargo_log}" \
      PATH="${bin_dir}:/usr/bin:/bin" \
      CONTROL_PLANE_RUNTIME_ENV_FILE=/dev/null \
      CONTROL_PLANE_RUST_HOOK_IMAGE='' \
      CONTROL_PLANE_JOB_TRANSFER_IMAGE='' \
      bash "${repo_root}/containers/control-plane/hooks/postToolUse/control-plane-rust.sh" \
        fmt containers/control-plane/exec-api/src/lib.rs
  )

  grep -Fqx "${repo_dir}/containers/control-plane/exec-api|fmt --all" "${cargo_log}"
)

printf '%s\n' 'test-github-hooks.sh: verifying generic Rust hook routing' >&2
(
  set -euo pipefail

  workdir="$(mktemp -d)"
  trap 'rm -rf "${workdir}"' EXIT

  repo_dir="${workdir}/repo"
  bin_dir="${workdir}/bin"
  cargo_log="${workdir}/cargo.log"
  mkdir -p "${repo_dir}/src" "${bin_dir}"
  git -C "${repo_dir}" init -q

  cat > "${repo_dir}/Cargo.toml" <<'EOF'
[package]
name = "test-root-crate"
version = "0.1.0"
edition = "2024"
EOF
  cat > "${repo_dir}/Cargo.lock" <<'EOF'
# synthetic lockfile for routing coverage
EOF
  cat > "${repo_dir}/src/main.rs" <<'EOF'
fn main() {}
EOF

  cat > "${bin_dir}/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s\n' "${PWD}" "$*" >> "${TEST_CARGO_LOG}"
EOF
  chmod 755 "${bin_dir}/cargo"

  (
    cd "${repo_dir}"
    TEST_CARGO_LOG="${cargo_log}" \
      PATH="${bin_dir}:/usr/bin:/bin" \
      CONTROL_PLANE_RUNTIME_ENV_FILE=/dev/null \
      CONTROL_PLANE_RUST_HOOK_IMAGE='' \
      CONTROL_PLANE_JOB_TRANSFER_IMAGE='' \
      bash "${repo_root}/containers/control-plane/hooks/postToolUse/control-plane-rust.sh" \
        fmt src/main.rs Cargo.lock Cargo.toml
  )

  line_count="$(wc -l < "${cargo_log}")"
  [[ "${line_count}" -eq 1 ]]
  grep -Fqx "${repo_dir}|fmt --all" "${cargo_log}"
)

printf '%s\n' 'test-github-hooks.sh: verifying Rust hook no-op outside Cargo repos' >&2
(
  set -euo pipefail

  workdir="$(mktemp -d)"
  trap 'rm -rf "${workdir}"' EXIT

  repo_dir="${workdir}/repo"
  mkdir -p "${repo_dir}/src"
  git -C "${repo_dir}" init -q

  cat > "${repo_dir}/src/main.rs" <<'EOF'
fn main() {}
EOF

  stderr_log="${workdir}/stderr.log"
  (
    cd "${repo_dir}"
    PATH="/usr/bin:/bin" \
      CONTROL_PLANE_RUNTIME_ENV_FILE=/dev/null \
      CONTROL_PLANE_RUST_HOOK_IMAGE='' \
      CONTROL_PLANE_JOB_TRANSFER_IMAGE='' \
      bash "${repo_root}/containers/control-plane/hooks/postToolUse/control-plane-rust.sh" \
        fmt src/main.rs
  ) > /dev/null 2> "${stderr_log}"

  grep -Fqx 'control-plane-rust: no affected Rust crates' "${stderr_log}"
  ! grep -Fq 'no Cargo.toml files found' "${stderr_log}"
)

printf '%s\n' 'test-github-hooks.sh: verifying Rust hook no-op without paths outside Cargo repos' >&2
(
  set -euo pipefail

  workdir="$(mktemp -d)"
  trap 'rm -rf "${workdir}"' EXIT

  repo_dir="${workdir}/repo"
  mkdir -p "${repo_dir}"
  git -C "${repo_dir}" init -q

  stderr_log="${workdir}/stderr.log"
  (
    cd "${repo_dir}"
    PATH="/usr/bin:/bin" \
      CONTROL_PLANE_RUNTIME_ENV_FILE=/dev/null \
      CONTROL_PLANE_RUST_HOOK_IMAGE='' \
      CONTROL_PLANE_JOB_TRANSFER_IMAGE='' \
      bash "${repo_root}/containers/control-plane/hooks/postToolUse/control-plane-rust.sh" \
        fmt
  ) > /dev/null 2> "${stderr_log}"

  grep -Fqx 'control-plane-rust: no affected Rust crates' "${stderr_log}"
  ! grep -Fq 'control-plane-rust: .' "${stderr_log}"
)

if [[ -z "${control_plane_image}" ]]; then
  exit 0
fi

printf '%s\n' 'test-github-hooks.sh: verifying bundled hooks in control-plane image' >&2
"${container_bin}" run --rm \
  "${control_plane_run_user[@]}" \
  -i \
  "${control_plane_image}" \
  bash -l -se <<'EOF'
set -euo pipefail
test -f /usr/local/share/control-plane/hooks/hooks.json
test -x /usr/local/share/control-plane/hooks/audit/main
test -x /usr/local/share/control-plane/hooks/preToolUse/main
test -x /usr/local/share/control-plane/hooks/preToolUse/exec-forward
test -f /usr/local/share/control-plane/hooks/preToolUse/deny-rules.yaml
test -f /usr/local/lib/libcontrol_plane_exec_policy.so
test -x /usr/local/share/control-plane/hooks/git/pre-commit
test -x /usr/local/share/control-plane/hooks/git/pre-push
test -f /usr/local/share/control-plane/hooks/git/lib/common.sh
test -x /usr/local/share/control-plane/hooks/postToolUse/main
test -x /usr/local/share/control-plane/hooks/postToolUse/control-plane-rust.sh
test -f /usr/local/share/control-plane/hooks/postToolUse/linters.json
test -x /usr/local/bin/control-plane-biome
test -x /usr/local/share/control-plane/hooks/sessionEnd/cleanup
test -x /usr/local/bin/control-plane-exec-api
test -x /usr/local/bin/control-plane-exec-api-launcher
test -x /usr/local/bin/control-plane-runtime-tool
test -x /usr/local/bin/control-plane-session-exec
test -x /usr/local/bin/ruff
test -x /usr/local/bin/hadolint
test "${COPILOT_HOME}" = /var/lib/control-plane/managed-runtime/copilot-home
test "${GIT_CONFIG_GLOBAL}" = /var/lib/control-plane/managed-runtime/gitconfig
test "$(stat -c '%a %U %G' /home/copilot)" = "1770 root copilot"
test "$(stat -c '%a %U %G' /home/copilot/.copilot)" = "1770 root copilot"
test -L "${COPILOT_HOME}"
test "$(readlink "${COPILOT_HOME}")" = /home/copilot/.copilot
test -L /home/copilot/.copilot/hooks
test "$(readlink /home/copilot/.copilot/hooks)" = /usr/local/share/control-plane/hooks
test -L /home/copilot/.gitconfig
test "$(readlink /home/copilot/.gitconfig)" = "${GIT_CONFIG_GLOBAL}"
test "$(stat -Lc '%a %U %G' "${COPILOT_HOME}")" = "1770 root copilot"
test "$(stat -c '%a %U %G' "${COPILOT_HOME}/hooks/hooks.json")" = "644 root root"
test "$(stat -c '%a %U %G' "${GIT_CONFIG_GLOBAL}")" = "644 root root"
test -f /home/copilot/.copilot/hooks/hooks.json
test -x /home/copilot/.copilot/hooks/audit/main
test -x /home/copilot/.copilot/hooks/preToolUse/main
test -x /home/copilot/.copilot/hooks/preToolUse/exec-forward
test -f /home/copilot/.copilot/hooks/preToolUse/deny-rules.yaml
test -f /usr/local/lib/libcontrol_plane_exec_policy.so
test -x /home/copilot/.copilot/hooks/git/pre-commit
test -x /home/copilot/.copilot/hooks/git/pre-push
test -f /home/copilot/.copilot/hooks/git/lib/common.sh
test -x /home/copilot/.copilot/hooks/postToolUse/main
test -x /home/copilot/.copilot/hooks/postToolUse/control-plane-rust.sh
test -f /home/copilot/.copilot/hooks/postToolUse/linters.json
test -x /home/copilot/.copilot/hooks/sessionEnd/cleanup
grep -Fqx '    hooksPath = /usr/local/share/control-plane/hooks/git' "${GIT_CONFIG_GLOBAL}"
test "$(grep -Fc '    helper = !gh auth git-credential' "${GIT_CONFIG_GLOBAL}")" -eq 2
grep -Fq "COPILOT_HOME" /home/copilot/.copilot/hooks/hooks.json
grep -Fq "hooks/audit/main" /home/copilot/.copilot/hooks/hooks.json
grep -Fq "hooks/preToolUse/main" /home/copilot/.copilot/hooks/hooks.json
grep -Fq "hooks/preToolUse/exec-forward" /home/copilot/.copilot/hooks/hooks.json
grep -Fq "hooks/postToolUse/main" /home/copilot/.copilot/hooks/hooks.json
grep -Fq '"command": "control-plane-biome"' /usr/local/share/control-plane/hooks/postToolUse/linters.json
grep -Fq "hooks/postToolUse/control-plane-rust.sh" /usr/local/share/control-plane/hooks/postToolUse/linters.json
grep -Fq "hooks/sessionEnd/cleanup" /home/copilot/.copilot/hooks/hooks.json
! grep -Fq "powershell" /home/copilot/.copilot/hooks/hooks.json
! grep -Fq "auditAnalysis" /home/copilot/.copilot/hooks/hooks.json
! grep -Fq ".github/hooks" /home/copilot/.copilot/hooks/hooks.json
if su -s /bin/bash copilot -lc "printf tamper >> \"${GIT_CONFIG_GLOBAL}\"" 2>/dev/null; then
  printf "%s\n" "Expected managed git config to be read-only for the copilot user" >&2
  exit 1
fi
if su -s /bin/bash copilot -lc "printf tamper >> \"${COPILOT_HOME}/hooks/hooks.json\"" 2>/dev/null; then
  printf "%s\n" "Expected managed Copilot hooks to be read-only for the copilot user" >&2
  exit 1
fi
if su -s /bin/bash copilot -lc 'ln -sfn /tmp/evil-hooks ~/.copilot/hooks' 2>/dev/null; then
  printf "%s\n" "Expected ~/.copilot/hooks to resist symlink replacement for the copilot user" >&2
  exit 1
fi
test "$(readlink /home/copilot/.copilot/hooks)" = /usr/local/share/control-plane/hooks
su -s /bin/bash copilot -lc 'touch ~/.copilot/user-owned-state && rm ~/.copilot/user-owned-state'
EOF
