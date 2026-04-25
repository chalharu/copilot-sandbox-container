use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Map, Value, json};

use crate::git;
use crate::support::{
    absolute_path, current_directory, parent_process_id, parse_json_object_input,
};

use super::redaction::redact_remote_url;

#[derive(Debug)]
pub(super) struct AuditEvent {
    pub(super) event_type: String,
    pub(super) created_at_ms: i64,
    pub(super) cwd: String,
    pub(super) repo_path: String,
    pub(super) ppid: Option<i64>,
    pub(super) git_remotes_json: Option<String>,
    pub(super) session_source: Option<String>,
    pub(super) initial_prompt: Option<String>,
    pub(super) user_prompt: Option<String>,
    pub(super) tool_name: Option<String>,
    pub(super) tool_args_json: Option<String>,
    pub(super) tool_result_type: Option<String>,
    pub(super) tool_result_text: Option<String>,
}

impl AuditEvent {
    pub(super) fn from_payload(
        event_type: &str,
        payload: &Map<String, Value>,
    ) -> Result<Self, String> {
        let cwd = resolve_cwd(payload)?;
        let repo_path = resolve_repo_path(&cwd);
        let tool_result = payload.get("toolResult").and_then(Value::as_object);

        Ok(Self {
            event_type: event_type.to_string(),
            created_at_ms: normalize_timestamp(payload.get("timestamp")),
            cwd: cwd.display().to_string(),
            repo_path: repo_path.display().to_string(),
            ppid: parent_process_id(),
            git_remotes_json: resolve_git_remotes(&repo_path),
            session_source: session_source(event_type, payload),
            initial_prompt: initial_prompt(event_type, payload),
            user_prompt: user_prompt(event_type, payload),
            tool_name: tool_name(event_type, payload),
            tool_args_json: tool_args_json(event_type, payload),
            tool_result_type: tool_result_type(event_type, tool_result),
            tool_result_text: tool_result_text(event_type, tool_result),
        })
    }

    pub(super) fn is_tool_event(&self) -> bool {
        matches!(self.event_type.as_str(), "preToolUse" | "postToolUse")
    }
}

pub(super) fn parse_hook_input(
    raw_input: &str,
    event_type: &str,
) -> Result<Map<String, Value>, String> {
    parse_json_object_input(raw_input, &format!("{event_type} hook input"))
}

fn resolve_cwd(payload: &Map<String, Value>) -> Result<PathBuf, String> {
    let cwd = payload
        .get("cwd")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(current_directory);
    absolute_path(&cwd).map_err(|error| error.to_string())
}

fn session_source(event_type: &str, payload: &Map<String, Value>) -> Option<String> {
    if event_type == "sessionStart" {
        normalize_text(payload.get("source"))
    } else {
        None
    }
}

fn initial_prompt(event_type: &str, payload: &Map<String, Value>) -> Option<String> {
    if event_type == "sessionStart" {
        normalize_text(payload.get("initialPrompt"))
    } else {
        None
    }
}

fn user_prompt(event_type: &str, payload: &Map<String, Value>) -> Option<String> {
    if event_type == "userPromptSubmitted" {
        normalize_text(payload.get("prompt"))
    } else {
        None
    }
}

fn tool_name(event_type: &str, payload: &Map<String, Value>) -> Option<String> {
    if matches!(event_type, "preToolUse" | "postToolUse") {
        normalize_text(payload.get("toolName"))
    } else {
        None
    }
}

fn tool_args_json(event_type: &str, payload: &Map<String, Value>) -> Option<String> {
    if matches!(event_type, "preToolUse" | "postToolUse") {
        normalize_tool_args(payload.get("toolArgs"))
    } else {
        None
    }
}

fn tool_result_type(event_type: &str, tool_result: Option<&Map<String, Value>>) -> Option<String> {
    if event_type == "postToolUse" {
        tool_result.and_then(|value| normalize_text(value.get("resultType")))
    } else {
        None
    }
}

fn tool_result_text(event_type: &str, tool_result: Option<&Map<String, Value>>) -> Option<String> {
    if event_type == "postToolUse" {
        tool_result.and_then(|value| normalize_text(value.get("textResultForLlm")))
    } else {
        None
    }
}

fn normalize_timestamp(value: Option<&Value>) -> i64 {
    if let Some(Value::Number(number)) = value {
        if let Some(value) = number.as_i64().filter(|value| *value >= 0) {
            return value;
        }
        if let Some(value) = number.as_u64().and_then(|value| i64::try_from(value).ok()) {
            return value;
        }
    }

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_else(|_| Duration::from_millis(0));
    i64::try_from(now.as_millis()).unwrap_or(i64::MAX)
}

fn normalize_text(value: Option<&Value>) -> Option<String> {
    match value {
        Some(Value::Null) | None => None,
        Some(Value::String(value)) => Some(value.clone()),
        Some(other) => Some(other.to_string()),
    }
}

fn normalize_tool_args(value: Option<&Value>) -> Option<String> {
    match value {
        None | Some(Value::Null) => None,
        Some(Value::String(value)) if value.is_empty() => None,
        Some(Value::String(value)) => Some(value.clone()),
        Some(other) => Some(other.to_string()),
    }
}

fn resolve_repo_path(cwd: &Path) -> PathBuf {
    git::get_repo_root(cwd)
}

fn resolve_git_remotes(repo_path: &Path) -> Option<String> {
    let remotes = git::list_remotes(repo_path)
        .into_iter()
        .map(|remote| json!({ "name": remote.name, "url": redact_remote_url(&remote.url) }))
        .collect::<Vec<_>>();
    if remotes.is_empty() {
        None
    } else {
        Some(Value::Array(remotes).to_string())
    }
}
