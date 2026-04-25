mod args;
mod kube_ops;

use std::future::Future;

use crate::error::{ToolError, ToolResult};

use self::args::{JobCommandArgs, parse_job_command_args, print_usage};
use self::kube_ops::{JobWaitStatus, kube_client, resolve_job_pod, stream_job_logs, wait_for_job};

const JOB_RUNTIME_FAILURE_EXIT_CODE: i32 = 70;

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

#[cfg(test)]
mod tests {
    use k8s_openapi::api::batch::v1::{Job, JobCondition, JobStatus};
    use k8s_openapi::api::core::v1::{Container, Pod, PodSpec};
    use k8s_openapi::apimachinery::pkg::apis::meta::v1::{ObjectMeta, OwnerReference};

    use super::args::parse_job_command_args;
    use super::kube_ops::{
        JobWaitStatus, evaluate_job_wait_status, first_controlled_pod_name,
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
                        controller: Some(false),
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
        .unwrap_err();
        assert_eq!(error, "failed to resolve controlled pod for job demo-job");
    }

    #[test]
    fn parses_namespace_job_name_and_timeout() {
        let parsed = parse_job_command_args(
            "k8s-job-wait",
            &[
                "--namespace".to_string(),
                "demo".to_string(),
                "--job-name".to_string(),
                "demo-job".to_string(),
                "--timeout".to_string(),
                "90s".to_string(),
            ],
        )
        .unwrap();

        assert_eq!(parsed.namespace, "demo");
        assert_eq!(parsed.job_name, "demo-job");
        assert_eq!(parsed.timeout.as_secs(), 90);
    }

    #[test]
    fn rejects_invalid_timeout_suffix() {
        let error = parse_job_command_args(
            "k8s-job-wait",
            &[
                "--job-name".to_string(),
                "demo-job".to_string(),
                "--timeout".to_string(),
                "5d".to_string(),
            ],
        )
        .unwrap_err();
        assert_eq!(error.code, 64);
        assert_eq!(error.prefix, "k8s-job-wait");
        assert_eq!(error.message, "invalid timeout value: 5d");
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
    fn prefers_execution_container_for_logs() {
        let pod = Pod {
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
        };

        assert_eq!(preferred_log_container_name(&pod).unwrap(), "execution");
    }

    #[test]
    fn falls_back_to_only_regular_container_logs() {
        let pod = Pod {
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
        };

        assert_eq!(preferred_log_container_name(&pod).unwrap(), "main");
    }

    #[test]
    fn rejects_ambiguous_log_container() {
        let pod = Pod {
            metadata: ObjectMeta {
                name: Some("demo-pod".to_string()),
                ..Default::default()
            },
            spec: Some(PodSpec {
                containers: vec![
                    Container {
                        name: "one".to_string(),
                        ..Default::default()
                    },
                    Container {
                        name: "two".to_string(),
                        ..Default::default()
                    },
                ],
                ..Default::default()
            }),
            ..Default::default()
        };

        assert_eq!(
            preferred_log_container_name(&pod).unwrap_err(),
            "pod demo-pod has multiple regular containers and no \"execution\" container: [one, two]"
        );
    }
}
