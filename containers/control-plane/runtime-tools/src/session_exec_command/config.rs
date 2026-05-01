use std::collections::BTreeSet;
use std::env;
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

use crate::error::{ToolError, ToolResult};
use k8s_openapi::api::core::v1::{Volume, VolumeMount};

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
    pub(super) extra_volumes: Vec<Volume>,
    pub(super) extra_volume_mounts: Vec<VolumeMount>,
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
    let copilot_session_pvc = optional_env("CONTROL_PLANE_COPILOT_SESSION_PVC");
    let service_account = optional_env("CONTROL_PLANE_FAST_EXECUTION_SERVICE_ACCOUNT");
    let extra_volumes = parse_extra_volumes()?;
    let extra_volume_mounts = parse_extra_volume_mounts()?;
    validate_extra_volume_config(
        &extra_volumes,
        &extra_volume_mounts,
        &workspace_mount_path,
        &remote_home,
        copilot_session_pvc.is_some(),
        service_account.is_some(),
    )?;

    Ok(SessionExecConfig {
        state_file,
        lock_file,
        workspace_pvc,
        workspace_mount_path,
        workspace_subpath,
        copilot_session_pvc,
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
        start_timeout,
        port,
        cpu_request,
        cpu_limit,
        memory_request,
        memory_limit,
        remote_home,
        service_account,
        run_as_uid,
        run_as_gid,
        git_user_name: optional_env("CONTROL_PLANE_GIT_USER_NAME"),
        git_user_email: optional_env("CONTROL_PLANE_GIT_USER_EMAIL"),
        request_timeout,
        post_tool_use_forward_addr,
        post_tool_use_forward_token,
        post_tool_use_forward_timeout,
        startup_script,
        extra_volumes,
        extra_volume_mounts,
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

fn parse_extra_volumes() -> ToolResult<Vec<Volume>> {
    let name = "CONTROL_PLANE_FAST_EXECUTION_EXTRA_VOLUMES_JSON";
    let Some(value) = optional_env(name) else {
        return Ok(Vec::new());
    };
    parse_extra_volumes_json(name, &value)
}

fn parse_extra_volumes_json(name: &str, value: &str) -> ToolResult<Vec<Volume>> {
    let parsed: serde_json::Value = serde_json::from_str(&value).map_err(|error| {
        ToolError::new(
            64,
            COMMAND_NAME,
            format!("{name} must be a JSON array of Kubernetes core/v1 Volume objects: {error}"),
        )
    })?;
    if !parsed.is_array() {
        return Err(ToolError::new(
            64,
            COMMAND_NAME,
            format!("{name} must be a JSON array of Kubernetes core/v1 Volume objects"),
        ));
    }
    serde_json::from_value(parsed).map_err(|error| {
        ToolError::new(
            64,
            COMMAND_NAME,
            format!("{name} must contain valid Kubernetes core/v1 Volume objects: {error}"),
        )
    })
}

fn parse_extra_volume_mounts() -> ToolResult<Vec<VolumeMount>> {
    let name = "CONTROL_PLANE_FAST_EXECUTION_EXTRA_VOLUME_MOUNTS_JSON";
    let Some(value) = optional_env(name) else {
        return Ok(Vec::new());
    };
    parse_extra_volume_mounts_json(name, &value)
}

fn parse_extra_volume_mounts_json(name: &str, value: &str) -> ToolResult<Vec<VolumeMount>> {
    let parsed: serde_json::Value = serde_json::from_str(&value).map_err(|error| {
        ToolError::new(
            64,
            COMMAND_NAME,
            format!(
                "{name} must be a JSON array of Kubernetes core/v1 VolumeMount objects: {error}"
            ),
        )
    })?;
    if !parsed.is_array() {
        return Err(ToolError::new(
            64,
            COMMAND_NAME,
            format!("{name} must be a JSON array of Kubernetes core/v1 VolumeMount objects"),
        ));
    }
    serde_json::from_value(parsed).map_err(|error| {
        ToolError::new(
            64,
            COMMAND_NAME,
            format!("{name} must contain valid Kubernetes core/v1 VolumeMount objects: {error}"),
        )
    })
}

fn validate_extra_volume_config(
    extra_volumes: &[Volume],
    extra_volume_mounts: &[VolumeMount],
    workspace_mount_path: &str,
    remote_home: &str,
    has_copilot_session_volume: bool,
    has_service_account_token: bool,
) -> ToolResult<()> {
    let mut known_volume_names = BTreeSet::from(["workspace".to_string()]);
    if has_copilot_session_volume {
        known_volume_names.insert("copilot-session".to_string());
    }
    for volume in extra_volumes {
        if volume.name.trim().is_empty() {
            return Err(ToolError::new(
                64,
                COMMAND_NAME,
                "CONTROL_PLANE_FAST_EXECUTION_EXTRA_VOLUMES_JSON contains a volume with an empty name",
            ));
        }
        if !known_volume_names.insert(volume.name.clone()) {
            return Err(ToolError::new(
                64,
                COMMAND_NAME,
                format!(
                    "CONTROL_PLANE_FAST_EXECUTION_EXTRA_VOLUMES_JSON contains duplicate volume name: {}",
                    volume.name
                ),
            ));
        }
        if volume.host_path.is_some() {
            return Err(ToolError::new(
                64,
                COMMAND_NAME,
                format!(
                    "CONTROL_PLANE_FAST_EXECUTION_EXTRA_VOLUMES_JSON hostPath volumes are not allowed: {}",
                    volume.name
                ),
            ));
        }
    }

    let reserved_mount_paths = reserved_extra_mount_paths(
        workspace_mount_path,
        remote_home,
        has_copilot_session_volume,
        has_service_account_token,
    )?;
    let mut mount_paths = BTreeSet::new();
    for mount in extra_volume_mounts {
        if !known_volume_names.contains(&mount.name) {
            return Err(ToolError::new(
                64,
                COMMAND_NAME,
                format!(
                    "CONTROL_PLANE_FAST_EXECUTION_EXTRA_VOLUME_MOUNTS_JSON references unknown volume: {}",
                    mount.name
                ),
            ));
        }
        let Some(mount_path) = normalize_absolute_mount_path(&mount.mount_path) else {
            return Err(ToolError::new(
                64,
                COMMAND_NAME,
                format!(
                    "CONTROL_PLANE_FAST_EXECUTION_EXTRA_VOLUME_MOUNTS_JSON mountPath must be absolute for volume {}: {}",
                    mount.name, mount.mount_path
                ),
            ));
        };
        if !mount_paths.insert(mount_path.clone()) {
            return Err(ToolError::new(
                64,
                COMMAND_NAME,
                format!(
                    "CONTROL_PLANE_FAST_EXECUTION_EXTRA_VOLUME_MOUNTS_JSON contains duplicate mountPath: {}",
                    mount.mount_path
                ),
            ));
        }
        if let Some(reserved_path) = reserved_mount_paths
            .iter()
            .find(|reserved_path| mount_paths_overlap(&mount_path, reserved_path))
        {
            return Err(ToolError::new(
                64,
                COMMAND_NAME,
                format!(
                    "CONTROL_PLANE_FAST_EXECUTION_EXTRA_VOLUME_MOUNTS_JSON mountPath must not overlap reserved path {reserved_path} for volume {}: {}",
                    mount.name, mount.mount_path
                ),
            ));
        }
    }
    Ok(())
}

fn reserved_extra_mount_paths(
    workspace_mount_path: &str,
    remote_home: &str,
    has_copilot_session_volume: bool,
    has_service_account_token: bool,
) -> ToolResult<Vec<String>> {
    let mut paths = vec![normalize_configured_mount_path(
        workspace_mount_path,
        "workspace mount path",
    )?];
    if has_copilot_session_volume {
        paths.push(normalize_configured_mount_path(
            &Path::new(remote_home).join(".config/gh").to_string_lossy(),
            "Copilot session GitHub mount path",
        )?);
        paths.push(normalize_configured_mount_path(
            &Path::new(remote_home).join(".ssh").to_string_lossy(),
            "Copilot session SSH mount path",
        )?);
    }
    if has_service_account_token {
        paths.push(String::from(
            "/var/run/secrets/kubernetes.io/serviceaccount",
        ));
    }
    Ok(paths)
}

fn normalize_configured_mount_path(path: &str, description: &str) -> ToolResult<String> {
    normalize_absolute_mount_path(path)
        .ok_or_else(|| ToolError::new(64, COMMAND_NAME, format!("invalid {description}: {path}")))
}

fn normalize_absolute_mount_path(path: &str) -> Option<String> {
    let path = Path::new(path);
    if !path.is_absolute() {
        return None;
    }

    let mut parts = Vec::new();
    for component in path.components() {
        match component {
            Component::RootDir => {}
            Component::CurDir => {}
            Component::Normal(value) => parts.push(value.to_str()?.to_string()),
            Component::ParentDir => {
                parts.pop()?;
            }
            Component::Prefix(_) => return None,
        }
    }

    if parts.is_empty() {
        Some(String::from("/"))
    } else {
        Some(format!("/{}", parts.join("/")))
    }
}

fn mounts_path_or_child(path: &str, parent: &str) -> bool {
    if parent == "/" || path == parent {
        return true;
    }
    path.strip_prefix(parent)
        .is_some_and(|suffix| suffix.starts_with('/'))
}

fn mount_paths_overlap(left: &str, right: &str) -> bool {
    mounts_path_or_child(left, right) || mounts_path_or_child(right, left)
}

#[cfg(test)]
mod tests {
    use super::{
        parse_extra_volume_mounts_json, parse_extra_volumes_json, validate_extra_volume_config,
    };

    #[test]
    fn extra_volume_json_parses_kubernetes_volumes_and_mounts() {
        let volumes = parse_extra_volumes_json(
            "CONTROL_PLANE_FAST_EXECUTION_EXTRA_VOLUMES_JSON",
            r#"[{"name":"ephemeral-storage","ephemeral":{"volumeClaimTemplate":{"spec":{"accessModes":["ReadWriteOnce"],"storageClassName":"standard","resources":{"requests":{"storage":"10Gi"}}}}}}]"#,
        )
        .unwrap();
        let mounts = parse_extra_volume_mounts_json(
            "CONTROL_PLANE_FAST_EXECUTION_EXTRA_VOLUME_MOUNTS_JSON",
            r#"[{"name":"ephemeral-storage","mountPath":"/var/tmp/control-plane"}]"#,
        )
        .unwrap();

        validate_extra_volume_config(&volumes, &mounts, "/workspace", "/root", false, false)
            .unwrap();
        assert_eq!(volumes[0].name, "ephemeral-storage");
        assert_eq!(mounts[0].mount_path, "/var/tmp/control-plane");
    }

    #[test]
    fn extra_volume_json_rejects_non_arrays() {
        let error = parse_extra_volumes_json(
            "CONTROL_PLANE_FAST_EXECUTION_EXTRA_VOLUMES_JSON",
            r#"{"name":"not-an-array"}"#,
        )
        .unwrap_err();

        assert!(error.message.contains("must be a JSON array"));
    }

    #[test]
    fn extra_volume_config_rejects_duplicate_volume_names() {
        let volumes = parse_extra_volumes_json(
            "CONTROL_PLANE_FAST_EXECUTION_EXTRA_VOLUMES_JSON",
            r#"[{"name":"cache","emptyDir":{}},{"name":"cache","emptyDir":{}}]"#,
        )
        .unwrap();
        let mounts = parse_extra_volume_mounts_json(
            "CONTROL_PLANE_FAST_EXECUTION_EXTRA_VOLUME_MOUNTS_JSON",
            r#"[{"name":"cache","mountPath":"/cache"}]"#,
        )
        .unwrap();

        let error =
            validate_extra_volume_config(&volumes, &mounts, "/workspace", "/root", false, false)
                .unwrap_err();
        assert!(error.message.contains("duplicate volume name: cache"));
    }

    #[test]
    fn extra_volume_config_rejects_host_path_volumes() {
        let volumes = parse_extra_volumes_json(
            "CONTROL_PLANE_FAST_EXECUTION_EXTRA_VOLUMES_JSON",
            r#"[{"name":"node-root","hostPath":{"path":"/"}}]"#,
        )
        .unwrap();

        let error =
            validate_extra_volume_config(&volumes, &[], "/workspace", "/root", false, false)
                .unwrap_err();
        assert!(error.message.contains("hostPath volumes are not allowed"));
    }

    #[test]
    fn extra_volume_config_rejects_unknown_mount_references() {
        let mounts = parse_extra_volume_mounts_json(
            "CONTROL_PLANE_FAST_EXECUTION_EXTRA_VOLUME_MOUNTS_JSON",
            r#"[{"name":"missing","mountPath":"/cache"}]"#,
        )
        .unwrap();

        let error = validate_extra_volume_config(&[], &mounts, "/workspace", "/root", false, false)
            .unwrap_err();
        assert!(error.message.contains("references unknown volume: missing"));
    }

    #[test]
    fn extra_volume_config_allows_built_in_mount_references() {
        let mounts = parse_extra_volume_mounts_json(
            "CONTROL_PLANE_FAST_EXECUTION_EXTRA_VOLUME_MOUNTS_JSON",
            r#"[{"name":"workspace","mountPath":"/alternate-workspace"},{"name":"copilot-session","mountPath":"/root/.config/extra"}]"#,
        )
        .unwrap();

        validate_extra_volume_config(&[], &mounts, "/workspace", "/root", true, false).unwrap();
    }

    #[test]
    fn extra_volume_config_rejects_relative_mount_paths() {
        let volumes = parse_extra_volumes_json(
            "CONTROL_PLANE_FAST_EXECUTION_EXTRA_VOLUMES_JSON",
            r#"[{"name":"cache","emptyDir":{}}]"#,
        )
        .unwrap();
        let mounts = parse_extra_volume_mounts_json(
            "CONTROL_PLANE_FAST_EXECUTION_EXTRA_VOLUME_MOUNTS_JSON",
            r#"[{"name":"cache","mountPath":"relative"}]"#,
        )
        .unwrap();

        let error =
            validate_extra_volume_config(&volumes, &mounts, "/workspace", "/root", false, false)
                .unwrap_err();
        assert!(error.message.contains("mountPath must be absolute"));
    }

    #[test]
    fn extra_volume_config_rejects_duplicate_mount_paths() {
        let volumes = parse_extra_volumes_json(
            "CONTROL_PLANE_FAST_EXECUTION_EXTRA_VOLUMES_JSON",
            r#"[{"name":"cache-a","emptyDir":{}},{"name":"cache-b","emptyDir":{}}]"#,
        )
        .unwrap();
        let mounts = parse_extra_volume_mounts_json(
            "CONTROL_PLANE_FAST_EXECUTION_EXTRA_VOLUME_MOUNTS_JSON",
            r#"[{"name":"cache-a","mountPath":"/cache"},{"name":"cache-b","mountPath":"/cache/."}]"#,
        )
        .unwrap();

        let error =
            validate_extra_volume_config(&volumes, &mounts, "/workspace", "/root", false, false)
                .unwrap_err();
        assert!(error.message.contains("duplicate mountPath"));
    }

    #[test]
    fn extra_volume_config_rejects_reserved_mount_path_overlap() {
        let volumes = parse_extra_volumes_json(
            "CONTROL_PLANE_FAST_EXECUTION_EXTRA_VOLUMES_JSON",
            r#"[{"name":"cache","emptyDir":{}}]"#,
        )
        .unwrap();
        let mounts = parse_extra_volume_mounts_json(
            "CONTROL_PLANE_FAST_EXECUTION_EXTRA_VOLUME_MOUNTS_JSON",
            r#"[{"name":"cache","mountPath":"/root/.config/gh/hosts.yml"}]"#,
        )
        .unwrap();

        let error =
            validate_extra_volume_config(&volumes, &mounts, "/workspace", "/root", true, false)
                .unwrap_err();
        assert!(error.message.contains("must not overlap reserved path"));
    }
}
