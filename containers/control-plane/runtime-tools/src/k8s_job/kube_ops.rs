use std::io::{self, Write};
use std::time::{Duration, Instant};

use futures_util::AsyncBufReadExt;
use k8s_openapi::api::batch::v1::{Job, JobCondition};
use k8s_openapi::api::core::v1::Pod;
use kube::api::{ListParams, LogParams};
use kube::{Api, Client};

const EXECUTION_CONTAINER_NAME: &str = "execution";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum JobWaitStatus {
    Completed,
    Failed,
    TimedOut,
}

pub(super) async fn wait_for_job(
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

pub(super) async fn kube_client() -> Result<Client, String> {
    Client::try_default()
        .await
        .map_err(|error| format!("failed to create Kubernetes client: {error}"))
}

pub(super) fn evaluate_job_wait_status(job: &Job) -> Option<JobWaitStatus> {
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

pub(super) async fn resolve_job_pod(
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

pub(super) fn first_controlled_pod_name(
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

pub(super) async fn stream_job_logs(
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

pub(super) fn preferred_log_container_name(pod: &Pod) -> Result<String, String> {
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
