#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
chart_path="./deploy/helm/control-plane"
fixture_values="./deploy/helm/control-plane/ci/multi-instance-values.yaml"
manifest_path="$(mktemp)"

cleanup() {
  rm -f "${manifest_path}"
}

trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

run_helm() {
  if command -v helm >/dev/null 2>&1; then
    (
      cd "${repo_root}"
      helm "$@"
    )
    return
  fi

  local container_bin="${CONTROL_PLANE_CONTAINER_BIN:-docker}"
  require_command "${container_bin}"

  "${container_bin}" run --rm \
    -v "${repo_root}:/workspace" \
    -w /workspace \
    docker.io/alpine/helm:3.17.3 \
    "$@"
}

render_chart() {
  run_helm template test-release "${chart_path}" -f "${fixture_values}" >"${manifest_path}"
}

resource_block() {
  local kind="$1"
  local name="$2"
  local resource_namespace="${3:-}"

  awk -v kind="${kind}" -v name="${name}" -v resource_namespace="${resource_namespace}" '
    BEGIN {
      RS = "---\n"
    }

    $0 ~ ("kind:[[:space:]]*" kind "([[:space:]]|$)") \
      && $0 ~ ("name:[[:space:]]*" name "([[:space:]]|$)") \
      && (resource_namespace == "" || $0 ~ ("namespace:[[:space:]]*" resource_namespace "([[:space:]]|$)")) {
        print
        found = 1
        exit
      }

    END {
      exit(found ? 0 : 1)
    }
  ' "${manifest_path}"
}

assert_resource_present() {
  resource_block "$1" "$2" "${3:-}" >/dev/null || {
    printf 'Expected %s/%s%s in rendered chart\n' "$1" "$2" "${3:+ namespace $3}" >&2
    exit 1
  }
}

assert_resource_absent() {
  if resource_block "$1" "$2" "${3:-}" >/dev/null; then
    printf 'Did not expect %s/%s%s in rendered chart\n' "$1" "$2" "${3:+ namespace $3}" >&2
    exit 1
  fi
}

assert_resource_contains() {
  local kind="$1"
  local name="$2"
  local namespace="$3"
  local expected="$4"
  local block

  block="$(resource_block "${kind}" "${name}" "${namespace}")"
  grep -Fq -- "${expected}" <<<"${block}" || {
    printf 'Expected %s/%s namespace %s to contain: %s\n' "${kind}" "${name}" "${namespace}" "${expected}" >&2
    exit 1
  }
}

assert_kind_count() {
  local kind="$1"
  local expected="$2"
  local actual

  actual="$(grep -Ec "^[[:space:]]*kind:[[:space:]]*${kind}([[:space:]]|$)" "${manifest_path}")"
  [[ "${actual}" == "${expected}" ]] || {
    printf 'Expected %s count %s but found %s\n' "${kind}" "${expected}" "${actual}" >&2
    exit 1
  }
}

printf '%s\n' 'helm-chart-test: rendering chart' >&2
render_chart

assert_kind_count Namespace 4
assert_kind_count Deployment 2
assert_kind_count Service 2
assert_kind_count PersistentVolumeClaim 2
assert_kind_count Secret 1

assert_resource_present Namespace copilot-repo-one
assert_resource_present Namespace copilot-repo-one-jobs
assert_resource_present Namespace repo-two-main
assert_resource_present Namespace repo-two-jobs

assert_resource_present Secret control-plane-auth copilot-repo-one
assert_resource_absent Secret control-plane-auth repo-two-main

assert_resource_present PersistentVolumeClaim control-plane-workspace-pvc copilot-repo-one
assert_resource_present PersistentVolumeClaim control-plane-copilot-session-pvc copilot-repo-one
assert_resource_absent PersistentVolumeClaim control-plane-workspace-pvc repo-two-main
assert_resource_absent PersistentVolumeClaim control-plane-copilot-session-pvc repo-two-main

assert_resource_contains PersistentVolumeClaim control-plane-workspace-pvc copilot-repo-one 'storage: 20Gi'
assert_resource_contains PersistentVolumeClaim control-plane-workspace-pvc copilot-repo-one 'storageClassName: "fast-rwo"'
assert_resource_contains PersistentVolumeClaim control-plane-copilot-session-pvc copilot-repo-one 'storage: 4Gi'
assert_resource_contains PersistentVolumeClaim control-plane-copilot-session-pvc copilot-repo-one 'storageClassName: "fast-rwx"'

assert_resource_contains ConfigMap control-plane-env repo-two-main 'CONTROL_PLANE_K8S_NAMESPACE: "repo-two-main"'
assert_resource_contains ConfigMap control-plane-env repo-two-main 'CONTROL_PLANE_JOB_NAMESPACE: "repo-two-jobs"'
assert_resource_contains ConfigMap control-plane-env repo-two-main 'CONTROL_PLANE_COPILOT_SESSION_PVC: "repo-two-session-pvc"'
assert_resource_contains ConfigMap control-plane-env repo-two-main 'CONTROL_PLANE_COPILOT_SESSION_GH_SUBPATH: "session/gh"'
assert_resource_contains ConfigMap control-plane-env repo-two-main 'CONTROL_PLANE_COPILOT_SESSION_SSH_SUBPATH: "session/ssh"'
assert_resource_contains ConfigMap control-plane-env repo-two-main 'CONTROL_PLANE_WORKSPACE_SUBPATH: "repositories/repo-two"'

assert_resource_contains ConfigMap control-plane-instance-env repo-two-main 'CONTROL_PLANE_WORKSPACE_PVC: "repo-two-workspace-pvc"'
assert_resource_contains ConfigMap control-plane-instance-env repo-two-main 'CONTROL_PLANE_JOB_TRANSFER_HOST: "repo-two-control-plane.repo-two-main.svc.cluster.local"'
assert_resource_contains ConfigMap control-plane-instance-env repo-two-main 'CONTROL_PLANE_JOB_TRANSFER_PORT: "2022"'
assert_resource_contains ConfigMap control-plane-instance-env repo-two-main 'CONTROL_PLANE_FAST_EXECUTION_BOOTSTRAP_IMAGE: "ghcr.io/chalharu/copilot-sandbox-container/control-plane:sha-abcdef0"'
assert_resource_contains ConfigMap control-plane-instance-env repo-two-main 'CONTROL_PLANE_JOB_TRANSFER_IMAGE: "ghcr.io/chalharu/copilot-sandbox-container/control-plane:sha-abcdef0"'
assert_resource_contains ConfigMap control-plane-instance-env repo-two-main 'CONTROL_PLANE_JOB_IMAGE_PULL_POLICY: "Always"'

assert_resource_contains Service repo-two-control-plane repo-two-main 'type: ClusterIP'
assert_resource_contains Service repo-two-control-plane repo-two-main 'port: 2022'

assert_resource_contains Deployment control-plane repo-two-main 'image: ghcr.io/chalharu/copilot-sandbox-container/control-plane:sha-abcdef0'
assert_resource_contains Deployment control-plane repo-two-main 'imagePullPolicy: Always'
assert_resource_contains Deployment control-plane repo-two-main 'claimName: repo-two-session-pvc'
assert_resource_contains Deployment control-plane repo-two-main 'claimName: repo-two-workspace-pvc'
assert_resource_contains Deployment control-plane repo-two-main 'secretName: repo-two-auth'
assert_resource_contains Deployment control-plane repo-two-main 'subPath: "repositories/repo-two"'
assert_resource_contains Deployment control-plane repo-two-main 'subPath: "session/gh"'
assert_resource_contains Deployment control-plane repo-two-main 'subPath: "session/ssh"'

assert_resource_contains RoleBinding control-plane-jobs repo-two-jobs 'namespace: repo-two-main'
assert_resource_contains RoleBinding control-plane-exec-workloads repo-two-jobs 'namespace: repo-two-main'

printf '%s\n' 'helm-chart-test: ok' >&2
