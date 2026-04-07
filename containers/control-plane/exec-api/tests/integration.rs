use control_plane_exec_api::{ServerConfig, check_health, execute_remote, serve_with_listener};
use std::time::Duration;
use tempfile::TempDir;
use tokio::net::TcpListener;
use tokio::sync::oneshot;

async fn start_server(temp_dir: &TempDir, token: &str) -> (String, oneshot::Sender<()>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("listener should bind");
    let addr = format!(
        "http://{}",
        listener.local_addr().expect("listener address")
    );
    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    let config = ServerConfig {
        port: listener.local_addr().expect("listener address").port(),
        workspace_root: temp_dir.path().to_path_buf(),
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

#[tokio::test(flavor = "multi_thread")]
async fn exec_api_rejects_requests_without_the_session_token_and_runs_authorized_commands() {
    let workspace_dir = TempDir::new().expect("workspace directory");
    let exec_token = "test-exec-token";
    let (addr, shutdown_tx) = start_server(&workspace_dir, exec_token).await;

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
    assert_eq!(allowed.stdout, "api stdout\n");
    assert_eq!(allowed.stderr, "api stderr\n");
    assert_eq!(allowed.exit_code, 0);
    assert_eq!(
        std::fs::read_to_string(workspace_dir.path().join("api-marker.txt")).expect("marker file"),
        "ok"
    );

    shutdown_tx.send(()).expect("shutdown should succeed");
}
