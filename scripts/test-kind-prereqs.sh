#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workdir="$(mktemp -d)"
stderr_log="${workdir}/stderr.log"
kind_log="${workdir}/kind.log"

cleanup() {
  rm -rf "${workdir}"
}
trap cleanup EXIT

mkdir -p "${workdir}/bin"

cat > "${workdir}/bin/kind" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${TEST_KIND_LOG:?}"
if [[ "${1:-}" == "get" ]] && [[ "${2:-}" == "clusters" ]]; then
  exit 0
fi
printf 'unexpected fake kind invocation: %s\n' "$*" >&2
exit 1
EOF
chmod 755 "${workdir}/bin/kind"

cat > "${workdir}/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'unexpected fake docker invocation: %s\n' "$*" >&2
exit 1
EOF
chmod 755 "${workdir}/bin/docker"

cat > "${workdir}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'unexpected fake kubectl invocation: %s\n' "$*" >&2
exit 1
EOF
chmod 755 "${workdir}/bin/kubectl"

printf '%s\n' 'kind-prereqs-test: verifying missing host modules path skips Kind cluster creation' >&2

set +e
PATH="${workdir}/bin:${PATH}" \
TEST_KIND_LOG="${kind_log}" \
CONTROL_PLANE_KIND_REQUIRED_HOST_PATH="${workdir}/missing-modules" \
  "${script_dir}/test-kind.sh" fake/control-plane:test fake/execution-plane:test kind-prereq-cluster \
  > /dev/null 2>"${stderr_log}"
status=$?
set -e

if [[ "${status}" -ne 0 ]]; then
  cat "${stderr_log}" >&2
  exit 1
fi

grep -Fqx "get clusters" "${kind_log}"
grep -Fq "Skipping Kind cluster tests: required host path is unavailable: ${workdir}/missing-modules" "${stderr_log}"
