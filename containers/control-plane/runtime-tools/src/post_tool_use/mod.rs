mod config;
mod executor;
mod git;
mod pipeline;
mod state;

use std::env;
use std::path::{Path, PathBuf};
use std::time::Duration;

use control_plane_exec_api::execute_remote;
use serde::Deserialize;
use tokio::runtime::Builder;

use crate::error::{ToolError, ToolResult};
use crate::support::{current_directory, read_stdin_string};

const FORWARD_ADDR_ENV: &str = "CONTROL_PLANE_POST_TOOL_USE_FORWARD_ADDR";
const FORWARD_TOKEN_ENV: &str = "CONTROL_PLANE_POST_TOOL_USE_FORWARD_TOKEN";
const FORWARD_TIMEOUT_ENV: &str = "CONTROL_PLANE_POST_TOOL_USE_FORWARD_TIMEOUT_SEC";
const FORWARD_ACTIVE_ENV: &str = "CONTROL_PLANE_POST_TOOL_USE_FORWARD_ACTIVE";

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
    if let Some(exit_code) = maybe_forward(raw_input, &input)? {
        return Ok(exit_code);
    }

    handle_local(&input)
}

fn handle_local(input: &HookInput) -> Result<i32, String> {
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

fn maybe_forward(raw_input: &str, input: &HookInput) -> Result<Option<i32>, String> {
    if matches!(env::var(FORWARD_ACTIVE_ENV).ok().as_deref(), Some("1")) {
        return Ok(None);
    }

    let Some(addr) = env::var(FORWARD_ADDR_ENV)
        .ok()
        .filter(|value| !value.trim().is_empty())
    else {
        return Ok(None);
    };
    let token = env::var(FORWARD_TOKEN_ENV)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| format!("{FORWARD_TOKEN_ENV} is required when {FORWARD_ADDR_ENV} is set"))?;
    let timeout = Duration::from_secs(parse_positive_u64(
        &env::var(FORWARD_TIMEOUT_ENV).unwrap_or_else(|_| String::from("3600")),
        FORWARD_TIMEOUT_ENV,
    )?);
    let cwd = input.cwd_path();
    let cwd = cwd.display().to_string();
    let runtime = Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| format!("failed to build postToolUse forward runtime: {error}"))?;
    let result = runtime
        .block_on(execute_remote(&addr, timeout, &token, &cwd, raw_input))
        .map_err(|error| format!("failed to forward postToolUse hook to control-plane: {error}"))?;
    if !result.stdout.is_empty() {
        print!("{}", result.stdout);
    }
    if !result.stderr.is_empty() {
        eprint!("{}", result.stderr);
    }
    Ok(Some(result.exit_code))
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

fn parse_positive_u64(raw_value: &str, variable_name: &str) -> Result<u64, String> {
    let value = raw_value
        .parse::<u64>()
        .map_err(|_| format!("{variable_name} must be a positive integer: {raw_value}"))?;
    if value == 0 {
        Err(format!("{variable_name} must be a positive integer: {raw_value}"))
    } else {
        Ok(value)
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::Path;
    use std::time::Duration;

    use control_plane_exec_api::{ServerConfig, ServerMode, serve_with_listener};
    use tempfile::TempDir;
    use tokio::net::TcpListener;
    use tokio::runtime::Builder;
    use tokio::sync::oneshot;

    use crate::test_support::{EnvRestore, lock_env};

    use super::{FORWARD_ADDR_ENV, FORWARD_TIMEOUT_ENV, FORWARD_TOKEN_ENV, handle};

    fn start_server(
        workspace: &Path,
        remote_home: &Path,
        token: &str,
    ) -> (String, oneshot::Sender<()>, std::thread::JoinHandle<()>) {
        let (addr_tx, addr_rx) = std::sync::mpsc::channel();
        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        let workspace = workspace.to_path_buf();
        let remote_home = remote_home.to_path_buf();
        let token = token.to_string();
        let handle = std::thread::spawn(move || {
            let runtime = Builder::new_current_thread().enable_all().build().unwrap();
            runtime.block_on(async move {
                let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
                let addr = format!("http://{}", listener.local_addr().unwrap());
                addr_tx.send(addr).unwrap();
                let config = ServerConfig {
                    port: listener.local_addr().unwrap().port(),
                    workspace_root: workspace.clone(),
                    logical_workspace_root: workspace,
                    chroot_root: None,
                    environment_mount_path: None,
                    git_hooks_source: None,
                    remote_home,
                    git_user_name: None,
                    git_user_email: None,
                    startup_script: None,
                    mode: ServerMode::PostToolUse,
                    exec_api_token: token,
                    exec_timeout: Duration::from_secs(5),
                    run_as_uid: unsafe { libc::geteuid() },
                    run_as_gid: unsafe { libc::getegid() },
                };
                serve_with_listener(listener, config, async {
                    let _ = shutdown_rx.await;
                })
                .await
                .unwrap();
            });
        });
        (addr_rx.recv().unwrap(), shutdown_tx, handle)
    }

    #[test]
    fn forwards_to_control_plane_post_tool_use_api() {
        let _env_lock = lock_env();
        let workspace = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        let hook_dir = home.path().join(".copilot/hooks/postToolUse");
        let hook_input_path = workspace.path().join("forwarded-hook-input.json");
        fs::create_dir_all(&hook_dir).unwrap();
        let hook_path = hook_dir.join("main");
        fs::write(
            &hook_path,
            format!(
                "#!/usr/bin/env bash\nset -euo pipefail\ncat > {}\nprintf 'hook-stdout\\n'\nprintf 'hook-stderr\\n' >&2\nexit 7\n",
                hook_input_path.display()
            ),
        )
        .unwrap();
        let mut permissions = fs::metadata(&hook_path).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&hook_path, permissions).unwrap();

        let (addr, shutdown_tx, server_handle) = start_server(workspace.path(), home.path(), "token");
        let _forward_addr = EnvRestore::set(FORWARD_ADDR_ENV, &addr);
        let _forward_token = EnvRestore::set(FORWARD_TOKEN_ENV, "token");
        let _forward_timeout = EnvRestore::set(FORWARD_TIMEOUT_ENV, "30");

        let raw_input = format!(
            r#"{{"cwd":"{}","toolResult":{{"resultType":"success"}}}}"#,
            workspace.path().display()
        );
        let exit_code = handle(&raw_input).unwrap();
        assert_eq!(exit_code, 7);
        assert_eq!(fs::read_to_string(&hook_input_path).unwrap(), raw_input);

        shutdown_tx.send(()).unwrap();
        server_handle.join().unwrap();
    }
}
