#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"

container_bin=""
# renovate: datasource=docker depName=ghcr.io/renovatebot/renovate versioning=docker
renovate_image="${CONTROL_PLANE_RENOVATE_IMAGE:-ghcr.io/renovatebot/renovate:43.104.4@sha256:54369958207b06c85398d8c4dffc70997c89f07546fa0a4703b3774f48f48dab}"
base_dir=""
log_file=""
renovate_dry_run_timeout="${CONTROL_PLANE_RENOVATE_DRY_RUN_TIMEOUT:-120s}"
# Use container root so restrictive workspace mounts remain readable across
# Docker, rootful Podman, and rootless Podman.
workspace_access_user="0:0"
renovate_env=()

lookup_update_errors_are_tolerated() {
  local log_path="$1"

  if ! grep -Eq '^ERROR: lookupUpdates error' "${log_path}"; then
    return 0
  fi

  awk '
    BEGIN {
      in_block = 0
      block_count = 0
      package = ""
      message = ""
      ok = 1
    }
    function finish_block() {
      if (!in_block) {
        return
      }
      block_count++
      if (package != "https://github.com/anthropics/skills" || (message !~ /timeout while waiting for mutex to become available/ && index(message, "fatal: unable to access '\''https://github.com/anthropics/skills/'\''") == 0)) {
        ok = 0
      }
      in_block = 0
      package = ""
      message = ""
    }
    /^ERROR: lookupUpdates error/ {
      finish_block()
      in_block = 1
      next
    }
    in_block && /"packageName": / {
      package = $0
      sub(/^.*"packageName": "/, "", package)
      sub(/".*$/, "", package)
      next
    }
    in_block && /"message": / {
      message = $0
      sub(/^.*"message": "/, "", message)
      sub(/".*$/, "", message)
      next
    }
    in_block && /^(DEBUG:| INFO:| WARN:|ERROR:)/ {
      finish_block()
      if ($0 ~ /^ERROR: lookupUpdates error/) {
        in_block = 1
      }
      next
    }
    END {
      finish_block()
      if (block_count == 0 || ok == 0) {
        exit 1
      }
    }
  ' "${log_path}"
}

dependency_report_contains() {
  local dependency="$1"
  local log_path="$2"

  case "${dependency}" in
    busybox)
      grep -Eq '(^|[^[:alnum:]_-])busybox([^[:alnum:]_-]|$)|library/busybox' "${log_path}"
      ;;
    docker.io/library/node)
      grep -Eq 'docker\.io/library/node|index\.docker\.io, library/node|index\.docker\.io/v2/library/node' "${log_path}"
      ;;
    ghcr.io/biomejs/biome)
      grep -Eq 'ghcr\.io/biomejs/biome|ghcr\.io, biomejs/biome|ghcr\.io/v2/biomejs/biome' "${log_path}"
      ;;
    ghcr.io/renovatebot/renovate)
      grep -Eq 'ghcr\.io/renovatebot/renovate|ghcr\.io, renovatebot/renovate|ghcr\.io/v2/renovatebot/renovate' "${log_path}"
      ;;
    hadolint/hadolint)
      grep -Eq 'hadolint/hadolint|index\.docker\.io, hadolint/hadolint|index\.docker\.io/v2/hadolint/hadolint' "${log_path}"
      ;;
    koalaman/shellcheck)
      grep -Eq 'koalaman/shellcheck|index\.docker\.io, koalaman/shellcheck|index\.docker\.io/v2/koalaman/shellcheck' "${log_path}"
      ;;
    yamllint)
      grep -Eq 'yamllint|host=pypi\.org|https://pypi\.org' "${log_path}"
      ;;
    *)
      grep -Fq "${dependency}" "${log_path}"
      ;;
  esac
}

cleanup() {
  local cleanup_container_bin="${container_bin:-}"
  local cleanup_renovate_image="${renovate_image:-}"
  local cleanup_base_dir="${base_dir:-}"
  local cleanup_log_file="${log_file:-}"

  if [[ -n "${cleanup_container_bin}" ]] && command -v "${cleanup_container_bin}" >/dev/null 2>&1 && [[ -d "${cleanup_base_dir}" ]]; then
    "${cleanup_container_bin}" run --rm \
      --user "${workspace_access_user}" \
      -v "${cleanup_base_dir}:/tmp/renovate-base" \
      --entrypoint sh \
      "${cleanup_renovate_image}" \
      -c 'rm -rf /tmp/renovate-base/* /tmp/renovate-base/.[!.]* /tmp/renovate-base/..?* 2>/dev/null || true' \
      >/dev/null 2>&1 || true
  fi

  if [[ -n "${cleanup_base_dir}" ]]; then
    rm -rf "${cleanup_base_dir}" >/dev/null 2>&1 || true
  fi

  if [[ -n "${cleanup_log_file}" ]]; then
    rm -f "${cleanup_log_file}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

container_bin="$(detect_container_runtime)"
base_dir="$(mktemp -d)"
log_file="$(mktemp)"

# Renovate runs as a non-root UID, so the mounted cache directory must be
# writable even when executed through rootless Podman in GitHub Actions.
chmod 0777 "${base_dir}"

require_command "${container_bin}"
require_command timeout

"${container_bin}" run --rm \
  --user "${workspace_access_user}" \
  -v "${PWD}:/workspace:ro" \
  -w /workspace \
  --entrypoint renovate-config-validator \
  "${renovate_image}" \
  --strict --no-global /workspace/renovate.json5

renovate_status=0

set +e
timeout --signal=TERM --kill-after=10s "${renovate_dry_run_timeout}" \
  "${container_bin}" run --rm \
  --user "${workspace_access_user}" \
  "${renovate_env[@]}" \
  -e LOG_LEVEL=debug \
  -e RENOVATE_CONFIG_FILE=/workspace/renovate.json5 \
  -e RENOVATE_BASE_DIR=/tmp/renovate-base \
  -v "${base_dir}:/tmp/renovate-base" \
  -v "${PWD}:/workspace:ro" \
  -w /workspace \
  --entrypoint renovate \
  "${renovate_image}" \
  --platform=local \
  --dry-run=full \
  --onboarding=false \
  --repository-cache=reset \
  >"${log_file}" 2>&1
renovate_status=$?
set -e

if [[ "${renovate_status}" -eq 124 || "${renovate_status}" -eq 137 || "${renovate_status}" -eq 143 ]]; then
  if lookup_update_errors_are_tolerated "${log_file}"; then
    printf 'Renovate local dry-run timed out after %s; validating the captured dependency report instead.\n' \
      "${renovate_dry_run_timeout}" \
      >&2
    if grep -Fq 'ERROR: lookupUpdates error' "${log_file}"; then
      printf '%s\n' \
        'Ignoring transient git-refs lookup failures for the pinned external skills repository during local dry-run.' \
        >&2
    fi
  else
    cat "${log_file}" >&2
    exit 1
  fi
elif [[ "${renovate_status}" -ne 0 ]]; then
  if grep -Fq 'Cannot sync git when platform=local' "${log_file}" \
    && lookup_update_errors_are_tolerated "${log_file}"; then
    printf '%s\n' \
      'Renovate local dry-run hit the known platform=local git sync limitation; validating the captured dependency report instead.' \
      >&2
    if grep -Fq 'ERROR: lookupUpdates error' "${log_file}"; then
      printf '%s\n' \
        'Ignoring transient git-refs lookup failures for the pinned external skills repository during local dry-run.' \
        >&2
    fi
  else
    cat "${log_file}" >&2
    exit 1
  fi
fi

expected_dependencies=(
  "@github/copilot"
  "actions/download-artifact"
  "actions/checkout"
  "actions/upload-artifact"
  "azure/setup-kubectl"
  "busybox"
  "docker.io/library/node"
  "engineerd/setup-kind"
  "ghcr.io/biomejs/biome"
  "ghcr.io/renovatebot/renovate"
  "hadolint/hadolint"
  "koalaman/shellcheck"
  "markdownlint-cli2"
  "yamllint"
)

for dependency in "${expected_dependencies[@]}"; do
  if ! dependency_report_contains "${dependency}" "${log_file}"; then
    printf 'Renovate local dry run did not report expected dependency: %s\n' "${dependency}" >&2
    cat "${log_file}" >&2
    exit 1
  fi
done
