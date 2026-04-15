use std::collections::HashMap;
use std::env;
use std::ffi::OsString;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use super::config::{Config, Tool};

const DEFAULT_RUNTIME_FAILURE_LABEL: &str = "Hook runtime reported tool execution failure:";
const HOOK_RUNTIME_FAILURE_EXIT_CODE: i32 = 70;

pub fn run_pipelines(
    config: &Config,
    repo_root: &Path,
    files_by_pipeline: &HashMap<String, Vec<String>>,
) -> Result<i32, String> {
    let mut exit_code = 0;
    let mut has_reported_failure = false;

    for pipeline in &config.pipelines {
        let files = files_by_pipeline
            .get(&pipeline.id)
            .cloned()
            .unwrap_or_default();
        if files.is_empty() {
            continue;
        }

        for step in &pipeline.steps {
            let result = run_step_with_fallback(config, repo_root, &step.tools, &files)?;
            if result.status == 0 {
                continue;
            }

            if result.runtime_failure {
                if has_reported_failure {
                    eprintln!();
                }
                eprintln!(
                    "{}",
                    step.runtime_failure_label
                        .as_deref()
                        .unwrap_or(DEFAULT_RUNTIME_FAILURE_LABEL)
                );
                write_result_output(&result);
                return Ok(exit_code.max(result.status));
            }

            if !step.report_failure {
                continue;
            }

            if let Some(label) = &step.failure_label {
                if has_reported_failure {
                    eprintln!();
                }
                eprintln!("{label}");
            }
            write_result_output(&result);
            exit_code = exit_code.max(result.status);
            has_reported_failure = true;
        }
    }

    Ok(exit_code)
}

fn run_step_with_fallback(
    config: &Config,
    repo_root: &Path,
    tool_ids: &[String],
    files: &[String],
) -> Result<CommandResult, String> {
    let tool_env = build_tool_env()?;
    let mut attempted = Vec::new();

    for tool_id in tool_ids {
        let tool = config
            .tools
            .get(tool_id)
            .ok_or_else(|| format!("unknown tool id in runtime config: {tool_id}"))?;
        let args = command_args(tool, files);

        match execute_tool(tool, &args, repo_root, &tool_env) {
            Ok(result) => {
                return Ok(CommandResult {
                    runtime_failure: tool.runtime_failure_exit_codes.contains(&result.status),
                    ..result
                });
            }
            Err(ExecuteError::MissingCommand) => {
                attempted.push(format!("{tool_id} ({})", tool.command));
            }
            Err(ExecuteError::Spawn(message)) => {
                return Ok(CommandResult {
                    status: HOOK_RUNTIME_FAILURE_EXIT_CODE,
                    stdout: String::new(),
                    stderr: format!("{message}\n"),
                    runtime_failure: true,
                });
            }
        }
    }

    Ok(CommandResult {
        status: HOOK_RUNTIME_FAILURE_EXIT_CODE,
        stdout: String::new(),
        stderr: format!("No available tool found. Tried: {}\n", attempted.join(", ")),
        runtime_failure: true,
    })
}

fn command_args(tool: &Tool, files: &[String]) -> Vec<String> {
    let mut args = tool.args.clone();
    if tool.append_files {
        args.extend(files.iter().cloned());
    }
    args
}

fn build_tool_env() -> Result<HashMap<OsString, OsString>, String> {
    let hook_cache_root = hook_cache_root();
    let npm_cache = hook_cache_root.join("npm-cache");
    let node_compile_cache = hook_cache_root.join("node-compile-cache");
    std::fs::create_dir_all(&npm_cache).map_err(|error| {
        format!(
            "failed to create npm cache {}: {error}",
            npm_cache.display()
        )
    })?;
    std::fs::create_dir_all(&node_compile_cache).map_err(|error| {
        format!(
            "failed to create node compile cache {}: {error}",
            node_compile_cache.display()
        )
    })?;

    let mut env_map: HashMap<OsString, OsString> = env::vars_os().collect();
    env_map
        .entry(OsString::from("TMPDIR"))
        .or_insert(hook_cache_root.into_os_string());
    env_map
        .entry(OsString::from("NODE_COMPILE_CACHE"))
        .or_insert(node_compile_cache.into_os_string());
    env_map
        .entry(OsString::from("NPM_CONFIG_CACHE"))
        .or_insert(npm_cache.clone().into_os_string());
    env_map
        .entry(OsString::from("npm_config_cache"))
        .or_insert(npm_cache.into_os_string());
    Ok(env_map)
}

fn hook_cache_root() -> PathBuf {
    if let Some(path) = env::var_os("CONTROL_PLANE_HOOK_TMP_ROOT") {
        return PathBuf::from(path);
    }

    let tmp_root = env::var_os("CONTROL_PLANE_TMP_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/var/tmp/control-plane"));
    tmp_root.join("hooks")
}

fn execute_tool(
    tool: &Tool,
    args: &[String],
    repo_root: &Path,
    tool_env: &HashMap<OsString, OsString>,
) -> Result<CommandResult, ExecuteError> {
    let output = Command::new(&tool.command)
        .args(args)
        .current_dir(repo_root)
        .envs(tool_env)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|error| classify_spawn_error(&tool.command, error))?;

    Ok(CommandResult {
        status: output.status.code().unwrap_or(1),
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        runtime_failure: false,
    })
}

fn classify_spawn_error(command: &str, error: io::Error) -> ExecuteError {
    if error.kind() == io::ErrorKind::NotFound {
        ExecuteError::MissingCommand
    } else {
        ExecuteError::Spawn(format!("failed to run {command}: {error}"))
    }
}

fn write_result_output(result: &CommandResult) {
    if !result.stdout.is_empty() {
        print!("{}", result.stdout);
    }
    if !result.stderr.is_empty() {
        eprint!("{}", result.stderr);
    }
}

struct CommandResult {
    status: i32,
    stdout: String,
    stderr: String,
    runtime_failure: bool,
}

enum ExecuteError {
    MissingCommand,
    Spawn(String),
}
