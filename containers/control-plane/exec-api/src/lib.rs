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
}

impl ExecApiService {
    fn new(workspace_root: PathBuf, exec_api_token: String) -> Self {
        Self {
            workspace_root,
            exec_api_token,
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
        let result = run_shell_command(&request.command, &cwd).await?;

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
    let port = raw_port
        .parse::<u16>()
        .map_err(|_| format!("invalid CONTROL_PLANE_FAST_EXECUTION_PORT: {raw_port}"))?;
    if port == 0 {
        return Err(format!(
            "invalid CONTROL_PLANE_FAST_EXECUTION_PORT: {raw_port}"
        ));
    }

    let raw_workspace =
        std::env::var("CONTROL_PLANE_WORKSPACE").unwrap_or_else(|_| String::from("/workspace"));
    let workspace_root = normalize_workspace_root(Path::new(&raw_workspace))?;
    let exec_api_token = std::env::var("CONTROL_PLANE_EXEC_API_TOKEN").unwrap_or_default();

    Ok(ServerConfig {
        port,
        workspace_root,
        exec_api_token,
    })
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
    let service = ExecApiService::new(config.workspace_root.clone(), config.exec_api_token.clone());
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

    Ok(normalize_path(&absolute_workspace))
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

    if target == workspace_root || target.starts_with(workspace_root) {
        Ok(target)
    } else {
        Err(format!(
            "cwd must stay within {}: {}",
            workspace_root.display(),
            target.display()
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

async fn run_shell_command(command: &str, cwd: &Path) -> Result<ExecResult, Status> {
    let shell = resolve_shell().ok_or_else(|| {
        Status::failed_precondition("no supported shell found (tried bash and sh variants)")
    })?;
    let output = Command::new(shell)
        .arg("-lc")
        .arg(command)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await
        .map_err(|error| Status::new(Code::Internal, error.to_string()))?;

    Ok(ExecResult {
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        exit_code: exit_code_from_status(output.status),
    })
}

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
    use super::{normalize_cwd, normalize_path};
    use std::path::{Path, PathBuf};

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
}
