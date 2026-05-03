#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-biome-hook-image.sh
source "${script_dir}/lib-biome-hook-image.sh"
repo_root="$(cd "${script_dir}/.." && pwd)"
chart_path="./deploy/helm/control-plane"
fixture_values="./deploy/helm/control-plane/ci/multi-instance-values.yaml"
resource_isolation_values="./deploy/helm/control-plane/ci/per-instance-resource-isolation-values.yaml"
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
  local values_path="${1:-${fixture_values}}"
  run_helm template test-release "${chart_path}" -f "${values_path}" >"${manifest_path}"
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

assert_resource_not_contains() {
  local kind="$1"
  local name="$2"
  local namespace="$3"
  local unexpected="$4"
  local block

  block="$(resource_block "${kind}" "${name}" "${namespace}")"
  if grep -Fq -- "${unexpected}" <<<"${block}"; then
    printf 'Did not expect %s/%s namespace %s to contain: %s\n' "${kind}" "${name}" "${namespace}" "${unexpected}" >&2
    exit 1
  fi
}

assert_kind_count() {
  local kind="$1"
  local expected="$2"
  local actual

  actual="$(grep -Ec "^kind:[[:space:]]*${kind}([[:space:]]|$)" "${manifest_path}")"
  [[ "${actual}" == "${expected}" ]] || {
    printf 'Expected %s count %s but found %s\n' "${kind}" "${expected}" "${actual}" >&2
    exit 1
  }
}

printf '%s\n' 'helm-chart-test: rendering chart' >&2
render_chart

assert_kind_count Namespace 2
assert_kind_count Deployment 2
assert_kind_count Service 2
assert_kind_count PersistentVolumeClaim 2
assert_kind_count ConfigMap 5
assert_kind_count Secret 1
assert_kind_count ServiceAccount 3
assert_kind_count Role 4
assert_kind_count RoleBinding 4

assert_resource_present Namespace copilot-shared
assert_resource_present Namespace copilot-shared-jobs

assert_resource_present Secret control-plane-auth copilot-shared
assert_resource_absent Secret control-plane-auth-repo-two copilot-shared
assert_resource_absent Secret repo-two-auth copilot-shared
assert_resource_contains Secret control-plane-auth copilot-shared 'gh-github-token: "shared-gh-token"'
assert_resource_contains Secret control-plane-auth copilot-shared 'gh-hosts.yml: |'
assert_resource_contains Secret control-plane-auth copilot-shared 'oauth_token: shared-host-token'

assert_resource_present PersistentVolumeClaim control-plane-workspace-pvc-repo-one copilot-shared
assert_resource_present PersistentVolumeClaim shared-session-pvc copilot-shared
assert_resource_absent PersistentVolumeClaim repo-two-workspace-pvc copilot-shared

assert_resource_contains PersistentVolumeClaim control-plane-workspace-pvc-repo-one copilot-shared 'storage: 20Gi'
assert_resource_contains PersistentVolumeClaim control-plane-workspace-pvc-repo-one copilot-shared 'storageClassName: "fast-rwo"'
assert_resource_contains PersistentVolumeClaim shared-session-pvc copilot-shared 'storage: 4Gi'
assert_resource_contains PersistentVolumeClaim shared-session-pvc copilot-shared 'storageClassName: "fast-rwx"'

assert_resource_contains ConfigMap control-plane-env copilot-shared 'CONTROL_PLANE_GIT_USER_NAME: "Control Plane Bot"'
assert_resource_contains ConfigMap control-plane-env copilot-shared 'CONTROL_PLANE_GIT_USER_EMAIL: "control-plane@example.com"'
assert_resource_contains ConfigMap control-plane-env copilot-shared 'CONTROL_PLANE_FAST_EXECUTION_STARTUP_SCRIPT: "printf global-startup"'
assert_resource_contains ConfigMap control-plane-env copilot-shared "CONTROL_PLANE_BIOME_HOOK_IMAGE: \"${biome_hook_image}\""

assert_resource_contains ConfigMap control-plane-instance-env-repo-one copilot-shared 'CONTROL_PLANE_K8S_NAMESPACE: "copilot-shared"'
assert_resource_contains ConfigMap control-plane-instance-env-repo-one copilot-shared 'CONTROL_PLANE_JOB_NAMESPACE: "copilot-shared-jobs"'
assert_resource_contains ConfigMap control-plane-instance-env-repo-one copilot-shared 'CONTROL_PLANE_COPILOT_SESSION_PVC: "shared-session-pvc"'
assert_resource_contains ConfigMap control-plane-instance-env-repo-one copilot-shared 'GH_GITHUB_TOKEN_FILE: "/var/run/control-plane-auth/gh-github-token"'
assert_resource_contains ConfigMap control-plane-instance-env-repo-one copilot-shared 'GH_HOSTS_YML_FILE: "/var/run/control-plane-auth/gh-hosts.yml"'
assert_resource_contains ConfigMap control-plane-instance-env-repo-one copilot-shared 'CONTROL_PLANE_FAST_EXECUTION_SERVICE_ACCOUNT: "control-plane-exec"'
assert_resource_contains ConfigMap control-plane-instance-env-repo-one copilot-shared 'CONTROL_PLANE_JOB_SERVICE_ACCOUNT: "control-plane-job"'
assert_resource_contains ConfigMap control-plane-instance-env-repo-one copilot-shared 'CONTROL_PLANE_WORKSPACE_PVC: "control-plane-workspace-pvc-repo-one"'
assert_resource_contains ConfigMap control-plane-instance-env-repo-one copilot-shared 'TZ: "Asia/Tokyo"'

assert_resource_contains ConfigMap control-plane-instance-env-repo-two copilot-shared 'CONTROL_PLANE_K8S_NAMESPACE: "copilot-shared"'
assert_resource_contains ConfigMap control-plane-instance-env-repo-two copilot-shared 'CONTROL_PLANE_JOB_NAMESPACE: "copilot-shared-jobs"'
assert_resource_contains ConfigMap control-plane-instance-env-repo-two copilot-shared 'CONTROL_PLANE_COPILOT_SESSION_PVC: "shared-session-pvc"'
assert_resource_contains ConfigMap control-plane-instance-env-repo-two copilot-shared 'CONTROL_PLANE_COPILOT_SESSION_GH_SUBPATH: "session/gh"'
assert_resource_contains ConfigMap control-plane-instance-env-repo-two copilot-shared 'CONTROL_PLANE_COPILOT_SESSION_SSH_SUBPATH: "session/ssh"'
assert_resource_contains ConfigMap control-plane-instance-env-repo-two copilot-shared 'CONTROL_PLANE_WORKSPACE_SUBPATH: "repositories/repo-two"'
assert_resource_contains ConfigMap control-plane-instance-env-repo-two copilot-shared 'CONTROL_PLANE_GIT_USER_EMAIL: "repo-two@example.com"'
assert_resource_contains ConfigMap control-plane-instance-env-repo-two copilot-shared 'CONTROL_PLANE_FAST_EXECUTION_IMAGE_PULL_POLICY: "Always"'
assert_resource_contains ConfigMap control-plane-instance-env-repo-two copilot-shared 'CONTROL_PLANE_FAST_EXECUTION_STARTUP_SCRIPT: "printf repo-two-startup"'
assert_resource_contains ConfigMap control-plane-instance-env-repo-two copilot-shared 'CONTROL_PLANE_FAST_EXECUTION_SERVICE_ACCOUNT: "control-plane-exec"'
assert_resource_contains ConfigMap control-plane-instance-env-repo-two copilot-shared 'CONTROL_PLANE_JOB_SERVICE_ACCOUNT: "control-plane-job"'
assert_resource_contains ConfigMap control-plane-instance-env-repo-two copilot-shared 'TZ: "Europe/Berlin"'
assert_resource_not_contains ConfigMap control-plane-instance-env-repo-two copilot-shared 'GH_GITHUB_TOKEN_FILE: "/var/run/control-plane-auth/gh-github-token"'
assert_resource_not_contains ConfigMap control-plane-instance-env-repo-two copilot-shared 'GH_HOSTS_YML_FILE: "/var/run/control-plane-auth/gh-hosts.yml"'
assert_resource_contains ConfigMap control-plane-instance-env-repo-two copilot-shared 'CONTROL_PLANE_WORKSPACE_PVC: "repo-two-workspace-pvc"'
assert_resource_contains ConfigMap control-plane-instance-env-repo-two copilot-shared 'CONTROL_PLANE_JOB_TRANSFER_HOST: "repo-two-control-plane.copilot-shared.svc.cluster.local"'
assert_resource_contains ConfigMap control-plane-instance-env-repo-two copilot-shared 'CONTROL_PLANE_JOB_TRANSFER_PORT: "2022"'
assert_resource_not_contains ConfigMap control-plane-instance-env-repo-two copilot-shared 'CONTROL_PLANE_FAST_EXECUTION_BOOTSTRAP_IMAGE:'
assert_resource_contains ConfigMap control-plane-instance-env-repo-two copilot-shared 'CONTROL_PLANE_JOB_TRANSFER_IMAGE: "ghcr.io/chalharu/copilot-sandbox-container/control-plane:sha-abcdef0"'
assert_resource_contains ConfigMap control-plane-instance-env-repo-two copilot-shared 'CONTROL_PLANE_JOB_IMAGE_PULL_POLICY: "Always"'

assert_resource_contains ConfigMap control-plane-config copilot-shared '"telemetry": false'
assert_resource_contains ConfigMap control-plane-config-repo-two copilot-shared '"chat.warnOnLargeFiles": true'

assert_resource_contains Service control-plane-repo-one copilot-shared 'type: LoadBalancer'
assert_resource_contains Service repo-two-control-plane copilot-shared 'type: ClusterIP'
assert_resource_contains Service repo-two-control-plane copilot-shared 'port: 2022'

assert_resource_contains Deployment control-plane-repo-one copilot-shared 'image: ghcr.io/chalharu/copilot-sandbox-container/control-plane:test-global'
assert_resource_contains Deployment control-plane-repo-one copilot-shared 'claimName: shared-session-pvc'
assert_resource_contains Deployment control-plane-repo-one copilot-shared 'claimName: control-plane-workspace-pvc-repo-one'
assert_resource_contains Deployment control-plane-repo-one copilot-shared 'serviceAccountName: control-plane'
assert_resource_contains Deployment control-plane-repo-one copilot-shared 'name: control-plane-config'
assert_resource_contains Deployment control-plane-repo-one copilot-shared 'subPath: "instances/repo-one/session-state"'
assert_resource_contains Deployment control-plane-repo-two copilot-shared 'image: ghcr.io/chalharu/copilot-sandbox-container/control-plane:sha-abcdef0'
assert_resource_contains Deployment control-plane-repo-two copilot-shared 'imagePullPolicy: Always'
assert_resource_contains Deployment control-plane-repo-two copilot-shared 'claimName: shared-session-pvc'
assert_resource_contains Deployment control-plane-repo-two copilot-shared 'claimName: repo-two-workspace-pvc'
assert_resource_contains Deployment control-plane-repo-two copilot-shared 'secretName: repo-two-auth'
assert_resource_contains Deployment control-plane-repo-two copilot-shared 'serviceAccountName: control-plane'
assert_resource_contains Deployment control-plane-repo-two copilot-shared 'name: control-plane-config-repo-two'
assert_resource_contains Deployment control-plane-repo-two copilot-shared 'subPath: "repositories/repo-two"'
assert_resource_contains Deployment control-plane-repo-two copilot-shared 'subPath: "repo-state/repo-two/session-state"'
assert_resource_contains Deployment control-plane-repo-two copilot-shared 'subPath: "session/gh"'
assert_resource_contains Deployment control-plane-repo-two copilot-shared 'subPath: "session/ssh"'
assert_resource_not_contains Deployment control-plane-repo-one copilot-shared '/home/copilot/.copilot/config.json'
assert_resource_not_contains Deployment control-plane-repo-two copilot-shared '/home/copilot/.copilot/config.json'

assert_resource_contains RoleBinding control-plane-jobs-copilot-shared copilot-shared-jobs 'namespace: copilot-shared'
assert_resource_contains RoleBinding control-plane-exec-workloads-copilot-shared copilot-shared-jobs 'namespace: copilot-shared'

printf '%s\n' 'helm-chart-test: verifying per-instance resource isolation' >&2
render_chart "${resource_isolation_values}"

assert_kind_count Deployment 3
assert_resource_contains Deployment control-plane-copilot-sandbox-container copilot-sandbox 'memory: 2Gi'
assert_resource_contains Deployment control-plane-copilot-sandbox-container-2 copilot-sandbox 'memory: 8Gi'
assert_resource_contains Deployment control-plane-copilot-sandbox-container-3 copilot-sandbox 'memory: 2Gi'
assert_resource_not_contains Deployment control-plane-copilot-sandbox-container-3 copilot-sandbox 'memory: 8Gi'

printf '%s\n' 'helm-chart-test: ok' >&2
