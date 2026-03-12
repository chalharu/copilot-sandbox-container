#!/usr/bin/env bash
set -euo pipefail

control_plane_image="${1:?usage: scripts/test-kind.sh <control-plane-image> <execution-plane-image> [cluster-name]}"
execution_plane_image="${2:?usage: scripts/test-kind.sh <control-plane-image> <execution-plane-image> [cluster-name]}"
cluster_name="${3:-control-plane-ci}"
namespace="${CONTROL_PLANE_TEST_NAMESPACE:-control-plane-ci}"
ssh_port="${CONTROL_PLANE_TEST_SSH_PORT:-32222}"
workdir="$(mktemp -d)"
ssh_key="${workdir}/id_ed25519"
port_forward_pid=""
created_cluster=0

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

ssh_opts=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o IdentitiesOnly=yes
  -i "${ssh_key}"
  -p "${ssh_port}"
)

ssh_cmd() {
  # shellcheck disable=SC2029
  ssh "${ssh_opts[@]}" copilot@127.0.0.1 "$@"
}

ssh_bash() {
  ssh "${ssh_opts[@]}" copilot@127.0.0.1 'bash -se'
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

stop_port_forward() {
  if [[ -n "${port_forward_pid}" ]]; then
    kill "${port_forward_pid}" >/dev/null 2>&1 || true
    wait "${port_forward_pid}" 2>/dev/null || true
    port_forward_pid=""
  fi
}

start_port_forward() {
  stop_port_forward
  kubectl port-forward --namespace "${namespace}" pod/control-plane "${ssh_port}:2222" >"${workdir}/port-forward.log" 2>&1 &
  port_forward_pid=$!
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
kind: Pod
metadata:
  name: control-plane
  namespace: ${namespace}
spec:
  serviceAccountName: control-plane
  initContainers:
    - name: init-state
      image: busybox:1.36
      command:
        - sh
        - -c
        - mkdir -p /state/copilot /state/gh /state/ssh /state/workspace && chmod 700 /state/ssh
      volumeMounts:
        - name: state
          mountPath: /state
  containers:
    - name: control-plane
      image: ${control_plane_image}
      imagePullPolicy: IfNotPresent
      env:
        - name: SSH_PUBLIC_KEY
          value: "${public_key}"
        - name: CONTROL_PLANE_K8S_NAMESPACE
          value: ${namespace}
        - name: CONTROL_PLANE_WORKSPACE_PVC
          value: control-plane-state-pvc
        - name: CONTROL_PLANE_WORKSPACE_SUBPATH
          value: workspace
        - name: CONTROL_PLANE_JOB_SERVICE_ACCOUNT
          value: control-plane
      ports:
        - containerPort: 2222
          name: ssh
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
          mountPath: /workspace
          subPath: workspace
  volumes:
    - name: state
      persistentVolumeClaim:
        claimName: control-plane-state-pvc
EOF
}

cleanup() {
  stop_port_forward
  kubectl delete namespace "${namespace}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete pv control-plane-state-pv --ignore-not-found >/dev/null 2>&1 || true
  if [[ "${created_cluster}" -eq 1 ]]; then
    kind delete cluster --name "${cluster_name}" >/dev/null 2>&1 || true
  fi
  rm -rf "${workdir}"
}
trap cleanup EXIT

require_command docker
require_command kind
require_command kubectl
require_command ssh
require_command ssh-keygen

if ! kind get clusters | grep -qx "${cluster_name}"; then
  kind create cluster --name "${cluster_name}"
  created_cluster=1
fi

kubectl config use-context "kind-${cluster_name}" >/dev/null
kubectl wait --for=condition=Ready node --all --timeout=180s >/dev/null
kind load docker-image "${control_plane_image}" --name "${cluster_name}"
kind load docker-image "${execution_plane_image}" --name "${cluster_name}"
ssh-keygen -q -t ed25519 -N '' -f "${ssh_key}"
apply_resources
kubectl wait --namespace "${namespace}" --for=condition=Ready pod/control-plane --timeout=180s >/dev/null
start_port_forward
wait_for_ssh

ssh_bash <<EOF
set -euo pipefail
command -v node
command -v npm
npm ls -g @github/copilot-cli --depth=0 | grep -q '@github/copilot-cli@'
command -v git
command -v gh
command -v kubectl
command -v podman
command -v docker
command -v sshd
command -v screen
kubectl auth can-i create jobs --namespace ${namespace} | grep -q '^yes$'
EOF

ssh_bash <<'EOF'
set -euo pipefail
mkdir -p ~/.copilot ~/.config/gh ~/.ssh /workspace
echo k8s > ~/.copilot/state.txt
echo gh > ~/.config/gh/state.txt
echo ssh > ~/.ssh/state.txt
screen -dmS kind-session sh -lc 'echo k8s-screen > /workspace/k8s-screen.txt; sleep 30'
EOF

sleep 2
ssh_bash <<'EOF'
set -euo pipefail
screen -list | grep -q kind-session
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

stop_port_forward
kubectl delete pod control-plane --namespace "${namespace}" --wait=true >/dev/null
apply_resources
kubectl wait --namespace "${namespace}" --for=condition=Ready pod/control-plane --timeout=180s >/dev/null
start_port_forward
wait_for_ssh

ssh_bash <<'EOF'
set -euo pipefail
test -f ~/.copilot/state.txt
test -f ~/.config/gh/state.txt
test -f ~/.ssh/state.txt
test -f /workspace/manual-job.txt
test -f /workspace/auto-job.txt
test -f /workspace/k8s-screen.txt
EOF
