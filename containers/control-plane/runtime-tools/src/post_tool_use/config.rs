use std::collections::HashMap;
use std::fs;
use std::path::Path;

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
}

#[derive(Debug, Clone)]
pub struct Step {
    pub tools: Vec<String>,
    pub report_failure: bool,
    pub failure_label: Option<String>,
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
    let tools = normalize_tools(merge_tools(bundled.tools, repo_config.tools))?;
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

fn merge_tools(mut base: Vec<RawTool>, overrides: Vec<RawTool>) -> Vec<RawTool> {
    for override_tool in overrides {
        if let Some(index) = base.iter().position(|tool| tool.id == override_tool.id) {
            base[index] = override_tool;
        } else {
            base.push(override_tool);
        }
    }
    base
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
    for tool in raw_tools {
        validate_id(&tool.id, "tool")?;
        if tools.contains_key(&tool.id) {
            return Err(format!("Duplicate tool id in config: {}", tool.id));
        }
        tools.insert(
            tool.id,
            Tool {
                command: tool.command,
                args: tool.args,
                append_files: tool.append_files,
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
                })
                .collect(),
        });
    }
    Ok(pipelines)
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
