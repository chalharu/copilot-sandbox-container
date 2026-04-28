use std::env;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tonic::metadata::{Ascii, MetadataValue};

use crate::paths::{canonicalize_absolute_path, host_path_for_logical, normalize_absolute_path};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ServerMode {
    Exec,
    PostToolUse,
}

impl ServerMode {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Exec => "exec",
            Self::PostToolUse => "post-tool-use",
        }
    }
}
#[derive(Clone, Debug)]
pub struct ServerConfig {
    pub port: u16,
    pub workspace_root: PathBuf,
    pub logical_workspace_root: PathBuf,
    pub chroot_root: Option<PathBuf>,
    pub environment_mount_path: Option<PathBuf>,
    pub git_hooks_source: Option<PathBuf>,
    pub remote_home: PathBuf,
    pub git_user_name: Option<String>,
    pub git_user_email: Option<String>,
    pub startup_script: Option<String>,
    pub mode: ServerMode,
    pub exec_api_token: String,
    pub exec_timeout: Duration,
    pub run_as_uid: u32,
    pub run_as_gid: u32,
}

#[derive(Debug)]
pub(crate) struct RawServerConfig<'a> {
    pub(crate) port: &'a str,
    pub(crate) workspace: &'a Path,
    pub(crate) chroot_root: Option<&'a Path>,
    pub(crate) environment_mount: Option<&'a Path>,
    pub(crate) git_hooks_source: Option<&'a Path>,
    pub(crate) remote_home: &'a Path,
    pub(crate) git_user_name: Option<String>,
    pub(crate) git_user_email: Option<String>,
    pub(crate) startup_script: Option<&'a str>,
    pub(crate) mode: &'a str,
    pub(crate) exec_api_token: String,
    pub(crate) timeout_sec: &'a str,
    pub(crate) run_as_uid: &'a str,
    pub(crate) run_as_gid: &'a str,
}

#[derive(Debug)]
struct ResolvedEnvironmentPaths {
    workspace_root: PathBuf,
    logical_workspace_root: PathBuf,
    chroot_root: Option<PathBuf>,
    environment_mount_path: Option<PathBuf>,
    git_hooks_source: Option<PathBuf>,
}
pub fn load_server_config_from_env() -> Result<ServerConfig, String> {
    let raw_port =
        env::var("CONTROL_PLANE_FAST_EXECUTION_PORT").unwrap_or_else(|_| String::from("8080"));
    let raw_workspace =
        env::var("CONTROL_PLANE_WORKSPACE").unwrap_or_else(|_| String::from("/workspace"));
    let raw_chroot_root = env::var("CONTROL_PLANE_FAST_EXECUTION_CHROOT_ROOT").ok();
    let raw_environment_mount =
        env::var("CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_MOUNT_PATH").ok();
    let raw_git_hooks_source = env::var("CONTROL_PLANE_FAST_EXECUTION_GIT_HOOKS_SOURCE").ok();
    let raw_remote_home =
        env::var("CONTROL_PLANE_FAST_EXECUTION_HOME").unwrap_or_else(|_| String::from("/root"));
    let git_user_name = env::var("CONTROL_PLANE_GIT_USER_NAME")
        .ok()
        .filter(|value| !value.trim().is_empty());
    let git_user_email = env::var("CONTROL_PLANE_GIT_USER_EMAIL")
        .ok()
        .filter(|value| !value.trim().is_empty());
    let raw_startup_script = env::var("CONTROL_PLANE_FAST_EXECUTION_STARTUP_SCRIPT").ok();
    let raw_mode = env::var("CONTROL_PLANE_EXEC_API_MODE").unwrap_or_else(|_| String::from("exec"));
    let exec_api_token = env::var("CONTROL_PLANE_EXEC_API_TOKEN")
        .map_err(|_| String::from("CONTROL_PLANE_EXEC_API_TOKEN is required"))?;
    let timeout_sec = env::var("CONTROL_PLANE_FAST_EXECUTION_REQUEST_TIMEOUT_SEC")
        .unwrap_or_else(|_| String::from("3600"));
    let run_as_uid = env::var("CONTROL_PLANE_FAST_EXECUTION_RUN_AS_UID")
        .unwrap_or_else(|_| String::from("1000"));
    let run_as_gid = env::var("CONTROL_PLANE_FAST_EXECUTION_RUN_AS_GID")
        .unwrap_or_else(|_| String::from("1000"));

    build_server_config(RawServerConfig {
        port: &raw_port,
        workspace: Path::new(&raw_workspace),
        chroot_root: raw_chroot_root.as_deref().map(Path::new),
        environment_mount: raw_environment_mount.as_deref().map(Path::new),
        git_hooks_source: raw_git_hooks_source.as_deref().map(Path::new),
        remote_home: Path::new(&raw_remote_home),
        git_user_name,
        git_user_email,
        startup_script: raw_startup_script.as_deref(),
        mode: &raw_mode,
        exec_api_token,
        timeout_sec: &timeout_sec,
        run_as_uid: &run_as_uid,
        run_as_gid: &run_as_gid,
    })
}

pub(crate) fn build_server_config(raw: RawServerConfig<'_>) -> Result<ServerConfig, String> {
    let port = parse_port(raw.port)?;
    let remote_home =
        normalize_absolute_path(raw.remote_home, "CONTROL_PLANE_FAST_EXECUTION_HOME")?;
    let paths = resolve_environment_paths(
        raw.workspace,
        raw.chroot_root,
        raw.environment_mount,
        raw.git_hooks_source,
    )?;
    let exec_timeout = Duration::from_secs(parse_positive_u64(
        raw.timeout_sec,
        "CONTROL_PLANE_FAST_EXECUTION_REQUEST_TIMEOUT_SEC",
    )?);
    let run_as_uid = parse_non_root_u32(raw.run_as_uid, "CONTROL_PLANE_FAST_EXECUTION_RUN_AS_UID")?;
    let run_as_gid = parse_non_root_u32(raw.run_as_gid, "CONTROL_PLANE_FAST_EXECUTION_RUN_AS_GID")?;
    let startup_script = raw
        .startup_script
        .filter(|value| !value.is_empty())
        .filter(|value| !value.trim().is_empty())
        .map(String::from);
    let mode = parse_server_mode(raw.mode)?;
    let exec_api_token = require_non_empty(raw.exec_api_token, "CONTROL_PLANE_EXEC_API_TOKEN")?;
    parse_exec_api_token(&exec_api_token)?;

    Ok(ServerConfig {
        port,
        workspace_root: paths.workspace_root,
        logical_workspace_root: paths.logical_workspace_root,
        chroot_root: paths.chroot_root,
        environment_mount_path: paths.environment_mount_path,
        git_hooks_source: paths.git_hooks_source,
        remote_home,
        git_user_name: raw.git_user_name,
        git_user_email: raw.git_user_email,
        startup_script,
        mode,
        exec_api_token,
        exec_timeout,
        run_as_uid,
        run_as_gid,
    })
}

fn resolve_environment_paths(
    raw_workspace: &Path,
    raw_chroot_root: Option<&Path>,
    raw_environment_mount: Option<&Path>,
    raw_git_hooks_source: Option<&Path>,
) -> Result<ResolvedEnvironmentPaths, String> {
    if let Some(raw_chroot_root) = raw_chroot_root {
        let logical_workspace_root =
            normalize_absolute_path(raw_workspace, "CONTROL_PLANE_WORKSPACE")?;
        let chroot_root =
            normalize_absolute_path(raw_chroot_root, "CONTROL_PLANE_FAST_EXECUTION_CHROOT_ROOT")?;
        let environment_mount_path = normalize_absolute_path(
            raw_environment_mount.unwrap_or_else(|| Path::new("/environment")),
            "CONTROL_PLANE_FAST_EXECUTION_ENVIRONMENT_MOUNT_PATH",
        )?;
        let git_hooks_source = raw_git_hooks_source
            .map(|path| {
                normalize_absolute_path(path, "CONTROL_PLANE_FAST_EXECUTION_GIT_HOOKS_SOURCE")
            })
            .transpose()?;
        let workspace_root = host_path_for_logical(&chroot_root, &logical_workspace_root)?;
        Ok(ResolvedEnvironmentPaths {
            workspace_root,
            logical_workspace_root,
            chroot_root: Some(chroot_root),
            environment_mount_path: Some(environment_mount_path),
            git_hooks_source,
        })
    } else {
        let workspace_root = canonicalize_absolute_path(raw_workspace, "CONTROL_PLANE_WORKSPACE")?;
        Ok(ResolvedEnvironmentPaths {
            workspace_root: workspace_root.clone(),
            logical_workspace_root: workspace_root,
            chroot_root: None,
            environment_mount_path: None,
            git_hooks_source: None,
        })
    }
}

fn parse_port(raw_port: &str) -> Result<u16, String> {
    let port = raw_port
        .parse::<u16>()
        .map_err(|_| format!("invalid CONTROL_PLANE_FAST_EXECUTION_PORT: {raw_port}"))?;
    if port == 0 {
        Err(format!(
            "invalid CONTROL_PLANE_FAST_EXECUTION_PORT: {raw_port}"
        ))
    } else {
        Ok(port)
    }
}

fn parse_positive_u64(raw_value: &str, variable_name: &str) -> Result<u64, String> {
    let value = raw_value
        .parse::<u64>()
        .map_err(|_| format!("{variable_name} must be a positive integer: {raw_value}"))?;
    if value == 0 {
        Err(format!(
            "{variable_name} must be a positive integer: {raw_value}"
        ))
    } else {
        Ok(value)
    }
}

fn parse_server_mode(raw_mode: &str) -> Result<ServerMode, String> {
    match raw_mode {
        "exec" => Ok(ServerMode::Exec),
        "post-tool-use" => Ok(ServerMode::PostToolUse),
        _ => Err(format!("invalid CONTROL_PLANE_EXEC_API_MODE: {raw_mode}")),
    }
}

fn parse_non_root_u32(raw_value: &str, variable_name: &str) -> Result<u32, String> {
    let value = raw_value
        .parse::<u32>()
        .map_err(|_| format!("{variable_name} must be a positive integer: {raw_value}"))?;
    if value == 0 {
        Err(format!(
            "{variable_name} must be greater than zero: {raw_value}"
        ))
    } else {
        Ok(value)
    }
}

fn require_non_empty(value: String, variable_name: &str) -> Result<String, String> {
    if value.trim().is_empty() {
        Err(format!("{variable_name} must not be empty"))
    } else {
        Ok(value)
    }
}

pub(crate) fn parse_exec_api_token(raw_token: &str) -> Result<MetadataValue<Ascii>, String> {
    MetadataValue::try_from(raw_token)
        .map_err(|_| String::from("CONTROL_PLANE_EXEC_API_TOKEN must be valid gRPC metadata"))
}

#[cfg(test)]
mod tests {
    use super::{RawServerConfig, build_server_config};
    use std::path::{Path, PathBuf};
    use tempfile::TempDir;

    #[test]
    fn rejects_empty_exec_api_token() {
        let workspace = TempDir::new().unwrap();
        let error = build_server_config(RawServerConfig {
            port: "8080",
            workspace: workspace.path(),
            chroot_root: None,
            environment_mount: None,
            git_hooks_source: None,
            remote_home: Path::new("/root"),
            git_user_name: None,
            git_user_email: None,
            startup_script: None,
            mode: "exec",
            exec_api_token: String::new(),
            timeout_sec: "3600",
            run_as_uid: "1000",
            run_as_gid: "1000",
        })
        .unwrap_err();
        assert_eq!(error, "CONTROL_PLANE_EXEC_API_TOKEN must not be empty");
    }

    #[test]
    fn chroot_config_derives_host_workspace_under_chroot_root() {
        let workspace = TempDir::new().unwrap();
        let config = build_server_config(RawServerConfig {
            port: "8080",
            workspace: Path::new("/workspace"),
            chroot_root: Some(&workspace.path().join("cache/root")),
            environment_mount: Some(Path::new("/environment")),
            git_hooks_source: Some(Path::new("/environment/cache/hooks/git")),
            remote_home: Path::new("/root"),
            git_user_name: Some(String::from("Copilot")),
            git_user_email: Some(String::from("copilot@example.com")),
            startup_script: Some("apt-get update && apt-get install -y ripgrep"),
            mode: "exec",
            exec_api_token: String::from("token"),
            timeout_sec: "3600",
            run_as_uid: "1000",
            run_as_gid: "1000",
        })
        .unwrap();
        assert_eq!(config.logical_workspace_root, PathBuf::from("/workspace"));
        assert_eq!(
            config.workspace_root,
            workspace.path().join("cache/root/workspace")
        );
        assert_eq!(
            config.chroot_root.as_deref(),
            Some(workspace.path().join("cache/root").as_path())
        );
        assert_eq!(
            config.startup_script.as_deref(),
            Some("apt-get update && apt-get install -y ripgrep")
        );
    }
}
