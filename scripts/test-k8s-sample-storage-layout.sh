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

resource_block() {
  local kind="$1"
  local name="$2"

  awk -v kind="${kind}" -v name="${name}" '
    BEGIN {
      RS = "---\n"
    }

    $0 ~ ("kind:[[:space:]]*" kind) && $0 ~ ("name:[[:space:]]*" name "([[:space:]]|$)") {
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
  local kind="$1"
  local name="$2"

  resource_block "${kind}" "${name}" >/dev/null || {
    printf 'Expected %s/%s in sample manifest\n' "${kind}" "${name}" >&2
    exit 1
  }
}

assert_resource_absent() {
  local kind="$1"
  local name="$2"

  if resource_block "${kind}" "${name}" >/dev/null; then
    printf 'Did not expect %s/%s in sample manifest\n' "${kind}" "${name}" >&2
    exit 1
  fi
}

assert_resource_contains() {
  local kind="$1"
  local name="$2"
  local expected="$3"
  local block

  block="$(resource_block "${kind}" "${name}")"
  grep -Fq "${expected}" <<<"${block}" || {
    printf 'Expected %s/%s to contain: %s\n' "${kind}" "${name}" "${expected}" >&2
    exit 1
  }
}

deployment_block() {
  resource_block Deployment control-plane
}

assert_deployment_contains() {
  local expected="$1"
  local block

  block="$(deployment_block)"
  grep -Fq "${expected}" <<<"${block}" || {
    printf 'Expected Deployment/control-plane to contain: %s\n' "${expected}" >&2
    exit 1
  }
}

assert_deployment_absent() {
  local unexpected="$1"
  local block

  block="$(deployment_block)"
  if grep -Fq "${unexpected}" <<<"${block}"; then
    printf 'Did not expect Deployment/control-plane to contain: %s\n' "${unexpected}" >&2
    exit 1
  fi
}

printf '%s\n' 'k8s-sample-storage-layout-test: validating sample manifest syntax' >&2
grep -Eq '^apiVersion:' "${manifest_path}" || {
  printf 'Expected sample manifest to contain Kubernetes resources\n' >&2
  exit 1
}

printf '%s\n' 'k8s-sample-storage-layout-test: checking persistent volume claims' >&2
pvc_count="$(awk '
  BEGIN {
    RS = "---\n"
  }

  /kind:[[:space:]]*PersistentVolumeClaim/ {
    count++
  }

  END {
    print count + 0
  }
' "${manifest_path}")"
[[ "${pvc_count}" == "3" ]] || {
  printf 'Expected exactly 3 PersistentVolumeClaims, found %s\n' "${pvc_count}" >&2
  exit 1
}

assert_resource_present PersistentVolumeClaim control-plane-copilot-session-pvc
assert_resource_contains PersistentVolumeClaim control-plane-copilot-session-pvc 'ReadWriteMany'
assert_resource_contains PersistentVolumeClaim control-plane-copilot-session-pvc 'storage: 2Gi'
assert_resource_contains PersistentVolumeClaim control-plane-copilot-session-pvc 'storageClassName: replace-me-with-rwx-storage-class'

assert_resource_present PersistentVolumeClaim control-plane-workspace-pvc
assert_resource_contains PersistentVolumeClaim control-plane-workspace-pvc 'ReadWriteOnce'
assert_resource_contains PersistentVolumeClaim control-plane-workspace-pvc 'storage: 5Gi'
assert_resource_contains PersistentVolumeClaim control-plane-workspace-pvc 'storageClassName: standard'

assert_resource_present PersistentVolumeClaim control-plane-sccache-pvc
assert_resource_contains PersistentVolumeClaim control-plane-sccache-pvc 'ReadWriteOnce'
assert_resource_contains PersistentVolumeClaim control-plane-sccache-pvc 'storage: 5Gi'
assert_resource_contains PersistentVolumeClaim control-plane-sccache-pvc 'storageClassName: standard'
assert_resource_absent StorageClass control-plane-local-storage

assert_resource_absent PersistentVolumeClaim control-plane-state-pvc
assert_resource_absent PersistentVolumeClaim control-plane-session-state-pvc
assert_resource_absent PersistentVolumeClaim control-plane-rootful-podman-pvc

printf '%s\n' 'k8s-sample-storage-layout-test: checking ConfigMap-backed environment defaults' >&2
assert_resource_present ConfigMap control-plane-config
assert_resource_contains ConfigMap control-plane-config 'copilot-config.json: |'
assert_resource_present ConfigMap control-plane-env
assert_resource_present Secret sccache-dist-auth
assert_resource_contains ConfigMap control-plane-env 'SSH_PUBLIC_KEY_FILE: /var/run/control-plane-auth/ssh-public-key'
assert_resource_contains ConfigMap control-plane-env 'CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS: "10000"'
assert_resource_contains ConfigMap control-plane-env 'CONTROL_PLANE_JOB_TRANSFER_IMAGE: ghcr.io/chalharu/copilot-sandbox-container/control-plane:replace-me-with-commit-sha'
assert_resource_contains ConfigMap control-plane-env 'CONTROL_PLANE_ROOTFUL_PODMAN_STORAGE_DRIVER: overlay'
assert_resource_contains ConfigMap control-plane-env 'CONTROL_PLANE_ROOTFUL_PODMAN_RUNTIME_DIR: /var/tmp/control-plane/rootful-overlay'
assert_resource_contains ConfigMap control-plane-env 'SCCACHE_DIST_SCHEDULER_URL: http://sccache-dist.copilot-sandbox.svc.cluster.local:10600'
assert_resource_contains ConfigMap control-plane-env 'SCCACHE_DIST_CLIENT_TOKEN_FILE: /var/run/sccache-dist-auth-client/client-token'
assert_resource_contains ConfigMap control-plane-env 'SCCACHE_DIST_TOOLCHAIN_CACHE_SIZE: "4294967296"'
assert_resource_contains ConfigMap control-plane-env 'SCCACHE_CACHE_SIZE: "4G"'
assert_resource_contains ConfigMap control-plane-env 'TZ: Asia/Tokyo'

printf '%s\n' 'k8s-sample-storage-layout-test: checking services, deployments, and cache mounts' >&2
assert_resource_present Service control-plane
assert_resource_present Service sccache-dist
assert_resource_present Deployment sccache-dist
assert_resource_contains Service sccache-dist 'port: 10600'
assert_resource_contains Service sccache-dist 'targetPort: dist-sch'
assert_resource_contains Service sccache-dist 'app.kubernetes.io/name: sccache-dist'
assert_deployment_contains 'claimName: control-plane-copilot-session-pvc'
assert_deployment_contains 'claimName: control-plane-workspace-pvc'
assert_deployment_contains 'envFrom:'
assert_deployment_contains 'name: control-plane-env'
assert_deployment_contains 'subPath: state/copilot-config.json'
assert_deployment_contains 'subPath: state/command-history-state.json'
assert_deployment_contains 'subPath: session-state'
assert_deployment_contains 'subPath: state/gh'
assert_deployment_contains 'subPath: state/ssh'
assert_deployment_contains 'subPath: state/ssh-host-keys'
assert_deployment_contains 'mountPath: /var/run/sccache-dist-auth-client'
assert_deployment_contains 'chown 1000:1000 /workspace-state/workspace /workspace-state/workspace/cache'
assert_deployment_contains 'chmod 700 /workspace-state/workspace /workspace-state/workspace/cache'
assert_deployment_contains 'mountPath: /var/lib/control-plane/rootful-podman'
assert_deployment_contains 'subPath: rootful-podman'
assert_deployment_contains 'mountPath: /var/tmp/control-plane'
assert_deployment_contains 'subPath: runtime-tmp'
assert_deployment_contains 'name: cache'
assert_deployment_contains 'emptyDir: {}'
assert_deployment_contains 'rm -rf /cache/rootful-podman/*'
assert_deployment_contains 'mkdir -p /cache/rootful-podman/rootful-overlay /cache/runtime-tmp/rootful-overlay'
assert_deployment_absent 'mountPath: /workspace/cache/sccache'
assert_deployment_absent 'claimName: control-plane-sccache-pvc'
assert_deployment_absent 'kubernetes.io/arch: amd64'
assert_deployment_absent 'name: sccache-dist-scheduler'
assert_deployment_absent 'name: sccache-dist-builder'
assert_deployment_absent 'mountPath: /var/cache/sccache-dist'
assert_deployment_absent 'mountPath: /var/run/sccache-dist-auth-server'
assert_deployment_absent 'fieldPath: status.podIP'
assert_deployment_absent "value: \$(POD_IP):10501"
assert_deployment_absent 'image: ghcr.io/chalharu/copilot-sandbox-container/sccache:0.14.0'
assert_resource_contains Deployment sccache-dist 'claimName: control-plane-sccache-pvc'
assert_resource_contains Deployment sccache-dist 'kubernetes.io/arch: amd64'
assert_resource_contains Deployment sccache-dist 'name: sccache-dist-scheduler'
assert_resource_contains Deployment sccache-dist 'name: sccache-dist-builder'
assert_resource_contains Deployment sccache-dist 'image: ghcr.io/chalharu/copilot-sandbox-container/sccache-dist:0.14.0'
assert_resource_contains Deployment sccache-dist '/usr/local/bin/sccache-dist-entrypoint'
assert_resource_contains Deployment sccache-dist 'mountPath: /var/cache/sccache-dist'
assert_resource_contains Deployment sccache-dist 'mountPath: /var/run/sccache-dist-auth-client'
assert_resource_contains Deployment sccache-dist 'mountPath: /var/run/sccache-dist-auth-server'
assert_resource_contains Deployment sccache-dist 'fieldPath: status.podIP'
assert_resource_contains Deployment sccache-dist "value: \$(POD_IP):10501"

printf '%s\n' 'k8s-sample-storage-layout-test: checking Podman defaults and legacy PVC removal' >&2
if grep -Fq '/run/control-plane/podman' "${manifest_path}"; then
  printf 'Expected sample manifest to avoid /run/control-plane/podman for Podman state\n' >&2
  exit 1
fi
if grep -Fq 'rootful-vfs' "${manifest_path}"; then
  printf 'Expected sample manifest to stop defaulting rootful Podman to vfs\n' >&2
  exit 1
fi
if grep -Fq 'CONTROL_PLANE_SCCACHE_PVC' "${manifest_path}"; then
  printf 'Expected sample manifest to stop wiring direct sccache PVC mounts into jobs\n' >&2
  exit 1
fi
if grep -Fq 'control-plane-local-storage' "${manifest_path}"; then
  printf 'Expected sample manifest to stop depending on the bespoke local-storage class\n' >&2
  exit 1
fi

printf '%s\n' 'k8s-sample-storage-layout-test: sample manifest ok' >&2
