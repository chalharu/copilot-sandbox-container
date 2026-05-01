mod args;
mod config;
mod kube;
mod manifest;
mod state;

use ::kube::{Api, Client};
use base64::Engine as _;
use control_plane_exec_api::execute_remote;
use k8s_openapi::api::core::v1::Pod;
use tokio::runtime::Builder;

use crate::error::{ToolError, ToolResult};

use self::args::{CommandArgs, parse_args, print_usage};
use self::config::{SessionExecConfig, load_config};
use self::kube::{
    create_pod, delete_pod, get_existing_pod, kube_client, pod_ip as ready_pod_ip,
    pod_matches_session_entry, pod_uid as ready_pod_uid, wait_for_healthcheck, wait_for_pod,
};
use self::manifest::{build_exec_pod, pod_name_for_session};
use self::state::{
    PreparedPod, StateLock, ensure_state_parent, entry_from_prepared, generate_session_token,
    read_prepared_pod, read_state, write_state,
};

const COMMAND_NAME: &str = "control-plane-session-exec";

pub fn run(args: &[String]) -> ToolResult<i32> {
    if args.len() == 1 && matches!(args[0].as_str(), "--help" | "-h") {
        print_usage();
        return Ok(0);
    }

    let command = parse_args(args)?;
    let config = load_config()?;
    let runtime = Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| ToolError::new(1, COMMAND_NAME, error.to_string()))?;

    match command {
        CommandArgs::Prepare {
            session_key,
            refresh,
        } => {
            runtime
                .block_on(prepare_session(&config, &session_key, refresh))
                .map_err(|message| ToolError::new(1, COMMAND_NAME, message))?;
            Ok(0)
        }
        CommandArgs::Proxy {
            session_key,
            cwd,
            command_base64,
        } => proxy_command(&runtime, &config, &session_key, &cwd, &command_base64),
        CommandArgs::Cleanup { session_key } => {
            runtime
                .block_on(cleanup_session(&config, &session_key))
                .map_err(|message| ToolError::new(1, COMMAND_NAME, message))?;
            Ok(0)
        }
    }
}

fn proxy_command(
    runtime: &tokio::runtime::Runtime,
    config: &SessionExecConfig,
    session_key: &str,
    cwd: &str,
    command_base64: &str,
) -> ToolResult<i32> {
    let command = base64::engine::general_purpose::STANDARD
        .decode(command_base64)
        .map_err(|error| ToolError::new(64, COMMAND_NAME, error.to_string()))?;
    let command = String::from_utf8(command)
        .map_err(|error| ToolError::new(64, COMMAND_NAME, error.to_string()))?;

    runtime
        .block_on(prepare_session(config, session_key, false))
        .map_err(|message| ToolError::new(1, COMMAND_NAME, message))?;
    let mut prepared = read_prepared_pod(config, session_key)
        .map_err(|message| ToolError::new(1, COMMAND_NAME, message))?;

    let mut result = runtime.block_on(execute_remote_command(config, &prepared, cwd, &command));
    if result.is_err() {
        runtime
            .block_on(prepare_session(config, session_key, true))
            .map_err(|message| ToolError::new(1, COMMAND_NAME, message))?;
        prepared = read_prepared_pod(config, session_key)
            .map_err(|message| ToolError::new(1, COMMAND_NAME, message))?;
        result = runtime.block_on(execute_remote_command(config, &prepared, cwd, &command));
    }

    let result = result.map_err(|message| ToolError::new(1, COMMAND_NAME, message))?;
    print!("{}", result.stdout);
    eprint!("{}", result.stderr);
    Ok(result.exit_code)
}

async fn execute_remote_command(
    config: &SessionExecConfig,
    prepared: &PreparedPod,
    cwd: &str,
    command: &str,
) -> Result<control_plane_exec_api::ExecResult, String> {
    execute_remote(
        &format!("http://{}:{}", prepared.pod_ip, config.port),
        config.request_timeout,
        &prepared.auth_token,
        cwd,
        command,
    )
    .await
    .map_err(|error| format!("failed to reach execution pod API: {error}"))
}

async fn prepare_session(
    config: &SessionExecConfig,
    session_key: &str,
    refresh: bool,
) -> Result<(), String> {
    ensure_state_parent(config)?;
    let _lock = StateLock::acquire(&config.lock_file)?;
    let client = kube_client().await?;
    ensure_pod_ready(&client, config, session_key, refresh).await?;
    Ok(())
}

async fn cleanup_session(config: &SessionExecConfig, session_key: &str) -> Result<(), String> {
    ensure_state_parent(config)?;
    let _lock = StateLock::acquire(&config.lock_file)?;
    let client = kube_client().await?;
    let mut state = read_state(&config.state_file)?;
    let pod_name = state
        .sessions
        .get(session_key)
        .map(|entry| entry.pod_name.clone())
        .unwrap_or_else(|| pod_name_for_session(&config.owner_pod_name, session_key));
    delete_pod(&client, &config.namespace, &pod_name).await?;
    state.sessions.remove(session_key);
    write_state(&config.state_file, &state)?;
    Ok(())
}

async fn ensure_pod_ready(
    client: &Client,
    config: &SessionExecConfig,
    session_key: &str,
    refresh: bool,
) -> Result<PreparedPod, String> {
    let pods: Api<Pod> = Api::namespaced(client.clone(), &config.namespace);
    let mut state = read_state(&config.state_file)?;
    let pod_name = pod_name_for_session(&config.owner_pod_name, session_key);
    let existing_pod = get_existing_pod(&pods, &pod_name).await?;

    if !refresh
        && let Some(pod) = existing_pod.as_ref()
        && let Some(entry) = state.sessions.get(session_key)
        && pod_matches_session_entry(pod, entry)
        && let Some(pod_uid) = ready_pod_uid(pod)
        && let Some(pod_ip) = ready_pod_ip(pod)
        && wait_for_healthcheck(config, &pod_ip).await
    {
        let prepared = PreparedPod {
            pod_name: pod_name.clone(),
            pod_uid: pod_uid.to_string(),
            pod_ip,
            auth_token: entry.auth_token.clone(),
        };
        state
            .sessions
            .insert(session_key.to_string(), entry_from_prepared(&prepared));
        write_state(&config.state_file, &state)?;
        return Ok(prepared);
    }

    if existing_pod.is_some() {
        delete_pod(client, &config.namespace, &pod_name).await?;
    }

    let auth_token = generate_session_token()?;
    let pod = build_exec_pod(config, session_key, &pod_name, &auth_token)?;
    create_pod(&pods, &pod, config.start_timeout).await?;
    let ready_pod = wait_for_pod(client, config, &pod_name).await?;
    let prepared = PreparedPod {
        pod_name,
        pod_uid: ready_pod.pod_uid,
        pod_ip: ready_pod.pod_ip,
        auth_token,
    };
    state
        .sessions
        .insert(session_key.to_string(), entry_from_prepared(&prepared));
    write_state(&config.state_file, &state)?;
    Ok(prepared)
}

#[cfg(test)]
mod tests {
    use k8s_openapi::api::core::v1::{Pod, Volume, VolumeMount};

    use super::config::SessionExecConfig;
    use super::kube::{pod_matches_session_entry, pod_ready};
    use super::manifest::{build_exec_pod, pod_name_for_session};
    use super::state::{PreparedPod, SessionEntry, entry_from_prepared};

    fn config() -> SessionExecConfig {
        SessionExecConfig {
            state_file: "/tmp/session-exec.json".into(),
            lock_file: "/tmp/session-exec.json.lock".into(),
            workspace_pvc: "control-plane-workspace-pvc".to_string(),
            workspace_mount_path: "/workspace".to_string(),
            workspace_subpath: "workspace".to_string(),
            copilot_session_pvc: Some("control-plane-copilot-session-pvc".to_string()),
            copilot_session_gh_subpath: "state/gh".to_string(),
            copilot_session_ssh_subpath: "state/ssh".to_string(),
            namespace: "copilot-sandbox".to_string(),
            job_namespace: "copilot-sandbox-jobs".to_string(),
            owner_pod_name: "control-plane-0".to_string(),
            owner_pod_uid: "pod-uid-1".to_string(),
            node_name: "kind-control-plane".to_string(),
            image: "ghcr.io/example/control-plane:test".to_string(),
            image_pull_policy: "Never".to_string(),
            start_timeout: std::time::Duration::from_secs(120),
            port: 8080,
            cpu_request: "250m".to_string(),
            cpu_limit: "1".to_string(),
            memory_request: "256Mi".to_string(),
            memory_limit: "1Gi".to_string(),
            remote_home: "/root".to_string(),
            service_account: Some("control-plane-exec".to_string()),
            run_as_uid: 1000,
            run_as_gid: 1000,
            git_user_name: Some("Copilot".to_string()),
            git_user_email: Some("copilot@example.com".to_string()),
            request_timeout: std::time::Duration::from_secs(3600),
            post_tool_use_forward_addr: "http://10.0.0.10:8081".to_string(),
            post_tool_use_forward_token: "reverse-token".to_string(),
            post_tool_use_forward_timeout: std::time::Duration::from_secs(3600),
            startup_script: Some(
                "printf \"fast-exec-startup\\n\" > /workspace/fast-exec-startup-marker.txt"
                    .to_string(),
            ),
            extra_volumes: vec![
                serde_json::from_value::<Volume>(serde_json::json!({
                    "name": "ephemeral-storage",
                    "ephemeral": {
                        "volumeClaimTemplate": {
                            "spec": {
                                "accessModes": ["ReadWriteOnce"],
                                "storageClassName": "standard",
                                "resources": {
                                    "requests": {
                                        "storage": "10Gi"
                                    }
                                }
                            }
                        }
                    }
                }))
                .unwrap(),
            ],
            extra_volume_mounts: vec![
                serde_json::from_value::<VolumeMount>(serde_json::json!({
                    "name": "ephemeral-storage",
                    "mountPath": "/var/tmp/control-plane"
                }))
                .unwrap(),
            ],
        }
    }

    fn ready_execution_pod(uid: &str, terminating: bool) -> Pod {
        let mut value = serde_json::json!({
            "metadata": {
                "name": "control-plane-exec-test",
                "uid": uid
            },
            "status": {
                "phase": "Running",
                "podIP": "10.0.0.42",
                "containerStatuses": [{
                    "name": "execution",
                    "ready": true,
                    "restartCount": 0,
                    "image": "ghcr.io/example/control-plane:test",
                    "imageID": "ghcr.io/example/control-plane:test@sha256:test",
                    "started": true,
                    "state": {
                        "running": {
                            "startedAt": "2026-04-09T00:00:00Z"
                        }
                    },
                    "lastState": {}
                }]
            }
        });
        if terminating {
            value["metadata"]["deletionTimestamp"] = serde_json::json!("2026-04-09T00:00:00Z");
        }
        serde_json::from_value(value).unwrap()
    }

    #[test]
    fn pod_name_stays_stable_for_session() {
        assert_eq!(
            pod_name_for_session("control-plane-0", "Session_42"),
            "control-plane-exec-f6373fc203-session-42"
        );
    }

    #[test]
    fn pod_readiness_rejects_terminating_pods() {
        assert!(pod_ready(&ready_execution_pod("pod-uid-1", false)));
        assert!(!pod_ready(&ready_execution_pod("pod-uid-1", true)));
    }

    #[test]
    fn session_entries_only_reuse_the_same_pod_instance() {
        let entry = SessionEntry {
            pod_name: "control-plane-exec-test".to_string(),
            pod_uid: "pod-uid-1".to_string(),
            pod_ip: "10.0.0.42".to_string(),
            auth_token: "session-token".to_string(),
        };

        assert!(pod_matches_session_entry(
            &ready_execution_pod("pod-uid-1", false),
            &entry
        ));
        assert!(!pod_matches_session_entry(
            &ready_execution_pod("pod-uid-2", false),
            &entry
        ));
        assert!(!pod_matches_session_entry(
            &ready_execution_pod("pod-uid-1", true),
            &entry
        ));
    }

    #[test]
    fn pod_manifest_mounts_workspace_copilot_session_and_extra_volumes_directly() {
        let config = config();
        let pod = build_exec_pod(
            &config,
            "session-42",
            "control-plane-exec-test",
            "session-token",
        )
        .unwrap();
        let pod_value = serde_json::to_value(&pod).unwrap();
        let spec = pod.spec.unwrap();
        assert_eq!(
            spec.service_account_name.as_deref(),
            Some("control-plane-exec")
        );
        assert_eq!(spec.automount_service_account_token, Some(true));
        let node_affinity = spec
            .affinity
            .as_ref()
            .and_then(|affinity| affinity.node_affinity.as_ref())
            .and_then(|affinity| {
                affinity
                    .required_during_scheduling_ignored_during_execution
                    .as_ref()
            })
            .expect("node affinity should be configured");
        let node_requirement = node_affinity.node_selector_terms[0]
            .match_fields
            .as_ref()
            .and_then(|requirements| {
                requirements
                    .iter()
                    .find(|entry| entry.key == "metadata.name")
            })
            .expect("node affinity should target the owner node");
        assert_eq!(node_requirement.operator, "In");
        assert_eq!(
            node_requirement.values.as_ref().unwrap(),
            &vec![config.node_name.clone()]
        );
        let execution = spec
            .containers
            .iter()
            .find(|container| container.name == "execution")
            .unwrap();
        let env = execution.env.as_ref().unwrap();
        assert!(env.iter().any(|entry| {
            entry.name == "CONTROL_PLANE_JOB_NAMESPACE"
                && entry.value.as_deref() == Some("copilot-sandbox-jobs")
        }));
        assert!(env.iter().any(|entry| {
            entry.name == "CONTROL_PLANE_EXEC_POLICY_LIBRARY"
                && entry.value.as_deref() == Some("/usr/local/lib/libcontrol_plane_exec_policy.so")
        }));
        assert!(env.iter().any(|entry| {
            entry.name == "CONTROL_PLANE_EXEC_POLICY_RULES_FILE"
                && entry.value.as_deref()
                    == Some("/usr/local/share/control-plane/hooks/preToolUse/deny-rules.yaml")
        }));
        assert_eq!(
            execution.command.as_ref().unwrap(),
            &vec![
                "/usr/local/bin/control-plane-exec-api".to_string(),
                "serve".to_string()
            ]
        );
        let mounts = execution.volume_mounts.as_ref().unwrap();
        assert!(
            mounts
                .iter()
                .any(|mount| mount.name == "workspace" && mount.mount_path == "/workspace")
        );
        assert!(mounts.iter().any(|mount| mount.name == "ephemeral-storage"
            && mount.mount_path == "/var/tmp/control-plane"));
        let execution_capabilities = execution
            .security_context
            .as_ref()
            .and_then(|context| context.capabilities.as_ref())
            .and_then(|capabilities| capabilities.add.as_ref())
            .unwrap();
        let execution_seccomp = execution
            .security_context
            .as_ref()
            .and_then(|context| context.seccomp_profile.as_ref())
            .map(|profile| profile.type_.as_str())
            .unwrap();
        let allow_privilege_escalation = execution
            .security_context
            .as_ref()
            .and_then(|context| context.allow_privilege_escalation)
            .unwrap();
        assert!(execution_capabilities.contains(&"CHOWN".to_string()));
        assert!(execution_capabilities.contains(&"DAC_OVERRIDE".to_string()));
        assert!(execution_capabilities.contains(&"SETGID".to_string()));
        assert!(execution_capabilities.contains(&"SETUID".to_string()));
        assert!(!execution_capabilities.contains(&"SYS_CHROOT".to_string()));
        assert_eq!(execution_seccomp, "RuntimeDefault");
        assert!(allow_privilege_escalation);
        let gh_mount = mounts
            .iter()
            .find(|mount| mount.name == "copilot-session" && mount.mount_path == "/root/.config/gh")
            .unwrap();
        assert_eq!(gh_mount.read_only, Some(false));
        let ssh_mount = mounts
            .iter()
            .find(|mount| mount.name == "copilot-session" && mount.mount_path == "/root/.ssh")
            .unwrap();
        assert_eq!(ssh_mount.read_only, Some(true));
        assert!(spec.init_containers.is_none());
        let env = execution.env.as_ref().unwrap();
        assert!(
            !env.iter()
                .any(|value| value.name == "CONTROL_PLANE_FAST_EXECUTION_CHROOT_ROOT")
        );
        let startup_probe = execution.startup_probe.as_ref().unwrap();
        assert_eq!(startup_probe.grpc.as_ref().unwrap().port, 8080);
        assert_eq!(startup_probe.period_seconds, Some(5));
        assert_eq!(startup_probe.failure_threshold, Some(26));
        assert!(
            !env.iter()
                .any(|value| value.name == "CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_MOUNT_PATH")
        );
        assert!(
            !env.iter()
                .any(|value| value.name == "CONTROL_PLANE_FAST_EXECUTION_GIT_HOOKS_SOURCE")
        );
        assert!(env.iter().any(
            |value| value.name == "CONTROL_PLANE_POST_TOOL_USE_FORWARD_ADDR"
                && value.value.as_deref() == Some("http://10.0.0.10:8081")
        ));
        assert!(env.iter().any(
            |value| value.name == "CONTROL_PLANE_POST_TOOL_USE_FORWARD_TOKEN"
                && value.value.as_deref() == Some("reverse-token")
        ));
        assert!(env.iter().any(|value| value.name
            == "CONTROL_PLANE_POST_TOOL_USE_FORWARD_TIMEOUT_SEC"
            && value.value.as_deref() == Some("3600")));
        assert!(env.iter().any(|value| value.name
            == "CONTROL_PLANE_FAST_EXECUTION_STARTUP_SCRIPT"
            && value.value.as_deref()
                == Some(
                    "printf \"fast-exec-startup\\n\" > /workspace/fast-exec-startup-marker.txt"
                )));
        let volumes = spec.volumes.as_ref().unwrap();
        assert!(
            pod_value["spec"]["volumes"]
                .as_array()
                .unwrap()
                .iter()
                .any(|volume| {
                    volume["name"].as_str() == Some("ephemeral-storage")
                        && volume["ephemeral"]["volumeClaimTemplate"]["spec"]["storageClassName"]
                            .as_str()
                            == Some("standard")
                        && volume["ephemeral"]["volumeClaimTemplate"]["spec"]["resources"]
                            ["requests"]["storage"]
                            .as_str()
                            == Some("10Gi")
                })
        );
        assert!(!volumes.iter().any(|volume| volume.name == "environment"));
        assert!(!volumes.iter().any(|volume| volume.name == "runtime-bin"));
    }

    #[test]
    fn pod_manifest_keeps_service_account_token_disabled_without_exec_service_account() {
        let mut config = config();
        config.service_account = None;
        let pod = build_exec_pod(
            &config,
            "session-42",
            "control-plane-exec-test",
            "session-token",
        )
        .unwrap();
        let spec = pod.spec.unwrap();
        assert!(spec.service_account_name.is_none());
        assert_eq!(spec.automount_service_account_token, Some(false));
    }

    #[test]
    fn session_state_keeps_only_runtime_routing_fields() {
        let entry = entry_from_prepared(&PreparedPod {
            pod_name: "control-plane-exec-test".to_string(),
            pod_uid: "pod-uid-1".to_string(),
            pod_ip: "10.0.0.42".to_string(),
            auth_token: "session-token".to_string(),
        });
        let value = serde_json::to_value(entry).unwrap();

        assert_eq!(
            value,
            serde_json::json!({
                "podName": "control-plane-exec-test",
                "podUid": "pod-uid-1",
                "podIp": "10.0.0.42",
                "authToken": "session-token"
            })
        );
    }
}
