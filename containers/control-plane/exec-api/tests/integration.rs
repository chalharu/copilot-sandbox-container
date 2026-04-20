use control_plane_exec_api::{
    ServerConfig, ServerMode, check_health, execute_remote, serve_with_listener,
};
use std::env;
use std::ffi::OsString;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::OnceLock;
use std::time::Duration;
use tempfile::TempDir;
use tokio::net::TcpListener;
use tokio::sync::{Mutex, oneshot};

async fn start_server(
    temp_dir: &TempDir,
    token: &str,
    mode: ServerMode,
) -> (String, oneshot::Sender<()>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("listener should bind");
    let addr = format!(
        "http://{}",
        listener.local_addr().expect("listener address")
    );
    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    let remote_home = temp_dir.path().join("home");
    fs::create_dir_all(&remote_home).expect("home directory");
    let config = ServerConfig {
        port: listener.local_addr().expect("listener address").port(),
        workspace_root: temp_dir.path().to_path_buf(),
        logical_workspace_root: temp_dir.path().to_path_buf(),
        chroot_root: None,
        environment_mount_path: None,
        git_hooks_source: None,
        remote_home,
        git_user_name: None,
        git_user_email: None,
        startup_script: None,
        mode,
        exec_api_token: token.to_owned(),
        exec_timeout: Duration::from_secs(5),
        run_as_uid: unsafe { libc::geteuid() },
        run_as_gid: unsafe { libc::getegid() },
    };

    tokio::spawn(async move {
        serve_with_listener(listener, config, async {
            let _ = shutdown_rx.await;
        })
        .await
        .expect("server should run");
    });

    (addr, shutdown_tx)
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

fn write_executable(file_path: &Path, content: &str) {
    fs::write(file_path, content).expect("executable content");
    let mut permissions = fs::metadata(file_path)
        .expect("executable metadata")
        .permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(file_path, permissions).expect("executable permissions");
}

#[tokio::test(flavor = "multi_thread")]
async fn exec_api_rejects_requests_without_the_session_token_and_runs_authorized_commands() {
    let _env_lock = env_lock().lock().await;
    let workspace_dir = TempDir::new().expect("workspace directory");
    let exec_token = "test-exec-token";
    let (addr, shutdown_tx) = start_server(&workspace_dir, exec_token, ServerMode::Exec).await;

    check_health(&addr, Duration::from_secs(5))
        .await
        .expect("health check should pass");

    let denied = execute_remote(
        &addr,
        Duration::from_secs(5),
        "",
        workspace_dir.path().to_str().expect("workspace path"),
        "printf denied",
    )
    .await
    .expect_err("request without token should fail");
    assert!(
        denied
            .to_string()
            .contains("missing or invalid exec API token"),
        "unexpected permission error: {denied}"
    );

    let allowed = execute_remote(
        &addr,
        Duration::from_secs(5),
        exec_token,
        workspace_dir.path().to_str().expect("workspace path"),
        "printf 'api stdout\\n'; printf 'api stderr\\n' >&2; printf ok > api-marker.txt",
    )
    .await
    .expect("authorized request should succeed");
    assert_eq!(
        allowed.stdout,
        "$ printf 'api stdout\\n'; printf 'api stderr\\n' >&2; printf ok > api-marker.txt\napi stdout\n"
    );
    assert_eq!(allowed.stderr, "api stderr\n");
    assert_eq!(allowed.exit_code, 0);
    assert_eq!(
        std::fs::read_to_string(workspace_dir.path().join("api-marker.txt")).expect("marker file"),
        "ok"
    );

    shutdown_tx.send(()).expect("shutdown should succeed");
}

#[tokio::test(flavor = "multi_thread")]
async fn post_tool_use_mode_runs_bundled_hook_from_remote_home() {
    let _env_lock = env_lock().lock().await;
    let workspace_dir = TempDir::new().expect("workspace directory");
    let exec_token = "post-tool-use-token";
    let hook_dir = workspace_dir.path().join("home/.copilot/hooks/postToolUse");
    let hook_input_path = workspace_dir.path().join("hook-input.json");
    fs::create_dir_all(&hook_dir).expect("hook directory");
    let hook_script = hook_dir.join("main");
    fs::write(
        &hook_script,
        format!(
            "#!/usr/bin/env bash\nset -euo pipefail\ncat > {}\nprintf 'hook-stdout\\n'\nprintf 'hook-stderr\\n' >&2\nexit 7\n",
            hook_input_path.display()
        ),
    )
    .expect("hook script");
    let mut permissions = fs::metadata(&hook_script)
        .expect("hook metadata")
        .permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&hook_script, permissions).expect("hook permissions");

    let (addr, shutdown_tx) =
        start_server(&workspace_dir, exec_token, ServerMode::PostToolUse).await;

    check_health(&addr, Duration::from_secs(5))
        .await
        .expect("health check should pass");

    let raw_input = format!(
        r#"{{"cwd":"{}","toolResult":{{"resultType":"success"}}}}"#,
        workspace_dir.path().display()
    );
    let result = execute_remote(
        &addr,
        Duration::from_secs(5),
        exec_token,
        workspace_dir.path().to_str().expect("workspace path"),
        &raw_input,
    )
    .await
    .expect("postToolUse request should succeed");

    assert_eq!(result.stdout, "hook-stdout\n");
    assert_eq!(result.stderr, "hook-stderr\n");
    assert_eq!(result.exit_code, 7);
    assert_eq!(
        fs::read_to_string(&hook_input_path).expect("hook input"),
        raw_input
    );

    shutdown_tx.send(()).expect("shutdown should succeed");
}

#[tokio::test(flavor = "multi_thread")]
async fn post_tool_use_mode_preserves_runtime_path_for_hook_commands() {
    let _env_lock = env_lock().lock().await;
    let workspace_dir = TempDir::new().expect("workspace directory");
    let exec_token = "post-tool-use-path-token";
    let hook_dir = workspace_dir.path().join("home/.copilot/hooks/postToolUse");
    let runtime_bin_dir = workspace_dir.path().join("runtime-bin");
    let tool_output_path = workspace_dir.path().join("tool-output.txt");
    fs::create_dir_all(&hook_dir).expect("hook directory");
    fs::create_dir_all(&runtime_bin_dir).expect("runtime bin directory");
    write_executable(
        &runtime_bin_dir.join("runtime-path-tool"),
        "#!/bin/sh\nset -eu\nprintf 'runtime-path-ok\\n'\n",
    );
    let hook_script = hook_dir.join("main");
    write_executable(
        &hook_script,
        &format!(
            "#!/bin/sh\nset -eu\nruntime-path-tool > {}\n",
            tool_output_path.display()
        ),
    );
    let runtime_path = format!("{}:/usr/bin:/bin", runtime_bin_dir.display());
    let _path = ScopedEnvVar::set("PATH", Some(&runtime_path));

    let (addr, shutdown_tx) =
        start_server(&workspace_dir, exec_token, ServerMode::PostToolUse).await;

    check_health(&addr, Duration::from_secs(5))
        .await
        .expect("health check should pass");

    let raw_input = format!(
        r#"{{"cwd":"{}","toolResult":{{"resultType":"success"}}}}"#,
        workspace_dir.path().display()
    );
    let result = execute_remote(
        &addr,
        Duration::from_secs(5),
        exec_token,
        workspace_dir.path().to_str().expect("workspace path"),
        &raw_input,
    )
    .await
    .expect("postToolUse request should succeed");

    assert_eq!(result.stdout, "");
    assert_eq!(result.stderr, "");
    assert_eq!(result.exit_code, 0);
    assert_eq!(
        fs::read_to_string(&tool_output_path).expect("tool output"),
        "runtime-path-ok\n"
    );

    shutdown_tx.send(()).expect("shutdown should succeed");
}
