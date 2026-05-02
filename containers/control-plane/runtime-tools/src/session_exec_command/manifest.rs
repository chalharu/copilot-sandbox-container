use k8s_openapi::api::core::v1::Pod;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::config::SessionExecConfig;

pub(super) const STARTUP_PROBE_PERIOD_SECONDS: u64 = 5;
pub(super) const STARTUP_PROBE_GRACE_SECONDS: u64 = 10;
const EXEC_POLICY_LIBRARY_PATH: &str = "/usr/local/lib/libcontrol_plane_exec_policy.so";
const EXEC_POLICY_RULES_PATH: &str =
    "/usr/local/share/control-plane/hooks/preToolUse/deny-rules.yaml";

pub(super) fn pod_name_for_session(owner_pod_name: &str, session_key: &str) -> String {
    let normalized = sanitize_dns_subdomain(session_key);
    let mut hasher = Sha256::new();
    hasher.update(owner_pod_name.as_bytes());
    hasher.update(b":");
    hasher.update(session_key.as_bytes());
    let checksum = hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    let mut value = normalized;
    if value.len() > 33 {
        value.truncate(33);
    }
    format!("control-plane-exec-{}-{value}", &checksum[..10])
}

fn sanitize_dns_subdomain(value: &str) -> String {
    let mut output = String::new();
    let mut previous_dash = false;
    for character in value.chars() {
        let mapped = match character {
            'A'..='Z' => character.to_ascii_lowercase(),
            'a'..='z' | '0'..='9' => character,
            _ => '-',
        };
        if mapped == '-' {
            if !previous_dash {
                output.push(mapped);
            }
            previous_dash = true;
        } else {
            output.push(mapped);
            previous_dash = false;
        }
    }
    let trimmed = output.trim_matches('-');
    if trimmed.is_empty() {
        "session".to_string()
    } else {
        trimmed.to_string()
    }
}

fn startup_probe_failure_threshold(start_timeout: std::time::Duration) -> u64 {
    let timeout_seconds = start_timeout
        .as_secs()
        .saturating_add(STARTUP_PROBE_GRACE_SECONDS)
        .max(STARTUP_PROBE_PERIOD_SECONDS);
    timeout_seconds.saturating_add(STARTUP_PROBE_PERIOD_SECONDS - 1) / STARTUP_PROBE_PERIOD_SECONDS
}

pub(super) fn build_exec_pod(
    config: &SessionExecConfig,
    session_key: &str,
    pod_name: &str,
    auth_token: &str,
) -> Result<Pod, String> {
    let mut volume_mounts = vec![json!({
        "name": "workspace",
        "mountPath": config.workspace_mount_path,
        "subPath": config.workspace_subpath,
    })];
    let mut volumes = vec![json!({
        "name": "workspace",
        "persistentVolumeClaim": {
            "claimName": config.workspace_pvc
        }
    })];

    if let Some(copilot_session_pvc) = &config.copilot_session_pvc {
        volume_mounts.push(json!({
            "name": "copilot-session",
            "mountPath": format!("{}/.config/gh", config.remote_home.trim_end_matches('/')),
            "subPath": config.copilot_session_gh_subpath,
            "readOnly": false
        }));
        volume_mounts.push(json!({
            "name": "copilot-session",
            "mountPath": format!("{}/.ssh", config.remote_home.trim_end_matches('/')),
            "subPath": config.copilot_session_ssh_subpath,
            "readOnly": true
        }));
        volumes.push(json!({
            "name": "copilot-session",
            "persistentVolumeClaim": {
                "claimName": copilot_session_pvc
            }
        }));
    }
    for volume_mount in &config.extra_volume_mounts {
        volume_mounts.push(serde_json::to_value(volume_mount).map_err(|error| {
            format!("failed to encode extra execution pod volume mount: {error}")
        })?);
    }
    for volume in &config.extra_volumes {
        volumes
            .push(serde_json::to_value(volume).map_err(|error| {
                format!("failed to encode extra execution pod volume: {error}")
            })?);
    }

    let mut pod = json!({
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": pod_name,
            "namespace": config.namespace,
            "labels": {
                "app.kubernetes.io/name": "control-plane-fast-exec",
                "control-plane.github.io/session-key": session_key,
            },
            "ownerReferences": [{
                "apiVersion": "v1",
                "kind": "Pod",
                "name": config.owner_pod_name,
                "uid": config.owner_pod_uid,
                "controller": false,
                "blockOwnerDeletion": false
            }]
        },
        "spec": {
            "automountServiceAccountToken": false,
            "restartPolicy": "Always",
            "affinity": required_node_affinity(&config.node_name),
            "securityContext": {
                "fsGroup": i64::from(config.run_as_gid)
            },
            "containers": [{
                "name": "execution",
                "image": config.image,
                "imagePullPolicy": config.image_pull_policy,
                "command": ["/usr/local/bin/control-plane-exec-api", "serve"],
                "ports": [{
                    "name": "grpc",
                    "containerPort": config.port
                }],
                "startupProbe": {
                    "grpc": {
                        "port": config.port
                    },
                    "periodSeconds": STARTUP_PROBE_PERIOD_SECONDS,
                    "failureThreshold": startup_probe_failure_threshold(config.start_timeout)
                },
                "readinessProbe": {
                    "grpc": {
                        "port": config.port
                    },
                    "periodSeconds": 2,
                    "failureThreshold": 30
                },
                "livenessProbe": {
                    "grpc": {
                        "port": config.port
                    },
                    "initialDelaySeconds": 5,
                    "periodSeconds": 10,
                    "failureThreshold": 6
                },
                "resources": {
                    "requests": {
                        "cpu": config.cpu_request,
                        "memory": config.memory_request
                    },
                    "limits": {
                        "cpu": config.cpu_limit,
                        "memory": config.memory_limit
                    }
                },
                "securityContext": {
                    "privileged": false,
                    "runAsUser": 0,
                    "runAsNonRoot": false,
                    "allowPrivilegeEscalation": true,
                    "capabilities": {
                        "drop": ["ALL"],
                        "add": ["CHOWN", "DAC_OVERRIDE", "SETGID", "SETUID"]
                    },
                    "seccompProfile": {
                        "type": "RuntimeDefault"
                    }
                },
                "volumeMounts": volume_mounts,
                "env": [{
                    "name": "CONTROL_PLANE_FAST_EXECUTION_PORT",
                    "value": config.port.to_string()
                }, {
                    "name": "CONTROL_PLANE_EXEC_POLICY_LIBRARY",
                    "value": EXEC_POLICY_LIBRARY_PATH
                }, {
                    "name": "CONTROL_PLANE_EXEC_POLICY_RULES_FILE",
                    "value": EXEC_POLICY_RULES_PATH
                }, {
                    "name": "CONTROL_PLANE_EXEC_API_TOKEN",
                    "value": auth_token
                }, {
                    "name": "CONTROL_PLANE_WORKSPACE",
                    "value": config.workspace_mount_path
                }, {
                    "name": "CONTROL_PLANE_JOB_NAMESPACE",
                    "value": config.job_namespace
                }, {
                    "name": "CONTROL_PLANE_FAST_EXECUTION_REQUEST_TIMEOUT_SEC",
                    "value": config.request_timeout.as_secs().to_string()
                }, {
                    "name": "CONTROL_PLANE_FAST_EXECUTION_RUN_AS_UID",
                    "value": config.run_as_uid.to_string()
                }, {
                    "name": "CONTROL_PLANE_FAST_EXECUTION_RUN_AS_GID",
                    "value": config.run_as_gid.to_string()
                }, {
                    "name": "CONTROL_PLANE_POST_TOOL_USE_FORWARD_ADDR",
                    "value": config.post_tool_use_forward_addr
                }, {
                    "name": "CONTROL_PLANE_POST_TOOL_USE_FORWARD_TOKEN",
                    "value": config.post_tool_use_forward_token
                }, {
                    "name": "CONTROL_PLANE_POST_TOOL_USE_FORWARD_TIMEOUT_SEC",
                    "value": config.post_tool_use_forward_timeout.as_secs().to_string()
                }, {
                    "name": "CONTROL_PLANE_FAST_EXECUTION_HOME",
                    "value": config.remote_home
                }, {
                    "name": "CONTROL_PLANE_FAST_EXECUTION_STARTUP_SCRIPT",
                    "value": config.startup_script.clone().unwrap_or_default()
                }, {
                    "name": "HOME",
                    "value": config.remote_home
                }, {
                    "name": "GIT_CONFIG_GLOBAL",
                    "value": format!("{}/.gitconfig", config.remote_home)
                }, {
                    "name": "CONTROL_PLANE_GIT_USER_NAME",
                    "value": config.git_user_name.clone().unwrap_or_default()
                }, {
                    "name": "CONTROL_PLANE_GIT_USER_EMAIL",
                    "value": config.git_user_email.clone().unwrap_or_default()
                }]
            }],
            "volumes": volumes
        }
    });
    if let Some(service_account) = config.service_account.as_ref() {
        pod["spec"]["automountServiceAccountToken"] = json!(true);
        pod["spec"]["serviceAccountName"] = json!(service_account);
    }
    serde_json::from_value(pod)
        .map_err(|error| format!("failed to build execution pod manifest: {error}"))
}

fn required_node_affinity(node_name: &str) -> Value {
    json!({
        "nodeAffinity": {
            "requiredDuringSchedulingIgnoredDuringExecution": {
                "nodeSelectorTerms": [{
                    "matchFields": [{
                        "key": "metadata.name",
                        "operator": "In",
                        "values": [node_name]
                    }]
                }]
            }
        }
    })
}
