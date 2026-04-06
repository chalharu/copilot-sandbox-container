#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
control_plane_image="${1:?usage: scripts/test-kind.sh <control-plane-image> <execution-plane-image> [cluster-name]}"
execution_plane_image="${2:?usage: scripts/test-kind.sh <control-plane-image> <execution-plane-image> [cluster-name]}"
cluster_name="${3:-control-plane-ci}"
namespace="${CONTROL_PLANE_TEST_NAMESPACE:-control-plane-ci}"
job_namespace="${CONTROL_PLANE_TEST_JOB_NAMESPACE:-${namespace}-jobs}"
ssh_port="${CONTROL_PLANE_TEST_SSH_PORT:-32222}"
kind_provider="${KIND_EXPERIMENTAL_PROVIDER:-docker}"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-${kind_provider}}"
control_plane_selector="app.kubernetes.io/name=control-plane"
kind_image_archive="${CONTROL_PLANE_KIND_IMAGE_ARCHIVE:-}"
workdir="$(mktemp -d)"
ssh_key="${workdir}/id_ed25519"
kubeconfig_path="${workdir}/kubeconfig"
kind_auto_login_session="k8s-auto-login-${RANDOM}"
port_forward_pid=""
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

ssh_opts=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o IdentitiesOnly=yes
  -o SetEnv=LC_ALL=en_US.UTF8
  -i "${ssh_key}"
  -p "${ssh_port}"
)

ssh_cmd() {
  # shellcheck disable=SC2029
  ssh "${ssh_opts[@]}" copilot@127.0.0.1 "$@"
}

ssh_bash() {
  ssh "${ssh_opts[@]}" copilot@127.0.0.1 'bash -l -se'
}

wait_for_ssh() {
  local _
  for _ in $(seq 1 60); do
    if ssh_cmd true >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  printf 'Timed out waiting for SSH on port %s\n' "${ssh_port}" >&2
  if [[ -f "${workdir}/port-forward.log" ]]; then
    printf '%s\n' '--- kubectl port-forward log ---' >&2
    cat "${workdir}/port-forward.log" >&2 || true
  fi
  dump_control_plane_diagnostics
  exit 1
}

wait_for_screen_term() {
  local target_session="$1"
  local term_file="$2"
  local expected_term_pattern="${3:-screen-256color(-bce)?}"
  local attempts="${4:-15}"
  local remote_command
  local _

  printf -v remote_command 'TARGET_SESSION=%q TERM_FILE=%q EXPECTED_TERM_PATTERN=%q bash -l -se' \
    "${target_session}" "${term_file}" "${expected_term_pattern}"

  for _ in $(seq 1 "${attempts}"); do
    # shellcheck disable=SC2029
    if ssh "${ssh_opts[@]}" copilot@127.0.0.1 "${remote_command}" <<'EOF' >/dev/null 2>&1
set -euo pipefail
screen -list | grep -q -- "${TARGET_SESSION}"
grep -Eq -- "^(${EXPECTED_TERM_PATTERN})$" "${TERM_FILE}"
EOF
    then
      return 0
    fi
    sleep 1
  done

  return 1
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
    # shellcheck disable=SC2029
    if ssh "${ssh_opts[@]}" copilot@127.0.0.1 "${remote_command}" <<'EOF' >/dev/null 2>&1
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

  fingerprint="$(ssh-keyscan -p "${ssh_port}" 127.0.0.1 2>/dev/null | ssh-keygen -lf - | awk '/ED25519/ { print $2; exit }')"
  [[ -n "${fingerprint}" ]] || {
    printf 'Unable to read SSH host key fingerprint on port %s\n' "${ssh_port}" >&2
    exit 1
  }

  printf '%s\n' "${fingerprint}"
}

stop_port_forward() {
  if [[ -n "${port_forward_pid}" ]]; then
    kill "${port_forward_pid}" >/dev/null 2>&1 || true
    wait "${port_forward_pid}" 2>/dev/null || true
    port_forward_pid=""
  fi
}

start_port_forward() {
  stop_port_forward
  kubectl port-forward --namespace "${namespace}" service/control-plane "${ssh_port}:2222" >"${workdir}/port-forward.log" 2>&1 &
  port_forward_pid=$!
}

control_plane_pod_name() {
  kubectl get pods --namespace "${namespace}" -l "${control_plane_selector}" -o jsonpath='{.items[0].metadata.name}'
}

dump_control_plane_diagnostics() {
  local pod_name=""

  kubectl get deployment,replicaset,pods,svc --namespace "${namespace}" -l "${control_plane_selector}" -o wide >&2 || true
  kubectl describe deployment/control-plane --namespace "${namespace}" >&2 || true
  pod_name="$(control_plane_pod_name 2>/dev/null || true)"
  if [[ -n "${pod_name}" ]]; then
    kubectl describe pod/"${pod_name}" --namespace "${namespace}" >&2 || true
    kubectl logs --namespace "${namespace}" pod/"${pod_name}" -c init-state-dirs >&2 || true
    kubectl logs --namespace "${namespace}" pod/"${pod_name}" -c init-state >&2 || true
    kubectl logs --namespace "${namespace}" pod/"${pod_name}" -c control-plane >&2 || true
  fi
  kubectl get events --namespace "${namespace}" --sort-by=.lastTimestamp >&2 || true
}

wait_for_control_plane_pod() {
  if kubectl rollout status --namespace "${namespace}" deployment/control-plane --timeout=180s >/dev/null \
    && kubectl wait --namespace "${namespace}" --for=condition=Ready pod -l "${control_plane_selector}" --timeout=180s >/dev/null; then
    return 0
  fi

  dump_control_plane_diagnostics
  return 1
}

load_kind_images() {
  local helper_args=(--cluster-name "${cluster_name}")

  if [[ -n "${kind_image_archive}" ]]; then
    helper_args+=(--image-archive "${kind_image_archive}")
  else
    helper_args+=(--container-bin "${container_bin}" --image "${control_plane_image}" --image "${execution_plane_image}")
  fi

  CONTROL_PLANE_KIND_USE_SUDO="${kind_uses_sudo}" \
    KIND_EXPERIMENTAL_PROVIDER="${kind_provider}" \
    "${script_dir}/load-kind-images.sh" "${helper_args[@]}"
}

apply_resources() {
  local public_key
  public_key="$(cat "${ssh_key}.pub")"
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
    resources: ["pods/log"]
    verbs: ["get"]
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
    path: /tmp/control-plane-copilot-session
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
    path: /tmp/control-plane-workspace
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
    path: /tmp/control-plane-workspace
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
  CONTROL_PLANE_FAST_EXECUTION_IMAGE: ${control_plane_image}
  CONTROL_PLANE_FAST_EXECUTION_IMAGE_PULL_POLICY: Never
  CONTROL_PLANE_FAST_EXECUTION_START_TIMEOUT: 120s
  CONTROL_PLANE_FAST_EXECUTION_PORT: "8080"
  CONTROL_PLANE_FAST_EXECUTION_ENV_CONFIGMAP: control-plane-env
  CONTROL_PLANE_FAST_EXECUTION_AUTH_SECRET: control-plane-auth
  CONTROL_PLANE_FAST_EXECUTION_CONFIG_CONFIGMAP: control-plane-config
  CONTROL_PLANE_FAST_EXECUTION_CPU_REQUEST: 250m
  CONTROL_PLANE_FAST_EXECUTION_CPU_LIMIT: "1"
  CONTROL_PLANE_FAST_EXECUTION_MEMORY_REQUEST: 256Mi
  CONTROL_PLANE_FAST_EXECUTION_MEMORY_LIMIT: 1Gi
  CONTROL_PLANE_FAST_EXECUTION_REQUEST_TIMEOUT_SEC: "3600"
  CONTROL_PLANE_JOB_WORKSPACE_PVC: control-plane-workspace-pvc
  CONTROL_PLANE_JOB_WORKSPACE_SUBPATH: workspace
  CONTROL_PLANE_JOB_SERVICE_ACCOUNT: control-plane-job
  CONTROL_PLANE_RUN_MODE: k8s-job
  CONTROL_PLANE_JOB_TRANSFER_IMAGE: ${control_plane_image}
  CONTROL_PLANE_JOB_TRANSFER_HOST: control-plane.${namespace}.svc.cluster.local
  CONTROL_PLANE_JOB_TRANSFER_PORT: "2222"
  CONTROL_PLANE_COPILOT_CPU_LIMIT_PERCENT: "100"
  CONTROL_PLANE_JOB_IMAGE_PULL_POLICY: Never
---
apiVersion: v1
kind: Service
metadata:
  name: control-plane
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: control-plane
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: control-plane
  ports:
    - name: ssh
      port: 2222
      targetPort: ssh
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: control-plane
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: control-plane
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: control-plane
  template:
    metadata:
      labels:
        app.kubernetes.io/name: control-plane
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
                /copilot-session/state/ssh \
                /copilot-session/state/ssh-host-keys \
                /copilot-session/session-state \
                /workspace-state/workspace \
                /cache/runtime-tmp
              touch /copilot-session/state/copilot-config.json /copilot-session/state/command-history-state.json
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
              [ -s /state/copilot-config.json ] || cat > /state/copilot-config.json <<'JSON'
              {
                "auth": {
                  "provider": "github"
                },
                "features": {
                  "persisted": true,
                  "sessionPicker": true
                },
                "nested": {
                  "keep": 1,
                  "replace": {
                    "fromBase": true
                  },
                  "array": [
                    "base"
                  ]
                }
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
            - name: CONTROL_PLANE_POD_UID
              valueFrom:
                fieldRef:
                  fieldPath: metadata.uid
            - name: CONTROL_PLANE_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          # Keep the Kind test on the same SSH-focused capability profile as the
          # sample manifest.
          securityContext:
            privileged: false
            runAsUser: 0
            runAsNonRoot: false
            allowPrivilegeEscalation: true
            capabilities:
              drop:
                - ALL
              add:
                - AUDIT_WRITE
                - CHOWN
                - DAC_OVERRIDE
                - FOWNER
                - KILL
                - SETGID
                - SETUID
                - SYS_CHROOT
            seccompProfile:
              type: RuntimeDefault
          ports:
            - containerPort: 2222
              name: ssh
          readinessProbe:
            tcpSocket:
              port: ssh
            periodSeconds: 5
            failureThreshold: 12
          livenessProbe:
            tcpSocket:
              port: ssh
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
command -v gh
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
command -v vim
printf '%s\n' 'kind-test remote: command availability ok' >&2
test "\$(TERM=xterm-256color tput colors)" -ge 256
test "\$(TERM=screen-256color tput colors)" -ge 256
test "\$(TERM=tmux-256color tput colors)" -ge 256
printf '%s\n' 'kind-test remote: terminfo ok' >&2
printf '%s\n' "\${LANG}" | grep -qi 'utf-8'
test "\${LC_ALL}" = "en_US.UTF8"
locale charmap | grep -qx 'UTF-8'
locale -a | grep -Eqi '^en_US\.utf-?8$'
locale -a | grep -Eqi '^ja_JP\.utf-?8$'
test "\${EDITOR}" = "vim"
test "\${VISUAL}" = "vim"
test "\${GH_PAGER}" = "cat"
printf '%s\n' 'kind-test remote: locale and editor env ok' >&2
test -f ~/.copilot/skills/control-plane-operations/SKILL.md
test -f ~/.copilot/skills/containerized-yamllint-ops/SKILL.md
test -f ~/.copilot/skills/repo-change-delivery/SKILL.md
test -f ~/.copilot/config.json
test -f ~/.copilot/command-history-state.json
test -d ~/.copilot/session-state
test -f ~/.config/gh/hosts.yml
test "\$(stat -c '%a %U %G' ~/.copilot/config.json)" = '600 copilot copilot'
test "\$(stat -c '%a %U %G' ~/.copilot/command-history-state.json)" = '600 copilot copilot'
test "\$(stat -c '%a %U %G' ~/.config/gh/hosts.yml)" = '600 copilot copilot'
printf '%s\n' 'kind-test remote: persisted files ok' >&2
jq -e '.auth.provider == "github"' ~/.copilot/config.json >/dev/null
jq -e '.features.sessionPicker == true' ~/.copilot/config.json >/dev/null
jq -e '.features.persisted == false' ~/.copilot/config.json >/dev/null
jq -e '.features.overlayOnly == true' ~/.copilot/config.json >/dev/null
jq -e '.nested.keep == 1' ~/.copilot/config.json >/dev/null
jq -e '.nested.replace.fromBase == true and .nested.replace.fromOverlay == true' ~/.copilot/config.json >/dev/null
jq -e '.nested.array == ["overlay"]' ~/.copilot/config.json >/dev/null
jq -e '.topLevelOverlay == "kind"' ~/.copilot/config.json >/dev/null
printf '%s\n' 'kind-test remote: config merge ok' >&2
gh config get git_protocol --host github.com | grep -qx 'ssh'
printf '%s\n' 'kind-test remote: gh hosts ok' >&2
grep -Fqx 'CARGO_HOME=/home/copilot/.cargo' ~/.config/control-plane/runtime.env
grep -Fqx 'CARGO_TARGET_DIR=/var/tmp/control-plane/cargo-target' ~/.config/control-plane/runtime.env
test -d /var/tmp/control-plane
test -d /var/tmp/control-plane/cargo-target
printf '%s\n' 'kind-test remote: runtime tmp ok' >&2
test "\${CONTROL_PLANE_JOB_NAMESPACE}" = "${job_namespace}"
test "\${CONTROL_PLANE_FAST_EXECUTION_ENABLED}" = "1"
test "\${CONTROL_PLANE_FAST_EXECUTION_IMAGE}" = "${control_plane_image}"
test "\${CONTROL_PLANE_COPILOT_SESSION_PVC}" = "control-plane-copilot-session-pvc"
cat /proc/self/uid_map > /workspace/k8s-pod-uid-map.txt
printf '%s\n' 'kind-test remote: runtime env and workspace write ok' >&2
EOF
  then
    ssh_bash <<'EOF' >&2 || true
set +e
printf '%s\n' '--- kind-test initial remote debug ---'
printf 'LANG=%s\n' "${LANG:-}" || true
printf 'LC_ALL=%s\n' "${LC_ALL:-}" || true
printf 'EDITOR=%s\n' "${EDITOR:-}" || true
printf 'VISUAL=%s\n' "${VISUAL:-}" || true
printf 'GH_PAGER=%s\n' "${GH_PAGER:-}" || true
printf '%s\n' '--- terminfo ---'
TERM=xterm-256color tput colors || true
TERM=screen-256color tput colors || true
TERM=tmux-256color tput colors || true
printf '%s\n' '--- locale ---'
locale charmap || true
locale -a || true
printf '%s\n' '--- persisted files ---'
ls -ld ~/.copilot ~/.copilot/session-state ~/.config ~/.config/gh ~/.ssh /workspace || true
ls -l ~/.copilot/config.json ~/.copilot/command-history-state.json ~/.config/gh/hosts.yml || true
stat -c '%n %a %U %G' ~/.copilot/config.json ~/.copilot/command-history-state.json ~/.config/gh/hosts.yml || true
printf '%s\n' '--- config and gh hosts ---'
cat ~/.copilot/config.json || true
gh auth status --hostname github.com || true
gh config get git_protocol --host github.com || true
printf '%s\n' '--- runtime tmp ---'
ls -la /var/tmp/control-plane || true
printf '%s\n' '--- runtime env ---'
printf 'CONTROL_PLANE_JOB_NAMESPACE=%s\n' "${CONTROL_PLANE_JOB_NAMESPACE:-}" || true
printf 'CONTROL_PLANE_FAST_EXECUTION_ENABLED=%s\n' "${CONTROL_PLANE_FAST_EXECUTION_ENABLED:-}" || true
printf 'CONTROL_PLANE_FAST_EXECUTION_IMAGE=%s\n' "${CONTROL_PLANE_FAST_EXECUTION_IMAGE:-}" || true
printf 'CONTROL_PLANE_COPILOT_SESSION_PVC=%s\n' "${CONTROL_PLANE_COPILOT_SESSION_PVC:-}" || true
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
control-plane-session-exec prepare --session-key "${session_key}" >/dev/null
jq -e --arg key "${session_key}" '.sessions[$key].podName != null and .sessions[$key].podIp != null' \
  ~/.copilot/session-state/session-exec.json >/dev/null
pod_name="$(jq -r --arg key "${session_key}" '.sessions[$key].podName' ~/.copilot/session-state/session-exec.json)"
pod_ip="$(jq -r --arg key "${session_key}" '.sessions[$key].podIp' ~/.copilot/session-state/session-exec.json)"
test -n "${pod_name}"
test -n "${pod_ip}"
kubectl get pod --namespace "${CONTROL_PLANE_POD_NAMESPACE}" "${pod_name}" -o json > /workspace/k8s-fast-exec-pod.json
test "$(jq -r '.metadata.ownerReferences[0].kind' /workspace/k8s-fast-exec-pod.json)" = "Pod"
test "$(jq -r '.metadata.ownerReferences[0].name' /workspace/k8s-fast-exec-pod.json)" = "${CONTROL_PLANE_POD_NAME}"
test "$(jq -r '.metadata.ownerReferences[0].uid' /workspace/k8s-fast-exec-pod.json)" = "${CONTROL_PLANE_POD_UID}"
test "$(jq -r '.spec.nodeName' /workspace/k8s-fast-exec-pod.json)" = "${CONTROL_PLANE_NODE_NAME}"
test "$(jq -r '.spec.containers[0].image' /workspace/k8s-fast-exec-pod.json)" = "${CONTROL_PLANE_FAST_EXECUTION_IMAGE}"
test "$(jq -r '.spec.volumes[] | select(.name == "workspace").persistentVolumeClaim.claimName' /workspace/k8s-fast-exec-pod.json)" = "control-plane-workspace-pvc"
test "$(jq -r '.spec.volumes[] | select(.name == "copilot-session").persistentVolumeClaim.claimName' /workspace/k8s-fast-exec-pod.json)" = "control-plane-copilot-session-pvc"
command_text=$'printf "fast-exec-stdout\\n"; printf "fast-exec-stderr\\n" >&2; printf "delegated\\n" > /workspace/fast-exec-marker.txt; exit 7'
command_base64="$(printf '%s' "${command_text}" | base64 | tr -d '\n')"
set +e
control-plane-session-exec proxy --session-key "${session_key}" --cwd /workspace --command-base64 "${command_base64}" \
  > /workspace/k8s-fast-exec-stdout.txt 2> /workspace/k8s-fast-exec-stderr.txt
proxy_status=$?
set -e
test "${proxy_status}" -eq 7
grep -qx 'fast-exec-stdout' /workspace/k8s-fast-exec-stdout.txt
grep -qx 'fast-exec-stderr' /workspace/k8s-fast-exec-stderr.txt
grep -qx 'delegated' /workspace/fast-exec-marker.txt
control-plane-session-exec cleanup --session-key "${session_key}"
! kubectl get pod --namespace "${CONTROL_PLANE_POD_NAMESPACE}" "${pod_name}" >/dev/null 2>&1
jq -e --arg key "${session_key}" '.sessions[$key] == null' ~/.copilot/session-state/session-exec.json >/dev/null
EOF
  then
    ssh_bash <<'EOF' >&2 || true
set +e
printf '%s\n' '--- fast exec debug ---'
cat ~/.copilot/session-state/session-exec.json || true
cat /workspace/k8s-fast-exec-pod.json || true
cat /workspace/k8s-fast-exec-stdout.txt || true
cat /workspace/k8s-fast-exec-stderr.txt || true
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
screen -T screen-256color -dmS kind-session sh -lc 'printf "%s\n" "$TERM" > /workspace/k8s-screen-term.txt; printf "日本語★\n" > /workspace/k8s-screen-utf8.txt; echo k8s-screen > /workspace/k8s-screen.txt; sleep 30'
EOF
  printf '%s\n' 'kind-test: screen session started' >&2
}

wait_for_screen_output_fixture() {
  if ! wait_for_remote_grep '^k8s-screen$' /workspace/k8s-screen.txt; then
    ssh_bash <<'EOF' >&2 || true
set -euo pipefail
cat /workspace/k8s-screen-term.txt || true
cat /workspace/k8s-screen-utf8.txt || true
cat /workspace/k8s-screen.txt || true
EOF
    printf 'Expected kind-session fixture to persist screen status output\n' >&2
    exit 1
  fi
}

run_terminal_session_assertions() {
  printf '%s\n' 'kind-test: verifying login TERM fallback' >&2
  if ! TERM=bogusterm ssh -tt "${ssh_opts[@]}" copilot@127.0.0.1 \
    "CONTROL_PLANE_DISABLE_SESSION_PICKER=1 bash -lic 'printf \"%s\n\" \"\$TERM\" > /workspace/k8s-login-term.txt; tput colors > /workspace/k8s-login-colors.txt'" \
    </dev/null >"${workdir}/ssh-login-term.log" 2>&1; then
    cat "${workdir}/ssh-login-term.log" >&2 || true
    printf 'Expected kind login shell TERM fallback to succeed over SSH\n' >&2
    exit 1
  fi
  if ! ssh_bash <<'EOF'
set -euo pipefail
grep -Eq '^(xterm-256color|xterm)$' /workspace/k8s-login-term.txt
awk 'NR == 1 { exit !($1 >= 8) }' /workspace/k8s-login-colors.txt
EOF
  then
    ssh_bash <<'EOF' >&2 || true
set -euo pipefail
cat /workspace/k8s-login-term.txt || true
cat /workspace/k8s-login-colors.txt || true
EOF
    printf 'Expected kind login TERM fallback files to report a usable terminal\n' >&2
    exit 1
  fi
  printf '%s\n' 'kind-test: login TERM fallback ok' >&2

  printf '%s\n' 'kind-test: verifying login TERM upgrade to 256 colors' >&2
  if ! TERM=xterm-color ssh -tt "${ssh_opts[@]}" copilot@127.0.0.1 \
    "CONTROL_PLANE_DISABLE_SESSION_PICKER=1 bash -lic 'printf \"%s\n\" \"\$TERM\" > /workspace/k8s-login-term-upgrade.txt; tput colors > /workspace/k8s-login-term-upgrade-colors.txt'" \
    </dev/null >"${workdir}/ssh-login-term-upgrade.log" 2>&1; then
    cat "${workdir}/ssh-login-term-upgrade.log" >&2 || true
    printf 'Expected kind login TERM upgrade to succeed over SSH\n' >&2
    exit 1
  fi
  if ! ssh_bash <<'EOF'
set -euo pipefail
grep -qx 'xterm-256color' /workspace/k8s-login-term-upgrade.txt
awk 'NR == 1 { exit !($1 >= 256) }' /workspace/k8s-login-term-upgrade-colors.txt
EOF
  then
    ssh_bash <<'EOF' >&2 || true
set -euo pipefail
cat /workspace/k8s-login-term-upgrade.txt || true
cat /workspace/k8s-login-term-upgrade-colors.txt || true
EOF
    printf 'Expected kind login TERM upgrade files to report xterm-256color with 256 colors\n' >&2
    exit 1
  fi
  printf '%s\n' 'kind-test: login TERM upgrade ok' >&2

  if ! wait_for_screen_term kind-session /workspace/k8s-screen-term.txt; then
    ssh_bash <<'EOF' >&2 || true
set -euo pipefail
screen -list || true
cat /workspace/k8s-screen-term.txt || true
cat /workspace/k8s-screen-utf8.txt || true
EOF
    printf 'Expected kind-session to report a screen-256color TERM variant\n' >&2
    exit 1
  fi
  printf '%s\n' 'kind-test: screen term ready' >&2

  if ! wait_for_remote_grep '^日本語★$' /workspace/k8s-screen-utf8.txt; then
    ssh_bash <<'EOF' >&2 || true
set -euo pipefail
cat /workspace/k8s-screen-term.txt || true
cat /workspace/k8s-screen-utf8.txt || true
cat /workspace/k8s-screen.txt || true
EOF
    printf 'Expected kind-session to persist UTF-8 screen output\n' >&2
    exit 1
  fi
  printf '%s\n' 'kind-test: screen utf8 ready' >&2

  if ! wait_for_remote_grep '^k8s-screen$' /workspace/k8s-screen.txt; then
    ssh_bash <<'EOF' >&2 || true
set -euo pipefail
cat /workspace/k8s-screen-term.txt || true
cat /workspace/k8s-screen-utf8.txt || true
cat /workspace/k8s-screen.txt || true
EOF
    printf 'Expected kind-session to persist screen status output\n' >&2
    exit 1
  fi
  printf '%s\n' 'kind-test: screen output ready' >&2

  printf '%s\n' 'kind-test: verifying session picker fallback' >&2
  if ! TERM=tmux-256color ssh -tt "${ssh_opts[@]}" copilot@127.0.0.1 \
    "CONTROL_PLANE_SESSION_SELECTION=9999 bash -lic 'printf \"%s\n\" fallback-shell-ok'" \
    </dev/null >"${workdir}/ssh-picker-fallback.log" 2>&1; then
    cat "${workdir}/ssh-picker-fallback.log" >&2 || true
    printf 'Expected SSH login to fall back to a shell when the session picker fails\n' >&2
    exit 1
  fi
  if ! grep -q 'fallback-shell-ok' "${workdir}/ssh-picker-fallback.log"; then
    printf 'Expected fallback-shell-ok marker in kind SSH fallback log\n' >&2
    cat "${workdir}/ssh-picker-fallback.log" >&2 || true
    exit 1
  fi
  if ! grep -q 'session picker failed; continuing with the login shell' "${workdir}/ssh-picker-fallback.log"; then
    printf 'Expected session picker fallback warning in kind SSH fallback log\n' >&2
    cat "${workdir}/ssh-picker-fallback.log" >&2 || true
    exit 1
  fi
  printf '%s\n' 'kind-test: session picker fallback ok' >&2

  printf '%s\n' 'kind-test: verifying interactive SSH auto-login' >&2
  if ! ssh_bash <<EOF
set -euo pipefail
cp ~/.config/control-plane/runtime.env /workspace/k8s-runtime.env.bak
printf '\nCONTROL_PLANE_SESSION_SELECTION=new:%s\n' "${kind_auto_login_session}" >> ~/.config/control-plane/runtime.env
EOF
  then
    printf 'Expected kind runtime.env backup/setup to succeed before SSH auto-login probe\n' >&2
    exit 1
  fi

  set +e
  "${script_dir}/test-ssh-session-persistence.sh" \
    --identity "${ssh_key}" \
    --port "${ssh_port}" \
    --session-name "${kind_auto_login_session}" \
    --marker-path /workspace/k8s-auto-login-marker.txt
  kind_auto_login_status=$?
  set -e

  if ! ssh_bash <<'EOF'
set -euo pipefail
cp /workspace/k8s-runtime.env.bak ~/.config/control-plane/runtime.env
chmod 600 ~/.config/control-plane/runtime.env
rm -f /workspace/k8s-runtime.env.bak
EOF
  then
    printf 'Expected kind runtime.env restore to succeed after SSH auto-login probe\n' >&2
    exit 1
  fi

  if [[ "${kind_auto_login_status}" -ne 0 ]]; then
    printf 'Expected kind interactive SSH auto-login to stay attached and accept input\n' >&2
    exit 1
  fi
  printf '%s\n' 'kind-test: interactive SSH auto-login ok' >&2

  printf '%s\n' 'kind-test: verifying picker menu options' >&2
  if ! ssh_bash <<'EOF'
set -euo pipefail
screen -T screen-256color -dmS shell bash -lc 'sleep 30'
EOF
  then
    printf 'Expected shell session fixture for kind picker menu test\n' >&2
    exit 1
  fi
  set +e
  printf '9999\n' | TERM=tmux-256color ssh -tt "${ssh_opts[@]}" copilot@127.0.0.1 \
    "control-plane-session --select" >"${workdir}/ssh-picker-menu.log" 2>&1
  picker_menu_status=$?
  set -e
  if [[ "${picker_menu_status}" -eq 0 ]]; then
    printf 'Expected kind picker menu probe to fail on invalid selection\n' >&2
    cat "${workdir}/ssh-picker-menu.log" >&2 || true
    exit 1
  fi
  if ! grep -Fq 'Copilot (/workspace, --yolo)' "${workdir}/ssh-picker-menu.log"; then
    printf 'Expected kind picker menu to show the Copilot option when only shell sessions exist\n' >&2
    cat "${workdir}/ssh-picker-menu.log" >&2 || true
    exit 1
  fi
  printf '%s\n' 'kind-test: picker menu shows Copilot option' >&2
}

run_job_core_assertions() {
  printf '%s\n' 'kind-test: starting manual job' >&2
  if ! job_name="$(ssh_bash <<EOF
set -euo pipefail
k8s-job-start --namespace ${job_namespace} --job-name ci-manual-job --image ${execution_plane_image} -- /usr/local/bin/execution-plane-smoke write-marker /workspace/manual-job.txt manual
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
bash -x "\$(command -v k8s-job-start)" --namespace ${job_namespace} --job-name ci-manual-job --image ${execution_plane_image} -- /usr/local/bin/execution-plane-smoke write-marker /workspace/manual-job.txt manual
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
control-plane-run --job-name ci-default-job --image ${execution_plane_image} -- /usr/local/bin/execution-plane-smoke write-marker /workspace/default-job.txt default
EOF
)"
  grep -q 'default' <<<"${default_mode_output}"

  ssh_bash <<'EOF'
set -euo pipefail
test -f /workspace/default-job.txt
EOF

}

run_job_transfer_assertions() {
  printf -v remote_job_transfer_command 'bash -l -se -- %q %q' "${execution_plane_image}" "${job_namespace}"
  # shellcheck disable=SC2029
  if ! ssh "${ssh_opts[@]}" copilot@127.0.0.1 "${remote_job_transfer_command}" < "${script_dir}/test-job-transfer.sh"; then
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
  if [[ "${created_cluster}" -eq 1 ]]; then
    kind_cmd delete cluster --name "${cluster_name}" >/dev/null 2>&1 || true
  fi
  rm -rf "${workdir}"
}
trap cleanup EXIT

require_command kind
require_command kubectl
require_command "${container_bin}"
require_command ssh
require_command ssh-keygen
require_command ssh-keyscan

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
test "$(kubectl get service/control-plane --namespace "${namespace}" -o jsonpath='{.spec.type}')" = "LoadBalancer"
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
