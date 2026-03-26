#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
manifest_root="${script_dir}/../deploy/kubernetes/control-plane.example"
install_manifest_root="${script_dir}/../deploy/kubernetes/control-plane.example/install"
manifest_path="$(mktemp)"
install_manifest_path="${install_manifest_root}/shared-persistent-volume-claims.yaml"

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

render_kustomization() {
  local source_root="$1"
  local output_path="$2"

  if command -v kustomize >/dev/null 2>&1; then
    kustomize build "${source_root}" >"${output_path}"
    return
  fi

  require_command kubectl
  kubectl kustomize "${source_root}" >"${output_path}"
}

render_sample_manifests() {
  render_kustomization "${manifest_root}" "${manifest_path}"
}

resource_block_from_file() {
  local source_manifest="$1"
  local kind="$2"
  local name="$3"

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
  ' "${source_manifest}"
}

resource_block() {
  resource_block_from_file "${manifest_path}" "$1" "$2"
}

install_resource_block() {
  resource_block_from_file "${install_manifest_path}" "$1" "$2"
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
  grep -Fq -- "${expected}" <<<"${block}" || {
    printf 'Expected %s/%s to contain: %s\n' "${kind}" "${name}" "${expected}" >&2
    exit 1
  }
}

assert_resource_not_contains() {
  local kind="$1"
  local name="$2"
  local unexpected="$3"
  local block

  block="$(resource_block "${kind}" "${name}")"
  if grep -Fq -- "${unexpected}" <<<"${block}"; then
    printf 'Did not expect %s/%s to contain: %s\n' "${kind}" "${name}" "${unexpected}" >&2
    exit 1
  fi
}

assert_install_resource_present() {
  local kind="$1"
  local name="$2"

  install_resource_block "${kind}" "${name}" >/dev/null || {
    printf 'Expected %s/%s in install sample manifest\n' "${kind}" "${name}" >&2
    exit 1
  }
}

assert_install_resource_contains() {
  local kind="$1"
  local name="$2"
  local expected="$3"
  local block

  block="$(install_resource_block "${kind}" "${name}")"
  grep -Fq "${expected}" <<<"${block}" || {
    printf 'Expected install %s/%s to contain: %s\n' "${kind}" "${name}" "${expected}" >&2
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

printf '%s\n' 'k8s-sample-storage-layout-test: rendering sample kustomization' >&2
if grep -R -n '^bases:' "${manifest_root}" >/dev/null; then
  printf 'Expected sample kustomizations to stop using deprecated bases\n' >&2
  exit 1
fi

render_sample_manifests

printf '%s\n' 'k8s-sample-storage-layout-test: validating rendered manifest syntax' >&2
grep -Eq '^apiVersion:' "${manifest_path}" || {
  printf 'Expected sample manifest to contain Kubernetes resources\n' >&2
  exit 1
}
grep -Eq '^apiVersion:' "${install_manifest_path}" || {
  printf 'Expected install sample manifest to contain Kubernetes resources\n' >&2
  exit 1
}

printf '%s\n' 'k8s-sample-storage-layout-test: checking persistent volume claims' >&2
assert_install_resource_present Namespace copilot-sandbox

root_pvc_count="$(awk '
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
[[ "${root_pvc_count}" == "1" ]] || {
  printf 'Expected exactly 1 PersistentVolumeClaim in the update-safe root manifest, found %s\n' "${root_pvc_count}" >&2
  exit 1
}
install_pvc_count="$(awk '
  BEGIN {
    RS = "---\n"
  }

  /kind:[[:space:]]*PersistentVolumeClaim/ {
    count++
  }

  END {
    print count + 0
  }
' "${install_manifest_path}")"
[[ "${install_pvc_count}" == "2" ]] || {
  printf 'Expected exactly 2 PersistentVolumeClaims in the install manifest, found %s\n' "${install_pvc_count}" >&2
  exit 1
}

assert_resource_present PersistentVolumeClaim control-plane-workspace-pvc
assert_resource_contains PersistentVolumeClaim control-plane-workspace-pvc 'ReadWriteOnce'
assert_resource_contains PersistentVolumeClaim control-plane-workspace-pvc 'storage: 5Gi'
assert_resource_contains PersistentVolumeClaim control-plane-workspace-pvc 'storageClassName: standard'

assert_resource_absent PersistentVolumeClaim control-plane-copilot-session-pvc
assert_resource_absent PersistentVolumeClaim control-plane-sccache-pvc

assert_install_resource_present PersistentVolumeClaim control-plane-copilot-session-pvc
assert_install_resource_contains PersistentVolumeClaim control-plane-copilot-session-pvc 'ReadWriteMany'
assert_install_resource_contains PersistentVolumeClaim control-plane-copilot-session-pvc 'storage: 2Gi'
assert_install_resource_contains PersistentVolumeClaim control-plane-copilot-session-pvc 'storageClassName: replace-me-with-rwx-storage-class'

assert_install_resource_present PersistentVolumeClaim control-plane-sccache-pvc
assert_install_resource_contains PersistentVolumeClaim control-plane-sccache-pvc 'ReadWriteOnce'
assert_install_resource_contains PersistentVolumeClaim control-plane-sccache-pvc 'storage: 5Gi'
assert_install_resource_contains PersistentVolumeClaim control-plane-sccache-pvc 'storageClassName: standard'
assert_resource_absent StorageClass control-plane-local-storage

assert_resource_absent PersistentVolumeClaim control-plane-state-pvc
assert_resource_absent PersistentVolumeClaim control-plane-session-state-pvc
assert_resource_absent PersistentVolumeClaim control-plane-rootful-podman-pvc

printf '%s\n' 'k8s-sample-storage-layout-test: checking ConfigMap-backed environment defaults' >&2
assert_resource_present ConfigMap control-plane-config
assert_resource_contains ConfigMap control-plane-config 'copilot-config.json: |'
assert_resource_present ConfigMap control-plane-env
assert_resource_present ServiceAccount garage-bootstrap
assert_resource_present Secret garage-admin-auth
assert_resource_absent Secret garage-sccache-auth
assert_resource_present Role garage-bootstrap-secret-writer
assert_resource_present RoleBinding garage-bootstrap-secret-writer
assert_resource_contains Role garage-bootstrap-secret-writer '- create'
assert_resource_contains Role garage-bootstrap-secret-writer 'resourceNames:'
assert_resource_contains Role garage-bootstrap-secret-writer '- garage-sccache-auth'
assert_resource_contains Role garage-bootstrap-secret-writer '- get'
assert_resource_contains Role garage-bootstrap-secret-writer '- patch'
assert_resource_contains Role garage-bootstrap-secret-writer '- update'
assert_resource_contains ConfigMap control-plane-env 'SSH_PUBLIC_KEY_FILE: /var/run/control-plane-auth/ssh-public-key'
assert_resource_contains ConfigMap control-plane-env 'CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS: "10000"'
assert_resource_contains ConfigMap control-plane-env 'CONTROL_PLANE_JOB_TRANSFER_IMAGE: ghcr.io/chalharu/copilot-sandbox-container/control-plane:replace-me-with-commit-sha'
assert_resource_contains ConfigMap control-plane-env 'CONTROL_PLANE_ROOTFUL_PODMAN_STORAGE_DRIVER: overlay'
assert_resource_contains ConfigMap control-plane-env 'CONTROL_PLANE_ROOTFUL_PODMAN_RUNTIME_DIR: /var/tmp/control-plane/rootful-overlay'
assert_resource_contains ConfigMap control-plane-env 'SCCACHE_BUCKET: control-plane-sccache'
assert_resource_contains ConfigMap control-plane-env 'SCCACHE_ENDPOINT: http://garage-s3.copilot-sandbox.svc.cluster.local:3900'
assert_resource_contains ConfigMap control-plane-env 'SCCACHE_REGION: garage'
assert_resource_contains ConfigMap control-plane-env 'SCCACHE_S3_USE_SSL: "false"'
assert_resource_contains ConfigMap control-plane-env 'SCCACHE_S3_KEY_PREFIX: sccache/'
assert_resource_contains ConfigMap control-plane-env 'AWS_ACCESS_KEY_ID_FILE: /var/run/garage-sccache-auth/access-key-id'
assert_resource_contains ConfigMap control-plane-env 'AWS_SECRET_ACCESS_KEY_FILE: /var/run/garage-sccache-auth/secret-access-key'
assert_resource_contains ConfigMap control-plane-env 'SCCACHE_CACHE_SIZE: 4G'

printf '%s\n' 'k8s-sample-storage-layout-test: checking services, deployments, and cache mounts' >&2
assert_resource_present Service control-plane
assert_resource_present Service garage-s3
assert_resource_present Deployment garage-s3
assert_resource_present Job garage-bootstrap
assert_resource_contains Service garage-s3 'port: 3900'
assert_resource_contains Service garage-s3 'targetPort: s3'
assert_resource_contains Service garage-s3 'app.kubernetes.io/name: garage-s3'
assert_resource_contains Service garage-s3 'port: 3903'
assert_resource_contains Service garage-s3 'targetPort: admin'
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
assert_deployment_contains 'mountPath: /var/run/garage-sccache-auth'
assert_deployment_contains 'secretName: garage-sccache-auth'
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
assert_deployment_absent 'mountPath: /var/run/sccache-dist-auth-client'
assert_deployment_absent 'mountPath: /var/run/sccache-dist-auth-server'
assert_deployment_absent '/usr/local/bin/sccache-dist-entrypoint'
assert_resource_absent Secret sccache-dist-auth
assert_resource_absent Service sccache-dist
assert_resource_absent Deployment sccache-dist
assert_resource_absent ConfigMap garage-bootstrap
assert_resource_contains Deployment garage-s3 'claimName: control-plane-sccache-pvc'
assert_resource_contains Deployment garage-s3 'name: init-garage-config'
assert_resource_contains Deployment garage-s3 'mountPath: /garage-config'
assert_resource_contains Deployment garage-s3 'image: dxflrs/garage:v2.2.0'
assert_resource_contains Deployment garage-s3 'mountPath: /etc/garage'
assert_resource_contains Deployment garage-s3 'containerPort: 3903'
assert_resource_contains Deployment garage-s3 'name: admin'
assert_resource_contains Deployment garage-s3 'mountPath: /var/lib/garage'
assert_resource_contains Deployment garage-s3 'mountPath: /var/run/garage-admin-auth'
assert_resource_contains Deployment garage-s3 'defaultMode: 384'
assert_resource_contains Deployment garage-s3 'fieldPath: status.podIP'
assert_resource_not_contains Deployment garage-s3 'GARAGE_ALLOW_WORLD_READABLE_SECRETS'
assert_resource_not_contains Deployment garage-s3 'ghcr.io/chalharu/copilot-sandbox-container/garage'
assert_resource_not_contains Deployment garage-s3 'name: garage-bootstrap'
assert_resource_not_contains Deployment garage-s3 'mountPath: /var/run/garage-sccache-auth'
assert_resource_not_contains Deployment garage-s3 'mountPath: /var/run/garage-bootstrap'
assert_resource_not_contains Deployment garage-s3 'kubernetes.io/arch: amd64'
assert_resource_not_contains Service garage-s3 'name: garage-admin'
assert_resource_absent Service garage-admin
assert_resource_contains Job garage-bootstrap 'image: ghcr.io/chalharu/copilot-sandbox-container/control-plane:replace-me-with-commit-sha'
assert_resource_contains Job garage-bootstrap '/usr/local/bin/garage-bootstrap.mjs'
assert_resource_contains Job garage-bootstrap 'restartPolicy: OnFailure'
assert_resource_contains Job garage-bootstrap 'backoffLimit: 6'
assert_resource_contains Job garage-bootstrap 'serviceAccountName: garage-bootstrap'
assert_resource_contains Job garage-bootstrap 'automountServiceAccountToken: true'
assert_resource_contains Job garage-bootstrap 'http://garage-s3.copilot-sandbox.svc.cluster.local:3903'
assert_resource_contains Job garage-bootstrap 'http://garage-s3.copilot-sandbox.svc.cluster.local:3900'
assert_resource_contains Job garage-bootstrap 'mountPath: /var/run/garage-admin-auth'
assert_resource_contains Job garage-bootstrap 'GARAGE_CACHE_QUOTA_BYTES'
assert_resource_contains Job garage-bootstrap 'GARAGE_CACHE_EXPIRATION_DAYS'
assert_resource_contains Job garage-bootstrap 'GARAGE_S3_AUTH_SECRET_NAME'
assert_resource_contains Job garage-bootstrap 'fieldPath: metadata.namespace'
assert_resource_not_contains Job garage-bootstrap 'AWS_ACCESS_KEY_ID_FILE'
assert_resource_not_contains Job garage-bootstrap 'AWS_SECRET_ACCESS_KEY_FILE'
assert_resource_not_contains Job garage-bootstrap 'mountPath: /var/run/garage-sccache-auth'
assert_resource_not_contains Job garage-bootstrap 'defaultMode: 384'

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
if grep -Fq 'SCCACHE_DIST_' "${manifest_path}"; then
  printf 'Expected sample manifest to stop using sccache-dist runtime wiring\n' >&2
  exit 1
fi
if grep -Fq 'control-plane-local-storage' "${manifest_path}"; then
  printf 'Expected sample manifest to stop depending on the bespoke local-storage class\n' >&2
  exit 1
fi

printf '%s\n' 'k8s-sample-storage-layout-test: sample manifest ok' >&2
