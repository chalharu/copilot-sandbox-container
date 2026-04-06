mod config;
mod executor;
mod git;
mod pipeline;
mod state;

use std::env;
use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::error::{ToolError, ToolResult};
use crate::support::{current_directory, read_stdin_string};

pub fn run(args: &[String]) -> ToolResult<i32> {
    if args.len() == 1 && args[0] == "--help" {
        println!("usage: post-tool-use");
        return Ok(0);
    }

    let raw_input = read_stdin_string().map_err(|error| {
        ToolError::new(1, "control-plane post-tool-use hook", error.to_string())
    })?;
    handle(&raw_input)
        .map_err(|message| ToolError::new(1, "control-plane post-tool-use hook", message))
}

fn handle(raw_input: &str) -> Result<i32, String> {
    if raw_input.trim().is_empty() {
        return Ok(0);
    }

    let input = HookInput::parse(raw_input)?;
    if input.is_denied() {
        return Ok(0);
    }

    let repo_root = git::get_repo_root(&input.cwd_path());
    let bundled_config_path = resolve_bundled_config_path()?;
    let config = config::load(&repo_root, &bundled_config_path)?;
    let state_path = state::resolve_state_file_path(&repo_root);
    let previous_signatures = state::load_state(&state_path)?;
    let current_relevant_files = pipeline::current_relevant_files(&config, &repo_root)?;
    let changed_files = state::get_changed_files(
        &repo_root,
        &current_relevant_files.matched_files,
        &previous_signatures,
    )?;

    if changed_files.is_empty() {
        state::save_state(
            &state_path,
            &repo_root,
            &current_relevant_files.matched_files,
        )?;
        return Ok(0);
    }

    let changed_files = pipeline::classify_files_by_pipeline(&config, &repo_root, &changed_files);
    let exit_code = executor::run_pipelines(&config, &repo_root, &changed_files.files_by_pipeline)?;
    let current_relevant_files = pipeline::current_relevant_files(&config, &repo_root)?;
    state::save_state(
        &state_path,
        &repo_root,
        &current_relevant_files.matched_files,
    )?;
    Ok(exit_code)
}

fn resolve_bundled_config_path() -> Result<PathBuf, String> {
    if let Some(path) = env::var_os("CONTROL_PLANE_POST_TOOL_USE_BUNDLED_CONFIG") {
        return Ok(PathBuf::from(path));
    }

    let arg0 = env::args_os().next().map(PathBuf::from).ok_or_else(|| {
        "failed to resolve post-tool-use hook path for bundled config".to_string()
    })?;
    Ok(config_path_from_hook_path(&arg0))
}

fn config_path_from_hook_path(hook_path: &Path) -> PathBuf {
    hook_path
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join("linters.json")
}

#[derive(Debug, Deserialize)]
struct HookInput {
    cwd: Option<String>,
    #[serde(rename = "toolResult")]
    tool_result: Option<HookToolResult>,
}

#[derive(Debug, Deserialize)]
struct HookToolResult {
    #[serde(rename = "resultType")]
    result_type: String,
}

impl HookInput {
    fn parse(raw_input: &str) -> Result<Self, String> {
        serde_json::from_str(raw_input)
            .map_err(|error| format!("Failed to parse postToolUse hook input JSON: {error}"))
    }

    fn is_denied(&self) -> bool {
        matches!(
            self.tool_result
                .as_ref()
                .map(|value| value.result_type.as_str()),
            Some("denied")
        )
    }

    fn cwd_path(&self) -> PathBuf {
        self.cwd
            .as_deref()
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(current_directory)
    }
}
