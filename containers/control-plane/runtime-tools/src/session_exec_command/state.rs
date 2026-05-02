use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{ErrorKind, Read};
use std::os::fd::AsRawFd;
use std::path::Path;

use base64::Engine as _;
use serde::{Deserialize, Serialize};

use super::config::SessionExecConfig;

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(super) struct SessionState {
    pub(super) sessions: BTreeMap<String, SessionEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(super) struct SessionEntry {
    pub(super) pod_name: String,
    #[serde(default)]
    pub(super) pod_uid: String,
    pub(super) pod_ip: String,
    pub(super) auth_token: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct PreparedPod {
    pub(super) pod_name: String,
    pub(super) pod_uid: String,
    pub(super) pod_ip: String,
    pub(super) auth_token: String,
}

pub(super) fn read_prepared_pod(
    config: &SessionExecConfig,
    session_key: &str,
) -> Result<PreparedPod, String> {
    let state = read_state(&config.state_file)?;
    let entry = state
        .sessions
        .get(session_key)
        .ok_or_else(|| format!("missing session execution state for {session_key}"))?;
    Ok(prepared_from_entry(entry))
}

fn prepared_from_entry(entry: &SessionEntry) -> PreparedPod {
    PreparedPod {
        pod_name: entry.pod_name.clone(),
        pod_uid: entry.pod_uid.clone(),
        pod_ip: entry.pod_ip.clone(),
        auth_token: entry.auth_token.clone(),
    }
}

pub(super) fn entry_from_prepared(prepared: &PreparedPod) -> SessionEntry {
    SessionEntry {
        pod_name: prepared.pod_name.clone(),
        pod_uid: prepared.pod_uid.clone(),
        pod_ip: prepared.pod_ip.clone(),
        auth_token: prepared.auth_token.clone(),
    }
}

pub(super) fn ensure_state_parent(config: &SessionExecConfig) -> Result<(), String> {
    if let Some(parent) = config.state_file.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            format!(
                "failed to create session execution state directory {}: {error}",
                parent.display()
            )
        })?;
    }
    Ok(())
}

pub(super) fn read_state(path: &Path) -> Result<SessionState, String> {
    match fs::read_to_string(path) {
        Ok(content) => serde_json::from_str(&content)
            .map_err(|error| format!("failed to parse {}: {error}", path.display())),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(SessionState::default()),
        Err(error) => Err(format!("failed to read {}: {error}", path.display())),
    }
}

pub(super) fn write_state(path: &Path, state: &SessionState) -> Result<(), String> {
    let content =
        serde_json::to_string(state).map_err(|error| format!("failed to encode state: {error}"))?;
    fs::write(path, format!("{content}\n"))
        .map_err(|error| format!("failed to write {}: {error}", path.display()))
}

pub(super) fn generate_session_token() -> Result<String, String> {
    let mut bytes = [0u8; 32];
    File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(&mut bytes))
        .map_err(|error| format!("failed to generate session token: {error}"))?;
    Ok(base64::engine::general_purpose::STANDARD.encode(bytes))
}

pub(super) struct StateLock {
    file: File,
}

impl StateLock {
    pub(super) fn acquire(path: &Path) -> Result<Self, String> {
        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .read(true)
            .open(path)
            .map_err(|error| format!("failed to open {}: {error}", path.display()))?;
        let status = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) };
        if status == 0 {
            Ok(Self { file })
        } else {
            Err(format!(
                "failed to lock {}: {}",
                path.display(),
                std::io::Error::last_os_error()
            ))
        }
    }
}

impl Drop for StateLock {
    fn drop(&mut self) {
        unsafe {
            libc::flock(self.file.as_raw_fd(), libc::LOCK_UN);
        }
    }
}
