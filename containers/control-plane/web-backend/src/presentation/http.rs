use crate::application::use_cases::SubmitPromptUseCase;
use axum::Json;
use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, get_service, post, put};
use axum::{Router, serve};
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Write;
use std::net::SocketAddr;
use std::path::{Path as FsPath, PathBuf};
use std::process::{Command, Output, Stdio};
use tower_http::services::{ServeDir, ServeFile};

#[derive(Clone)]
pub struct HttpState {
    submit_prompt: SubmitPromptUseCase,
    assets_dir: PathBuf,
    job_transfer_root: PathBuf,
}

impl HttpState {
    pub fn new(
        submit_prompt: SubmitPromptUseCase,
        assets_dir: PathBuf,
        job_transfer_root: PathBuf,
    ) -> Self {
        Self {
            submit_prompt,
            assets_dir,
            job_transfer_root,
        }
    }
}

#[derive(Deserialize)]
struct ChatRequest {
    prompt: String,
}

#[derive(Serialize)]
struct ChatResponse {
    response: String,
}

#[derive(Deserialize)]
struct TransferManifest {
    transfer_token: String,
    input_root: String,
    output_root: String,
    control_plane_pod_name: Option<String>,
    control_plane_pod_namespace: Option<String>,
}

pub async fn serve_http(state: HttpState, web_port: u16) -> Result<(), String> {
    let assets_dir = state.assets_dir.clone();
    let index_path = assets_dir.join("index.html");
    let router = Router::new()
        .route("/healthz", get(healthz))
        .route("/api/healthz", get(healthz))
        .route("/api/chat", post(chat))
        .route(
            "/api/transfers/{transfer_id}/input.tar",
            get(download_transfer_input),
        )
        .route(
            "/api/transfers/{transfer_id}/output.tar",
            put(upload_transfer_output),
        )
        .route(
            "/api/transfers/{transfer_id}/finalize",
            post(finalize_transfer),
        )
        .route(
            "/api/transfers/{transfer_id}/release",
            post(release_transfer),
        )
        .fallback_service(get_service(
            ServeDir::new(assets_dir).not_found_service(ServeFile::new(index_path)),
        ))
        .with_state(state);
    let bind_addr = SocketAddr::from(([0, 0, 0, 0], web_port));
    let listener = tokio::net::TcpListener::bind(bind_addr)
        .await
        .map_err(|error| format!("failed to bind {bind_addr}: {error}"))?;
    serve(listener, router)
        .await
        .map_err(|error| format!("web server failed: {error}"))
}

async fn healthz() -> impl IntoResponse {
    StatusCode::OK
}

async fn chat(State(state): State<HttpState>, Json(request): Json<ChatRequest>) -> Response {
    match state.submit_prompt.execute(request.prompt).await {
        Ok(response) => (
            StatusCode::OK,
            Json(ChatResponse {
                response: response.text,
            }),
        )
            .into_response(),
        Err(error) => error_response(StatusCode::BAD_REQUEST, error),
    }
}

async fn download_transfer_input(
    State(state): State<HttpState>,
    Path(transfer_id): Path<String>,
    headers: HeaderMap,
) -> Response {
    match tokio::task::spawn_blocking(move || {
        let manifest = read_transfer_manifest(&state, &transfer_id)?;
        authorize_transfer(&manifest, &headers)?;
        let payload = archive_directory(resolve_transfer_path(
            &state.job_transfer_root,
            &transfer_id,
            &manifest.input_root,
        )?)?;
        Ok::<_, String>(payload)
    })
    .await
    {
        Ok(Ok(payload)) => {
            let mut response = Response::new(payload.into());
            response.headers_mut().insert(
                axum::http::header::CONTENT_TYPE,
                HeaderValue::from_static("application/x-tar"),
            );
            response
        }
        Ok(Err(error)) => error_response(StatusCode::BAD_REQUEST, error),
        Err(error) => error_response(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("failed to join transfer worker: {error}"),
        ),
    }
}

async fn upload_transfer_output(
    State(state): State<HttpState>,
    Path(transfer_id): Path<String>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    match tokio::task::spawn_blocking(move || {
        let manifest = read_transfer_manifest(&state, &transfer_id)?;
        authorize_transfer(&manifest, &headers)?;
        let output_root = resolve_transfer_path(
            &state.job_transfer_root,
            &transfer_id,
            &manifest.output_root,
        )?;
        extract_archive(&output_root, &body)?;
        Ok::<_, String>(())
    })
    .await
    {
        Ok(Ok(())) => StatusCode::NO_CONTENT.into_response(),
        Ok(Err(error)) => error_response(StatusCode::BAD_REQUEST, error),
        Err(error) => error_response(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("failed to join transfer worker: {error}"),
        ),
    }
}

async fn finalize_transfer(
    State(state): State<HttpState>,
    Path(transfer_id): Path<String>,
    headers: HeaderMap,
) -> Response {
    run_transfer_helper(state, transfer_id, headers, "finalize", StatusCode::OK).await
}

async fn release_transfer(
    State(state): State<HttpState>,
    Path(transfer_id): Path<String>,
    headers: HeaderMap,
) -> Response {
    run_transfer_helper(
        state,
        transfer_id,
        headers,
        "release-access",
        StatusCode::NO_CONTENT,
    )
    .await
}

async fn run_transfer_helper(
    state: HttpState,
    transfer_id: String,
    headers: HeaderMap,
    subcommand: &'static str,
    success_status: StatusCode,
) -> Response {
    match tokio::task::spawn_blocking(move || {
        let manifest = read_transfer_manifest(&state, &transfer_id)?;
        authorize_transfer(&manifest, &headers)?;
        let output = transfer_helper_command(&manifest, subcommand, &transfer_id)
            .output()
            .map_err(|error| format!("failed to start transfer helper: {error}"))?;
        forward_transfer_helper_output(&output)?;
        if output.status.success() {
            Ok::<_, String>(())
        } else {
            Err(render_transfer_helper_failure(subcommand, &output))
        }
    })
    .await
    {
        Ok(Ok(())) => success_status.into_response(),
        Ok(Err(error)) => error_response(StatusCode::BAD_REQUEST, error),
        Err(error) => error_response(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("failed to join transfer helper: {error}"),
        ),
    }
}

fn forward_transfer_helper_output(output: &Output) -> Result<(), String> {
    if !output.stdout.is_empty() {
        let mut stdout = std::io::stdout();
        stdout
            .write_all(&output.stdout)
            .map_err(|error| format!("failed to forward transfer helper stdout: {error}"))?;
        stdout
            .flush()
            .map_err(|error| format!("failed to flush transfer helper stdout: {error}"))?;
    }
    if !output.stderr.is_empty() {
        let mut stderr = std::io::stderr();
        stderr
            .write_all(&output.stderr)
            .map_err(|error| format!("failed to forward transfer helper stderr: {error}"))?;
        stderr
            .flush()
            .map_err(|error| format!("failed to flush transfer helper stderr: {error}"))?;
    }
    Ok(())
}

fn render_transfer_helper_failure(subcommand: &str, output: &Output) -> String {
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if !stderr.is_empty() {
        format!(
            "transfer helper {subcommand} exited with {}: {stderr}",
            output.status
        )
    } else if !stdout.is_empty() {
        format!(
            "transfer helper {subcommand} exited with {}: {stdout}",
            output.status
        )
    } else {
        format!("transfer helper {subcommand} exited with {}", output.status)
    }
}

fn transfer_helper_command(
    manifest: &TransferManifest,
    subcommand: &'static str,
    transfer_id: &str,
) -> Command {
    let control_plane_pod_name = manifest
        .control_plane_pod_name
        .as_deref()
        .filter(|value| !value.is_empty());
    let control_plane_pod_namespace = manifest
        .control_plane_pod_namespace
        .as_deref()
        .filter(|value| !value.is_empty());

    if let (Some(pod_name), Some(namespace)) = (control_plane_pod_name, control_plane_pod_namespace)
    {
        let mut command = Command::new("kubectl");
        command
            .arg("exec")
            .arg("--namespace")
            .arg(namespace)
            .arg(pod_name)
            .arg("-c")
            .arg("control-plane")
            .arg("--")
            .arg("control-plane-job-transfer");
        command
            .arg(subcommand)
            .arg("--transfer-id")
            .arg(transfer_id);
        return command;
    }

    let mut command = Command::new("control-plane-job-transfer");
    command
        .arg(subcommand)
        .arg("--transfer-id")
        .arg(transfer_id);
    command
}

fn error_response(status: StatusCode, message: String) -> Response {
    (status, message).into_response()
}

fn read_transfer_manifest(
    state: &HttpState,
    transfer_id: &str,
) -> Result<TransferManifest, String> {
    let manifest_path = state
        .job_transfer_root
        .join(transfer_id)
        .join("manifest.json");
    let contents = fs::read_to_string(&manifest_path).map_err(|error| {
        format!(
            "failed to read transfer manifest {}: {error}",
            manifest_path.display()
        )
    })?;
    serde_json::from_str(&contents).map_err(|error| {
        format!(
            "failed to parse transfer manifest {}: {error}",
            manifest_path.display()
        )
    })
}

fn authorize_transfer(manifest: &TransferManifest, headers: &HeaderMap) -> Result<(), String> {
    let Some(value) = headers.get(axum::http::header::AUTHORIZATION) else {
        return Err(String::from("missing Authorization header"));
    };
    let value = value
        .to_str()
        .map_err(|error| format!("invalid Authorization header: {error}"))?;
    let expected = format!("Bearer {}", manifest.transfer_token);
    if value == expected {
        Ok(())
    } else {
        Err(String::from("invalid transfer token"))
    }
}

fn resolve_transfer_path(
    root_dir: &FsPath,
    transfer_id: &str,
    manifest_path: &str,
) -> Result<PathBuf, String> {
    let base_dir = root_dir.join(transfer_id).canonicalize().map_err(|error| {
        format!(
            "failed to resolve transfer root {}/{}: {error}",
            root_dir.display(),
            transfer_id
        )
    })?;
    let candidate = PathBuf::from(manifest_path)
        .canonicalize()
        .map_err(|error| format!("failed to resolve transfer path {manifest_path}: {error}"))?;
    if candidate.starts_with(&base_dir) {
        Ok(candidate)
    } else {
        Err(format!(
            "refusing to access transfer path outside {}: {}",
            base_dir.display(),
            candidate.display()
        ))
    }
}

fn archive_directory(source_dir: PathBuf) -> Result<Vec<u8>, String> {
    let output = Command::new("tar")
        .arg("cf")
        .arg("-")
        .arg(".")
        .current_dir(&source_dir)
        .output()
        .map_err(|error| format!("failed to archive {}: {error}", source_dir.display()))?;
    if output.status.success() {
        Ok(output.stdout)
    } else {
        Err(format!(
            "tar failed while archiving {}: {}",
            source_dir.display(),
            String::from_utf8_lossy(&output.stderr)
        ))
    }
}

fn extract_archive(target_dir: &FsPath, archive: &[u8]) -> Result<(), String> {
    if target_dir.exists() {
        fs::remove_dir_all(target_dir)
            .map_err(|error| format!("failed to reset {}: {error}", target_dir.display()))?;
    }
    fs::create_dir_all(target_dir)
        .map_err(|error| format!("failed to create {}: {error}", target_dir.display()))?;
    let mut child = Command::new("tar")
        .arg("xf")
        .arg("-")
        .current_dir(target_dir)
        .stdin(Stdio::piped())
        .spawn()
        .map_err(|error| {
            format!(
                "failed to start tar extract into {}: {error}",
                target_dir.display()
            )
        })?;
    let Some(stdin) = child.stdin.as_mut() else {
        return Err(String::from("tar extractor did not expose stdin"));
    };
    stdin
        .write_all(archive)
        .map_err(|error| format!("failed to write tar archive: {error}"))?;
    let status = child
        .wait()
        .map_err(|error| format!("failed to wait for tar extract: {error}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!(
            "tar failed while extracting into {} with status {status}",
            target_dir.display()
        ))
    }
}
