use hyper_util::rt::{TokioExecutor, TokioIo};
use hyper_util::server::conn::auto::Builder as HyperServerBuilder;
use hyper_util::service::TowerToHyperService;
use std::convert::Infallible;
use std::future::Future;
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::Duration;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::watch;
use tokio::task::JoinSet;
use tonic::Request;
use tonic::metadata::MetadataValue;
use tonic::transport::{Channel, Endpoint};
use tonic_health::ServingStatus;
use tonic_health::pb::health_client::HealthClient;
use tower::Service;

use crate::bootstrap::prepare_server_environment;
use crate::command::ExecResult;
use crate::config::ServerConfig;
use crate::logging::log_message;
use crate::service::ExecApiService;
use crate::{DynError, EXEC_API_TOKEN_METADATA_KEY, HEALTH_SERVICE_NAME, proto};

type ExecGrpcService = proto::exec_service_server::ExecServiceServer<ExecApiService>;
type HealthGrpcService =
    tonic_health::pb::health_server::HealthServer<tonic_health::server::HealthService>;
type GrpcRequest = http::Request<hyper::body::Incoming>;
type TonicGrpcRequest = http::Request<tonic::body::Body>;
type GrpcResponse = http::Response<tonic::body::Body>;
type GrpcFuture = Pin<Box<dyn Future<Output = Result<GrpcResponse, Infallible>> + Send>>;
#[derive(Clone)]
struct GrpcRouter {
    exec_service: ExecGrpcService,
    health_service: HealthGrpcService,
}

impl GrpcRouter {
    fn new(exec_service: ExecGrpcService, health_service: HealthGrpcService) -> Self {
        Self {
            exec_service,
            health_service,
        }
    }

    fn route_to_health(path: &str) -> bool {
        path.starts_with("/grpc.health.v1.Health/")
    }
}

impl Service<GrpcRequest> for GrpcRouter {
    type Response = GrpcResponse;
    type Error = Infallible;
    type Future = GrpcFuture;

    fn poll_ready(&mut self, _cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        Poll::Ready(Ok(()))
    }

    fn call(&mut self, request: GrpcRequest) -> Self::Future {
        let path = request.uri().path().to_owned();
        let request: TonicGrpcRequest = request.map(tonic::body::Body::new);

        if Self::route_to_health(&path) {
            let mut service = self.health_service.clone();
            Box::pin(async move { service.call(request).await })
        } else {
            let mut service = self.exec_service.clone();
            Box::pin(async move { service.call(request).await })
        }
    }
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
    let health_reporter = tonic_health::server::HealthReporter::new();
    let health_service = tonic_health::pb::health_server::HealthServer::new(
        tonic_health::server::HealthService::from_health_reporter(health_reporter.clone()),
    );
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

    serve_grpc_connections(
        listener,
        GrpcRouter::new(
            proto::exec_service_server::ExecServiceServer::new(service),
            health_service,
        ),
        shutdown,
    )
    .await?;

    Ok(())
}

async fn serve_grpc_connections<F>(
    listener: TcpListener,
    service: GrpcRouter,
    shutdown: F,
) -> Result<(), DynError>
where
    F: Future<Output = ()> + Send + 'static,
{
    tokio::pin!(shutdown);
    let (connection_shutdown_tx, _) = watch::channel(());
    let mut connections = JoinSet::new();

    loop {
        tokio::select! {
            _ = shutdown.as_mut() => {
                let _ = connection_shutdown_tx.send(());
                break;
            }
            result = connections.join_next(), if !connections.is_empty() => {
                if let Some(result) = result {
                    log_grpc_connection_task_result(result);
                }
            }
            accepted = listener.accept() => {
                match accepted {
                    Ok((stream, _)) => spawn_grpc_connection(
                        &mut connections,
                        stream,
                        service.clone(),
                        connection_shutdown_tx.subscribe(),
                    ),
                    Err(error) => log_message(&format!("gRPC accept failed: {error}")),
                }
            }
        }
    }

    while let Some(result) = connections.join_next().await {
        log_grpc_connection_task_result(result);
    }

    Ok(())
}

fn log_grpc_connection_task_result(result: Result<(), tokio::task::JoinError>) {
    if let Err(error) = result {
        log_message(&format!("gRPC connection task failed: {error}"));
    }
}

fn spawn_grpc_connection(
    connections: &mut JoinSet<()>,
    stream: TcpStream,
    service: GrpcRouter,
    mut shutdown: watch::Receiver<()>,
) {
    connections.spawn(async move {
        let builder = HyperServerBuilder::new(TokioExecutor::new());
        let mut connection = Box::pin(
            builder.serve_connection(TokioIo::new(stream), TowerToHyperService::new(service)),
        );

        tokio::select! {
            result = connection.as_mut() => {
                if let Err(error) = result {
                    log_message(&format!("gRPC connection failed: {error}"));
                }
            }
            changed = shutdown.changed() => {
                if changed.is_ok() {
                    connection.as_mut().graceful_shutdown();
                }
                if let Err(error) = connection.await {
                    log_message(&format!("gRPC connection failed: {error}"));
                }
            }
        }
    });
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
async fn connect(addr: &str, timeout: Duration) -> Result<Channel, DynError> {
    Ok(Endpoint::from_shared(addr.to_owned())?
        .timeout(timeout)
        .connect()
        .await?)
}
