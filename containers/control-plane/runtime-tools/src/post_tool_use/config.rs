use std::collections::HashMap;
use std::fs;
use std::path::{Component, Path};

use regex::Regex;
use serde::Deserialize;

#[derive(Debug)]
pub struct Config {
    pub tools: HashMap<String, Tool>,
    pub pipelines: Vec<Pipeline>,
}

#[derive(Debug, Clone)]
pub struct Tool {
    pub command: String,
    pub args: Vec<String>,
    pub append_files: bool,
    pub runtime_failure_exit_codes: Vec<i32>,
    pub applicability: ToolApplicability,
}

#[derive(Debug, Clone)]
pub enum ToolApplicability {
    Always,
    RequiresRepoFiles(Vec<String>),
}

#[derive(Debug, Clone)]
pub struct Step {
    pub tools: Vec<String>,
    pub report_failure: bool,
    pub failure_label: Option<String>,
    pub runtime_failure_label: Option<String>,
}

#[derive(Debug)]
pub struct Pipeline {
    pub id: String,
    pub matcher: Regex,
    pub steps: Vec<Step>,
}

#[derive(Debug, Default, Deserialize)]
struct RawConfig {
    #[serde(default)]
    tools: Vec<RawTool>,
    #[serde(default)]
    pipelines: Vec<RawPipeline>,
}

#[derive(Debug, Clone, Deserialize)]
struct RawTool {
    id: String,
    command: String,
    #[serde(default)]
    args: Vec<String>,
    #[serde(default = "default_append_files")]
    #[serde(rename = "appendFiles")]
    append_files: bool,
    #[serde(default)]
    #[serde(rename = "runtimeFailureExitCodes")]
    runtime_failure_exit_codes: Vec<i32>,
    #[serde(rename = "requiredRepoFiles")]
    required_repo_files: Option<Vec<String>>,
}

#[derive(Debug, Clone, Deserialize)]
struct RawStep {
    tools: Vec<String>,
    #[serde(default)]
    #[serde(rename = "reportFailure")]
    report_failure: bool,
    #[serde(default)]
    #[serde(rename = "failureLabel")]
    failure_label: Option<String>,
    #[serde(default)]
    #[serde(rename = "runtimeFailureLabel")]
    runtime_failure_label: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct RawPipeline {
    id: String,
    matcher: Vec<String>,
    steps: Vec<RawStep>,
}

pub fn load(repo_root: &Path, bundled_config_path: &Path) -> Result<Config, String> {
    let bundled = read_config_file(bundled_config_path, false)?.unwrap_or_default();
    let repo_config =
        read_config_file(&repo_root.join(".github/linters.json"), true)?.unwrap_or_default();
    let tools = normalize_tools(merge_tools(bundled.tools, repo_config.tools)?)?;
    let pipelines = normalize_pipelines(
        merge_pipelines(bundled.pipelines, repo_config.pipelines),
        &tools,
    )?;
    Ok(Config { tools, pipelines })
}

fn read_config_file(path: &Path, optional: bool) -> Result<Option<RawConfig>, String> {
    let raw = match fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(error) if optional && error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(format!(
                "Failed to read linters config at {}: {error}",
                path.display()
            ));
        }
    };

    let parsed = serde_json::from_str(&raw).map_err(|error| {
        format!(
            "Failed to parse linters config at {}: {error}",
            path.display()
        )
    })?;
    Ok(Some(parsed))
}

fn merge_tools(mut base: Vec<RawTool>, overrides: Vec<RawTool>) -> Result<Vec<RawTool>, String> {
    for override_tool in overrides {
        let Some(index) = base.iter().position(|tool| tool.id == override_tool.id) else {
            return Err(format!(
                "Repo linters config may only override bundled tool ids: {}",
                override_tool.id
            ));
        };
        if base[index].command != override_tool.command {
            return Err(format!(
                "Repo linters config may not change the command for tool {}",
                override_tool.id
            ));
        }
        base[index].args = override_tool.args;
        base[index].append_files = override_tool.append_files;
        if override_tool.required_repo_files.is_some() {
            base[index].required_repo_files = override_tool.required_repo_files;
        }
    }
    Ok(base)
}

fn merge_pipelines(mut base: Vec<RawPipeline>, overrides: Vec<RawPipeline>) -> Vec<RawPipeline> {
    for override_pipeline in overrides {
        if let Some(index) = base
            .iter()
            .position(|pipeline| pipeline.id == override_pipeline.id)
        {
            base[index] = override_pipeline;
        } else {
            base.push(override_pipeline);
        }
    }
    base
}

fn normalize_tools(raw_tools: Vec<RawTool>) -> Result<HashMap<String, Tool>, String> {
    let mut tools = HashMap::new();
    for raw_tool in raw_tools {
        let RawTool {
            id,
            command,
            args,
            append_files,
            runtime_failure_exit_codes,
            required_repo_files,
        } = raw_tool;
        let required_repo_files = required_repo_files.unwrap_or_default();
        validate_id(&id, "tool")?;
        validate_runtime_failure_exit_codes(&id, &runtime_failure_exit_codes)?;
        validate_required_repo_files(&id, &required_repo_files)?;
        if tools.contains_key(&id) {
            return Err(format!("Duplicate tool id in config: {id}"));
        }
        tools.insert(
            id,
            Tool {
                command,
                args,
                append_files,
                runtime_failure_exit_codes,
                applicability: normalize_tool_applicability(required_repo_files),
            },
        );
    }
    Ok(tools)
}

fn normalize_pipelines(
    raw_pipelines: Vec<RawPipeline>,
    tools: &HashMap<String, Tool>,
) -> Result<Vec<Pipeline>, String> {
    let mut pipelines = Vec::new();
    for pipeline in raw_pipelines {
        validate_pipeline(&pipeline, tools)?;
        pipelines.push(Pipeline {
            id: pipeline.id.clone(),
            matcher: compile_matcher(&pipeline.id, &pipeline.matcher)?,
            steps: pipeline
                .steps
                .into_iter()
                .map(|step| Step {
                    tools: step.tools,
                    report_failure: step.report_failure,
                    failure_label: step.failure_label,
                    runtime_failure_label: step.runtime_failure_label,
                })
                .collect(),
        });
    }
    Ok(pipelines)
}

fn validate_runtime_failure_exit_codes(tool_id: &str, codes: &[i32]) -> Result<(), String> {
    if let Some(code) = codes.iter().copied().find(|code| *code <= 0) {
        return Err(format!(
            "Tool \"{}\" runtimeFailureExitCodes must contain only positive integers: {}",
            tool_id, code
        ));
    }
    Ok(())
}

fn validate_required_repo_files(tool_id: &str, files: &[String]) -> Result<(), String> {
    if let Some(file) = files.iter().find(|file| file.is_empty()) {
        return Err(format!(
            "Tool \"{}\" requiredRepoFiles entries must be non-empty strings: {:?}",
            tool_id, file
        ));
    }
    if let Some(file) = files.iter().find(|file| {
        Path::new(file)
            .components()
            .any(|component| matches!(component, Component::ParentDir))
    }) {
        return Err(format!(
            "Tool \"{}\" requiredRepoFiles entries must stay within the repo root: {}",
            tool_id, file
        ));
    }
    if let Some(file) = files.iter().find(|file| Path::new(file).is_absolute()) {
        return Err(format!(
            "Tool \"{}\" requiredRepoFiles entries must be repo-relative paths: {}",
            tool_id, file
        ));
    }
    Ok(())
}

fn normalize_tool_applicability(required_repo_files: Vec<String>) -> ToolApplicability {
    if required_repo_files.is_empty() {
        ToolApplicability::Always
    } else {
        ToolApplicability::RequiresRepoFiles(required_repo_files)
    }
}

fn validate_pipeline(pipeline: &RawPipeline, tools: &HashMap<String, Tool>) -> Result<(), String> {
    validate_id(&pipeline.id, "pipeline")?;
    if pipeline.steps.is_empty() {
        return Err(format!(
            "Pipeline \"{}\" must define at least one step.",
            pipeline.id
        ));
    }
    for step in &pipeline.steps {
        if step.tools.is_empty() {
            return Err(format!(
                "Each step in pipeline \"{}\" must define at least one tool.",
                pipeline.id
            ));
        }
        for tool_id in &step.tools {
            if !tools.contains_key(tool_id) {
                return Err(format!(
                    "Unknown tool referenced by pipeline \"{}\": {}",
                    pipeline.id, tool_id
                ));
            }
        }
    }
    Ok(())
}

fn validate_id(id: &str, entry_label: &str) -> Result<(), String> {
    if id.is_empty() {
        Err(format!(
            "Each {entry_label} in config must define a non-empty string id."
        ))
    } else {
        Ok(())
    }
}

fn compile_matcher(pipeline_id: &str, matcher: &[String]) -> Result<Regex, String> {
    if matcher.is_empty() {
        return Err(format!(
            "Pipeline \"{pipeline_id}\" must define matcher as a non-empty array."
        ));
    }
    if matcher.iter().any(|pattern| pattern.is_empty()) {
        return Err(format!(
            "Pipeline \"{pipeline_id}\" matcher entries must be non-empty regex strings."
        ));
    }

    let joined = matcher
        .iter()
        .map(|pattern| format!("(?:{pattern})"))
        .collect::<Vec<_>>()
        .join("|");
    Regex::new(&joined).map_err(|error| {
        format!("Failed to compile matcher for pipeline \"{pipeline_id}\": {error}")
    })
}

fn default_append_files() -> bool {
    true
}

#[cfg(test)]
mod tests {
    use super::{RawTool, merge_tools, validate_required_repo_files};

    fn raw_tool(id: &str, command: &str, args: &[&str], append_files: bool) -> RawTool {
        RawTool {
            id: id.to_string(),
            command: command.to_string(),
            args: args.iter().map(|value| value.to_string()).collect(),
            append_files,
            runtime_failure_exit_codes: Vec::new(),
            required_repo_files: None,
        }
    }

    #[test]
    fn rejects_repo_defined_tool_ids() {
        let error = merge_tools(
            vec![raw_tool("bundled", "biome", &["check"], true)],
            vec![raw_tool("repo-only", "second-tool", &["check"], true)],
        )
        .unwrap_err();
        assert_eq!(
            error,
            "Repo linters config may only override bundled tool ids: repo-only"
        );
    }

    #[test]
    fn rejects_repo_command_changes() {
        let error = merge_tools(
            vec![raw_tool("bundled", "biome", &["check"], true)],
            vec![raw_tool("bundled", "second-tool", &["check"], true)],
        )
        .unwrap_err();
        assert_eq!(
            error,
            "Repo linters config may not change the command for tool bundled"
        );
    }

    #[test]
    fn allows_repo_to_override_args_for_bundled_tools() {
        let merged = merge_tools(
            vec![raw_tool("bundled", "biome", &["check"], true)],
            vec![raw_tool("bundled", "biome", &["check", "--write"], false)],
        )
        .unwrap();
        assert_eq!(merged[0].command, "biome");
        assert_eq!(merged[0].args, vec!["check", "--write"]);
        assert!(!merged[0].append_files);
    }

    #[test]
    fn allows_repo_to_override_required_repo_files_for_bundled_tools() {
        let mut bundled = raw_tool("bundled", "eslint", &["--fix"], true);
        bundled.required_repo_files = Some(vec!["eslint.config.js".to_string()]);

        let mut override_tool = raw_tool("bundled", "eslint", &["--fix"], true);
        override_tool.required_repo_files = Some(vec![
            "eslint.config.mjs".to_string(),
            "eslint.config.cjs".to_string(),
        ]);

        let merged = merge_tools(vec![bundled], vec![override_tool]).unwrap();
        assert_eq!(
            merged[0].required_repo_files.as_ref().unwrap(),
            vec!["eslint.config.mjs", "eslint.config.cjs"]
        );
    }

    #[test]
    fn preserves_required_repo_files_when_repo_override_omits_them() {
        let mut bundled = raw_tool("bundled", "eslint", &["--fix"], true);
        bundled.required_repo_files = Some(vec!["eslint.config.js".to_string()]);

        let merged = merge_tools(
            vec![bundled],
            vec![raw_tool("bundled", "eslint", &["--fix", "--cache"], true)],
        )
        .unwrap();
        assert_eq!(
            merged[0].required_repo_files.as_ref().unwrap(),
            &vec!["eslint.config.js".to_string()]
        );
    }

    #[test]
    fn rejects_required_repo_files_that_escape_repo_root() {
        let error =
            validate_required_repo_files("bundled", &[String::from("../outside")]).unwrap_err();
        assert_eq!(
            error,
            "Tool \"bundled\" requiredRepoFiles entries must stay within the repo root: ../outside"
        );
    }
}
