use nix::mount::{MsFlags, mount};
use nix::unistd::{Gid, Uid, chdir, chown, chroot, setgid, setuid};
use serde::{Deserialize, Serialize};
use std::env;
use std::ffi::{CString, OsString};
use std::fs;
use std::future::Future;
use std::io::{self, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Component, Path, PathBuf};
use std::process::{Command as StdCommand, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::io::AsyncWriteExt;
use tokio::net::TcpListener;
use tokio::process::Command as TokioCommand;
use tokio_stream::wrappers::TcpListenerStream;
use tonic::metadata::{Ascii, MetadataValue};
use tonic::transport::{Channel, Endpoint, Server};
use tonic::{Code, Request, Response, Status};
use tonic_health::ServingStatus;
use tonic_health::pb::health_client::HealthClient;

pub mod proto {
    tonic::include_proto!("controlplane.exec.v1");
}

const HEALTH_SERVICE_NAME: &str = "";
const EXEC_API_TOKEN_METADATA_KEY: &str = "x-control-plane-exec-token";
const DEFAULT_EXEC_PATH: &str = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
const KUBERNETES_SERVICE_ACCOUNT_DIR: &str = "/var/run/secrets/kubernetes.io/serviceaccount";
const CHROOT_KUBERNETES_SERVICE_ACCOUNT_DIR: &str = "/run/secrets/kubernetes.io/serviceaccount";
const CHROOT_COPILOT_HOOKS_DIR: &str = "/usr/local/share/control-plane/hooks";
const CHROOT_GIT_HOOKS_DIR: &str = "/usr/local/share/control-plane/hooks/git";
const CHROOT_POST_TOOL_USE_HOOKS_PATH: &str = "/usr/local/share/control-plane/hooks/postToolUse";
const CHROOT_EXEC_POLICY_LIBRARY_PATH: &str = "/usr/local/lib/libcontrol_plane_exec_policy.so";
const CHROOT_EXEC_POLICY_RULES_PATH: &str =
    "/usr/local/share/control-plane/hooks/preToolUse/deny-rules.yaml";
const CHROOT_RUNTIME_TOOL_PATH: &str = "/usr/local/bin/control-plane-runtime-tool";
const CHROOT_KUBECTL_PATH: &str = "/usr/local/bin/kubectl";
const REMOTE_CARGO_TARGET_DIR: &str = "/var/tmp/control-plane/cargo-target";

pub type DynError = Box<dyn std::error::Error + Send + Sync>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ServerMode {
    Exec,
    PostToolUse,
}

impl ServerMode {
    fn as_str(self) -> &'static str {
        match self {
            Self::Exec => "exec",
            Self::PostToolUse => "post-tool-use",
        }
    }
}

fn with_context<T, E>(result: Result<T, E>, context: impl FnOnce() -> String) -> Result<T, DynError>
where
    E: std::fmt::Display,
{
    result.map_err(|error| format!("{}: {error}", context()).into())
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
struct RawServerConfig<'a> {
    port: &'a str,
    workspace: &'a Path,
    chroot_root: Option<&'a Path>,
    environment_mount: Option<&'a Path>,
    git_hooks_source: Option<&'a Path>,
    remote_home: &'a Path,
    git_user_name: Option<String>,
    git_user_email: Option<String>,
    startup_script: Option<&'a str>,
    mode: &'a str,
    exec_api_token: String,
    timeout_sec: &'a str,
    run_as_uid: &'a str,
    run_as_gid: &'a str,
}

#[derive(Debug)]
struct ResolvedEnvironmentPaths {
    workspace_root: PathBuf,
    logical_workspace_root: PathBuf,
    chroot_root: Option<PathBuf>,
    environment_mount_path: Option<PathBuf>,
    git_hooks_source: Option<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExecResult {
    pub stdout: String,
    pub stderr: String,
    #[serde(rename = "exitCode")]
    pub exit_code: i32,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct ExecuteRequestLog<'a> {
    timestamp: u64,
    event: &'static str,
    request_id: u64,
    mode: &'static str,
    cwd: &'a str,
    command: &'a str,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct ExecuteResponseLog<'a> {
    timestamp: u64,
    event: &'static str,
    request_id: u64,
    status: &'static str,
    mode: &'static str,
    cwd: &'a str,
    command: &'a str,
    exit_code: Option<i32>,
    stdout: Option<&'a str>,
    stderr: Option<&'a str>,
    grpc_code: Option<&'a str>,
    error: Option<&'a str>,
}

trait TrafficLogger: Send + Sync + std::fmt::Debug {
    fn log_line(&self, line: &str) -> Result<(), String>;
}

fn current_timestamp_ms() -> u64 {
    let elapsed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX)
}

fn format_log_line(timestamp_ms: u64, message: &str) -> String {
    format!("{timestamp_ms} control-plane-exec-api: {message}")
}

pub fn log_message(message: &str) {
    eprintln!("{}", format_log_line(current_timestamp_ms(), message));
}

#[derive(Debug, Default)]
struct StdoutTrafficLogger;

impl TrafficLogger for StdoutTrafficLogger {
    fn log_line(&self, line: &str) -> Result<(), String> {
        let stdout = io::stdout();
        let mut lock = stdout.lock();
        lock.write_all(line.as_bytes())
            .map_err(|error| format!("failed to write exec API traffic log: {error}"))?;
        lock.write_all(b"\n")
            .map_err(|error| format!("failed to write exec API traffic log newline: {error}"))?;
        lock.flush()
            .map_err(|error| format!("failed to flush exec API traffic log: {error}"))?;
        Ok(())
    }
}

#[derive(Clone, Debug)]
struct ExecApiService {
    workspace_root: PathBuf,
    logical_workspace_root: PathBuf,
    chroot_root: Option<PathBuf>,
    remote_home: PathBuf,
    mode: ServerMode,
    expected_exec_api_token: MetadataValue<Ascii>,
    exec_timeout: Duration,
    run_as_uid: u32,
    run_as_gid: u32,
    traffic_logger: Arc<dyn TrafficLogger>,
    request_id_counter: Arc<AtomicU64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ResolvedCwd {
    host: PathBuf,
    logical: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct RemoteHomePaths {
    home_dir: PathBuf,
    cargo_home_dir: PathBuf,
    cargo_config_path: PathBuf,
    config_dir: PathBuf,
    copilot_dir: PathBuf,
    copilot_hooks_path: PathBuf,
    gitconfig_path: PathBuf,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TokenValidationError {
    MissingOrInvalid,
}

impl From<TokenValidationError> for Status {
    fn from(_: TokenValidationError) -> Self {
        Status::permission_denied("missing or invalid exec API token")
    }
}

impl ExecApiService {
    fn new(config: &ServerConfig) -> Self {
        Self::new_with_traffic_logger(config, Arc::new(StdoutTrafficLogger))
    }

    fn new_with_traffic_logger(
        config: &ServerConfig,
        traffic_logger: Arc<dyn TrafficLogger>,
    ) -> Self {
        Self {
            workspace_root: config.workspace_root.clone(),
            logical_workspace_root: config.logical_workspace_root.clone(),
            chroot_root: config.chroot_root.clone(),
            remote_home: config.remote_home.clone(),
            mode: config.mode,
            expected_exec_api_token: parse_exec_api_token(&config.exec_api_token)
                .expect("CONTROL_PLANE_EXEC_API_TOKEN should be validated before serving"),
            exec_timeout: config.exec_timeout,
            run_as_uid: config.run_as_uid,
            run_as_gid: config.run_as_gid,
            traffic_logger,
            request_id_counter: Arc::new(AtomicU64::new(1)),
        }
    }

    fn next_request_id(&self) -> u64 {
        self.request_id_counter.fetch_add(1, Ordering::Relaxed)
    }

    fn log_request(&self, request_id: u64, request: &proto::ExecuteRequest) {
        self.log_traffic(&ExecuteRequestLog {
            timestamp: current_timestamp_ms(),
            event: "executeRequest",
            request_id,
            mode: self.mode.as_str(),
            cwd: &request.cwd,
            command: &request.command,
        });
    }

    fn log_success_response(
        &self,
        request_id: u64,
        request: &proto::ExecuteRequest,
        result: &ExecResult,
    ) {
        self.log_traffic(&ExecuteResponseLog {
            timestamp: current_timestamp_ms(),
            event: "executeResponse",
            request_id,
            status: "ok",
            mode: self.mode.as_str(),
            cwd: &request.cwd,
            command: &request.command,
            exit_code: Some(result.exit_code),
            stdout: Some(&result.stdout),
            stderr: Some(&result.stderr),
            grpc_code: None,
            error: None,
        });
    }

    fn log_error_response(
        &self,
        request_id: u64,
        request: &proto::ExecuteRequest,
        status: &Status,
    ) {
        let grpc_code = format!("{:?}", status.code());
        self.log_traffic(&ExecuteResponseLog {
            timestamp: current_timestamp_ms(),
            event: "executeResponse",
            request_id,
            status: "error",
            mode: self.mode.as_str(),
            cwd: &request.cwd,
            command: &request.command,
            exit_code: None,
            stdout: None,
            stderr: None,
            grpc_code: Some(grpc_code.as_str()),
            error: Some(status.message()),
        });
    }

    fn log_traffic<T: Serialize>(&self, value: &T) {
        let line = match serde_json::to_string(value) {
            Ok(line) => line,
            Err(error) => {
                log_message(&format!("failed to serialize stdout traffic log: {error}"));
                return;
            }
        };
        if let Err(error) = self.traffic_logger.log_line(&line) {
            log_message(&error);
        }
    }

    async fn execute_request(&self, request: &proto::ExecuteRequest) -> Result<ExecResult, Status> {
        if request.command.is_empty() {
            return Err(Status::invalid_argument(
                "command must be a non-empty string",
            ));
        }

        let cwd = resolve_cwd(
            &self.workspace_root,
            &self.logical_workspace_root,
            &request.cwd,
        )
        .map_err(Status::invalid_argument)?;
        match self.mode {
            ServerMode::Exec => {
                run_shell_command(
                    &request.command,
                    &cwd,
                    self.exec_timeout,
                    self.run_as_uid,
                    self.run_as_gid,
                    self.chroot_root.as_deref(),
                    &self.remote_home,
                )
                .await
            }
            ServerMode::PostToolUse => {
                run_post_tool_use_hook(
                    &request.command,
                    &cwd,
                    self.exec_timeout,
                    self.run_as_uid,
                    self.run_as_gid,
                    self.chroot_root.as_deref(),
                    &self.remote_home,
                )
                .await
            }
        }
    }
}

#[tonic::async_trait]
impl proto::exec_service_server::ExecService for ExecApiService {
    async fn execute(
        &self,
        request: Request<proto::ExecuteRequest>,
    ) -> Result<Response<proto::ExecuteResponse>, Status> {
        if let Err(error) = validate_token(request.metadata(), &self.expected_exec_api_token) {
            return Err(Status::from(error));
        }

        let request_id = self.next_request_id();
        self.log_request(request_id, request.get_ref());
        let request = request.into_inner();
        match self.execute_request(&request).await {
            Ok(result) => {
                self.log_success_response(request_id, &request, &result);
                Ok(Response::new(proto::ExecuteResponse {
                    stdout: result.stdout,
                    stderr: result.stderr,
                    exit_code: result.exit_code,
                }))
            }
            Err(status) => {
                self.log_error_response(request_id, &request, &status);
                Err(status)
            }
        }
    }
}

fn validate_token(
    metadata: &tonic::metadata::MetadataMap,
    expected_exec_api_token: &MetadataValue<Ascii>,
) -> Result<(), TokenValidationError> {
    let Some(token) = metadata.get(EXEC_API_TOKEN_METADATA_KEY) else {
        return Err(TokenValidationError::MissingOrInvalid);
    };
    if token == expected_exec_api_token {
        Ok(())
    } else {
        Err(TokenValidationError::MissingOrInvalid)
    }
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

fn build_server_config(raw: RawServerConfig<'_>) -> Result<ServerConfig, String> {
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

fn parse_exec_api_token(raw_token: &str) -> Result<MetadataValue<Ascii>, String> {
    MetadataValue::try_from(raw_token)
        .map_err(|_| String::from("CONTROL_PLANE_EXEC_API_TOKEN must be valid gRPC metadata"))
}

pub async fn serve_with_listener<F>(
    listener: TcpListener,
    config: ServerConfig,
    shutdown: F,
) -> Result<(), DynError>
where
    F: Future<Output = ()> + Send + 'static,
{
    prepare_server_environment(&config)?;

    let local_addr = listener.local_addr()?;
    let service = ExecApiService::new(&config);
    let (health_reporter, health_service) = tonic_health::server::health_reporter();
    health_reporter
        .set_service_status(HEALTH_SERVICE_NAME, ServingStatus::Serving)
        .await;
    health_reporter
        .set_serving::<proto::exec_service_server::ExecServiceServer<ExecApiService>>()
        .await;

    log_message(&format!(
        "listening on {} for {}",
        local_addr,
        config.logical_workspace_root.display()
    ));

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

fn prepare_server_environment(config: &ServerConfig) -> Result<(), DynError> {
    let Some(chroot_root) = config.chroot_root.as_deref() else {
        return Ok(());
    };

    with_context(fs::create_dir_all(chroot_root), || {
        format!("failed to create chroot root {}", chroot_root.display())
    })?;
    let needs_bootstrap = !bootstrap_marker_path(chroot_root).is_file();
    if needs_bootstrap {
        seed_chroot_root(chroot_root, config)?;
    }
    ensure_runtime_dirs(chroot_root, &config.remote_home).map_err(|error| {
        format!(
            "failed to prepare runtime directories under {}: {error}",
            chroot_root.display()
        )
    })?;
    mount_runtime_filesystems(chroot_root).map_err(|error| {
        format!(
            "failed to mount runtime filesystems under {}: {error}",
            chroot_root.display()
        )
    })?;
    if needs_bootstrap {
        install_required_packages(chroot_root).map_err(|error| {
            format!(
                "failed to install required packages in {}: {error}",
                chroot_root.display()
            )
        })?;
    }
    sync_git_hooks_into_chroot(config).map_err(|error| {
        format!(
            "failed to sync git hooks into {}: {error}",
            chroot_root.display()
        )
    })?;
    sync_remote_home_config(config).map_err(|error| {
        format!(
            "failed to sync remote home config into {}: {error}",
            chroot_root.display()
        )
    })?;
    if let Some(startup_script) = config.startup_script.as_deref() {
        run_startup_script(chroot_root, startup_script).map_err(|error| {
            format!(
                "failed to run startup script in {}: {error}",
                chroot_root.display()
            )
        })?;
    }
    if needs_bootstrap {
        let marker_path = bootstrap_marker_path(chroot_root);
        with_context(fs::write(&marker_path, b"ready\n"), || {
            format!("failed to write bootstrap marker {}", marker_path.display())
        })?;
    }
    Ok(())
}

fn bootstrap_marker_path(chroot_root: &Path) -> PathBuf {
    chroot_root.join(".control-plane-ready")
}

fn seed_chroot_root(chroot_root: &Path, config: &ServerConfig) -> Result<(), DynError> {
    with_context(fs::create_dir_all(chroot_root), || {
        format!("failed to create bootstrap root {}", chroot_root.display())
    })?;
    reset_incomplete_bootstrap_root(chroot_root, config).map_err(|error| {
        format!(
            "failed to reset incomplete execution rootfs under {}: {error}",
            chroot_root.display()
        )
    })?;
    copy_rootfs(chroot_root, config).map_err(|error| {
        format!(
            "failed to seed execution rootfs into {}: {error}",
            chroot_root.display()
        )
    })?;
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum BootstrapResetAction {
    Remove,
    ClearContents,
    KeepSubtree,
    Descend,
}

fn reset_incomplete_bootstrap_root(
    chroot_root: &Path,
    config: &ServerConfig,
) -> Result<(), DynError> {
    let preserve_subtrees = preserved_bootstrap_subtrees(config)
        .into_iter()
        .map(|path| strip_leading_slash(&path))
        .collect::<Vec<_>>();
    let clear_dirs = [PathBuf::from("tmp"), PathBuf::from("var/tmp")];
    reset_bootstrap_directory(chroot_root, Path::new(""), &preserve_subtrees, &clear_dirs)
}

fn preserved_bootstrap_subtrees(config: &ServerConfig) -> Vec<PathBuf> {
    vec![
        config.logical_workspace_root.clone(),
        config.remote_home.join(".config/gh"),
        config.remote_home.join(".ssh"),
        PathBuf::from(CHROOT_KUBECTL_PATH),
        PathBuf::from(CHROOT_RUNTIME_TOOL_PATH),
        PathBuf::from(CHROOT_EXEC_POLICY_LIBRARY_PATH),
        PathBuf::from(CHROOT_EXEC_POLICY_RULES_PATH),
        PathBuf::from(CHROOT_POST_TOOL_USE_HOOKS_PATH),
    ]
}

fn reset_bootstrap_directory(
    path: &Path,
    relative_path: &Path,
    preserve_subtrees: &[PathBuf],
    clear_dirs: &[PathBuf],
) -> Result<(), DynError> {
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let entry_name = entry.file_name();
        let entry_relative = if relative_path.as_os_str().is_empty() {
            PathBuf::from(entry_name)
        } else {
            relative_path.join(entry_name)
        };
        let file_type = entry.file_type()?;
        match bootstrap_reset_action(&entry_relative, preserve_subtrees, clear_dirs) {
            BootstrapResetAction::KeepSubtree => {}
            BootstrapResetAction::ClearContents => {
                if !file_type.is_dir() {
                    return Err(io::Error::other(format!(
                        "expected resettable bootstrap directory at {}",
                        entry.path().display()
                    ))
                    .into());
                }
                clear_directory_contents(&entry.path())?;
            }
            BootstrapResetAction::Descend => {
                if !file_type.is_dir() {
                    return Err(io::Error::other(format!(
                        "expected bootstrap path ancestor to be a directory: {}",
                        entry.path().display()
                    ))
                    .into());
                }
                reset_bootstrap_directory(
                    &entry.path(),
                    &entry_relative,
                    preserve_subtrees,
                    clear_dirs,
                )?;
            }
            BootstrapResetAction::Remove => remove_path(&entry.path(), file_type)?,
        }
    }
    Ok(())
}

fn clear_directory_contents(path: &Path) -> Result<(), DynError> {
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        remove_path(&entry.path(), entry.file_type()?)?;
    }
    Ok(())
}

fn remove_path(path: &Path, file_type: fs::FileType) -> io::Result<()> {
    if file_type.is_dir() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    }
}

fn bootstrap_reset_action(
    relative_path: &Path,
    preserve_subtrees: &[PathBuf],
    clear_dirs: &[PathBuf],
) -> BootstrapResetAction {
    if preserve_subtrees.iter().any(|path| path == relative_path) {
        return BootstrapResetAction::KeepSubtree;
    }
    if clear_dirs.iter().any(|path| path == relative_path) {
        return BootstrapResetAction::ClearContents;
    }
    if preserve_subtrees
        .iter()
        .chain(clear_dirs.iter())
        .any(|path| path.starts_with(relative_path))
    {
        return BootstrapResetAction::Descend;
    }
    BootstrapResetAction::Remove
}

fn copy_rootfs(chroot_root: &Path, config: &ServerConfig) -> Result<(), DynError> {
    let mut archive = StdCommand::new("tar");
    archive.current_dir("/");
    archive.arg("cf").arg("-");
    for path in excluded_rootfs_paths(config) {
        archive.arg(format!(
            "--exclude=./{}",
            strip_leading_slash(path).display()
        ));
    }
    for entry in rootfs_archive_paths()? {
        archive.arg(entry);
    }
    archive.stdout(Stdio::piped());

    let mut archive_child = with_context(archive.spawn(), || {
        String::from("failed to start tar archive process")
    })?;
    let archive_stdout = archive_child
        .stdout
        .take()
        .ok_or_else(|| io::Error::other("missing tar stdout"))?;
    let extract_status = with_context(
        build_rootfs_extract_command(chroot_root)
            .stdin(Stdio::from(archive_stdout))
            .status(),
        || {
            format!(
                "failed to extract execution image rootfs into {}",
                chroot_root.display()
            )
        },
    )?;
    let archive_status = with_context(archive_child.wait(), || {
        String::from("failed to wait for tar archive process")
    })?;

    if !archive_status.success() {
        return Err(format!("tar archive process failed with status {archive_status}").into());
    }
    if !extract_status.success() {
        return Err(format!(
            "tar extract process failed with status {extract_status} while seeding {}",
            chroot_root.display()
        )
        .into());
    }
    Ok(())
}

fn rootfs_archive_paths() -> Result<Vec<PathBuf>, DynError> {
    let mut entries = fs::read_dir("/")?
        .map(|entry| entry.map(|value| Path::new(".").join(value.file_name())))
        .collect::<Result<Vec<_>, _>>()?;
    entries.sort();
    Ok(entries)
}

fn build_rootfs_extract_command(chroot_root: &Path) -> StdCommand {
    let mut command = StdCommand::new("tar");
    command
        .arg("xmf")
        .arg("-")
        // PVC-backed paths can reject restoring source owners, modes, or mtimes,
        // and Alpine/BusyBox tar does not support GNU-only --no-same-owner.
        // The chroot only needs a runnable filesystem; required runtime paths are
        // normalized explicitly after extraction.
        .arg("-m")
        .arg("-o")
        .arg("--no-same-permissions")
        .arg("-C")
        .arg(chroot_root);
    command
}

fn excluded_rootfs_paths(config: &ServerConfig) -> Vec<&Path> {
    let mut paths = vec![
        Path::new("/proc"),
        Path::new("/sys"),
        Path::new("/dev"),
        Path::new("/run"),
        Path::new("/tmp"),
        config.logical_workspace_root.as_path(),
        config.remote_home.as_path(),
    ];
    if let Some(environment_mount_path) = config.environment_mount_path.as_deref() {
        paths.push(environment_mount_path);
    }
    paths
}

fn ensure_runtime_dirs(chroot_root: &Path, remote_home: &Path) -> Result<(), DynError> {
    for relative in ["proc", "dev", "run", "tmp", "var/tmp"] {
        let path = chroot_root.join(relative);
        with_context(fs::create_dir_all(&path), || {
            format!("failed to create runtime directory {}", path.display())
        })?;
    }
    for relative in ["tmp", "var/tmp"] {
        let path = chroot_root.join(relative);
        with_context(
            fs::set_permissions(&path, fs::Permissions::from_mode(0o1777)),
            || format!("failed to set sticky permissions on {}", path.display()),
        )?;
    }

    ensure_remote_home_dirs(&resolve_remote_home_paths(chroot_root, remote_home)?)?;
    Ok(())
}

fn mount_runtime_filesystems(chroot_root: &Path) -> Result<(), DynError> {
    let dev_target = nested_absolute_path(chroot_root, Path::new("/dev"))?;
    let proc_target = nested_absolute_path(chroot_root, Path::new("/proc"))?;
    let run_target = nested_absolute_path(chroot_root, Path::new("/run"))?;
    bind_mount_if_missing(Path::new("/dev"), &dev_target)?;
    mount_proc_if_missing(&proc_target)?;
    mount_tmpfs_if_missing(&run_target, "mode=0755")?;
    bind_kubernetes_service_account_if_present(chroot_root)?;
    Ok(())
}

fn bind_kubernetes_service_account_if_present(chroot_root: &Path) -> Result<(), DynError> {
    let source = Path::new(KUBERNETES_SERVICE_ACCOUNT_DIR);
    if !source.is_dir() {
        return Ok(());
    }

    let target = nested_absolute_path(
        chroot_root,
        Path::new(CHROOT_KUBERNETES_SERVICE_ACCOUNT_DIR),
    )?;
    let parent = target.parent().ok_or_else(|| {
        io::Error::other(format!(
            "missing parent for Kubernetes service account mount {}",
            target.display()
        ))
    })?;
    with_context(fs::create_dir_all(parent), || {
        format!(
            "failed to create Kubernetes service account mount parent {}",
            parent.display()
        )
    })?;
    with_context(fs::create_dir_all(&target), || {
        format!(
            "failed to create Kubernetes service account mount target {}",
            target.display()
        )
    })?;
    bind_mount_if_missing(source, &target)
}

fn mountinfo_contains(target: &Path) -> Result<bool, DynError> {
    let target = target
        .to_str()
        .ok_or_else(|| io::Error::other("mount target must be valid UTF-8"))?;
    let mountinfo = fs::read_to_string("/proc/self/mountinfo")?;
    Ok(mountinfo
        .lines()
        .filter_map(parse_mountinfo_mount_point)
        .any(|mount_point| mount_point == target))
}

fn parse_mountinfo_mount_point(line: &str) -> Option<String> {
    let mount_point = line.split(" ").nth(4)?;
    decode_mountinfo_field(mount_point).ok()
}

fn decode_mountinfo_field(field: &str) -> io::Result<String> {
    let bytes = field.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;

    while index < bytes.len() {
        if let Some(value) = parse_mountinfo_escape(bytes, index)? {
            decoded.push(value);
            index += 4;
            continue;
        }

        decoded.push(bytes[index]);
        index += 1;
    }

    String::from_utf8(decoded).map_err(io::Error::other)
}

fn parse_mountinfo_escape(bytes: &[u8], index: usize) -> io::Result<Option<u8>> {
    if bytes.get(index) != Some(&b'\\') || index + 3 >= bytes.len() {
        return Ok(None);
    }

    let octal = &bytes[index + 1..index + 4];
    if !octal.iter().all(|value| matches!(value, b'0'..=b'7')) {
        return Ok(None);
    }

    let octal = std::str::from_utf8(octal).map_err(io::Error::other)?;
    let value = u8::from_str_radix(octal, 8).map_err(io::Error::other)?;
    Ok(Some(value))
}

fn bind_mount_if_missing(source: &Path, target: &Path) -> Result<(), DynError> {
    if mountinfo_contains(target)? {
        return Ok(());
    }

    with_context(
        mount(
            Some(source),
            target,
            Option::<&str>::None,
            MsFlags::MS_BIND | MsFlags::MS_REC,
            Option::<&str>::None,
        ),
        || {
            format!(
                "failed to bind-mount {} onto {}",
                source.display(),
                target.display()
            )
        },
    )?;
    Ok(())
}

fn mount_proc_if_missing(target: &Path) -> Result<(), DynError> {
    if mountinfo_contains(target)? {
        return Ok(());
    }

    with_context(
        mount(
            Some("proc"),
            target,
            Some("proc"),
            MsFlags::empty(),
            Option::<&str>::None,
        ),
        || format!("failed to mount proc at {}", target.display()),
    )?;
    Ok(())
}

fn mount_tmpfs_if_missing(target: &Path, options: &str) -> Result<(), DynError> {
    if mountinfo_contains(target)? {
        return Ok(());
    }

    with_context(
        mount(
            Some("tmpfs"),
            target,
            Some("tmpfs"),
            MsFlags::empty(),
            Some(options),
        ),
        || {
            format!(
                "failed to mount tmpfs at {} with options {options}",
                target.display()
            )
        },
    )?;
    Ok(())
}

fn install_required_packages(chroot_root: &Path) -> Result<(), DynError> {
    if required_commands_present(chroot_root) {
        return Ok(());
    }

    if let Some(apk_path) = resolve_chroot_command(chroot_root, &["/sbin/apk", "/bin/apk"]) {
        let packages = apk_required_packages();
        run_in_chroot(chroot_root, &apk_path, &packages, &[])?;
        return Ok(());
    }

    if let Some(apt_get_path) =
        resolve_chroot_command(chroot_root, &["/usr/bin/apt-get", "/bin/apt-get"])
    {
        let noninteractive = [(
            OsString::from("DEBIAN_FRONTEND"),
            OsString::from("noninteractive"),
        )];
        let update_args = [
            OsString::from("update"),
            OsString::from("-o"),
            OsString::from("Acquire::Retries=3"),
        ];
        let install_args = apt_required_packages();
        run_in_chroot(chroot_root, &apt_get_path, &update_args, &noninteractive)?;
        run_in_chroot(chroot_root, &apt_get_path, &install_args, &noninteractive)?;
        return Ok(());
    }

    Err(io::Error::other("unsupported execution image package manager: need apk or apt-get").into())
}

fn apk_required_packages() -> Vec<OsString> {
    vec![
        OsString::from("add"),
        OsString::from("--no-cache"),
        OsString::from("bash"),
        OsString::from("git"),
        OsString::from("github-cli"),
        OsString::from("kubectl"),
        OsString::from("ca-certificates"),
        OsString::from("openssh-client"),
    ]
}

fn apt_required_packages() -> Vec<OsString> {
    vec![
        OsString::from("install"),
        OsString::from("-y"),
        OsString::from("--no-install-recommends"),
        OsString::from("bash"),
        OsString::from("ca-certificates"),
        OsString::from("git"),
        OsString::from("gh"),
        OsString::from("openssh-client"),
    ]
}

fn run_startup_script(chroot_root: &Path, startup_script: &str) -> Result<(), DynError> {
    if startup_script.trim().is_empty() {
        return Ok(());
    }

    let shell = resolve_shell(Some(chroot_root))
        .ok_or_else(|| io::Error::other("no supported shell found for startup script"))?;
    run_in_chroot(
        chroot_root,
        &shell,
        &[OsString::from("-lc"), OsString::from(startup_script)],
        &[],
    )
}

fn required_commands_present(chroot_root: &Path) -> bool {
    ["/bin/bash", "/usr/bin/git", "/usr/bin/gh", "/usr/bin/ssh"]
        .iter()
        .all(|candidate| resolve_chroot_command(chroot_root, &[*candidate]).is_some())
        && resolve_chroot_command(chroot_root, &["/usr/bin/kubectl", "/usr/local/bin/kubectl"])
            .is_some()
}

fn resolve_chroot_command(chroot_root: &Path, candidates: &[&str]) -> Option<PathBuf> {
    candidates.iter().find_map(|candidate| {
        let absolute = Path::new(candidate);
        nested_absolute_path(chroot_root, absolute)
            .ok()
            .filter(|path| path.is_file())
            .map(|_| absolute.to_path_buf())
    })
}

fn run_in_chroot(
    chroot_root: &Path,
    program: &Path,
    args: &[OsString],
    envs: &[(OsString, OsString)],
) -> Result<(), DynError> {
    let mut command = std::process::Command::new(program);
    command.args(args);
    for (key, value) in envs {
        command.env(key, value);
    }
    command.stdin(Stdio::null());
    command.stdout(Stdio::inherit());
    command.stderr(Stdio::inherit());
    configure_chroot_command(&mut command, chroot_root, Path::new("/"), None, None).map_err(
        |error| {
            format!(
                "failed to configure chroot command {} in {}: {error}",
                program.display(),
                chroot_root.display()
            )
        },
    )?;
    let status = with_context(command.status(), || {
        format!(
            "failed to execute {} inside chroot {}",
            program.display(),
            chroot_root.display()
        )
    })?;
    if status.success() {
        Ok(())
    } else {
        Err(format!(
            "command {} failed in chroot {} with status {status}",
            program.display(),
            chroot_root.display()
        )
        .into())
    }
}

fn sync_git_hooks_into_chroot(config: &ServerConfig) -> Result<(), DynError> {
    let Some(chroot_root) = config.chroot_root.as_deref() else {
        return Ok(());
    };
    let Some(git_hooks_source) = config.git_hooks_source.as_deref() else {
        return Ok(());
    };

    let target = nested_absolute_path(chroot_root, Path::new(CHROOT_GIT_HOOKS_DIR))?;
    if target.exists() {
        fs::remove_dir_all(&target)?;
    }
    copy_directory_recursive(git_hooks_source, &target)?;
    set_directory_mode_recursive(&target, 0o755, 0o644)?;
    for hook_name in ["pre-commit", "pre-push"] {
        let hook_path = target.join(hook_name);
        if hook_path.is_file() {
            fs::set_permissions(hook_path, fs::Permissions::from_mode(0o755))?;
        }
    }
    Ok(())
}

fn copy_directory_recursive(source: &Path, target: &Path) -> Result<(), DynError> {
    fs::create_dir_all(target)?;
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let source_path = entry.path();
        let target_path = target.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            copy_directory_recursive(&source_path, &target_path)?;
        } else {
            fs::copy(&source_path, &target_path)?;
        }
    }
    Ok(())
}

fn set_directory_mode_recursive(
    path: &Path,
    directory_mode: u32,
    file_mode: u32,
) -> Result<(), DynError> {
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let entry_path = entry.path();
        if entry.file_type()?.is_dir() {
            fs::set_permissions(&entry_path, fs::Permissions::from_mode(directory_mode))?;
            set_directory_mode_recursive(&entry_path, directory_mode, file_mode)?;
        } else {
            fs::set_permissions(&entry_path, fs::Permissions::from_mode(file_mode))?;
        }
    }
    fs::set_permissions(path, fs::Permissions::from_mode(directory_mode))?;
    Ok(())
}

fn sync_remote_home_config(config: &ServerConfig) -> Result<(), DynError> {
    let Some(chroot_root) = config.chroot_root.as_deref() else {
        return Ok(());
    };

    let paths = resolve_remote_home_paths(chroot_root, &config.remote_home)?;
    ensure_remote_home_dirs(&paths)?;
    prepare_remote_home_for_update(&paths)?;
    ensure_symlink_path(
        &paths.copilot_hooks_path,
        Path::new(CHROOT_COPILOT_HOOKS_DIR),
    )?;
    with_context(
        fs::write(&paths.cargo_config_path, render_remote_cargo_config()),
        || {
            format!(
                "failed to write remote cargo config {}",
                paths.cargo_config_path.display()
            )
        },
    )?;
    with_context(
        fs::write(
            &paths.gitconfig_path,
            render_remote_git_config(&config.git_user_name, &config.git_user_email),
        ),
        || {
            format!(
                "failed to write remote git config {}",
                paths.gitconfig_path.display()
            )
        },
    )?;
    set_path_mode(&paths.cargo_config_path, 0o644, "remote cargo config")?;
    set_path_mode(&paths.gitconfig_path, 0o640, "remote git config")?;
    finalize_remote_home_permissions(&paths, config.run_as_uid, config.run_as_gid)?;
    Ok(())
}

fn resolve_remote_home_paths(
    chroot_root: &Path,
    remote_home: &Path,
) -> Result<RemoteHomePaths, DynError> {
    let home_dir = nested_absolute_path(chroot_root, remote_home)?;
    let cargo_home_dir = home_dir.join(".cargo");
    let cargo_config_path = cargo_home_dir.join("config.toml");
    let config_dir = home_dir.join(".config");
    let copilot_dir = home_dir.join(".copilot");
    let copilot_hooks_path = copilot_dir.join("hooks");
    let gitconfig_path = home_dir.join(".gitconfig");
    Ok(RemoteHomePaths {
        home_dir,
        cargo_home_dir,
        cargo_config_path,
        config_dir,
        copilot_dir,
        copilot_hooks_path,
        gitconfig_path,
    })
}

fn ensure_remote_home_dirs(paths: &RemoteHomePaths) -> Result<(), DynError> {
    with_context(fs::create_dir_all(&paths.cargo_home_dir), || {
        format!(
            "failed to create remote cargo directory {}",
            paths.cargo_home_dir.display()
        )
    })?;
    with_context(fs::create_dir_all(&paths.config_dir), || {
        format!(
            "failed to create remote config directory {}",
            paths.config_dir.display()
        )
    })?;
    with_context(fs::create_dir_all(&paths.copilot_dir), || {
        format!(
            "failed to create remote Copilot directory {}",
            paths.copilot_dir.display()
        )
    })?;
    Ok(())
}

fn prepare_remote_home_for_update(paths: &RemoteHomePaths) -> Result<(), DynError> {
    for path in [
        &paths.home_dir,
        &paths.cargo_home_dir,
        &paths.config_dir,
        &paths.copilot_dir,
    ] {
        set_path_owner(path, 0, 0, "remote home path")?;
    }
    if paths.cargo_config_path.exists() {
        set_path_owner(&paths.cargo_config_path, 0, 0, "remote cargo config")?;
    }
    if paths.gitconfig_path.exists() {
        set_path_owner(&paths.gitconfig_path, 0, 0, "remote git config")?;
    }
    Ok(())
}

fn finalize_remote_home_permissions(
    paths: &RemoteHomePaths,
    uid: u32,
    gid: u32,
) -> Result<(), DynError> {
    for (path, owner_uid, description) in [
        (&paths.home_dir, 0, "remote home"),
        (&paths.cargo_home_dir, uid, "remote cargo directory"),
        (&paths.config_dir, uid, "remote config directory"),
        (&paths.copilot_dir, 0, "remote Copilot directory"),
        (&paths.cargo_config_path, uid, "remote cargo config"),
        (&paths.gitconfig_path, 0, "remote git config"),
    ] {
        set_path_owner(path, owner_uid, gid, description)?;
    }
    for (path, mode, description) in [
        (&paths.home_dir, 0o1770, "remote home"),
        (&paths.copilot_dir, 0o1770, "remote Copilot directory"),
        (&paths.gitconfig_path, 0o640, "remote git config"),
    ] {
        set_path_mode(path, mode, description)?;
    }
    set_symlink_owner(
        &paths.copilot_hooks_path,
        0,
        gid,
        "remote Copilot hooks symlink",
    )?;
    Ok(())
}

fn ensure_symlink_path(link_path: &Path, target_path: &Path) -> Result<(), DynError> {
    if let Ok(metadata) = fs::symlink_metadata(link_path) {
        if metadata.file_type().is_symlink() {
            if fs::read_link(link_path)? == target_path {
                return Ok(());
            }
            fs::remove_file(link_path)?;
        } else if metadata.is_dir() {
            fs::remove_dir_all(link_path)?;
        } else {
            fs::remove_file(link_path)?;
        }
    }

    std::os::unix::fs::symlink(target_path, link_path)?;
    Ok(())
}

fn set_path_owner(path: &Path, uid: u32, gid: u32, description: &str) -> Result<(), DynError> {
    with_context(
        chown(path, Some(Uid::from_raw(uid)), Some(Gid::from_raw(gid))),
        || {
            format!(
                "failed to set ownership on {description} {}",
                path.display()
            )
        },
    )?;
    Ok(())
}

fn set_symlink_owner(path: &Path, uid: u32, gid: u32, description: &str) -> Result<(), DynError> {
    let path_bytes = path.as_os_str().as_bytes();
    let path_cstr = CString::new(path_bytes).map_err(|_| {
        format!(
            "failed to prepare {description} {} for ownership update",
            path.display()
        )
    })?;
    if unsafe { libc::lchown(path_cstr.as_ptr(), uid, gid) } != 0 {
        return Err(format!(
            "failed to set ownership on {description} {}: {}",
            path.display(),
            io::Error::last_os_error()
        )
        .into());
    }
    Ok(())
}

fn set_path_mode(path: &Path, mode: u32, description: &str) -> Result<(), DynError> {
    with_context(
        fs::set_permissions(path, fs::Permissions::from_mode(mode)),
        || {
            format!(
                "failed to set mode {mode:o} on {description} {}",
                path.display()
            )
        },
    )?;
    Ok(())
}

fn render_remote_git_config(
    git_user_name: &Option<String>,
    git_user_email: &Option<String>,
) -> String {
    let mut content = String::from(
        "[core]\n    hooksPath = /usr/local/share/control-plane/hooks/git\n[credential \"https://github.com\"]\n    helper =\n    helper = !gh auth git-credential\n[credential \"https://gist.github.com\"]\n    helper =\n    helper = !gh auth git-credential\n",
    );
    if git_user_name.is_some() || git_user_email.is_some() {
        content.push_str("[user]\n");
        if let Some(name) = git_user_name {
            content.push_str(&format!("    name = {name}\n"));
        }
        if let Some(email) = git_user_email {
            content.push_str(&format!("    email = {email}\n"));
        }
    }
    content
}

fn render_remote_cargo_config() -> String {
    format!("[build]\ntarget-dir = \"{REMOTE_CARGO_TARGET_DIR}\"\n")
}

fn canonicalize_absolute_path(path: &Path, variable_name: &str) -> Result<PathBuf, String> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        env::current_dir()
            .map_err(|error| format!("failed to determine current directory: {error}"))?
            .join(path)
    };
    fs::canonicalize(&absolute).map_err(|error| {
        format!(
            "failed to resolve {variable_name} {}: {error}",
            absolute.display()
        )
    })
}

fn normalize_absolute_path(path: &Path, variable_name: &str) -> Result<PathBuf, String> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        env::current_dir()
            .map_err(|error| format!("failed to determine current directory: {error}"))?
            .join(path)
    };
    let normalized = normalize_path(&absolute);
    if normalized.is_absolute() {
        Ok(normalized)
    } else {
        Err(format!(
            "{variable_name} must resolve to an absolute path: {}",
            path.display()
        ))
    }
}

fn resolve_cwd(
    workspace_root: &Path,
    logical_workspace_root: &Path,
    raw_cwd: &str,
) -> Result<ResolvedCwd, String> {
    let logical = normalize_logical_cwd(logical_workspace_root, raw_cwd)?;
    let host = host_path_for_cwd(workspace_root, logical_workspace_root, &logical)?;
    let resolved_host = fs::canonicalize(&host)
        .map_err(|error| format!("failed to resolve cwd {}: {error}", host.display()))?;
    if resolved_host == workspace_root || resolved_host.starts_with(workspace_root) {
        Ok(ResolvedCwd {
            host: resolved_host,
            logical,
        })
    } else {
        Err(format!(
            "cwd must stay within {}: {}",
            workspace_root.display(),
            resolved_host.display()
        ))
    }
}

fn normalize_logical_cwd(workspace_root: &Path, raw_cwd: &str) -> Result<PathBuf, String> {
    let candidate = if raw_cwd.trim().is_empty() {
        workspace_root.to_path_buf()
    } else {
        let raw_path = Path::new(raw_cwd);
        if raw_path.is_absolute() {
            normalize_path(raw_path)
        } else {
            normalize_path(&workspace_root.join(raw_path))
        }
    };
    if candidate == workspace_root || candidate.starts_with(workspace_root) {
        Ok(candidate)
    } else {
        Err(format!(
            "cwd must stay within {}: {}",
            workspace_root.display(),
            candidate.display()
        ))
    }
}

fn host_path_for_cwd(
    workspace_root: &Path,
    logical_workspace_root: &Path,
    logical_cwd: &Path,
) -> Result<PathBuf, String> {
    let relative = logical_cwd
        .strip_prefix(logical_workspace_root)
        .map_err(|_| {
            format!(
                "cwd must stay within {}: {}",
                logical_workspace_root.display(),
                logical_cwd.display()
            )
        })?;
    Ok(workspace_root.join(relative))
}

fn host_path_for_logical(
    chroot_root: &Path,
    logical_workspace_root: &Path,
) -> Result<PathBuf, String> {
    nested_absolute_path(chroot_root, logical_workspace_root)
        .map_err(|error| format!("failed to derive chroot workspace root: {error}"))
}

fn nested_absolute_path(root: &Path, absolute_path: &Path) -> io::Result<PathBuf> {
    let suffix = strip_leading_slash(absolute_path);
    Ok(root.join(suffix))
}

fn strip_leading_slash(path: &Path) -> PathBuf {
    path.components()
        .filter_map(|component| match component {
            Component::Normal(value) => Some(value.to_os_string()),
            Component::CurDir => None,
            Component::ParentDir => Some(component.as_os_str().to_os_string()),
            Component::RootDir | Component::Prefix(_) => None,
        })
        .collect()
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

fn resolve_shell(chroot_root: Option<&Path>) -> Option<PathBuf> {
    let candidates = ["/bin/bash", "/usr/bin/bash", "/bin/sh", "/usr/bin/sh"];
    candidates.iter().find_map(|candidate| {
        let absolute = Path::new(candidate);
        if let Some(chroot_root) = chroot_root {
            nested_absolute_path(chroot_root, absolute)
                .ok()
                .filter(|path| path.is_file())
                .map(|_| absolute.to_path_buf())
        } else {
            absolute.is_file().then(|| absolute.to_path_buf())
        }
    })
}

fn managed_exec_path(runtime_path: Option<OsString>) -> OsString {
    match runtime_path {
        Some(path) if !path.is_empty() => path,
        _ => OsString::from(DEFAULT_EXEC_PATH),
    }
}

fn managed_shell_environment(remote_home: &Path, chrooted: bool) -> Vec<(&'static str, OsString)> {
    let mut env = vec![
        ("PATH", managed_exec_path(env::var_os("PATH"))),
        ("HOME", remote_home.as_os_str().to_os_string()),
        (
            "GIT_CONFIG_GLOBAL",
            remote_home.join(".gitconfig").into_os_string(),
        ),
    ];
    for key in ["CONTROL_PLANE_K8S_NAMESPACE", "CONTROL_PLANE_JOB_NAMESPACE"] {
        if let Some(value) = env::var_os(key) {
            env.push((key, value));
        }
    }
    if chrooted {
        env.push((
            "LD_PRELOAD",
            OsString::from(CHROOT_EXEC_POLICY_LIBRARY_PATH),
        ));
        env.push((
            "CONTROL_PLANE_EXEC_POLICY_RULES_FILE",
            OsString::from(CHROOT_EXEC_POLICY_RULES_PATH),
        ));
    }
    env
}

fn stdout_with_command_line(command: &str, stdout: &[u8]) -> String {
    let mut rendered = String::from("$ ");
    rendered.push_str(command);
    if !command.ends_with('\n') {
        rendered.push('\n');
    }
    rendered.push_str(&String::from_utf8_lossy(stdout));
    rendered
}

async fn run_shell_command(
    command: &str,
    cwd: &ResolvedCwd,
    exec_timeout: Duration,
    run_as_uid: u32,
    run_as_gid: u32,
    chroot_root: Option<&Path>,
    remote_home: &Path,
) -> Result<ExecResult, Status> {
    let shell = resolve_shell(chroot_root).ok_or_else(|| {
        Status::failed_precondition("no supported shell found (tried bash and sh variants)")
    })?;
    let mut process = TokioCommand::new(shell);
    process
        .arg("-lc")
        .arg(command)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for (key, value) in managed_shell_environment(remote_home, chroot_root.is_some()) {
        process.env(key, value);
    }
    process.kill_on_drop(true);
    configure_command_identity(
        &mut process,
        run_as_uid,
        run_as_gid,
        chroot_root,
        &cwd.host,
        &cwd.logical,
    )
    .map_err(|error| Status::new(Code::Internal, error.to_string()))?;
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
        stdout: stdout_with_command_line(command, &output.stdout),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        exit_code: exit_code_from_status(output.status),
    })
}

fn post_tool_use_hook_path(remote_home: &Path) -> PathBuf {
    remote_home.join(".copilot/hooks/postToolUse/main")
}

async fn run_post_tool_use_hook(
    raw_input: &str,
    cwd: &ResolvedCwd,
    exec_timeout: Duration,
    run_as_uid: u32,
    run_as_gid: u32,
    chroot_root: Option<&Path>,
    remote_home: &Path,
) -> Result<ExecResult, Status> {
    let hook_path = post_tool_use_hook_path(remote_home);
    let mut process = TokioCommand::new(&hook_path);
    process
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for (key, value) in managed_shell_environment(remote_home, chroot_root.is_some()) {
        process.env(key, value);
    }
    process.env("CONTROL_PLANE_POST_TOOL_USE_FORWARD_ACTIVE", "1");
    process.kill_on_drop(true);
    configure_command_identity(
        &mut process,
        run_as_uid,
        run_as_gid,
        chroot_root,
        &cwd.host,
        &cwd.logical,
    )
    .map_err(|error| Status::new(Code::Internal, error.to_string()))?;
    let mut child = process
        .spawn()
        .map_err(|error| Status::new(Code::Internal, error.to_string()))?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(raw_input.as_bytes())
            .await
            .map_err(|error| Status::new(Code::Internal, error.to_string()))?;
    }
    let output = tokio::time::timeout(exec_timeout, child.wait_with_output())
        .await
        .map_err(|_| {
            Status::deadline_exceeded(format!(
                "postToolUse hook exceeded execution timeout of {} seconds",
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
fn configure_command_identity(
    process: &mut TokioCommand,
    run_as_uid: u32,
    run_as_gid: u32,
    chroot_root: Option<&Path>,
    host_cwd: &Path,
    logical_cwd: &Path,
) -> io::Result<()> {
    if let Some(chroot_root) = chroot_root {
        configure_chroot_command(
            process.as_std_mut(),
            chroot_root,
            logical_cwd,
            Some(run_as_uid),
            Some(run_as_gid),
        )?;
    } else {
        process.current_dir(host_cwd);
        process.uid(run_as_uid);
        process.gid(run_as_gid);
    }
    Ok(())
}

#[cfg(unix)]
fn configure_chroot_command(
    process: &mut std::process::Command,
    chroot_root: &Path,
    cwd: &Path,
    run_as_uid: Option<u32>,
    run_as_gid: Option<u32>,
) -> io::Result<()> {
    let chroot_root = chroot_root.to_path_buf();
    let cwd = cwd.to_path_buf();
    unsafe {
        process.pre_exec(move || {
            chroot(&chroot_root).map_err(io::Error::other)?;
            chdir(&cwd).map_err(io::Error::other)?;
            if let Some(run_as_gid) = run_as_gid {
                setgid(Gid::from_raw(run_as_gid)).map_err(io::Error::other)?;
            }
            if let Some(run_as_uid) = run_as_uid {
                setuid(Uid::from_raw(run_as_uid)).map_err(io::Error::other)?;
            }
            Ok(())
        });
    }
    Ok(())
}

#[cfg(not(unix))]
fn configure_command_identity(
    _process: &mut TokioCommand,
    _run_as_uid: u32,
    _run_as_gid: u32,
    _chroot_root: Option<&Path>,
    _host_cwd: &Path,
    _logical_cwd: &Path,
) -> io::Result<()> {
    Ok(())
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
    use super::{
        CHROOT_COPILOT_HOOKS_DIR, CHROOT_EXEC_POLICY_LIBRARY_PATH, CHROOT_EXEC_POLICY_RULES_PATH,
        CHROOT_KUBECTL_PATH, CHROOT_KUBERNETES_SERVICE_ACCOUNT_DIR,
        CHROOT_POST_TOOL_USE_HOOKS_PATH, CHROOT_RUNTIME_TOOL_PATH, DEFAULT_EXEC_PATH,
        EXEC_API_TOKEN_METADATA_KEY, ExecApiService, ServerConfig, ServerMode, TrafficLogger,
        apt_required_packages, build_rootfs_extract_command, build_server_config,
        ensure_runtime_dirs, managed_exec_path, managed_shell_environment, normalize_path,
        render_remote_cargo_config, render_remote_git_config, required_commands_present,
        reset_incomplete_bootstrap_root, resolve_cwd, stdout_with_command_line,
        sync_remote_home_config,
    };
    use crate::RawServerConfig;
    use crate::proto;
    use crate::proto::exec_service_server::ExecService;
    use serde_json::json;
    use std::env;
    use std::ffi::OsString;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::sync::{Arc, Mutex, OnceLock};
    use std::time::Duration;
    use tempfile::TempDir;
    use tonic::Request;
    use tonic::metadata::MetadataValue;

    #[derive(Debug, Default)]
    struct CapturingTrafficLogger {
        lines: Mutex<Vec<String>>,
    }

    impl CapturingTrafficLogger {
        fn lines(&self) -> Vec<String> {
            self.lines.lock().unwrap().clone()
        }
    }

    impl TrafficLogger for CapturingTrafficLogger {
        fn log_line(&self, line: &str) -> Result<(), String> {
            self.lines.lock().unwrap().push(line.to_owned());
            Ok(())
        }
    }

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    struct ScopedEnvVar {
        key: &'static str,
        previous: Option<OsString>,
    }

    impl ScopedEnvVar {
        fn set(key: &'static str, value: Option<&str>) -> Self {
            let previous = env::var_os(key);
            match value {
                Some(value) => unsafe { env::set_var(key, value) },
                None => unsafe { env::remove_var(key) },
            }
            Self { key, previous }
        }
    }

    impl Drop for ScopedEnvVar {
        fn drop(&mut self) {
            match &self.previous {
                Some(value) => unsafe { env::set_var(self.key, value) },
                None => unsafe { env::remove_var(self.key) },
            }
        }
    }

    #[derive(Debug, Default)]
    struct FailingTrafficLogger;

    impl TrafficLogger for FailingTrafficLogger {
        fn log_line(&self, _line: &str) -> Result<(), String> {
            Err(String::from("synthetic traffic logger failure"))
        }
    }

    fn test_server_config(workspace: &TempDir, token: &str) -> ServerConfig {
        let remote_home = workspace.path().join("home");
        fs::create_dir_all(&remote_home).unwrap();
        ServerConfig {
            port: 8080,
            workspace_root: workspace.path().to_path_buf(),
            logical_workspace_root: workspace.path().to_path_buf(),
            chroot_root: None,
            environment_mount_path: None,
            git_hooks_source: None,
            remote_home,
            git_user_name: None,
            git_user_email: None,
            startup_script: None,
            mode: ServerMode::Exec,
            exec_api_token: token.to_owned(),
            exec_timeout: Duration::from_secs(5),
            run_as_uid: unsafe { libc::geteuid() },
            run_as_gid: unsafe { libc::getegid() },
        }
    }

    #[test]
    fn normalize_path_removes_dot_segments() {
        assert_eq!(
            normalize_path(Path::new("/workspace/./nested/../repo")),
            PathBuf::from("/workspace/repo")
        );
    }

    #[test]
    fn resolve_cwd_rejects_paths_outside_workspace() {
        let error = resolve_cwd(
            Path::new("/workspace"),
            Path::new("/workspace"),
            "/workspace/../tmp",
        )
        .expect_err("path should be rejected");
        assert_eq!(error, "cwd must stay within /workspace: /tmp");
    }

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

    #[cfg(unix)]
    #[test]
    fn resolve_cwd_rejects_symlink_escapes() {
        use std::os::unix::fs::symlink;

        let temp_dir = TempDir::new().unwrap();
        let workspace = temp_dir.path().join("workspace");
        let outside = temp_dir.path().join("outside");
        std::fs::create_dir_all(&workspace).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        symlink(&outside, workspace.join("escape")).unwrap();
        let workspace = std::fs::canonicalize(&workspace).unwrap();

        let error = resolve_cwd(
            &workspace,
            &workspace,
            workspace.join("escape").to_str().unwrap(),
        )
        .unwrap_err();
        assert_eq!(
            error,
            format!(
                "cwd must stay within {}: {}",
                workspace.display(),
                outside.display()
            )
        );
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

    #[test]
    fn remote_git_config_uses_chroot_hook_path() {
        let rendered = render_remote_git_config(
            &Some(String::from("Copilot")),
            &Some(String::from("copilot@example.com")),
        );
        assert!(rendered.contains("hooksPath = /usr/local/share/control-plane/hooks/git"));
        assert!(rendered.contains("name = Copilot"));
        assert!(rendered.contains("email = copilot@example.com"));
    }

    #[test]
    fn managed_shell_environment_enables_exec_policy_for_chroot() {
        let _env_lock = env_lock().lock().unwrap();
        let _path = ScopedEnvVar::set("PATH", Some("/runtime/bin:/usr/bin"));
        let env = managed_shell_environment(Path::new("/root"), true);
        assert!(env.contains(&("PATH", OsString::from("/runtime/bin:/usr/bin"))));
        assert!(env.contains(&("HOME", OsString::from("/root"))));
        assert!(env.contains(&("GIT_CONFIG_GLOBAL", OsString::from("/root/.gitconfig"))));
        assert!(env.contains(&(
            "LD_PRELOAD",
            OsString::from(CHROOT_EXEC_POLICY_LIBRARY_PATH),
        )));
        assert!(env.contains(&(
            "CONTROL_PLANE_EXEC_POLICY_RULES_FILE",
            OsString::from(CHROOT_EXEC_POLICY_RULES_PATH),
        )));
    }

    #[test]
    fn managed_shell_environment_skips_exec_policy_without_chroot() {
        let _env_lock = env_lock().lock().unwrap();
        let _path = ScopedEnvVar::set("PATH", Some("/tooling/bin:/usr/bin"));
        let env = managed_shell_environment(Path::new("/root"), false);
        assert!(env.contains(&("PATH", OsString::from("/tooling/bin:/usr/bin"))));
        assert!(env.contains(&("HOME", OsString::from("/root"))));
        assert!(env.contains(&("GIT_CONFIG_GLOBAL", OsString::from("/root/.gitconfig"))));
        assert!(!env.iter().any(|(key, _)| *key == "LD_PRELOAD"));
        assert!(
            !env.iter()
                .any(|(key, _)| *key == "CONTROL_PLANE_EXEC_POLICY_RULES_FILE")
        );
    }

    #[test]
    fn managed_exec_path_preserves_runtime_path() {
        assert_eq!(
            managed_exec_path(Some(OsString::from("/venv/bin:/usr/bin"))),
            OsString::from("/venv/bin:/usr/bin")
        );
    }

    #[test]
    fn managed_exec_path_falls_back_without_runtime_path() {
        assert_eq!(managed_exec_path(None), OsString::from(DEFAULT_EXEC_PATH));
        assert_eq!(
            managed_exec_path(Some(OsString::new())),
            OsString::from(DEFAULT_EXEC_PATH)
        );
    }

    #[test]
    fn managed_shell_environment_falls_back_to_default_path_without_runtime_path() {
        let _env_lock = env_lock().lock().unwrap();
        let _path = ScopedEnvVar::set("PATH", None);
        let env = managed_shell_environment(Path::new("/root"), false);
        assert!(env.contains(&("PATH", OsString::from(DEFAULT_EXEC_PATH))));
    }

    fn write_stub_command(chroot_root: &Path, relative_path: &str) {
        let full_path = chroot_root.join(relative_path.trim_start_matches('/'));
        fs::create_dir_all(full_path.parent().unwrap()).unwrap();
        fs::write(full_path, "").unwrap();
    }

    #[test]
    fn required_commands_present_requires_kubectl_in_chroot() {
        let chroot_root = TempDir::new().unwrap();
        for command_path in ["/bin/bash", "/usr/bin/git", "/usr/bin/gh", "/usr/bin/ssh"] {
            write_stub_command(chroot_root.path(), command_path);
        }
        assert!(!required_commands_present(chroot_root.path()));
        write_stub_command(chroot_root.path(), "/usr/local/bin/kubectl");
        assert!(required_commands_present(chroot_root.path()));
    }

    #[test]
    fn apt_required_packages_skip_kubectl_package() {
        let packages = apt_required_packages();

        assert!(!packages.contains(&OsString::from("kubectl")));
        assert!(!packages.contains(&OsString::from("kubernetes-client")));
    }

    #[test]
    fn incomplete_bootstrap_reset_preserves_workspace_and_managed_assets() {
        let chroot_root = TempDir::new().unwrap();
        let workspace_root = chroot_root.path().join("workspace/project");
        fs::create_dir_all(&workspace_root).unwrap();
        fs::write(workspace_root.join("keep.txt"), "keep").unwrap();
        fs::create_dir_all(chroot_root.path().join("tmp")).unwrap();
        fs::write(chroot_root.path().join("tmp/stale.txt"), "stale").unwrap();
        fs::create_dir_all(chroot_root.path().join("var/tmp")).unwrap();
        fs::write(chroot_root.path().join("var/tmp/stale.txt"), "stale").unwrap();
        fs::create_dir_all(chroot_root.path().join("bin")).unwrap();
        fs::write(chroot_root.path().join("bin/bash"), "").unwrap();
        fs::create_dir_all(chroot_root.path().join("etc")).unwrap();
        fs::write(chroot_root.path().join("etc/os-release"), "").unwrap();
        fs::create_dir_all(chroot_root.path().join("root/.config/gh")).unwrap();
        fs::write(chroot_root.path().join("root/.config/gh/hosts.yml"), "gh").unwrap();
        fs::create_dir_all(chroot_root.path().join("root/.config/control-plane")).unwrap();
        fs::write(
            chroot_root
                .path()
                .join("root/.config/control-plane/stale.txt"),
            "stale",
        )
        .unwrap();
        fs::create_dir_all(chroot_root.path().join("root/.ssh")).unwrap();
        fs::write(chroot_root.path().join("root/.ssh/config"), "ssh").unwrap();
        write_stub_command(chroot_root.path(), CHROOT_KUBECTL_PATH);
        write_stub_command(chroot_root.path(), CHROOT_RUNTIME_TOOL_PATH);
        write_stub_command(chroot_root.path(), CHROOT_EXEC_POLICY_LIBRARY_PATH);
        write_stub_command(chroot_root.path(), CHROOT_EXEC_POLICY_RULES_PATH);
        write_stub_command(
            chroot_root.path(),
            &format!("{CHROOT_POST_TOOL_USE_HOOKS_PATH}/control-plane-rust.sh"),
        );
        write_stub_command(
            chroot_root.path(),
            &format!("{CHROOT_COPILOT_HOOKS_DIR}/git/pre-commit"),
        );

        let config = build_server_config(RawServerConfig {
            port: "8080",
            workspace: Path::new("/workspace"),
            chroot_root: Some(chroot_root.path()),
            environment_mount: Some(Path::new("/environment")),
            git_hooks_source: Some(Path::new("/environment/hooks/git")),
            remote_home: Path::new("/root"),
            git_user_name: None,
            git_user_email: None,
            startup_script: None,
            mode: "exec",
            exec_api_token: String::from("token"),
            timeout_sec: "3600",
            run_as_uid: "1000",
            run_as_gid: "1000",
        })
        .unwrap();

        reset_incomplete_bootstrap_root(chroot_root.path(), &config).unwrap();

        assert!(
            chroot_root
                .path()
                .join("workspace/project/keep.txt")
                .is_file()
        );
        assert!(chroot_root.path().join("usr/local/bin/kubectl").is_file());
        assert!(
            chroot_root
                .path()
                .join("usr/local/bin/control-plane-runtime-tool")
                .is_file()
        );
        assert!(
            chroot_root
                .path()
                .join("usr/local/share/control-plane/hooks/postToolUse/control-plane-rust.sh")
                .is_file()
        );
        assert!(
            chroot_root
                .path()
                .join("usr/local/share/control-plane/hooks/preToolUse/deny-rules.yaml")
                .is_file()
        );
        assert!(
            chroot_root
                .path()
                .join("root/.config/gh/hosts.yml")
                .is_file()
        );
        assert!(chroot_root.path().join("root/.ssh/config").is_file());
        assert!(!chroot_root.path().join("bin").exists());
        assert!(!chroot_root.path().join("etc").exists());
        assert!(
            !chroot_root
                .path()
                .join("root/.config/control-plane")
                .exists()
        );
        assert!(
            !chroot_root
                .path()
                .join("usr/local/share/control-plane/hooks/git")
                .exists()
        );
        assert!(chroot_root.path().join("tmp").is_dir());
        assert!(!chroot_root.path().join("tmp/stale.txt").exists());
        assert!(chroot_root.path().join("var/tmp").is_dir());
        assert!(!chroot_root.path().join("var/tmp/stale.txt").exists());
    }

    #[test]
    fn rootfs_extract_command_uses_portable_metadata_flags() {
        let command = build_rootfs_extract_command(Path::new("/environment/root"));
        let args = command.get_args().map(OsString::from).collect::<Vec<_>>();

        assert_eq!(
            args,
            vec![
                OsString::from("xmf"),
                OsString::from("-"),
                OsString::from("-m"),
                OsString::from("-o"),
                OsString::from("--no-same-permissions"),
                OsString::from("-C"),
                OsString::from("/environment/root"),
            ]
        );
    }

    #[test]
    fn ensure_runtime_dirs_creates_run_directory() {
        let tempdir = TempDir::new().unwrap();
        ensure_runtime_dirs(tempdir.path(), Path::new("/root")).unwrap();

        assert!(tempdir.path().join("run").is_dir());
        assert!(tempdir.path().join("tmp").is_dir());
        assert!(tempdir.path().join("var/tmp").is_dir());
        assert!(tempdir.path().join("root/.config").is_dir());
        assert!(tempdir.path().join("root/.copilot").is_dir());
    }

    #[test]
    fn chroot_kubernetes_service_account_path_uses_run_directory() {
        let tempdir = TempDir::new().unwrap();

        assert_eq!(
            super::nested_absolute_path(
                tempdir.path(),
                Path::new(CHROOT_KUBERNETES_SERVICE_ACCOUNT_DIR)
            )
            .unwrap(),
            tempdir
                .path()
                .join("run/secrets/kubernetes.io/serviceaccount")
        );
    }

    #[test]
    fn parse_mountinfo_mount_point_decodes_escaped_paths() {
        let line = "29 23 0:26 / /environment/root\\040with\\040spaces rw,nosuid - tmpfs tmpfs rw";

        assert_eq!(
            super::parse_mountinfo_mount_point(line).as_deref(),
            Some("/environment/root with spaces")
        );
    }

    #[test]
    fn stdout_with_command_line_prefixes_command_output() {
        assert_eq!(
            stdout_with_command_line("printf 'hello\\n'", b"hello\n"),
            "$ printf 'hello\\n'\nhello\n"
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn execute_logs_request_and_success_response() {
        let workspace = TempDir::new().unwrap();
        let token = "traffic-log-token";
        let logger = Arc::new(CapturingTrafficLogger::default());
        let service = ExecApiService::new_with_traffic_logger(
            &test_server_config(&workspace, token),
            logger.clone(),
        );
        let command = "printf 'logged stdout\\n'; printf 'logged stderr\\n' >&2";
        let cwd = workspace.path().to_str().unwrap().to_owned();

        let mut request = Request::new(proto::ExecuteRequest {
            command: command.to_owned(),
            cwd: cwd.clone(),
        });
        request.metadata_mut().insert(
            EXEC_API_TOKEN_METADATA_KEY,
            MetadataValue::try_from(token).unwrap(),
        );

        let response = service.execute(request).await.unwrap().into_inner();
        assert_eq!(
            response.stdout,
            "$ printf 'logged stdout\\n'; printf 'logged stderr\\n' >&2\nlogged stdout\n"
        );
        assert_eq!(response.stderr, "logged stderr\n");
        assert_eq!(response.exit_code, 0);

        let lines = logger.lines();
        assert_eq!(lines.len(), 2);
        let mut request_log = serde_json::from_str::<serde_json::Value>(&lines[0]).unwrap();
        let request_timestamp = request_log
            .as_object_mut()
            .unwrap()
            .remove("timestamp")
            .and_then(|value| value.as_u64())
            .expect("request log should include a millisecond timestamp");
        assert!(request_timestamp > 0);
        assert_eq!(
            request_log,
            json!({
                "event": "executeRequest",
                "requestId": 1,
                "mode": "exec",
                "cwd": cwd,
                "command": command,
            })
        );
        let mut response_log = serde_json::from_str::<serde_json::Value>(&lines[1]).unwrap();
        let response_timestamp = response_log
            .as_object_mut()
            .unwrap()
            .remove("timestamp")
            .and_then(|value| value.as_u64())
            .expect("response log should include a millisecond timestamp");
        assert!(response_timestamp > 0);
        assert_eq!(
            response_log,
            json!({
                "event": "executeResponse",
                "requestId": 1,
                "status": "ok",
                "mode": "exec",
                "cwd": workspace.path().to_str().unwrap(),
                "command": command,
                "exitCode": 0,
                "stdout": "$ printf 'logged stdout\\n'; printf 'logged stderr\\n' >&2\nlogged stdout\n",
                "stderr": "logged stderr\n",
                "grpcCode": null,
                "error": null,
            })
        );
    }

    #[test]
    fn format_log_line_prefixes_epoch_milliseconds() {
        assert_eq!(
            super::format_log_line(
                1_704_614_400_000,
                "listening on 127.0.0.1:7777 for /workspace"
            ),
            "1704614400000 control-plane-exec-api: listening on 127.0.0.1:7777 for /workspace"
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn execute_does_not_log_permission_denied_requests() {
        let workspace = TempDir::new().unwrap();
        let logger = Arc::new(CapturingTrafficLogger::default());
        let service = ExecApiService::new_with_traffic_logger(
            &test_server_config(&workspace, "expected-token"),
            logger.clone(),
        );
        let cwd = workspace.path().to_str().unwrap().to_owned();

        let request = Request::new(proto::ExecuteRequest {
            command: String::from("printf denied"),
            cwd: cwd.clone(),
        });

        let error = service
            .execute(request)
            .await
            .expect_err("request without token should fail");
        assert_eq!(error.code(), tonic::Code::PermissionDenied);
        assert_eq!(error.message(), "missing or invalid exec API token");
        assert!(logger.lines().is_empty());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn execute_still_succeeds_when_stdout_traffic_logging_fails() {
        let workspace = TempDir::new().unwrap();
        let token = "traffic-log-token";
        let service = ExecApiService::new_with_traffic_logger(
            &test_server_config(&workspace, token),
            Arc::new(FailingTrafficLogger),
        );
        let cwd = workspace.path().to_str().unwrap().to_owned();

        let mut request = Request::new(proto::ExecuteRequest {
            command: String::from("printf resilient"),
            cwd,
        });
        request.metadata_mut().insert(
            EXEC_API_TOKEN_METADATA_KEY,
            MetadataValue::try_from(token).unwrap(),
        );

        let response = service.execute(request).await.unwrap().into_inner();
        assert_eq!(response.stdout, "$ printf resilient\nresilient");
        assert_eq!(response.stderr, "");
        assert_eq!(response.exit_code, 0);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn execute_keeps_invalid_argument_when_stdout_traffic_logging_fails() {
        let workspace = TempDir::new().unwrap();
        let token = "expected-token";
        let service = ExecApiService::new_with_traffic_logger(
            &test_server_config(&workspace, token),
            Arc::new(FailingTrafficLogger),
        );
        let cwd = workspace.path().to_str().unwrap().to_owned();

        let mut request = Request::new(proto::ExecuteRequest {
            command: String::new(),
            cwd,
        });
        request.metadata_mut().insert(
            EXEC_API_TOKEN_METADATA_KEY,
            MetadataValue::try_from(token).unwrap(),
        );

        let error = service
            .execute(request)
            .await
            .expect_err("empty command should fail");
        assert_eq!(error.code(), tonic::Code::InvalidArgument);
        assert_eq!(error.message(), "command must be a non-empty string");
    }

    #[cfg(unix)]
    #[test]
    fn sync_remote_home_config_handles_reused_runtime_owned_home() {
        use nix::unistd::{Gid, Uid, chown};
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        use std::os::unix::process::CommandExt;
        use std::process::Command;

        if !Uid::effective().is_root() {
            return;
        }

        let workspace = TempDir::new().unwrap();
        let chroot_root = TempDir::new().unwrap();
        let config = build_server_config(RawServerConfig {
            port: "8080",
            workspace: workspace.path(),
            chroot_root: Some(chroot_root.path()),
            environment_mount: None,
            git_hooks_source: None,
            remote_home: Path::new("/root"),
            git_user_name: Some(String::from("Copilot")),
            git_user_email: Some(String::from("copilot@example.com")),
            startup_script: None,
            mode: "exec",
            exec_api_token: String::from("token"),
            timeout_sec: "3600",
            run_as_uid: "1000",
            run_as_gid: "1000",
        })
        .unwrap();
        let home_dir = chroot_root.path().join("root");
        let cargo_dir = home_dir.join(".cargo");
        let cargo_config_path = cargo_dir.join("config.toml");
        let config_dir = home_dir.join(".config");
        let copilot_dir = home_dir.join(".copilot");
        let copilot_hooks_path = copilot_dir.join("hooks");
        let gitconfig_path = home_dir.join(".gitconfig");

        fs::create_dir_all(&cargo_dir).unwrap();
        fs::create_dir_all(&config_dir).unwrap();
        fs::create_dir_all(&copilot_dir).unwrap();
        fs::write(&cargo_config_path, "stale\n").unwrap();
        fs::write(&gitconfig_path, "stale\n").unwrap();
        chown(
            &home_dir,
            Some(Uid::from_raw(1000)),
            Some(Gid::from_raw(1000)),
        )
        .unwrap();
        chown(
            &cargo_dir,
            Some(Uid::from_raw(1000)),
            Some(Gid::from_raw(1000)),
        )
        .unwrap();
        chown(
            &config_dir,
            Some(Uid::from_raw(1000)),
            Some(Gid::from_raw(1000)),
        )
        .unwrap();
        chown(
            &copilot_dir,
            Some(Uid::from_raw(1000)),
            Some(Gid::from_raw(1000)),
        )
        .unwrap();
        chown(
            &cargo_config_path,
            Some(Uid::from_raw(1000)),
            Some(Gid::from_raw(1000)),
        )
        .unwrap();
        chown(
            &gitconfig_path,
            Some(Uid::from_raw(1000)),
            Some(Gid::from_raw(1000)),
        )
        .unwrap();

        sync_remote_home_config(&config).unwrap();

        let home_metadata = fs::metadata(&home_dir).unwrap();
        let cargo_metadata = fs::metadata(&cargo_dir).unwrap();
        let cargo_config_metadata = fs::metadata(&cargo_config_path).unwrap();
        let config_metadata = fs::metadata(&config_dir).unwrap();
        let copilot_metadata = fs::metadata(&copilot_dir).unwrap();
        let copilot_hooks_metadata = fs::symlink_metadata(&copilot_hooks_path).unwrap();
        let gitconfig_metadata = fs::metadata(&gitconfig_path).unwrap();
        assert_eq!(home_metadata.uid(), 0);
        assert_eq!(home_metadata.gid(), 1000);
        assert_eq!(cargo_metadata.uid(), 1000);
        assert_eq!(cargo_metadata.gid(), 1000);
        assert_eq!(cargo_config_metadata.uid(), 1000);
        assert_eq!(cargo_config_metadata.gid(), 1000);
        assert_eq!(config_metadata.uid(), 1000);
        assert_eq!(config_metadata.gid(), 1000);
        assert_eq!(copilot_metadata.uid(), 0);
        assert_eq!(copilot_metadata.gid(), 1000);
        assert_eq!(copilot_hooks_metadata.uid(), 0);
        assert_eq!(copilot_hooks_metadata.gid(), 1000);
        assert_eq!(gitconfig_metadata.uid(), 0);
        assert_eq!(gitconfig_metadata.gid(), 1000);
        assert_eq!(home_metadata.permissions().mode() & 0o7777, 0o1770);
        assert_eq!(cargo_config_metadata.permissions().mode() & 0o777, 0o644);
        assert_eq!(copilot_metadata.permissions().mode() & 0o7777, 0o1770);
        assert_eq!(gitconfig_metadata.permissions().mode() & 0o777, 0o640);
        assert_eq!(
            fs::read_to_string(&cargo_config_path).unwrap(),
            render_remote_cargo_config()
        );
        assert_eq!(
            fs::read_link(&copilot_hooks_path).unwrap(),
            PathBuf::from(CHROOT_COPILOT_HOOKS_DIR)
        );

        let replacement_status = Command::new("ln")
            .arg("-sfn")
            .arg("/tmp/evil-hooks")
            .arg(&copilot_hooks_path)
            .uid(1000)
            .gid(1000)
            .status()
            .unwrap();
        assert!(!replacement_status.success());
        assert_eq!(
            fs::read_link(&copilot_hooks_path).unwrap(),
            PathBuf::from(CHROOT_COPILOT_HOOKS_DIR)
        );

        let writable_state_path = copilot_dir.join("user-owned.json");
        let writable_state_status = Command::new("touch")
            .arg(&writable_state_path)
            .uid(1000)
            .gid(1000)
            .status()
            .unwrap();
        assert!(writable_state_status.success());
        let writable_state_metadata = fs::metadata(&writable_state_path).unwrap();
        assert_eq!(writable_state_metadata.uid(), 1000);
        assert_eq!(writable_state_metadata.gid(), 1000);
    }

    #[cfg(unix)]
    #[test]
    fn sync_remote_home_config_replaces_stale_copilot_hooks_directory_with_symlink() {
        use nix::unistd::Uid;

        if !Uid::effective().is_root() {
            return;
        }

        let workspace = TempDir::new().unwrap();
        let chroot_root = TempDir::new().unwrap();
        let config = build_server_config(RawServerConfig {
            port: "8080",
            workspace: workspace.path(),
            chroot_root: Some(chroot_root.path()),
            environment_mount: None,
            git_hooks_source: None,
            remote_home: Path::new("/root"),
            git_user_name: Some(String::from("Copilot")),
            git_user_email: Some(String::from("copilot@example.com")),
            startup_script: None,
            mode: "exec",
            exec_api_token: String::from("token"),
            timeout_sec: "3600",
            run_as_uid: "1000",
            run_as_gid: "1000",
        })
        .unwrap();
        let hooks_dir = chroot_root.path().join("root/.copilot/hooks");

        fs::create_dir_all(&hooks_dir).unwrap();
        fs::write(hooks_dir.join("stale.txt"), "stale\n").unwrap();

        sync_remote_home_config(&config).unwrap();

        assert_eq!(
            fs::read_link(&hooks_dir).unwrap(),
            PathBuf::from(CHROOT_COPILOT_HOOKS_DIR)
        );
        assert_eq!(
            fs::read_to_string(chroot_root.path().join("root/.cargo/config.toml")).unwrap(),
            render_remote_cargo_config()
        );
    }
}
