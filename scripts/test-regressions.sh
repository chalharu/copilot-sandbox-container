#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
control_plane_image="${1:?usage: scripts/test-regressions.sh <control-plane-image>}"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-podman}"
workdir="$(mktemp -d)"
container_name="control-plane-regression-test"

cleanup() {
  "${container_bin}" rm -f "${container_name}" >/dev/null 2>&1 || true
  rm -rf "${workdir}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

require_command "${container_bin}"
require_command awk

printf '%s\n' 'regression-test: verifying broken overlay symlink startup handling' >&2
mkdir -p \
  "${workdir}/state/copilot/containers/overlay/storage/overlay/l" \
  "${workdir}/state/gh" \
  "${workdir}/state/ssh" \
  "${workdir}/state/ssh-host-keys" \
  "${workdir}/state/workspace"
ln -s /nonexistent/overlay-target "${workdir}/state/copilot/containers/overlay/storage/overlay/l/BROKENLINK"

set +e
broken_symlink_output="$("${container_bin}" run --rm \
  --name "${container_name}" \
  -e SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForRegressionOnly control-plane-regression' \
  -v "${workdir}/state/copilot:/home/copilot/.copilot" \
  -v "${workdir}/state/gh:/home/copilot/.config/gh" \
  -v "${workdir}/state/ssh:/home/copilot/.ssh" \
  -v "${workdir}/state/ssh-host-keys:/var/lib/control-plane/ssh-host-keys" \
  -v "${workdir}/state/workspace:/workspace" \
  "${control_plane_image}" \
  bash -lc 'printf "%s\n" startup-ok' 2>&1)"
broken_symlink_status=$?
set -e

if [[ "${broken_symlink_status}" -ne 0 ]]; then
  printf 'Expected control-plane startup to ignore broken overlay symlinks\n' >&2
  printf '%s\n' "${broken_symlink_output}" >&2
  exit 1
fi
if grep -q 'cannot dereference' <<<"${broken_symlink_output}"; then
  printf 'Unexpected chown dereference failure with broken overlay symlink\n' >&2
  printf '%s\n' "${broken_symlink_output}" >&2
  exit 1
fi
grep -qx 'startup-ok' <<<"${broken_symlink_output}"

printf '%s\n' 'regression-test: verifying bundled skill sync keeps reference docs readable' >&2
mkdir -p \
  "${workdir}/skill-state/copilot" \
  "${workdir}/skill-state/gh" \
  "${workdir}/skill-state/ssh" \
  "${workdir}/skill-state/ssh-host-keys" \
  "${workdir}/skill-state/workspace"

set +e
skill_output="$("${container_bin}" run --rm \
  --name "${container_name}" \
  -e SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForRegressionOnly control-plane-regression' \
  -v "${workdir}/skill-state/copilot:/home/copilot/.copilot" \
  -v "${workdir}/skill-state/gh:/home/copilot/.config/gh" \
  -v "${workdir}/skill-state/ssh:/home/copilot/.ssh" \
  -v "${workdir}/skill-state/ssh-host-keys:/var/lib/control-plane/ssh-host-keys" \
  -v "${workdir}/skill-state/workspace:/workspace" \
  "${control_plane_image}" \
  bash -lc "set -euo pipefail
su -s /bin/bash copilot -c 'set -euo pipefail
skill_root=\"\$HOME/.copilot/skills/control-plane-operations\"
test ! -L \"\$skill_root\"
test -r \"\$skill_root/SKILL.md\"
test -x \"\$skill_root/references\"
test -r \"\$skill_root/references/control-plane-run.md\"
test -r \"\$skill_root/references/skills.md\"
head -n 1 \"\$skill_root/references/skills.md\"'" 2>&1)"
skill_status=$?
set -e

if [[ "${skill_status}" -ne 0 ]]; then
  printf 'Expected bundled skill references to remain readable after startup sync\n' >&2
  printf '%s\n' "${skill_output}" >&2
  exit 1
fi
grep -qx '# Built-in skill reference' <<<"${skill_output}"

printf '%s\n' 'regression-test: verifying file-based DHI auth handling' >&2
mkdir -p "${workdir}/fake-bin"
cat > "${workdir}/fake-bin/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log_dir="${TEST_REGRESSION_LOG_DIR:?}"
state_file="${log_dir}/fake-image-exists"
case "${1:-}" in
  login)
    printf '%s\n' "$*" > "${log_dir}/login.args"
    cat > "${log_dir}/login.stdin"
    exit 0
    ;;
  image)
    if [[ "${2:-}" == "exists" ]]; then
      printf '%s\n' "$*" > "${log_dir}/image-exists.args"
      if [[ -f "${state_file}" ]]; then
        exit 0
      fi
      exit 1
    fi
    ;;
  pull)
    printf '%s\n' "$*" > "${log_dir}/pull.args"
    : > "${state_file}"
    exit 0
    ;;
esac
printf 'unexpected fake podman command: %s\n' "$*" >&2
exit 1
EOF
chmod +x "${workdir}/fake-bin/podman"

cat > "${workdir}/yamllint.Dockerfile" <<'EOF'
FROM dhi.io/python:3-alpine3.23-dev
EOF
printf '%s' 'test-user' > "${workdir}/dockerhub-username"
printf '%s' 'test-token' > "${workdir}/dockerhub-token"

PATH="${workdir}/fake-bin:${PATH}" \
  TEST_REGRESSION_LOG_DIR="${workdir}" \
  CONTROL_PLANE_YAMLLINT_DOCKERFILE="${workdir}/yamllint.Dockerfile" \
  DOCKERHUB_USERNAME_FILE="${workdir}/dockerhub-username" \
  DOCKERHUB_TOKEN_FILE="${workdir}/dockerhub-token" \
  "${script_dir}/prepare-dhi-images.sh"

grep -qx 'login dhi.io -u test-user --password-stdin' "${workdir}/login.args"
grep -qx 'test-token' "${workdir}/login.stdin"
grep -qx 'image exists dhi.io/python:3-alpine3.23-dev' "${workdir}/image-exists.args"
grep -qx 'pull dhi.io/python:3-alpine3.23-dev' "${workdir}/pull.args"

printf '%s\n' 'regression-test: verifying published ports skip default host network injection' >&2
cat > "${workdir}/fake-bin/podman-run-publish" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "${TEST_REGRESSION_LOG_DIR:?}/published.args"
exit 0
EOF
chmod +x "${workdir}/fake-bin/podman-run-publish"

CONTROL_PLANE_RUNTIME_ENV_FILE=/dev/null \
  TEST_REGRESSION_LOG_DIR="${workdir}" \
  CONTROL_PLANE_PODMAN_BIN="${workdir}/fake-bin/podman-run-publish" \
  CONTROL_PLANE_PODMAN_DEFAULT_CGROUPS=disabled \
  CONTROL_PLANE_PODMAN_DEFAULT_NETWORK=host \
  CONTROL_PLANE_PODMAN_RUN_DETACH_WORKAROUND=never \
  "${script_dir}/../containers/control-plane/bin/control-plane-podman" \
  run --rm --name published-probe -e FOO=bar -v /tmp:/tmp -p 127.0.0.1:2222:2222 quay.io/example/test:latest true

grep -qx -- '--cgroups=disabled' "${workdir}/published.args"
if grep -q -- '--network=host' "${workdir}/published.args"; then
  printf 'Expected published-port podman run to avoid default host network injection\n' >&2
  cat "${workdir}/published.args" >&2
  exit 1
fi

printf '%s\n' 'regression-test: verifying default build isolation rewrites build args' >&2
cat > "${workdir}/fake-bin/podman-build-env" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'BUILDAH_ISOLATION=%s\n' "${BUILDAH_ISOLATION:-}" > "${TEST_REGRESSION_LOG_DIR:?}/build.env"
printf '%s\n' "$@" > "${TEST_REGRESSION_LOG_DIR:?}/build.args"
exit 0
EOF
chmod +x "${workdir}/fake-bin/podman-build-env"

CONTROL_PLANE_RUNTIME_ENV_FILE=/dev/null \
  TEST_REGRESSION_LOG_DIR="${workdir}" \
  CONTROL_PLANE_PODMAN_BIN="${workdir}/fake-bin/podman-build-env" \
  CONTROL_PLANE_PODMAN_BUILD_ISOLATION=chroot \
  "${script_dir}/../containers/control-plane/bin/control-plane-podman" \
  build -t quay.io/example/test:latest /tmp

grep -qx 'BUILDAH_ISOLATION=' "${workdir}/build.env"
if ! grep -q -- '--isolation=chroot' "${workdir}/build.args"; then
  printf 'Expected wrapper to inject --isolation=chroot for podman build\n' >&2
  cat "${workdir}/build.args" >&2
  exit 1
fi

printf '%s\n' 'regression-test: verifying explicit build isolation is not duplicated after valued flags' >&2
CONTROL_PLANE_RUNTIME_ENV_FILE=/dev/null \
  TEST_REGRESSION_LOG_DIR="${workdir}" \
  CONTROL_PLANE_PODMAN_BIN="${workdir}/fake-bin/podman-build-env" \
  CONTROL_PLANE_PODMAN_BUILD_ISOLATION=chroot \
  "${script_dir}/../containers/control-plane/bin/control-plane-podman" \
  build -t quay.io/example/test:latest --isolation=oci /tmp

if ! grep -qx -- '--isolation=oci' "${workdir}/build.args"; then
  printf 'Expected wrapper to preserve explicit build isolation setting\n' >&2
  cat "${workdir}/build.args" >&2
  exit 1
fi
if grep -q -- '--isolation=chroot' "${workdir}/build.args"; then
  printf 'Expected wrapper to avoid injecting duplicate build isolation after valued flags\n' >&2
  cat "${workdir}/build.args" >&2
  exit 1
fi

printf '%s\n' 'regression-test: verifying interactive podman run returns promptly' >&2
cat > "${workdir}/fake-bin/podman-run-interactive" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "run" ]] && [[ "${2:-}" == "-it" ]]; then
  {
    sleep 5
  } >&2 &
  printf '%s\n' 'interactive-ok'
  exit 0
fi
printf 'unexpected fake podman command: %s\n' "$*" >&2
exit 1
EOF
chmod +x "${workdir}/fake-bin/podman-run-interactive"

set +e
interactive_output="$(
  CONTROL_PLANE_RUNTIME_ENV_FILE=/dev/null \
    CONTROL_PLANE_PODMAN_DEFAULT_CGROUPS='' \
    CONTROL_PLANE_PODMAN_DEFAULT_NETWORK='' \
    CONTROL_PLANE_PODMAN_BIN="${workdir}/fake-bin/podman-run-interactive" \
    timeout 2s "${script_dir}/../containers/control-plane/bin/control-plane-podman" run -it quay.io/example/test:latest 2>&1
)"
interactive_status=$?
set -e

if [[ "${interactive_status}" -ne 0 ]]; then
  printf 'Expected interactive control-plane-podman run to return promptly\n' >&2
  printf '%s\n' "${interactive_output}" >&2
  exit 1
fi
grep -q 'interactive-ok' <<<"${interactive_output}"

printf '%s\n' 'regression-test: verifying detached podman run propagates failures' >&2
cat > "${workdir}/fake-bin/podman-run-fail" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "run" ]] && [[ "${2:-}" == "-d" ]]; then
  printf '%s\n' 'time="2026-03-17T00:00:00Z" level=error msg="running `/usr/bin/newuidmap 123 0 1000 1 1 100000 65536`: newuidmap: write to uid_map failed: Operation not permitted\n"' >&2
  printf '%s\n' 'Error: cannot set up namespace using "/usr/bin/newuidmap": exit status 1' >&2
  exit 125
fi
printf 'unexpected fake podman command: %s\n' "$*" >&2
exit 1
EOF
chmod +x "${workdir}/fake-bin/podman-run-fail"

set +e
detached_failure_output="$(
  CONTROL_PLANE_RUNTIME_ENV_FILE=/dev/null \
    CONTROL_PLANE_PODMAN_DEFAULT_CGROUPS='' \
    CONTROL_PLANE_PODMAN_DEFAULT_NETWORK='' \
    CONTROL_PLANE_PODMAN_BIN="${workdir}/fake-bin/podman-run-fail" \
    CONTROL_PLANE_PODMAN_RUN_DETACH_WORKAROUND=always \
    "${script_dir}/../containers/control-plane/bin/control-plane-podman" run --rm quay.io/example/test:latest 2>&1
)"
detached_failure_status=$?
set -e

if [[ "${detached_failure_status}" -eq 0 ]]; then
  printf 'Expected detached control-plane-podman run failure to return non-zero\n' >&2
  printf '%s\n' "${detached_failure_output}" >&2
  exit 1
fi
grep -q 'rootless Podman is blocked by the outer runtime' <<<"${detached_failure_output}"

printf '%s\n' 'regression-test: targeted regressions ok' >&2
