use std::env;
use std::ffi::OsString;
use std::path::{Path, PathBuf};

use crate::audit;
use crate::cleanup;
use crate::error::{ToolError, ToolResult};
use crate::exec_forward;
use crate::install_skills;
use crate::k8s_job;
use crate::post_tool_use;

const RUNTIME_TOOL: &str = "control-plane-runtime-tool";

pub fn dispatch_main() -> ToolResult<i32> {
    let invocation = resolve_invocation(env::args_os().next())?;
    let mut args = env::args().skip(1).collect::<Vec<_>>();
    dispatch(&invocation, &mut args)
}

fn resolve_invocation(arg0: Option<OsString>) -> ToolResult<String> {
    let path = arg0
        .map(PathBuf::from)
        .or_else(|| env::current_exe().ok())
        .ok_or_else(|| ToolError::new(1, RUNTIME_TOOL, "failed to resolve executable name"))?;
    let exe_name = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| ToolError::new(1, RUNTIME_TOOL, "failed to resolve executable name"))?;

    if exe_name == "main" {
        return Ok(main_alias(&path));
    }

    Ok(exe_name.to_string())
}

fn main_alias(path: &Path) -> String {
    match parent_name(path) {
        Some("audit") => "audit".to_string(),
        Some("postToolUse") => "post-tool-use".to_string(),
        _ => "main".to_string(),
    }
}

fn parent_name(path: &Path) -> Option<&str> {
    path.parent()
        .and_then(Path::file_name)
        .and_then(|value| value.to_str())
}

fn dispatch(invocation: &str, args: &mut Vec<String>) -> ToolResult<i32> {
    match invocation {
        RUNTIME_TOOL => dispatch_subcommand(args),
        "install-git-skills-from-manifest" => install_skills::run(args),
        "audit" => audit::run(args),
        "exec-forward" => exec_forward::run(args),
        "cleanup" => cleanup::run(args),
        "k8s-job-wait" => k8s_job::run_wait(args),
        "k8s-job-pod" => k8s_job::run_pod(args),
        "k8s-job-logs" => k8s_job::run_logs(args),
        "post-tool-use" | "postToolUse" => post_tool_use::run(args),
        other => Err(ToolError::new(
            64,
            RUNTIME_TOOL,
            format!("unsupported invocation: {other}"),
        )),
    }
}

fn dispatch_subcommand(args: &mut Vec<String>) -> ToolResult<i32> {
    let Some(subcommand) = args.first().cloned() else {
        return Err(ToolError::new(64, RUNTIME_TOOL, "missing subcommand"));
    };

    args.remove(0);
    dispatch(&subcommand, args)
}
