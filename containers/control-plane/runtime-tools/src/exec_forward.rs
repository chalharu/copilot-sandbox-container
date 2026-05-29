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
        ToolKind::Read => {
            match path_uses_passthrough_root(&input, &tool_args, "Read", FileToolAccess::Read) {
                Ok(true) => return None,
                Ok(false) => {
                    return Some(deny_json(&non_workspace_file_tool_reason(
                        "Read",
                        FileToolAccess::Read,
                    )));
                }
                Err(message) => return Some(deny_json(&message)),
            }
        }
        ToolKind::Write => {
            match path_uses_passthrough_root(&input, &tool_args, "Write", FileToolAccess::Write) {
                Ok(true) => return None,
                Ok(false) => {
                    return Some(deny_json(&non_workspace_file_tool_reason(
                        "Write",
                        FileToolAccess::Write,
                    )));
                }
                Err(message) => return Some(deny_json(&message)),
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FileToolAccess {
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

fn path_uses_passthrough_root(
    input: &Map<String, Value>,
    tool_args: &Map<String, Value>,
    tool_label: &str,
    access: FileToolAccess,
) -> Result<bool, String> {
    let (_, path) = path_arg(tool_args, tool_label)?;
    Ok(is_file_tool_passthrough_path(
        &cwd_text(input),
        path,
        access,
    ))
}

fn non_workspace_file_tool_reason(tool_label: &str, access: FileToolAccess) -> String {
    let local_root_scope = match access {
        FileToolAccess::Read => "control-plane local roots",
        FileToolAccess::Write => "control-plane writable local roots",
    };
    format!(
        "preToolUse: {tool_label} path is outside the shared workspace and {local_root_scope}; the built-in file tool would run against the control-plane filesystem, and copying from the Exec Pod would not preserve path semantics. Use Bash for non-workspace Exec Pod file access."
    )
}

fn is_file_tool_passthrough_path(cwd: &str, path: &str, access: FileToolAccess) -> bool {
    is_shared_workspace_path(cwd, path) || is_control_plane_local_path(cwd, path, access)
}

fn is_shared_workspace_path(cwd: &str, path: &str) -> bool {
    path_stays_under_root(cwd, path, &shared_workspace_root())
}

fn is_control_plane_local_path(cwd: &str, path: &str, access: FileToolAccess) -> bool {
    control_plane_local_roots(access)
        .iter()
        .any(|root| path_stays_under_root(cwd, path, root))
}

fn path_stays_under_root(cwd: &str, path: &str, root: &Path) -> bool {
    let root = normalize_path(root);
    let canonical_root = match fs::canonicalize(&root) {
        Ok(path) => normalize_path(&path),
        Err(_) => return false,
    };
    let path = Path::new(path);
    let raw_candidate = if path.is_absolute() {
        path.to_path_buf()
    } else {
        Path::new(cwd).join(path)
    };
    let candidate = normalize_path(&raw_candidate);

    (is_path_under_root(&candidate, &root) || is_path_under_root(&candidate, &canonical_root))
        && symlink_components_stay_in_root(&raw_candidate, &root)
}

fn symlink_components_stay_in_root(raw_candidate: &Path, root: &Path) -> bool {
    let canonical_root = match fs::canonicalize(root) {
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
                if !is_path_under_root(&current, &canonical_root)
                    && !is_path_under_root(&canonical_root, &current)
                {
                    return false;
                }
            }
        }
    }

    is_path_under_root(&normalize_path(&current), &canonical_root)
}

fn is_path_under_root(path: &Path, root: &Path) -> bool {
    path == root || path.starts_with(root)
}

fn shared_workspace_root() -> PathBuf {
    env_path("CONTROL_PLANE_WORKSPACE_MOUNT_PATH")
        .or_else(|| env_path("CONTROL_PLANE_WORKSPACE"))
        .unwrap_or_else(|| PathBuf::from("/workspace"))
}

fn control_plane_local_roots(access: FileToolAccess) -> Vec<PathBuf> {
    match access {
        FileToolAccess::Read => control_plane_read_roots(),
        FileToolAccess::Write => control_plane_write_roots(),
    }
}

fn control_plane_read_roots() -> Vec<PathBuf> {
    let mut roots = control_plane_write_roots();
    roots.extend(env_paths("CONTROL_PLANE_LOCAL_FILE_ROOTS"));
    roots.extend(env_paths("CONTROL_PLANE_LOCAL_READ_ONLY_ROOTS"));

    let home_dir = home_dir();
    roots.push(home_dir.join(".config").join("control-plane"));
    roots.push(home_dir.join(".config").join("gh"));
    roots.push(home_dir.join(".ssh"));
    roots.push(PathBuf::from("/var/lib/control-plane/ssh-host-keys"));
    roots.push(PathBuf::from("/run/control-plane"));
    roots
}

fn control_plane_write_roots() -> Vec<PathBuf> {
    let mut roots: Vec<PathBuf> = env_paths("CONTROL_PLANE_LOCAL_READ_WRITE_ROOTS");

    let copilot_home = copilot_home();
    roots.push(copilot_home.join("session-state"));
    roots.push(copilot_home.join("tmp"));
    if let Some(path) = env_path("CONTROL_PLANE_HOOK_TMP_ROOT") {
        roots.push(path);
    }
    roots.push(control_plane_tmp_root());
    roots
}

fn env_paths(name: &str) -> Vec<PathBuf> {
    env::var_os(name)
        .map(|value| env::split_paths(&value).collect())
        .unwrap_or_default()
}

fn copilot_home() -> PathBuf {
    env_path("COPILOT_HOME").unwrap_or_else(|| home_dir().join(".copilot"))
}

fn home_dir() -> PathBuf {
    env_path("HOME").unwrap_or_else(|| PathBuf::from("/home/copilot"))
}

fn control_plane_tmp_root() -> PathBuf {
    env_path("CONTROL_PLANE_TMP_ROOT").unwrap_or_else(|| PathBuf::from("/var/tmp/control-plane"))
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
mod tests;
