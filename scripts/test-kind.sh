#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
control_plane_image="${1:?usage: scripts/test-kind.sh <control-plane-image> [cluster-name]}"
cluster_name="${2:-control-plane-ci}"
namespace="${CONTROL_PLANE_TEST_NAMESPACE:-control-plane-ci}"
job_namespace="${CONTROL_PLANE_TEST_JOB_NAMESPACE:-${namespace}-jobs}"
kind_provider="${KIND_EXPERIMENTAL_PROVIDER:-docker}"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-${kind_provider}}"
control_plane_selector="app.kubernetes.io/name=control-plane,app.kubernetes.io/component=acp"
control_plane_web_selector="app.kubernetes.io/name=control-plane,app.kubernetes.io/component=web"
kind_image_archive="${CONTROL_PLANE_KIND_IMAGE_ARCHIVE:-}"
kind_required_host_path="${CONTROL_PLANE_KIND_REQUIRED_HOST_PATH:-/lib/modules}"
workdir="$(mktemp -d)"
ssh_key="${workdir}/id_ed25519"
kubeconfig_path="${workdir}/kubeconfig"
rust_hook_image="${CONTROL_PLANE_TEST_RUST_HOOK_IMAGE:-docker.io/library/rust:1.94.1-bookworm@sha256:fdb91abf3cb33f1ebc84a76461d2472fd8cf606df69c181050fa7474bade2895}"
fast_execution_image="${CONTROL_PLANE_TEST_FAST_EXECUTION_IMAGE:-docker.io/library/ubuntu:24.04}"
fast_execution_image_pull_policy="${CONTROL_PLANE_TEST_FAST_EXECUTION_IMAGE_PULL_POLICY:-IfNotPresent}"
created_cluster=0
kind_uses_sudo=0
kind_sudo_mode="${CONTROL_PLANE_KIND_SUDO_MODE:-auto}"
kind_test_group="${CONTROL_PLANE_KIND_TEST_GROUP:-all}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

kind_cmd() {
  if [[ "${kind_uses_sudo}" -eq 1 ]]; then
    sudo -n env KIND_EXPERIMENTAL_PROVIDER="${kind_provider}" kind "$@"
  else
    kind "$@"
  fi
}

refresh_kubeconfig() {
  if [[ "${kind_uses_sudo}" -eq 1 ]]; then
    rm -f "${kubeconfig_path}"
    kind_cmd export kubeconfig --name "${cluster_name}" --kubeconfig "${kubeconfig_path}" >/dev/null
    sudo chown "$(id -u):$(id -g)" "${kubeconfig_path}" >/dev/null 2>&1 || true
    export KUBECONFIG="${kubeconfig_path}"
  else
    unset KUBECONFIG || true
  fi
}

enable_kind_sudo() {
  require_command sudo
  sudo -n true >/dev/null 2>&1 || {
    printf 'Passwordless sudo is required for Kind fallback in this environment\n' >&2
    exit 1
  }
  kind_uses_sudo=1
}

create_cluster() {
  local create_log="${workdir}/kind-create.log"

  if [[ ! -d "${kind_required_host_path}" ]]; then
    printf 'Skipping Kind cluster tests: required host path is unavailable: %s\n' "${kind_required_host_path}" >&2
    return 2
  fi

  if kind_cmd create cluster --name "${cluster_name}" >"${create_log}" 2>&1; then
    cat "${create_log}"
    return 0
  fi

  cat "${create_log}" >&2

  if [[ "${kind_uses_sudo}" -eq 1 ]] || [[ "${kind_sudo_mode}" == "never" ]]; then
    return 1
  fi

  if ! grep -Eq 'could not find a log line that matches|Failed to allocate manager object|Failed to create /init.scope control group|Error during unshare\(\.\.\.\): Operation not permitted' "${create_log}"; then
    return 1
  fi

  enable_kind_sudo
  kind delete cluster --name "${cluster_name}" >/dev/null 2>&1 || true

  if kind_cmd get clusters | grep -qx "${cluster_name}"; then
    return 0
  fi

  if kind_cmd create cluster --name "${cluster_name}" >"${create_log}" 2>&1; then
    cat "${create_log}"
    return 0
  fi

  cat "${create_log}" >&2
  return 1
}

ssh_cmd() {
  kubectl exec --namespace "${namespace}" "$(control_plane_pod_name)" -c control-plane -- \
    su -s /bin/bash copilot -c "$*"
}

ssh_bash() {
  kubectl exec -i --namespace "${namespace}" "$(control_plane_pod_name)" -c control-plane -- \
    su -s /bin/bash copilot -c 'bash -l -se'
}

wait_for_ssh() {
  local _
  for _ in $(seq 1 60); do
    if kubectl exec --namespace "${namespace}" "$(control_plane_pod_name)" -c control-plane -- \
      su -s /bin/bash copilot -c true >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  printf '%s\n' 'Timed out waiting for control-plane exec access\n' >&2
  dump_control_plane_diagnostics
  exit 1
}

wait_for_remote_grep() {
  local remote_pattern="$1"
  local remote_path="$2"
  local attempts="${3:-15}"
  local remote_command
  local _

  printf -v remote_command 'REMOTE_PATTERN=%q REMOTE_PATH=%q bash -l -se' \
    "${remote_pattern}" "${remote_path}"

  for _ in $(seq 1 "${attempts}"); do
    if kubectl exec -i --namespace "${namespace}" "$(control_plane_pod_name)" -c control-plane -- \
      su -s /bin/bash copilot -c "${remote_command}" <<'EOF' >/dev/null 2>&1
set -euo pipefail
grep -Eq -- "${REMOTE_PATTERN}" "${REMOTE_PATH}"
EOF
    then
      return 0
    fi
    sleep 1
  done

  return 1
}

ssh_host_fingerprint() {
  local fingerprint

  fingerprint="$(
    kubectl exec --namespace "${namespace}" "$(control_plane_pod_name)" -c control-plane -- \
      bash -lc "sha256sum /run/control-plane/ssh-host-keys/ssh_host_ed25519_key.pub | cut -d' ' -f1"
  )"
  [[ -n "${fingerprint}" ]] || {
    printf '%s\n' 'Unable to read control-plane SSH host key fingerprint' >&2
    exit 1
  }

  printf '%s\n' "${fingerprint}"
}

stop_port_forward() {
  :
}

start_port_forward() {
  :
}

control_plane_pod_name() {
  kubectl get pods --namespace "${namespace}" -l "${control_plane_selector}" -o jsonpath='{.items[0].metadata.name}'
}

control_plane_web_pod_name() {
  kubectl get pods --namespace "${namespace}" -l "${control_plane_web_selector}" -o jsonpath='{.items[0].metadata.name}'
}

dump_control_plane_diagnostics() {
  local pod_name=""
  local exec_pod=""
  local web_pod=""

  kubectl get deployment,replicaset,pods,svc --namespace "${namespace}" -l "${control_plane_selector}" -o wide >&2 || true
  kubectl get deployment,replicaset,pods,svc --namespace "${namespace}" -l "${control_plane_web_selector}" -o wide >&2 || true
  kubectl describe deployment/control-plane --namespace "${namespace}" >&2 || true
  kubectl describe deployment/control-plane-web --namespace "${namespace}" >&2 || true
  pod_name="$(control_plane_pod_name 2>/dev/null || true)"
  if [[ -n "${pod_name}" ]]; then
    kubectl describe pod/"${pod_name}" --namespace "${namespace}" >&2 || true
    kubectl logs --namespace "${namespace}" pod/"${pod_name}" -c init-state-dirs >&2 || true
    kubectl logs --namespace "${namespace}" pod/"${pod_name}" -c init-state >&2 || true
    kubectl logs --namespace "${namespace}" pod/"${pod_name}" -c control-plane >&2 || true
  fi
  web_pod="$(control_plane_web_pod_name 2>/dev/null || true)"
  if [[ -n "${web_pod}" ]]; then
    kubectl describe pod/"${web_pod}" --namespace "${namespace}" >&2 || true
    kubectl logs --namespace "${namespace}" pod/"${web_pod}" -c init-state-dirs >&2 || true
    kubectl logs --namespace "${namespace}" pod/"${web_pod}" -c init-state >&2 || true
    kubectl logs --namespace "${namespace}" pod/"${web_pod}" -c control-plane-web >&2 || true
  fi
  while read -r exec_pod; do
    [[ -n "${exec_pod}" ]] || continue
    kubectl describe "${exec_pod}" --namespace "${namespace}" >&2 || true
    kubectl logs --namespace "${namespace}" "${exec_pod}" -c bootstrap-assets >&2 || true
    kubectl logs --namespace "${namespace}" "${exec_pod}" -c execution >&2 || true
    kubectl logs --namespace "${namespace}" "${exec_pod}" -c execution --previous >&2 || true
  done < <(
    kubectl get pods \
      --namespace "${namespace}" \
      -l app.kubernetes.io/name=control-plane-fast-exec \
      -o name 2>/dev/null || true
  )
  kubectl get events --namespace "${namespace}" --sort-by=.lastTimestamp >&2 || true
}

wait_for_control_plane_pod() {
  if kubectl rollout status --namespace "${namespace}" deployment/control-plane --timeout=180s >/dev/null \
    && kubectl wait --namespace "${namespace}" --for=condition=Ready pod -l "${control_plane_selector}" --timeout=180s >/dev/null \
    && kubectl rollout status --namespace "${namespace}" deployment/control-plane-web --timeout=180s >/dev/null \
    && kubectl wait --namespace "${namespace}" --for=condition=Ready pod -l "${control_plane_web_selector}" --timeout=180s >/dev/null; then
    return 0
  fi

  dump_control_plane_diagnostics
  return 1
}

assert_control_plane_probe_spec() {
  local deployment_json="${workdir}/control-plane-deployment.json"
  local web_deployment_json="${workdir}/control-plane-web-deployment.json"
  local expected_acp_probe="bash -lc :</dev/tcp/127.0.0.1/\${CONTROL_PLANE_ACP_PORT:-3000}"

  kubectl get deployment/control-plane --namespace "${namespace}" -o json > "${deployment_json}"
  test "$(jq -r '.spec.template.spec.containers[] | select(.name == "control-plane").readinessProbe.exec.command | join(" ")' "${deployment_json}")" = "${expected_acp_probe}"
  test "$(jq -r '.spec.template.spec.containers[] | select(.name == "control-plane").livenessProbe.exec.command | join(" ")' "${deployment_json}")" = "${expected_acp_probe}"
  kubectl get deployment/control-plane-web --namespace "${namespace}" -o json > "${web_deployment_json}"
  test "$(jq -r '.spec.template.spec.containers[] | select(.name == "control-plane-web").readinessProbe.httpGet.path' "${web_deployment_json}")" = "/healthz"
  test "$(jq -r '.spec.template.spec.containers[] | select(.name == "control-plane-web").livenessProbe.httpGet.path' "${web_deployment_json}")" = "/healthz"
}

load_kind_images() {
  local helper_args=(--cluster-name "${cluster_name}")

  if [[ -n "${kind_image_archive}" ]]; then
    helper_args+=(--image-archive "${kind_image_archive}")
  else
    helper_args+=(--container-bin "${container_bin}" --image "${control_plane_image}")
  fi

  CONTROL_PLANE_KIND_USE_SUDO="${kind_uses_sudo}" \
    KIND_EXPERIMENTAL_PROVIDER="${kind_provider}" \
    "${script_dir}/load-kind-images.sh" "${helper_args[@]}"
}

apply_resources() {
  local public_key
  local environment_pvc_name
  public_key="$(cat "${ssh_key}.pub")"
  environment_pvc_name="node-workspace-${cluster_name}-control-plane"
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${namespace}
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${job_namespace}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: control-plane
  namespace: ${namespace}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: control-plane-exec
  namespace: ${namespace}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: control-plane-job
  namespace: ${job_namespace}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: control-plane-exec-pods
  namespace: ${namespace}
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["create", "delete", "get", "list", "watch"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["create", "get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: control-plane-exec-pods
  namespace: ${namespace}
subjects:
  - kind: ServiceAccount
    name: control-plane
    namespace: ${namespace}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: control-plane-exec-pods
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: control-plane-jobs
  namespace: ${job_namespace}
rules:
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["create", "delete", "get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["secrets", "configmaps"]
    verbs: ["create", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: control-plane-jobs
  namespace: ${job_namespace}
subjects:
  - kind: ServiceAccount
    name: control-plane
    namespace: ${namespace}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: control-plane-jobs
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: control-plane-exec-workloads
  namespace: ${job_namespace}
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["create", "delete", "get", "list", "patch", "watch"]
  - apiGroups: [""]
    resources: ["services"]
    verbs: ["create", "delete", "get", "list", "patch", "watch"]
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["create", "delete", "get", "list", "patch", "watch"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["create", "delete", "get", "list", "patch", "watch"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: control-plane-exec-workloads
  namespace: ${job_namespace}
subjects:
  - kind: ServiceAccount
    name: control-plane-exec
    namespace: ${namespace}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: control-plane-exec-workloads
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: control-plane-job-self-read
  namespace: ${job_namespace}
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: control-plane-job-self-read
  namespace: ${job_namespace}
subjects:
  - kind: ServiceAccount
    name: control-plane-job
    namespace: ${job_namespace}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: control-plane-job-self-read
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: control-plane-copilot-session-pv
spec:
  capacity:
    storage: 2Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Delete
  storageClassName: control-plane-copilot-session-manual
  hostPath:
    path: /var/lib/control-plane-copilot-session
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: control-plane-workspace-control-pv
spec:
  capacity:
    storage: 2Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete
  storageClassName: control-plane-control-workspace-manual
  hostPath:
    # Kind nodes can mount /tmp with noexec, which breaks running cached shells,
    # package managers, and workspace scripts from hostPath-backed volumes.
    path: /var/lib/control-plane-workspace
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: control-plane-copilot-session-pvc
  namespace: ${namespace}
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 2Gi
  storageClassName: control-plane-copilot-session-manual
  volumeName: control-plane-copilot-session-pv
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: control-plane-workspace-pvc
  namespace: ${namespace}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
  storageClassName: control-plane-control-workspace-manual
  volumeName: control-plane-workspace-control-pv
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: control-plane-workspace-job-pv
spec:
  capacity:
    storage: 2Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete
  storageClassName: control-plane-job-workspace-manual
  # Intentionally use the same hostPath as the control-plane workspace PV so
  # the Kind test can simulate a shared RW filesystem across namespaces.
  hostPath:
    path: /var/lib/control-plane-workspace
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: control-plane-fast-exec-environment-pv
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete
  storageClassName: control-plane-fast-exec-environment-manual
  claimRef:
    name: ${environment_pvc_name}
    namespace: ${namespace}
  hostPath:
    path: /var/lib/control-plane-fast-exec-environment
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: control-plane-workspace-pvc
  namespace: ${job_namespace}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
  storageClassName: control-plane-job-workspace-manual
  volumeName: control-plane-workspace-job-pv
---
apiVersion: v1
kind: Secret
metadata:
  name: control-plane-auth
  namespace: ${namespace}
type: Opaque
stringData:
  ssh-public-key: |
    ${public_key}
  gh-hosts.yml: |
    github.com:
      oauth_token: kind-secret-hosts-token
      git_protocol: ssh
      user: kind-bot
  gh-github-token: kind-secret-token-fallback
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: control-plane-config
  namespace: ${namespace}
data:
  copilot-config.json: |
    {
      "features": {
        "persisted": false,
        "overlayOnly": true
      },
      "nested": {
        "replace": {
          "fromOverlay": true
        },
        "array": [
          "overlay"
        ]
      },
      "topLevelOverlay": "kind"
    }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: control-plane-env
  namespace: ${namespace}
data:
  SSH_PUBLIC_KEY_FILE: /var/run/control-plane-auth/ssh-public-key
  COPILOT_CONFIG_JSON_FILE: /var/run/control-plane-config/copilot-config.json
  GH_HOSTS_YML_FILE: /var/run/control-plane-auth/gh-hosts.yml
  GH_GITHUB_TOKEN_FILE: /var/run/control-plane-auth/gh-github-token
  CONTROL_PLANE_K8S_NAMESPACE: ${namespace}
  CONTROL_PLANE_JOB_NAMESPACE: ${job_namespace}
  CONTROL_PLANE_COPILOT_SESSION_PVC: control-plane-copilot-session-pvc
  CONTROL_PLANE_COPILOT_SESSION_GH_SUBPATH: state/gh
  CONTROL_PLANE_COPILOT_SESSION_SSH_SUBPATH: state/ssh
  CONTROL_PLANE_WORKSPACE_PVC: control-plane-workspace-pvc
  CONTROL_PLANE_WORKSPACE_SUBPATH: workspace
  CONTROL_PLANE_FAST_EXECUTION_ENABLED: "1"
  CONTROL_PLANE_FAST_EXECUTION_IMAGE: ${fast_execution_image}
  CONTROL_PLANE_FAST_EXECUTION_IMAGE_PULL_POLICY: ${fast_execution_image_pull_policy}
  CONTROL_PLANE_FAST_EXECUTION_BOOTSTRAP_IMAGE: ${control_plane_image}
  CONTROL_PLANE_FAST_EXECUTION_BOOTSTRAP_IMAGE_PULL_POLICY: Never
  CONTROL_PLANE_FAST_EXECUTION_START_TIMEOUT: 300s
  CONTROL_PLANE_FAST_EXECUTION_PORT: "8080"
  CONTROL_PLANE_FAST_EXECUTION_HOME: /root
  CONTROL_PLANE_FAST_EXECUTION_SERVICE_ACCOUNT: control-plane-exec
  CONTROL_PLANE_FAST_EXECUTION_STARTUP_SCRIPT: 'printf "fast-exec-startup\n" > /workspace/fast-exec-startup-marker.txt'
  CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_PVC_PREFIX: node-workspace
  CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_STORAGE_CLASS: control-plane-fast-exec-environment-manual
  CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_SIZE: 10Gi
  CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_MOUNT_PATH: /environment
  CONTROL_PLANE_FAST_EXECUTION_CPU_REQUEST: 250m
  CONTROL_PLANE_FAST_EXECUTION_CPU_LIMIT: "1"
  CONTROL_PLANE_FAST_EXECUTION_MEMORY_REQUEST: 256Mi
  CONTROL_PLANE_FAST_EXECUTION_MEMORY_LIMIT: 1Gi
  CONTROL_PLANE_FAST_EXECUTION_REQUEST_TIMEOUT_SEC: "3600"
  CONTROL_PLANE_ACP_HOST: control-plane.${namespace}.svc.cluster.local
  CONTROL_PLANE_ACP_PORT: "3000"
  CONTROL_PLANE_WEB_PORT: "8080"
  CONTROL_PLANE_JOB_WORKSPACE_PVC: control-plane-workspace-pvc
  CONTROL_PLANE_JOB_WORKSPACE_SUBPATH: workspace
  CONTROL_PLANE_JOB_SERVICE_ACCOUNT: control-plane-job
  CONTROL_PLANE_JOB_TRANSFER_IMAGE: ${control_plane_image}
  CONTROL_PLANE_JOB_TRANSFER_ROOT: /home/copilot/.copilot/session-state/job-transfers
  CONTROL_PLANE_JOB_TRANSFER_HOST: control-plane-web.${namespace}.svc.cluster.local
  CONTROL_PLANE_JOB_TRANSFER_PORT: "8080"
  CONTROL_PLANE_RUST_HOOK_IMAGE: ${rust_hook_image}
  CONTROL_PLANE_JOB_IMAGE_PULL_POLICY: Never
---
apiVersion: v1
kind: Service
metadata:
  name: control-plane
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: control-plane
    app.kubernetes.io/component: acp
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: control-plane
    app.kubernetes.io/component: acp
  ports:
    - name: acp
      port: 3000
      targetPort: acp
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: control-plane
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: control-plane
    app.kubernetes.io/component: acp
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: control-plane
      app.kubernetes.io/component: acp
  template:
    metadata:
      labels:
        app.kubernetes.io/name: control-plane
        app.kubernetes.io/component: acp
    spec:
      securityContext:
        fsGroup: 1000
      serviceAccountName: control-plane
      initContainers:
        - name: init-state-dirs
          # renovate: datasource=docker depName=busybox versioning=docker
          image: busybox:1.37.0@sha256:1487d0af5f52b4ba31c7e465126ee2123fe3f2305d638e7827681e7cf6c83d5e
          command:
            - sh
            - -c
            - |
              set -eu
              umask 077
              mkdir -p \
                /copilot-session/state/gh \
                /copilot-session/state/ssh-auth \
                /copilot-session/state/ssh \
                /copilot-session/state/ssh-host-keys \
                /copilot-session/session-state \
                /workspace-state/workspace \
                /cache/runtime-tmp
              touch \
                /copilot-session/state/copilot-config.json \
                /copilot-session/state/command-history-state.json
              chown -R 1000:1000 /copilot-session/state /copilot-session/session-state
              find /copilot-session/state /copilot-session/session-state -type d -exec chmod 700 {} +
              find /copilot-session/state /copilot-session/session-state -type f -exec chmod 600 {} +
              # Preserve user workspace file modes; only hand the shared mount root
              # back to UID/GID 1000 so the control-plane session can use it.
              chown 1000:1000 /workspace-state/workspace
              chmod 700 /workspace-state/workspace
              # Keep the shared tmp/cache root traversable for the copilot user.
              chown 0:1000 /cache/runtime-tmp
              chmod 755 /cache/runtime-tmp
          securityContext:
            privileged: false
            # Fresh PVC roots start out owned by root, so create the shared
            # top-level directories before handing file seeding to UID 1000.
            runAsUser: 0
            runAsGroup: 1000
            runAsNonRoot: false
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
              add:
                - CHOWN
                - DAC_OVERRIDE
                - FOWNER
            seccompProfile:
              type: RuntimeDefault
          volumeMounts:
            - name: copilot-session
              mountPath: /copilot-session
            - name: workspace
              mountPath: /workspace-state
            - name: cache
              mountPath: /cache
        - name: init-state
          # renovate: datasource=docker depName=busybox versioning=docker
          image: busybox:1.37.0@sha256:1487d0af5f52b4ba31c7e465126ee2123fe3f2305d638e7827681e7cf6c83d5e
          command:
            - sh
            - -c
            - |
              set -eu
              umask 077
              # Keep the Kind fixture aligned with the shipped manifests. The
              # deeper merge behavior is covered in test-config-injection.sh.
              [ -s /state/copilot-config.json ] || cat > /state/copilot-config.json <<'JSON'
              {
                "telemetry": false
              }
              JSON
              [ -f /state/gh/hosts.yml ] || cat > /state/gh/hosts.yml <<'YAML'
              github.com:
                oauth_token: stale-kind-token
                git_protocol: https
              YAML
          securityContext:
            privileged: false
            runAsUser: 1000
            runAsGroup: 1000
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            seccompProfile:
              type: RuntimeDefault
          volumeMounts:
            - name: copilot-session
              mountPath: /state
              subPath: state
      containers:
        - name: control-plane
          image: ${control_plane_image}
          imagePullPolicy: Never
          envFrom:
            - configMapRef:
                name: control-plane-env
          env:
            - name: CONTROL_PLANE_POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: CONTROL_PLANE_POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: CONTROL_PLANE_POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            - name: CONTROL_PLANE_POD_UID
              valueFrom:
                fieldRef:
                  fieldPath: metadata.uid
            - name: CONTROL_PLANE_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          args:
            - /usr/local/bin/control-plane-copilot
          securityContext:
            privileged: false
            runAsUser: 0
            runAsNonRoot: false
            allowPrivilegeEscalation: true
            capabilities:
              drop:
                - ALL
              add:
                - CHOWN
                - DAC_OVERRIDE
                - FOWNER
                - KILL
                - SETGID
                - SETUID
            seccompProfile:
              type: RuntimeDefault
          ports:
            - containerPort: 3000
              name: acp
          readinessProbe:
            exec:
              command:
                - bash
                - -lc
                - ":</dev/tcp/127.0.0.1/\${CONTROL_PLANE_ACP_PORT:-3000}"
            periodSeconds: 5
            failureThreshold: 12
          livenessProbe:
            exec:
              command:
                - bash
                - -lc
                - ":</dev/tcp/127.0.0.1/\${CONTROL_PLANE_ACP_PORT:-3000}"
            initialDelaySeconds: 10
            periodSeconds: 10
            failureThreshold: 6
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 1Gi
          volumeMounts:
            - name: copilot-session
              mountPath: /home/copilot/.copilot/config.json
              subPath: state/copilot-config.json
            - name: copilot-session
              mountPath: /home/copilot/.copilot/command-history-state.json
              subPath: state/command-history-state.json
            - name: copilot-session
              mountPath: /home/copilot/.copilot/session-state
              subPath: session-state
            - name: copilot-session
              mountPath: /home/copilot/.config/gh
              subPath: state/gh
            - name: copilot-session
              mountPath: /home/copilot/.ssh
              subPath: state/ssh
            - name: copilot-session
              mountPath: /home/copilot/.config/control-plane/ssh-auth
              subPath: state/ssh-auth
            - name: copilot-session
              mountPath: /var/lib/control-plane/ssh-host-keys
              subPath: state/ssh-host-keys
            - name: workspace
              mountPath: /workspace
              subPath: workspace
            - name: cache
              mountPath: /var/tmp/control-plane
              subPath: runtime-tmp
            - name: control-plane-auth
              mountPath: /var/run/control-plane-auth
              readOnly: true
            - name: control-plane-config
              mountPath: /var/run/control-plane-config
              readOnly: true
      volumes:
        - name: copilot-session
          persistentVolumeClaim:
            claimName: control-plane-copilot-session-pvc
        - name: workspace
          persistentVolumeClaim:
            claimName: control-plane-workspace-pvc
        - name: cache
          emptyDir: {}
        - name: control-plane-auth
          secret:
            secretName: control-plane-auth
        - name: control-plane-config
          configMap:
            name: control-plane-config
---
apiVersion: v1
kind: Service
metadata:
  name: control-plane-web
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: control-plane
    app.kubernetes.io/component: web
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: control-plane
    app.kubernetes.io/component: web
  ports:
    - name: http
      port: 8080
      targetPort: http
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: control-plane-web
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: control-plane
    app.kubernetes.io/component: web
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: control-plane
      app.kubernetes.io/component: web
  template:
    metadata:
      labels:
        app.kubernetes.io/name: control-plane
        app.kubernetes.io/component: web
    spec:
      securityContext:
        fsGroup: 1000
      serviceAccountName: control-plane
      initContainers:
        - name: init-state-dirs
          # renovate: datasource=docker depName=busybox versioning=docker
          image: busybox:1.37.0@sha256:b3255e7dfbcd10cb367af0d409747d511aeb66dfac98cf30e97e87e4207dd76f
          command:
            - sh
            - -c
            - |
              set -eu
              umask 077
              mkdir -p \
                /copilot-session/state/gh \
                /copilot-session/state/ssh-auth \
                /copilot-session/state/ssh \
                /copilot-session/state/ssh-host-keys \
                /copilot-session/session-state \
                /workspace-state/workspace \
                /cache/runtime-tmp
              touch \
                /copilot-session/state/copilot-config.json \
                /copilot-session/state/command-history-state.json
              chown -R 1000:1000 /copilot-session/state /copilot-session/session-state
              find /copilot-session/state /copilot-session/session-state -type d -exec chmod 700 {} +
              find /copilot-session/state /copilot-session/session-state -type f -exec chmod 600 {} +
              chown 1000:1000 /workspace-state/workspace
              chmod 700 /workspace-state/workspace
              chown 0:1000 /cache/runtime-tmp
              chmod 755 /cache/runtime-tmp
          securityContext:
            privileged: false
            runAsUser: 0
            runAsGroup: 1000
            runAsNonRoot: false
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
              add:
                - CHOWN
                - DAC_OVERRIDE
                - FOWNER
            seccompProfile:
              type: RuntimeDefault
          volumeMounts:
            - name: copilot-session
              mountPath: /copilot-session
            - name: workspace
              mountPath: /workspace-state
            - name: cache
              mountPath: /cache
        - name: init-state
          # renovate: datasource=docker depName=busybox versioning=docker
          image: busybox:1.37.0@sha256:b3255e7dfbcd10cb367af0d409747d511aeb66dfac98cf30e97e87e4207dd76f
          command:
            - sh
            - -c
            - |
              set -eu
              umask 077
              [ -s /state/copilot-config.json ] || cat > /state/copilot-config.json <<'JSON'
              {
                "telemetry": false
              }
              JSON
          securityContext:
            privileged: false
            runAsUser: 1000
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            seccompProfile:
              type: RuntimeDefault
          volumeMounts:
            - name: copilot-session
              mountPath: /state
              subPath: state
      containers:
        - name: control-plane-web
          image: ${control_plane_image}
          imagePullPolicy: Never
          envFrom:
            - configMapRef:
                name: control-plane-env
          env:
            - name: CONTROL_PLANE_FAST_EXECUTION_ENABLED
              value: "0"
          args:
            - /usr/local/bin/control-plane-web-backend
          securityContext:
            privileged: false
            runAsUser: 0
            runAsNonRoot: false
            allowPrivilegeEscalation: true
            capabilities:
              drop:
                - ALL
              add:
                - CHOWN
                - DAC_OVERRIDE
                - FOWNER
                - KILL
                - SETGID
                - SETUID
            seccompProfile:
              type: RuntimeDefault
          ports:
            - containerPort: 8080
              name: http
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 5
            failureThreshold: 12
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
            failureThreshold: 6
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: "2"
              memory: 2Gi
          volumeMounts:
            - name: copilot-session
              mountPath: /home/copilot/.copilot/config.json
              subPath: state/copilot-config.json
            - name: copilot-session
              mountPath: /home/copilot/.copilot/command-history-state.json
              subPath: state/command-history-state.json
            - name: copilot-session
              mountPath: /home/copilot/.copilot/session-state
              subPath: session-state
            - name: copilot-session
              mountPath: /home/copilot/.config/gh
              subPath: state/gh
            - name: copilot-session
              mountPath: /home/copilot/.ssh
              subPath: state/ssh
            - name: copilot-session
              mountPath: /home/copilot/.config/control-plane/ssh-auth
              subPath: state/ssh-auth
            - name: copilot-session
              mountPath: /var/lib/control-plane/ssh-host-keys
              subPath: state/ssh-host-keys
            - name: workspace
              mountPath: /workspace
              subPath: workspace
            - name: cache
              mountPath: /var/tmp/control-plane
              subPath: runtime-tmp
            - name: control-plane-auth
              mountPath: /var/run/control-plane-auth
              readOnly: true
            - name: control-plane-config
              mountPath: /var/run/control-plane-config
              readOnly: true
      volumes:
        - name: copilot-session
          persistentVolumeClaim:
            claimName: control-plane-copilot-session-pvc
        - name: workspace
          persistentVolumeClaim:
            claimName: control-plane-workspace-pvc
        - name: cache
          emptyDir: {}
        - name: control-plane-auth
          secret:
            secretName: control-plane-auth
        - name: control-plane-config
          configMap:
            name: control-plane-config
EOF
}

run_shared_remote_assertions() {
  if ! ssh_bash <<EOF
set -euo pipefail
command -v node
command -v npm
npm ls -g @github/copilot --depth=0 | grep -q '@github/copilot@'
command -v git
! command -v gh >/dev/null 2>&1
command -v kubectl
command -v k8s-job-start
command -v k8s-job-wait
command -v k8s-job-pod
command -v k8s-job-logs
command -v control-plane-copilot
command -v control-plane-run
command -v control-plane-job-transfer
command -v control-plane-exec-api
command -v control-plane-session-exec
command -v kind
command -v cargo
command -v yamllint
command -v sshd
command -v screen
! command -v cpulimit >/dev/null 2>&1
! command -v gcc >/dev/null 2>&1
! command -v pkg-config >/dev/null 2>&1
command -v vim
printf '%s\n' 'kind-test remote: command availability ok' >&2
printf '%s\n' "\${LANG}" | grep -qi 'utf-8'
printf '%s\n' 'kind-test remote: login env ok' >&2
test -f ~/.copilot/skills/repo-change-delivery/SKILL.md
test -f ~/.copilot/config.json
test -f ~/.copilot/command-history-state.json
test -d ~/.copilot/session-state
test -f ~/.config/gh/hosts.yml
test "\$(stat -c '%a %U %G' ~/.copilot/config.json)" = '600 copilot copilot'
test "\$(stat -c '%a %U %G' ~/.copilot/command-history-state.json)" = '600 copilot copilot'
test "\$(stat -c '%a %U %G' ~/.config/gh/hosts.yml)" = '600 copilot copilot'
printf '%s\n' 'kind-test remote: persisted files ok' >&2
# Copilot may stamp runtime metadata like firstLaunchAt back into the persisted
# config after startup, so the stable integration check here is the mounted
# config wiring. Deeper merge coverage lives in test-config-injection.sh.
copilot_config_source='/var/run/control-plane-config/copilot-config.json'
test -f "${copilot_config_source}"
jq -e 'type == "object"' ~/.copilot/config.json >/dev/null
jq -e '.features.persisted == false' "${copilot_config_source}" >/dev/null
jq -e '.features.overlayOnly == true' "${copilot_config_source}" >/dev/null
jq -e '.nested.replace.fromOverlay == true' "${copilot_config_source}" >/dev/null
jq -e '.nested.array == ["overlay"]' "${copilot_config_source}" >/dev/null
jq -e '.topLevelOverlay == "kind"' "${copilot_config_source}" >/dev/null
printf '%s\n' 'kind-test remote: config wiring ok' >&2
if cat ~/.config/gh/hosts.yml >/dev/null 2>&1; then
  printf '%s\n' 'expected direct ~/.config/gh/hosts.yml reads to be blocked by the exec policy' >&2
  exit 1
fi
env -u LD_PRELOAD grep -Fqx '  git_protocol: ssh' ~/.config/gh/hosts.yml
printf '%s\n' 'kind-test remote: gh hosts confinement ok' >&2
grep -Fqx 'CARGO_HOME=/home/copilot/.cargo' ~/.config/control-plane/runtime.env
grep -Fqx 'CARGO_TARGET_DIR=/var/tmp/control-plane/cargo-target' ~/.config/control-plane/runtime.env
grep -Fqx 'LANG=C.UTF-8' ~/.config/control-plane/runtime.env
grep -Fqx 'LC_CTYPE=C.UTF-8' ~/.config/control-plane/runtime.env
grep -Fqx "CONTROL_PLANE_RUST_HOOK_IMAGE=${rust_hook_image}" ~/.config/control-plane/runtime.env
grep -Fqx 'CONTROL_PLANE_FAST_EXECUTION_SERVICE_ACCOUNT=control-plane-exec' ~/.config/control-plane/runtime.env
grep -Fqx "CONTROL_PLANE_POST_TOOL_USE_FORWARD_ADDR=http://\${CONTROL_PLANE_POD_IP}:8081" ~/.config/control-plane/runtime.env
grep -Eq '^CONTROL_PLANE_POST_TOOL_USE_FORWARD_TOKEN=.+$' ~/.config/control-plane/runtime.env
grep -Fqx 'CONTROL_PLANE_POST_TOOL_USE_FORWARD_TIMEOUT_SEC=3600' ~/.config/control-plane/runtime.env
test -d /var/tmp/control-plane
test -d /var/tmp/control-plane/cargo-target
printf '%s\n' 'kind-test remote: runtime tmp ok' >&2
test "\${LANG}" = "C.UTF-8"
test "\${LC_CTYPE}" = "C.UTF-8"
test "\${CONTROL_PLANE_JOB_NAMESPACE}" = "${job_namespace}"
test -n "\${CONTROL_PLANE_POD_IP}"
test "\${CONTROL_PLANE_FAST_EXECUTION_ENABLED}" = "1"
test "\${CONTROL_PLANE_FAST_EXECUTION_IMAGE}" = "${fast_execution_image}"
test "\${CONTROL_PLANE_FAST_EXECUTION_BOOTSTRAP_IMAGE}" = "${control_plane_image}"
test "\${CONTROL_PLANE_FAST_EXECUTION_STARTUP_SCRIPT}" = 'printf "fast-exec-startup\n" > /workspace/fast-exec-startup-marker.txt'
test "\${CONTROL_PLANE_POST_TOOL_USE_FORWARD_ADDR}" = "http://\${CONTROL_PLANE_POD_IP}:8081"
test -n "\${CONTROL_PLANE_POST_TOOL_USE_FORWARD_TOKEN}"
test "\${CONTROL_PLANE_POST_TOOL_USE_FORWARD_TIMEOUT_SEC}" = "3600"
test "\${CONTROL_PLANE_COPILOT_SESSION_PVC}" = "control-plane-copilot-session-pvc"
test "\${CONTROL_PLANE_RUST_HOOK_IMAGE}" = "${rust_hook_image}"
cat /proc/self/uid_map > /workspace/k8s-pod-uid-map.txt
printf '%s\n' 'kind-test remote: runtime env and workspace write ok' >&2
EOF
  then
    ssh_bash <<'EOF' >&2 || true
set +e
printf '%s\n' '--- kind-test initial remote debug ---'
printf 'LANG=%s\n' "${LANG:-}" || true
printf '%s\n' '--- persisted files ---'
ls -ld ~/.copilot ~/.copilot/session-state ~/.config ~/.config/gh ~/.ssh /workspace || true
ls -l ~/.copilot/config.json ~/.copilot/command-history-state.json ~/.config/gh/hosts.yml || true
stat -c '%n %a %U %G' ~/.copilot/config.json ~/.copilot/command-history-state.json ~/.config/gh/hosts.yml || true
printf '%s\n' '--- config and gh auth ---'
cat ~/.copilot/config.json || true
printf 'COPILOT_CONFIG_JSON_FILE=%s\n' "${COPILOT_CONFIG_JSON_FILE:-}" || true
cat "${COPILOT_CONFIG_JSON_FILE:-/var/run/control-plane-config/copilot-config.json}" || true
printf '%s\n' 'direct reads of ~/.config/gh/hosts.yml are expected to fail under the exec policy'
printf '%s\n' '--- runtime tmp ---'
ls -la /var/tmp/control-plane || true
printf '%s\n' '--- runtime env ---'
printf 'CONTROL_PLANE_JOB_NAMESPACE=%s\n' "${CONTROL_PLANE_JOB_NAMESPACE:-}" || true
printf 'CONTROL_PLANE_FAST_EXECUTION_ENABLED=%s\n' "${CONTROL_PLANE_FAST_EXECUTION_ENABLED:-}" || true
printf 'CONTROL_PLANE_FAST_EXECUTION_IMAGE=%s\n' "${CONTROL_PLANE_FAST_EXECUTION_IMAGE:-}" || true
printf 'CONTROL_PLANE_FAST_EXECUTION_BOOTSTRAP_IMAGE=%s\n' "${CONTROL_PLANE_FAST_EXECUTION_BOOTSTRAP_IMAGE:-}" || true
printf 'CONTROL_PLANE_COPILOT_SESSION_PVC=%s\n' "${CONTROL_PLANE_COPILOT_SESSION_PVC:-}" || true
printf 'CONTROL_PLANE_RUST_HOOK_IMAGE=%s\n' "${CONTROL_PLANE_RUST_HOOK_IMAGE:-}" || true
cat /proc/self/uid_map || true
EOF
    dump_control_plane_diagnostics
    exit 1
  fi
  printf '%s\n' 'kind-test: initial remote assertions ok' >&2

  ssh_bash <<EOF
set -euo pipefail
set +e
jobs_access="\$(kubectl auth can-i create jobs --namespace ${job_namespace} 2>&1)"
jobs_status=\$?
set -e
if [[ "\${jobs_status}" -ne 0 ]] || [[ "\${jobs_access}" != "yes" ]]; then
  printf 'Expected control-plane service account to create jobs in namespace %s\n' "${job_namespace}" >&2
  printf 'kubectl auth can-i exit status: %s\n' "\${jobs_status}" >&2
  printf '%s\n' "\${jobs_access}" >&2
  kubectl config current-context >&2 || true
  exit 1
fi
set +e
secrets_access="\$(kubectl auth can-i create secrets --namespace ${job_namespace} 2>&1)"
secrets_status=\$?
set -e
if [[ "\${secrets_status}" -ne 0 ]] || [[ "\${secrets_access}" != "yes" ]]; then
  printf 'Expected control-plane service account to create secrets in namespace %s\n' "${job_namespace}" >&2
  printf 'kubectl auth can-i exit status: %s\n' "\${secrets_status}" >&2
  printf '%s\n' "\${secrets_access}" >&2
  kubectl config current-context >&2 || true
  exit 1
fi
set +e
configmaps_access="\$(kubectl auth can-i create configmaps --namespace ${job_namespace} 2>&1)"
configmaps_status=\$?
set -e
if [[ "\${configmaps_status}" -ne 0 ]] || [[ "\${configmaps_access}" != "yes" ]]; then
  printf 'Expected control-plane service account to create configmaps in namespace %s\n' "${job_namespace}" >&2
  printf 'kubectl auth can-i exit status: %s\n' "\${configmaps_status}" >&2
  printf '%s\n' "\${configmaps_access}" >&2
  kubectl config current-context >&2 || true
  exit 1
fi
set +e
pods_access="\$(kubectl auth can-i create pods --namespace ${namespace} 2>&1)"
pods_status=\$?
set -e
if [[ "\${pods_status}" -ne 0 ]] || [[ "\${pods_access}" != "yes" ]]; then
  printf 'Expected control-plane service account to create pods in namespace %s\n' "${namespace}" >&2
  printf 'kubectl auth can-i exit status: %s\n' "\${pods_status}" >&2
  printf '%s\n' "\${pods_access}" >&2
  kubectl config current-context >&2 || true
  exit 1
fi
set +e
pvcs_access="\$(kubectl auth can-i create persistentvolumeclaims --namespace ${namespace} 2>&1)"
pvcs_status=\$?
set -e
if [[ "\${pvcs_status}" -ne 0 ]] || [[ "\${pvcs_access}" != "yes" ]]; then
  printf 'Expected control-plane service account to create persistentvolumeclaims in namespace %s\n' "${namespace}" >&2
  printf 'kubectl auth can-i exit status: %s\n' "\${pvcs_status}" >&2
  printf '%s\n' "\${pvcs_access}" >&2
  kubectl config current-context >&2 || true
  exit 1
fi
EOF
  printf '%s\n' 'kind-test: rbac assertions ok' >&2

  utf8_roundtrip="$(ssh_bash <<'EOF'
set -euo pipefail
printf '日本語★\n'
EOF
)"
  [[ "${utf8_roundtrip}" == "日本語★" ]]
  printf '%s\n' 'kind-test: utf8 roundtrip ok' >&2
}

run_fast_exec_assertions() {
  printf '%s\n' 'kind-test: verifying fast execution pod flow' >&2
  if ! ssh_bash <<'EOF'
set -euo pipefail
session_key=kind-fast-exec
control-plane-session-exec cleanup --session-key "${session_key}" >/dev/null 2>&1 || true
rm -f /workspace/fast-exec-startup-marker.txt
rm -f /workspace/fast-exec-kubectl-marker.txt
control-plane-session-exec prepare --session-key "${session_key}" >/dev/null
jq -e --arg key "${session_key}" '.sessions[$key].podName != null and .sessions[$key].podIp != null' \
  ~/.copilot/session-state/session-exec.json >/dev/null
pod_name="$(jq -r --arg key "${session_key}" '.sessions[$key].podName' ~/.copilot/session-state/session-exec.json)"
pod_ip="$(jq -r --arg key "${session_key}" '.sessions[$key].podIp' ~/.copilot/session-state/session-exec.json)"
environment_pvc="$(jq -r --arg key "${session_key}" '.sessions[$key].environmentPvcName' ~/.copilot/session-state/session-exec.json)"
test -n "${pod_name}"
test -n "${pod_ip}"
test -n "${environment_pvc}"
test "$(cat /workspace/fast-exec-startup-marker.txt)" = "fast-exec-startup"
kubectl get pod --namespace "${CONTROL_PLANE_POD_NAMESPACE}" "${pod_name}" -o json > /workspace/k8s-fast-exec-pod.json
test "$(jq -r '.metadata.ownerReferences[0].kind' /workspace/k8s-fast-exec-pod.json)" = "Pod"
test "$(jq -r '.metadata.ownerReferences[0].name' /workspace/k8s-fast-exec-pod.json)" = "${CONTROL_PLANE_POD_NAME}"
test "$(jq -r '.metadata.ownerReferences[0].uid' /workspace/k8s-fast-exec-pod.json)" = "${CONTROL_PLANE_POD_UID}"
test "$(jq -r '.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchFields[] | select(.key == "metadata.name").values[0]' /workspace/k8s-fast-exec-pod.json)" = "${CONTROL_PLANE_NODE_NAME}"
test "$(jq -r '.spec.containers[0].image' /workspace/k8s-fast-exec-pod.json)" = "${CONTROL_PLANE_FAST_EXECUTION_IMAGE}"
test "$(jq -r '.spec.initContainers[0].image' /workspace/k8s-fast-exec-pod.json)" = "${CONTROL_PLANE_FAST_EXECUTION_BOOTSTRAP_IMAGE}"
test "$(jq -r '.spec.volumes[] | select(.name == "workspace").persistentVolumeClaim.claimName' /workspace/k8s-fast-exec-pod.json)" = "control-plane-workspace-pvc"
test "$(jq -r '.spec.volumes[] | select(.name == "copilot-session").persistentVolumeClaim.claimName' /workspace/k8s-fast-exec-pod.json)" = "control-plane-copilot-session-pvc"
test "$(jq -r '.spec.volumes[] | select(.name == "environment").persistentVolumeClaim.claimName' /workspace/k8s-fast-exec-pod.json)" = "${environment_pvc}"
test "$(jq -r '.spec.volumes[] | select(.name == "runtime-bin").emptyDir | type' /workspace/k8s-fast-exec-pod.json)" = "object"
test "$(jq -r '.spec.containers[0].command[0]' /workspace/k8s-fast-exec-pod.json)" = "/control-plane/bin/control-plane-exec-api"
test "$(jq -r '.spec.containers[0].startupProbe.grpc.port' /workspace/k8s-fast-exec-pod.json)" = "8080"
test "$(jq -r '.spec.containers[0].startupProbe.periodSeconds' /workspace/k8s-fast-exec-pod.json)" = "5"
test "$(jq -r '.spec.containers[0].startupProbe.failureThreshold' /workspace/k8s-fast-exec-pod.json)" = "62"
test "$(jq -r '.spec.serviceAccountName' /workspace/k8s-fast-exec-pod.json)" = "control-plane-exec"
test "$(jq -r '.spec.automountServiceAccountToken' /workspace/k8s-fast-exec-pod.json)" = "true"
test "$(jq -r '.spec.containers[0].volumeMounts[] | select(.name == "environment").mountPath' /workspace/k8s-fast-exec-pod.json)" = "/environment"
test "$(jq -r '.spec.containers[0].volumeMounts[] | select(.name == "runtime-bin").mountPath' /workspace/k8s-fast-exec-pod.json)" = "/control-plane/bin"
test "$(jq -r '.spec.containers[0].volumeMounts[] | select(.name == "workspace").mountPath' /workspace/k8s-fast-exec-pod.json)" = "/environment/root/workspace"
test "$(jq -r '.spec.containers[0].volumeMounts[] | select(.mountPath == "/environment/root/root/.config/gh") | (.readOnly // false)' /workspace/k8s-fast-exec-pod.json)" = "false"
test "$(jq -r '.spec.containers[0].volumeMounts[] | select(.mountPath == "/environment/root/root/.ssh") | (.readOnly // false)' /workspace/k8s-fast-exec-pod.json)" = "true"
test "$(jq -r '.spec.containers[0].env[] | select(.name == "CONTROL_PLANE_FAST_EXECUTION_CHROOT_ROOT").value' /workspace/k8s-fast-exec-pod.json)" = "/environment/root"
test "$(jq -r '.spec.containers[0].env[] | select(.name == "CONTROL_PLANE_JOB_NAMESPACE").value' /workspace/k8s-fast-exec-pod.json)" = "${CONTROL_PLANE_JOB_NAMESPACE}"
test "$(jq -r '.spec.containers[0].env[] | select(.name == "CONTROL_PLANE_FAST_EXECUTION_GIT_HOOKS_SOURCE").value' /workspace/k8s-fast-exec-pod.json)" = "/environment/hooks/git"
test "$(jq -r '.spec.containers[0].env[] | select(.name == "CONTROL_PLANE_POST_TOOL_USE_FORWARD_ADDR").value' /workspace/k8s-fast-exec-pod.json)" = "http://${CONTROL_PLANE_POD_IP}:8081"
test -n "$(jq -r '.spec.containers[0].env[] | select(.name == "CONTROL_PLANE_POST_TOOL_USE_FORWARD_TOKEN").value' /workspace/k8s-fast-exec-pod.json)"
test "$(jq -r '.spec.containers[0].env[] | select(.name == "CONTROL_PLANE_POST_TOOL_USE_FORWARD_TIMEOUT_SEC").value' /workspace/k8s-fast-exec-pod.json)" = "3600"
test "$(jq -r '.spec.containers[0].env[] | select(.name == "CONTROL_PLANE_FAST_EXECUTION_STARTUP_SCRIPT").value' /workspace/k8s-fast-exec-pod.json)" = 'printf "fast-exec-startup\n" > /workspace/fast-exec-startup-marker.txt'
test "$(jq -r '.spec.containers[0].env[] | select(.name == "HOME").value' /workspace/k8s-fast-exec-pod.json)" = "/root"
git_hook_command=$'rm -rf /workspace/fast-exec-git-hook-test-repo\nmkdir -p /workspace/fast-exec-git-hook-test-repo\ncd /workspace/fast-exec-git-hook-test-repo\ngit init >/dev/null\ngit checkout -b fast-exec-test >/dev/null 2>&1\ngit config user.name "Fast Exec Test"\ngit config user.email "fast-exec-test@example.com"\ngit config core.hooksPath /environment/hooks/git\ntest -x /root/.copilot/hooks/postToolUse/main\ngit commit --allow-empty -m "fast exec hook test" >/dev/null\ngit rev-parse --verify HEAD > /workspace/fast-exec-git-hook-commit.txt'
git_hook_command_base64="$(printf '%s' "${git_hook_command}" | base64 | tr -d '\n')"
control-plane-session-exec proxy --session-key "${session_key}" --cwd /workspace --command-base64 "${git_hook_command_base64}" >/dev/null
grep -Eq '^[0-9a-f]{40}$' /workspace/fast-exec-git-hook-commit.txt
hook_readonly_command=$'set -euo pipefail\ntest -x /root/.copilot/hooks/postToolUse/main\ntest -f /usr/local/share/control-plane/hooks/postToolUse/linters.json\nif printf tamper >> /root/.copilot/hooks/postToolUse/linters.json 2>/dev/null; then\n  printf "%s\\n" "Expected fast-exec compat hooks to stay read-only" >&2\n  exit 1\nfi\nif printf tamper >> /usr/local/share/control-plane/hooks/postToolUse/linters.json 2>/dev/null; then\n  printf "%s\\n" "Expected fast-exec managed hooks to stay read-only" >&2\n  exit 1\nfi\nif ln -sfn /tmp/evil-hooks /root/.copilot/hooks 2>/dev/null; then\n  printf "%s\\n" "Expected fast-exec ~/.copilot/hooks symlink replacement to fail" >&2\n  exit 1\nfi\ntest "$(readlink /root/.copilot/hooks)" = "/usr/local/share/control-plane/hooks"\nprintf "exec-hooks-readonly-ok\\n" > /workspace/fast-exec-hooks-readonly.txt'
hook_readonly_command_base64="$(printf '%s' "${hook_readonly_command}" | base64 | tr -d '\n')"
control-plane-session-exec proxy --session-key "${session_key}" --cwd /workspace --command-base64 "${hook_readonly_command_base64}" >/dev/null
grep -qx 'exec-hooks-readonly-ok' /workspace/fast-exec-hooks-readonly.txt
command_text=$'printf "fast-exec-stdout\\n"; printf "fast-exec-stderr\\n" >&2; printf "delegated\\n" > /workspace/fast-exec-marker.txt; exit 7'
command_base64="$(printf '%s' "${command_text}" | base64 | tr -d '\n')"
set +e
control-plane-session-exec proxy --session-key "${session_key}" --cwd /workspace --command-base64 "${command_base64}" \
  > /workspace/k8s-fast-exec-stdout.txt 2> /workspace/k8s-fast-exec-stderr.txt
proxy_status=$?
set -e
test "${proxy_status}" -eq 7
test "$(sed -n '1p' /workspace/k8s-fast-exec-stdout.txt)" = "\$ ${command_text}"
test "$(sed -n '2p' /workspace/k8s-fast-exec-stdout.txt)" = 'fast-exec-stdout'
grep -qx 'fast-exec-stderr' /workspace/k8s-fast-exec-stderr.txt
grep -qx 'delegated' /workspace/fast-exec-marker.txt
blocked_command_base64="$(printf '%s' 'cat /root/.config/gh/hosts.yml' | base64 | tr -d '\n')"
set +e
control-plane-session-exec proxy --session-key "${session_key}" --cwd /workspace --command-base64 "${blocked_command_base64}" \
  > /workspace/k8s-fast-exec-blocked-stdout.txt 2> /workspace/k8s-fast-exec-blocked-stderr.txt
blocked_status=$?
set -e
test "${blocked_status}" -ne 0
! [ -s /workspace/k8s-fast-exec-blocked-stdout.txt ]
grep -Fq 'Direct reads of ~/.config/gh/hosts.yml are blocked by control-plane policy.' \
  /workspace/k8s-fast-exec-blocked-stderr.txt
service_account_command=$'set -euo pipefail\ntest -n "${KUBERNETES_SERVICE_HOST:-}"\ntest -n "${KUBERNETES_SERVICE_PORT:-}"\ntest -f /var/run/secrets/kubernetes.io/serviceaccount/token\ntest -f /var/run/secrets/kubernetes.io/serviceaccount/ca.crt'
service_account_command_base64="$(printf '%s' "${service_account_command}" | base64 | tr -d '\n')"
control-plane-session-exec proxy --session-key "${session_key}" --cwd /workspace --command-base64 "${service_account_command_base64}" >/dev/null
kubectl_command=$(cat <<'INNER'
set -euo pipefail
namespace="${CONTROL_PLANE_JOB_NAMESPACE}"
command -v kubectl >/dev/null
test "$(kubectl auth can-i create deployments.apps -n "${namespace}")" = "yes"
test "$(kubectl auth can-i delete deployments.apps -n "${namespace}")" = "yes"
test "$(kubectl auth can-i patch deployments.apps -n "${namespace}")" = "yes"
test "$(kubectl auth can-i create services -n "${namespace}")" = "yes"
test "$(kubectl auth can-i create jobs.batch -n "${namespace}")" = "yes"
test "$(kubectl auth can-i create pods -n "${namespace}")" = "yes"
test "$(kubectl auth can-i get pods/log -n "${namespace}")" = "yes"
kubectl -n "${namespace}" create deployment fast-exec-deployment \
  --image=docker.io/library/busybox:1.37.0 \
  --dry-run=server \
  -o yaml >/dev/null
kubectl -n "${namespace}" create service clusterip fast-exec-service \
  --tcp=80:80 \
  --dry-run=server \
  -o yaml >/dev/null
kubectl -n "${namespace}" create job fast-exec-job \
  --image=docker.io/library/busybox:1.37.0 \
  --dry-run=server \
  -o yaml \
  -- /bin/sh -lc 'printf ok\n' >/dev/null
cat <<'POD' | kubectl -n "${namespace}" create --dry-run=server -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: fast-exec-pod
spec:
  restartPolicy: Never
  containers:
    - name: main
      image: docker.io/library/busybox:1.37.0
      command: ["/bin/sh", "-lc", "sleep 1"]
POD
printf 'exec-kubectl-ok\n' > /workspace/fast-exec-kubectl-marker.txt
INNER
)
kubectl_command_base64="$(printf '%s' "${kubectl_command}" | base64 | tr -d '\n')"
control-plane-session-exec proxy --session-key "${session_key}" --cwd /workspace --command-base64 "${kubectl_command_base64}" >/dev/null
grep -qx 'exec-kubectl-ok' /workspace/fast-exec-kubectl-marker.txt
control-plane-session-exec cleanup --session-key "${session_key}"
! kubectl get pod --namespace "${CONTROL_PLANE_POD_NAMESPACE}" "${pod_name}" >/dev/null 2>&1
jq -e --arg key "${session_key}" '.sessions[$key] == null' ~/.copilot/session-state/session-exec.json >/dev/null
terminating_session_key=kind-fast-exec-terminating
control-plane-session-exec cleanup --session-key "${terminating_session_key}" >/dev/null 2>&1 || true
rm -f /workspace/fast-exec-terminating-marker.txt
control-plane-session-exec prepare --session-key "${terminating_session_key}" >/dev/null
terminating_pod_name="$(jq -r --arg key "${terminating_session_key}" '.sessions[$key].podName' ~/.copilot/session-state/session-exec.json)"
terminating_pod_uid="$(kubectl get pod --namespace "${CONTROL_PLANE_POD_NAMESPACE}" "${terminating_pod_name}" -o jsonpath='{.metadata.uid}')"
kubectl delete pod --namespace "${CONTROL_PLANE_POD_NAMESPACE}" "${terminating_pod_name}" --wait=false >/dev/null
deletion_timestamp=''
for _ in $(seq 1 60); do
  deletion_timestamp="$(kubectl get pod --namespace "${CONTROL_PLANE_POD_NAMESPACE}" "${terminating_pod_name}" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || true)"
  if [ -n "${deletion_timestamp}" ]; then
    break
  fi
  sleep 1
done
test -n "${deletion_timestamp}"
state_temp="$(mktemp)"
jq --arg key "${terminating_session_key}" 'del(.sessions[$key])' ~/.copilot/session-state/session-exec.json > "${state_temp}"
mv "${state_temp}" ~/.copilot/session-state/session-exec.json
control-plane-session-exec prepare --session-key "${terminating_session_key}" >/dev/null
replacement_pod_uid="$(kubectl get pod --namespace "${CONTROL_PLANE_POD_NAMESPACE}" "${terminating_pod_name}" -o jsonpath='{.metadata.uid}')"
test -n "${replacement_pod_uid}"
test "${replacement_pod_uid}" != "${terminating_pod_uid}"
terminating_command_base64="$(printf '%s' 'printf "terminating-fast-exec-ok\n" > /workspace/fast-exec-terminating-marker.txt' | base64 | tr -d '\n')"
control-plane-session-exec proxy --session-key "${terminating_session_key}" --cwd /workspace --command-base64 "${terminating_command_base64}" >/dev/null
grep -qx 'terminating-fast-exec-ok' /workspace/fast-exec-terminating-marker.txt
control-plane-session-exec cleanup --session-key "${terminating_session_key}"
! kubectl get pod --namespace "${CONTROL_PLANE_POD_NAMESPACE}" "${terminating_pod_name}" >/dev/null 2>&1
jq -e --arg key "${terminating_session_key}" '.sessions[$key] == null' ~/.copilot/session-state/session-exec.json >/dev/null
EOF
  then
    ssh_bash <<'EOF' >&2 || true
set +e
printf '%s\n' '--- fast exec debug ---'
cat ~/.copilot/session-state/session-exec.json || true
cat /workspace/k8s-fast-exec-pod.json || true
cat /workspace/k8s-fast-exec-stdout.txt || true
cat /workspace/k8s-fast-exec-stderr.txt || true
cat /workspace/k8s-fast-exec-blocked-stdout.txt || true
cat /workspace/k8s-fast-exec-blocked-stderr.txt || true
cat /workspace/fast-exec-terminating-marker.txt || true
kubectl get pods --namespace "${CONTROL_PLANE_POD_NAMESPACE:-default}" -o wide || true
EOF
    dump_control_plane_diagnostics
    exit 1
  fi
  printf '%s\n' 'kind-test: fast execution pod flow ok' >&2
}

start_persistence_session_fixtures() {
  ssh_bash <<'EOF'
set -euo pipefail
mkdir -p ~/.copilot ~/.config/gh ~/.ssh /workspace
echo k8s > ~/.copilot/state.txt
echo gh > ~/.config/gh/state.txt
echo ssh > ~/.ssh/state.txt
printf '日本語★\n' > /workspace/k8s-screen-utf8.txt
printf '%s\n' k8s-screen > /workspace/k8s-screen.txt
EOF
  printf '%s\n' 'kind-test: session fixtures seeded' >&2
}

wait_for_screen_output_fixture() {
  if ! wait_for_remote_grep '^k8s-screen$' /workspace/k8s-screen.txt; then
    ssh_bash <<'EOF' >&2 || true
set -euo pipefail
cat /workspace/k8s-screen-utf8.txt || true
cat /workspace/k8s-screen.txt || true
EOF
    printf 'Expected seeded session fixture to persist status output\n' >&2
    exit 1
  fi
}

run_terminal_session_assertions() {
  if ! wait_for_remote_grep '^日本語★$' /workspace/k8s-screen-utf8.txt; then
    ssh_bash <<'EOF' >&2 || true
set -euo pipefail
cat /workspace/k8s-screen-utf8.txt || true
cat /workspace/k8s-screen.txt || true
EOF
    printf 'Expected seeded session fixture to persist UTF-8 output\n' >&2
    exit 1
  fi
  printf '%s\n' 'kind-test: session utf8 fixture ready' >&2

  if ! wait_for_remote_grep '^k8s-screen$' /workspace/k8s-screen.txt; then
    ssh_bash <<'EOF' >&2 || true
set -euo pipefail
cat /workspace/k8s-screen-utf8.txt || true
cat /workspace/k8s-screen.txt || true
EOF
    printf 'Expected seeded session fixture to persist status output\n' >&2
    exit 1
  fi
  printf '%s\n' 'kind-test: session status fixture ready' >&2

  printf '%s\n' 'kind-test: verifying web backend health surface' >&2
  kubectl exec --namespace "${namespace}" "$(control_plane_web_pod_name)" -c control-plane-web -- node - <<'EOF'
const http = require('http');

http.get({ host: '127.0.0.1', port: 8080, path: '/healthz' }, (res) => {
  let body = '';
  res.setEncoding('utf8');
  res.on('data', (chunk) => { body += chunk; });
  res.on('end', () => {
    if (res.statusCode !== 200 || body.trim() !== 'ok') {
      console.error(`unexpected web health response: ${res.statusCode} ${body}`);
      process.exit(1);
    }
  });
}).on('error', (error) => {
  console.error(error.message);
  process.exit(1);
});
EOF
  printf '%s\n' 'kind-test: web backend health ok' >&2
}

run_job_core_assertions() {
  printf '%s\n' 'kind-test: starting manual job' >&2
  if ! job_name="$(ssh_bash <<EOF
set -euo pipefail
k8s-job-start --namespace ${job_namespace} --job-name ci-manual-job --image ${control_plane_image} -- bash -lc 'printf "%s\n" manual | tee /workspace/manual-job.txt'
EOF
)";
  then
    ssh_bash <<EOF >&2 || true
set -euxo pipefail
command -v k8s-job-start
kubectl config current-context
kubectl get namespace ${job_namespace}
kubectl get serviceaccount control-plane-job --namespace ${job_namespace}
kubectl get pvc control-plane-workspace-pvc --namespace ${job_namespace}
kubectl auth can-i create jobs --namespace ${job_namespace}
kubectl delete job --namespace ${job_namespace} ci-manual-job --ignore-not-found >/dev/null 2>&1 || true
bash -x "\$(command -v k8s-job-start)" --namespace ${job_namespace} --job-name ci-manual-job --image ${control_plane_image} -- bash -lc 'printf "%s\n" manual | tee /workspace/manual-job.txt'
EOF
    dump_control_plane_diagnostics
    exit 1
  fi
  job_name="$(printf '%s' "${job_name}" | tr -d '\r\n')"
  printf '%s\n' 'kind-test: manual job created' >&2

  ssh_bash <<EOF
set -euo pipefail
k8s-job-wait --namespace ${job_namespace} --job-name ${job_name} --timeout 180s
EOF

  pod_name="$(ssh_bash <<EOF
set -euo pipefail
k8s-job-pod --namespace ${job_namespace} --job-name ${job_name}
EOF
)"
  pod_name="$(printf '%s' "${pod_name}" | tr -d '\r\n')"
  [[ -n "${pod_name}" ]]

  logs="$(ssh_bash <<EOF
set -euo pipefail
k8s-job-logs --namespace ${job_namespace} --job-name ${job_name}
EOF
)"
  grep -q 'manual' <<<"${logs}"

  ssh_bash <<'EOF'
set -euo pipefail
test -f /workspace/manual-job.txt
EOF

  default_mode_output="$(ssh_bash <<EOF
set -euo pipefail
control-plane-run --job-name ci-default-job --image ${control_plane_image} -- bash -lc 'printf "%s\n" default | tee /workspace/default-job.txt'
EOF
)"
  grep -q 'default' <<<"${default_mode_output}"

  ssh_bash <<'EOF'
set -euo pipefail
test -f /workspace/default-job.txt
EOF

}

run_job_transfer_assertions() {
  printf -v remote_job_transfer_command 'bash -l -se -- %q %q' "${control_plane_image}" "${job_namespace}"
  if ! kubectl exec -i --namespace "${namespace}" "$(control_plane_pod_name)" -c control-plane -- \
    su -s /bin/bash copilot -c "${remote_job_transfer_command}" < "${script_dir}/test-job-transfer.sh"; then
    printf 'Expected kind job transfer regression script to succeed\n' >&2
    dump_control_plane_diagnostics
    exit 1
  fi
}

run_restart_assertions() {
  ssh_bash <<'EOF'
set -euo pipefail
printf '%s\n' 'command-history-ok' > ~/.copilot/command-history-state.json
mkdir -p ~/.copilot/session-state
printf '%s\n' 'session-state-ok' > ~/.copilot/session-state/k8s-session-state.txt
printf '%s\n' 'tmp-ok' > "${TMPDIR}/k8s-tmp.txt"
EOF

  kubectl exec --namespace "${namespace}" "$(control_plane_pod_name)" -c control-plane -- bash -lc \
    "set -euo pipefail; printf '%s\n' 'runtime-reset' > /var/tmp/control-plane/should-disappear.txt"

  first_host_fingerprint="$(ssh_host_fingerprint)"

  stop_port_forward
  kubectl rollout restart deployment/control-plane --namespace "${namespace}" >/dev/null
  wait_for_control_plane_pod
  start_port_forward
  wait_for_ssh

  kubectl exec --namespace "${namespace}" "$(control_plane_pod_name)" -c control-plane -- bash -lc \
    "set -euo pipefail; \
     test -L /etc/ssh/ssh_host_ed25519_key; \
     test -L /etc/ssh/ssh_host_ed25519_key.pub; \
     test \"\$(readlink /etc/ssh/ssh_host_ed25519_key)\" = '/run/control-plane/ssh-host-keys/ssh_host_ed25519_key'; \
     test \"\$(readlink /etc/ssh/ssh_host_ed25519_key.pub)\" = '/run/control-plane/ssh-host-keys/ssh_host_ed25519_key.pub'; \
     test \"\$(env -u LD_PRELOAD stat -c '%a %U %G' /run/control-plane/ssh-host-keys)\" = '700 root root'; \
     test \"\$(env -u LD_PRELOAD stat -c '%a %U %G' /run/control-plane/ssh-host-keys/ssh_host_ed25519_key)\" = '600 root root'; \
     test \"\$(env -u LD_PRELOAD stat -c '%a %U %G' /run/control-plane/ssh-host-keys/ssh_host_ed25519_key.pub)\" = '644 root root'"

  second_host_fingerprint="$(ssh_host_fingerprint)"
  [[ "${first_host_fingerprint}" == "${second_host_fingerprint}" ]]

  ssh_bash <<'EOF'
set -euo pipefail
test ! -e ~/.copilot/state.txt
grep -qx 'command-history-ok' ~/.copilot/command-history-state.json
test -f ~/.copilot/session-state/k8s-session-state.txt
test -f ~/.config/gh/state.txt
test -f ~/.ssh/state.txt
test -f /workspace/manual-job.txt
test -f /workspace/default-job.txt
test -f /workspace/k8s-screen.txt
test ! -e "${TMPDIR}/k8s-tmp.txt"
test ! -e /var/tmp/control-plane/should-disappear.txt
test ! -e ~/.copilot/tmp
EOF
}

run_job_and_restart_assertions() {
  run_job_core_assertions
  run_job_transfer_assertions
  run_restart_assertions
}

run_job_core_and_restart_assertions() {
  run_job_core_assertions
  run_restart_assertions
}

cleanup() {
  stop_port_forward
  kubectl delete namespace "${namespace}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete namespace "${job_namespace}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete pv control-plane-copilot-session-pv --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete pv control-plane-workspace-control-pv --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete pv control-plane-workspace-job-pv --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete pv control-plane-fast-exec-environment-pv --ignore-not-found >/dev/null 2>&1 || true
  if [[ "${created_cluster}" -eq 1 ]]; then
    kind_cmd delete cluster --name "${cluster_name}" >/dev/null 2>&1 || true
  fi
  rm -rf "${workdir}"
}
trap cleanup EXIT

require_command kind
require_command kubectl
require_command "${container_bin}"
require_command ssh-keygen

export KIND_EXPERIMENTAL_PROVIDER="${kind_provider}"

if [[ -n "${kind_image_archive}" ]] && [[ ! -f "${kind_image_archive}" ]]; then
  printf 'Missing Kind image archive: %s\n' "${kind_image_archive}" >&2
  exit 1
fi

if [[ "${kind_sudo_mode}" == "always" ]]; then
  enable_kind_sudo
fi

case "${kind_test_group}" in
  all|session|jobs|jobs-core|jobs-transfer)
    ;;
  *)
    printf 'Unsupported Kind test group: %s\n' "${kind_test_group}" >&2
    exit 1
    ;;
esac

if ! kind_cmd get clusters | grep -qx "${cluster_name}"; then
  set +e
  create_cluster
  status=$?
  set -e
  if [[ "${status}" -ne 0 ]]; then
    if [[ "${status}" -eq 2 ]]; then
      exit 0
    fi
    exit "${status}"
  fi
  created_cluster=1
fi

refresh_kubeconfig
kubectl config use-context "kind-${cluster_name}" >/dev/null
kubectl wait --for=condition=Ready node --all --timeout=180s >/dev/null
load_kind_images
ssh-keygen -q -t ed25519 -N '' -f "${ssh_key}"
apply_resources
test "$(kubectl get service/control-plane --namespace "${namespace}" -o jsonpath='{.spec.type}')" = "ClusterIP"
test "$(kubectl get service/control-plane-web --namespace "${namespace}" -o jsonpath='{.spec.type}')" = "LoadBalancer"
test "$(kubectl get configmap/control-plane-env --namespace "${namespace}" -o jsonpath='{.data.COPILOT_CONFIG_JSON_FILE}')" = "/var/run/control-plane-config/copilot-config.json"
assert_control_plane_probe_spec
wait_for_control_plane_pod
start_port_forward
wait_for_ssh

run_shared_remote_assertions
if [[ "${kind_test_group}" == "all" ]] || [[ "${kind_test_group}" == "session" ]]; then
  run_fast_exec_assertions
fi

case "${kind_test_group}" in
  all)
    start_persistence_session_fixtures
    run_terminal_session_assertions
    run_job_and_restart_assertions
    ;;
  session)
    start_persistence_session_fixtures
    run_terminal_session_assertions
    ;;
  jobs)
    start_persistence_session_fixtures
    wait_for_screen_output_fixture
    run_job_and_restart_assertions
    ;;
  jobs-core)
    start_persistence_session_fixtures
    wait_for_screen_output_fixture
    run_job_core_and_restart_assertions
    ;;
  jobs-transfer)
    run_job_transfer_assertions
    ;;
esac
