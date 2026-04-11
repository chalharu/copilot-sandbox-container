use control_plane_web_backend::application::use_cases::SubmitPromptUseCase;
use control_plane_web_backend::infrastructure::acp_gateway::TcpAcpPromptGateway;
use control_plane_web_backend::presentation::http::{HttpState, serve_http};
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;

#[tokio::main(flavor = "multi_thread")]
async fn main() -> Result<(), String> {
    let web_port = parse_port("CONTROL_PLANE_WEB_PORT", 8080)?;
    let acp_port = parse_port("CONTROL_PLANE_ACP_PORT", 3000)?;
    let acp_host =
        non_empty_env("CONTROL_PLANE_ACP_HOST").unwrap_or_else(|| "127.0.0.1".to_string());
    let workspace_root = PathBuf::from(
        non_empty_env("CONTROL_PLANE_WEB_WORKSPACE")
            .unwrap_or_else(|| env_or_default("CONTROL_PLANE_WORKSPACE", "/workspace")),
    );
    let assets_dir = PathBuf::from(env_or_default(
        "CONTROL_PLANE_WEB_ASSETS_DIR",
        "/usr/local/share/control-plane/web-frontend",
    ));
    let index_path = assets_dir.join("index.html");
    if !index_path.is_file() {
        return Err(format!(
            "missing frontend assets at {}",
            index_path.display()
        ));
    }
    let job_transfer_root = PathBuf::from(
        non_empty_env("CONTROL_PLANE_JOB_TRANSFER_ROOT").unwrap_or_else(|| {
            env_or_default(
                "CONTROL_PLANE_JOB_TRANSFER_ROOT",
                "/home/copilot/.copilot/session-state/job-transfers",
            )
        }),
    );
    fs::create_dir_all(&job_transfer_root).map_err(|error| {
        format!(
            "failed to create job transfer root {}: {error}",
            job_transfer_root.display()
        )
    })?;

    let gateway = Arc::new(TcpAcpPromptGateway::new(
        format!("{acp_host}:{acp_port}"),
        workspace_root,
    ));
    let state = HttpState::new(
        SubmitPromptUseCase::new(gateway),
        assets_dir,
        job_transfer_root,
    );
    serve_http(state, web_port).await
}

fn parse_port(name: &str, default: u16) -> Result<u16, String> {
    match std::env::var(name) {
        Ok(raw) => raw
            .parse::<u16>()
            .map_err(|error| format!("{name} must be a valid TCP port: {error}")),
        Err(_) => Ok(default),
    }
}

fn env_or_default(name: &str, default: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| default.to_string())
}

fn non_empty_env(name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .filter(|value| !value.trim().is_empty())
}
