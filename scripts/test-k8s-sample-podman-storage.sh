#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
manifest_path="${script_dir}/../deploy/kubernetes/control-plane.example.yaml"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

require_command kubectl

assert_env_value() {
  local env_name="$1"
  local expected_value="$2"

  awk -v env_name="${env_name}" -v expected_value="${expected_value}" '
    $1 == "-" && $2 == "name:" && $3 == env_name {
      if (getline > 0 && $1 == "value:" && $2 == expected_value) {
        found = 1
        exit
      }
    }

    END {
      exit(found ? 0 : 1)
    }
  ' "${manifest_path}"
}

printf '%s\n' 'k8s-sample-podman-storage-test: validating sample manifest syntax' >&2
kubectl create --dry-run=client --validate=false -f "${manifest_path}" -o name >/dev/null

printf '%s\n' 'k8s-sample-podman-storage-test: checking overlay defaults and non-/run Podman paths' >&2
assert_env_value CONTROL_PLANE_ROOTFUL_PODMAN_STORAGE_DRIVER overlay
assert_env_value CONTROL_PLANE_ROOTFUL_PODMAN_RUNTIME_DIR /var/tmp/control-plane/rootful-overlay
grep -Fq 'rm -rf /var/lib/control-plane/rootful-podman/*' "${manifest_path}"
grep -Fq 'mkdir -p /var/lib/control-plane/rootful-podman/rootful-overlay' "${manifest_path}"
grep -Fq 'mountPath: /var/lib/control-plane/rootful-podman' "${manifest_path}"
grep -Fq 'mountPath: /var/tmp/control-plane' "${manifest_path}"
if grep -Fq '/run/control-plane/podman' "${manifest_path}"; then
  printf 'Expected sample manifest to avoid /run/control-plane/podman for Podman state\n' >&2
  exit 1
fi
if grep -Fq 'rootful-vfs' "${manifest_path}"; then
  printf 'Expected sample manifest to stop defaulting rootful Podman to vfs\n' >&2
  exit 1
fi

printf '%s\n' 'k8s-sample-podman-storage-test: sample manifest ok' >&2
