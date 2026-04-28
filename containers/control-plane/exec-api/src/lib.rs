pub mod proto {
    tonic::include_proto!("controlplane.exec.v1");
}

mod bootstrap;
mod command;
mod config;
mod git_hooks;
mod logging;
mod mounts;
mod packages;
mod paths;
mod remote_home;
mod server;
mod service;
#[cfg(test)]
mod test_support;

pub use command::ExecResult;
pub use config::{ServerConfig, ServerMode, load_server_config_from_env};
pub use logging::log_message;
pub use server::{check_health, execute_remote, serve, serve_with_listener};

pub type DynError = Box<dyn std::error::Error + Send + Sync>;

pub(crate) const HEALTH_SERVICE_NAME: &str = "";
pub(crate) const EXEC_API_TOKEN_METADATA_KEY: &str = "x-control-plane-exec-token";
pub(crate) const DEFAULT_EXEC_PATH: &str =
    "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
pub(crate) const KUBERNETES_SERVICE_ACCOUNT_DIR: &str =
    "/var/run/secrets/kubernetes.io/serviceaccount";
pub(crate) const CHROOT_KUBERNETES_SERVICE_ACCOUNT_DIR: &str =
    "/run/secrets/kubernetes.io/serviceaccount";
pub(crate) const CHROOT_COPILOT_HOOKS_DIR: &str = "/usr/local/share/control-plane/hooks";
pub(crate) const CHROOT_GIT_HOOKS_DIR: &str = "/usr/local/share/control-plane/hooks/git";
pub(crate) const CHROOT_POST_TOOL_USE_HOOKS_PATH: &str =
    "/usr/local/share/control-plane/hooks/postToolUse";
pub(crate) const CHROOT_EXEC_POLICY_LIBRARY_PATH: &str =
    "/usr/local/lib/libcontrol_plane_exec_policy.so";
pub(crate) const CHROOT_EXEC_POLICY_RULES_PATH: &str =
    "/usr/local/share/control-plane/hooks/preToolUse/deny-rules.yaml";
pub(crate) const CHROOT_RUNTIME_TOOL_PATH: &str = "/usr/local/bin/control-plane-runtime-tool";
pub(crate) const CHROOT_KUBECTL_PATH: &str = "/usr/local/bin/kubectl";
pub(crate) const REMOTE_CARGO_TARGET_DIR: &str = "/var/tmp/control-plane/cargo-target";

pub(crate) fn with_context<T, E>(
    result: Result<T, E>,
    context: impl FnOnce() -> String,
) -> Result<T, DynError>
where
    E: std::fmt::Display,
{
    result.map_err(|error| format!("{}: {error}", context()).into())
}
