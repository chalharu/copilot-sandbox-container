use nix::mount::{MsFlags, mount};
use nix::unistd::{Gid, Uid, chdir, chown, chroot, setgid, setuid};
use serde::{Deserialize, Serialize};
use std::env;
use std::ffi::OsString;
use std::fs;
use std::future::Future;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Component, Path, PathBuf};
use std::process::{Command as StdCommand, Stdio};
use std::time::Duration;
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
const CHROOT_GIT_HOOKS_DIR: &str = "/usr/local/share/control-plane/hooks/git";
const CHROOT_EXEC_POLICY_LIBRARY_PATH: &str = "/usr/local/lib/libcontrol_plane_exec_policy.so";
const CHROOT_EXEC_POLICY_RULES_PATH: &str =
    "/usr/local/share/control-plane/hooks/preToolUse/deny-rules.yaml";

pub type DynError = Box<dyn std::error::Error + Send + Sync>;

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

#[derive(Clone, Debug)]
struct ExecApiService {
    workspace_root: PathBuf,
    logical_workspace_root: PathBuf,
    chroot_root: Option<PathBuf>,
    remote_home: PathBuf,
    expected_exec_api_token: MetadataValue<Ascii>,
    exec_timeout: Duration,
    run_as_uid: u32,
    run_as_gid: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ResolvedCwd {
    host: PathBuf,
    logical: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct RemoteHomePaths {
    home_dir: PathBuf,
    config_dir: PathBuf,
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
        Self {
            workspace_root: config.workspace_root.clone(),
            logical_workspace_root: config.logical_workspace_root.clone(),
            chroot_root: config.chroot_root.clone(),
            remote_home: config.remote_home.clone(),
            expected_exec_api_token: parse_exec_api_token(&config.exec_api_token)
                .expect("CONTROL_PLANE_EXEC_API_TOKEN should be validated before serving"),
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
        validate_token(request.metadata(), &self.expected_exec_api_token).map_err(Status::from)?;

        let request = request.into_inner();
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
        let result = run_shell_command(
            &request.command,
            &cwd,
            self.exec_timeout,
            self.run_as_uid,
            self.run_as_gid,
            self.chroot_root.as_deref(),
            &self.remote_home,
        )
        .await?;

        Ok(Response::new(proto::ExecuteResponse {
            stdout: result.stdout,
            stderr: result.stderr,
            exit_code: result.exit_code,
        }))
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
        config.logical_workspace_root.display()
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
        let marker_path = bootstrap_marker_path(chroot_root);
        with_context(fs::write(&marker_path, b"ready\n"), || {
            format!("failed to write bootstrap marker {}", marker_path.display())
        })?;
    }
    sync_git_hooks_into_chroot(config).map_err(|error| {
        format!(
            "failed to sync git hooks into {}: {error}",
            chroot_root.display()
        )
    })?;
    sync_git_config(config).map_err(|error| {
        format!(
            "failed to sync git config into {}: {error}",
            chroot_root.display()
        )
    })?;
    Ok(())
}

fn bootstrap_marker_path(chroot_root: &Path) -> PathBuf {
    chroot_root.join(".control-plane-ready")
}

fn seed_chroot_root(chroot_root: &Path, config: &ServerConfig) -> Result<(), DynError> {
    with_context(fs::create_dir_all(chroot_root), || {
        format!("failed to create bootstrap root {}", chroot_root.display())
    })?;
    copy_rootfs(chroot_root, config).map_err(|error| {
        format!(
            "failed to seed execution rootfs into {}: {error}",
            chroot_root.display()
        )
    })?;
    Ok(())
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
        // PVC-backed paths can reject restoring source owners, modes, or mtimes.
        // The chroot only needs a runnable filesystem; required runtime paths are
        // normalized explicitly after extraction.
        .arg("--no-same-owner")
        .arg("--no-same-permissions")
        .arg("--no-overwrite-dir")
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
    Ok(())
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
        run_in_chroot(
            chroot_root,
            &apk_path,
            &[
                OsString::from("add"),
                OsString::from("--no-cache"),
                OsString::from("bash"),
                OsString::from("git"),
                OsString::from("github-cli"),
                OsString::from("ca-certificates"),
                OsString::from("openssh-client"),
            ],
            &[],
        )?;
        return Ok(());
    }

    if let Some(apt_get_path) =
        resolve_chroot_command(chroot_root, &["/usr/bin/apt-get", "/bin/apt-get"])
    {
        let noninteractive = [(
            OsString::from("DEBIAN_FRONTEND"),
            OsString::from("noninteractive"),
        )];
        run_in_chroot(
            chroot_root,
            &apt_get_path,
            &[
                OsString::from("update"),
                OsString::from("-o"),
                OsString::from("Acquire::Retries=3"),
            ],
            &noninteractive,
        )?;
        run_in_chroot(
            chroot_root,
            &apt_get_path,
            &[
                OsString::from("install"),
                OsString::from("-y"),
                OsString::from("--no-install-recommends"),
                OsString::from("bash"),
                OsString::from("ca-certificates"),
                OsString::from("git"),
                OsString::from("gh"),
                OsString::from("openssh-client"),
            ],
            &noninteractive,
        )?;
        return Ok(());
    }

    Err(io::Error::other("unsupported execution image package manager: need apk or apt-get").into())
}

fn required_commands_present(chroot_root: &Path) -> bool {
    ["/bin/bash", "/usr/bin/git", "/usr/bin/gh", "/usr/bin/ssh"]
        .iter()
        .all(|candidate| resolve_chroot_command(chroot_root, &[*candidate]).is_some())
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

fn sync_git_config(config: &ServerConfig) -> Result<(), DynError> {
    let Some(chroot_root) = config.chroot_root.as_deref() else {
        return Ok(());
    };

    let paths = resolve_remote_home_paths(chroot_root, &config.remote_home)?;
    ensure_remote_home_dirs(&paths)?;
    prepare_remote_home_for_update(&paths)?;
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
    set_path_mode(&paths.gitconfig_path, 0o600, "remote git config")?;
    assign_remote_home_owner(&paths, config.run_as_uid, config.run_as_gid)?;
    Ok(())
}

fn resolve_remote_home_paths(
    chroot_root: &Path,
    remote_home: &Path,
) -> Result<RemoteHomePaths, DynError> {
    let home_dir = nested_absolute_path(chroot_root, remote_home)?;
    let config_dir = home_dir.join(".config");
    let gitconfig_path = home_dir.join(".gitconfig");
    Ok(RemoteHomePaths {
        home_dir,
        config_dir,
        gitconfig_path,
    })
}

fn ensure_remote_home_dirs(paths: &RemoteHomePaths) -> Result<(), DynError> {
    with_context(fs::create_dir_all(&paths.config_dir), || {
        format!(
            "failed to create remote config directory {}",
            paths.config_dir.display()
        )
    })?;
    Ok(())
}

fn prepare_remote_home_for_update(paths: &RemoteHomePaths) -> Result<(), DynError> {
    for path in [&paths.home_dir, &paths.config_dir] {
        set_path_owner(path, 0, 0, "remote home path")?;
    }
    if paths.gitconfig_path.exists() {
        set_path_owner(&paths.gitconfig_path, 0, 0, "remote git config")?;
    }
    set_path_mode(&paths.home_dir, 0o700, "remote home")?;
    set_path_mode(&paths.config_dir, 0o700, "remote config directory")?;
    Ok(())
}

fn assign_remote_home_owner(paths: &RemoteHomePaths, uid: u32, gid: u32) -> Result<(), DynError> {
    for (path, description) in [
        (&paths.home_dir, "remote home"),
        (&paths.config_dir, "remote config directory"),
        (&paths.gitconfig_path, "remote git config"),
    ] {
        set_path_owner(path, uid, gid, description)?;
    }
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

fn managed_shell_environment(remote_home: &Path, chrooted: bool) -> Vec<(&'static str, OsString)> {
    let mut env = vec![
        ("PATH", OsString::from(DEFAULT_EXEC_PATH)),
        ("HOME", remote_home.as_os_str().to_os_string()),
        (
            "GIT_CONFIG_GLOBAL",
            remote_home.join(".gitconfig").into_os_string(),
        ),
    ];
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
        CHROOT_EXEC_POLICY_LIBRARY_PATH, CHROOT_EXEC_POLICY_RULES_PATH, DEFAULT_EXEC_PATH,
        build_rootfs_extract_command, build_server_config, ensure_runtime_dirs,
        managed_shell_environment, normalize_path, render_remote_git_config, resolve_cwd,
        sync_git_config,
    };
    use crate::RawServerConfig;
    use std::ffi::OsString;
    use std::fs;
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
        let env = managed_shell_environment(Path::new("/root"), true);
        assert_eq!(
            env,
            vec![
                ("PATH", OsString::from(DEFAULT_EXEC_PATH)),
                ("HOME", OsString::from("/root")),
                ("GIT_CONFIG_GLOBAL", OsString::from("/root/.gitconfig")),
                (
                    "LD_PRELOAD",
                    OsString::from(CHROOT_EXEC_POLICY_LIBRARY_PATH),
                ),
                (
                    "CONTROL_PLANE_EXEC_POLICY_RULES_FILE",
                    OsString::from(CHROOT_EXEC_POLICY_RULES_PATH),
                ),
            ]
        );
    }

    #[test]
    fn managed_shell_environment_skips_exec_policy_without_chroot() {
        let env = managed_shell_environment(Path::new("/root"), false);
        assert_eq!(
            env,
            vec![
                ("PATH", OsString::from(DEFAULT_EXEC_PATH)),
                ("HOME", OsString::from("/root")),
                ("GIT_CONFIG_GLOBAL", OsString::from("/root/.gitconfig")),
            ]
        );
    }

    #[test]
    fn rootfs_extract_command_skips_preserving_host_metadata() {
        let command = build_rootfs_extract_command(Path::new("/environment/root"));
        let args = command.get_args().map(OsString::from).collect::<Vec<_>>();

        assert_eq!(
            args,
            vec![
                OsString::from("xmf"),
                OsString::from("-"),
                OsString::from("--no-same-owner"),
                OsString::from("--no-same-permissions"),
                OsString::from("--no-overwrite-dir"),
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
    }

    #[test]
    fn parse_mountinfo_mount_point_decodes_escaped_paths() {
        let line = "29 23 0:26 / /environment/root\\040with\\040spaces rw,nosuid - tmpfs tmpfs rw";

        assert_eq!(
            super::parse_mountinfo_mount_point(line).as_deref(),
            Some("/environment/root with spaces")
        );
    }

    #[cfg(unix)]
    #[test]
    fn sync_git_config_handles_reused_runtime_owned_home() {
        use nix::unistd::{Gid, Uid, chown};
        use std::os::unix::fs::{MetadataExt, PermissionsExt};

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
            exec_api_token: String::from("token"),
            timeout_sec: "3600",
            run_as_uid: "1000",
            run_as_gid: "1000",
        })
        .unwrap();
        let home_dir = chroot_root.path().join("root");
        let config_dir = home_dir.join(".config");
        let gitconfig_path = home_dir.join(".gitconfig");

        fs::create_dir_all(&config_dir).unwrap();
        fs::write(&gitconfig_path, "stale\n").unwrap();
        chown(
            &home_dir,
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
            &gitconfig_path,
            Some(Uid::from_raw(1000)),
            Some(Gid::from_raw(1000)),
        )
        .unwrap();

        sync_git_config(&config).unwrap();

        let home_metadata = fs::metadata(&home_dir).unwrap();
        let config_metadata = fs::metadata(&config_dir).unwrap();
        let gitconfig_metadata = fs::metadata(&gitconfig_path).unwrap();
        assert_eq!(home_metadata.uid(), 1000);
        assert_eq!(config_metadata.uid(), 1000);
        assert_eq!(gitconfig_metadata.uid(), 1000);
        assert_eq!(home_metadata.permissions().mode() & 0o777, 0o700);
        assert_eq!(config_metadata.permissions().mode() & 0o777, 0o700);
        assert_eq!(gitconfig_metadata.permissions().mode() & 0o777, 0o600);
    }
}
