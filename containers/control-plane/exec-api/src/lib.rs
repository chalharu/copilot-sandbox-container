use serde::{Deserialize, Serialize};
use std::env;
use std::future::Future;
use std::path::{Component, Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::net::TcpListener;
use tokio::process::Command;
use tokio_stream::wrappers::TcpListenerStream;
use tonic::metadata::MetadataValue;
use tonic::transport::{Channel, Endpoint, Server};
use tonic::{Code, Request, Response, Status};
use tonic_health::ServingStatus;
use tonic_health::pb::health_client::HealthClient;

pub mod proto {
    tonic::include_proto!("controlplane.exec.v1");
}

const HEALTH_SERVICE_NAME: &str = "";
const EXEC_API_TOKEN_METADATA_KEY: &str = "x-control-plane-exec-token";

pub type DynError = Box<dyn std::error::Error + Send + Sync>;

#[derive(Clone, Debug)]
pub struct ServerConfig {
    pub port: u16,
    pub workspace_root: PathBuf,
    pub exec_api_token: String,
    pub exec_timeout: Duration,
    pub run_as_uid: u32,
    pub run_as_gid: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExecResult {
    pub stdout: String,
    pub stderr: String,
    #[serde(rename = "exitCode")]
    pub exit_code: i32,
}

#[derive(Clone, Debug)]
struct ExecApiService {
    workspace_root: PathBuf,
    exec_api_token: String,
    exec_timeout: Duration,
    run_as_uid: u32,
    run_as_gid: u32,
}

impl ExecApiService {
    fn new(config: &ServerConfig) -> Self {
        Self {
            workspace_root: config.workspace_root.clone(),
            exec_api_token: config.exec_api_token.clone(),
            exec_timeout: config.exec_timeout,
            run_as_uid: config.run_as_uid,
            run_as_gid: config.run_as_gid,
        }
    }
}

#[tonic::async_trait]
impl proto::exec_service_server::ExecService for ExecApiService {
    async fn execute(
        &self,
        request: Request<proto::ExecuteRequest>,
    ) -> Result<Response<proto::ExecuteResponse>, Status> {
        if !self.exec_api_token.is_empty() {
            let Some(token) = request.metadata().get(EXEC_API_TOKEN_METADATA_KEY) else {
                return Err(Status::permission_denied(
                    "missing or invalid exec API token",
                ));
            };
            let expected = MetadataValue::try_from(self.exec_api_token.as_str()).map_err(|_| {
                Status::internal("execution API token could not be encoded as gRPC metadata")
            })?;
            if token != expected {
                return Err(Status::permission_denied(
                    "missing or invalid exec API token",
                ));
            }
        }

        let request = request.into_inner();
        if request.command.is_empty() {
            return Err(Status::invalid_argument(
                "command must be a non-empty string",
            ));
        }

        let cwd =
            normalize_cwd(&self.workspace_root, &request.cwd).map_err(Status::invalid_argument)?;
        let result = run_shell_command(
            &request.command,
            &cwd,
            self.exec_timeout,
            self.run_as_uid,
            self.run_as_gid,
        )
        .await?;

        Ok(Response::new(proto::ExecuteResponse {
            stdout: result.stdout,
            stderr: result.stderr,
            exit_code: result.exit_code,
        }))
    }
}

pub fn load_server_config_from_env() -> Result<ServerConfig, String> {
    let raw_port =
        std::env::var("CONTROL_PLANE_FAST_EXECUTION_PORT").unwrap_or_else(|_| String::from("8080"));
    let raw_workspace =
        std::env::var("CONTROL_PLANE_WORKSPACE").unwrap_or_else(|_| String::from("/workspace"));
    let exec_api_token = std::env::var("CONTROL_PLANE_EXEC_API_TOKEN")
        .map_err(|_| String::from("CONTROL_PLANE_EXEC_API_TOKEN is required"))?;
    let timeout_sec = std::env::var("CONTROL_PLANE_FAST_EXECUTION_REQUEST_TIMEOUT_SEC")
        .unwrap_or_else(|_| String::from("3600"));
    let run_as_uid = std::env::var("CONTROL_PLANE_FAST_EXECUTION_RUN_AS_UID")
        .unwrap_or_else(|_| String::from("1000"));
    let run_as_gid = std::env::var("CONTROL_PLANE_FAST_EXECUTION_RUN_AS_GID")
        .unwrap_or_else(|_| String::from("1000"));
    build_server_config(
        &raw_port,
        Path::new(&raw_workspace),
        exec_api_token,
        &timeout_sec,
        &run_as_uid,
        &run_as_gid,
    )
}

fn build_server_config(
    raw_port: &str,
    raw_workspace: &Path,
    exec_api_token: String,
    timeout_sec: &str,
    run_as_uid: &str,
    run_as_gid: &str,
) -> Result<ServerConfig, String> {
    let port = parse_port(raw_port)?;
    let workspace_root = normalize_workspace_root(raw_workspace)?;
    let exec_timeout = Duration::from_secs(parse_positive_u64(
        timeout_sec,
        "CONTROL_PLANE_FAST_EXECUTION_REQUEST_TIMEOUT_SEC",
    )?);
    let run_as_uid = parse_non_root_u32(run_as_uid, "CONTROL_PLANE_FAST_EXECUTION_RUN_AS_UID")?;
    let run_as_gid = parse_non_root_u32(run_as_gid, "CONTROL_PLANE_FAST_EXECUTION_RUN_AS_GID")?;
    let exec_api_token = require_non_empty(exec_api_token, "CONTROL_PLANE_EXEC_API_TOKEN")?;

    Ok(ServerConfig {
        port,
        workspace_root,
        exec_api_token,
        exec_timeout,
        run_as_uid,
        run_as_gid,
    })
}

fn parse_port(raw_port: &str) -> Result<u16, String> {
    let port = raw_port
        .parse::<u16>()
        .map_err(|_| format!("invalid CONTROL_PLANE_FAST_EXECUTION_PORT: {raw_port}"))?;
    if port == 0 {
        return Err(format!(
            "invalid CONTROL_PLANE_FAST_EXECUTION_PORT: {raw_port}"
        ));
    }
    Ok(port)
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

pub async fn serve_with_listener<F>(
    listener: TcpListener,
    config: ServerConfig,
    shutdown: F,
) -> Result<(), DynError>
where
    F: Future<Output = ()> + Send + 'static,
{
    let local_addr = listener.local_addr()?;
    let service = ExecApiService::new(&config);
    let (mut health_reporter, health_service) = tonic_health::server::health_reporter();
    health_reporter
        .set_service_status(HEALTH_SERVICE_NAME, ServingStatus::Serving)
        .await;
    health_reporter
        .set_serving::<proto::exec_service_server::ExecServiceServer<ExecApiService>>()
        .await;

    eprintln!(
        "control-plane-exec-api: listening on {} for {}",
        local_addr,
        config.workspace_root.display()
    );

    Server::builder()
        .add_service(health_service)
        .add_service(proto::exec_service_server::ExecServiceServer::new(service))
        .serve_with_incoming_shutdown(TcpListenerStream::new(listener), shutdown)
        .await?;

    Ok(())
}

pub async fn serve(config: ServerConfig) -> Result<(), DynError> {
    let listener = TcpListener::bind(("0.0.0.0", config.port)).await?;
    serve_with_listener(listener, config, async {
        let _ = tokio::signal::ctrl_c().await;
    })
    .await
}

pub async fn check_health(addr: &str, timeout: Duration) -> Result<(), DynError> {
    let channel = connect(addr, timeout).await?;
    let mut client = HealthClient::new(channel);
    client
        .check(tonic_health::pb::HealthCheckRequest {
            service: String::from(HEALTH_SERVICE_NAME),
        })
        .await?;
    Ok(())
}

pub async fn execute_remote(
    addr: &str,
    timeout: Duration,
    token: &str,
    cwd: &str,
    command: &str,
) -> Result<ExecResult, DynError> {
    let channel = connect(addr, timeout).await?;
    let mut client = proto::exec_service_client::ExecServiceClient::new(channel);
    let mut request = Request::new(proto::ExecuteRequest {
        command: command.to_owned(),
        cwd: cwd.to_owned(),
    });
    if !token.is_empty() {
        request.metadata_mut().insert(
            EXEC_API_TOKEN_METADATA_KEY,
            MetadataValue::try_from(token).map_err(|error| {
                format!("failed to encode execution API token as metadata: {error}")
            })?,
        );
    }

    let response = client.execute(request).await?.into_inner();
    Ok(ExecResult {
        stdout: response.stdout,
        stderr: response.stderr,
        exit_code: response.exit_code,
    })
}

fn normalize_workspace_root(raw_workspace: &Path) -> Result<PathBuf, String> {
    let absolute_workspace = if raw_workspace.is_absolute() {
        raw_workspace.to_path_buf()
    } else {
        std::env::current_dir()
            .map_err(|error| format!("failed to determine current directory: {error}"))?
            .join(raw_workspace)
    };

    std::fs::canonicalize(&absolute_workspace).map_err(|error| {
        format!(
            "failed to resolve CONTROL_PLANE_WORKSPACE {}: {error}",
            absolute_workspace.display()
        )
    })
}

fn normalize_cwd(workspace_root: &Path, raw_cwd: &str) -> Result<PathBuf, String> {
    let target = if raw_cwd.trim().is_empty() {
        workspace_root.to_path_buf()
    } else {
        let raw_path = Path::new(raw_cwd);
        if raw_path.is_absolute() {
            normalize_path(raw_path)
        } else {
            normalize_path(&workspace_root.join(raw_path))
        }
    };

    let resolved_target = std::fs::canonicalize(&target)
        .map_err(|error| format!("failed to resolve cwd {}: {error}", target.display()))?;
    if resolved_target == workspace_root || resolved_target.starts_with(workspace_root) {
        Ok(resolved_target)
    } else {
        Err(format!(
            "cwd must stay within {}: {}",
            workspace_root.display(),
            resolved_target.display()
        ))
    }
}

fn normalize_path(path: &Path) -> PathBuf {
    let mut parts = Vec::new();
    let mut absolute = false;

    for component in path.components() {
        match component {
            Component::RootDir => {
                absolute = true;
                parts.clear();
            }
            Component::CurDir => {}
            Component::ParentDir => {
                if !parts.is_empty() {
                    parts.pop();
                }
            }
            Component::Normal(segment) => parts.push(segment.to_os_string()),
            Component::Prefix(prefix) => {
                absolute = true;
                parts.clear();
                parts.push(prefix.as_os_str().to_os_string());
            }
        }
    }

    let mut normalized = if absolute {
        PathBuf::from("/")
    } else {
        PathBuf::new()
    };
    for part in parts {
        normalized.push(part);
    }
    if normalized.as_os_str().is_empty() {
        PathBuf::from(".")
    } else {
        normalized
    }
}

async fn connect(addr: &str, timeout: Duration) -> Result<Channel, DynError> {
    Ok(Endpoint::from_shared(addr.to_owned())?
        .timeout(timeout)
        .connect()
        .await?)
}

fn resolve_shell() -> Option<PathBuf> {
    for candidate in ["bash", "/bin/bash", "sh", "/bin/sh"] {
        if let Some(path) = resolve_shell_candidate(candidate) {
            return Some(path);
        }
    }
    None
}

fn resolve_shell_candidate(candidate: &str) -> Option<PathBuf> {
    let candidate_path = Path::new(candidate);
    if candidate_path.is_absolute() {
        return candidate_path
            .is_file()
            .then(|| candidate_path.to_path_buf());
    }

    let path_env = env::var_os("PATH")?;
    env::split_paths(&path_env)
        .map(|segment| segment.join(candidate))
        .find(|path| path.is_file())
}

async fn run_shell_command(
    command: &str,
    cwd: &Path,
    exec_timeout: Duration,
    run_as_uid: u32,
    run_as_gid: u32,
) -> Result<ExecResult, Status> {
    let shell = resolve_shell().ok_or_else(|| {
        Status::failed_precondition("no supported shell found (tried bash and sh variants)")
    })?;
    let mut process = Command::new(shell);
    process
        .arg("-lc")
        .arg(command)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    process.kill_on_drop(true);
    configure_command_identity(&mut process, run_as_uid, run_as_gid);
    let output = tokio::time::timeout(exec_timeout, process.output())
        .await
        .map_err(|_| {
            Status::deadline_exceeded(format!(
                "command exceeded execution timeout of {} seconds",
                exec_timeout.as_secs()
            ))
        })?
        .map_err(|error| Status::new(Code::Internal, error.to_string()))?;

    Ok(ExecResult {
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        exit_code: exit_code_from_status(output.status),
    })
}

#[cfg(unix)]
fn configure_command_identity(process: &mut Command, run_as_uid: u32, run_as_gid: u32) {
    process.uid(run_as_uid);
    process.gid(run_as_gid);
}

#[cfg(not(unix))]
fn configure_command_identity(_process: &mut Command, _run_as_uid: u32, _run_as_gid: u32) {}

#[cfg(unix)]
fn exit_code_from_status(status: std::process::ExitStatus) -> i32 {
    use std::os::unix::process::ExitStatusExt;

    status
        .code()
        .or_else(|| status.signal().map(|signal| 128 + signal))
        .unwrap_or(1)
}

#[cfg(not(unix))]
fn exit_code_from_status(status: std::process::ExitStatus) -> i32 {
    status.code().unwrap_or(1)
}

#[cfg(test)]
mod tests {
    use super::{build_server_config, normalize_cwd, normalize_path};
    use std::path::{Path, PathBuf};
    use tempfile::TempDir;

    #[test]
    fn normalize_path_removes_dot_segments() {
        assert_eq!(
            normalize_path(Path::new("/workspace/./nested/../repo")),
            PathBuf::from("/workspace/repo")
        );
    }

    #[test]
    fn normalize_cwd_rejects_paths_outside_workspace() {
        let error = normalize_cwd(Path::new("/workspace"), "/workspace/../tmp")
            .expect_err("path should be rejected");
        assert_eq!(error, "cwd must stay within /workspace: /tmp");
    }

    #[test]
    fn rejects_empty_exec_api_token() {
        let workspace = TempDir::new().unwrap();
        let error = build_server_config(
            "8080",
            workspace.path(),
            String::new(),
            "3600",
            "1000",
            "1000",
        )
        .unwrap_err();
        assert_eq!(error, "CONTROL_PLANE_EXEC_API_TOKEN must not be empty");
    }

    #[cfg(unix)]
    #[test]
    fn normalize_cwd_rejects_symlink_escapes() {
        use std::os::unix::fs::symlink;

        let temp_dir = TempDir::new().unwrap();
        let workspace = temp_dir.path().join("workspace");
        let outside = temp_dir.path().join("outside");
        std::fs::create_dir_all(&workspace).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        symlink(&outside, workspace.join("escape")).unwrap();
        let workspace = std::fs::canonicalize(&workspace).unwrap();

        let error =
            normalize_cwd(&workspace, workspace.join("escape").to_str().unwrap()).unwrap_err();
        assert_eq!(
            error,
            format!(
                "cwd must stay within {}: {}",
                workspace.display(),
                outside.display()
            )
        );
    }
}
