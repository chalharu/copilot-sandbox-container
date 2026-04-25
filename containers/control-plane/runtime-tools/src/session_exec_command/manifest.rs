use k8s_openapi::api::core::v1::{PersistentVolumeClaim, Pod};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::config::SessionExecConfig;

pub(super) const STARTUP_PROBE_PERIOD_SECONDS: u64 = 5;
pub(super) const STARTUP_PROBE_GRACE_SECONDS: u64 = 10;
const CHROOT_EXEC_POLICY_LIBRARY_PATH: &str = "/usr/local/lib/libcontrol_plane_exec_policy.so";
const CHROOT_EXEC_POLICY_RULES_PATH: &str =
    "/usr/local/share/control-plane/hooks/preToolUse/deny-rules.yaml";
const CHROOT_RUNTIME_TOOL_PATH: &str = "/usr/local/bin/control-plane-runtime-tool";
const CHROOT_POST_TOOL_USE_HOOKS_PATH: &str = "/usr/local/share/control-plane/hooks/postToolUse";
pub(super) const EXEC_EPHEMERAL_VOLUME_NAME: &str = "ephemeral-storage";
pub(super) const EXEC_EPHEMERAL_INIT_MOUNT_PATH: &str = "/control-plane/ephemeral-storage";
pub(super) const EXEC_EPHEMERAL_TMP_SUBPATH: &str = "tmp";
pub(super) const EXEC_EPHEMERAL_VAR_TMP_SUBPATH: &str = "var/tmp";

pub(super) fn environment_pvc_name(config: &SessionExecConfig) -> String {
    let prefix = config.environment_pvc_prefix.trim_end_matches('-');
    format!("{prefix}-{}", sanitize_dns_label(&config.node_name))
}

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

fn sanitize_dns_label(value: &str) -> String {
    let sanitized = sanitize_dns_subdomain(value);
    if sanitized.len() <= 63 {
        sanitized
    } else {
        sanitized[..63].trim_matches('-').to_string()
    }
}

pub(super) fn build_environment_pvc(
    config: &SessionExecConfig,
    pvc_name: &str,
) -> Result<PersistentVolumeClaim, String> {
    let mut spec = json!({
        "accessModes": ["ReadWriteOnce"],
        "resources": {
            "requests": {
                "storage": config.environment_size
            }
        }
    });
    if let Some(storage_class) = &config.environment_storage_class {
        spec["storageClassName"] = Value::String(storage_class.clone());
    }

    serde_json::from_value(json!({
        "apiVersion": "v1",
        "kind": "PersistentVolumeClaim",
        "metadata": {
            "name": pvc_name,
            "namespace": config.namespace,
            "labels": {
                "app.kubernetes.io/name": "control-plane-fast-exec-environment"
            },
            "annotations": {
                "control-plane.github.io/node-name": config.node_name
            }
        },
        "spec": spec
    }))
    .map_err(|error| format!("failed to build environment PVC manifest: {error}"))
}

pub(super) fn build_bootstrap_assets_init_command(
    environment_root: &str,
    runtime_bin_dir: &str,
    ephemeral_storage_dir: &str,
) -> String {
    let chroot_root = format!("{environment_root}/root");
    let policy_library_source = CHROOT_EXEC_POLICY_LIBRARY_PATH;
    let policy_rules_source = CHROOT_EXEC_POLICY_RULES_PATH;
    let policy_library_path = format!("{chroot_root}{CHROOT_EXEC_POLICY_LIBRARY_PATH}");
    let policy_rules_path = format!("{chroot_root}{CHROOT_EXEC_POLICY_RULES_PATH}");
    let chroot_kubectl_path = format!("{chroot_root}/usr/local/bin/kubectl");
    let chroot_runtime_tool_path = format!("{chroot_root}{CHROOT_RUNTIME_TOOL_PATH}");
    let post_tool_use_dir = format!("{chroot_root}{CHROOT_POST_TOOL_USE_HOOKS_PATH}");
    format!(
        concat!(
            "set -eu\n",
            "environment_root={environment_root:?}\n",
            "runtime_bin_dir={runtime_bin_dir:?}\n",
            "ephemeral_storage_dir={ephemeral_storage_dir:?}\n",
            "policy_library_path={policy_library_path:?}\n",
            "policy_rules_path={policy_rules_path:?}\n",
            "chroot_kubectl_path={chroot_kubectl_path:?}\n",
            "chroot_runtime_tool_path={chroot_runtime_tool_path:?}\n",
            "post_tool_use_dir={post_tool_use_dir:?}\n",
            "policy_library_dir=\"$(dirname \"$policy_library_path\")\"\n",
            "policy_rules_dir=\"$(dirname \"$policy_rules_path\")\"\n",
            "chroot_kubectl_dir=\"$(dirname \"$chroot_kubectl_path\")\"\n",
            "chroot_runtime_tool_dir=\"$(dirname \"$chroot_runtime_tool_path\")\"\n",
            "install -d -m 0755 \"$environment_root/root\" \"$environment_root/hooks/git\" \"$runtime_bin_dir\" \"$policy_library_dir\" \"$policy_rules_dir\" \"$chroot_kubectl_dir\" \"$chroot_runtime_tool_dir\" \"$post_tool_use_dir\"\n",
            "install -d -m 0755 \"$ephemeral_storage_dir/var\"\n",
            "install -d -m 1777 \"$ephemeral_storage_dir/tmp\" \"$ephemeral_storage_dir/var/tmp\"\n",
            "install -m 0755 /usr/local/bin/control-plane-exec-api \"$runtime_bin_dir/control-plane-exec-api\"\n",
            "install -m 0755 /usr/local/bin/kubectl \"$chroot_kubectl_path\"\n",
            "install -m 0755 /usr/local/bin/control-plane-runtime-tool \"$chroot_runtime_tool_path\"\n",
            "rm -rf \"$environment_root/hooks/git\"\n",
            "install -d -m 0755 \"$environment_root/hooks/git\"\n",
            "cp -R /usr/local/share/control-plane/hooks/git/. \"$environment_root/hooks/git/\"\n",
            "find \"$environment_root/hooks/git\" -type d -exec chmod 755 {{}} +\n",
            "find \"$environment_root/hooks/git\" -type f -exec chmod 644 {{}} +\n",
            "chmod 755 \"$environment_root/hooks/git/pre-commit\" \"$environment_root/hooks/git/pre-push\"\n",
            "rm -rf \"$post_tool_use_dir\"\n",
            "install -d -m 0755 \"$post_tool_use_dir\"\n",
            "cp -R /usr/local/share/control-plane/hooks/postToolUse/. \"$post_tool_use_dir/\"\n",
            "find \"$post_tool_use_dir\" -type d -exec chmod 755 {{}} +\n",
            "find \"$post_tool_use_dir\" -type f -exec chmod 644 {{}} +\n",
            "chmod 755 \"$post_tool_use_dir/control-plane-rust.sh\"\n",
            "ln -sf {runtime_tool_path:?} \"$post_tool_use_dir/main\"\n",
            "install -m 0644 {policy_library_source:?} \"$policy_library_path\"\n",
            "install -m 0644 {policy_rules_source:?} \"$policy_rules_path\"\n",
        ),
        environment_root = environment_root,
        runtime_bin_dir = runtime_bin_dir,
        ephemeral_storage_dir = ephemeral_storage_dir,
        policy_library_source = policy_library_source,
        policy_rules_source = policy_rules_source,
        policy_library_path = policy_library_path,
        policy_rules_path = policy_rules_path,
        chroot_kubectl_path = chroot_kubectl_path,
        chroot_runtime_tool_path = chroot_runtime_tool_path,
        post_tool_use_dir = post_tool_use_dir,
        runtime_tool_path = CHROOT_RUNTIME_TOOL_PATH,
    )
}

fn build_exec_ephemeral_volume(ephemeral_size: &str, storage_class: &str) -> Value {
    json!({
        "name": EXEC_EPHEMERAL_VOLUME_NAME,
        "ephemeral": {
            "volumeClaimTemplate": {
                "spec": {
                    "accessModes": ["ReadWriteOnce"],
                    "storageClassName": storage_class,
                    "resources": {
                        "requests": {
                            "storage": ephemeral_size
                        }
                    }
                }
            }
        }
    })
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
    bootstrap_image: &str,
    environment_pvc_name: &str,
    ephemeral_storage_class: &str,
) -> Result<Pod, String> {
    let environment_root = config.environment_mount_path.trim_end_matches('/');
    let chroot_root = format!("{environment_root}/root");
    let runtime_bin_dir = "/control-plane/bin";
    let exec_api_path = format!("{runtime_bin_dir}/control-plane-exec-api");
    let hooks_source = format!("{environment_root}/hooks/git");
    let workspace_mount = nested_mount_path(&chroot_root, &config.workspace_mount_path)?;
    let remote_home_mount = nested_mount_path(&chroot_root, &config.remote_home)?;
    let tmp_mount = nested_mount_path(&chroot_root, "/tmp")?;
    let var_tmp_mount = nested_mount_path(&chroot_root, "/var/tmp")?;
    let gh_mount = format!("{remote_home_mount}/.config/gh");
    let ssh_mount = format!("{remote_home_mount}/.ssh");
    let init_command = build_bootstrap_assets_init_command(
        environment_root,
        runtime_bin_dir,
        EXEC_EPHEMERAL_INIT_MOUNT_PATH,
    );

    let mut volume_mounts = vec![
        json!({
            "name": "environment",
            "mountPath": config.environment_mount_path,
        }),
        json!({
            "name": "runtime-bin",
            "mountPath": runtime_bin_dir,
            "readOnly": true,
        }),
        json!({
            "name": "workspace",
            "mountPath": workspace_mount,
            "subPath": config.workspace_subpath,
        }),
        json!({
            "name": EXEC_EPHEMERAL_VOLUME_NAME,
            "mountPath": tmp_mount,
            "subPath": EXEC_EPHEMERAL_TMP_SUBPATH,
        }),
        json!({
            "name": EXEC_EPHEMERAL_VOLUME_NAME,
            "mountPath": var_tmp_mount,
            "subPath": EXEC_EPHEMERAL_VAR_TMP_SUBPATH,
        }),
    ];
    let mut volumes = vec![
        json!({
            "name": "environment",
            "persistentVolumeClaim": {
                "claimName": environment_pvc_name
            }
        }),
        json!({
            "name": "runtime-bin",
            "emptyDir": {}
        }),
        build_exec_ephemeral_volume(&config.ephemeral_size, ephemeral_storage_class),
        json!({
            "name": "workspace",
            "persistentVolumeClaim": {
                "claimName": config.workspace_pvc
            }
        }),
    ];

    if let Some(copilot_session_pvc) = &config.copilot_session_pvc {
        volume_mounts.push(json!({
            "name": "copilot-session",
            "mountPath": gh_mount,
            "subPath": config.copilot_session_gh_subpath,
            "readOnly": false
        }));
        volume_mounts.push(json!({
            "name": "copilot-session",
            "mountPath": ssh_mount,
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
            "annotations": {
                "container.apparmor.security.beta.kubernetes.io/execution": "unconfined"
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
            "initContainers": [{
                "name": "bootstrap-assets",
                "image": bootstrap_image,
                "imagePullPolicy": config.bootstrap_image_pull_policy,
                "command": ["/bin/sh", "-lc", init_command],
                "securityContext": {
                    "privileged": false,
                    "runAsUser": 0,
                    "runAsNonRoot": false,
                    "allowPrivilegeEscalation": false,
                    "capabilities": {
                        "drop": ["ALL"],
                        "add": ["CHOWN", "DAC_OVERRIDE"]
                    },
                    "seccompProfile": {
                        "type": "RuntimeDefault"
                    }
                },
                "volumeMounts": [{
                    "name": "environment",
                    "mountPath": config.environment_mount_path,
                }, {
                    "name": "runtime-bin",
                    "mountPath": runtime_bin_dir,
                }, {
                    "name": EXEC_EPHEMERAL_VOLUME_NAME,
                    "mountPath": EXEC_EPHEMERAL_INIT_MOUNT_PATH,
                }]
            }],
            "containers": [{
                "name": "execution",
                "image": config.image,
                "imagePullPolicy": config.image_pull_policy,
                "command": [exec_api_path, "serve"],
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
                    "allowPrivilegeEscalation": false,
                    "capabilities": {
                        "drop": ["ALL"],
                        "add": ["CHOWN", "DAC_OVERRIDE", "SETGID", "SETUID", "SYS_ADMIN", "SYS_CHROOT"]
                    },
                    "seccompProfile": {
                        "type": "Unconfined"
                    },
                    "appArmorProfile": {
                        "type": "Unconfined"
                    }
                },
                "volumeMounts": volume_mounts,
                "env": [{
                    "name": "CONTROL_PLANE_FAST_EXECUTION_PORT",
                    "value": config.port.to_string()
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
                    "name": "CONTROL_PLANE_FAST_EXECUTION_CHROOT_ROOT",
                    "value": chroot_root
                }, {
                    "name": "CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_MOUNT_PATH",
                    "value": config.environment_mount_path
                }, {
                    "name": "CONTROL_PLANE_FAST_EXECUTION_GIT_HOOKS_SOURCE",
                    "value": hooks_source
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

fn nested_mount_path(root: &str, absolute_path: &str) -> Result<String, String> {
    let trimmed_root = root.trim_end_matches('/');
    let suffix = absolute_path
        .strip_prefix('/')
        .ok_or_else(|| format!("expected absolute nested mount path, got {absolute_path}"))?;
    Ok(format!("{trimmed_root}/{suffix}"))
}
