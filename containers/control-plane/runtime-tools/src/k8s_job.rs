use std::future::Future;
use std::io::{self, Write};
use std::time::{Duration, Instant};

use futures_util::AsyncBufReadExt;
use k8s_openapi::api::batch::v1::{Job, JobCondition};
use k8s_openapi::api::core::v1::Pod;
use kube::api::{ListParams, LogParams};
use kube::{Api, Client};

use crate::error::{ToolError, ToolResult};

const JOB_RUNTIME_FAILURE_EXIT_CODE: i32 = 70;
const EXECUTION_CONTAINER_NAME: &str = "execution";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum JobWaitStatus {
    Completed,
    Failed,
    TimedOut,
}

#[derive(Debug)]
struct JobCommandArgs {
    namespace: String,
    job_name: String,
    timeout: Duration,
}

#[derive(Debug)]
enum ParsedArg {
    Namespace(String),
    JobName(String),
    Timeout(Duration),
}

pub fn run_wait(args: &[String]) -> ToolResult<i32> {
    run_job_command("k8s-job-wait", args, |parsed, command_name| {
        let namespace = parsed.namespace.clone();
        let job_name = parsed.job_name.clone();
        let timeout = parsed.timeout;
        let status = run_async(async move {
            let client = kube_client().await?;
            wait_for_job(client, namespace, job_name, timeout).await
        })
        .map_err(|message| ToolError::new(JOB_RUNTIME_FAILURE_EXIT_CODE, command_name, message))?;
        match status {
            JobWaitStatus::Completed => Ok(0),
            JobWaitStatus::Failed => {
                eprintln!("{command_name}: job {} failed", parsed.job_name);
                Ok(1)
            }
            JobWaitStatus::TimedOut => {
                eprintln!(
                    "{command_name}: timed out waiting for job {}",
                    parsed.job_name
                );
                Ok(124)
            }
        }
    })
}

pub fn run_pod(args: &[String]) -> ToolResult<i32> {
    run_job_command("k8s-job-pod", args, |parsed, command_name| {
        let namespace = parsed.namespace.clone();
        let job_name = parsed.job_name.clone();
        let pod_name = run_async(async move {
            let client = kube_client().await?;
            resolve_job_pod(client, namespace, job_name).await
        })
        .map_err(|message| ToolError::new(JOB_RUNTIME_FAILURE_EXIT_CODE, command_name, message))?;
        println!("{pod_name}");
        Ok(0)
    })
}

pub fn run_logs(args: &[String]) -> ToolResult<i32> {
    run_job_command("k8s-job-logs", args, |parsed, command_name| {
        let namespace = parsed.namespace.clone();
        let job_name = parsed.job_name.clone();
        run_async(async move {
            let client = kube_client().await?;
            stream_job_logs(client, namespace, job_name).await
        })
        .map_err(|message| ToolError::new(JOB_RUNTIME_FAILURE_EXIT_CODE, command_name, message))
    })
}

fn run_job_command<F>(command_name: &'static str, args: &[String], handler: F) -> ToolResult<i32>
where
    F: FnOnce(&JobCommandArgs, &'static str) -> ToolResult<i32>,
{
    if args.len() == 1 && args[0] == "--help" {
        print_usage(command_name);
        return Ok(0);
    }

    let parsed = parse_job_command_args(command_name, args)?;
    handler(&parsed, command_name)
}

fn parse_job_command_args(
    command_name: &'static str,
    args: &[String],
) -> ToolResult<JobCommandArgs> {
    let mut namespace = "default".to_string();
    let mut job_name = String::new();
    let mut timeout = Duration::from_secs(300);
    let mut index = 0usize;

    while index < args.len() {
        let (parsed_arg, next_index) = parse_arg(command_name, args, index)?;
        apply_parsed_arg(parsed_arg, &mut namespace, &mut job_name, &mut timeout);
        index = next_index;
    }

    if job_name.is_empty() {
        return Err(ToolError::new(64, command_name, "--job-name is required"));
    }
    validate_namespace(command_name, &namespace)?;
    validate_job_name(command_name, &job_name)?;

    Ok(JobCommandArgs {
        namespace,
        job_name,
        timeout,
    })
}

fn parse_arg(
    command_name: &'static str,
    args: &[String],
    index: usize,
) -> ToolResult<(ParsedArg, usize)> {
    match args[index].as_str() {
        "--namespace" => Ok((
            ParsedArg::Namespace(require_value(command_name, args, index, "--namespace")?.clone()),
            index + 2,
        )),
        "--job-name" => Ok((
            ParsedArg::JobName(require_value(command_name, args, index, "--job-name")?.clone()),
            index + 2,
        )),
        "--timeout" => {
            let value = require_value(command_name, args, index, "--timeout")?;
            Ok((
                ParsedArg::Timeout(
                    parse_timeout_duration(value)
                        .map_err(|message| ToolError::new(64, command_name, message))?,
                ),
                index + 2,
            ))
        }
        other => Err(ToolError::new(
            64,
            command_name,
            format!("unknown option: {other}"),
        )),
    }
}

fn apply_parsed_arg(
    parsed_arg: ParsedArg,
    namespace: &mut String,
    job_name: &mut String,
    timeout: &mut Duration,
) {
    match parsed_arg {
        ParsedArg::Namespace(value) => *namespace = value,
        ParsedArg::JobName(value) => *job_name = value,
        ParsedArg::Timeout(value) => *timeout = value,
    }
}

fn require_value<'a>(
    command_name: &'static str,
    args: &'a [String],
    index: usize,
    flag: &str,
) -> ToolResult<&'a String> {
    args.get(index + 1)
        .ok_or_else(|| ToolError::new(64, command_name, format!("{flag} requires a value")))
}

fn print_usage(command_name: &str) {
    match command_name {
        "k8s-job-wait" => {
            println!("Usage:\n  k8s-job-wait --namespace NAME --job-name NAME [--timeout 300s]")
        }
        "k8s-job-pod" => println!("Usage:\n  k8s-job-pod --namespace NAME --job-name NAME"),
        "k8s-job-logs" => println!("Usage:\n  k8s-job-logs --namespace NAME --job-name NAME"),
        _ => {}
    }
}

fn parse_timeout_duration(raw_value: &str) -> Result<Duration, String> {
    if raw_value.is_empty() {
        return Err("--timeout requires a value".to_string());
    }

    let split_at = raw_value
        .find(|character: char| !character.is_ascii_digit())
        .unwrap_or(raw_value.len());
    let (digits, suffix) = raw_value.split_at(split_at);
    if digits.is_empty() {
        return Err(format!("invalid timeout value: {raw_value}"));
    }

    let amount: u64 = digits
        .parse()
        .map_err(|_| format!("invalid timeout value: {raw_value}"))?;
    let seconds = match suffix {
        "" | "s" => amount,
        "m" => amount.saturating_mul(60),
        "h" => amount.saturating_mul(60 * 60),
        _ => return Err(format!("invalid timeout value: {raw_value}")),
    };
    Ok(Duration::from_secs(seconds))
}

fn validate_job_name(command_name: &'static str, job_name: &str) -> ToolResult<()> {
    if is_dns_subdomain(job_name) {
        Ok(())
    } else {
        Err(ToolError::new(
            64,
            command_name,
            format!("invalid Kubernetes job name: {job_name}"),
        ))
    }
}

fn validate_namespace(command_name: &'static str, namespace: &str) -> ToolResult<()> {
    if is_dns_label(namespace) {
        Ok(())
    } else {
        Err(ToolError::new(
            64,
            command_name,
            format!("invalid Kubernetes namespace: {namespace}"),
        ))
    }
}

fn is_dns_subdomain(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 253
        && value.bytes().all(|character| {
            character.is_ascii_lowercase()
                || character.is_ascii_digit()
                || matches!(character, b'.' | b'-')
        })
        && !value.starts_with(['.', '-'])
        && !value.ends_with(['.', '-'])
        && value.split('.').all(is_dns_label)
}

fn is_dns_label(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 63
        && value.bytes().all(|character| {
            character.is_ascii_lowercase() || character.is_ascii_digit() || character == b'-'
        })
        && !value.starts_with('-')
        && !value.ends_with('-')
}

async fn wait_for_job(
    client: Client,
    namespace: String,
    job_name: String,
    timeout: Duration,
) -> Result<JobWaitStatus, String> {
    let started = Instant::now();
    let jobs: Api<Job> = Api::namespaced(client, &namespace);
    loop {
        let job = jobs
            .get(&job_name)
            .await
            .map_err(|error| format!("failed to read job {job_name}: {error}"))?;
        match evaluate_job_wait_status(&job) {
            Some(status) => return Ok(status),
            None if started.elapsed() >= timeout => return Ok(JobWaitStatus::TimedOut),
            None => tokio::time::sleep(Duration::from_secs(1)).await,
        }
    }
}

async fn kube_client() -> Result<Client, String> {
    Client::try_default()
        .await
        .map_err(|error| format!("failed to create Kubernetes client: {error}"))
}

fn run_async<F, T>(future: F) -> Result<T, String>
where
    F: Future<Output = Result<T, String>>,
{
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| format!("failed to start async runtime: {error}"))?;
    runtime.block_on(future)
}

fn evaluate_job_wait_status(job: &Job) -> Option<JobWaitStatus> {
    let conditions = job.status.as_ref()?.conditions.as_ref()?;
    if has_condition(conditions, "Complete", "True") {
        Some(JobWaitStatus::Completed)
    } else if has_condition(conditions, "Failed", "True") {
        Some(JobWaitStatus::Failed)
    } else {
        None
    }
}

fn has_condition(conditions: &[JobCondition], expected_type: &str, expected_status: &str) -> bool {
    conditions
        .iter()
        .any(|condition| condition.type_ == expected_type && condition.status == expected_status)
}

async fn resolve_job_pod(
    client: Client,
    namespace: String,
    job_name: String,
) -> Result<String, String> {
    let job_uid = read_job_uid(client.clone(), &namespace, &job_name).await?;
    let pods = list_job_pods(client, &namespace, &job_name, &job_uid).await?;
    first_controlled_pod_name(&pods, &job_name, &job_uid)
}

async fn read_job_uid(client: Client, namespace: &str, job_name: &str) -> Result<String, String> {
    let jobs: Api<Job> = Api::namespaced(client, namespace);
    let job = jobs
        .get(job_name)
        .await
        .map_err(|error| format!("failed to read job {job_name}: {error}"))?;
    job.metadata
        .uid
        .ok_or_else(|| format!("job {job_name} is missing metadata.uid"))
}

async fn list_job_pods(
    client: Client,
    namespace: &str,
    job_name: &str,
    job_uid: &str,
) -> Result<Vec<Pod>, String> {
    let pods: Api<Pod> = Api::namespaced(client, namespace);
    let selector = format!("job-name={job_name},controller-uid={job_uid}");
    let pod_list = pods
        .list(&ListParams::default().labels(&selector))
        .await
        .map_err(|error| format!("failed to list pods for {job_name}: {error}"))?;
    Ok(pod_list.items)
}

fn first_controlled_pod_name(
    pods: &[Pod],
    job_name: &str,
    job_uid: &str,
) -> Result<String, String> {
    pods.iter()
        .find_map(|pod| controlled_pod_name(pod, job_name, job_uid))
        .ok_or_else(|| format!("failed to resolve controlled pod for job {job_name}"))
}

fn controlled_pod_name(pod: &Pod, job_name: &str, job_uid: &str) -> Option<String> {
    if is_controlled_by_job(pod, job_name, job_uid) {
        pod.metadata.name.clone()
    } else {
        None
    }
}

fn is_controlled_by_job(pod: &Pod, job_name: &str, job_uid: &str) -> bool {
    let owners = pod.metadata.owner_references.as_deref().unwrap_or(&[]);
    owners.iter().any(|owner| {
        owner.kind == "Job"
            && owner.name == job_name
            && owner.uid == job_uid
            && owner.controller.unwrap_or(false)
    })
}

async fn stream_job_logs(
    client: Client,
    namespace: String,
    job_name: String,
) -> Result<i32, String> {
    let pod_name = resolve_job_pod(client.clone(), namespace.clone(), job_name).await?;
    let pods: Api<Pod> = Api::namespaced(client, &namespace);
    let pod = pods
        .get(&pod_name)
        .await
        .map_err(|error| format!("failed to read pod {pod_name}: {error}"))?;
    let container_name = preferred_log_container_name(&pod)
        .map_err(|message| format!("failed to resolve log container for {pod_name}: {message}"))?;
    let mut logs = pods
        .log_stream(
            &pod_name,
            &LogParams {
                container: Some(container_name),
                ..Default::default()
            },
        )
        .await
        .map_err(|error| format!("failed to open log stream for {pod_name}: {error}"))?;
    let mut buffer = Vec::new();
    loop {
        buffer.clear();
        let bytes_read = logs
            .read_until(b'\n', &mut buffer)
            .await
            .map_err(|error| format!("failed to read logs for {pod_name}: {error}"))?;
        if bytes_read == 0 {
            break;
        }
        io::stdout()
            .write_all(&buffer)
            .map_err(|error| format!("failed to write logs for {pod_name}: {error}"))?;
    }
    io::stdout()
        .flush()
        .map_err(|error| format!("failed to flush logs for {pod_name}: {error}"))?;
    Ok(0)
}

fn preferred_log_container_name(pod: &Pod) -> Result<String, String> {
    let pod_name = pod.metadata.name.as_deref().unwrap_or("<unknown>");
    let spec = pod
        .spec
        .as_ref()
        .ok_or_else(|| format!("pod {pod_name} is missing spec"))?;

    if let Some(container) = spec
        .containers
        .iter()
        .find(|container| container.name == EXECUTION_CONTAINER_NAME)
    {
        return Ok(container.name.clone());
    }

    match spec.containers.as_slice() {
        [container] => Ok(container.name.clone()),
        [] => Err(format!("pod {pod_name} has no regular containers")),
        containers => Err(format!(
            "pod {pod_name} has multiple regular containers and no \"{EXECUTION_CONTAINER_NAME}\" container: [{}]",
            containers
                .iter()
                .map(|container| container.name.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        )),
    }
}

#[cfg(test)]
mod tests {
    use k8s_openapi::api::batch::v1::{Job, JobCondition, JobStatus};
    use k8s_openapi::api::core::v1::{Container, Pod, PodSpec};
    use k8s_openapi::apimachinery::pkg::apis::meta::v1::{ObjectMeta, OwnerReference};

    use super::{
        JobWaitStatus, evaluate_job_wait_status, first_controlled_pod_name, parse_job_command_args,
        preferred_log_container_name,
    };

    #[test]
    fn detects_completion() {
        let status = evaluate_job_wait_status(&Job {
            status: Some(JobStatus {
                conditions: Some(vec![JobCondition {
                    type_: "Complete".to_string(),
                    status: "True".to_string(),
                    ..Default::default()
                }]),
                ..Default::default()
            }),
            ..Default::default()
        })
        .unwrap();
        assert_eq!(status, JobWaitStatus::Completed);
    }

    #[test]
    fn returns_controlled_pod_name() {
        let pod_name = first_controlled_pod_name(
            &[Pod {
                metadata: ObjectMeta {
                    name: Some("demo-pod".to_string()),
                    owner_references: Some(vec![OwnerReference {
                        api_version: "batch/v1".to_string(),
                        block_owner_deletion: Some(true),
                        controller: Some(true),
                        kind: "Job".to_string(),
                        name: "demo-job".to_string(),
                        uid: "job-uid".to_string(),
                    }]),
                    ..Default::default()
                },
                ..Default::default()
            }],
            "demo-job",
            "job-uid",
        )
        .unwrap();
        assert_eq!(pod_name, "demo-pod");
    }

    #[test]
    fn ignores_pods_without_matching_owner() {
        let error = first_controlled_pod_name(
            &[Pod {
                metadata: ObjectMeta {
                    name: Some("demo-pod".to_string()),
                    owner_references: Some(vec![OwnerReference {
                        api_version: "batch/v1".to_string(),
                        block_owner_deletion: Some(true),
                        controller: Some(true),
                        kind: "Job".to_string(),
                        name: "other-job".to_string(),
                        uid: "other-uid".to_string(),
                    }]),
                    ..Default::default()
                },
                ..Default::default()
            }],
            "demo-job",
            "job-uid",
        )
        .unwrap_err();
        assert_eq!(error, "failed to resolve controlled pod for job demo-job");
    }

    #[test]
    fn rejects_invalid_job_name() {
        let error = parse_job_command_args(
            "k8s-job-logs",
            &[
                "--job-name".to_string(),
                "demo,status=running".to_string(),
                "--namespace".to_string(),
                "default".to_string(),
            ],
        )
        .unwrap_err();
        assert_eq!(
            error.message,
            "invalid Kubernetes job name: demo,status=running"
        );
    }

    #[test]
    fn rejects_invalid_namespace() {
        let error = parse_job_command_args(
            "k8s-job-logs",
            &[
                "--job-name".to_string(),
                "demo-job".to_string(),
                "--namespace".to_string(),
                "default.ops".to_string(),
            ],
        )
        .unwrap_err();
        assert_eq!(error.message, "invalid Kubernetes namespace: default.ops");
    }

    #[test]
    fn prefers_execution_container_logs() {
        let container_name = preferred_log_container_name(&Pod {
            metadata: ObjectMeta {
                name: Some("demo-pod".to_string()),
                ..Default::default()
            },
            spec: Some(PodSpec {
                containers: vec![
                    Container {
                        name: "sidecar".to_string(),
                        ..Default::default()
                    },
                    Container {
                        name: "execution".to_string(),
                        ..Default::default()
                    },
                ],
                ..Default::default()
            }),
            ..Default::default()
        })
        .unwrap();
        assert_eq!(container_name, "execution");
    }

    #[test]
    fn falls_back_to_only_regular_container_logs() {
        let container_name = preferred_log_container_name(&Pod {
            metadata: ObjectMeta {
                name: Some("demo-pod".to_string()),
                ..Default::default()
            },
            spec: Some(PodSpec {
                containers: vec![Container {
                    name: "main".to_string(),
                    ..Default::default()
                }],
                init_containers: Some(vec![Container {
                    name: "setup".to_string(),
                    ..Default::default()
                }]),
                ..Default::default()
            }),
            ..Default::default()
        })
        .unwrap();
        assert_eq!(container_name, "main");
    }

    #[test]
    fn rejects_multi_container_logs_without_execution() {
        let error = preferred_log_container_name(&Pod {
            metadata: ObjectMeta {
                name: Some("demo-pod".to_string()),
                ..Default::default()
            },
            spec: Some(PodSpec {
                containers: vec![
                    Container {
                        name: "main".to_string(),
                        ..Default::default()
                    },
                    Container {
                        name: "sidecar".to_string(),
                        ..Default::default()
                    },
                ],
                ..Default::default()
            }),
            ..Default::default()
        })
        .unwrap_err();
        assert_eq!(
            error,
            "pod demo-pod has multiple regular containers and no \"execution\" container: [main, sidecar]"
        );
    }
}
