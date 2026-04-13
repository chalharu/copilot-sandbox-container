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
    if !should_rewrite(&input) {
        return None;
    }

    let mut tool_args = match parse_tool_args(input.get("toolArgs")) {
        Ok(value) => value,
        Err(message) => return Some(deny_json(&message)),
    };
    let command = command_text(&tool_args)?;

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

    Some(
        json!({
            "permissionDecision": "allow",
            "modifiedArgs": Value::Object(tool_args),
        })
        .to_string(),
    )
}

fn should_rewrite(input: &Map<String, Value>) -> bool {
    input.get("toolName").and_then(Value::as_str) == Some("bash") && fast_execution_enabled()
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
}
