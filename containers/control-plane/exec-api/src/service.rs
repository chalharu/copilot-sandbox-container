use serde::Serialize;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use tonic::metadata::{Ascii, MetadataValue};
use tonic::{Request, Response, Status};

use crate::command::{ExecResult, run_post_tool_use_hook, run_shell_command};
use crate::config::{ServerConfig, ServerMode, parse_exec_api_token};
use crate::logging::{
    ExecuteRequestLog, ExecuteResponseLog, StdoutTrafficLogger, TrafficLogger,
    current_timestamp_ms, log_message,
};
use crate::paths::resolve_cwd;
use crate::{EXEC_API_TOKEN_METADATA_KEY, proto};

#[derive(Clone, Debug)]
pub(crate) struct ExecApiService {
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TokenValidationError {
    MissingOrInvalid,
}

impl From<TokenValidationError> for Status {
    fn from(_: TokenValidationError) -> Self {
        Status::permission_denied("missing or invalid exec API token")
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

impl ExecApiService {
    pub(crate) fn new(config: &ServerConfig) -> Self {
        Self::new_with_traffic_logger(config, Arc::new(StdoutTrafficLogger))
    }

    pub(crate) fn new_with_traffic_logger(
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

#[cfg(test)]
mod tests {
    use super::ExecApiService;
    use crate::EXEC_API_TOKEN_METADATA_KEY;
    use crate::proto;
    use crate::proto::exec_service_server::ExecService;
    use crate::test_support::{CapturingTrafficLogger, FailingTrafficLogger, test_server_config};
    use serde_json::json;
    use std::sync::Arc;
    use tempfile::TempDir;
    use tonic::Request;
    use tonic::metadata::MetadataValue;

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
}
