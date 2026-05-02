use std::time::Duration;

use control_plane_exec_api::check_health;
use k8s_openapi::api::core::v1::Pod;
use kube::api::{DeleteParams, PostParams};
use kube::{Api, Client};
use tokio::time::{Instant, sleep};

use super::config::SessionExecConfig;
use super::manifest::STARTUP_PROBE_GRACE_SECONDS;
use super::state::SessionEntry;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct ReadyExecutionPod {
    pub(super) pod_uid: String,
    pub(super) pod_ip: String,
}

pub(super) async fn kube_client() -> Result<Client, String> {
    Client::try_default()
        .await
        .map_err(|error| format!("failed to create Kubernetes client: {error}"))
}

pub(super) async fn get_existing_pod(
    pods: &Api<Pod>,
    pod_name: &str,
) -> Result<Option<Pod>, String> {
    match pods.get(pod_name).await {
        Ok(pod) => Ok(Some(pod)),
        Err(kube::Error::Api(error)) if error.code == 404 => Ok(None),
        Err(error) => Err(format!(
            "failed to inspect execution pod {pod_name}: {error}"
        )),
    }
}

pub(super) async fn create_pod(
    pods: &Api<Pod>,
    pod: &Pod,
    timeout: Duration,
) -> Result<(), String> {
    let pod_name = pod.metadata.name.as_deref().unwrap_or("unknown");
    let deadline = Instant::now() + timeout + Duration::from_secs(STARTUP_PROBE_GRACE_SECONDS);
    loop {
        match pods.create(&PostParams::default(), pod).await {
            Ok(_) => return Ok(()),
            Err(kube::Error::Api(error)) if error.code == 409 => {
                if Instant::now() > deadline {
                    return Err(format!(
                        "timed out waiting to create execution pod {pod_name}: a pod with the same name is still terminating"
                    ));
                }
                sleep(Duration::from_secs(1)).await;
            }
            Err(error) => {
                return Err(format!(
                    "failed to create execution pod {pod_name}: {error}"
                ));
            }
        }
    }
}

pub(super) async fn delete_pod(
    client: &Client,
    namespace: &str,
    pod_name: &str,
) -> Result<(), String> {
    let pods: Api<Pod> = Api::namespaced(client.clone(), namespace);
    match pods
        .delete(pod_name, &DeleteParams::default())
        .await
        .map(|_| ())
    {
        Ok(()) => Ok(()),
        Err(kube::Error::Api(error)) if error.code == 404 => Ok(()),
        Err(error) => Err(format!(
            "failed to delete execution pod {pod_name}: {error}"
        )),
    }
}

pub(super) async fn wait_for_pod(
    client: &Client,
    config: &SessionExecConfig,
    pod_name: &str,
) -> Result<ReadyExecutionPod, String> {
    let pods: Api<Pod> = Api::namespaced(client.clone(), &config.namespace);
    let deadline =
        Instant::now() + config.start_timeout + Duration::from_secs(STARTUP_PROBE_GRACE_SECONDS);
    loop {
        if Instant::now() > deadline {
            return Err(format!(
                "timed out waiting for execution pod {pod_name} to become ready"
            ));
        }

        let pod = match pods.get(pod_name).await {
            Ok(pod) => pod,
            Err(kube::Error::Api(error)) if error.code == 404 => {
                sleep(Duration::from_secs(1)).await;
                continue;
            }
            Err(error) => {
                return Err(format!(
                    "failed while waiting for execution pod {pod_name}: {error}"
                ));
            }
        };

        if pod_ready(&pod)
            && let Some(pod_uid) = pod_uid(&pod)
            && let Some(pod_ip) = pod_ip(&pod)
            && wait_for_healthcheck(config, &pod_ip).await
        {
            return Ok(ReadyExecutionPod {
                pod_uid: pod_uid.to_string(),
                pod_ip,
            });
        }

        sleep(Duration::from_secs(1)).await;
    }
}

pub(super) async fn wait_for_healthcheck(config: &SessionExecConfig, pod_ip: &str) -> bool {
    for _ in 0..30 {
        if healthcheck(config, pod_ip).await {
            return true;
        }
        sleep(Duration::from_secs(1)).await;
    }
    false
}

async fn healthcheck(config: &SessionExecConfig, pod_ip: &str) -> bool {
    if pod_ip.is_empty() {
        return false;
    }
    check_health(
        &format!("http://{}:{}", pod_ip, config.port),
        Duration::from_secs(2),
    )
    .await
    .is_ok()
}

pub(super) fn pod_matches_session_entry(pod: &Pod, entry: &SessionEntry) -> bool {
    !entry.auth_token.is_empty()
        && !entry.pod_uid.is_empty()
        && pod_uid(pod).is_some_and(|pod_uid| pod_uid == entry.pod_uid.as_str())
        && pod_ready(pod)
}

pub(super) fn pod_ready(pod: &Pod) -> bool {
    if pod_is_terminating(pod) {
        return false;
    }
    let Some(status) = &pod.status else {
        return false;
    };
    if status.phase.as_deref() != Some("Running") {
        return false;
    }
    status.container_statuses.as_ref().is_some_and(|statuses| {
        statuses
            .iter()
            .any(|container| container.name == "execution" && container.ready)
    })
}

fn pod_is_terminating(pod: &Pod) -> bool {
    pod.metadata.deletion_timestamp.is_some()
}

pub(super) fn pod_uid(pod: &Pod) -> Option<&str> {
    pod.metadata
        .uid
        .as_deref()
        .filter(|value| !value.is_empty())
}

pub(super) fn pod_ip(pod: &Pod) -> Option<String> {
    pod.status
        .as_ref()?
        .pod_ip
        .clone()
        .filter(|value| !value.is_empty())
}
