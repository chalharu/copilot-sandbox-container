use std::env;
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use serde_json::{Map, Value, json};

use crate::error::{ToolError, ToolResult};
use crate::session_exec::{fast_execution_enabled, session_exec_bin, session_key};
use crate::support::{
    current_directory, output_message, parse_json_object_input, read_stdin_string, shell_quote,
};

pub fn run(_args: &[String]) -> ToolResult<i32> {
    let raw_input = read_stdin_string()
        .map_err(|error| ToolError::new(1, "control-plane exec-forward hook", error.to_string()))?;
    if let Some(output) = handle(&raw_input) {
        println!("{output}");
    }
    Ok(0)
}

pub fn handle(raw_input: &str) -> Option<String> {
    let input = match parse_input_object(raw_input) {
        Ok(value) => value,
        Err(message) => return Some(deny_json(&message)),
    };
    let tool_kind = tool_kind(&input)?;
    if !fast_execution_enabled() {
        return None;
    }

    let mut tool_args = match parse_tool_args(input.get("toolArgs")) {
        Ok(value) => value,
        Err(message) => return Some(deny_json(&message)),
    };

    match tool_kind {
        ToolKind::Bash => {
            let command = match command_text(&tool_args) {
                Some(command) => command,
                None => return Some(deny_json("preToolUse: bash requires non-empty 'command'")),
            };
            let session_exec_bin = session_exec_bin();
            let session_key = match session_key() {
                Ok(value) => value,
                Err(message) => return Some(deny_json(&message)),
            };
            if should_passthrough(command, &session_exec_bin, &session_key) {
                return None;
            }
            if let Err(message) = prepare_execution_pod(&session_exec_bin, &session_key) {
                return Some(deny_json(&message));
            }
            tool_args.insert(
                "command".to_string(),
                Value::String(rewritten_command(
                    &input,
                    &session_exec_bin,
                    &session_key,
                    command,
                )),
            );
        }
        ToolKind::Read => match path_uses_shared_workspace(&input, &tool_args, "Read") {
            Ok(true) => return None,
            Ok(false) => return Some(deny_json(&non_workspace_file_tool_reason("Read"))),
            Err(message) => return Some(deny_json(&message)),
        },
        ToolKind::Write => match path_uses_shared_workspace(&input, &tool_args, "Write") {
            Ok(true) => return None,
            Ok(false) => return Some(deny_json(&non_workspace_file_tool_reason("Write"))),
            Err(message) => return Some(deny_json(&message)),
        },
    }

    Some(
        json!({
            "permissionDecision": "allow",
            "modifiedArgs": Value::Object(tool_args),
        })
        .to_string(),
    )
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ToolKind {
    Bash,
    Read,
    Write,
}

fn tool_kind(input: &Map<String, Value>) -> Option<ToolKind> {
    let tool_name = input.get("toolName").and_then(Value::as_str)?;
    match tool_name.to_ascii_lowercase().as_str() {
        "bash" => Some(ToolKind::Bash),
        "view" | "read" => Some(ToolKind::Read),
        "write" | "edit" => Some(ToolKind::Write),
        _ => None,
    }
}

fn command_text(tool_args: &Map<String, Value>) -> Option<&str> {
    tool_args
        .get("command")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
}

fn should_passthrough(command: &str, session_exec_bin: &str, session_key: &str) -> bool {
    let prefix = session_exec_proxy_prefix(session_exec_bin, session_key);
    command == prefix || command.starts_with(&format!("{prefix} "))
}

fn session_exec_proxy_prefix(session_exec_bin: &str, session_key: &str) -> String {
    [
        shell_quote(session_exec_bin),
        "proxy".to_string(),
        "--session-key".to_string(),
        shell_quote(session_key),
    ]
    .join(" ")
}

fn rewritten_command(
    input: &Map<String, Value>,
    session_exec_bin: &str,
    session_key: &str,
    command: &str,
) -> String {
    let cwd = input
        .get("cwd")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| current_directory().display().to_string());
    let command_base64 = BASE64_STANDARD.encode(command.as_bytes());

    [
        session_exec_proxy_prefix(session_exec_bin, session_key),
        "--cwd".to_string(),
        shell_quote(&cwd),
        "--command-base64".to_string(),
        shell_quote(&command_base64),
    ]
    .join(" ")
}

fn path_arg<'a>(
    tool_args: &'a Map<String, Value>,
    tool_label: &str,
) -> Result<(String, &'a str), String> {
    for key in ["path", "file_path", "filePath"] {
        if let Some(path) = tool_args
            .get(key)
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
        {
            return Ok((key.to_string(), path));
        }
    }
    Err(format!(
        "preToolUse: {tool_label} requires a non-empty path argument"
    ))
}

fn path_uses_shared_workspace(
    input: &Map<String, Value>,
    tool_args: &Map<String, Value>,
    tool_label: &str,
) -> Result<bool, String> {
    let (_, path) = path_arg(tool_args, tool_label)?;
    Ok(is_shared_workspace_path(&cwd_text(input), path))
}

fn non_workspace_file_tool_reason(tool_label: &str) -> String {
    format!(
        "preToolUse: {tool_label} path is outside the shared workspace; the built-in file tool would run against the control-plane filesystem, and copying from the Exec Pod would not preserve path semantics. Use Bash for non-workspace Exec Pod file access."
    )
}

fn is_shared_workspace_path(cwd: &str, path: &str) -> bool {
    let workspace_root = normalize_path(&shared_workspace_root());
    let path = Path::new(path);
    let raw_candidate = if path.is_absolute() {
        path.to_path_buf()
    } else {
        Path::new(cwd).join(path)
    };
    let candidate = normalize_path(&raw_candidate);

    (candidate == workspace_root || candidate.starts_with(&workspace_root))
        && symlink_components_stay_in_workspace(&raw_candidate, &workspace_root)
}

fn symlink_components_stay_in_workspace(raw_candidate: &Path, workspace_root: &Path) -> bool {
    let canonical_workspace_root = match fs::canonicalize(workspace_root) {
        Ok(path) => normalize_path(&path),
        Err(_) => return false,
    };
    let mut current = PathBuf::new();

    for component in raw_candidate.components() {
        match component {
            Component::Prefix(prefix) => current.push(prefix.as_os_str()),
            Component::RootDir => current.push(Path::new("/")),
            Component::CurDir => {}
            Component::ParentDir => {
                current.pop();
            }
            Component::Normal(value) => {
                current.push(value);
                let Ok(metadata) = fs::symlink_metadata(&current) else {
                    continue;
                };
                if !metadata.file_type().is_symlink() {
                    continue;
                }
                let Ok(resolved) = fs::canonicalize(&current) else {
                    return false;
                };
                current = normalize_path(&resolved);
                if !is_path_under_root(&current, &canonical_workspace_root) {
                    return false;
                }
            }
        }
    }

    is_path_under_root(&normalize_path(&current), &canonical_workspace_root)
}

fn is_path_under_root(path: &Path, root: &Path) -> bool {
    path == root || path.starts_with(root)
}

fn shared_workspace_root() -> PathBuf {
    env_path("CONTROL_PLANE_WORKSPACE_MOUNT_PATH")
        .or_else(|| env_path("CONTROL_PLANE_WORKSPACE"))
        .unwrap_or_else(|| PathBuf::from("/workspace"))
}

fn env_path(name: &str) -> Option<PathBuf> {
    env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

fn normalize_path(path: &Path) -> PathBuf {
    let mut normalized = PathBuf::new();
    let mut absolute = false;
    for component in path.components() {
        match component {
            Component::Prefix(prefix) => normalized.push(prefix.as_os_str()),
            Component::RootDir => {
                normalized.push(Path::new("/"));
                absolute = true;
            }
            Component::CurDir => {}
            Component::ParentDir => {
                if !normalized.pop() && !absolute {
                    normalized.push("..");
                }
            }
            Component::Normal(value) => normalized.push(value),
        }
    }
    normalized
}

fn cwd_text(input: &Map<String, Value>) -> String {
    input
        .get("cwd")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| current_directory().display().to_string())
}

fn parse_input_object(raw_input: &str) -> Result<Map<String, Value>, String> {
    parse_json_object_input(raw_input, "hook input")
}

fn parse_tool_args(tool_args: Option<&Value>) -> Result<Map<String, Value>, String> {
    match tool_args {
        None | Some(Value::Null) => Ok(Map::new()),
        Some(Value::Object(object)) => Ok(object.clone()),
        Some(Value::String(raw)) => parse_serialized_tool_args(raw),
        _ => Err("preToolUse toolArgs must be a JSON object or JSON object string".to_string()),
    }
}

fn parse_serialized_tool_args(raw: &str) -> Result<Map<String, Value>, String> {
    let parsed: Value = serde_json::from_str(raw).map_err(|error| error.to_string())?;
    let Value::Object(object) = parsed else {
        return Err("preToolUse toolArgs must decode to a JSON object".to_string());
    };
    Ok(object)
}

fn prepare_execution_pod(session_exec_bin: &str, session_key: &str) -> Result<(), String> {
    let output = Command::new(session_exec_bin)
        .arg("prepare")
        .arg("--session-key")
        .arg(session_key)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|error| format!("failed to prepare session execution pod: {error}"))?;

    if output.status.success() {
        Ok(())
    } else {
        Err(output_message(
            &output,
            "failed to prepare session execution pod",
        ))
    }
}

fn deny_json(message: &str) -> String {
    json!({
        "permissionDecision": "deny",
        "permissionDecisionReason": message,
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use std::fs;

    use serde_json::{Value, json};
    use tempfile::TempDir;

    use crate::support::shell_quote;
    use crate::test_support::{EnvRestore, lock_env, write_executable};

    use super::handle;

    #[test]
    fn rewrites_bash_command() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let helper_path = temp_dir.path().join("control-plane-session-exec");
        write_executable(
            &helper_path,
            "#!/usr/bin/env bash\nset -euo pipefail\nif [[ \"$1\" == prepare ]]; then exit 0; fi\nexit 1\n",
        );

        let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
        let _session_exec = EnvRestore::set(
            "CONTROL_PLANE_SESSION_EXEC_BIN",
            helper_path.to_str().unwrap(),
        );
        let _session_key = EnvRestore::set("CONTROL_PLANE_HOOK_SESSION_KEY", "session-123");

        let output = handle(
            r#"{"toolName":"bash","cwd":"/workspace","toolArgs":{"command":"echo hello","description":"demo"}}"#,
        )
        .unwrap();
        let value: Value = serde_json::from_str(&output).unwrap();

        assert_eq!(value["permissionDecision"], "allow");
        let command = value["modifiedArgs"]["command"].as_str().unwrap();
        assert!(command.contains("proxy"));
        assert!(command.contains("--session-key 'session-123'"));
        assert!(command.contains("--cwd '/workspace'"));
        assert!(command.contains("--command-base64 'ZWNobyBoZWxsbw=='"));
    }

    #[test]
    fn passes_through_same_session_proxy_command() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let helper_path = temp_dir.path().join("control-plane-session-exec");
        write_executable(
            &helper_path,
            "#!/usr/bin/env bash\nset -euo pipefail\nprintf 'unexpected helper call\\n' >&2\nexit 1\n",
        );

        let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
        let _session_exec = EnvRestore::set(
            "CONTROL_PLANE_SESSION_EXEC_BIN",
            helper_path.to_str().unwrap(),
        );
        let _session_key = EnvRestore::set("CONTROL_PLANE_HOOK_SESSION_KEY", "session-123");

        let proxied_command = [
            shell_quote(helper_path.to_str().unwrap()),
            "proxy".to_string(),
            "--session-key".to_string(),
            shell_quote("session-123"),
            "--cwd".to_string(),
            shell_quote("/workspace"),
            "--command-base64".to_string(),
            shell_quote("ZWNobyBoZWxsbw=="),
        ]
        .join(" ");
        let input = json!({
            "toolName": "bash",
            "cwd": "/workspace",
            "toolArgs": {
                "command": proxied_command,
                "description": "demo"
            }
        })
        .to_string();

        assert!(handle(&input).is_none());
    }

    #[test]
    fn denies_on_prepare_failure() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let helper_path = temp_dir.path().join("control-plane-session-exec");
        write_executable(
            &helper_path,
            "#!/usr/bin/env bash\nset -euo pipefail\nprintf 'prepare exploded\\n' >&2\nexit 1\n",
        );

        let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
        let _session_exec = EnvRestore::set(
            "CONTROL_PLANE_SESSION_EXEC_BIN",
            helper_path.to_str().unwrap(),
        );

        let output = handle(
            r#"{"toolName":"bash","toolArgs":{"command":"echo hello","description":"demo"}}"#,
        )
        .unwrap();
        let value: Value = serde_json::from_str(&output).unwrap();

        assert_eq!(value["permissionDecision"], "deny");
        assert_eq!(value["permissionDecisionReason"], "prepare exploded");
    }

    #[test]
    fn denies_read_tool_for_non_workspace_path_without_copying() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let helper_path = temp_dir.path().join("control-plane-session-exec");
        write_executable(
            &helper_path,
            "#!/usr/bin/env bash\nset -euo pipefail\nprintf 'unexpected helper call\\n' >&2\nexit 1\n",
        );
        let cache_dir = temp_dir.path().join("hook-cache");

        let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
        let _session_exec = EnvRestore::set(
            "CONTROL_PLANE_SESSION_EXEC_BIN",
            helper_path.to_str().unwrap(),
        );
        let _session_key = EnvRestore::set("CONTROL_PLANE_HOOK_SESSION_KEY", "session-123");
        let _cache_root =
            EnvRestore::set("CONTROL_PLANE_HOOK_TMP_ROOT", cache_dir.to_str().unwrap());

        let output = handle(
            r#"{"toolName":"Read","cwd":"/workspace","toolArgs":{"file_path":"/var/tmp/control-plane/remote.txt","limit":200}}"#,
        )
        .unwrap();
        let value: Value = serde_json::from_str(&output).unwrap();

        assert_eq!(value["permissionDecision"], "deny");
        let reason = value["permissionDecisionReason"].as_str().unwrap();
        assert!(
            reason.contains("built-in file tool would run against the control-plane filesystem")
        );
        assert!(reason.contains("copying from the Exec Pod would not preserve path semantics"));
        assert!(reason.contains("Use Bash for non-workspace Exec Pod file access"));
        assert!(!cache_dir.exists());
    }

    #[test]
    fn denies_view_tool_for_non_workspace_path_without_copying() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let helper_path = temp_dir.path().join("control-plane-session-exec");
        write_executable(
            &helper_path,
            "#!/usr/bin/env bash\nset -euo pipefail\nprintf 'unexpected helper call\\n' >&2\nexit 1\n",
        );
        let cache_dir = temp_dir.path().join("hook-cache");

        let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
        let _session_exec = EnvRestore::set(
            "CONTROL_PLANE_SESSION_EXEC_BIN",
            helper_path.to_str().unwrap(),
        );
        let _session_key = EnvRestore::set("CONTROL_PLANE_HOOK_SESSION_KEY", "session-123");
        let _cache_root =
            EnvRestore::set("CONTROL_PLANE_HOOK_TMP_ROOT", cache_dir.to_str().unwrap());

        let output = handle(
            r#"{"toolName":"view","cwd":"/workspace","toolArgs":{"path":"/var/tmp/control-plane/remote.txt","limit":200}}"#,
        )
        .unwrap();
        let value: Value = serde_json::from_str(&output).unwrap();

        assert_eq!(value["permissionDecision"], "deny");
        assert!(
            value["permissionDecisionReason"]
                .as_str()
                .unwrap()
                .contains("copying from the Exec Pod would not preserve path semantics")
        );
        assert!(!cache_dir.exists());
    }

    #[test]
    fn denies_write_tool_for_non_workspace_path_without_marker_file() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let helper_path = temp_dir.path().join("control-plane-session-exec");
        write_executable(
            &helper_path,
            "#!/usr/bin/env bash\nset -euo pipefail\nprintf 'unexpected helper call\\n' >&2\nexit 1\n",
        );
        let cache_dir = temp_dir.path().join("hook-cache");

        let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
        let _session_exec = EnvRestore::set(
            "CONTROL_PLANE_SESSION_EXEC_BIN",
            helper_path.to_str().unwrap(),
        );
        let _session_key = EnvRestore::set("CONTROL_PLANE_HOOK_SESSION_KEY", "session-123");
        let _cache_root =
            EnvRestore::set("CONTROL_PLANE_HOOK_TMP_ROOT", cache_dir.to_str().unwrap());

        let output = handle(
            r#"{"toolName":"Write","cwd":"/workspace","toolArgs":{"file_path":"/var/tmp/control-plane/new.txt","content":"hello\nworld\n"}}"#,
        )
        .unwrap();
        let value: Value = serde_json::from_str(&output).unwrap();

        assert_eq!(value["permissionDecision"], "deny");
        let reason = value["permissionDecisionReason"].as_str().unwrap();
        assert!(
            reason.contains("built-in file tool would run against the control-plane filesystem")
        );
        assert!(reason.contains("copying from the Exec Pod would not preserve path semantics"));
        assert!(reason.contains("Use Bash for non-workspace Exec Pod file access"));
        assert!(!cache_dir.exists());
    }

    #[test]
    fn denies_edit_tool_for_non_workspace_path_without_marker_file() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let helper_path = temp_dir.path().join("control-plane-session-exec");
        write_executable(
            &helper_path,
            "#!/usr/bin/env bash\nset -euo pipefail\nprintf 'unexpected helper call\\n' >&2\nexit 1\n",
        );
        let cache_dir = temp_dir.path().join("hook-cache");

        let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
        let _session_exec = EnvRestore::set(
            "CONTROL_PLANE_SESSION_EXEC_BIN",
            helper_path.to_str().unwrap(),
        );
        let _session_key = EnvRestore::set("CONTROL_PLANE_HOOK_SESSION_KEY", "session-123");
        let _cache_root =
            EnvRestore::set("CONTROL_PLANE_HOOK_TMP_ROOT", cache_dir.to_str().unwrap());

        let output = handle(
            r#"{"toolName":"edit","cwd":"/workspace","toolArgs":{"path":"/var/tmp/control-plane/edit.txt","text":"edited\n"}}"#,
        )
        .unwrap();
        let value: Value = serde_json::from_str(&output).unwrap();

        assert_eq!(value["permissionDecision"], "deny");
        assert!(
            value["permissionDecisionReason"]
                .as_str()
                .unwrap()
                .contains("copying from the Exec Pod would not preserve path semantics")
        );
        assert!(!cache_dir.exists());
    }

    #[test]
    fn passes_read_tool_through_for_shared_workspace_path() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let helper_path = temp_dir.path().join("control-plane-session-exec");
        write_executable(
            &helper_path,
            "#!/usr/bin/env bash\nset -euo pipefail\nprintf 'unexpected helper call\\n' >&2\nexit 1\n",
        );

        let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
        let _session_exec = EnvRestore::set(
            "CONTROL_PLANE_SESSION_EXEC_BIN",
            helper_path.to_str().unwrap(),
        );
        let workspace = temp_dir.path().join("workspace");
        fs::create_dir_all(&workspace).unwrap();
        let _workspace = EnvRestore::set(
            "CONTROL_PLANE_WORKSPACE_MOUNT_PATH",
            workspace.to_str().unwrap(),
        );
        let input = json!({
            "toolName": "Read",
            "cwd": workspace,
            "toolArgs": {
                "file_path": temp_dir.path().join("workspace").join("shared.txt")
            }
        })
        .to_string();

        assert!(handle(&input).is_none());
    }

    #[test]
    fn passes_write_tool_through_for_relative_shared_workspace_path() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let helper_path = temp_dir.path().join("control-plane-session-exec");
        write_executable(
            &helper_path,
            "#!/usr/bin/env bash\nset -euo pipefail\nprintf 'unexpected helper call\\n' >&2\nexit 1\n",
        );

        let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
        let _session_exec = EnvRestore::set(
            "CONTROL_PLANE_SESSION_EXEC_BIN",
            helper_path.to_str().unwrap(),
        );
        let workspace = temp_dir.path().join("workspace");
        let project = workspace.join("project");
        fs::create_dir_all(&project).unwrap();
        let _workspace = EnvRestore::set(
            "CONTROL_PLANE_WORKSPACE_MOUNT_PATH",
            workspace.to_str().unwrap(),
        );
        let input = json!({
            "toolName": "Write",
            "cwd": project,
            "toolArgs": {
                "file_path": "src/shared.txt",
                "content": "shared\n"
            }
        })
        .to_string();

        assert!(handle(&input).is_none());
    }

    #[test]
    fn denies_read_tool_when_path_traversal_escapes_workspace() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let helper_path = temp_dir.path().join("control-plane-session-exec");
        write_executable(
            &helper_path,
            "#!/usr/bin/env bash\nset -euo pipefail\nprintf 'unexpected helper call\\n' >&2\nexit 1\n",
        );
        let cache_dir = temp_dir.path().join("hook-cache");

        let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
        let _session_exec = EnvRestore::set(
            "CONTROL_PLANE_SESSION_EXEC_BIN",
            helper_path.to_str().unwrap(),
        );
        let _session_key = EnvRestore::set("CONTROL_PLANE_HOOK_SESSION_KEY", "session-123");
        let _cache_root =
            EnvRestore::set("CONTROL_PLANE_HOOK_TMP_ROOT", cache_dir.to_str().unwrap());
        let _workspace = EnvRestore::set("CONTROL_PLANE_WORKSPACE_MOUNT_PATH", "/workspace");

        let output = handle(
            r#"{"toolName":"Read","cwd":"/workspace","toolArgs":{"file_path":"/workspace/../etc/config"}}"#,
        )
        .unwrap();
        let value: Value = serde_json::from_str(&output).unwrap();

        assert_eq!(value["permissionDecision"], "deny");
        assert!(
            value["permissionDecisionReason"]
                .as_str()
                .unwrap()
                .contains("copying from the Exec Pod would not preserve path semantics")
        );
        assert!(!cache_dir.exists());
    }

    #[test]
    fn denies_write_tool_for_near_workspace_prefix() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let helper_path = temp_dir.path().join("control-plane-session-exec");
        write_executable(
            &helper_path,
            "#!/usr/bin/env bash\nset -euo pipefail\nprintf 'unexpected helper call\\n' >&2\nexit 1\n",
        );
        let cache_dir = temp_dir.path().join("hook-cache");

        let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
        let _session_exec = EnvRestore::set(
            "CONTROL_PLANE_SESSION_EXEC_BIN",
            helper_path.to_str().unwrap(),
        );
        let _session_key = EnvRestore::set("CONTROL_PLANE_HOOK_SESSION_KEY", "session-123");
        let _cache_root =
            EnvRestore::set("CONTROL_PLANE_HOOK_TMP_ROOT", cache_dir.to_str().unwrap());
        let _workspace = EnvRestore::set("CONTROL_PLANE_WORKSPACE_MOUNT_PATH", "/workspace");

        let output = handle(
            r#"{"toolName":"Write","cwd":"/workspace","toolArgs":{"file_path":"/workspace-other/file.txt","content":"outside\n"}}"#,
        )
        .unwrap();
        let value: Value = serde_json::from_str(&output).unwrap();

        assert_eq!(value["permissionDecision"], "deny");
        assert!(
            value["permissionDecisionReason"]
                .as_str()
                .unwrap()
                .contains("copying from the Exec Pod would not preserve path semantics")
        );
        assert!(!cache_dir.exists());
    }

    #[test]
    fn passes_read_tool_through_when_normalized_relative_path_stays_in_workspace() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let helper_path = temp_dir.path().join("control-plane-session-exec");
        write_executable(
            &helper_path,
            "#!/usr/bin/env bash\nset -euo pipefail\nprintf 'unexpected helper call\\n' >&2\nexit 1\n",
        );

        let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
        let _session_exec = EnvRestore::set(
            "CONTROL_PLANE_SESSION_EXEC_BIN",
            helper_path.to_str().unwrap(),
        );
        let workspace = temp_dir.path().join("workspace");
        let subdir = workspace.join("subdir");
        fs::create_dir_all(&subdir).unwrap();
        let _workspace = EnvRestore::set(
            "CONTROL_PLANE_WORKSPACE_MOUNT_PATH",
            workspace.to_str().unwrap(),
        );
        let input = json!({
            "toolName": "Read",
            "cwd": subdir,
            "toolArgs": {
                "file_path": "../shared.txt"
            }
        })
        .to_string();

        assert!(handle(&input).is_none());
    }

    #[cfg(unix)]
    #[test]
    fn denies_read_tool_when_workspace_symlink_points_outside() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let workspace = temp_dir.path().join("workspace");
        let outside = temp_dir.path().join("outside");
        fs::create_dir_all(&workspace).unwrap();
        fs::create_dir_all(&outside).unwrap();
        fs::write(outside.join("secret.txt"), "secret\n").unwrap();
        std::os::unix::fs::symlink(outside.join("secret.txt"), workspace.join("secret-link"))
            .unwrap();

        let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
        let _workspace = EnvRestore::set(
            "CONTROL_PLANE_WORKSPACE_MOUNT_PATH",
            workspace.to_str().unwrap(),
        );
        let input = json!({
            "toolName": "Read",
            "cwd": workspace,
            "toolArgs": {
                "file_path": temp_dir.path().join("workspace").join("secret-link")
            }
        })
        .to_string();

        let output = handle(&input).unwrap();
        let value: Value = serde_json::from_str(&output).unwrap();

        assert_eq!(value["permissionDecision"], "deny");
        assert!(
            value["permissionDecisionReason"]
                .as_str()
                .unwrap()
                .contains("copying from the Exec Pod would not preserve path semantics")
        );
    }

    #[cfg(unix)]
    #[test]
    fn denies_write_tool_when_workspace_parent_symlink_points_outside() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let workspace = temp_dir.path().join("workspace");
        let outside = temp_dir.path().join("outside");
        fs::create_dir_all(&workspace).unwrap();
        fs::create_dir_all(&outside).unwrap();
        std::os::unix::fs::symlink(&outside, workspace.join("outside-link")).unwrap();

        let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
        let _workspace = EnvRestore::set(
            "CONTROL_PLANE_WORKSPACE_MOUNT_PATH",
            workspace.to_str().unwrap(),
        );
        let input = json!({
            "toolName": "Write",
            "cwd": workspace,
            "toolArgs": {
                "file_path": temp_dir.path().join("workspace").join("outside-link").join("new.txt"),
                "content": "outside\n"
            }
        })
        .to_string();

        let output = handle(&input).unwrap();
        let value: Value = serde_json::from_str(&output).unwrap();

        assert_eq!(value["permissionDecision"], "deny");
        assert!(
            value["permissionDecisionReason"]
                .as_str()
                .unwrap()
                .contains("copying from the Exec Pod would not preserve path semantics")
        );
    }

    #[cfg(unix)]
    #[test]
    fn passes_read_tool_through_when_workspace_symlink_stays_inside() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let workspace = temp_dir.path().join("workspace");
        let target_dir = workspace.join("target");
        fs::create_dir_all(&target_dir).unwrap();
        fs::write(target_dir.join("shared.txt"), "shared\n").unwrap();
        std::os::unix::fs::symlink(target_dir.join("shared.txt"), workspace.join("shared-link"))
            .unwrap();

        let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
        let _workspace = EnvRestore::set(
            "CONTROL_PLANE_WORKSPACE_MOUNT_PATH",
            workspace.to_str().unwrap(),
        );
        let input = json!({
            "toolName": "Read",
            "cwd": workspace,
            "toolArgs": {
                "file_path": temp_dir.path().join("workspace").join("shared-link")
            }
        })
        .to_string();

        assert!(handle(&input).is_none());
    }

    #[cfg(unix)]
    #[test]
    fn denies_read_tool_when_workspace_symlink_then_parent_escapes() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let workspace = temp_dir.path().join("workspace");
        let link_parent = workspace.join("a").join("b");
        fs::create_dir_all(&link_parent).unwrap();
        std::os::unix::fs::symlink(&workspace, link_parent.join("link")).unwrap();

        let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
        let _workspace = EnvRestore::set(
            "CONTROL_PLANE_WORKSPACE_MOUNT_PATH",
            workspace.to_str().unwrap(),
        );
        let input = json!({
            "toolName": "Read",
            "cwd": workspace,
            "toolArgs": {
                "file_path": temp_dir
                    .path()
                    .join("workspace")
                    .join("a")
                    .join("b")
                    .join("link")
                    .join("..")
                    .join("..")
                    .join("etc")
                    .join("passwd")
            }
        })
        .to_string();

        let output = handle(&input).unwrap();
        let value: Value = serde_json::from_str(&output).unwrap();

        assert_eq!(value["permissionDecision"], "deny");
        assert!(
            value["permissionDecisionReason"]
                .as_str()
                .unwrap()
                .contains("copying from the Exec Pod would not preserve path semantics")
        );
    }
}
