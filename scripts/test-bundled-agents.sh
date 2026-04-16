#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
agents_dir="${repo_root}/containers/control-plane/agents"
dockerfile_path="${repo_root}/containers/control-plane/Dockerfile"
entrypoint_path="${repo_root}/containers/control-plane/bin/control-plane-entrypoint"
control_plane_image="${CONTROL_PLANE_IMAGE_TAG:-localhost/control-plane:test}"
container_name="control-plane-bundled-agent-test"
container_bin=''
workdir="$(mktemp -d)"
control_plane_run_user=(--user 0:0)
startup_caps=(
  --cap-add AUDIT_WRITE
  --cap-add CHOWN
  --cap-add DAC_OVERRIDE
  --cap-add FOWNER
  --cap-add SETGID
  --cap-add SETUID
  --cap-add SYS_CHROOT
)

# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"
# shellcheck source=scripts/lib-bundled-agents.sh
source "${script_dir}/lib-bundled-agents.sh"

cleanup() {
  if [[ -n "${container_bin}" ]]; then
    "${container_bin}" rm -f "${container_name}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${container_bin}" ]] && [[ -d "${workdir}" ]]; then
    "${container_bin}" run --rm \
      --user 0:0 \
      -v "${workdir}:/cleanup" \
      --entrypoint sh \
      "${control_plane_image}" \
      -c 'find /cleanup -mindepth 1 -depth -delete' >/dev/null 2>&1 || true
  fi
  rm -rf "${workdir}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

assert_file_present() {
  local path="$1"

  [[ -f "${path}" ]] || {
    printf 'Expected file: %s\n' "${path}" >&2
    exit 1
  }
}

assert_file_contains() {
  local path="$1"
  local expected="$2"

  grep -Fq -- "${expected}" "${path}" || {
    printf 'Expected %s to contain: %s\n' "${path}" "${expected}" >&2
    exit 1
  }
}

toolchain="$(detect_build_test_toolchain)"
container_bin="$(container_runtime_for_toolchain "${toolchain}")"

require_command "${container_bin}"
build_image_for_toolchain "${toolchain}" "${control_plane_image}" containers/control-plane

mapfile -t bundled_agent_specs < <(control_plane_bundled_agent_specs)
image_check_script='set -euo pipefail'
startup_check_script=''

printf '%s\n' 'bundled-agents-test: checking agent wiring' >&2
assert_file_present "${dockerfile_path}"
assert_file_present "${entrypoint_path}"
assert_file_contains "${dockerfile_path}" 'COPY agents/ /usr/local/share/control-plane/agents/'
assert_file_contains "${entrypoint_path}" 'bundled_agents_dir="/usr/local/share/control-plane/agents"'
assert_file_contains "${entrypoint_path}" 'sync_bundled_control_plane_entries'
assert_file_contains "${entrypoint_path}" 'install_bundled_control_plane_agents'

for spec in "${bundled_agent_specs[@]}"; do
  IFS='|' read -r agent_name agent_file <<<"${spec}"
  agent_path="${agents_dir}/${agent_file}"

  assert_file_present "${agent_path}"
  assert_file_contains "${agent_path}" "name: ${agent_name}"

  image_check_script+=$'\n'"agent_file=/usr/local/share/control-plane/agents/${agent_file}"
  image_check_script+=$'\n'"test -r \"\$agent_file\""
  image_check_script+=$'\n'"grep -Fqx \"name: ${agent_name}\" \"\$agent_file\""

  startup_check_script+=$'\n'"agent_file=\"\$HOME/.copilot/agents/${agent_file}\""
  startup_check_script+=$'\n'"test ! -L \"\$agent_file\""
  startup_check_script+=$'\n'"test -r \"\$agent_file\""
  startup_check_script+=$'\n'"grep -Fqx \"name: ${agent_name}\" \"\$agent_file\""
done

assert_file_contains "${agents_dir}/implementation-agent.agent.md" 'KISS, DRY, SOLID, security, and architecture-first reasoning'
assert_file_contains "${agents_dir}/kiss-dry-review-agent.agent.md" 'KISS and DRY issues'
assert_file_contains "${agents_dir}/solid-review-agent.agent.md" 'SOLID design issues'
assert_file_contains "${agents_dir}/security-review-agent.agent.md" 'security weaknesses, trust boundary issues'
assert_file_contains "${agents_dir}/architecture-review-agent.agent.md" 'architecture drift, layering issues'
assert_file_contains "${agents_dir}/review-coordinator-agent.agent.md" 'high-performance model such as claude-opus-4.6'
assert_file_contains "${agents_dir}/review-coordinator-agent.agent.md" 'batches of at most 4 concurrent review sub-agents'
assert_file_contains "${agents_dir}/review-coordinator-agent.agent.md" 'Aggregate the results into one critical review'
assert_file_contains "${agents_dir}/pre-implementation-design-agent.agent.md" 'pre-implementation investigation and design'
assert_file_contains "${agents_dir}/pre-implementation-design-agent.agent.md" 'wait for the user or invoking agent to choose'
assert_file_contains "${agents_dir}/pre-implementation-design-agent.agent.md" 'Do not write, edit, or delete repository source files'

printf '%s\n' 'bundled-agents-test: verifying bundled agents in image' >&2
"${container_bin}" run --rm \
  --entrypoint bash "${control_plane_image}" -lc "${image_check_script}"

printf '%s\n' 'bundled-agents-test: verifying startup sync keeps bundled agents readable' >&2
mkdir -p \
  "${workdir}/copilot" \
  "${workdir}/gh" \
  "${workdir}/ssh" \
  "${workdir}/ssh-host-keys" \
  "${workdir}/workspace"

set +e
agent_output="$("${container_bin}" run --rm \
  --name "${container_name}" \
  "${control_plane_run_user[@]}" \
  "${startup_caps[@]}" \
  -e SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForRegressionOnly control-plane-bundled-agent' \
  -v "${workdir}/copilot:/home/copilot/.copilot" \
  -v "${workdir}/gh:/home/copilot/.config/gh" \
  -v "${workdir}/ssh:/home/copilot/.ssh" \
  -v "${workdir}/ssh-host-keys:/var/lib/control-plane/ssh-host-keys" \
  -v "${workdir}/workspace:/workspace" \
  "${control_plane_image}" \
  bash -lc "set -euo pipefail
test -L /var/lib/control-plane/managed-runtime/copilot-home/agents
su -s /bin/bash copilot -c 'set -euo pipefail${startup_check_script}
printf \"%s\n\" bundled-agents-ok'" 2>&1)"
agent_status=$?
set -e

if [[ "${agent_status}" -ne 0 ]]; then
  printf 'Expected bundled agents to remain readable after startup sync\n' >&2
  printf '%s\n' "${agent_output}" >&2
  exit 1
fi
grep -qx 'bundled-agents-ok' <<<"${agent_output}"

printf '%s\n' 'bundled-agents-test: agents ok' >&2
