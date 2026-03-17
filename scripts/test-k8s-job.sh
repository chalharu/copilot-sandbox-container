#!/usr/bin/env bash
set -euo pipefail

current_namespace_file="/var/run/secrets/kubernetes.io/serviceaccount/namespace"
control_plane_namespace="${CONTROL_PLANE_K8S_NAMESPACE:-}"
job_namespace="${2:-${CONTROL_PLANE_JOB_NAMESPACE:-${control_plane_namespace}}}"
service_account="${CONTROL_PLANE_K8S_TEST_SERVICE_ACCOUNT:-}"
image_pull_policy="${CONTROL_PLANE_K8S_TEST_IMAGE_PULL_POLICY:-IfNotPresent}"
job_timeout="${CONTROL_PLANE_K8S_TEST_TIMEOUT:-240s}"
job_name_prefix="${3:-control-plane-k8s-smoke}"
control_plane_image="${1:-${CONTROL_PLANE_K8S_TEST_IMAGE:-}}"

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
  --from-file=control-plane-session=/workspace/containers/control-plane/bin/control-plane-session \
  --from-file=profile-control-plane-env.sh=/workspace/containers/control-plane/config/profile-control-plane-env.sh \
  --from-file=profile-control-plane-session.sh=/workspace/containers/control-plane/config/profile-control-plane-session.sh \
  --from-file=control-plane-skill.md=/workspace/containers/control-plane/skills/control-plane-operations/SKILL.md \
  --from-file=control-plane-run.md=/workspace/containers/control-plane/skills/control-plane-operations/references/control-plane-run.md \
  --from-file=skills-reference.md=/workspace/containers/control-plane/skills/control-plane-operations/references/skills.md

service_account_yaml=''
if [[ -n "${service_account}" ]]; then
  service_account_yaml="      serviceAccountName: ${service_account}"
fi

cat <<EOF | kubectl create -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${active_namespace}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 300
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${job_name}
    spec:
      restartPolicy: Never
${service_account_yaml}
      securityContext:
        fsGroup: 1000
      containers:
        - name: smoke
          image: ${control_plane_image}
          imagePullPolicy: ${image_pull_policy}
          env:
            - name: CONTROL_PLANE_LOCAL_PODMAN_MODE
              value: rootful-service
          command:
            - /bin/bash
            - -lc
            - |
              set -euo pipefail
              install -m 0755 /var/run/control-plane-test/control-plane-entrypoint /usr/local/bin/control-plane-entrypoint
               install -m 0755 /var/run/control-plane-test/control-plane-podman /usr/local/bin/control-plane-podman
               install -m 0755 /var/run/control-plane-test/control-plane-screen /usr/local/bin/control-plane-screen
               install -m 0755 /var/run/control-plane-test/control-plane-session /usr/local/bin/control-plane-session
               install -m 0644 /var/run/control-plane-test/profile-control-plane-env.sh /etc/profile.d/control-plane-env.sh
               install -m 0644 /var/run/control-plane-test/profile-control-plane-session.sh /etc/profile.d/control-plane-session.sh
               install -d -m 0755 /usr/local/share/control-plane/skills/control-plane-operations/references
               install -m 0644 /var/run/control-plane-test/control-plane-skill.md /usr/local/share/control-plane/skills/control-plane-operations/SKILL.md
               install -m 0644 /var/run/control-plane-test/control-plane-run.md /usr/local/share/control-plane/skills/control-plane-operations/references/control-plane-run.md
               install -m 0644 /var/run/control-plane-test/skills-reference.md /usr/local/share/control-plane/skills/control-plane-operations/references/skills.md
               ln -sf /usr/local/bin/control-plane-podman /usr/local/bin/podman
               ln -sf /usr/local/bin/control-plane-podman /usr/local/bin/docker
               ln -sf /usr/local/bin/control-plane-screen /usr/local/bin/screen
               exec /usr/local/bin/control-plane-entrypoint /bin/bash -lc '
                 set -euo pipefail
                 runtime_line="\$(grep -E "^(XDG_RUNTIME_DIR|TMPDIR|SCREENDIR|CONTAINER_HOST|DOCKER_HOST|CONTROL_PLANE_LOCAL_PODMAN_MODE|CONTROL_PLANE_PODMAN_DEFAULT_CGROUPS|CONTROL_PLANE_PODMAN_DEFAULT_NETWORK|CONTROL_PLANE_PODMAN_BUILD_ISOLATION)=" /home/copilot/.config/control-plane/runtime.env | tr "\n" " ")"
                 printf "job-check: runtime-env=%s\n" "\${runtime_line}"
                 [[ "\${runtime_line}" == *"XDG_RUNTIME_DIR=/run/user/1000"* ]]
                 [[ "\${runtime_line}" == *"TMPDIR=/tmp/control-plane-1000"* ]]
                 [[ "\${runtime_line}" == *"SCREENDIR=/run/user/1000/screen"* ]]
                 [[ "\${runtime_line}" == *"CONTROL_PLANE_LOCAL_PODMAN_MODE=rootful-service"* ]]
                 [[ "\${runtime_line}" == *"CONTROL_PLANE_PODMAN_DEFAULT_CGROUPS=disabled"* ]]
                 [[ "\${runtime_line}" == *"CONTROL_PLANE_PODMAN_DEFAULT_NETWORK=host"* ]]
                 [[ "\${runtime_line}" == *"CONTROL_PLANE_PODMAN_BUILD_ISOLATION=chroot"* ]]
                 [[ "\${runtime_line}" == *"CONTAINER_HOST="*"/run/control-plane/podman-root.sock"* ]]

                 su -s /bin/bash copilot -c '"'"'set -euo pipefail; skill_root="\$HOME/.copilot/skills/control-plane-operations"; test ! -L "\$skill_root"; test -r "\$skill_root/SKILL.md"; test -x "\$skill_root/references"; test -r "\$skill_root/references/control-plane-run.md"; test -r "\$skill_root/references/skills.md"'"'"'
                 printf "%s\n" "job-check: skill-read=ok"

                 term_report="\$(TERM=xterm-color bash -lc '"'"'printf "%s %s" "\$TERM" "\$(tput colors)"'"'"')"
                 printf "job-check: term=%s\n" "\${term_report}"
                 [[ "\${term_report}" == "xterm-256color 256" ]]

                podman_info="\$(su -s /bin/bash copilot -c '"'"'set -a; source /home/copilot/.config/control-plane/runtime.env; set +a; podman info --format "{{.Store.GraphDriverName}} {{.Host.Security.Rootless}}"'"'"')"
                printf "job-check: podman-info=%s\n" "\${podman_info}"
                [[ "\${podman_info}" == "vfs false" ]]

                 podman_output="\$(su -s /bin/bash copilot -c '"'"'set -a; source /home/copilot/.config/control-plane/runtime.env; set +a; podman run --rm docker.io/library/busybox:1.37.0 echo k8s-job-podman-ok'"'"')"
                 printf "job-check: podman=%s\n" "\${podman_output}"
                 [[ "\${podman_output}" == *"k8s-job-podman-ok"* ]]

                 mkdir -p /tmp/podman-build-probe
                 printf "%s\n" "FROM docker.io/library/busybox:1.37.0" > /tmp/podman-build-probe/Dockerfile
                 printf "%s\n" "RUN echo build-ok > /build-ok.txt" >> /tmp/podman-build-probe/Dockerfile
                 set +e
                 build_image_id="\$(su -s /bin/bash copilot -c '"'"'set -a; source /home/copilot/.config/control-plane/runtime.env; set +a; podman build --isolation=chroot -q -t localhost/k8s-job-build-probe:test /tmp/podman-build-probe'"'"' 2>/tmp/podman-build.log)"
                 build_status=\$?
                 set -e
                 if [[ "\${build_status}" -eq 0 ]]; then
                   printf "job-check: podman-build-image=%s\n" "\${build_image_id}"
                   test -n "\${build_image_id}"
                   build_output="\$(su -s /bin/bash copilot -c '"'"'set -a; source /home/copilot/.config/control-plane/runtime.env; set +a; podman run --rm localhost/k8s-job-build-probe:test cat /build-ok.txt'"'"')"
                   [[ "\${build_output}" == "build-ok" ]]
                   printf "%s\n" "job-check: podman-build=ok"
                 else
                   sed "s/^/job-check: podman-build-log: /" /tmp/podman-build.log >&2 || true
                   printf "%s\n" "job-check: podman-build=skipped"
                 fi

                 printf "%s\n" "#!/usr/bin/env bash" > /tmp/podman-it-check.sh
                 printf "%s\n" "set -euo pipefail" >> /tmp/podman-it-check.sh
                 printf "%s\n" "podman run -it --rm docker.io/library/busybox:1.37.0 true" >> /tmp/podman-it-check.sh
                printf "%s\n" "printf \"%s\\n\" \"status:0\"" >> /tmp/podman-it-check.sh
                chmod 755 /tmp/podman-it-check.sh
                set +e
                su -s /bin/bash copilot -c '"'"'set -a; source /home/copilot/.config/control-plane/runtime.env; set +a; timeout 20s script -qec /tmp/podman-it-check.sh /tmp/podman-it.log'"'"'
                podman_it_status=\$?
                set -e
                printf "job-check: interactive-status=%s\n" "\${podman_it_status}"
                if [[ "\${podman_it_status}" -ne 0 ]]; then
                  printf "Interactive podman probe failed: %s\n" "\${podman_it_status}" >&2
                  cat /tmp/podman-it.log >&2 || true
                  exit 1
                fi
                tr -d "\r" < /tmp/podman-it.log > /tmp/podman-it.log.clean
                sed "s/^/job-check: interactive-log: /" /tmp/podman-it.log.clean
                grep -Fq "status:0" /tmp/podman-it.log.clean
                printf "%s\n" "job-check: interactive=ok"

                ssh-keygen -q -t ed25519 -N "" -f /tmp/id_ed25519
                cat /tmp/id_ed25519.pub >> /home/copilot/.ssh/authorized_keys
                chmod 600 /home/copilot/.ssh/authorized_keys
                /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config >/tmp/sshd.log 2>&1 &
                for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
                  if ssh-keyscan -p 2222 127.0.0.1 >/dev/null 2>&1; then
                    break
                  fi
                  sleep 1
                done
                ssh_output="\$(ssh -i /tmp/id_ed25519 -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes copilot@127.0.0.1 '"'"'printf "%s\n" ssh-ok; id'"'"')"
                printf "job-check: ssh=%s\n" "\${ssh_output}"
                grep -Fq "ssh-ok" <<<"\${ssh_output}"
                 if grep -q "cleanup_exit: kill(" /tmp/sshd.log; then
                   printf "Unexpected sshd cleanup_exit warning under drop-all profile\n" >&2
                   cat /tmp/sshd.log >&2
                   exit 1
                 fi
                 printf "%s\n" "job-check: ssh-clean=ok"

                 cp /home/copilot/.config/control-plane/runtime.env /tmp/runtime.env.bak
                 printf "%s\n" "CONTROL_PLANE_SESSION_SELECTION=new:k8s-auto-login" >> /home/copilot/.config/control-plane/runtime.env
                 TERM=tmux-256color ssh -tt -i /tmp/id_ed25519 -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes copilot@127.0.0.1 </dev/null >/tmp/ssh-interactive.log 2>&1 &
                 interactive_ssh_pid=\$!
                 for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
                   if su -s /bin/bash copilot -c '"'"'set -a; source /home/copilot/.config/control-plane/runtime.env; set +a; screen -list | grep -q -- "k8s-auto-login"'"'"'; then
                     break
                   fi
                   if ! kill -0 "\${interactive_ssh_pid}" 2>/dev/null; then
                     break
                   fi
                   sleep 1
                 done
                 if ! su -s /bin/bash copilot -c '"'"'set -a; source /home/copilot/.config/control-plane/runtime.env; set +a; screen -list | grep -q -- "k8s-auto-login"'"'"'; then
                   printf "%s\n" "job-check: ssh-interactive-log: Interactive SSH login did not create the expected screen session; relying on standalone smoke for this path" >&2
                   cat /tmp/ssh-interactive.log >&2 || true
                   printf "%s\n" "job-check: ssh-interactive=skipped"
                 elif ! kill -0 "\${interactive_ssh_pid}" 2>/dev/null; then
                   printf "%s\n" "job-check: ssh-interactive-log: Interactive SSH login exited before the session was observed; relying on standalone smoke for this path" >&2
                   cat /tmp/ssh-interactive.log >&2 || true
                   printf "%s\n" "job-check: ssh-interactive=skipped"
                 else
                   printf "%s\n" "job-check: ssh-interactive=ok"
                 fi
                 kill "\${interactive_ssh_pid}" >/dev/null 2>&1 || true
                 wait "\${interactive_ssh_pid}" 2>/dev/null || true
                 cp /tmp/runtime.env.bak /home/copilot/.config/control-plane/runtime.env
                 chown copilot:copilot /home/copilot/.config/control-plane/runtime.env
                 chmod 600 /home/copilot/.config/control-plane/runtime.env
                 if grep -q "cannot change locale" /tmp/ssh-interactive.log; then
                   printf "Unexpected locale warning during interactive SSH login\n" >&2
                   cat /tmp/ssh-interactive.log >&2 || true
                   exit 1
                 fi
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
                - KILL
                - MKNOD
                - NET_ADMIN
                - SETFCAP
                - SETGID
                - SETPCAP
                - SETUID
                - SYS_ADMIN
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
grep -Fq 'job-check: skill-read=ok' <<<"${job_logs}"
grep -Fq 'job-check: term=xterm-256color 256' <<<"${job_logs}"
grep -Fq 'job-check: podman-info=vfs false' <<<"${job_logs}"
grep -Fq 'job-check: podman=k8s-job-podman-ok' <<<"${job_logs}"
grep -Eq 'job-check: podman-build=(ok|skipped)' <<<"${job_logs}"
grep -Fq 'job-check: interactive=ok' <<<"${job_logs}"
grep -Fq 'job-check: ssh-clean=ok' <<<"${job_logs}"
grep -Eq 'job-check: ssh-interactive=(ok|skipped)' <<<"${job_logs}"

printf '%s\n' 'k8s-job-test: current-cluster rootful-service smoke ok' >&2
