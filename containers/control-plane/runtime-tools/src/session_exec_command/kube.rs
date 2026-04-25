use std::time::Duration;

use control_plane_exec_api::check_health;
use k8s_openapi::api::core::v1::{PersistentVolumeClaim, Pod};
use k8s_openapi::api::storage::v1::StorageClass;
use kube::api::{DeleteParams, ListParams, PostParams};
use kube::{Api, Client};
use tokio::time::{Instant, sleep};

use super::config::SessionExecConfig;
use super::manifest::{STARTUP_PROBE_GRACE_SECONDS, build_environment_pvc};
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

pub(super) async fn ensure_environment_pvc(
    client: &Client,
    config: &SessionExecConfig,
    pvc_name: &str,
) -> Result<(), String> {
    let pvcs: Api<PersistentVolumeClaim> = Api::namespaced(client.clone(), &config.namespace);
    if pvcs.get(pvc_name).await.is_ok() {
        return Ok(());
    }

    let pvc = build_environment_pvc(config, pvc_name)?;
    match pvcs.create(&PostParams::default(), &pvc).await {
        Ok(_) => Ok(()),
        Err(kube::Error::Api(error)) if error.code == 409 => Ok(()),
        Err(error) => Err(format!(
            "failed to create execution environment PVC {pvc_name}: {error}"
        )),
    }
}

pub(super) async fn resolve_exec_ephemeral_storage_class(
    client: &Client,
    config: &SessionExecConfig,
) -> Result<String, String> {
    if let Some(storage_class) = config.ephemeral_storage_class.as_ref() {
        return Ok(storage_class.clone());
    }

    let storage_classes: Api<StorageClass> = Api::all(client.clone());
    let storage_classes = storage_classes
        .list(&ListParams::default())
        .await
        .map_err(|error| {
            format!(
                "failed to resolve fast execution ephemeral storage class: {error}; \
                 set CONTROL_PLANE_FAST_EXECUTION_EPHEMERAL_STORAGE_CLASS or grant access to list StorageClasses"
            )
        })?;
    find_default_storage_class_name(&storage_classes.items).map_err(|error| {
        format!("{error}; set CONTROL_PLANE_FAST_EXECUTION_EPHEMERAL_STORAGE_CLASS to override")
    })
}

pub(super) fn find_default_storage_class_name(
    storage_classes: &[StorageClass],
) -> Result<String, String> {
    let mut defaults = storage_classes
        .iter()
        .filter(|storage_class| storage_class_is_default(storage_class))
        .filter_map(|storage_class| storage_class.metadata.name.clone())
        .collect::<Vec<_>>();
    defaults.sort();
    defaults.dedup();

    match defaults.as_slice() {
        [storage_class] => Ok(storage_class.clone()),
        [] => Err("no default StorageClass found for fast execution ephemeral storage".to_string()),
        _ => Err(format!(
            "multiple default StorageClasses found for fast execution ephemeral storage: {}",
            defaults.join(", ")
        )),
    }
}

fn storage_class_is_default(storage_class: &StorageClass) -> bool {
    storage_class
        .metadata
        .annotations
        .as_ref()
        .is_some_and(|annotations| {
            [
                "storageclass.kubernetes.io/is-default-class",
                "storageclass.beta.kubernetes.io/is-default-class",
            ]
            .into_iter()
            .filter_map(|key| annotations.get(key))
            .any(|value| value.trim().eq_ignore_ascii_case("true"))
        })
}

pub(super) async fn resolve_bootstrap_image(
    client: &Client,
    config: &SessionExecConfig,
) -> Result<String, String> {
    if let Some(image) = &config.bootstrap_image {
        return Ok(image.clone());
    }

    let pods: Api<Pod> = Api::namespaced(client.clone(), &config.namespace);
    let owner_pod = pods
        .get(&config.owner_pod_name)
        .await
        .map_err(|error| format!("failed to determine bootstrap image: {error}"))?;
    owner_pod
        .spec
        .as_ref()
        .and_then(|spec| {
            spec.containers
                .iter()
                .find(|container| container.name == "control-plane")
                .or_else(|| spec.containers.first())
        })
        .and_then(|container| container.image.clone())
        .ok_or_else(|| {
            format!(
                "owner pod {} does not expose a bootstrap image",
                config.owner_pod_name
            )
        })
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
