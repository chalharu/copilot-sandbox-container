use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, Transaction, params};
use serde_json::{Map, Value, json};
use url::Url;

use crate::error::{ToolError, ToolResult};
use crate::git;
use crate::support::{
    absolute_path, current_directory, parent_process_id, parse_json_object_input,
    read_stdin_string, set_mode,
};

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

fn parse_hook_input(raw_input: &str, event_type: &str) -> Result<Map<String, Value>, String> {
    parse_json_object_input(raw_input, &format!("{event_type} hook input"))
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

struct AuditDatabase {
    path: PathBuf,
    connection: Connection,
}

impl AuditDatabase {
    fn open(path: &Path) -> Result<Self, String> {
        ensure_database_parent(path)?;
        ensure_regular_file(path)?;
        let connection = open_connection(path)?;
        initialize_schema(&connection)?;
        ensure_database_permissions(path)?;
        Ok(Self {
            path: path.to_path_buf(),
            connection,
        })
    }

    fn insert_event(&mut self, event: &AuditEvent, max_records: usize) -> Result<(), String> {
        let transaction = self
            .connection
            .transaction()
            .map_err(|error| format!("failed to start sqlite transaction: {error}"))?;
        let inserted_id = insert_event_row(&transaction, event)?;
        if event.is_tool_event() {
            prune_audit_events(&transaction, max_records, inserted_id)?;
        }
        transaction
            .commit()
            .map_err(|error| format!("failed to commit sqlite transaction: {error}"))?;
        ensure_database_permissions(&self.path)
    }
}

fn ensure_database_parent(path: &Path) -> Result<(), String> {
    let Some(parent_dir) = path.parent() else {
        return Err(format!(
            "audit log path has no parent directory: {}",
            path.display()
        ));
    };

    fs::create_dir_all(parent_dir).map_err(|error| {
        format!(
            "failed to create audit log directory {}: {error}",
            parent_dir.display()
        )
    })?;
    set_mode(parent_dir, 0o700)
}

fn ensure_regular_file(path: &Path) -> Result<(), String> {
    if path.exists() && !path.is_file() {
        Err(format!(
            "Audit log database path must be a regular file: {}",
            path.display()
        ))
    } else {
        Ok(())
    }
}

fn open_connection(path: &Path) -> Result<Connection, String> {
    let connection = Connection::open(path)
        .map_err(|error| format!("failed to open sqlite database {}: {error}", path.display()))?;
    connection
        .busy_timeout(Duration::from_secs(30))
        .map_err(|error| format!("failed to configure sqlite busy timeout: {error}"))?;
    Ok(connection)
}

fn initialize_schema(connection: &Connection) -> Result<(), String> {
    connection
        .execute_batch(
            "CREATE TABLE IF NOT EXISTS audit_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                event_type TEXT NOT NULL CHECK (event_type IN ('sessionStart', 'userPromptSubmitted', 'preToolUse', 'postToolUse')),
                created_at_ms INTEGER NOT NULL,
                cwd TEXT NOT NULL,
                repo_path TEXT NOT NULL,
                ppid INTEGER,
                git_remotes_json TEXT,
                session_source TEXT,
                initial_prompt TEXT,
                user_prompt TEXT,
                tool_name TEXT,
                tool_args_json TEXT,
                tool_result_type TEXT,
                tool_result_text TEXT
            );
            CREATE INDEX IF NOT EXISTS audit_events_event_type_created_at_idx ON audit_events (event_type, created_at_ms);
            CREATE INDEX IF NOT EXISTS audit_events_created_at_idx ON audit_events (created_at_ms, id);",
        )
        .map_err(|error| format!("failed to initialize audit database: {error}"))?;
    ensure_ppid_column(connection)?;
    connection
        .execute(
            "CREATE INDEX IF NOT EXISTS audit_events_ppid_created_at_idx ON audit_events (ppid, created_at_ms)",
            [],
        )
        .map_err(|error| format!("failed to create audit_events ppid index: {error}"))?;
    Ok(())
}

fn ensure_ppid_column(connection: &Connection) -> Result<(), String> {
    if table_has_column(connection, "audit_events", "ppid")? {
        return Ok(());
    }

    connection
        .execute("ALTER TABLE audit_events ADD COLUMN ppid INTEGER", [])
        .map_err(|error| format!("failed to add audit_events.ppid column: {error}"))?;
    Ok(())
}

fn table_has_column(
    connection: &Connection,
    table_name: &str,
    column_name: &str,
) -> Result<bool, String> {
    let mut statement = connection
        .prepare(&format!("PRAGMA table_info({table_name})"))
        .map_err(|error| format!("failed to inspect sqlite table {table_name}: {error}"))?;
    let mut rows = statement
        .query([])
        .map_err(|error| format!("failed to read sqlite table info for {table_name}: {error}"))?;

    while let Some(row) = rows
        .next()
        .map_err(|error| format!("failed to iterate sqlite table info for {table_name}: {error}"))?
    {
        let name: String = row.get(1).map_err(|error| {
            format!("failed to decode sqlite table info for {table_name}: {error}")
        })?;
        if name == column_name {
            return Ok(true);
        }
    }
    Ok(false)
}

fn ensure_database_permissions(path: &Path) -> Result<(), String> {
    if path.exists() {
        set_mode(path, 0o600)
    } else {
        Ok(())
    }
}

#[derive(Debug)]
struct AuditEvent {
    event_type: String,
    created_at_ms: i64,
    cwd: String,
    repo_path: String,
    ppid: Option<i64>,
    git_remotes_json: Option<String>,
    session_source: Option<String>,
    initial_prompt: Option<String>,
    user_prompt: Option<String>,
    tool_name: Option<String>,
    tool_args_json: Option<String>,
    tool_result_type: Option<String>,
    tool_result_text: Option<String>,
}

impl AuditEvent {
    fn from_payload(event_type: &str, payload: &Map<String, Value>) -> Result<Self, String> {
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

    fn is_tool_event(&self) -> bool {
        matches!(self.event_type.as_str(), "preToolUse" | "postToolUse")
    }
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

fn redact_remote_url(remote_url: &str) -> String {
    redact_standard_remote_url(remote_url)
        .or_else(|| redact_scp_like_remote(remote_url))
        .unwrap_or_else(|| remote_url.to_string())
}

fn redact_standard_remote_url(remote_url: &str) -> Option<String> {
    let mut url = Url::parse(remote_url).ok()?;
    if !url.username().is_empty() {
        let _ = url.set_username("");
    }
    let _ = url.set_password(None);
    url.set_query(None);
    url.set_fragment(None);
    Some(url.to_string())
}

fn redact_scp_like_remote(remote_url: &str) -> Option<String> {
    if remote_url.contains("://") {
        return None;
    }
    let (userinfo, host_path) = remote_url.split_once('@')?;
    if userinfo.is_empty() || !host_path.contains(':') {
        None
    } else {
        Some(host_path.to_string())
    }
}

fn insert_event_row(transaction: &Transaction<'_>, event: &AuditEvent) -> Result<i64, String> {
    transaction
        .execute(
            "INSERT INTO audit_events (
                event_type,
                created_at_ms,
                cwd,
                repo_path,
                ppid,
                git_remotes_json,
                session_source,
                initial_prompt,
                user_prompt,
                tool_name,
                tool_args_json,
                tool_result_type,
                tool_result_text
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
            params![
                &event.event_type,
                event.created_at_ms,
                &event.cwd,
                &event.repo_path,
                event.ppid,
                &event.git_remotes_json,
                &event.session_source,
                &event.initial_prompt,
                &event.user_prompt,
                &event.tool_name,
                &event.tool_args_json,
                &event.tool_result_type,
                &event.tool_result_text,
            ],
        )
        .map_err(|error| format!("failed to insert audit event: {error}"))?;
    Ok(transaction.last_insert_rowid())
}

fn prune_audit_events(
    connection: &Transaction<'_>,
    max_records: usize,
    protected_id: i64,
) -> Result<(), String> {
    let count = audit_event_count(connection)?;
    if count <= max_records as i64 {
        return Ok(());
    }

    let delete_count = prune_delete_count(max_records, count);
    if delete_count <= 0 {
        return Ok(());
    }

    for id in prune_candidate_ids(connection, protected_id, delete_count)? {
        connection
            .execute("DELETE FROM audit_events WHERE id = ?1", params![id])
            .map_err(|error| format!("failed to delete audit event {id}: {error}"))?;
    }
    Ok(())
}

fn audit_event_count(connection: &Transaction<'_>) -> Result<i64, String> {
    connection
        .query_row("SELECT COUNT(*) FROM audit_events", [], |row| row.get(0))
        .map_err(|error| format!("failed to count audit events: {error}"))
}

fn prune_delete_count(max_records: usize, count: i64) -> i64 {
    let retained_records = usize::max(1, max_records - max_records.div_ceil(4));
    count - retained_records as i64
}

fn prune_candidate_ids(
    connection: &Transaction<'_>,
    protected_id: i64,
    delete_count: i64,
) -> Result<Vec<i64>, String> {
    let mut statement = connection
        .prepare(
            "SELECT id
             FROM audit_events
             WHERE id != ?1
             ORDER BY created_at_ms ASC, id ASC
             LIMIT ?2",
        )
        .map_err(|error| format!("failed to prepare audit prune query: {error}"))?;
    let rows = statement
        .query_map(params![protected_id, delete_count], |row| {
            row.get::<_, i64>(0)
        })
        .map_err(|error| format!("failed to select audit prune rows: {error}"))?;

    let mut ids = Vec::new();
    for row in rows {
        ids.push(row.map_err(|error| format!("failed to decode audit prune row: {error}"))?);
    }
    Ok(ids)
}

#[cfg(test)]
mod tests {
    use rusqlite::Connection;
    use tempfile::TempDir;

    use crate::test_support::{EnvRestore, lock_env};

    use super::{handle, redact_remote_url};

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
