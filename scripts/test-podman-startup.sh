#!/usr/bin/env bash
set -euo pipefail

control_plane_image="${1:?usage: scripts/test-podman-startup.sh <control-plane-image>}"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-podman}"
entrypoint_override="${CONTROL_PLANE_TEST_ENTRYPOINT_FILE:-}"
workdir="$(mktemp -d)"

all_startup_caps=(
  --cap-add AUDIT_WRITE
  --cap-add CHOWN
  --cap-add DAC_OVERRIDE
  --cap-add FOWNER
  --cap-add KILL
  --cap-add MKNOD
  --cap-add NET_ADMIN
  --cap-add SETFCAP
  --cap-add SETGID
  --cap-add SETPCAP
  --cap-add SETUID
  --cap-add SYS_ADMIN
  --cap-add SYS_CHROOT
)

cleanup() {
  "${container_bin}" rm -f control-plane-podman-startup-legacy >/dev/null 2>&1 || true
  "${container_bin}" rm -f control-plane-podman-startup-rootful >/dev/null 2>&1 || true
  "${container_bin}" rm -f control-plane-podman-startup-timezone >/dev/null 2>&1 || true
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
if [[ -n "${entrypoint_override}" ]] && [[ ! -f "${entrypoint_override}" ]]; then
  printf 'CONTROL_PLANE_TEST_ENTRYPOINT_FILE is not a regular file: %s\n' "${entrypoint_override}" >&2
  exit 1
fi

entrypoint_override_args=()
if [[ -n "${entrypoint_override}" ]]; then
  entrypoint_override_args=(-v "${entrypoint_override}:/usr/local/bin/control-plane-entrypoint:ro")
fi

base_state_dirs=(
  gh
  ssh
  ssh-host-keys
  workspace
)

prepare_state_tree() {
  local prefix="$1"
  mkdir -p "${workdir}/${prefix}/copilot"
  for dir_name in "${base_state_dirs[@]}"; do
    mkdir -p "${workdir}/${prefix}/${dir_name}"
  done
}

printf '%s\n' 'podman-startup-test: verifying startup skips legacy persistent rootful image storage' >&2
prepare_state_tree legacy
mkdir -p "${workdir}/legacy/copilot/containers/rootful-vfs/storage/overlay"
printf '%s\n' 'legacy-sentinel' > "${workdir}/legacy/copilot/containers/rootful-vfs/storage/overlay/legacy-sentinel"

cat > "${workdir}/fake-chown" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log_file="${TEST_CHOWN_LOG:?}"
for arg in "$@"; do
  if [[ "${arg}" == *legacy-sentinel* ]]; then
    printf '%s\n' "${arg}" >> "${log_file}"
  fi
done
exec /usr/bin/chown "$@"
EOF
chmod +x "${workdir}/fake-chown"

set +e
legacy_output="$("${container_bin}" run --rm \
  --name control-plane-podman-startup-legacy \
  "${all_startup_caps[@]}" \
  -e SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForStartupRegression control-plane-startup' \
  -e TEST_CHOWN_LOG=/var/run/control-plane-test/chown.log \
  -v "${workdir}/legacy/copilot:/home/copilot/.copilot" \
  -v "${workdir}/legacy/gh:/home/copilot/.config/gh" \
  -v "${workdir}/legacy/ssh:/home/copilot/.ssh" \
  -v "${workdir}/legacy/ssh-host-keys:/var/lib/control-plane/ssh-host-keys" \
  -v "${workdir}/legacy/workspace:/workspace" \
  -v "${workdir}:/var/run/control-plane-test" \
  -v "${workdir}/fake-chown:/usr/local/bin/chown:ro" \
  "${entrypoint_override_args[@]}" \
  "${control_plane_image}" \
  bash -lc 'printf "%s\n" startup-ok' 2>&1)"
legacy_status=$?
set -e

if [[ "${legacy_status}" -ne 0 ]]; then
  printf 'Expected startup to ignore legacy rootful Podman image storage\n' >&2
  printf '%s\n' "${legacy_output}" >&2
  exit 1
fi
grep -qx 'startup-ok' <<<"${legacy_output}"
if [[ -s "${workdir}/chown.log" ]]; then
  printf 'Expected entrypoint ownership repair to skip legacy rootful Podman files\n' >&2
  cat "${workdir}/chown.log" >&2
  exit 1
fi

printf '%s\n' 'podman-startup-test: verifying rootful-service uses dedicated rootful Podman storage' >&2
prepare_state_tree rootful
mkdir -p "${workdir}/rootful/rootful-podman"

cat > "${workdir}/fake-podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args_file="${TEST_FAKE_PODMAN_ARGS_FILE:?}"
printf '%s\n' "$@" > "${args_file}"
socket_uri="${*: -1}"
socket_path="${socket_uri#unix://}"
perl -MIO::Socket::UNIX -e '
  use strict;
  use warnings;

  my $socket_path = shift @ARGV;
  my ($socket_dir) = $socket_path =~ m{^(.*)/[^/]+$};
  mkdir $socket_dir unless -d $socket_dir;
  unlink $socket_path if -e $socket_path;

  my $sock = IO::Socket::UNIX->new(
    Local  => $socket_path,
    Type   => SOCK_STREAM,
    Listen => 1,
  ) or die "failed to create socket ${socket_path}: $!";

  my $cleanup = sub {
    close $sock;
    unlink $socket_path if -e $socket_path;
    exit 0;
  };

  $SIG{TERM} = $cleanup;
  $SIG{INT} = $cleanup;

  while (1) {
    sleep 1;
  }
' "${socket_path}"
EOF
chmod +x "${workdir}/fake-podman"

cat > "${workdir}/rootful-startup-check.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

rootful_storage_conf=/var/tmp/control-plane/rootful-overlay/storage.conf

grep -q '^CONTAINER_HOST=unix:///var/tmp/control-plane/rootful-overlay/podman-root.sock$' /home/copilot/.config/control-plane/runtime.env
grep -qx 'driver = "overlay"' "${rootful_storage_conf}"
grep -qx 'graphroot = "/var/lib/control-plane/rootful-podman/rootful-overlay/storage"' "${rootful_storage_conf}"
grep -qx 'runroot = "/var/tmp/control-plane/rootful-overlay/runroot"' "${rootful_storage_conf}"
if [[ -e /dev/fuse ]]; then
  grep -qx 'mount_program = "/usr/bin/fuse-overlayfs"' "${rootful_storage_conf}"
else
  ! grep -q 'mount_program' "${rootful_storage_conf}"
fi
printf '%s\n' rootful-ok
EOF
chmod +x "${workdir}/rootful-startup-check.sh"

set +e
rootful_output="$("${container_bin}" run --rm \
  --name control-plane-podman-startup-rootful \
  "${all_startup_caps[@]}" \
  -e SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForStartupRegression control-plane-startup' \
  -e CONTROL_PLANE_LOCAL_PODMAN_MODE=rootful-service \
  -e CONTROL_PLANE_PODMAN_BIN=/var/run/control-plane-test/fake-podman \
  -e TEST_FAKE_PODMAN_ARGS_FILE=/var/run/control-plane-test/fake-podman.args \
  -v "${workdir}/rootful/copilot:/home/copilot/.copilot" \
  -v "${workdir}/rootful/gh:/home/copilot/.config/gh" \
  -v "${workdir}/rootful/ssh:/home/copilot/.ssh" \
  -v "${workdir}/rootful/ssh-host-keys:/var/lib/control-plane/ssh-host-keys" \
  -v "${workdir}/rootful/workspace:/workspace" \
  -v "${workdir}/rootful/rootful-podman:/var/lib/control-plane/rootful-podman" \
  -v "${workdir}:/var/run/control-plane-test" \
  "${entrypoint_override_args[@]}" \
  "${control_plane_image}" \
  /var/run/control-plane-test/rootful-startup-check.sh 2>&1)"
rootful_status=$?
set -e

if [[ "${rootful_status}" -ne 0 ]]; then
  printf 'Expected rootful-service startup to succeed with a dedicated Podman state root\n' >&2
  printf '%s\n' "${rootful_output}" >&2
  exit 1
fi
grep -qx 'rootful-ok' <<<"${rootful_output}"
grep -Fqx -- '--root' "${workdir}/fake-podman.args"
grep -Fqx -- '/var/lib/control-plane/rootful-podman/rootful-overlay/storage' "${workdir}/fake-podman.args"
if [[ -e "${workdir}/rootful/copilot/containers/rootful-overlay" ]]; then
  printf 'Expected rootful-service startup to avoid persistent ~/.copilot rootful-overlay storage\n' >&2
  find "${workdir}/rootful/copilot/containers/rootful-overlay" -maxdepth 3 -print >&2 || true
  exit 1
fi
if [[ ! -d "${workdir}/rootful/rootful-podman/rootful-overlay" ]]; then
  printf 'Expected rootful-service startup to create dedicated /var/lib/control-plane/rootful-podman state\n' >&2
  find "${workdir}/rootful/rootful-podman" -maxdepth 3 -print >&2 || true
  exit 1
fi

printf '%s\n' 'podman-startup-test: verifying configured timezone propagates to runtime env and login shell' >&2
prepare_state_tree timezone

cat > "${workdir}/timezone-check.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

grep -qx 'TZ=Asia/Tokyo' /home/copilot/.config/control-plane/runtime.env
su -s /bin/bash copilot -c 'bash -lc '"'"'
  test "${TZ}" = "Asia/Tokyo"
  test "$(date +%Z)" = "JST"
  test "$(date +%z)" = "+0900"
'"'"''
printf '%s\n' timezone-ok
EOF
chmod +x "${workdir}/timezone-check.sh"

set +e
timezone_output="$("${container_bin}" run --rm \
  --name control-plane-podman-startup-timezone \
  "${all_startup_caps[@]}" \
  -e SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForStartupRegression control-plane-startup' \
  -e TZ=Asia/Tokyo \
  -v "${workdir}/timezone/copilot:/home/copilot/.copilot" \
  -v "${workdir}/timezone/gh:/home/copilot/.config/gh" \
  -v "${workdir}/timezone/ssh:/home/copilot/.ssh" \
  -v "${workdir}/timezone/ssh-host-keys:/var/lib/control-plane/ssh-host-keys" \
  -v "${workdir}/timezone/workspace:/workspace" \
  -v "${workdir}:/var/run/control-plane-test" \
  "${entrypoint_override_args[@]}" \
  "${control_plane_image}" \
  /var/run/control-plane-test/timezone-check.sh 2>&1)"
timezone_status=$?
set -e

if [[ "${timezone_status}" -ne 0 ]]; then
  printf 'Expected configured timezone to propagate through runtime.env and login shells\n' >&2
  printf '%s\n' "${timezone_output}" >&2
  exit 1
fi
grep -qx 'timezone-ok' <<<"${timezone_output}"

printf '%s\n' 'podman-startup-test: startup regressions ok' >&2
