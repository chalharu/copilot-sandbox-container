use std::env;
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Output, Stdio};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use serde_json::{Map, Value, json};
use uuid::Uuid;

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
        ToolKind::Read => {
            match path_uses_shared_workspace(&input, &tool_args, "Read") {
                Ok(true) => return None,
                Ok(false) => {}
                Err(message) => return Some(deny_json(&message)),
            }
            let session_exec_bin = session_exec_bin();
            let session_key = match session_key() {
                Ok(value) => value,
                Err(message) => return Some(deny_json(&message)),
            };
            if let Err(message) = prepare_execution_pod(&session_exec_bin, &session_key) {
                return Some(deny_json(&message));
            }
            if let Err(message) =
                forward_read_tool(&input, &mut tool_args, &session_exec_bin, &session_key)
            {
                return Some(deny_json(&message));
            }
        }
        ToolKind::Write => {
            match path_uses_shared_workspace(&input, &tool_args, "Write") {
                Ok(true) => return None,
                Ok(false) => {}
                Err(message) => return Some(deny_json(&message)),
            }
            let session_exec_bin = session_exec_bin();
            let session_key = match session_key() {
                Ok(value) => value,
                Err(message) => return Some(deny_json(&message)),
            };
            if let Err(message) = prepare_execution_pod(&session_exec_bin, &session_key) {
                return Some(deny_json(&message));
            }
            if let Err(message) =
                forward_write_tool(&input, &mut tool_args, &session_exec_bin, &session_key)
            {
                return Some(deny_json(&message));
            }
        }
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

fn forward_read_tool(
    input: &Map<String, Value>,
    tool_args: &mut Map<String, Value>,
    session_exec_bin: &str,
    session_key: &str,
) -> Result<(), String> {
    let (path_key, remote_path) = path_arg(tool_args, "Read")?;
    let remote_path = remote_path.to_string();
    let command = format!("cat -- {}", shell_quote(&remote_path));
    let output = run_session_exec_proxy(session_exec_bin, session_key, &cwd_text(input), &command)?;
    if !output.status.success() {
        return Err(output_message(
            &output,
            "failed to read file from session execution pod",
        ));
    }

    let prefix = format!("$ {command}\n").into_bytes();
    let Some(contents) = output.stdout.strip_prefix(prefix.as_slice()) else {
        return Err("failed to parse session execution pod read output".to_string());
    };
    let local_path = write_local_tool_file("read", contents)?;
    tool_args.insert(path_key, Value::String(local_path.display().to_string()));
    Ok(())
}

fn forward_write_tool(
    input: &Map<String, Value>,
    tool_args: &mut Map<String, Value>,
    session_exec_bin: &str,
    session_key: &str,
) -> Result<(), String> {
    let (path_key, remote_path) = path_arg(tool_args, "Write")?;
    let remote_path = remote_path.to_string();
    let (content_key, content) = content_arg(tool_args)?;
    let content = content.to_string();
    let command = write_remote_file_command(&remote_path, &content);
    let output = run_session_exec_proxy(session_exec_bin, session_key, &cwd_text(input), &command)?;
    if !output.status.success() {
        return Err(output_message(
            &output,
            "failed to write file in session execution pod",
        ));
    }

    let marker_path = write_local_tool_file(
        "write",
        format!("Exec Pod write completed for {remote_path}\n").as_bytes(),
    )?;
    tool_args.insert(path_key, Value::String(marker_path.display().to_string()));
    tool_args.insert(
        content_key,
        Value::String(format!("Exec Pod write completed for {remote_path}\n")),
    );
    Ok(())
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

fn is_shared_workspace_path(cwd: &str, path: &str) -> bool {
    let workspace_root = normalize_path(&shared_workspace_root());
    let path = Path::new(path);
    let candidate = if path.is_absolute() {
        path.to_path_buf()
    } else {
        Path::new(cwd).join(path)
    };
    let candidate = normalize_path(&candidate);

    candidate == workspace_root || candidate.starts_with(&workspace_root)
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

fn content_arg(tool_args: &Map<String, Value>) -> Result<(String, &str), String> {
    for key in ["content", "text"] {
        if let Some(content) = tool_args.get(key).and_then(Value::as_str) {
            return Ok((key.to_string(), content));
        }
    }
    Err("preToolUse: Write requires 'content' or 'text'".to_string())
}

fn cwd_text(input: &Map<String, Value>) -> String {
    input
        .get("cwd")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| current_directory().display().to_string())
}

fn write_remote_file_command(path: &str, content: &str) -> String {
    let encoded = BASE64_STANDARD.encode(content.as_bytes());
    format!(
        "set -euo pipefail\npath={}\nparent=$(dirname -- \"$path\")\nmkdir -p -- \"$parent\"\nprintf '%s' {} | base64 -d > \"$path\"",
        shell_quote(path),
        shell_quote(&encoded)
    )
}

fn run_session_exec_proxy(
    session_exec_bin: &str,
    session_key: &str,
    cwd: &str,
    command: &str,
) -> Result<Output, String> {
    Command::new(session_exec_bin)
        .arg("proxy")
        .arg("--session-key")
        .arg(session_key)
        .arg("--cwd")
        .arg(cwd)
        .arg("--command-base64")
        .arg(BASE64_STANDARD.encode(command.as_bytes()))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|error| format!("failed to execute command in session execution pod: {error}"))
}

fn write_local_tool_file(prefix: &str, contents: &[u8]) -> Result<PathBuf, String> {
    let directory = hook_cache_root().join("exec-forward");
    fs::create_dir_all(&directory).map_err(|error| {
        format!(
            "failed to create exec-forward hook cache directory {}: {error}",
            directory.display()
        )
    })?;
    let path = directory.join(format!("{prefix}-{}.tmp", Uuid::new_v4()));
    fs::write(&path, contents).map_err(|error| {
        format!(
            "failed to write exec-forward hook cache {}: {error}",
            path.display()
        )
    })?;
    Ok(path)
}

fn hook_cache_root() -> PathBuf {
    if let Some(path) = env::var_os("CONTROL_PLANE_HOOK_TMP_ROOT") {
        return PathBuf::from(path);
    }

    let tmp_root = env::var_os("CONTROL_PLANE_TMP_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/var/tmp/control-plane"));
    tmp_root.join("hooks")
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

    use base64::Engine as _;
    use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
    use serde_json::{Value, json};
    use tempfile::TempDir;

    use crate::support::shell_quote;
    use crate::test_support::{EnvRestore, lock_env, write_executable};

    use super::handle;

    fn write_proxy_stub(
        temp_dir: &TempDir,
        read_payload: &str,
    ) -> (std::path::PathBuf, std::path::PathBuf) {
        let helper_path = temp_dir.path().join("control-plane-session-exec");
        let log_path = temp_dir.path().join("session-exec.log");
        write_executable(
            &helper_path,
            &format!(
                r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "${{1:-}}" == prepare ]]; then
  exit 0
fi
if [[ "${{1:-}}" != proxy ]]; then
  printf 'unexpected subcommand: %s\n' "${{1:-}}" >&2
  exit 64
fi
command_base64=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --command-base64)
      command_base64="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
command="$(printf '%s' "$command_base64" | base64 -d)"
printf '%s\n' "$command" >> {}
printf '$ %s\n' "$command"
printf '%s' {}
"#,
                shell_quote(log_path.to_str().unwrap()),
                shell_quote(read_payload)
            ),
        );
        (helper_path, log_path)
    }

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
    fn rewrites_read_tool_to_local_copy_from_execution_pod() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let (helper_path, log_path) = write_proxy_stub(&temp_dir, "remote contents\n");
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

        assert_eq!(value["permissionDecision"], "allow");
        assert_eq!(value["modifiedArgs"]["limit"], 200);
        let local_path = value["modifiedArgs"]["file_path"].as_str().unwrap();
        assert_ne!(local_path, "/var/tmp/control-plane/remote.txt");
        assert!(local_path.starts_with(cache_dir.to_str().unwrap()));
        assert_eq!(fs::read_to_string(local_path).unwrap(), "remote contents\n");
        assert_eq!(
            fs::read_to_string(log_path).unwrap(),
            "cat -- '/var/tmp/control-plane/remote.txt'\n"
        );
    }

    #[test]
    fn rewrites_write_tool_after_writing_content_to_execution_pod() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let (helper_path, log_path) = write_proxy_stub(&temp_dir, "");
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

        assert_eq!(value["permissionDecision"], "allow");
        let local_path = value["modifiedArgs"]["file_path"].as_str().unwrap();
        assert_ne!(local_path, "/var/tmp/control-plane/new.txt");
        assert!(local_path.starts_with(cache_dir.to_str().unwrap()));
        assert_eq!(
            fs::read_to_string(local_path).unwrap(),
            "Exec Pod write completed for /var/tmp/control-plane/new.txt\n"
        );
        assert_eq!(
            value["modifiedArgs"]["content"],
            "Exec Pod write completed for /var/tmp/control-plane/new.txt\n"
        );
        let command_log = fs::read_to_string(log_path).unwrap();
        assert!(command_log.contains("path='/var/tmp/control-plane/new.txt'"));
        assert!(command_log.contains(&BASE64_STANDARD.encode("hello\nworld\n")));
        assert!(command_log.contains("base64 -d > \"$path\""));
    }

    #[test]
    fn rewrites_edit_tool_as_write_style_mutation() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let (helper_path, log_path) = write_proxy_stub(&temp_dir, "");
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

        assert_eq!(value["permissionDecision"], "allow");
        let local_path = value["modifiedArgs"]["path"].as_str().unwrap();
        assert_ne!(local_path, "/var/tmp/control-plane/edit.txt");
        assert_eq!(
            value["modifiedArgs"]["text"],
            "Exec Pod write completed for /var/tmp/control-plane/edit.txt\n"
        );
        let command_log = fs::read_to_string(log_path).unwrap();
        assert!(command_log.contains("path='/var/tmp/control-plane/edit.txt'"));
        assert!(command_log.contains(&BASE64_STANDARD.encode("edited\n")));
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
        let _workspace = EnvRestore::set("CONTROL_PLANE_WORKSPACE_MOUNT_PATH", "/workspace");

        assert!(
            handle(
                r#"{"toolName":"Read","cwd":"/workspace","toolArgs":{"file_path":"/workspace/shared.txt"}}"#
            )
            .is_none()
        );
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
        let _workspace = EnvRestore::set("CONTROL_PLANE_WORKSPACE_MOUNT_PATH", "/workspace");

        assert!(
            handle(
                r#"{"toolName":"Write","cwd":"/workspace/project","toolArgs":{"file_path":"src/shared.txt","content":"shared\n"}}"#
            )
            .is_none()
        );
    }
}
