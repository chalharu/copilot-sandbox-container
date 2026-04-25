use std::env;
use std::path::PathBuf;
use std::time::Duration;

use crate::error::{ToolError, ToolResult};

use super::COMMAND_NAME;

#[derive(Debug, Clone)]
pub(super) struct SessionExecConfig {
    pub(super) state_file: PathBuf,
    pub(super) lock_file: PathBuf,
    pub(super) workspace_pvc: String,
    pub(super) workspace_mount_path: String,
    pub(super) workspace_subpath: String,
    pub(super) copilot_session_pvc: Option<String>,
    pub(super) copilot_session_gh_subpath: String,
    pub(super) copilot_session_ssh_subpath: String,
    pub(super) namespace: String,
    pub(super) job_namespace: String,
    pub(super) owner_pod_name: String,
    pub(super) owner_pod_uid: String,
    pub(super) node_name: String,
    pub(super) image: String,
    pub(super) image_pull_policy: String,
    pub(super) bootstrap_image: Option<String>,
    pub(super) bootstrap_image_pull_policy: String,
    pub(super) start_timeout: Duration,
    pub(super) port: u16,
    pub(super) cpu_request: String,
    pub(super) cpu_limit: String,
    pub(super) memory_request: String,
    pub(super) memory_limit: String,
    pub(super) remote_home: String,
    pub(super) service_account: Option<String>,
    pub(super) run_as_uid: u32,
    pub(super) run_as_gid: u32,
    pub(super) git_user_name: Option<String>,
    pub(super) git_user_email: Option<String>,
    pub(super) request_timeout: Duration,
    pub(super) post_tool_use_forward_addr: String,
    pub(super) post_tool_use_forward_token: String,
    pub(super) post_tool_use_forward_timeout: Duration,
    pub(super) startup_script: Option<String>,
    pub(super) environment_pvc_prefix: String,
    pub(super) environment_storage_class: Option<String>,
    pub(super) environment_size: String,
    pub(super) environment_mount_path: String,
    pub(super) ephemeral_storage_class: Option<String>,
    pub(super) ephemeral_size: String,
}

pub(super) fn load_config() -> ToolResult<SessionExecConfig> {
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
    let job_namespace = non_empty_env(
        "CONTROL_PLANE_JOB_NAMESPACE",
        env_or_default("CONTROL_PLANE_JOB_NAMESPACE", &namespace),
    )?;
    let owner_pod_name = required_env("CONTROL_PLANE_POD_NAME")?;
    let owner_pod_uid = required_env("CONTROL_PLANE_POD_UID")?;
    let node_name = required_env("CONTROL_PLANE_NODE_NAME")?;
    let image = required_env("CONTROL_PLANE_FAST_EXECUTION_IMAGE")?;
    let image_pull_policy = env_or_default(
        "CONTROL_PLANE_FAST_EXECUTION_IMAGE_PULL_POLICY",
        "IfNotPresent",
    );
    let bootstrap_image = optional_env("CONTROL_PLANE_FAST_EXECUTION_BOOTSTRAP_IMAGE");
    let bootstrap_image_pull_policy = env_or_default(
        "CONTROL_PLANE_FAST_EXECUTION_BOOTSTRAP_IMAGE_PULL_POLICY",
        "IfNotPresent",
    );
    let start_timeout = parse_duration(
        &env_or_default("CONTROL_PLANE_FAST_EXECUTION_START_TIMEOUT", "300s"),
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
    let post_tool_use_forward_addr = required_env("CONTROL_PLANE_POST_TOOL_USE_FORWARD_ADDR")?;
    let post_tool_use_forward_token = required_env("CONTROL_PLANE_POST_TOOL_USE_FORWARD_TOKEN")?;
    let post_tool_use_forward_timeout = Duration::from_secs(parse_positive_u64(
        &env_or_default("CONTROL_PLANE_POST_TOOL_USE_FORWARD_TIMEOUT_SEC", "3600"),
        "CONTROL_PLANE_POST_TOOL_USE_FORWARD_TIMEOUT_SEC",
    )?);
    let startup_script = optional_env("CONTROL_PLANE_FAST_EXECUTION_STARTUP_SCRIPT");
    let environment_pvc_prefix = env_or_default(
        "CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_PVC_PREFIX",
        "node-workspace",
    );
    let environment_storage_class =
        optional_env("CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_STORAGE_CLASS");
    let environment_size = env_or_default("CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_SIZE", "10Gi");
    let environment_mount_path = absolute_env(
        "CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_MOUNT_PATH",
        "/environment",
        "environment mount path",
    )?;
    let ephemeral_storage_class =
        optional_env("CONTROL_PLANE_FAST_EXECUTION_EPHEMERAL_STORAGE_CLASS");
    let ephemeral_size = env_or_default("CONTROL_PLANE_FAST_EXECUTION_EPHEMERAL_SIZE", "10Gi");

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
        job_namespace,
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
        service_account: optional_env("CONTROL_PLANE_FAST_EXECUTION_SERVICE_ACCOUNT"),
        run_as_uid,
        run_as_gid,
        git_user_name: optional_env("CONTROL_PLANE_GIT_USER_NAME"),
        git_user_email: optional_env("CONTROL_PLANE_GIT_USER_EMAIL"),
        request_timeout,
        post_tool_use_forward_addr,
        post_tool_use_forward_token,
        post_tool_use_forward_timeout,
        startup_script,
        environment_pvc_prefix,
        environment_storage_class,
        environment_size,
        environment_mount_path,
        ephemeral_storage_class,
        ephemeral_size,
    })
}

fn ensure_enabled() -> ToolResult<()> {
    if env::var("CONTROL_PLANE_FAST_EXECUTION_ENABLED")
        .ok()
        .as_deref()
        == Some("1")
    {
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
    let value = env::var(name)
        .map_err(|_| ToolError::new(64, COMMAND_NAME, format!("{name} is required")))?;
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
    value
        .parse::<u64>()
        .ok()
        .filter(|parsed| *parsed > 0)
        .ok_or_else(|| {
            ToolError::new(
                64,
                COMMAND_NAME,
                format!("{name} must be a positive integer: {value}"),
            )
        })
}

fn parse_non_root_u32(value: &str, name: &str) -> ToolResult<u32> {
    value
        .parse::<u32>()
        .ok()
        .filter(|parsed| *parsed > 0)
        .ok_or_else(|| {
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

    let amount = digits
        .parse::<u64>()
        .map_err(|_| ToolError::new(64, COMMAND_NAME, format!("invalid {name}: {value}")))?;
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
