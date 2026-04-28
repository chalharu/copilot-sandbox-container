use std::env;
use std::ffi::OsString;
use std::fs;
use std::path::Path;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use tempfile::TempDir;

use crate::config::{ServerConfig, ServerMode};
use crate::logging::TrafficLogger;

#[derive(Debug, Default)]
pub(crate) struct CapturingTrafficLogger {
    lines: Mutex<Vec<String>>,
}

impl CapturingTrafficLogger {
    pub(crate) fn lines(&self) -> Vec<String> {
        self.lines.lock().unwrap().clone()
    }
}

impl TrafficLogger for CapturingTrafficLogger {
    fn log_line(&self, line: &str) -> Result<(), String> {
        self.lines.lock().unwrap().push(line.to_owned());
        Ok(())
    }
}

#[derive(Debug, Default)]
pub(crate) struct FailingTrafficLogger;

impl TrafficLogger for FailingTrafficLogger {
    fn log_line(&self, _line: &str) -> Result<(), String> {
        Err(String::from("synthetic traffic logger failure"))
    }
}

pub(crate) fn env_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

pub(crate) struct ScopedEnvVar {
    key: &'static str,
    previous: Option<OsString>,
}

impl ScopedEnvVar {
    pub(crate) fn set(key: &'static str, value: Option<&str>) -> Self {
        let previous = env::var_os(key);
        match value {
            Some(value) => unsafe { env::set_var(key, value) },
            None => unsafe { env::remove_var(key) },
        }
        Self { key, previous }
    }
}

impl Drop for ScopedEnvVar {
    fn drop(&mut self) {
        match &self.previous {
            Some(value) => unsafe { env::set_var(self.key, value) },
            None => unsafe { env::remove_var(self.key) },
        }
    }
}

pub(crate) fn test_server_config(workspace: &TempDir, token: &str) -> ServerConfig {
    let remote_home = workspace.path().join("home");
    fs::create_dir_all(&remote_home).unwrap();
    ServerConfig {
        port: 8080,
        workspace_root: workspace.path().to_path_buf(),
        logical_workspace_root: workspace.path().to_path_buf(),
        chroot_root: None,
        environment_mount_path: None,
        git_hooks_source: None,
        remote_home,
        git_user_name: None,
        git_user_email: None,
        startup_script: None,
        mode: ServerMode::Exec,
        exec_api_token: token.to_owned(),
        exec_timeout: Duration::from_secs(5),
        run_as_uid: unsafe { libc::geteuid() },
        run_as_gid: unsafe { libc::getegid() },
    }
}

pub(crate) fn write_stub_command(chroot_root: &Path, relative_path: &str) {
    let full_path = chroot_root.join(relative_path.trim_start_matches('/'));
    fs::create_dir_all(full_path.parent().unwrap()).unwrap();
    fs::write(full_path, "").unwrap();
}
