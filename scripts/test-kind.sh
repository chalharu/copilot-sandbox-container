#!/usr/bin/env bash
set -euo pipefail

control_plane_image="${1:?usage: scripts/test-kind.sh <control-plane-image> <execution-plane-image> [cluster-name]}"
execution_plane_image="${2:?usage: scripts/test-kind.sh <control-plane-image> <execution-plane-image> [cluster-name]}"
cluster_name="${3:-control-plane-ci}"
namespace="${CONTROL_PLANE_TEST_NAMESPACE:-control-plane-ci}"
ssh_port="${CONTROL_PLANE_TEST_SSH_PORT:-32222}"
kind_provider="${KIND_EXPERIMENTAL_PROVIDER:-podman}"
container_bin="${CONTROL_PLANE_CONTAINER_BIN:-${kind_provider}}"
control_plane_selector="app.kubernetes.io/name=control-plane"
workdir="$(mktemp -d)"
ssh_key="${workdir}/id_ed25519"
kubeconfig_path="${workdir}/kubeconfig"
port_forward_pid=""
created_cluster=0
kind_uses_sudo=0
kind_sudo_mode="${CONTROL_PLANE_KIND_SUDO_MODE:-auto}"

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

  if [[ "${kind_provider}" != "podman" ]] || [[ "${kind_uses_sudo}" -eq 1 ]] || [[ "${kind_sudo_mode}" == "never" ]]; then
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

load_kind_image() {
  local image="$1"
  local archive_basename archive_path

  archive_basename="$(printf '%s' "${image}" | tr '/:' '__')"
  archive_path="${workdir}/${archive_basename}.tar"

  "${container_bin}" save --output "${archive_path}" "${image}" >/dev/null
  kind_cmd load image-archive "${archive_path}" --name "${cluster_name}"
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
kind: ServiceAccount
metadata:
  name: control-plane
  namespace: ${namespace}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: control-plane-jobs
  namespace: ${namespace}
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
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: control-plane-jobs
  namespace: ${namespace}
subjects:
  - kind: ServiceAccount
    name: control-plane
    namespace: ${namespace}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: control-plane-jobs
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: control-plane-state-pv
spec:
  capacity:
    storage: 2Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete
  storageClassName: control-plane-manual
  hostPath:
    path: /tmp/control-plane-state
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: control-plane-state-pvc
  namespace: ${namespace}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
  storageClassName: control-plane-manual
  volumeName: control-plane-state-pv
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
---
apiVersion: v1
kind: Service
metadata:
  name: control-plane
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: control-plane
spec:
  type: ClusterIP
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
      hostUsers: false
      serviceAccountName: control-plane
      initContainers:
        - name: init-state
          # renovate: datasource=docker depName=busybox versioning=docker
          image: busybox:1.37.0@sha256:b3255e7dfbcd10cb367af0d409747d511aeb66dfac98cf30e97e87e4207dd76f
          command:
            - sh
            - -c
            - mkdir -p /state/copilot /state/gh /state/ssh /state/ssh-host-keys /state/workspace && chmod 700 /state/ssh /state/ssh-host-keys
          volumeMounts:
            - name: state
              mountPath: /state
      containers:
        - name: control-plane
          image: ${control_plane_image}
          imagePullPolicy: Never
          env:
            - name: SSH_PUBLIC_KEY_FILE
              value: /var/run/control-plane-auth/ssh-public-key
            - name: CONTROL_PLANE_K8S_NAMESPACE
              value: ${namespace}
            - name: CONTROL_PLANE_WORKSPACE_PVC
              value: control-plane-state-pvc
            - name: CONTROL_PLANE_WORKSPACE_SUBPATH
              value: workspace
            - name: CONTROL_PLANE_JOB_SERVICE_ACCOUNT
              value: control-plane
            - name: CONTROL_PLANE_JOB_IMAGE_PULL_POLICY
              value: Never
          # Prefer a least-privilege default: use Pod user namespaces and keep
          # the runtime seccomp profile. We intentionally avoid privileged=true,
          # but still allow the default root capability set because the
          # entrypoint and sshd need standard root operations such as chown and
          # setuid/setgid.
          securityContext:
            allowPrivilegeEscalation: true
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
            - name: state
              mountPath: /home/copilot/.copilot
              subPath: copilot
            - name: state
              mountPath: /home/copilot/.config/gh
              subPath: gh
            - name: state
              mountPath: /home/copilot/.ssh
              subPath: ssh
            - name: state
              mountPath: /var/lib/control-plane/ssh-host-keys
              subPath: ssh-host-keys
            - name: state
              mountPath: /workspace
              subPath: workspace
            - name: control-plane-auth
              mountPath: /var/run/control-plane-auth
              readOnly: true
      volumes:
        - name: state
          persistentVolumeClaim:
            claimName: control-plane-state-pvc
        - name: control-plane-auth
          secret:
            secretName: control-plane-auth
EOF
}

cleanup() {
  stop_port_forward
  kubectl delete namespace "${namespace}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete pv control-plane-state-pv --ignore-not-found >/dev/null 2>&1 || true
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

if [[ "${kind_sudo_mode}" == "always" ]]; then
  enable_kind_sudo
fi

if ! kind_cmd get clusters | grep -qx "${cluster_name}"; then
  create_cluster
  created_cluster=1
fi

refresh_kubeconfig
kubectl config use-context "kind-${cluster_name}" >/dev/null
kubectl wait --for=condition=Ready node --all --timeout=180s >/dev/null
load_kind_image "${control_plane_image}"
load_kind_image "${execution_plane_image}"
ssh-keygen -q -t ed25519 -N '' -f "${ssh_key}"
apply_resources
wait_for_control_plane_pod
start_port_forward
wait_for_ssh

ssh_bash <<EOF
set -euo pipefail
command -v node
command -v npm
npm ls -g @github/copilot --depth=0 | grep -q '@github/copilot@'
command -v git
command -v gh
command -v kubectl
command -v podman
command -v docker
command -v kind
docker --version >/dev/null
command -v sshd
command -v screen
command -v vim
test "\$(TERM=xterm-256color tput colors)" -ge 256
test "\$(TERM=screen-256color tput colors)" -ge 256
test "\$(TERM=tmux-256color tput colors)" -ge 256
printf '%s\n' "\${LANG}" | grep -qi 'utf-8'
test "\${LC_ALL}" = "en_US.UTF8"
locale charmap | grep -qx 'UTF-8'
locale -a | grep -Eqi '^en_US\.utf-?8$'
locale -a | grep -Eqi '^ja_JP\.utf-?8$'
test "\${EDITOR}" = "vim"
test "\${VISUAL}" = "vim"
test "\${GH_PAGER}" = "cat"
test -f ~/.copilot/skills/control-plane-operations/SKILL.md
uid_map_host_uid="\$(awk 'NR==1 { print \$2 }' /proc/self/uid_map)"
test -n "\${uid_map_host_uid}"
test "\${uid_map_host_uid}" != "0"
grep -qx 'graphroot = "/home/copilot/.copilot/containers/storage"' ~/.config/containers/storage.conf
grep -qx 'runroot = "/home/copilot/.copilot/run/containers/storage"' ~/.config/containers/storage.conf
test -d ~/.copilot/containers/storage/overlay
test -d ~/.copilot/containers/storage/volumes
kubectl auth can-i create jobs --namespace ${namespace} | grep -q '^yes$'
EOF

utf8_roundtrip="$(ssh_bash <<'EOF'
set -euo pipefail
printf '日本語★\n'
EOF
)"
[[ "${utf8_roundtrip}" == "日本語★" ]]

ssh_bash <<'EOF'
set -euo pipefail
mkdir -p ~/.copilot ~/.config/gh ~/.ssh /workspace
echo k8s > ~/.copilot/state.txt
echo gh > ~/.config/gh/state.txt
echo ssh > ~/.ssh/state.txt
screen -T screen-256color -dmS kind-session sh -lc 'printf "%s\n" "$TERM" > /workspace/k8s-screen-term.txt; printf "日本語★\n" > /workspace/k8s-screen-utf8.txt; echo k8s-screen > /workspace/k8s-screen.txt; sleep 30'
EOF

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

ssh_bash <<'EOF'
set -euo pipefail
grep -qx '日本語★' /workspace/k8s-screen-utf8.txt
EOF

job_name="$(ssh_bash <<EOF
set -euo pipefail
k8s-job-start --namespace ${namespace} --job-name ci-manual-job --image ${execution_plane_image} -- /usr/local/bin/execution-plane-smoke write-marker /workspace/manual-job.txt manual
EOF
)"
job_name="$(printf '%s' "${job_name}" | tr -d '\r\n')"

ssh_bash <<EOF
set -euo pipefail
k8s-job-wait --namespace ${namespace} --job-name ${job_name} --timeout 180s
EOF

pod_name="$(ssh_bash <<EOF
set -euo pipefail
k8s-job-pod --namespace ${namespace} --job-name ${job_name}
EOF
)"
pod_name="$(printf '%s' "${pod_name}" | tr -d '\r\n')"
[[ -n "${pod_name}" ]]

logs="$(ssh_bash <<EOF
set -euo pipefail
k8s-job-logs --namespace ${namespace} --job-name ${job_name}
EOF
)"
grep -q 'manual' <<<"${logs}"

ssh_bash <<'EOF'
set -euo pipefail
test -f /workspace/manual-job.txt
EOF

auto_output="$(ssh_bash <<EOF
set -euo pipefail
control-plane-run --mode auto --execution-hint long --namespace ${namespace} --job-name ci-auto-job --image ${execution_plane_image} -- /usr/local/bin/execution-plane-smoke write-marker /workspace/auto-job.txt auto
EOF
)"
grep -q 'auto' <<<"${auto_output}"

ssh_bash <<'EOF'
set -euo pipefail
test -f /workspace/auto-job.txt
EOF

ssh_bash <<EOF
set -euo pipefail
cat > /tmp/fake-podman <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$@" > /tmp/fake-podman.log
INNER
chmod +x /tmp/fake-podman
CONTROL_PLANE_PODMAN_BIN=/tmp/fake-podman control-plane-run --mode auto --execution-hint short --workspace /workspace --image ${execution_plane_image} -- /usr/local/bin/execution-plane-smoke write-marker /workspace/short-auto.txt short
grep -q '^run$' /tmp/fake-podman.log
grep -q '${execution_plane_image}' /tmp/fake-podman.log
EOF

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
test -f ~/.copilot/state.txt
test -f ~/.config/gh/state.txt
test -f ~/.ssh/state.txt
test -f /workspace/manual-job.txt
test -f /workspace/auto-job.txt
test -f /workspace/k8s-screen.txt
EOF
