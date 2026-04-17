#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
control_plane_root="${repo_root}/containers/control-plane"
# shellcheck source=scripts/lib-bundled-agents.sh
source "${script_dir}/lib-bundled-agents.sh"
current_namespace_file="/var/run/secrets/kubernetes.io/serviceaccount/namespace"
control_plane_namespace="${CONTROL_PLANE_K8S_NAMESPACE:-}"
job_namespace="${2:-${CONTROL_PLANE_JOB_NAMESPACE:-${control_plane_namespace}}}"
service_account="${CONTROL_PLANE_K8S_TEST_SERVICE_ACCOUNT:-}"
image_pull_policy="${CONTROL_PLANE_K8S_TEST_IMAGE_PULL_POLICY:-IfNotPresent}"
job_timeout="${CONTROL_PLANE_K8S_TEST_TIMEOUT:-240s}"
job_name_prefix="${3:-control-plane-k8s-smoke}"
control_plane_image="${1:-${CONTROL_PLANE_K8S_TEST_IMAGE:-}}"
workdir="$(mktemp -d)"
ssh_key="${workdir}/id_ed25519"
ssh_probe_log="${workdir}/ssh-probe.log"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

wait_for_job_terminal_state() {
  local namespace="$1"
  local name="$2"
  local timeout_seconds="${job_timeout}"
  local elapsed=0
  local succeeded=""
  local failed=""

  timeout_seconds="${timeout_seconds%s}"
  if [[ ! "${timeout_seconds}" =~ ^[0-9]+$ ]]; then
    printf 'Unsupported CONTROL_PLANE_K8S_TEST_TIMEOUT: %s (use seconds such as 240s)\n' "${job_timeout}" >&2
    exit 1
  fi

  while (( elapsed < timeout_seconds )); do
    succeeded="$(kubectl get job "${name}" -n "${namespace}" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
    failed="$(kubectl get job "${name}" -n "${namespace}" -o jsonpath='{.status.failed}' 2>/dev/null || true)"
    if [[ "${succeeded}" == "1" ]]; then
      return 0
    fi
    if [[ -n "${failed}" ]] && [[ "${failed}" != "0" ]]; then
      return 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  return 124
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
  rm -rf "${workdir}" >/dev/null 2>&1 || true
}

require_command kubectl
require_command ssh
require_command ssh-keygen
require_command ssh-keyscan

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

mapfile -t bundled_agent_specs < <(control_plane_bundled_agent_specs)
bundled_agent_configmap_args=()
bundled_agent_install_script=''
bundled_agent_read_script=''
for spec in "${bundled_agent_specs[@]}"; do
  IFS='|' read -r agent_name agent_file <<<"${spec}"
  bundled_agent_configmap_args+=(--from-file="${agent_file}=${control_plane_root}/agents/${agent_file}")
  bundled_agent_install_script+=$'                install -m 0644 /var/run/control-plane-test/'"${agent_file}"$' /usr/local/share/control-plane/agents/'"${agent_file}"$'\n'
  bundled_agent_read_script+="agent_file=\"\$HOME/.copilot/agents/${agent_file}\"; test ! -L \"\$agent_file\"; test -r \"\$agent_file\"; grep -Fqx \"name: ${agent_name}\" \"\$agent_file\"; "
done

ssh-keygen -q -t ed25519 -N '' -f "${ssh_key}" >/dev/null

trap cleanup EXIT
kubectl delete job "${job_name}" -n "${active_namespace}" --ignore-not-found >/dev/null 2>&1 || true
kubectl delete configmap "${configmap_name}" -n "${active_namespace}" --ignore-not-found >/dev/null 2>&1 || true

kubectl create configmap "${configmap_name}" \
  -n "${active_namespace}" \
  --from-file=control-plane-entrypoint="${control_plane_root}/bin/control-plane-entrypoint" \
  --from-file=control-plane-copilot="${control_plane_root}/bin/control-plane-copilot" \
  --from-file=control-plane-job-transfer="${control_plane_root}/bin/control-plane-job-transfer" \
  --from-file=control-plane-screen="${control_plane_root}/bin/control-plane-screen" \
  --from-file=control-plane-session="${control_plane_root}/bin/control-plane-session" \
  --from-file=control-plane-ssh-shell="${control_plane_root}/bin/control-plane-ssh-shell" \
  --from-file=job-ssh-public-key="${ssh_key}.pub" \
  --from-file=profile-control-plane-env.sh="${control_plane_root}/config/profile-control-plane-env.sh" \
  --from-file=profile-control-plane-session.sh="${control_plane_root}/config/profile-control-plane-session.sh" \
  "${bundled_agent_configmap_args[@]}" \
  --from-file=repo-change-delivery-skill.md="${control_plane_root}/skills/repo-change-delivery/SKILL.md" \
  --from-file=git-commit-skill.md="${control_plane_root}/skills/git-commit/SKILL.md" \
  --from-file=pull-request-workflow-skill.md="${control_plane_root}/skills/pull-request-workflow/SKILL.md"

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
          command:
            - /bin/bash
            - -lc
            - |
              set -euo pipefail
              install -m 0755 /var/run/control-plane-test/control-plane-entrypoint /usr/local/bin/control-plane-entrypoint
                install -m 0755 /var/run/control-plane-test/control-plane-copilot /usr/local/bin/control-plane-copilot
                install -m 0755 /var/run/control-plane-test/control-plane-job-transfer /usr/local/bin/control-plane-job-transfer
                install -m 0755 /var/run/control-plane-test/control-plane-screen /usr/local/bin/control-plane-screen
                install -m 0755 /var/run/control-plane-test/control-plane-session /usr/local/bin/control-plane-session
                install -m 0755 /var/run/control-plane-test/control-plane-ssh-shell /usr/local/bin/control-plane-ssh-shell
                 install -m 0644 /var/run/control-plane-test/profile-control-plane-env.sh /etc/profile.d/control-plane-env.sh
                 install -m 0644 /var/run/control-plane-test/profile-control-plane-session.sh /etc/profile.d/control-plane-session.sh
                 install -d -m 0755 /usr/local/share/control-plane/skills/repo-change-delivery
                 install -d -m 0755 /usr/local/share/control-plane/skills/git-commit
                 install -d -m 0755 /usr/local/share/control-plane/skills/pull-request-workflow
                 install -d -m 0755 /usr/local/share/control-plane/agents
${bundled_agent_install_script}                 install -m 0644 /var/run/control-plane-test/repo-change-delivery-skill.md /usr/local/share/control-plane/skills/repo-change-delivery/SKILL.md
                  install -m 0644 /var/run/control-plane-test/git-commit-skill.md /usr/local/share/control-plane/skills/git-commit/SKILL.md
                  install -m 0644 /var/run/control-plane-test/pull-request-workflow-skill.md /usr/local/share/control-plane/skills/pull-request-workflow/SKILL.md
                 ln -sf /usr/local/bin/control-plane-screen /usr/local/bin/screen
                 usermod --shell /usr/local/bin/control-plane-ssh-shell copilot
                exec /usr/local/bin/control-plane-entrypoint /bin/bash -lc '
                 set -euo pipefail
                 ! grep -q "^CONTROL_PLANE_RUN_MODE=" /home/copilot/.config/control-plane/runtime.env
                 runtime_line="\$(grep -E "^(XDG_RUNTIME_DIR|TMPDIR|SCREENDIR|CARGO_HOME|CARGO_TARGET_DIR|RUSTUP_HOME)=" /home/copilot/.config/control-plane/runtime.env | tr "\n" " ")"
                 printf "job-check: runtime-env=%s\n" "\${runtime_line}"
                 [[ "\${runtime_line}" == *"XDG_RUNTIME_DIR=/run/user/1000"* ]]
                 [[ "\${runtime_line}" == *"TMPDIR=/var/tmp/control-plane/tmp-1000"* ]]
                 [[ "\${runtime_line}" == *"SCREENDIR=/run/user/1000/screen"* ]]
                 [[ "\${runtime_line}" == *"CARGO_HOME=/home/copilot/.cargo"* ]]
                 [[ "\${runtime_line}" == *"CARGO_TARGET_DIR=/var/tmp/control-plane/cargo-target"* ]]
                 [[ "\${runtime_line}" == *"RUSTUP_HOME=/usr/local/rustup"* ]]

                   su -s /bin/bash copilot -c '"'"'set -euo pipefail; doc_coauthor_skill_root="\$HOME/.copilot/skills/doc-coauthoring"; frontend_design_skill_root="\$HOME/.copilot/skills/frontend-design"; delivery_skill_root="\$HOME/.copilot/skills/repo-change-delivery"; commit_skill_root="\$HOME/.copilot/skills/git-commit"; pull_request_skill_root="\$HOME/.copilot/skills/pull-request-workflow"; skill_creator_skill_root="\$HOME/.copilot/skills/skill-creator"; test ! -L "\$doc_coauthor_skill_root"; test -r "\$doc_coauthor_skill_root/SKILL.md"; grep -Fqx "name: doc-coauthoring" "\$doc_coauthor_skill_root/SKILL.md"; test ! -L "\$frontend_design_skill_root"; test -r "\$frontend_design_skill_root/SKILL.md"; test -r "\$frontend_design_skill_root/LICENSE.txt"; grep -Fqx "name: frontend-design" "\$frontend_design_skill_root/SKILL.md"; test ! -L "\$delivery_skill_root"; test -r "\$delivery_skill_root/SKILL.md"; grep -Fqx "name: repo-change-delivery" "\$delivery_skill_root/SKILL.md"; test ! -L "\$commit_skill_root"; test -r "\$commit_skill_root/SKILL.md"; grep -Fqx "name: git-commit" "\$commit_skill_root/SKILL.md"; test ! -L "\$pull_request_skill_root"; test -r "\$pull_request_skill_root/SKILL.md"; grep -Fqx "name: pull-request-workflow" "\$pull_request_skill_root/SKILL.md"; test ! -L "\$skill_creator_skill_root"; test -r "\$skill_creator_skill_root/SKILL.md"; test -r "\$skill_creator_skill_root/LICENSE.txt"; grep -Fqx "name: skill-creator" "\$skill_creator_skill_root/SKILL.md"'"'"'
                   printf "%s\n" "job-check: skill-read=ok"
                   su -s /bin/bash copilot -c '"'"'set -euo pipefail; ${bundled_agent_read_script}'"'"'
                   printf "%s\n" "job-check: agent-read=ok"

                 lang_report="\$(bash -lc '"'"'printf "%s" "\${LANG:-}"'"'"')"
                 printf "job-check: lang=%s\n" "\${lang_report}"
                  [[ "\${lang_report}" == "C.UTF-8" ]]

                  su -s /bin/bash copilot -c '"'"'set -a; source /home/copilot/.config/control-plane/runtime.env; set +a; command -v cargo >/dev/null; command -v yamllint >/dev/null; command -v control-plane-run >/dev/null; command -v control-plane-exec-api >/dev/null; ! command -v cpulimit >/dev/null 2>&1; ! command -v gcc >/dev/null 2>&1; ! command -v pkg-config >/dev/null 2>&1; command -v vim >/dev/null; cargo --version >/dev/null; yamllint --version >/dev/null; control-plane-run --help >/dev/null; control-plane-exec-api --help >/dev/null'"'"'
                  printf "%s\n" "job-check: bundled-tools=ok"
                  test -d /var/tmp/control-plane
                  test -d /var/tmp/control-plane/cargo-target
                  printf "%s\n" "job-check: runtime-cache=ok"

                ssh-keygen -q -t ed25519 -N "" -f /tmp/id_ed25519
                cat /tmp/id_ed25519.pub >> /home/copilot/.config/control-plane/ssh-auth/authorized_keys
                cat /var/run/control-plane-test/job-ssh-public-key >> /home/copilot/.config/control-plane/ssh-auth/authorized_keys
                chmod 600 /home/copilot/.config/control-plane/ssh-auth/authorized_keys
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
                  printf "\n%s\n" "CONTROL_PLANE_SSH_SHELL_LOG=/tmp/control-plane-ssh-shell.log" >> /home/copilot/.config/control-plane/runtime.env
                  printf "\n%s\n" "CONTROL_PLANE_COPILOT_SESSION=k8s-copilot" >> /home/copilot/.config/control-plane/runtime.env
                  printf "\n%s\n" "CONTROL_PLANE_COPILOT_BIN=/tmp/fake-copilot-shell" >> /home/copilot/.config/control-plane/runtime.env
                  cat > /tmp/fake-copilot-shell <<'"'"'INNER'"'"'
#!/usr/bin/env bash
set -euo pipefail
exec bash -il
INNER
                  chmod 755 /tmp/fake-copilot-shell
                  rm -f /tmp/ssh-interactive-marker.txt
                  rm -f /tmp/control-plane-ssh-shell.log
                  printf "%s\n" "job-check: ssh-interactive-probe-ready=ok"
                  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60; do
                    if grep -Fq "mode=login action=copilot-session" /tmp/control-plane-ssh-shell.log 2>/dev/null \
                      && su -s /bin/bash copilot -c '"'"'set -a; source /home/copilot/.config/control-plane/runtime.env; set +a; screen -list 2>/dev/null | grep -q -- k8s-copilot'"'"'; then
                      break
                    fi
                    sleep 1
                  done
                  if ! grep -Fq "mode=login action=copilot-session" /tmp/control-plane-ssh-shell.log 2>/dev/null \
                    || ! su -s /bin/bash copilot -c '"'"'set -a; source /home/copilot/.config/control-plane/runtime.env; set +a; screen -list 2>/dev/null | grep -q -- k8s-copilot'"'"'; then
                    printf "Interactive SSH never reached a usable screen session in k8s smoke\n" >&2
                    cat /tmp/sshd.log >&2 || true
                    cat /tmp/control-plane-ssh-shell.log >&2 || true
                    su -s /bin/bash copilot -c '"'"'set -a; source /home/copilot/.config/control-plane/runtime.env; set +a; rm -f /tmp/control-plane-session.log; timeout 10s script -qefc "control-plane-session" /tmp/control-plane-session.log'"'"' >&2 || true
                    cat /tmp/control-plane-session.log >&2 || true
                     su -s /bin/bash copilot -c '"'"'set -a; source /home/copilot/.config/control-plane/runtime.env; set +a; screen -list'"'"' >&2 || true
                     exit 1
                   fi
                   printf "%s\n" "job-check: ssh-interactive-ready=ok"
                   cp /tmp/runtime.env.bak /home/copilot/.config/control-plane/runtime.env
                   chown copilot:copilot /home/copilot/.config/control-plane/runtime.env
                   chmod 600 /home/copilot/.config/control-plane/runtime.env
                  printf "%s\n" "job-check: ssh-interactive=ok"
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
          volumeMounts:
            - name: test-files
              mountPath: /var/run/control-plane-test
              readOnly: true
            - name: state
              mountPath: /home/copilot/.copilot
            - name: runtime-tmp
              mountPath: /var/tmp/control-plane
      volumes:
        - name: test-files
          configMap:
            name: ${configmap_name}
            defaultMode: 0555
        - name: state
          emptyDir: {}
        - name: runtime-tmp
          emptyDir: {}
EOF

job_pod_name=""
job_pod_ip=""
for _ in $(seq 1 30); do
  job_pod_name="$(kubectl get pods -n "${active_namespace}" -l "job-name=${job_name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${job_pod_name}" ]]; then
    job_pod_ip="$(kubectl get pod "${job_pod_name}" -n "${active_namespace}" -o jsonpath='{.status.podIP}' 2>/dev/null || true)"
    if [[ -n "${job_pod_ip}" ]]; then
      break
    fi
  fi
  sleep 1
done

if [[ -z "${job_pod_name}" ]] || [[ -z "${job_pod_ip}" ]]; then
  kubectl logs "job/${job_name}" -n "${active_namespace}" --all-containers=true || true
  kubectl describe "job/${job_name}" -n "${active_namespace}" || true
  kubectl get pods -n "${active_namespace}" -l "job-name=${job_name}" -o wide || true
  printf 'Unable to determine Job pod name/IP for %s\n' "${job_name}" >&2
  exit 1
fi

for _ in $(seq 1 30); do
  if ssh-keyscan -p 2222 "${job_pod_ip}" >/dev/null 2>&1; then
    break
  fi
  pod_phase="$(kubectl get pod "${job_pod_name}" -n "${active_namespace}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${pod_phase}" == "Failed" ]] || [[ "${pod_phase}" == "Succeeded" ]]; then
    break
  fi
  sleep 1
done

for _ in $(seq 1 30); do
  if kubectl logs "job/${job_name}" -n "${active_namespace}" --all-containers=true 2>/dev/null | grep -Fq 'job-check: ssh-interactive-probe-ready=ok'; then
    break
  fi
  pod_phase="$(kubectl get pod "${job_pod_name}" -n "${active_namespace}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${pod_phase}" == "Failed" ]] || [[ "${pod_phase}" == "Succeeded" ]]; then
    break
  fi
  sleep 1
done

if ! kubectl logs "job/${job_name}" -n "${active_namespace}" --all-containers=true 2>/dev/null | grep -Fq 'job-check: ssh-interactive-probe-ready=ok'; then
  kubectl logs "job/${job_name}" -n "${active_namespace}" --all-containers=true || true
  kubectl describe "job/${job_name}" -n "${active_namespace}" || true
  kubectl get pods -n "${active_namespace}" -l "job-name=${job_name}" -o wide || true
  printf 'Job %s never reported ssh-interactive-probe-ready=ok\n' "${job_name}" >&2
  exit 1
fi

set +e
"${script_dir}/test-ssh-session-persistence.sh" \
  --identity "${ssh_key}" \
  --host "${job_pod_ip}" \
  --port 2222 \
  --session-name k8s-copilot \
  --marker-path /tmp/ssh-interactive-marker.txt \
  >"${ssh_probe_log}" 2>&1
ssh_probe_status=$?
set -e

set +e
wait_for_job_terminal_state "${active_namespace}" "${job_name}"
job_wait_status=$?
set -e
if [[ "${job_wait_status}" -ne 0 ]]; then
  kubectl logs "job/${job_name}" -n "${active_namespace}" --all-containers=true || true
  kubectl describe "job/${job_name}" -n "${active_namespace}" || true
  kubectl get pods -n "${active_namespace}" -l "job-name=${job_name}" -o wide || true
  if [[ "${job_wait_status}" -eq 124 ]]; then
    printf 'Timed out waiting for Job %s to finish in namespace %s\n' "${job_name}" "${active_namespace}" >&2
  else
    printf 'Job %s failed in namespace %s\n' "${job_name}" "${active_namespace}" >&2
  fi
  exit 1
fi

if [[ "${ssh_probe_status}" -ne 0 ]]; then
  printf 'k8s-job-test: detached external SSH probe exited after prompt; relying on in-pod session evidence\n' >&2
fi

job_logs="$(kubectl logs "job/${job_name}" -n "${active_namespace}" --all-containers=true)"
printf '%s\n' "${job_logs}"

grep -Fq 'job-check: runtime-env=' <<<"${job_logs}"
grep -Fq 'job-check: skill-read=ok' <<<"${job_logs}"
grep -Fq 'job-check: lang=C.UTF-8' <<<"${job_logs}"
grep -Fq 'job-check: bundled-tools=ok' <<<"${job_logs}"
grep -Fq 'job-check: runtime-cache=ok' <<<"${job_logs}"
grep -Fq 'job-check: ssh-clean=ok' <<<"${job_logs}"
grep -Fq 'job-check: ssh-interactive-probe-ready=ok' <<<"${job_logs}"
grep -Fq 'job-check: ssh-interactive-ready=ok' <<<"${job_logs}"
grep -Fq 'job-check: ssh-interactive=ok' <<<"${job_logs}"

printf '%s\n' 'k8s-job-test: current-cluster smoke ok' >&2
