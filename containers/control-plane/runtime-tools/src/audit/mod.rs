mod database;
mod event;
mod redaction;

use std::env;
use std::path::PathBuf;

use crate::error::{ToolError, ToolResult};
use crate::support::read_stdin_string;

use self::database::AuditDatabase;
use self::event::{AuditEvent, parse_hook_input};

const DEFAULT_AUDIT_MAX_RECORDS: usize = 10_000;
const DEFAULT_AUDIT_DB_SUFFIX: &str = ".copilot/session-state/audit/audit-log.db";

pub fn run(args: &[String]) -> ToolResult<i32> {
    let event_type = args.first().cloned().unwrap_or_default();
    let raw_input = read_stdin_string()
        .map_err(|error| ToolError::new(1, "control-plane audit hook", error.to_string()))?;
    handle(&event_type, &raw_input)
        .map_err(|message| ToolError::new(1, "control-plane audit hook", message))?;
    Ok(0)
}

pub fn handle(event_type: &str, raw_input: &str) -> Result<(), String> {
    require_supported_event_type(event_type)?;
    let payload = parse_hook_input(raw_input, event_type)?;
    let db_path = resolve_db_path()?;
    let max_records = resolve_max_records()?;
    let event = AuditEvent::from_payload(event_type, &payload)?;
    let mut database = AuditDatabase::open(&db_path)?;
    database.insert_event(&event, max_records)
}

fn require_supported_event_type(event_type: &str) -> Result<(), String> {
    match event_type {
        "sessionStart" | "userPromptSubmitted" | "preToolUse" | "postToolUse" => Ok(()),
        _ => Err(format!("Unsupported audit hook event: {event_type}")),
    }
}

fn resolve_db_path() -> Result<PathBuf, String> {
    let db_path = if let Some(path) = env::var_os("CONTROL_PLANE_AUDIT_LOG_DB_PATH") {
        PathBuf::from(path)
    } else {
        let home = env::var_os("HOME").unwrap_or_else(|| "/home/copilot".into());
        PathBuf::from(home).join(DEFAULT_AUDIT_DB_SUFFIX)
    };

    if db_path.is_absolute() {
        Ok(db_path)
    } else {
        Err(format!(
            "CONTROL_PLANE_AUDIT_LOG_DB_PATH must be an absolute path: {}",
            db_path.display()
        ))
    }
}

fn resolve_max_records() -> Result<usize, String> {
    let raw_value = env::var("CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS")
        .unwrap_or_else(|_| DEFAULT_AUDIT_MAX_RECORDS.to_string());
    let value: usize = raw_value.parse().map_err(|_| {
        format!("CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS must be a positive integer: {raw_value}")
    })?;

    if value == 0 {
        Err(format!(
            "CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS must be a positive safe integer: {raw_value}"
        ))
    } else {
        Ok(value)
    }
}

#[cfg(test)]
mod tests {
    use rusqlite::Connection;
    use tempfile::TempDir;

    use crate::test_support::{EnvRestore, lock_env};

    use super::{handle, redaction::redact_remote_url};

    #[test]
    fn inserts_and_prunes_records() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir.path().join("audit").join("audit-log.db");
        let _db_path =
            EnvRestore::set("CONTROL_PLANE_AUDIT_LOG_DB_PATH", db_path.to_str().unwrap());
        let _max_records = EnvRestore::set("CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS", "4");

        handle(
            "sessionStart",
            r#"{"source":"test","initialPrompt":"hello","timestamp":1}"#,
        )
        .unwrap();
        handle(
            "preToolUse",
            r#"{"toolName":"bash","toolArgs":{"command":"echo one"},"timestamp":10}"#,
        )
        .unwrap();
        handle("postToolUse", r#"{"toolName":"bash","toolArgs":{"command":"echo two"},"toolResult":{"resultType":"text","textResultForLlm":"ok"},"timestamp":20}"#).unwrap();
        handle(
            "preToolUse",
            r#"{"toolName":"bash","toolArgs":{"command":"echo three"},"timestamp":30}"#,
        )
        .unwrap();
        handle(
            "postToolUse",
            r#"{"toolName":"bash","toolArgs":{"command":"echo four"},"timestamp":40}"#,
        )
        .unwrap();

        let connection = Connection::open(&db_path).unwrap();
        let count: i64 = connection
            .query_row("SELECT COUNT(*) FROM audit_events", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 3);

        let newest: String = connection
            .query_row(
                "SELECT tool_args_json FROM audit_events ORDER BY created_at_ms DESC, id DESC LIMIT 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(newest.contains("echo four"));
    }

    #[test]
    fn redacts_credentials_from_remote_urls() {
        assert_eq!(
            redact_remote_url("https://token:x-oauth-basic@github.com/octo/repo.git?foo=bar#frag"),
            "https://github.com/octo/repo.git"
        );
        assert_eq!(
            redact_remote_url("git@github.com:octo/repo.git"),
            "github.com:octo/repo.git"
        );
    }
}
