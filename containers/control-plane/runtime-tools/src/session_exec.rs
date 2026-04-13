use std::env;
use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Write};
use std::path::{Path, PathBuf};

use uuid::Uuid;

use crate::support::DEFAULT_SESSION_EXEC_BIN;

const HOOK_SESSION_KEY_DIR_SUFFIX: &str = ".copilot/session-state/hook-session-keys";

enum HookSessionSource {
    Direct(String),
    Scoped(String),
}

pub fn fast_execution_enabled() -> bool {
    matches!(
        env::var("CONTROL_PLANE_FAST_EXECUTION_ENABLED")
            .ok()
            .as_deref(),
        Some("1")
    )
}

pub fn session_exec_bin() -> String {
    env::var("CONTROL_PLANE_SESSION_EXEC_BIN")
        .unwrap_or_else(|_| DEFAULT_SESSION_EXEC_BIN.to_string())
}

pub fn session_key() -> Result<String, String> {
    match hook_session_source()? {
        Some(HookSessionSource::Direct(value)) => Ok(value),
        Some(HookSessionSource::Scoped(scope)) => read_or_create_scoped_session_key(&scope),
        None => Ok(Uuid::new_v4().to_string()),
    }
}

pub fn clear_session_key() -> Result<(), String> {
    let Some(HookSessionSource::Scoped(scope)) = hook_session_source()? else {
        return Ok(());
    };
    let path = scoped_session_key_path(&scope);
    match fs::remove_file(&path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!(
            "failed to remove hook session key state {}: {error}",
            path.display()
        )),
    }
}

fn hook_session_source() -> Result<Option<HookSessionSource>, String> {
    let Some(value) = env::var("CONTROL_PLANE_HOOK_SESSION_KEY")
        .ok()
        .filter(|value| !value.is_empty())
    else {
        return Ok(None);
    };
    if value.chars().all(|character| character.is_ascii_digit()) {
        return Ok(Some(resolve_scoped_hook_session_source(&value)?));
    }
    Ok(Some(HookSessionSource::Direct(value)))
}

fn resolve_scoped_hook_session_source(process_id: &str) -> Result<HookSessionSource, String> {
    let stat_path = PathBuf::from(format!("/proc/{process_id}/stat"));
    let raw = match fs::read_to_string(&stat_path) {
        Ok(value) => value,
        Err(error) if error.kind() == ErrorKind::NotFound => {
            let Some(existing_scope) = existing_scoped_session_scope(process_id)? else {
                return Err(format!("failed to read {}: {error}", stat_path.display()));
            };
            return Ok(HookSessionSource::Scoped(existing_scope));
        }
        Err(error) => return Err(format!("failed to read {}: {error}", stat_path.display())),
    };
    let (_, remainder) = raw
        .rsplit_once(") ")
        .ok_or_else(|| format!("failed to parse {}", stat_path.display()))?;
    let start_time = remainder
        .split_whitespace()
        .nth(19)
        .map(ToOwned::to_owned)
        .ok_or_else(|| format!("missing process start time in {}", stat_path.display()))?;
    Ok(HookSessionSource::Scoped(format!(
        "{process_id}-{start_time}"
    )))
}

fn existing_scoped_session_scope(process_id: &str) -> Result<Option<String>, String> {
    let prefix = format!("{process_id}-");
    let mut scopes = Vec::new();
    match fs::read_dir(hook_session_key_dir()) {
        Ok(entries) => {
            for entry in entries {
                let entry = entry.map_err(|error| {
                    format!("failed to read hook session key state directory entry: {error}")
                })?;
                let file_name = entry.file_name();
                let file_name = file_name.to_string_lossy();
                let Some(scope) = file_name.strip_suffix(".key") else {
                    continue;
                };
                if scope.starts_with(&prefix) {
                    scopes.push(scope.to_string());
                }
            }
        }
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(format!(
                "failed to read hook session key state directory {}: {error}",
                hook_session_key_dir().display()
            ));
        }
    }
    match scopes.len() {
        0 => Ok(None),
        1 => Ok(scopes.pop()),
        _ => Err(format!(
            "multiple cached hook session key states matched process {process_id}"
        )),
    }
}

fn read_or_create_scoped_session_key(scope: &str) -> Result<String, String> {
    let path = scoped_session_key_path(scope);
    if let Some(existing) = read_scoped_session_key(&path)? {
        return Ok(existing);
    }
    ensure_session_key_parent(&path)?;

    let generated = Uuid::new_v4().to_string();
    let mut file = match OpenOptions::new().write(true).create_new(true).open(&path) {
        Ok(file) => file,
        Err(error) if error.kind() == ErrorKind::AlreadyExists => {
            return read_scoped_session_key(&path)?.ok_or_else(|| {
                format!(
                    "hook session key state {} disappeared during creation",
                    path.display()
                )
            });
        }
        Err(error) => {
            return Err(format!(
                "failed to create hook session key state {}: {error}",
                path.display()
            ));
        }
    };
    file.write_all(format!("{generated}\n").as_bytes())
        .map_err(|error| format!("failed to write {}: {error}", path.display()))?;
    Ok(generated)
}

fn read_scoped_session_key(path: &Path) -> Result<Option<String>, String> {
    match fs::read_to_string(path) {
        Ok(content) => {
            let value = content.trim().to_string();
            if value.is_empty() {
                return Err(format!(
                    "hook session key state {} is empty",
                    path.display()
                ));
            }
            Uuid::parse_str(&value).map_err(|error| {
                format!("invalid hook session key state {}: {error}", path.display())
            })?;
            Ok(Some(value))
        }
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!("failed to read {}: {error}", path.display())),
    }
}

fn ensure_session_key_parent(path: &Path) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            format!(
                "failed to create hook session key state directory {}: {error}",
                parent.display()
            )
        })?;
    }
    Ok(())
}

fn scoped_session_key_path(scope: &str) -> PathBuf {
    hook_session_key_dir().join(format!("{scope}.key"))
}

fn hook_session_key_dir() -> PathBuf {
    let home = env::var("HOME").unwrap_or_else(|_| "/home/copilot".to_string());
    PathBuf::from(home).join(HOOK_SESSION_KEY_DIR_SUFFIX)
}

#[cfg(test)]
mod tests {
    use std::fs;

    use tempfile::TempDir;
    use uuid::Uuid;

    use crate::test_support::{EnvRestore, lock_env};

    use super::{clear_session_key, session_key};

    #[test]
    fn uses_explicit_hook_session_key() {
        let _env_lock = lock_env();
        let _session_key = EnvRestore::set("CONTROL_PLANE_HOOK_SESSION_KEY", "session-123");

        assert_eq!(session_key().unwrap(), "session-123");
    }

    #[test]
    fn generates_uuidv4_when_hook_session_key_is_missing() {
        let _env_lock = lock_env();
        let _session_key = EnvRestore::set("CONTROL_PLANE_HOOK_SESSION_KEY", "");

        assert_uuid_v4(&session_key().unwrap());
    }

    #[test]
    fn reuses_and_clears_scoped_hook_session_keys() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let _home = EnvRestore::set("HOME", temp_dir.path().to_str().unwrap());
        let _session_key = EnvRestore::set(
            "CONTROL_PLANE_HOOK_SESSION_KEY",
            &std::process::id().to_string(),
        );

        let first = session_key().unwrap();
        assert_uuid_v4(&first);
        assert_eq!(session_key().unwrap(), first);

        clear_session_key().unwrap();

        let second = session_key().unwrap();
        assert_uuid_v4(&second);
        assert_ne!(first, second);
    }

    #[test]
    fn falls_back_to_cached_scoped_session_key_when_process_has_exited() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let _home = EnvRestore::set("HOME", temp_dir.path().to_str().unwrap());
        let cached_scope = "2147483647-12345";
        let cached_key = Uuid::new_v4().to_string();
        let key_dir = temp_dir.path().join(".copilot/session-state/hook-session-keys");
        fs::create_dir_all(&key_dir).unwrap();
        fs::write(
            key_dir.join(format!("{cached_scope}.key")),
            format!("{cached_key}\n"),
        )
        .unwrap();
        let _session_key = EnvRestore::set("CONTROL_PLANE_HOOK_SESSION_KEY", "2147483647");

        assert_eq!(session_key().unwrap(), cached_key);

        clear_session_key().unwrap();
        assert!(!key_dir.join(format!("{cached_scope}.key")).exists());
    }

    fn assert_uuid_v4(value: &str) {
        let parsed = Uuid::parse_str(value).unwrap();
        assert_eq!(parsed.get_version_num(), 4);
    }
}
