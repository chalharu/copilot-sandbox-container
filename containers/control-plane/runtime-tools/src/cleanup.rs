use std::process::{Command, Stdio};

use crate::error::{ToolError, ToolResult};
use crate::session_exec::{fast_execution_enabled, session_exec_bin, session_key};
use crate::support::{output_message, read_stdin_string};

pub fn run(_args: &[String]) -> ToolResult<i32> {
    let raw_input = read_stdin_string().map_err(|error| {
        ToolError::new(1, "control-plane session cleanup hook", error.to_string())
    })?;
    handle(&raw_input)
        .map_err(|message| ToolError::new(1, "control-plane session cleanup hook", message))?;
    Ok(0)
}

pub fn handle(_raw_input: &str) -> Result<(), String> {
    if !fast_execution_enabled() {
        return Ok(());
    }

    let output = Command::new(session_exec_bin())
        .arg("cleanup")
        .arg("--session-key")
        .arg(session_key())
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

#[cfg(test)]
mod tests {
    use std::fs;

    use tempfile::TempDir;

    use crate::support::shell_quote;
    use crate::test_support::{EnvRestore, lock_env, write_executable};

    use super::handle;

    #[test]
    fn invokes_session_exec_cleanup() {
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

        handle("").unwrap();

        let recorded = fs::read_to_string(&record_path).unwrap();
        assert_eq!(recorded.trim(), "cleanup --session-key cleanup-key");
    }
}
