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

assert_path_absent() {
  local path="$1"

  if [[ -e "${path}" ]]; then
    printf 'Did not expect %s to exist\n' "${path}" >&2
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
execution_plane_smoke_dir="${repo_root}/containers/execution-plane-smoke"
legacy_yamllint_installer="${repo_root}/containers/control-plane/build/install-yamllint-wheel.py"
legacy_execution_plane_go_dockerfile="${repo_root}/containers/execution-plane-go/Dockerfile"
legacy_execution_plane_node_dockerfile="${repo_root}/containers/execution-plane-node/Dockerfile"
legacy_execution_plane_python_dockerfile="${repo_root}/containers/execution-plane-python/Dockerfile"
legacy_execution_plane_rust_dockerfile="${repo_root}/containers/execution-plane-rust/Dockerfile"
legacy_yamllint_dockerfile="${repo_root}/containers/yamllint/Dockerfile"

assert_file_contains "${control_plane_dockerfile}" "USER \${CONTROL_PLANE_USER}"
assert_file_not_matches "${control_plane_dockerfile}" '^USER root$'
assert_healthcheck_cmd "${control_plane_dockerfile}" '    CMD ["bash", "-lc", "node --version >/dev/null && cargo --version >/dev/null && git --version >/dev/null && yamllint --version >/dev/null && control-plane-exec-api --help >/dev/null && test -x /usr/local/bin/control-plane-web && test -x /usr/local/bin/control-plane-entrypoint && test -r /etc/ssh/sshd_config"]'
assert_file_contains "${control_plane_dockerfile}" 'YAMLLINT_VIRTUAL_ENV=/opt/yamllint'
assert_file_contains "${control_plane_dockerfile}" 'python3-venv'
assert_file_contains "${control_plane_dockerfile}" "python3 -m venv \"\${YAMLLINT_VIRTUAL_ENV}\""
assert_file_contains "${control_plane_dockerfile}" "        git \\"
assert_file_contains "${control_plane_dockerfile}" '/tmp/yamllint-requirements.txt'
assert_file_contains "${control_plane_dockerfile}" '--only-binary=:all: --require-hashes -r /tmp/yamllint-requirements.txt'
assert_file_contains "${control_plane_dockerfile}" 'LANG=C.UTF-8'
assert_file_contains "${control_plane_dockerfile}" 'LC_CTYPE=C.UTF-8'
assert_file_contains "${control_plane_dockerfile}" "        locales \\"
assert_file_contains "${control_plane_dockerfile}" "        vim \\"
assert_file_contains "${control_plane_dockerfile}" 'locale-gen'
assert_file_contains "${control_plane_dockerfile}" 'localedef -i ja_JP -f UTF-8 ja_JP.UTF8'
assert_file_not_matches "${control_plane_dockerfile}" 'install-yamllint-wheel\.py|python3-pathspec|python3-yaml|YAMLLINT_WHEEL_SHA256'
assert_file_not_matches "${control_plane_dockerfile}" 'cpulimit|gcc|libc6-dev|libssl-dev|ncurses-term|pkg-config'

assert_path_absent "${execution_plane_smoke_dir}"
assert_path_absent "${legacy_yamllint_installer}"
assert_path_absent "${legacy_execution_plane_go_dockerfile}"
assert_path_absent "${legacy_execution_plane_node_dockerfile}"
assert_path_absent "${legacy_execution_plane_python_dockerfile}"
assert_path_absent "${legacy_execution_plane_rust_dockerfile}"
assert_path_absent "${legacy_yamllint_dockerfile}"

printf '%s\n' 'dockerfile-hardening-test: dockerfile hardening ok' >&2
