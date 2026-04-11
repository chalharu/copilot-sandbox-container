use crate::application::ports::PromptGateway;
use crate::domain::chat::{PromptInput, PromptOutput};
use agent_client_protocol::{self as acp, Agent as _};
use async_trait::async_trait;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::Mutex;
use tokio_util::compat::{TokioAsyncReadCompatExt, TokioAsyncWriteCompatExt};

#[derive(Clone)]
pub struct TcpAcpPromptGateway {
    acp_addr: String,
    workspace_root: PathBuf,
}

impl TcpAcpPromptGateway {
    pub fn new(acp_addr: String, workspace_root: PathBuf) -> Self {
        Self {
            acp_addr,
            workspace_root,
        }
    }
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

#[async_trait]
impl PromptGateway for TcpAcpPromptGateway {
    async fn prompt(&self, input: PromptInput) -> Result<PromptOutput, String> {
        let acp_addr = self.acp_addr.clone();
        let workspace_root = self.workspace_root.clone();
        let prompt = input.text().to_string();
        tokio::task::spawn_blocking(move || run_prompt(acp_addr, workspace_root, prompt))
            .await
            .map_err(|error| format!("failed to join ACP worker: {error}"))?
    }
}

fn run_prompt(
    acp_addr: String,
    workspace_root: PathBuf,
    prompt: String,
) -> Result<PromptOutput, String> {
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
                            acp::Implementation::new("control-plane-web-backend", "0.1.0")
                                .title("Control Plane Web Backend"),
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
                        vec![prompt.into()],
                    ))
                    .await
                    .map_err(|error| format!("ACP prompt failed: {error}"))?;
                Ok(PromptOutput {
                    text: collector_handle.finish().await,
                })
            })
            .await
    })
}
