use std::collections::BTreeMap;
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{ErrorKind, Read};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::time::Duration;

use base64::Engine as _;
use control_plane_exec_api::{check_health, execute_remote};
use k8s_openapi::api::core::v1::{PersistentVolumeClaim, Pod};
use kube::api::{DeleteParams, PostParams};
use kube::{Api, Client};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::runtime::Builder;
use tokio::time::{Instant, sleep};

use crate::error::{ToolError, ToolResult};

const COMMAND_NAME: &str = "control-plane-session-exec";

#[derive(Debug, Clone)]
struct SessionExecConfig {
    state_file: PathBuf,
    lock_file: PathBuf,
    workspace_pvc: String,
    workspace_mount_path: String,
    workspace_subpath: String,
    copilot_session_pvc: Option<String>,
    copilot_session_gh_subpath: String,
    copilot_session_ssh_subpath: String,
    namespace: String,
    owner_pod_name: String,
    owner_pod_uid: String,
    node_name: String,
    image: String,
    image_pull_policy: String,
    bootstrap_image: Option<String>,
    bootstrap_image_pull_policy: String,
    start_timeout: Duration,
    port: u16,
    cpu_request: String,
    cpu_limit: String,
    memory_request: String,
    memory_limit: String,
    remote_home: String,
    run_as_uid: u32,
    run_as_gid: u32,
    git_user_name: Option<String>,
    git_user_email: Option<String>,
    request_timeout: Duration,
    environment_pvc_prefix: String,
    environment_storage_class: Option<String>,
    environment_size: String,
    environment_mount_path: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum CommandArgs {
    Prepare {
        session_key: String,
        refresh: bool,
    },
    Proxy {
        session_key: String,
        cwd: String,
        command_base64: String,
    },
    Cleanup {
        session_key: String,
    },
}

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct SessionState {
    sessions: BTreeMap<String, SessionEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct SessionEntry {
    pod_name: String,
    pod_ip: String,
    auth_token: String,
    environment_pvc_name: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct PreparedPod {
    pod_name: String,
    pod_ip: String,
    auth_token: String,
    environment_pvc_name: String,
}

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

fn parse_args(args: &[String]) -> ToolResult<CommandArgs> {
    let Some(subcommand) = args.first() else {
        return Err(ToolError::new(64, COMMAND_NAME, "missing subcommand"));
    };

    let mut session_key = String::new();
    let mut refresh = false;
    let mut cwd = String::new();
    let mut command_base64 = String::new();
    let mut index = 1usize;
    while index < args.len() {
        match args[index].as_str() {
            "--session-key" => {
                let value = args.get(index + 1).ok_or_else(|| {
                    ToolError::new(64, COMMAND_NAME, "--session-key requires a value")
                })?;
                session_key = value.clone();
                index += 2;
            }
            "--refresh" => {
                refresh = true;
                index += 1;
            }
            "--cwd" => {
                let value = args
                    .get(index + 1)
                    .ok_or_else(|| ToolError::new(64, COMMAND_NAME, "--cwd requires a value"))?;
                cwd = value.clone();
                index += 2;
            }
            "--command-base64" => {
                let value = args.get(index + 1).ok_or_else(|| {
                    ToolError::new(64, COMMAND_NAME, "--command-base64 requires a value")
                })?;
                command_base64 = value.clone();
                index += 2;
            }
            other => {
                return Err(ToolError::new(
                    64,
                    COMMAND_NAME,
                    format!("unknown option: {other}"),
                ));
            }
        }
    }

    if session_key.is_empty() {
        return Err(ToolError::new(
            64,
            COMMAND_NAME,
            "--session-key is required",
        ));
    }

    match subcommand.as_str() {
        "prepare" => Ok(CommandArgs::Prepare {
            session_key,
            refresh,
        }),
        "proxy" => {
            if cwd.is_empty() {
                return Err(ToolError::new(
                    64,
                    COMMAND_NAME,
                    "--cwd is required for proxy",
                ));
            }
            if command_base64.is_empty() {
                return Err(ToolError::new(
                    64,
                    COMMAND_NAME,
                    "--command-base64 is required for proxy",
                ));
            }
            Ok(CommandArgs::Proxy {
                session_key,
                cwd,
                command_base64,
            })
        }
        "cleanup" => Ok(CommandArgs::Cleanup { session_key }),
        other => Err(ToolError::new(
            64,
            COMMAND_NAME,
            format!("unknown subcommand: {other}"),
        )),
    }
}

fn print_usage() {
    println!(
        "Usage:\n  control-plane-session-exec prepare --session-key KEY [--refresh]\n  control-plane-session-exec proxy --session-key KEY --cwd PATH --command-base64 BASE64\n  control-plane-session-exec cleanup --session-key KEY"
    );
}

fn load_config() -> ToolResult<SessionExecConfig> {
    ensure_enabled()?;
    let state_file = default_state_file();
    let lock_file = PathBuf::from(format!("{}.lock", state_file.display()));
    let workspace_pvc = required_env("CONTROL_PLANE_WORKSPACE_PVC")?;
    let workspace_mount_path = absolute_env(
        "CONTROL_PLANE_WORKSPACE_MOUNT_PATH",
        "/workspace",
        "logical workspace mount path",
    )?;
    let workspace_subpath = env_or_default("CONTROL_PLANE_WORKSPACE_SUBPATH", "workspace");
    let namespace = non_empty_env(
        "CONTROL_PLANE_POD_NAMESPACE",
        env_or_default("CONTROL_PLANE_K8S_NAMESPACE", "default"),
    )?;
    let owner_pod_name = required_env("CONTROL_PLANE_POD_NAME")?;
    let owner_pod_uid = required_env("CONTROL_PLANE_POD_UID")?;
    let node_name = required_env("CONTROL_PLANE_NODE_NAME")?;
    let image = required_env("CONTROL_PLANE_FAST_EXECUTION_IMAGE")?;
    let image_pull_policy = env_or_default("CONTROL_PLANE_FAST_EXECUTION_IMAGE_PULL_POLICY", "IfNotPresent");
    let bootstrap_image = optional_env("CONTROL_PLANE_FAST_EXECUTION_BOOTSTRAP_IMAGE");
    let bootstrap_image_pull_policy = env_or_default(
        "CONTROL_PLANE_FAST_EXECUTION_BOOTSTRAP_IMAGE_PULL_POLICY",
        "IfNotPresent",
    );
    let start_timeout = parse_duration(
        &env_or_default("CONTROL_PLANE_FAST_EXECUTION_START_TIMEOUT", "120s"),
        "CONTROL_PLANE_FAST_EXECUTION_START_TIMEOUT",
    )?;
    let port = parse_u16(
        &env_or_default("CONTROL_PLANE_FAST_EXECUTION_PORT", "8080"),
        "CONTROL_PLANE_FAST_EXECUTION_PORT",
    )?;
    let cpu_request = env_or_default("CONTROL_PLANE_FAST_EXECUTION_CPU_REQUEST", "250m");
    let cpu_limit = env_or_default("CONTROL_PLANE_FAST_EXECUTION_CPU_LIMIT", "2");
    let memory_request = env_or_default("CONTROL_PLANE_FAST_EXECUTION_MEMORY_REQUEST", "256Mi");
    let memory_limit = env_or_default("CONTROL_PLANE_FAST_EXECUTION_MEMORY_LIMIT", "2Gi");
    let remote_home = absolute_env("CONTROL_PLANE_FAST_EXECUTION_HOME", "/root", "remote home")?;
    let run_as_uid = parse_non_root_u32(
        &env_or_default("CONTROL_PLANE_FAST_EXECUTION_RUN_AS_UID", "1000"),
        "CONTROL_PLANE_FAST_EXECUTION_RUN_AS_UID",
    )?;
    let run_as_gid = parse_non_root_u32(
        &env_or_default("CONTROL_PLANE_FAST_EXECUTION_RUN_AS_GID", "1000"),
        "CONTROL_PLANE_FAST_EXECUTION_RUN_AS_GID",
    )?;
    let request_timeout = Duration::from_secs(parse_positive_u64(
        &env_or_default("CONTROL_PLANE_FAST_EXECUTION_REQUEST_TIMEOUT_SEC", "3600"),
        "CONTROL_PLANE_FAST_EXECUTION_REQUEST_TIMEOUT_SEC",
    )?);
    let environment_pvc_prefix = env_or_default(
        "CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_PVC_PREFIX",
        "node-workspace",
    );
    let environment_storage_class =
        optional_env("CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_STORAGE_CLASS");
    let environment_size =
        env_or_default("CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_SIZE", "10Gi");
    let environment_mount_path = absolute_env(
        "CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_MOUNT_PATH",
        "/environment",
        "environment mount path",
    )?;

    Ok(SessionExecConfig {
        state_file,
        lock_file,
        workspace_pvc,
        workspace_mount_path,
        workspace_subpath,
        copilot_session_pvc: optional_env("CONTROL_PLANE_COPILOT_SESSION_PVC"),
        copilot_session_gh_subpath: env_or_default(
            "CONTROL_PLANE_COPILOT_SESSION_GH_SUBPATH",
            "state/gh",
        ),
        copilot_session_ssh_subpath: env_or_default(
            "CONTROL_PLANE_COPILOT_SESSION_SSH_SUBPATH",
            "state/ssh",
        ),
        namespace,
        owner_pod_name,
        owner_pod_uid,
        node_name,
        image,
        image_pull_policy,
        bootstrap_image,
        bootstrap_image_pull_policy,
        start_timeout,
        port,
        cpu_request,
        cpu_limit,
        memory_request,
        memory_limit,
        remote_home,
        run_as_uid,
        run_as_gid,
        git_user_name: optional_env("CONTROL_PLANE_GIT_USER_NAME"),
        git_user_email: optional_env("CONTROL_PLANE_GIT_USER_EMAIL"),
        request_timeout,
        environment_pvc_prefix,
        environment_storage_class,
        environment_size,
        environment_mount_path,
    })
}

fn ensure_enabled() -> ToolResult<()> {
    if env::var("CONTROL_PLANE_FAST_EXECUTION_ENABLED").ok().as_deref() == Some("1") {
        Ok(())
    } else {
        Err(ToolError::new(
            64,
            COMMAND_NAME,
            "session execution pods are disabled (set CONTROL_PLANE_FAST_EXECUTION_ENABLED=1)",
        ))
    }
}

fn default_state_file() -> PathBuf {
    let home = env::var("HOME").unwrap_or_else(|_| "/home/copilot".to_string());
    PathBuf::from(home).join(".copilot/session-state/session-exec.json")
}

fn env_or_default(name: &str, default: &str) -> String {
    env::var(name).unwrap_or_else(|_| default.to_string())
}

fn optional_env(name: &str) -> Option<String> {
    env::var(name).ok().filter(|value| !value.trim().is_empty())
}

fn required_env(name: &str) -> ToolResult<String> {
    let value = env::var(name).map_err(|_| ToolError::new(64, COMMAND_NAME, format!("{name} is required")))?;
    non_empty_env(name, value)
}

fn non_empty_env(name: &str, value: String) -> ToolResult<String> {
    if value.trim().is_empty() {
        Err(ToolError::new(
            64,
            COMMAND_NAME,
            format!("{name} must not be empty"),
        ))
    } else {
        Ok(value)
    }
}

fn absolute_env(name: &str, default: &str, description: &str) -> ToolResult<String> {
    let value = env_or_default(name, default);
    if value.starts_with('/') {
        Ok(value)
    } else {
        Err(ToolError::new(
            64,
            COMMAND_NAME,
            format!("{name} must be an absolute {description}: {value}"),
        ))
    }
}

fn parse_u16(value: &str, name: &str) -> ToolResult<u16> {
    value
        .parse::<u16>()
        .ok()
        .filter(|port| *port > 0)
        .ok_or_else(|| ToolError::new(64, COMMAND_NAME, format!("invalid {name}: {value}")))
}

fn parse_positive_u64(value: &str, name: &str) -> ToolResult<u64> {
    value.parse::<u64>().ok().filter(|parsed| *parsed > 0).ok_or_else(|| {
        ToolError::new(
            64,
            COMMAND_NAME,
            format!("{name} must be a positive integer: {value}"),
        )
    })
}

fn parse_non_root_u32(value: &str, name: &str) -> ToolResult<u32> {
    value.parse::<u32>().ok().filter(|parsed| *parsed > 0).ok_or_else(|| {
        ToolError::new(
            64,
            COMMAND_NAME,
            format!("{name} must be greater than zero: {value}"),
        )
    })
}

fn parse_duration(value: &str, name: &str) -> ToolResult<Duration> {
    let split_at = value
        .find(|character: char| !character.is_ascii_digit())
        .unwrap_or(value.len());
    let (digits, suffix) = value.split_at(split_at);
    if digits.is_empty() {
        return Err(ToolError::new(
            64,
            COMMAND_NAME,
            format!("invalid {name}: {value}"),
        ));
    }

    let amount = digits.parse::<u64>().map_err(|_| {
        ToolError::new(64, COMMAND_NAME, format!("invalid {name}: {value}"))
    })?;
    let seconds = match suffix {
        "" | "s" => amount,
        "m" => amount.saturating_mul(60),
        "h" => amount.saturating_mul(60 * 60),
        _ => {
            return Err(ToolError::new(
                64,
                COMMAND_NAME,
                format!("invalid {name}: {value}"),
            ));
        }
    };
    Ok(Duration::from_secs(seconds))
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
    let environment_pvc_name = environment_pvc_name(config);
    ensure_environment_pvc(client, config, &environment_pvc_name).await?;
    let mut state = read_state(&config.state_file)?;
    let pod_name = pod_name_for_session(&config.owner_pod_name, session_key);

    if !refresh {
        if let Some(entry) = state.sessions.get(session_key) {
            if !entry.auth_token.is_empty() && healthcheck(config, &entry.pod_ip).await {
                return Ok(prepared_from_entry(entry));
            }
        }
    }

    if let Ok(pod) = pods.get(&pod_name).await {
        if pod_ready(&pod) {
            if let Some(entry) = state.sessions.get(session_key) {
                if let Some(pod_ip) = pod_ip(&pod) {
                    if !entry.auth_token.is_empty() && wait_for_healthcheck(config, &pod_ip).await {
                        let prepared = PreparedPod {
                            pod_name: pod_name.clone(),
                            pod_ip,
                            auth_token: entry.auth_token.clone(),
                            environment_pvc_name: entry.environment_pvc_name.clone(),
                        };
                        state.sessions.insert(
                            session_key.to_string(),
                            entry_from_prepared(&prepared),
                        );
                        write_state(&config.state_file, &state)?;
                        return Ok(prepared);
                    }
                }
            }
        }
        delete_pod(client, &config.namespace, &pod_name).await?;
    }

    let bootstrap_image = resolve_bootstrap_image(client, config).await?;
    let auth_token = generate_session_token()?;
    let pod = build_exec_pod(
        config,
        session_key,
        &pod_name,
        &auth_token,
        &bootstrap_image,
        &environment_pvc_name,
    )?;
    create_pod(&pods, &pod).await?;
    let pod_ip = wait_for_pod(client, config, &pod_name).await?;
    let prepared = PreparedPod {
        pod_name,
        pod_ip,
        auth_token,
        environment_pvc_name,
    };
    state
        .sessions
        .insert(session_key.to_string(), entry_from_prepared(&prepared));
    write_state(&config.state_file, &state)?;
    Ok(prepared)
}

fn read_prepared_pod(config: &SessionExecConfig, session_key: &str) -> Result<PreparedPod, String> {
    let state = read_state(&config.state_file)?;
    let entry = state
        .sessions
        .get(session_key)
        .ok_or_else(|| format!("missing session execution state for {session_key}"))?;
    Ok(prepared_from_entry(entry))
}

fn prepared_from_entry(entry: &SessionEntry) -> PreparedPod {
    PreparedPod {
        pod_name: entry.pod_name.clone(),
        pod_ip: entry.pod_ip.clone(),
        auth_token: entry.auth_token.clone(),
        environment_pvc_name: entry.environment_pvc_name.clone(),
    }
}

fn entry_from_prepared(prepared: &PreparedPod) -> SessionEntry {
    SessionEntry {
        pod_name: prepared.pod_name.clone(),
        pod_ip: prepared.pod_ip.clone(),
        auth_token: prepared.auth_token.clone(),
        environment_pvc_name: prepared.environment_pvc_name.clone(),
    }
}

async fn kube_client() -> Result<Client, String> {
    Client::try_default()
        .await
        .map_err(|error| format!("failed to create Kubernetes client: {error}"))
}

async fn ensure_environment_pvc(
    client: &Client,
    config: &SessionExecConfig,
    pvc_name: &str,
) -> Result<(), String> {
    let pvcs: Api<PersistentVolumeClaim> = Api::namespaced(client.clone(), &config.namespace);
    if pvcs.get(pvc_name).await.is_ok() {
        return Ok(());
    }

    let pvc = build_environment_pvc(config, pvc_name)?;
    match pvcs.create(&PostParams::default(), &pvc).await {
        Ok(_) => Ok(()),
        Err(kube::Error::Api(error)) if error.code == 409 => Ok(()),
        Err(error) => Err(format!(
            "failed to create execution environment PVC {pvc_name}: {error}"
        )),
    }
}

async fn resolve_bootstrap_image(
    client: &Client,
    config: &SessionExecConfig,
) -> Result<String, String> {
    if let Some(image) = &config.bootstrap_image {
        return Ok(image.clone());
    }

    let pods: Api<Pod> = Api::namespaced(client.clone(), &config.namespace);
    let owner_pod = pods
        .get(&config.owner_pod_name)
        .await
        .map_err(|error| format!("failed to determine bootstrap image: {error}"))?;
    owner_pod
        .spec
        .as_ref()
        .and_then(|spec| {
            spec.containers
                .iter()
                .find(|container| container.name == "control-plane")
                .or_else(|| spec.containers.first())
        })
        .and_then(|container| container.image.clone())
        .ok_or_else(|| {
            format!(
                "owner pod {} does not expose a bootstrap image",
                config.owner_pod_name
            )
        })
}

async fn create_pod(pods: &Api<Pod>, pod: &Pod) -> Result<(), String> {
    match pods.create(&PostParams::default(), pod).await {
        Ok(_) => Ok(()),
        Err(kube::Error::Api(error)) if error.code == 409 => Ok(()),
        Err(error) => Err(format!(
            "failed to create execution pod {}: {error}",
            pod.metadata.name.as_deref().unwrap_or("unknown")
        )),
    }
}

async fn delete_pod(client: &Client, namespace: &str, pod_name: &str) -> Result<(), String> {
    let pods: Api<Pod> = Api::namespaced(client.clone(), namespace);
    match pods
        .delete(pod_name, &DeleteParams::default())
        .await
        .map(|_| ())
    {
        Ok(()) => Ok(()),
        Err(kube::Error::Api(error)) if error.code == 404 => Ok(()),
        Err(error) => Err(format!("failed to delete execution pod {pod_name}: {error}")),
    }
}

async fn wait_for_pod(
    client: &Client,
    config: &SessionExecConfig,
    pod_name: &str,
) -> Result<String, String> {
    let pods: Api<Pod> = Api::namespaced(client.clone(), &config.namespace);
    let deadline = Instant::now() + config.start_timeout;
    loop {
        if Instant::now() > deadline {
            return Err(format!(
                "timed out waiting for execution pod {pod_name} to become ready"
            ));
        }

        let pod = match pods.get(pod_name).await {
            Ok(pod) => pod,
            Err(kube::Error::Api(error)) if error.code == 404 => {
                sleep(Duration::from_secs(1)).await;
                continue;
            }
            Err(error) => {
                return Err(format!(
                    "failed while waiting for execution pod {pod_name}: {error}"
                ));
            }
        };

        if pod_ready(&pod) {
            if let Some(pod_ip) = pod_ip(&pod) {
                if wait_for_healthcheck(config, &pod_ip).await {
                    return Ok(pod_ip);
                }
            }
        }

        sleep(Duration::from_secs(1)).await;
    }
}

async fn wait_for_healthcheck(config: &SessionExecConfig, pod_ip: &str) -> bool {
    for _ in 0..30 {
        if healthcheck(config, pod_ip).await {
            return true;
        }
        sleep(Duration::from_secs(1)).await;
    }
    false
}

async fn healthcheck(config: &SessionExecConfig, pod_ip: &str) -> bool {
    if pod_ip.is_empty() {
        return false;
    }
    check_health(
        &format!("http://{}:{}", pod_ip, config.port),
        Duration::from_secs(2),
    )
    .await
    .is_ok()
}

fn pod_ready(pod: &Pod) -> bool {
    let Some(status) = &pod.status else {
        return false;
    };
    if status.phase.as_deref() != Some("Running") {
        return false;
    }
    status
        .container_statuses
        .as_ref()
        .is_some_and(|statuses| {
            statuses
                .iter()
                .any(|container| container.name == "execution" && container.ready)
        })
}

fn pod_ip(pod: &Pod) -> Option<String> {
    pod.status.as_ref()?.pod_ip.clone().filter(|value| !value.is_empty())
}

fn environment_pvc_name(config: &SessionExecConfig) -> String {
    let prefix = config.environment_pvc_prefix.trim_end_matches('-');
    format!("{prefix}-{}", sanitize_dns_label(&config.node_name))
}

fn pod_name_for_session(owner_pod_name: &str, session_key: &str) -> String {
    let normalized = sanitize_dns_subdomain(session_key);
    let mut hasher = Sha256::new();
    hasher.update(owner_pod_name.as_bytes());
    hasher.update(b":");
    hasher.update(session_key.as_bytes());
    let checksum = format!("{:x}", hasher.finalize());
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

fn build_environment_pvc(
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

fn build_exec_pod(
    config: &SessionExecConfig,
    session_key: &str,
    pod_name: &str,
    auth_token: &str,
    bootstrap_image: &str,
    environment_pvc_name: &str,
) -> Result<Pod, String> {
    let environment_root = config.environment_mount_path.trim_end_matches('/');
    let chroot_root = format!("{environment_root}/root");
    let exec_api_path = format!("{environment_root}/control-plane-exec-api");
    let hooks_source = format!("{environment_root}/hooks/git");
    let workspace_mount = nested_mount_path(&chroot_root, &config.workspace_mount_path)?;
    let remote_home_mount = nested_mount_path(&chroot_root, &config.remote_home)?;
    let gh_mount = format!("{remote_home_mount}/.config/gh");
    let ssh_mount = format!("{remote_home_mount}/.ssh");

    let init_command = format!(
        "set -eu\nenvironment_root={environment_root:?}\ninstall -d -m 0755 \"$environment_root/hooks/git\" \"$environment_root/root\"\nif [ ! -x \"$environment_root/control-plane-exec-api\" ]; then\n  cp /usr/local/bin/control-plane-exec-api \"$environment_root/control-plane-exec-api\"\n  chmod 755 \"$environment_root/control-plane-exec-api\"\nfi\nif [ ! -x \"$environment_root/hooks/git/pre-commit\" ] || [ ! -x \"$environment_root/hooks/git/pre-push\" ]; then\n  rm -rf \"$environment_root/hooks/git\"\n  install -d -m 0755 \"$environment_root/hooks/git\"\n  cp -R /usr/local/share/control-plane/hooks/git/. \"$environment_root/hooks/git/\"\n  find \"$environment_root/hooks/git\" -type d -exec chmod 755 {{}} +\n  find \"$environment_root/hooks/git\" -type f -exec chmod 644 {{}} +\n  chmod 755 \"$environment_root/hooks/git/pre-commit\" \"$environment_root/hooks/git/pre-push\"\nfi\n"
    );

    let mut volume_mounts = vec![
        json!({
            "name": "environment",
            "mountPath": config.environment_mount_path,
        }),
        json!({
            "name": "workspace",
            "mountPath": workspace_mount,
            "subPath": config.workspace_subpath,
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
            "readOnly": true
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

    serde_json::from_value(json!({
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
            "nodeName": config.node_name,
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
                        "add": ["CHOWN", "DAC_OVERRIDE", "MKNOD", "SETGID", "SETUID", "SYS_CHROOT"]
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
                    "name": "CONTROL_PLANE_EXEC_API_TOKEN",
                    "value": auth_token
                }, {
                    "name": "CONTROL_PLANE_WORKSPACE",
                    "value": config.workspace_mount_path
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
                    "name": "CONTROL_PLANE_FAST_EXECUTION_HOME",
                    "value": config.remote_home
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
    }))
    .map_err(|error| format!("failed to build execution pod manifest: {error}"))
}

fn nested_mount_path(root: &str, absolute_path: &str) -> Result<String, String> {
    let trimmed_root = root.trim_end_matches('/');
    let suffix = absolute_path.strip_prefix('/').ok_or_else(|| {
        format!("expected absolute nested mount path, got {absolute_path}")
    })?;
    Ok(format!("{trimmed_root}/{suffix}"))
}

fn ensure_state_parent(config: &SessionExecConfig) -> Result<(), String> {
    if let Some(parent) = config.state_file.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            format!(
                "failed to create session execution state directory {}: {error}",
                parent.display()
            )
        })?;
    }
    Ok(())
}

fn read_state(path: &Path) -> Result<SessionState, String> {
    match fs::read_to_string(path) {
        Ok(content) => serde_json::from_str(&content)
            .map_err(|error| format!("failed to parse {}: {error}", path.display())),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(SessionState::default()),
        Err(error) => Err(format!("failed to read {}: {error}", path.display())),
    }
}

fn write_state(path: &Path, state: &SessionState) -> Result<(), String> {
    let content =
        serde_json::to_string(state).map_err(|error| format!("failed to encode state: {error}"))?;
    fs::write(path, format!("{content}\n"))
        .map_err(|error| format!("failed to write {}: {error}", path.display()))
}

fn generate_session_token() -> Result<String, String> {
    let mut bytes = [0u8; 32];
    File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(&mut bytes))
        .map_err(|error| format!("failed to generate session token: {error}"))?;
    Ok(base64::engine::general_purpose::STANDARD.encode(bytes))
}

struct StateLock {
    file: File,
}

impl StateLock {
    fn acquire(path: &Path) -> Result<Self, String> {
        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .read(true)
            .open(path)
            .map_err(|error| format!("failed to open {}: {error}", path.display()))?;
        let status = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) };
        if status == 0 {
            Ok(Self { file })
        } else {
            Err(format!("failed to lock {}: {}", path.display(), std::io::Error::last_os_error()))
        }
    }
}

impl Drop for StateLock {
    fn drop(&mut self) {
        unsafe {
            libc::flock(self.file.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        PreparedPod, SessionExecConfig, build_environment_pvc, build_exec_pod,
        entry_from_prepared, environment_pvc_name, pod_name_for_session,
    };

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
            owner_pod_name: "control-plane-0".to_string(),
            owner_pod_uid: "pod-uid-1".to_string(),
            node_name: "kind-control-plane".to_string(),
            image: "ghcr.io/example/control-plane:test".to_string(),
            image_pull_policy: "Never".to_string(),
            bootstrap_image: Some("ghcr.io/example/bootstrap:test".to_string()),
            bootstrap_image_pull_policy: "IfNotPresent".to_string(),
            start_timeout: std::time::Duration::from_secs(120),
            port: 8080,
            cpu_request: "250m".to_string(),
            cpu_limit: "1".to_string(),
            memory_request: "256Mi".to_string(),
            memory_limit: "1Gi".to_string(),
            remote_home: "/root".to_string(),
            run_as_uid: 1000,
            run_as_gid: 1000,
            git_user_name: Some("Copilot".to_string()),
            git_user_email: Some("copilot@example.com".to_string()),
            request_timeout: std::time::Duration::from_secs(3600),
            environment_pvc_prefix: "node-workspace".to_string(),
            environment_storage_class: Some("standard".to_string()),
            environment_size: "10Gi".to_string(),
            environment_mount_path: "/environment".to_string(),
        }
    }

    #[test]
    fn pvc_name_tracks_node_name() {
        let config = config();
        assert_eq!(
            environment_pvc_name(&config),
            "node-workspace-kind-control-plane"
        );
    }

    #[test]
    fn pod_name_stays_stable_for_session() {
        assert_eq!(
            pod_name_for_session("control-plane-0", "Session_42"),
            "control-plane-exec-f6373fc203-session-42"
        );
    }

    #[test]
    fn pvc_manifest_uses_rwo_storage() {
        let config = config();
        let pvc = build_environment_pvc(&config, "node-workspace-kind-control-plane").unwrap();
        assert_eq!(
            pvc.spec
                .as_ref()
                .and_then(|spec| spec.access_modes.as_ref())
                .unwrap(),
            &vec!["ReadWriteOnce".to_string()]
        );
        assert_eq!(
            pvc.spec
                .as_ref()
                .and_then(|spec| spec.storage_class_name.as_ref())
                .unwrap(),
            "standard"
        );
    }

    #[test]
    fn pod_manifest_mounts_environment_cache_and_chroot_workspace() {
        let config = config();
        let pod = build_exec_pod(
            &config,
            "session-42",
            "control-plane-exec-test",
            "session-token",
            "ghcr.io/example/bootstrap:test",
            "node-workspace-kind-control-plane",
        )
        .unwrap();
        let spec = pod.spec.unwrap();
        let execution = spec.containers.iter().find(|container| container.name == "execution").unwrap();
        assert_eq!(
            execution.command.as_ref().unwrap(),
            &vec![
                "/environment/control-plane-exec-api".to_string(),
                "serve".to_string()
            ]
        );
        let mounts = execution.volume_mounts.as_ref().unwrap();
        assert!(mounts.iter().any(|mount| mount.name == "environment" && mount.mount_path == "/environment"));
        assert!(mounts.iter().any(|mount| mount.name == "workspace"
            && mount.mount_path == "/environment/root/workspace"));
        assert!(mounts.iter().any(|mount| mount.name == "copilot-session"
            && mount.mount_path == "/environment/root/root/.config/gh"));
        let env = execution.env.as_ref().unwrap();
        assert!(env.iter().any(|value| value.name == "CONTROL_PLANE_FAST_EXECUTION_CHROOT_ROOT"
            && value.value.as_deref() == Some("/environment/root")));
        assert!(env.iter().any(|value| value.name == "CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_MOUNT_PATH"
            && value.value.as_deref() == Some("/environment")));
        assert!(env.iter().any(|value| value.name == "CONTROL_PLANE_FAST_EXECUTION_GIT_HOOKS_SOURCE"
            && value.value.as_deref() == Some("/environment/hooks/git")));
        let volumes = spec.volumes.as_ref().unwrap();
        assert!(volumes.iter().any(|volume| volume.name == "environment"));
        assert!(!volumes.iter().any(|volume| volume.name == "bootstrap"));
    }

    #[test]
    fn session_state_keeps_only_runtime_routing_fields() {
        let entry = entry_from_prepared(&PreparedPod {
            pod_name: "control-plane-exec-test".to_string(),
            pod_ip: "10.0.0.42".to_string(),
            auth_token: "session-token".to_string(),
            environment_pvc_name: "node-workspace-kind-control-plane".to_string(),
        });
        let value = serde_json::to_value(entry).unwrap();

        assert_eq!(
            value,
            serde_json::json!({
                "podName": "control-plane-exec-test",
                "podIp": "10.0.0.42",
                "authToken": "session-token",
                "environmentPvcName": "node-workspace-kind-control-plane"
            })
        );
    }
}
