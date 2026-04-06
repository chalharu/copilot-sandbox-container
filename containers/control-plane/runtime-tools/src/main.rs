use std::collections::HashMap;
use std::env;
use std::ffi::OsStr;
use std::fs;
use std::io::{self, Read};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Output, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use rusqlite::{Connection, params};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use tempfile::TempDir;

const DEFAULT_SESSION_EXEC_BIN: &str = "/usr/local/bin/control-plane-session-exec";
const DEFAULT_AUDIT_MAX_RECORDS: usize = 10_000;
const DEFAULT_AUDIT_DB_SUFFIX: &str = ".copilot/session-state/audit/audit-log.db";

#[derive(Debug)]
struct ToolError {
    code: i32,
    prefix: &'static str,
    message: String,
}

impl ToolError {
    fn new(code: i32, prefix: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            prefix,
            message: message.into(),
        }
    }
}

type ToolResult<T> = Result<T, ToolError>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum JobWaitStatus {
    Completed,
    Failed,
    TimedOut,
}

#[derive(Debug)]
struct JobCommandArgs {
    namespace: String,
    job_name: String,
    timeout: Duration,
}

#[derive(Debug, Deserialize)]
struct ExternalSkillManifestEntry {
    repository: String,
    #[serde(rename = "ref")]
    git_ref: String,
    skills: Vec<String>,
}

fn main() -> ExitCode {
    match dispatch_main() {
        Ok(code) => ExitCode::from(code as u8),
        Err(error) => {
            if error.prefix.is_empty() {
                eprintln!("{}", error.message);
            } else {
                eprintln!("{}: {}", error.prefix, error.message);
            }
            ExitCode::from(error.code as u8)
        }
    }
}

fn dispatch_main() -> ToolResult<i32> {
    let current_exe = env::current_exe()
        .map_err(|error| ToolError::new(1, "control-plane-runtime-tool", error.to_string()))?;
    let invocation = resolve_invocation(&current_exe)?;
    let mut args = env::args().skip(1).collect::<Vec<_>>();
    dispatch(&invocation, &mut args)
}

fn resolve_invocation(current_exe: &Path) -> ToolResult<String> {
    let exe_name = current_exe
        .file_name()
        .and_then(OsStr::to_str)
        .ok_or_else(|| {
            ToolError::new(
                1,
                "control-plane-runtime-tool",
                "failed to resolve executable name",
            )
        })?;

    if exe_name == "main" {
        let parent_name = current_exe
            .parent()
            .and_then(Path::file_name)
            .and_then(OsStr::to_str)
            .unwrap_or_default();
        if parent_name == "audit" {
            return Ok("audit".to_string());
        }
    }

    Ok(exe_name.to_string())
}

fn dispatch(invocation: &str, args: &mut Vec<String>) -> ToolResult<i32> {
    match invocation {
        "control-plane-runtime-tool" => {
            let Some(subcommand) = args.first().cloned() else {
                return Err(ToolError::new(
                    64,
                    "control-plane-runtime-tool",
                    "missing subcommand",
                ));
            };
            args.remove(0);
            dispatch(&subcommand, args)
        }
        "install-git-skills-from-manifest" => run_install_git_skills(args),
        "audit" => run_audit(args),
        "exec-forward" => run_exec_forward(args),
        "cleanup" => run_cleanup(args),
        "k8s-job-wait" => run_k8s_job_wait(args),
        "k8s-job-pod" => run_k8s_job_pod(args),
        "k8s-job-logs" => run_k8s_job_logs(args),
        other => Err(ToolError::new(
            64,
            "control-plane-runtime-tool",
            format!("unsupported invocation: {other}"),
        )),
    }
}

fn run_install_git_skills(args: &[String]) -> ToolResult<i32> {
    if args.len() == 1 && args[0] == "--help" {
        println!("usage: install-git-skills-from-manifest <manifest-path> <destination-root>");
        return Ok(0);
    }

    if args.len() != 2 {
        return Err(ToolError::new(
            64,
            "install-git-skills-from-manifest",
            "usage: install-git-skills-from-manifest <manifest-path> <destination-root>",
        ));
    }

    install_git_skills_from_manifest(Path::new(&args[0]), Path::new(&args[1]))
        .map_err(|message| ToolError::new(1, "install-git-skills-from-manifest", message))?;

    Ok(0)
}

fn install_git_skills_from_manifest(
    manifest_path: &Path,
    destination_root: &Path,
) -> Result<(), String> {
    ensure_command("git").map_err(|error| error.to_string())?;

    if !manifest_path.is_file() {
        return Err(format!(
            "Manifest path does not exist: {}",
            manifest_path.display()
        ));
    }

    fs::create_dir_all(destination_root).map_err(|error| {
        format!(
            "failed to create destination root {}: {error}",
            destination_root.display()
        )
    })?;

    let manifest_raw = fs::read_to_string(manifest_path).map_err(|error| {
        format!(
            "failed to read manifest {}: {error}",
            manifest_path.display()
        )
    })?;
    let entries: Vec<ExternalSkillManifestEntry> =
        serde_yaml::from_str(&manifest_raw).map_err(|error| {
            format!(
                "failed to parse manifest {}: {error}",
                manifest_path.display()
            )
        })?;

    let checkout_root =
        TempDir::new().map_err(|error| format!("failed to create checkout directory: {error}"))?;
    let mut checkout_dirs = HashMap::<(String, String), PathBuf>::new();
    let mut installed_skills = HashMap::<String, String>::new();
    let mut installed_count = 0usize;

    for entry in entries {
        let repository = entry.repository.trim();
        let git_ref = entry.git_ref.trim();
        if repository.is_empty() {
            return Err(format!(
                "manifest entry in {} is missing repository",
                manifest_path.display()
            ));
        }
        if git_ref.is_empty() {
            return Err(format!(
                "manifest entry in {} is missing ref for {repository}",
                manifest_path.display()
            ));
        }

        let key = (repository.to_string(), git_ref.to_string());
        let checkout_dir = if let Some(existing) = checkout_dirs.get(&key) {
            existing.clone()
        } else {
            let target_dir = checkout_root
                .path()
                .join(format!("repo-{}", checkout_dirs.len()));
            clone_checkout(repository, git_ref, &target_dir)?;
            checkout_dirs.insert(key.clone(), target_dir.clone());
            target_dir
        };

        for skill_path in entry.skills {
            let normalized_skill_path = skill_path.trim_matches('/');
            let skill_name = Path::new(normalized_skill_path)
                .file_name()
                .and_then(OsStr::to_str)
                .unwrap_or_default()
                .to_string();

            if skill_name.is_empty() {
                return Err(format!(
                    "Could not determine skill name from path: {skill_path}"
                ));
            }

            let installed_from = format!("{repository}@{git_ref}:{normalized_skill_path}");
            if let Some(first) = installed_skills.get(&skill_name) {
                return Err(format!(
                    "Duplicate installed skill name: {skill_name}\n  first: {first}\n  next:  {installed_from}"
                ));
            }

            let source_skill_dir = checkout_dir.join(normalized_skill_path);
            let source_skill_file = source_skill_dir.join("SKILL.md");
            if !source_skill_file.is_file() {
                return Err(format!(
                    "Missing SKILL.md for manifest entry: {repository}@{git_ref}:{normalized_skill_path}"
                ));
            }

            let destination_dir = destination_root.join(&skill_name);
            if destination_dir.exists() {
                fs::remove_dir_all(&destination_dir).map_err(|error| {
                    format!(
                        "failed to remove existing skill directory {}: {error}",
                        destination_dir.display()
                    )
                })?;
            }
            copy_dir_recursive(&source_skill_dir, &destination_dir)?;

            installed_skills.insert(skill_name, installed_from);
            installed_count += 1;
        }
    }

    if installed_count == 0 {
        return Err(format!(
            "Manifest did not define any skills: {}",
            manifest_path.display()
        ));
    }

    Ok(())
}

fn clone_checkout(repository: &str, git_ref: &str, checkout_dir: &Path) -> Result<(), String> {
    let clone = Command::new("git")
        .arg("clone")
        .arg(repository)
        .arg(checkout_dir)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .map_err(|error| format!("failed to run git clone for {repository}: {error}"))?;
    if !clone.status.success() {
        return Err(format!(
            "git clone failed for {repository}: {}",
            output_message(&clone, "unknown git clone failure")
        ));
    }

    let checkout = Command::new("git")
        .arg("-C")
        .arg(checkout_dir)
        .arg("checkout")
        .arg("--detach")
        .arg(git_ref)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .map_err(|error| {
            format!("failed to run git checkout for {repository}@{git_ref}: {error}")
        })?;
    if !checkout.status.success() {
        return Err(format!(
            "git checkout failed for {repository}@{git_ref}: {}",
            output_message(&checkout, "unknown git checkout failure")
        ));
    }

    Ok(())
}

fn copy_dir_recursive(source: &Path, destination: &Path) -> Result<(), String> {
    let metadata = fs::symlink_metadata(source).map_err(|error| {
        format!(
            "failed to inspect source directory {}: {error}",
            source.display()
        )
    })?;
    if !metadata.is_dir() {
        return Err(format!("source is not a directory: {}", source.display()));
    }

    fs::create_dir_all(destination).map_err(|error| {
        format!(
            "failed to create destination directory {}: {error}",
            destination.display()
        )
    })?;
    set_mode(destination, metadata.permissions().mode())?;

    for entry in fs::read_dir(source)
        .map_err(|error| format!("failed to read directory {}: {error}", source.display()))?
    {
        let entry = entry.map_err(|error| {
            format!(
                "failed to read directory entry in {}: {error}",
                source.display()
            )
        })?;
        let source_path = entry.path();
        let destination_path = destination.join(entry.file_name());
        let entry_metadata = fs::symlink_metadata(&source_path).map_err(|error| {
            format!("failed to inspect path {}: {error}", source_path.display())
        })?;

        if entry_metadata.is_dir() {
            copy_dir_recursive(&source_path, &destination_path)?;
            continue;
        }
        if !entry_metadata.is_file() {
            return Err(format!(
                "unsupported file type in skill directory: {}",
                source_path.display()
            ));
        }

        fs::copy(&source_path, &destination_path).map_err(|error| {
            format!(
                "failed to copy {} to {}: {error}",
                source_path.display(),
                destination_path.display()
            )
        })?;
        set_mode(&destination_path, entry_metadata.permissions().mode())?;
    }

    Ok(())
}

fn run_audit(args: &[String]) -> ToolResult<i32> {
    let event_type = args.first().cloned().unwrap_or_default();
    let raw_input = read_stdin_string()
        .map_err(|error| ToolError::new(1, "control-plane audit hook", error.to_string()))?;
    handle_audit(&event_type, &raw_input)
        .map_err(|message| ToolError::new(1, "control-plane audit hook", message))?;
    Ok(0)
}

fn handle_audit(event_type: &str, raw_input: &str) -> Result<(), String> {
    require_supported_event_type(event_type)?;
    let payload = parse_hook_input(raw_input, event_type)?;
    let db_path = resolve_audit_log_db_path()?;
    let max_records = resolve_audit_log_max_records()?;

    ensure_database(&db_path)?;
    let event = build_audit_event(event_type, &payload)?;
    insert_audit_event(&db_path, &event, max_records)?;
    Ok(())
}

fn require_supported_event_type(event_type: &str) -> Result<(), String> {
    match event_type {
        "sessionStart" | "userPromptSubmitted" | "preToolUse" | "postToolUse" => Ok(()),
        _ => Err(format!("Unsupported audit hook event: {event_type}")),
    }
}

fn parse_hook_input(raw_input: &str, event_type: &str) -> Result<Map<String, Value>, String> {
    if raw_input.trim().is_empty() {
        return Ok(Map::new());
    }

    let parsed: Value = serde_json::from_str(raw_input)
        .map_err(|error| format!("Failed to parse {event_type} hook input JSON: {error}"))?;
    let Value::Object(object) = parsed else {
        return Err(format!(
            "{event_type} hook input must be a top-level JSON object."
        ));
    };
    Ok(object)
}

fn resolve_audit_log_db_path() -> Result<PathBuf, String> {
    let db_path = if let Some(path) = env::var_os("CONTROL_PLANE_AUDIT_LOG_DB_PATH") {
        PathBuf::from(path)
    } else {
        let home = env::var_os("HOME").unwrap_or_else(|| "/home/copilot".into());
        PathBuf::from(home).join(DEFAULT_AUDIT_DB_SUFFIX)
    };

    if !db_path.is_absolute() {
        return Err(format!(
            "CONTROL_PLANE_AUDIT_LOG_DB_PATH must be an absolute path: {}",
            db_path.display()
        ));
    }

    Ok(db_path)
}

fn resolve_audit_log_max_records() -> Result<usize, String> {
    let raw_value = env::var("CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS")
        .unwrap_or_else(|_| DEFAULT_AUDIT_MAX_RECORDS.to_string());
    let value: usize = raw_value.parse().map_err(|_| {
        format!("CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS must be a positive integer: {raw_value}")
    })?;
    if value == 0 {
        return Err(format!(
            "CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS must be a positive safe integer: {raw_value}"
        ));
    }
    Ok(value)
}

fn ensure_database(db_path: &Path) -> Result<(), String> {
    let Some(parent_dir) = db_path.parent() else {
        return Err(format!(
            "audit log path has no parent directory: {}",
            db_path.display()
        ));
    };

    fs::create_dir_all(parent_dir).map_err(|error| {
        format!(
            "failed to create audit log directory {}: {error}",
            parent_dir.display()
        )
    })?;
    set_mode(parent_dir, 0o700)?;

    if db_path.exists() && !db_path.is_file() {
        return Err(format!(
            "Audit log database path must be a regular file: {}",
            db_path.display()
        ));
    }

    let connection = Connection::open(db_path).map_err(|error| {
        format!(
            "failed to open sqlite database {}: {error}",
            db_path.display()
        )
    })?;
    connection
        .busy_timeout(Duration::from_secs(30))
        .map_err(|error| format!("failed to configure sqlite busy timeout: {error}"))?;
    connection.execute_batch(
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
    ).map_err(|error| format!("failed to initialize audit database: {error}"))?;

    if !table_has_column(&connection, "audit_events", "ppid")? {
        connection
            .execute("ALTER TABLE audit_events ADD COLUMN ppid INTEGER", [])
            .map_err(|error| format!("failed to add audit_events.ppid column: {error}"))?;
    }
    connection.execute(
        "CREATE INDEX IF NOT EXISTS audit_events_ppid_created_at_idx ON audit_events (ppid, created_at_ms)",
        [],
    ).map_err(|error| format!("failed to create audit_events ppid index: {error}"))?;

    drop(connection);
    if db_path.exists() {
        set_mode(db_path, 0o600)?;
    }

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

fn build_audit_event(event_type: &str, payload: &Map<String, Value>) -> Result<AuditEvent, String> {
    let cwd = payload
        .get("cwd")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(current_directory);
    let cwd = absolute_path(&cwd).map_err(|error| error.to_string())?;
    let repo_path = resolve_repo_path(&cwd);

    Ok(AuditEvent {
        event_type: event_type.to_string(),
        created_at_ms: normalize_timestamp(payload.get("timestamp")),
        cwd: cwd.display().to_string(),
        repo_path: repo_path.display().to_string(),
        ppid: parent_process_id(),
        git_remotes_json: resolve_git_remotes(&repo_path),
        session_source: if event_type == "sessionStart" {
            normalize_text(payload.get("source"))
        } else {
            None
        },
        initial_prompt: if event_type == "sessionStart" {
            normalize_text(payload.get("initialPrompt"))
        } else {
            None
        },
        user_prompt: if event_type == "userPromptSubmitted" {
            normalize_text(payload.get("prompt"))
        } else {
            None
        },
        tool_name: if is_tool_event(event_type) {
            normalize_text(payload.get("toolName"))
        } else {
            None
        },
        tool_args_json: if is_tool_event(event_type) {
            normalize_tool_args(payload.get("toolArgs"))
        } else {
            None
        },
        tool_result_type: if event_type == "postToolUse" {
            payload
                .get("toolResult")
                .and_then(Value::as_object)
                .and_then(|tool_result| normalize_text(tool_result.get("resultType")))
        } else {
            None
        },
        tool_result_text: if event_type == "postToolUse" {
            payload
                .get("toolResult")
                .and_then(Value::as_object)
                .and_then(|tool_result| normalize_text(tool_result.get("textResultForLlm")))
        } else {
            None
        },
    })
}

fn is_tool_event(event_type: &str) -> bool {
    matches!(event_type, "preToolUse" | "postToolUse")
}

fn current_directory() -> PathBuf {
    env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

fn absolute_path(path: &Path) -> io::Result<PathBuf> {
    if path.is_absolute() {
        Ok(path.to_path_buf())
    } else {
        env::current_dir().map(|cwd| cwd.join(path))
    }
}

fn parent_process_id() -> Option<i64> {
    let ppid = unsafe { libc::getppid() };
    if ppid > 0 {
        Some(i64::from(ppid))
    } else {
        None
    }
}

fn normalize_timestamp(value: Option<&Value>) -> i64 {
    if let Some(Value::Number(number)) = value {
        if let Some(value) = number.as_i64()
            && value >= 0
        {
            return value;
        }
        if let Some(value) = number.as_u64()
            && let Ok(value) = i64::try_from(value)
        {
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
    let output = Command::new("git")
        .arg("rev-parse")
        .arg("--show-toplevel")
        .current_dir(cwd)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output();

    match output {
        Ok(output) if output.status.success() => {
            let repo_path = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if repo_path.is_empty() {
                cwd.to_path_buf()
            } else {
                PathBuf::from(repo_path)
            }
        }
        _ => cwd.to_path_buf(),
    }
}

fn resolve_git_remotes(repo_path: &Path) -> Option<String> {
    let output = Command::new("git")
        .arg("config")
        .arg("--get-regexp")
        .arg("^remote\\..*\\.url$")
        .current_dir(repo_path)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }

    let remotes = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                return None;
            }
            let (key, url) = trimmed.split_once(' ')?;
            let parts = key.split('.').collect::<Vec<_>>();
            if parts.len() != 3 || parts[0] != "remote" || parts[2] != "url" {
                return None;
            }

            Some(json!({
                "name": parts[1],
                "url": url,
            }))
        })
        .collect::<Vec<_>>();

    if remotes.is_empty() {
        None
    } else {
        Some(Value::Array(remotes).to_string())
    }
}

fn insert_audit_event(
    db_path: &Path,
    event: &AuditEvent,
    max_records: usize,
) -> Result<(), String> {
    let mut connection = Connection::open(db_path).map_err(|error| {
        format!(
            "failed to open sqlite database {}: {error}",
            db_path.display()
        )
    })?;
    connection
        .busy_timeout(Duration::from_secs(30))
        .map_err(|error| format!("failed to configure sqlite busy timeout: {error}"))?;
    let transaction = connection
        .transaction()
        .map_err(|error| format!("failed to start sqlite transaction: {error}"))?;

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
                event.event_type,
                event.created_at_ms,
                event.cwd,
                event.repo_path,
                event.ppid,
                event.git_remotes_json,
                event.session_source,
                event.initial_prompt,
                event.user_prompt,
                event.tool_name,
                event.tool_args_json,
                event.tool_result_type,
                event.tool_result_text,
            ],
        )
        .map_err(|error| format!("failed to insert audit event: {error}"))?;
    let inserted_id = transaction.last_insert_rowid();

    if is_tool_event(&event.event_type) {
        prune_audit_events(&transaction, max_records, inserted_id)?;
    }

    transaction
        .commit()
        .map_err(|error| format!("failed to commit sqlite transaction: {error}"))?;
    if db_path.exists() {
        set_mode(db_path, 0o600)?;
    }
    Ok(())
}

fn prune_audit_events(
    connection: &Connection,
    max_records: usize,
    protected_id: i64,
) -> Result<(), String> {
    let count: i64 = connection
        .query_row("SELECT COUNT(*) FROM audit_events", [], |row| row.get(0))
        .map_err(|error| format!("failed to count audit events: {error}"))?;
    if count <= max_records as i64 {
        return Ok(());
    }

    let retained_records = usize::max(1, max_records - max_records.div_ceil(4));
    let delete_count = count - retained_records as i64;
    if delete_count <= 0 {
        return Ok(());
    }

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

    for id in ids {
        connection
            .execute("DELETE FROM audit_events WHERE id = ?1", params![id])
            .map_err(|error| format!("failed to delete audit event {id}: {error}"))?;
    }

    Ok(())
}

fn run_exec_forward(_args: &[String]) -> ToolResult<i32> {
    let raw_input = read_stdin_string()
        .map_err(|error| ToolError::new(1, "control-plane exec-forward hook", error.to_string()))?;
    if let Some(output) = handle_exec_forward(&raw_input) {
        println!("{output}");
    }
    Ok(0)
}

fn handle_exec_forward(raw_input: &str) -> Option<String> {
    let input = match parse_input_object(raw_input) {
        Ok(value) => value,
        Err(message) => return Some(deny_json(&message)),
    };

    if input.get("toolName").and_then(Value::as_str) != Some("bash") {
        return None;
    }
    if env::var("CONTROL_PLANE_FAST_EXECUTION_ENABLED")
        .ok()
        .as_deref()
        != Some("1")
    {
        return None;
    }

    let mut tool_args = match parse_tool_args(input.get("toolArgs")) {
        Ok(value) => value,
        Err(message) => return Some(deny_json(&message)),
    };
    let command = tool_args
        .get("command")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())?;

    let session_exec_bin = env::var("CONTROL_PLANE_SESSION_EXEC_BIN")
        .unwrap_or_else(|_| DEFAULT_SESSION_EXEC_BIN.to_string());
    let session_key = session_key_from_environment();
    if let Err(message) = prepare_execution_pod(&session_exec_bin, &session_key) {
        return Some(deny_json(&message));
    }

    let cwd = input
        .get("cwd")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| current_directory().display().to_string());
    let command_base64 = BASE64_STANDARD.encode(command.as_bytes());
    let rewritten = [
        shell_quote(&session_exec_bin),
        "proxy".to_string(),
        "--session-key".to_string(),
        shell_quote(&session_key),
        "--cwd".to_string(),
        shell_quote(&cwd),
        "--command-base64".to_string(),
        shell_quote(&command_base64),
    ]
    .join(" ");
    tool_args.insert("command".to_string(), Value::String(rewritten));

    Some(
        json!({
            "permissionDecision": "allow",
            "modifiedArgs": Value::Object(tool_args),
        })
        .to_string(),
    )
}

fn parse_input_object(raw_input: &str) -> Result<Map<String, Value>, String> {
    if raw_input.trim().is_empty() {
        return Ok(Map::new());
    }
    let parsed: Value = serde_json::from_str(raw_input).map_err(|error| error.to_string())?;
    let Value::Object(object) = parsed else {
        return Err("hook input must be a top-level JSON object".to_string());
    };
    Ok(object)
}

fn parse_tool_args(tool_args: Option<&Value>) -> Result<Map<String, Value>, String> {
    match tool_args {
        None | Some(Value::Null) => Ok(Map::new()),
        Some(Value::Object(object)) => Ok(object.clone()),
        Some(Value::String(raw)) => {
            let parsed: Value = serde_json::from_str(raw).map_err(|error| error.to_string())?;
            let Value::Object(object) = parsed else {
                return Err("preToolUse toolArgs must decode to a JSON object".to_string());
            };
            Ok(object)
        }
        _ => Err("preToolUse toolArgs must be a JSON object or JSON object string".to_string()),
    }
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

fn session_key_from_environment() -> String {
    env::var("CONTROL_PLANE_HOOK_SESSION_KEY")
        .ok()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| parent_process_id().unwrap_or(0).to_string())
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

fn deny_json(message: &str) -> String {
    json!({
        "permissionDecision": "deny",
        "permissionDecisionReason": message,
    })
    .to_string()
}

fn run_cleanup(_args: &[String]) -> ToolResult<i32> {
    let raw_input = read_stdin_string().map_err(|error| {
        ToolError::new(1, "control-plane session cleanup hook", error.to_string())
    })?;
    handle_cleanup(&raw_input)
        .map_err(|message| ToolError::new(1, "control-plane session cleanup hook", message))?;
    Ok(0)
}

fn handle_cleanup(_raw_input: &str) -> Result<(), String> {
    if env::var("CONTROL_PLANE_FAST_EXECUTION_ENABLED")
        .ok()
        .as_deref()
        != Some("1")
    {
        return Ok(());
    }

    let session_exec_bin = env::var("CONTROL_PLANE_SESSION_EXEC_BIN")
        .unwrap_or_else(|_| DEFAULT_SESSION_EXEC_BIN.to_string());
    let session_key = session_key_from_environment();
    let output = Command::new(session_exec_bin)
        .arg("cleanup")
        .arg("--session-key")
        .arg(&session_key)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|error| format!("failed to clean up session execution pod: {error}"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(output_message(
            &output,
            "failed to clean up session execution pod",
        ))
    }
}

fn run_k8s_job_wait(args: &[String]) -> ToolResult<i32> {
    if args.len() == 1 && args[0] == "--help" {
        print_job_usage("k8s-job-wait");
        return Ok(0);
    }
    let parsed = parse_job_command_args("k8s-job-wait", args)?;
    ensure_command("kubectl")
        .map_err(|error| ToolError::new(64, "k8s-job-wait", error.to_string()))?;

    match k8s_job_wait(&parsed.namespace, &parsed.job_name, parsed.timeout)
        .map_err(|message| ToolError::new(1, "k8s-job-wait", message))?
    {
        JobWaitStatus::Completed => Ok(0),
        JobWaitStatus::Failed => {
            eprintln!("k8s-job-wait: job {} failed", parsed.job_name);
            Ok(1)
        }
        JobWaitStatus::TimedOut => {
            eprintln!(
                "k8s-job-wait: timed out waiting for job {}",
                parsed.job_name
            );
            Ok(124)
        }
    }
}

fn run_k8s_job_pod(args: &[String]) -> ToolResult<i32> {
    if args.len() == 1 && args[0] == "--help" {
        print_job_usage("k8s-job-pod");
        return Ok(0);
    }
    let parsed = parse_job_command_args("k8s-job-pod", args)?;
    ensure_command("kubectl")
        .map_err(|error| ToolError::new(64, "k8s-job-pod", error.to_string()))?;
    let pod_name = resolve_job_pod(&parsed.namespace, &parsed.job_name)
        .map_err(|message| ToolError::new(1, "k8s-job-pod", message))?;
    println!("{pod_name}");
    Ok(0)
}

fn run_k8s_job_logs(args: &[String]) -> ToolResult<i32> {
    if args.len() == 1 && args[0] == "--help" {
        print_job_usage("k8s-job-logs");
        return Ok(0);
    }
    let parsed = parse_job_command_args("k8s-job-logs", args)?;
    ensure_command("kubectl")
        .map_err(|error| ToolError::new(64, "k8s-job-logs", error.to_string()))?;
    let status = stream_job_logs(&parsed.namespace, &parsed.job_name)
        .map_err(|message| ToolError::new(1, "k8s-job-logs", message))?;
    Ok(status)
}

fn parse_job_command_args(
    command_name: &'static str,
    args: &[String],
) -> ToolResult<JobCommandArgs> {
    let mut namespace = "default".to_string();
    let mut job_name = String::new();
    let mut timeout = Duration::from_secs(300);
    let mut index = 0usize;

    while index < args.len() {
        match args[index].as_str() {
            "--namespace" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(ToolError::new(
                        64,
                        command_name,
                        "--namespace requires a value",
                    ));
                };
                namespace = value.clone();
                index += 2;
            }
            "--job-name" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(ToolError::new(
                        64,
                        command_name,
                        "--job-name requires a value",
                    ));
                };
                job_name = value.clone();
                index += 2;
            }
            "--timeout" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(ToolError::new(
                        64,
                        command_name,
                        "--timeout requires a value",
                    ));
                };
                timeout = parse_timeout_duration(value)
                    .map_err(|message| ToolError::new(64, command_name, message))?;
                index += 2;
            }
            other => {
                return Err(ToolError::new(
                    64,
                    command_name,
                    format!("unknown option: {other}"),
                ));
            }
        }
    }

    if job_name.is_empty() {
        return Err(ToolError::new(64, command_name, "--job-name is required"));
    }

    Ok(JobCommandArgs {
        namespace,
        job_name,
        timeout,
    })
}

fn print_job_usage(command_name: &str) {
    match command_name {
        "k8s-job-wait" => {
            println!("Usage:\n  k8s-job-wait --namespace NAME --job-name NAME [--timeout 300s]")
        }
        "k8s-job-pod" => println!("Usage:\n  k8s-job-pod --namespace NAME --job-name NAME"),
        "k8s-job-logs" => println!("Usage:\n  k8s-job-logs --namespace NAME --job-name NAME"),
        _ => {}
    }
}

fn parse_timeout_duration(raw_value: &str) -> Result<Duration, String> {
    if raw_value.is_empty() {
        return Err("--timeout requires a value".to_string());
    }

    let split_at = raw_value
        .find(|character: char| !character.is_ascii_digit())
        .unwrap_or(raw_value.len());
    let (digits, suffix) = raw_value.split_at(split_at);
    if digits.is_empty() {
        return Err(format!("invalid timeout value: {raw_value}"));
    }

    let amount: u64 = digits
        .parse()
        .map_err(|_| format!("invalid timeout value: {raw_value}"))?;
    let seconds = match suffix {
        "" | "s" => amount,
        "m" => amount.saturating_mul(60),
        "h" => amount.saturating_mul(60 * 60),
        _ => return Err(format!("invalid timeout value: {raw_value}")),
    };
    Ok(Duration::from_secs(seconds))
}

fn k8s_job_wait(
    namespace: &str,
    job_name: &str,
    timeout: Duration,
) -> Result<JobWaitStatus, String> {
    let started = Instant::now();
    loop {
        let output = Command::new("kubectl")
            .arg("get")
            .arg("job")
            .arg(job_name)
            .arg("--namespace")
            .arg(namespace)
            .arg("-o")
            .arg(r#"jsonpath={range .status.conditions[*]}{.type}={.status}{"\n"}{end}"#)
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .output()
            .map_err(|error| format!("failed to run kubectl get job {job_name}: {error}"))?;

        let conditions = String::from_utf8_lossy(&output.stdout);
        if conditions
            .lines()
            .any(|line| line.trim() == "Complete=True")
        {
            return Ok(JobWaitStatus::Completed);
        }
        if conditions.lines().any(|line| line.trim() == "Failed=True") {
            return Ok(JobWaitStatus::Failed);
        }

        if started.elapsed() >= timeout {
            return Ok(JobWaitStatus::TimedOut);
        }

        std::thread::sleep(Duration::from_secs(1));
    }
}

fn resolve_job_pod(namespace: &str, job_name: &str) -> Result<String, String> {
    let output = Command::new("kubectl")
        .arg("get")
        .arg("pods")
        .arg("--namespace")
        .arg(namespace)
        .arg("--selector")
        .arg(format!("job-name={job_name}"))
        .arg("-o")
        .arg("jsonpath={.items[0].metadata.name}")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|error| format!("failed to run kubectl get pods for {job_name}: {error}"))?;
    if !output.status.success() {
        return Err(output_message(&output, "failed to resolve job pod"));
    }

    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn stream_job_logs(namespace: &str, job_name: &str) -> Result<i32, String> {
    let pod_name = resolve_job_pod(namespace, job_name)?;
    if pod_name.is_empty() {
        return Err(format!("could not resolve pod for job {job_name}"));
    }

    let status = Command::new("kubectl")
        .arg("logs")
        .arg("--namespace")
        .arg(namespace)
        .arg(&pod_name)
        .status()
        .map_err(|error| format!("failed to run kubectl logs for {pod_name}: {error}"))?;
    Ok(status.code().unwrap_or(1))
}

fn read_stdin_string() -> io::Result<String> {
    let mut buffer = String::new();
    io::stdin().read_to_string(&mut buffer)?;
    Ok(buffer)
}

fn output_message(output: &Output, fallback: &str) -> String {
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if !stderr.is_empty() {
        stderr
    } else if !stdout.is_empty() {
        stdout
    } else {
        fallback.to_string()
    }
}

fn ensure_command(command_name: &str) -> io::Result<()> {
    let Some(path) = env::var_os("PATH") else {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("{command_name} is required"),
        ));
    };

    for directory in env::split_paths(&path) {
        let candidate = directory.join(command_name);
        if candidate.is_file() {
            return Ok(());
        }
    }

    Err(io::Error::new(
        io::ErrorKind::NotFound,
        format!("{command_name} is required"),
    ))
}

fn set_mode(path: &Path, mode: u32) -> Result<(), String> {
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
        .map_err(|error| format!("failed to set permissions on {}: {error}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{LazyLock, Mutex};

    static ENV_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

    struct EnvRestore {
        key: &'static str,
        original: Option<String>,
    }

    impl EnvRestore {
        fn set(key: &'static str, value: &str) -> Self {
            let original = env::var(key).ok();
            unsafe {
                env::set_var(key, value);
            }
            Self { key, original }
        }
    }

    impl Drop for EnvRestore {
        fn drop(&mut self) {
            match &self.original {
                Some(value) => unsafe {
                    env::set_var(self.key, value);
                },
                None => unsafe {
                    env::remove_var(self.key);
                },
            }
        }
    }

    fn lock_env() -> std::sync::MutexGuard<'static, ()> {
        ENV_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn write_executable(path: &Path, contents: &str) {
        fs::write(path, contents).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
    }

    #[test]
    fn exec_forward_rewrites_bash_command() {
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

        let output = handle_exec_forward(
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
    fn exec_forward_denies_on_prepare_failure() {
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

        let output = handle_exec_forward(
            r#"{"toolName":"bash","toolArgs":{"command":"echo hello","description":"demo"}}"#,
        )
        .unwrap();
        let value: Value = serde_json::from_str(&output).unwrap();

        assert_eq!(value["permissionDecision"], "deny");
        assert_eq!(value["permissionDecisionReason"], "prepare exploded");
    }

    #[test]
    fn cleanup_invokes_session_exec_cleanup() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let helper_path = temp_dir.path().join("control-plane-session-exec");
        let record_path = temp_dir.path().join("cleanup-args");
        write_executable(
            &helper_path,
            &format!(
                "#!/usr/bin/env bash\nset -euo pipefail\nprintf '%s %s %s\\n' \"$1\" \"$2\" \"$3\" > {}\n",
                shell_quote(record_path.to_str().unwrap())
            ),
        );

        let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
        let _session_exec = EnvRestore::set(
            "CONTROL_PLANE_SESSION_EXEC_BIN",
            helper_path.to_str().unwrap(),
        );
        let _session_key = EnvRestore::set("CONTROL_PLANE_HOOK_SESSION_KEY", "cleanup-key");

        handle_cleanup("").unwrap();

        let recorded = fs::read_to_string(&record_path).unwrap();
        assert_eq!(recorded.trim(), "cleanup --session-key cleanup-key");
    }

    #[test]
    fn audit_hook_inserts_and_prunes_records() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let db_path = temp_dir.path().join("audit").join("audit-log.db");
        let _db_path =
            EnvRestore::set("CONTROL_PLANE_AUDIT_LOG_DB_PATH", db_path.to_str().unwrap());
        let _max_records = EnvRestore::set("CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS", "4");

        handle_audit(
            "sessionStart",
            r#"{"source":"test","initialPrompt":"hello","timestamp":1}"#,
        )
        .unwrap();
        handle_audit(
            "preToolUse",
            r#"{"toolName":"bash","toolArgs":{"command":"echo one"},"timestamp":10}"#,
        )
        .unwrap();
        handle_audit("postToolUse", r#"{"toolName":"bash","toolArgs":{"command":"echo two"},"toolResult":{"resultType":"text","textResultForLlm":"ok"},"timestamp":20}"#).unwrap();
        handle_audit(
            "preToolUse",
            r#"{"toolName":"bash","toolArgs":{"command":"echo three"},"timestamp":30}"#,
        )
        .unwrap();
        handle_audit(
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
    fn install_manifest_rejects_duplicate_skill_names() {
        let _env_lock = lock_env();
        let manifest_path = TempDir::new().unwrap();
        let destination_root = TempDir::new().unwrap();
        let bin_dir = TempDir::new().unwrap();
        let manifest = manifest_path.path().join("external-skills.yaml");
        let git_path = bin_dir.path().join("git");
        write_executable(
            &git_path,
            "#!/usr/bin/env bash\nset -euo pipefail\nif [[ \"$1\" == clone ]]; then\n  repo=\"$2\"\n  target=\"$3\"\n  mkdir -p \"$target\"\n  case \"$repo\" in\n    https://example.com/one.git)\n      mkdir -p \"$target/skills/foo\"\n      printf '# foo\\n' > \"$target/skills/foo/SKILL.md\"\n      ;;\n    https://example.com/two.git)\n      mkdir -p \"$target/other/foo\"\n      printf '# foo\\n' > \"$target/other/foo/SKILL.md\"\n      ;;\n    *)\n      printf 'unexpected repository: %s\\n' \"$repo\" >&2\n      exit 1\n      ;;\n  esac\n  exit 0\nfi\nif [[ \"$1\" == -C ]]; then\n  exit 0\nfi\nprintf 'unexpected git args: %s\\n' \"$*\" >&2\nexit 1\n",
        );
        fs::write(
            &manifest,
            "- repository: https://example.com/one.git\n  ref: abc\n  skills:\n    - skills/foo\n- repository: https://example.com/two.git\n  ref: def\n  skills:\n    - other/foo\n",
        )
        .unwrap();
        let path_value = format!(
            "{}:{}",
            bin_dir.path().display(),
            env::var("PATH").unwrap_or_default()
        );
        let _path = EnvRestore::set("PATH", &path_value);

        let error =
            install_git_skills_from_manifest(&manifest, destination_root.path()).unwrap_err();
        assert!(error.contains("Duplicate installed skill name"));
    }

    #[test]
    fn k8s_job_wait_detects_completion() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let kubectl_path = temp_dir.path().join("kubectl");
        let state_path = temp_dir.path().join("state");
        write_executable(
            &kubectl_path,
            &format!(
                "#!/usr/bin/env bash\nset -euo pipefail\ncount=0\nif [[ -f {} ]]; then count=$(cat {}); fi\ncount=$((count + 1))\nprintf '%s' \"$count\" > {}\nif [[ \"$count\" -ge 2 ]]; then printf 'Complete=True\\n'; fi\n",
                shell_quote(state_path.to_str().unwrap()),
                shell_quote(state_path.to_str().unwrap()),
                shell_quote(state_path.to_str().unwrap())
            ),
        );
        let path_value = format!(
            "{}:{}",
            temp_dir.path().display(),
            env::var("PATH").unwrap_or_default()
        );
        let _path = EnvRestore::set("PATH", &path_value);

        let status = k8s_job_wait("default", "demo", Duration::from_secs(3)).unwrap();
        assert_eq!(status, JobWaitStatus::Completed);
    }

    #[test]
    fn resolve_job_pod_returns_first_pod_name() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let kubectl_path = temp_dir.path().join("kubectl");
        write_executable(
            &kubectl_path,
            "#!/usr/bin/env bash\nset -euo pipefail\nprintf 'demo-pod'\n",
        );
        let path_value = format!(
            "{}:{}",
            temp_dir.path().display(),
            env::var("PATH").unwrap_or_default()
        );
        let _path = EnvRestore::set("PATH", &path_value);

        let pod_name = resolve_job_pod("default", "demo").unwrap();
        assert_eq!(pod_name, "demo-pod");
    }
}
