use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use rusqlite::{Connection, Transaction, params};

use crate::support::set_mode;

use super::event::AuditEvent;

pub(super) struct AuditDatabase {
    path: PathBuf,
    connection: Connection,
}

impl AuditDatabase {
    pub(super) fn open(path: &Path) -> Result<Self, String> {
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

    pub(super) fn insert_event(
        &mut self,
        event: &AuditEvent,
        max_records: usize,
    ) -> Result<(), String> {
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
