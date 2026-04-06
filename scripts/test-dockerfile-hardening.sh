#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

assert_file_contains() {
  local path="$1"
  local expected="$2"

  grep -Fq -- "${expected}" "${path}" || {
    printf 'Expected %s to contain: %s\n' "${path}" "${expected}" >&2
    exit 1
  }
}

assert_file_not_matches() {
  local path="$1"
  local unexpected_pattern="$2"

  if grep -Eq -- "${unexpected_pattern}" "${path}"; then
    printf 'Did not expect %s to match: %s\n' "${path}" "${unexpected_pattern}" >&2
    exit 1
  fi
}

assert_healthcheck_cmd() {
  local path="$1"
  local expected_cmd_line="$2"
  local healthcheck_line=""
  local cmd_line=""

  healthcheck_line="$(grep -nF "HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \\" "${path}" | head -n 1 | cut -d: -f1 || true)"
  cmd_line="$(grep -nF -- "${expected_cmd_line}" "${path}" | head -n 1 | cut -d: -f1 || true)"

  if [[ -z "${healthcheck_line}" ]] || [[ -z "${cmd_line}" ]] || [[ "${cmd_line}" -ne $((healthcheck_line + 1)) ]]; then
    printf 'Expected %s to contain HEALTHCHECK followed by: %s\n' "${path}" "${expected_cmd_line}" >&2
    exit 1
  fi
}

printf '%s\n' 'dockerfile-hardening-test: verifying non-root defaults and healthchecks' >&2

control_plane_dockerfile="${repo_root}/containers/control-plane/Dockerfile"
sccache_dockerfile="${repo_root}/containers/sccache/Dockerfile"
execution_plane_go_dockerfile="${repo_root}/containers/execution-plane-go/Dockerfile"
execution_plane_node_dockerfile="${repo_root}/containers/execution-plane-node/Dockerfile"
execution_plane_python_dockerfile="${repo_root}/containers/execution-plane-python/Dockerfile"
execution_plane_rust_dockerfile="${repo_root}/containers/execution-plane-rust/Dockerfile"
execution_plane_smoke_dockerfile="${repo_root}/containers/execution-plane-smoke/Dockerfile"

assert_file_contains "${control_plane_dockerfile}" "USER \${CONTROL_PLANE_USER}"
assert_file_not_matches "${control_plane_dockerfile}" '^USER root$'
assert_healthcheck_cmd "${control_plane_dockerfile}" '    CMD ["bash", "-lc", "node --version >/dev/null && gh --version >/dev/null && cargo --version >/dev/null && yamllint --version >/dev/null && test -x /usr/local/bin/control-plane-entrypoint && test -r /etc/ssh/sshd_config"]'

assert_healthcheck_cmd "${sccache_dockerfile}" '    CMD ["/usr/local/bin/sccache", "--version"]'
assert_healthcheck_cmd "${execution_plane_go_dockerfile}" '    CMD ["bash", "-lc", "go version >/dev/null && dlv version >/dev/null"]'
assert_healthcheck_cmd "${execution_plane_node_dockerfile}" '    CMD ["bash", "-lc", "node --version >/dev/null && npm --version >/dev/null && corepack --version >/dev/null"]'
assert_healthcheck_cmd "${execution_plane_python_dockerfile}" '    CMD ["bash", "-lc", "python --version >/dev/null && python -m venv --help >/dev/null"]'
assert_healthcheck_cmd "${execution_plane_rust_dockerfile}" '    CMD ["bash", "-lc", "rustc --version >/dev/null && cargo --version >/dev/null && /usr/local/cargo/bin/sccache --version >/dev/null"]'
assert_healthcheck_cmd "${execution_plane_smoke_dockerfile}" '    CMD ["/usr/local/bin/execution-plane-smoke", "report"]'

printf '%s\n' 'dockerfile-hardening-test: dockerfile hardening ok' >&2
