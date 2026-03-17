#!/usr/bin/env bash
set -euo pipefail

current_namespace_file="/var/run/secrets/kubernetes.io/serviceaccount/namespace"
control_plane_namespace="${CONTROL_PLANE_K8S_NAMESPACE:-}"
job_namespace="${2:-${CONTROL_PLANE_JOB_NAMESPACE:-${control_plane_namespace}}}"
service_account="${CONTROL_PLANE_K8S_TEST_SERVICE_ACCOUNT:-}"
host_users="${CONTROL_PLANE_K8S_TEST_HOST_USERS:-}"
image_pull_policy="${CONTROL_PLANE_K8S_TEST_IMAGE_PULL_POLICY:-IfNotPresent}"
job_timeout="${CONTROL_PLANE_K8S_TEST_TIMEOUT:-180s}"
job_name_prefix="${3:-control-plane-k8s-smoke}"
control_plane_image="${1:-${CONTROL_PLANE_K8S_TEST_IMAGE:-}}"
podman_run_args="${CONTROL_PLANE_K8S_TEST_PODMAN_RUN_ARGS:-}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

default_namespace() {
  if [[ -f "${current_namespace_file}" ]]; then
    cat "${current_namespace_file}"
    return
  fi

  printf 'default\n'
}

detect_control_plane_image() {
  local namespace="$1"
  local pod_name

  if [[ -n "${control_plane_image}" ]]; then
    printf '%s\n' "${control_plane_image}"
    return
  fi

  pod_name="$(hostname)"
  kubectl get pod "${pod_name}" -n "${namespace}" -o jsonpath='{.spec.containers[?(@.name=="control-plane")].image}'
}

cleanup() {
  kubectl delete job "${job_name}" -n "${active_namespace}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete configmap "${configmap_name}" -n "${active_namespace}" --ignore-not-found >/dev/null 2>&1 || true
}

require_command kubectl

if [[ -z "${control_plane_namespace}" ]]; then
  control_plane_namespace="$(default_namespace)"
fi
if [[ -z "${job_namespace}" ]]; then
  job_namespace="${control_plane_namespace}"
fi

active_namespace="${job_namespace}"
control_plane_image="$(detect_control_plane_image "${control_plane_namespace}")"
job_name="${job_name_prefix}-$(date +%s)-$RANDOM"
job_name="${job_name,,}"
job_name="${job_name//[^a-z0-9-]/-}"
job_name="${job_name:0:63}"
job_name="${job_name%-}"
configmap_name="${job_name}-files"
configmap_name="${configmap_name:0:63}"
configmap_name="${configmap_name%-}"

trap cleanup EXIT
kubectl delete job "${job_name}" -n "${active_namespace}" --ignore-not-found >/dev/null 2>&1 || true
kubectl delete configmap "${configmap_name}" -n "${active_namespace}" --ignore-not-found >/dev/null 2>&1 || true

kubectl create configmap "${configmap_name}" \
  -n "${active_namespace}" \
  --from-file=control-plane-entrypoint=/workspace/containers/control-plane/bin/control-plane-entrypoint \
  --from-file=control-plane-podman=/workspace/containers/control-plane/bin/control-plane-podman \
  --from-file=control-plane-screen=/workspace/containers/control-plane/bin/control-plane-screen \
  --from-file=profile-control-plane-env.sh=/workspace/containers/control-plane/config/profile-control-plane-env.sh

service_account_yaml=''
if [[ -n "${service_account}" ]]; then
  service_account_yaml="      serviceAccountName: ${service_account}"
fi

host_users_yaml=''
if [[ -n "${host_users}" ]]; then
  host_users_yaml="      hostUsers: ${host_users}"
fi

cat <<EOF | kubectl create -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${active_namespace}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 240
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${job_name}
    spec:
${host_users_yaml}
      restartPolicy: Never
${service_account_yaml}
      securityContext:
        fsGroup: 1000
      containers:
        - name: smoke
          image: ${control_plane_image}
          imagePullPolicy: ${image_pull_policy}
          command:
            - /bin/bash
            - -lc
            - |
              set -euo pipefail
              install -m 0755 /var/run/control-plane-test/control-plane-entrypoint /usr/local/bin/control-plane-entrypoint
              install -m 0755 /var/run/control-plane-test/control-plane-podman /usr/local/bin/control-plane-podman
              install -m 0755 /var/run/control-plane-test/control-plane-screen /usr/local/bin/control-plane-screen
              install -m 0644 /var/run/control-plane-test/profile-control-plane-env.sh /etc/profile.d/control-plane-env.sh
              ln -sf /usr/local/bin/control-plane-podman /usr/local/bin/podman
              ln -sf /usr/local/bin/control-plane-podman /usr/local/bin/docker
              ln -sf /usr/local/bin/control-plane-screen /usr/local/bin/screen
              mkdir -p /home/copilot/.copilot/containers/overlay/storage/overlay/l
              ln -sfn /does-not-exist /home/copilot/.copilot/containers/overlay/storage/overlay/l/BROKENLINK
              exec /usr/local/bin/control-plane-entrypoint /bin/bash -lc '
                set -euo pipefail
                runtime_line="\$(grep -E "^(XDG_RUNTIME_DIR|TMPDIR|SCREENDIR)=" /home/copilot/.config/control-plane/runtime.env | tr "\n" " ")"
                printf "job-check: runtime-env=%s\n" "\${runtime_line}"
                [[ "\${runtime_line}" == *"XDG_RUNTIME_DIR=/run/user/1000"* ]]
                [[ "\${runtime_line}" == *"TMPDIR=/tmp/control-plane-1000"* ]]
                [[ "\${runtime_line}" == *"SCREENDIR=/run/user/1000/screen"* ]]
                term_report="\$(TERM=xterm-color bash -lc '"'"'printf "%s %s" "\$TERM" "\$(tput colors)"'"'"')"
                printf "job-check: term=%s\n" "\${term_report}"
                [[ "\${term_report}" == "xterm-256color 256" ]]
                podman_output="\$(su -s /bin/bash copilot -c '"'"'/usr/local/bin/control-plane-podman run ${podman_run_args} --rm --network=none docker.io/library/busybox:1.37.0 echo k8s-job-podman-ok'"'"')"
                printf "job-check: podman=%s\n" "\${podman_output}"
                [[ "\${podman_output}" == *"k8s-job-podman-ok"* ]]
                printf "job-check: symlink-safe-chown=ok\n"
              '
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
                - SETFCAP
                - SETGID
                - SETUID
                - SYS_CHROOT
            seccompProfile:
              type: Unconfined
            appArmorProfile:
              type: Unconfined
          volumeMounts:
            - name: test-files
              mountPath: /var/run/control-plane-test
              readOnly: true
            - name: state
              mountPath: /home/copilot/.copilot
      volumes:
        - name: test-files
          configMap:
            name: ${configmap_name}
            defaultMode: 0555
        - name: state
          emptyDir: {}
EOF

if ! kubectl wait --for=condition=complete "job/${job_name}" -n "${active_namespace}" --timeout="${job_timeout}" >/dev/null; then
  kubectl logs "job/${job_name}" -n "${active_namespace}" --all-containers=true || true
  kubectl describe "job/${job_name}" -n "${active_namespace}" || true
  kubectl get pods -n "${active_namespace}" -l "job-name=${job_name}" -o wide || true
  exit 1
fi

job_logs="$(kubectl logs "job/${job_name}" -n "${active_namespace}" --all-containers=true)"
printf '%s\n' "${job_logs}"

grep -Fq 'job-check: runtime-env=' <<<"${job_logs}"
grep -Fq 'job-check: term=xterm-256color 256' <<<"${job_logs}"
grep -Fq 'job-check: podman=k8s-job-podman-ok' <<<"${job_logs}"
grep -Fq 'job-check: symlink-safe-chown=ok' <<<"${job_logs}"

printf '%s\n' 'k8s-job-test: least-privilege Podman smoke ok' >&2
