use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use serde::{Deserialize, Serialize};
use tempfile::NamedTempFile;

use super::git;

#[derive(Debug, Serialize, Deserialize)]
struct StateFile {
    version: u32,
    #[serde(rename = "repoRoot")]
    repo_root: String,
    signatures: HashMap<String, String>,
}

pub fn resolve_state_file_path(repo_root: &Path) -> PathBuf {
    git::get_git_dir(repo_root).join(".copilot-hooks/post-tool-use-state.json")
}

pub fn load_state(state_file_path: &Path) -> Result<HashMap<String, String>, String> {
    if !state_file_path.exists() {
        return Ok(HashMap::new());
    }

    let raw = fs::read_to_string(state_file_path).map_err(|error| {
        format!(
            "failed to read post-tool-use state {}: {error}",
            state_file_path.display()
        )
    })?;
    let parsed: StateFile = serde_json::from_str(&raw).map_err(|error| {
        format!(
            "failed to parse post-tool-use state {}: {error}",
            state_file_path.display()
        )
    })?;
    Ok(parsed.signatures)
}

pub fn save_state(
    state_file_path: &Path,
    repo_root: &Path,
    files: &[PathBuf],
) -> Result<(), String> {
    if let Some(parent) = state_file_path.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            format!(
                "failed to create post-tool-use state directory {}: {error}",
                parent.display()
            )
        })?;
    }

    let payload = StateFile {
        version: 1,
        repo_root: repo_root.display().to_string(),
        signatures: signatures(repo_root, files)?,
    };
    let temp_dir = state_file_path.parent().unwrap_or_else(|| Path::new("."));
    let mut temp = NamedTempFile::new_in(temp_dir)
        .map_err(|error| format!("failed to create temporary post-tool-use state file: {error}"))?;
    serde_json::to_writer_pretty(temp.as_file_mut(), &payload)
        .map_err(|error| format!("failed to serialize post-tool-use state: {error}"))?;
    temp.as_file_mut()
        .write_all(b"\n")
        .map_err(|error| format!("failed to finalize post-tool-use state file: {error}"))?;
    temp.persist(state_file_path)
        .map_err(|error| format!("failed to persist post-tool-use state: {}", error.error))?;
    Ok(())
}

fn signatures(repo_root: &Path, files: &[PathBuf]) -> Result<HashMap<String, String>, String> {
    let mut signatures = HashMap::new();
    for file in files {
        signatures.insert(
            git::to_relative_repo_path(repo_root, file),
            file_signature(file)?,
        );
    }
    Ok(signatures)
}

pub fn get_changed_files(
    repo_root: &Path,
    current_files: &[PathBuf],
    previous_signatures: &HashMap<String, String>,
) -> Result<Vec<PathBuf>, String> {
    let mut changed_files = Vec::new();
    for file_path in current_files {
        let relative_path = git::to_relative_repo_path(repo_root, file_path);
        if previous_signatures.get(&relative_path) != Some(&file_signature(file_path)?) {
            changed_files.push(file_path.clone());
        }
    }
    Ok(changed_files)
}

fn file_signature(file_path: &Path) -> Result<String, String> {
    let metadata = fs::metadata(file_path)
        .map_err(|error| format!("failed to stat {}: {error}", file_path.display()))?;
    let modified = metadata
        .modified()
        .map_err(|error| format!("failed to read mtime for {}: {error}", file_path.display()))?;
    let modified_ms = modified
        .duration_since(UNIX_EPOCH)
        .map_err(|error| {
            format!(
                "failed to normalize mtime for {}: {error}",
                file_path.display()
            )
        })?
        .as_millis();
    Ok(format!("{}:{modified_ms}", metadata.len()))
}
