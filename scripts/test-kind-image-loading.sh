#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workdir="$(mktemp -d)"

cleanup() {
  rm -rf "${workdir}"
}

trap cleanup EXIT

mkdir -p "${workdir}/bin"

cat > "${workdir}/bin/kind" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${TEST_KIND_KIND_LOG:?}"
EOF
chmod +x "${workdir}/bin/kind"

cat > "${workdir}/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${TEST_KIND_DOCKER_LOG:?}"
if [[ "${1:-}" != "save" ]]; then
  printf 'unexpected fake docker command: %s\n' "$*" >&2
  exit 1
fi
shift
output_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      output_path="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "${output_path}" ]] || {
printf 'fake docker did not receive --output\n' >&2
  exit 1
}
: > "${output_path}"
EOF
chmod +x "${workdir}/bin/docker"

cat > "${workdir}/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${TEST_KIND_SUDO_LOG:?}"
[[ "${1:-}" == "-n" ]] || {
  printf 'fake sudo expected -n\n' >&2
  exit 1
}
shift
[[ "${1:-}" == "env" ]] || {
  printf 'fake sudo expected env\n' >&2
  exit 1
}
shift
while [[ $# -gt 0 ]] && [[ "$1" == *=* ]]; do
  export "$1"
  shift
done
exec "$@"
EOF
chmod +x "${workdir}/bin/sudo"

kind_log="${workdir}/kind.log"
docker_log="${workdir}/docker.log"
sudo_log="${workdir}/sudo.log"
archive_path="${workdir}/control-plane-images.tar"
: > "${archive_path}"

printf '%s\n' 'kind-image-loading-test: verifying direct archive import' >&2
PATH="${workdir}/bin:${PATH}" \
TEST_KIND_KIND_LOG="${kind_log}" \
TEST_KIND_DOCKER_LOG="${docker_log}" \
TEST_KIND_SUDO_LOG="${sudo_log}" \
  "${script_dir}/load-kind-images.sh" \
  --cluster-name control-plane-ci \
  --image-archive "${archive_path}"

grep -Fqx "load image-archive ${archive_path} --name control-plane-ci" "${kind_log}"
test ! -e "${docker_log}"
test ! -e "${sudo_log}"

: > "${kind_log}"
rm -f "${docker_log}" "${sudo_log}"

printf '%s\n' 'kind-image-loading-test: verifying fallback image export with sudo-aware kind load' >&2
PATH="${workdir}/bin:${PATH}" \
CONTROL_PLANE_KIND_USE_SUDO=1 \
KIND_EXPERIMENTAL_PROVIDER=docker \
TEST_KIND_KIND_LOG="${kind_log}" \
TEST_KIND_DOCKER_LOG="${docker_log}" \
TEST_KIND_SUDO_LOG="${sudo_log}" \
  "${script_dir}/load-kind-images.sh" \
  --cluster-name control-plane-ci \
  --container-bin docker \
  --image localhost/control-plane:test \
  --image localhost/execution-plane-smoke:test

expected_control_archive="$(printf '%s' 'localhost/control-plane:test' | tr '/:' '__')"
expected_execution_archive="$(printf '%s' 'localhost/execution-plane-smoke:test' | tr '/:' '__')"
control_archive_path="$(sed -n "s|^load image-archive \\(.*/${expected_control_archive}\\.tar\\) --name control-plane-ci$|\\1|p" "${kind_log}" | head -n 1)"
execution_archive_path="$(sed -n "s|^load image-archive \\(.*/${expected_execution_archive}\\.tar\\) --name control-plane-ci$|\\1|p" "${kind_log}" | head -n 1)"

grep -Eq "^save --output .*/${expected_control_archive}\.tar localhost/control-plane:test$" "${docker_log}"
grep -Eq "^save --output .*/${expected_execution_archive}\.tar localhost/execution-plane-smoke:test$" "${docker_log}"
grep -Eq "^load image-archive .*/${expected_control_archive}\.tar --name control-plane-ci$" "${kind_log}"
grep -Eq "^load image-archive .*/${expected_execution_archive}\.tar --name control-plane-ci$" "${kind_log}"
grep -Fqx -- "-n env KIND_EXPERIMENTAL_PROVIDER=docker kind load image-archive ${control_archive_path} --name control-plane-ci" "${sudo_log}"
grep -Fqx -- "-n env KIND_EXPERIMENTAL_PROVIDER=docker kind load image-archive ${execution_archive_path} --name control-plane-ci" "${sudo_log}"
