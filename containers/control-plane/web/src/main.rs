use agent_client_protocol::{self as acp, Agent as _};
use any_spawner::Executor;
use async_trait::async_trait;
use axum::body::Bytes;
use axum::extract::{Form, Path, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode};
use axum::response::{Html, IntoResponse, Response};
use axum::routing::{get, post, put};
use axum::{Router, serve};
use leptos::prelude::*;
use serde::Deserialize;
use std::fs;
use std::io::Write;
use std::net::SocketAddr;
use std::path::{Path as FsPath, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use tokio::sync::Mutex;
use tokio_util::compat::{TokioAsyncReadCompatExt, TokioAsyncWriteCompatExt};

#[derive(Clone)]
struct AppState {
    acp_addr: String,
    workspace_root: PathBuf,
    job_transfer_root: PathBuf,
}

#[derive(Clone, Default)]
struct PromptCollector {
    chunks: Arc<Mutex<Vec<String>>>,
}

impl PromptCollector {
    async fn finish(&self) -> String {
        self.chunks.lock().await.join("")
    }
}

#[async_trait(?Send)]
impl acp::Client for PromptCollector {
    async fn request_permission(
        &self,
        _args: acp::RequestPermissionRequest,
    ) -> acp::Result<acp::RequestPermissionResponse> {
        Err(acp::Error::method_not_found())
    }

    async fn write_text_file(
        &self,
        _args: acp::WriteTextFileRequest,
    ) -> acp::Result<acp::WriteTextFileResponse> {
        Err(acp::Error::method_not_found())
    }

    async fn read_text_file(
        &self,
        _args: acp::ReadTextFileRequest,
    ) -> acp::Result<acp::ReadTextFileResponse> {
        Err(acp::Error::method_not_found())
    }

    async fn create_terminal(
        &self,
        _args: acp::CreateTerminalRequest,
    ) -> acp::Result<acp::CreateTerminalResponse> {
        Err(acp::Error::method_not_found())
    }

    async fn terminal_output(
        &self,
        _args: acp::TerminalOutputRequest,
    ) -> acp::Result<acp::TerminalOutputResponse> {
        Err(acp::Error::method_not_found())
    }

    async fn release_terminal(
        &self,
        _args: acp::ReleaseTerminalRequest,
    ) -> acp::Result<acp::ReleaseTerminalResponse> {
        Err(acp::Error::method_not_found())
    }

    async fn wait_for_terminal_exit(
        &self,
        _args: acp::WaitForTerminalExitRequest,
    ) -> acp::Result<acp::WaitForTerminalExitResponse> {
        Err(acp::Error::method_not_found())
    }

    async fn kill_terminal(
        &self,
        _args: acp::KillTerminalRequest,
    ) -> acp::Result<acp::KillTerminalResponse> {
        Err(acp::Error::method_not_found())
    }

    async fn session_notification(&self, args: acp::SessionNotification) -> acp::Result<()> {
        if let acp::SessionUpdate::AgentMessageChunk(acp::ContentChunk { content, .. }) =
            args.update
        {
            let text = match content {
                acp::ContentBlock::Text(text_content) => text_content.text,
                acp::ContentBlock::Image(_) => "<image>".to_string(),
                acp::ContentBlock::Audio(_) => "<audio>".to_string(),
                acp::ContentBlock::ResourceLink(resource_link) => resource_link.uri,
                acp::ContentBlock::Resource(_) => "<resource>".to_string(),
                _ => String::new(),
            };
            if !text.is_empty() {
                self.chunks.lock().await.push(text);
            }
        }
        Ok(())
    }

    async fn ext_method(&self, _args: acp::ExtRequest) -> acp::Result<acp::ExtResponse> {
        Err(acp::Error::method_not_found())
    }

    async fn ext_notification(&self, _args: acp::ExtNotification) -> acp::Result<()> {
        Ok(())
    }
}

#[derive(Deserialize)]
struct PromptForm {
    prompt: String,
}

#[derive(Deserialize)]
struct TransferManifest {
    transfer_id: String,
    transfer_token: String,
    input_root: String,
    output_root: String,
}

#[component]
fn App(
    prompt: String,
    response: Option<String>,
    error: Option<String>,
    acp_addr: String,
) -> impl IntoView {
    view! {
        <!DOCTYPE html>
        <html lang="en">
            <head>
                <meta charset="utf-8"/>
                <meta name="viewport" content="width=device-width, initial-scale=1"/>
                <title>"Copilot ACP Control Plane"</title>
                <style>{r#"
                    :root { color-scheme: light dark; font-family: system-ui, sans-serif; }
                    body { margin: 0; background: #0f172a; color: #e2e8f0; }
                    main { max-width: 960px; margin: 0 auto; padding: 2rem 1.5rem 3rem; }
                    h1 { margin-bottom: 0.25rem; }
                    p { line-height: 1.6; }
                    form { display: grid; gap: 0.75rem; margin-top: 1.5rem; }
                    textarea { min-height: 12rem; resize: vertical; padding: 0.75rem; font: inherit; border-radius: 0.75rem; border: 1px solid #334155; background: #020617; color: inherit; }
                    button { width: fit-content; padding: 0.75rem 1.25rem; font: inherit; border: 0; border-radius: 999px; background: #2563eb; color: white; cursor: pointer; }
                    .card { margin-top: 1.5rem; padding: 1rem 1.25rem; border-radius: 1rem; background: #111827; border: 1px solid #334155; }
                    .error { border-color: #dc2626; color: #fecaca; }
                    pre { white-space: pre-wrap; word-break: break-word; margin: 0; font: 0.95rem/1.6 ui-monospace, SFMono-Regular, Menlo, monospace; }
                    code { font: 0.95rem ui-monospace, SFMono-Regular, Menlo, monospace; }
                "#}</style>
            </head>
            <body>
                <main>
                    <h1>"Copilot ACP Control Plane"</h1>
                    <p>
                        "This web frontend talks to the control-plane Copilot ACP runtime at "
                        <code>{acp_addr}</code>
                        "."
                    </p>
                    <form method="post" action="/prompt">
                        <label for="prompt">"Prompt"</label>
                        <textarea id="prompt" name="prompt">{prompt}</textarea>
                        <button type="submit">"Send prompt"</button>
                    </form>
                    {move || error.clone().map(|message| {
                        view! {
                            <section class="card error">
                                <h2>"Error"</h2>
                                <pre>{message}</pre>
                            </section>
                        }
                    })}
                    {move || response.clone().map(|content| {
                        view! {
                            <section class="card">
                                <h2>"Response"</h2>
                                <pre>{content}</pre>
                            </section>
                        }
                    })}
                </main>
            </body>
        </html>
    }
}

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
    let state = AppState {
        acp_addr: format!("{acp_host}:{acp_port}"),
        workspace_root,
        job_transfer_root,
    };
    let router = Router::new()
        .route("/", get(index))
        .route("/prompt", post(prompt))
        .route("/healthz", get(healthz))
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
        .with_state(state.clone());
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

async fn index(State(state): State<AppState>) -> Html<String> {
    render_page(String::new(), None, None, &state.acp_addr)
}

async fn prompt(State(state): State<AppState>, Form(form): Form<PromptForm>) -> Response {
    let prompt = form.prompt;
    let acp_addr = state.acp_addr.clone();
    let workspace_root = state.workspace_root.clone();
    let worker_prompt = prompt.clone();
    match tokio::task::spawn_blocking(move || run_prompt(acp_addr, workspace_root, worker_prompt))
        .await
    {
        Ok(Ok((prompt_text, response_text))) => {
            render_page(prompt_text, Some(response_text), None, &state.acp_addr).into_response()
        }
        Ok(Err(error)) => render_page(prompt, None, Some(error), &state.acp_addr).into_response(),
        Err(error) => render_page(
            prompt,
            None,
            Some(format!("failed to join ACP worker: {error}")),
            &state.acp_addr,
        )
        .into_response(),
    }
}

fn run_prompt(
    acp_addr: String,
    workspace_root: PathBuf,
    prompt: String,
) -> Result<(String, String), String> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| format!("failed to start ACP runtime: {error}"))?;
    runtime.block_on(async move {
        let local_set = tokio::task::LocalSet::new();
        local_set
            .run_until(async move {
                let stream = tokio::net::TcpStream::connect(&acp_addr)
                    .await
                    .map_err(|error| {
                        format!("failed to connect to ACP server {acp_addr}: {error}")
                    })?;
                let (reader, writer) = stream.into_split();
                let collector = PromptCollector::default();
                let collector_handle = collector.clone();
                let (connection, handle_io) = acp::ClientSideConnection::new(
                    collector,
                    writer.compat_write(),
                    reader.compat(),
                    |future| {
                        tokio::task::spawn_local(future);
                    },
                );
                tokio::task::spawn_local(handle_io);
                connection
                    .initialize(
                        acp::InitializeRequest::new(acp::ProtocolVersion::V1).client_info(
                            acp::Implementation::new("control-plane-web", "0.1.0")
                                .title("Control Plane Web"),
                        ),
                    )
                    .await
                    .map_err(|error| format!("failed to initialize ACP connection: {error}"))?;
                let session = connection
                    .new_session(acp::NewSessionRequest::new(workspace_root))
                    .await
                    .map_err(|error| format!("failed to create ACP session: {error}"))?;
                connection
                    .prompt(acp::PromptRequest::new(
                        session.session_id,
                        vec![prompt.clone().into()],
                    ))
                    .await
                    .map_err(|error| format!("ACP prompt failed: {error}"))?;
                let response = collector_handle.finish().await;
                Ok((prompt, response))
            })
            .await
    })
}

async fn download_transfer_input(
    State(state): State<AppState>,
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
    State(state): State<AppState>,
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
    State(state): State<AppState>,
    Path(transfer_id): Path<String>,
    headers: HeaderMap,
) -> Response {
    run_transfer_helper(state, transfer_id, headers, "finalize", StatusCode::OK).await
}

async fn release_transfer(
    State(state): State<AppState>,
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
    state: AppState,
    transfer_id: String,
    headers: HeaderMap,
    subcommand: &'static str,
    success_status: StatusCode,
) -> Response {
    match tokio::task::spawn_blocking(move || {
        let manifest = read_transfer_manifest(&state, &transfer_id)?;
        authorize_transfer(&manifest, &headers)?;
        let status = Command::new("control-plane-job-transfer")
            .arg(subcommand)
            .arg("--transfer-id")
            .arg(&transfer_id)
            .status()
            .map_err(|error| format!("failed to start control-plane-job-transfer: {error}"))?;
        if status.success() {
            Ok::<_, String>(())
        } else {
            Err(format!(
                "control-plane-job-transfer {subcommand} exited with {status}"
            ))
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

fn render_page(
    prompt: String,
    response: Option<String>,
    error: Option<String>,
    acp_addr: &str,
) -> Html<String> {
    let _ = Executor::init_tokio();
    let owner = Owner::new();
    owner.set();
    let app = view! {
        <App
            prompt=prompt
            response=response
            error=error
            acp_addr=acp_addr.to_string()
        />
    };
    Html(app.to_html())
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

fn error_response(status: StatusCode, message: String) -> Response {
    (status, message).into_response()
}

fn read_transfer_manifest(state: &AppState, transfer_id: &str) -> Result<TransferManifest, String> {
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
    let manifest: TransferManifest = serde_json::from_str(&contents).map_err(|error| {
        format!(
            "failed to parse transfer manifest {}: {error}",
            manifest_path.display()
        )
    })?;
    if manifest.transfer_id != transfer_id {
        return Err(format!(
            "transfer manifest {} does not match requested transfer id {transfer_id}",
            manifest.transfer_id
        ));
    }
    Ok(manifest)
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
    transfer_root: &FsPath,
    transfer_id: &str,
    manifest_path: &str,
) -> Result<PathBuf, String> {
    let base_dir = transfer_root.join(transfer_id);
    let base_dir = base_dir.canonicalize().map_err(|error| {
        format!(
            "failed to resolve transfer directory {}: {error}",
            base_dir.display()
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
