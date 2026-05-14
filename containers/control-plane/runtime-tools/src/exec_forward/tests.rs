use std::fs;

use serde_json::{Value, json};
use tempfile::TempDir;

use crate::support::shell_quote;
use crate::test_support::{EnvRestore, lock_env, write_executable};

use super::handle;

#[test]
fn rewrites_bash_command() {
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

    let output = handle(
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
fn passes_through_same_session_proxy_command() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let helper_path = temp_dir.path().join("control-plane-session-exec");
    write_executable(
        &helper_path,
        "#!/usr/bin/env bash\nset -euo pipefail\nprintf 'unexpected helper call\\n' >&2\nexit 1\n",
    );

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _session_exec = EnvRestore::set(
        "CONTROL_PLANE_SESSION_EXEC_BIN",
        helper_path.to_str().unwrap(),
    );
    let _session_key = EnvRestore::set("CONTROL_PLANE_HOOK_SESSION_KEY", "session-123");

    let proxied_command = [
        shell_quote(helper_path.to_str().unwrap()),
        "proxy".to_string(),
        "--session-key".to_string(),
        shell_quote("session-123"),
        "--cwd".to_string(),
        shell_quote("/workspace"),
        "--command-base64".to_string(),
        shell_quote("ZWNobyBoZWxsbw=="),
    ]
    .join(" ");
    let input = json!({
        "toolName": "bash",
        "cwd": "/workspace",
        "toolArgs": {
            "command": proxied_command,
            "description": "demo"
        }
    })
    .to_string();

    assert!(handle(&input).is_none());
}

#[test]
fn denies_on_prepare_failure() {
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

    let output =
        handle(r#"{"toolName":"bash","toolArgs":{"command":"echo hello","description":"demo"}}"#)
            .unwrap();
    let value: Value = serde_json::from_str(&output).unwrap();

    assert_eq!(value["permissionDecision"], "deny");
    assert_eq!(value["permissionDecisionReason"], "prepare exploded");
}

#[test]
fn denies_read_tool_for_non_workspace_path_without_copying() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let helper_path = temp_dir.path().join("control-plane-session-exec");
    write_executable(
        &helper_path,
        "#!/usr/bin/env bash\nset -euo pipefail\nprintf 'unexpected helper call\\n' >&2\nexit 1\n",
    );
    let cache_dir = temp_dir.path().join("hook-cache");

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _session_exec = EnvRestore::set(
        "CONTROL_PLANE_SESSION_EXEC_BIN",
        helper_path.to_str().unwrap(),
    );
    let _session_key = EnvRestore::set("CONTROL_PLANE_HOOK_SESSION_KEY", "session-123");
    let _cache_root = EnvRestore::set("CONTROL_PLANE_HOOK_TMP_ROOT", cache_dir.to_str().unwrap());

    let input = json!({
        "toolName": "Read",
        "cwd": "/workspace",
        "toolArgs": {
            "file_path": temp_dir.path().join("exec-pod-only").join("remote.txt"),
            "limit": 200
        }
    })
    .to_string();
    let output = handle(&input).unwrap();
    let value: Value = serde_json::from_str(&output).unwrap();

    assert_eq!(value["permissionDecision"], "deny");
    let reason = value["permissionDecisionReason"].as_str().unwrap();
    assert!(reason.contains("outside the shared workspace and control-plane local roots"));
    assert!(reason.contains("built-in file tool would run against the control-plane filesystem"));
    assert!(reason.contains("copying from the Exec Pod would not preserve path semantics"));
    assert!(reason.contains("Use Bash for non-workspace Exec Pod file access"));
    assert!(!cache_dir.exists());
}

#[test]
fn denies_view_tool_for_non_workspace_path_without_copying() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let helper_path = temp_dir.path().join("control-plane-session-exec");
    write_executable(
        &helper_path,
        "#!/usr/bin/env bash\nset -euo pipefail\nprintf 'unexpected helper call\\n' >&2\nexit 1\n",
    );
    let cache_dir = temp_dir.path().join("hook-cache");

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _session_exec = EnvRestore::set(
        "CONTROL_PLANE_SESSION_EXEC_BIN",
        helper_path.to_str().unwrap(),
    );
    let _session_key = EnvRestore::set("CONTROL_PLANE_HOOK_SESSION_KEY", "session-123");
    let _cache_root = EnvRestore::set("CONTROL_PLANE_HOOK_TMP_ROOT", cache_dir.to_str().unwrap());

    let input = json!({
        "toolName": "view",
        "cwd": "/workspace",
        "toolArgs": {
            "path": temp_dir.path().join("exec-pod-only").join("remote.txt"),
            "limit": 200
        }
    })
    .to_string();
    let output = handle(&input).unwrap();
    let value: Value = serde_json::from_str(&output).unwrap();

    assert_eq!(value["permissionDecision"], "deny");
    assert!(
        value["permissionDecisionReason"]
            .as_str()
            .unwrap()
            .contains("copying from the Exec Pod would not preserve path semantics")
    );
    assert!(!cache_dir.exists());
}

#[test]
fn denies_write_tool_for_non_workspace_path_without_marker_file() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let helper_path = temp_dir.path().join("control-plane-session-exec");
    write_executable(
        &helper_path,
        "#!/usr/bin/env bash\nset -euo pipefail\nprintf 'unexpected helper call\\n' >&2\nexit 1\n",
    );
    let cache_dir = temp_dir.path().join("hook-cache");

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _session_exec = EnvRestore::set(
        "CONTROL_PLANE_SESSION_EXEC_BIN",
        helper_path.to_str().unwrap(),
    );
    let _session_key = EnvRestore::set("CONTROL_PLANE_HOOK_SESSION_KEY", "session-123");
    let _cache_root = EnvRestore::set("CONTROL_PLANE_HOOK_TMP_ROOT", cache_dir.to_str().unwrap());

    let input = json!({
        "toolName": "Write",
        "cwd": "/workspace",
        "toolArgs": {
            "file_path": temp_dir.path().join("exec-pod-only").join("new.txt"),
            "content": "hello\nworld\n"
        }
    })
    .to_string();
    let output = handle(&input).unwrap();
    let value: Value = serde_json::from_str(&output).unwrap();

    assert_eq!(value["permissionDecision"], "deny");
    let reason = value["permissionDecisionReason"].as_str().unwrap();
    assert!(reason.contains("built-in file tool would run against the control-plane filesystem"));
    assert!(reason.contains("copying from the Exec Pod would not preserve path semantics"));
    assert!(reason.contains("Use Bash for non-workspace Exec Pod file access"));
    assert!(!cache_dir.exists());
}

#[test]
fn denies_edit_tool_for_non_workspace_path_without_marker_file() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let helper_path = temp_dir.path().join("control-plane-session-exec");
    write_executable(
        &helper_path,
        "#!/usr/bin/env bash\nset -euo pipefail\nprintf 'unexpected helper call\\n' >&2\nexit 1\n",
    );
    let cache_dir = temp_dir.path().join("hook-cache");

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _session_exec = EnvRestore::set(
        "CONTROL_PLANE_SESSION_EXEC_BIN",
        helper_path.to_str().unwrap(),
    );
    let _session_key = EnvRestore::set("CONTROL_PLANE_HOOK_SESSION_KEY", "session-123");
    let _cache_root = EnvRestore::set("CONTROL_PLANE_HOOK_TMP_ROOT", cache_dir.to_str().unwrap());

    let input = json!({
        "toolName": "edit",
        "cwd": "/workspace",
        "toolArgs": {
            "path": temp_dir.path().join("exec-pod-only").join("edit.txt"),
            "text": "edited\n"
        }
    })
    .to_string();
    let output = handle(&input).unwrap();
    let value: Value = serde_json::from_str(&output).unwrap();

    assert_eq!(value["permissionDecision"], "deny");
    assert!(
        value["permissionDecisionReason"]
            .as_str()
            .unwrap()
            .contains("copying from the Exec Pod would not preserve path semantics")
    );
    assert!(!cache_dir.exists());
}

#[test]
fn passes_read_tool_through_for_shared_workspace_path() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let helper_path = temp_dir.path().join("control-plane-session-exec");
    write_executable(
        &helper_path,
        "#!/usr/bin/env bash\nset -euo pipefail\nprintf 'unexpected helper call\\n' >&2\nexit 1\n",
    );

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _session_exec = EnvRestore::set(
        "CONTROL_PLANE_SESSION_EXEC_BIN",
        helper_path.to_str().unwrap(),
    );
    let workspace = temp_dir.path().join("workspace");
    fs::create_dir_all(&workspace).unwrap();
    let _workspace = EnvRestore::set(
        "CONTROL_PLANE_WORKSPACE_MOUNT_PATH",
        workspace.to_str().unwrap(),
    );
    let input = json!({
        "toolName": "Read",
        "cwd": workspace,
        "toolArgs": {
            "file_path": temp_dir.path().join("workspace").join("shared.txt")
        }
    })
    .to_string();

    assert!(handle(&input).is_none());
}

#[test]
fn passes_write_tool_through_for_relative_shared_workspace_path() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let helper_path = temp_dir.path().join("control-plane-session-exec");
    write_executable(
        &helper_path,
        "#!/usr/bin/env bash\nset -euo pipefail\nprintf 'unexpected helper call\\n' >&2\nexit 1\n",
    );

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _session_exec = EnvRestore::set(
        "CONTROL_PLANE_SESSION_EXEC_BIN",
        helper_path.to_str().unwrap(),
    );
    let workspace = temp_dir.path().join("workspace");
    let project = workspace.join("project");
    fs::create_dir_all(&project).unwrap();
    let _workspace = EnvRestore::set(
        "CONTROL_PLANE_WORKSPACE_MOUNT_PATH",
        workspace.to_str().unwrap(),
    );
    let input = json!({
        "toolName": "Write",
        "cwd": project,
        "toolArgs": {
            "file_path": "src/shared.txt",
            "content": "shared\n"
        }
    })
    .to_string();

    assert!(handle(&input).is_none());
}

#[test]
fn passes_read_tool_through_for_control_plane_session_state_path() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let copilot_home = temp_dir.path().join("copilot-home");
    let session_dir = copilot_home.join("session-state").join("session-123");
    fs::create_dir_all(&session_dir).unwrap();
    let plan_path = session_dir.join("plan.md");
    fs::write(&plan_path, "# plan\n").unwrap();

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _copilot_home = EnvRestore::set("COPILOT_HOME", copilot_home.to_str().unwrap());
    let input = json!({
        "toolName": "Read",
        "cwd": "/workspace",
        "toolArgs": {
            "file_path": plan_path
        }
    })
    .to_string();

    assert!(handle(&input).is_none());
}

#[test]
fn passes_write_tool_through_for_control_plane_session_state_path() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let copilot_home = temp_dir.path().join("copilot-home");
    let session_dir = copilot_home.join("session-state").join("session-123");
    fs::create_dir_all(&session_dir).unwrap();

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _copilot_home = EnvRestore::set("COPILOT_HOME", copilot_home.to_str().unwrap());
    let input = json!({
        "toolName": "Write",
        "cwd": "/workspace",
        "toolArgs": {
            "file_path": session_dir.join("plan.md"),
            "content": "# plan\n"
        }
    })
    .to_string();

    assert!(handle(&input).is_none());
}

#[test]
fn denies_read_tool_for_unspecified_control_plane_home_file() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let copilot_home = temp_dir.path().join("copilot-home");
    fs::create_dir_all(&copilot_home).unwrap();
    let config_path = copilot_home.join("config.json");
    fs::write(&config_path, "{}\n").unwrap();

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _copilot_home = EnvRestore::set("COPILOT_HOME", copilot_home.to_str().unwrap());
    let input = json!({
        "toolName": "Read",
        "cwd": "/workspace",
        "toolArgs": {
            "file_path": config_path
        }
    })
    .to_string();

    let output = handle(&input).unwrap();
    let value: Value = serde_json::from_str(&output).unwrap();

    assert_eq!(value["permissionDecision"], "deny");
}

#[test]
fn passes_write_tool_through_for_control_plane_tmp_root_path() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let tmp_root = temp_dir.path().join("control-plane-tmp");
    fs::create_dir_all(&tmp_root).unwrap();

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _tmp_root = EnvRestore::set("CONTROL_PLANE_TMP_ROOT", tmp_root.to_str().unwrap());
    let input = json!({
        "toolName": "Write",
        "cwd": "/workspace",
        "toolArgs": {
            "file_path": tmp_root.join("tool-output.txt"),
            "content": "local\n"
        }
    })
    .to_string();

    assert!(handle(&input).is_none());
}

#[test]
fn passes_read_tool_through_for_control_plane_hook_tmp_root_path() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let hook_tmp_root = temp_dir.path().join("hook-tmp");
    fs::create_dir_all(&hook_tmp_root).unwrap();

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _hook_tmp_root = EnvRestore::set(
        "CONTROL_PLANE_HOOK_TMP_ROOT",
        hook_tmp_root.to_str().unwrap(),
    );
    let input = json!({
        "toolName": "Read",
        "cwd": "/workspace",
        "toolArgs": {
            "file_path": hook_tmp_root.join("tool-output.txt")
        }
    })
    .to_string();

    assert!(handle(&input).is_none());
}

#[test]
fn passes_read_tool_through_for_configured_local_file_root() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let local_root = temp_dir.path().join("local-root");
    fs::create_dir_all(&local_root).unwrap();

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _local_roots = EnvRestore::set(
        "CONTROL_PLANE_LOCAL_FILE_ROOTS",
        local_root.to_str().unwrap(),
    );
    let input = json!({
        "toolName": "Read",
        "cwd": "/workspace",
        "toolArgs": {
            "file_path": local_root.join("state.json")
        }
    })
    .to_string();

    assert!(handle(&input).is_none());
}

#[test]
fn passes_read_tool_through_for_read_only_control_plane_config_root() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let home = temp_dir.path().join("home");
    let config_root = home.join(".config").join("gh");
    fs::create_dir_all(&config_root).unwrap();
    let hosts_path = config_root.join("hosts.yml");
    fs::write(&hosts_path, "github.com: {}\n").unwrap();

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _home = EnvRestore::set("HOME", home.to_str().unwrap());
    let input = json!({
        "toolName": "Read",
        "cwd": "/workspace",
        "toolArgs": {
            "file_path": hosts_path
        }
    })
    .to_string();

    assert!(handle(&input).is_none());
}

#[test]
fn passes_read_tool_through_for_configured_read_only_local_file_root() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let local_root = temp_dir.path().join("local-root");
    fs::create_dir_all(&local_root).unwrap();
    let state_path = local_root.join("state.json");
    fs::write(&state_path, "{}\n").unwrap();

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _local_roots = EnvRestore::set(
        "CONTROL_PLANE_LOCAL_READ_ONLY_ROOTS",
        local_root.to_str().unwrap(),
    );
    let input = json!({
        "toolName": "Read",
        "cwd": "/workspace",
        "toolArgs": {
            "file_path": state_path
        }
    })
    .to_string();

    assert!(handle(&input).is_none());
}

#[test]
fn passes_write_tool_through_for_configured_read_write_local_file_root() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let local_root = temp_dir.path().join("local-root");
    fs::create_dir_all(&local_root).unwrap();

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _local_roots = EnvRestore::set(
        "CONTROL_PLANE_LOCAL_READ_WRITE_ROOTS",
        local_root.to_str().unwrap(),
    );
    let input = json!({
        "toolName": "Write",
        "cwd": "/workspace",
        "toolArgs": {
            "file_path": local_root.join("state.json"),
            "content": "{}\n"
        }
    })
    .to_string();

    assert!(handle(&input).is_none());
}

#[test]
fn denies_write_tool_for_configured_read_only_local_file_root() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let local_root = temp_dir.path().join("local-root");
    fs::create_dir_all(&local_root).unwrap();

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _local_roots = EnvRestore::set(
        "CONTROL_PLANE_LOCAL_FILE_ROOTS",
        local_root.to_str().unwrap(),
    );
    let input = json!({
        "toolName": "Write",
        "cwd": "/workspace",
        "toolArgs": {
            "file_path": local_root.join("state.json"),
            "content": "{}\n"
        }
    })
    .to_string();

    let output = handle(&input).unwrap();
    let value: Value = serde_json::from_str(&output).unwrap();

    assert_eq!(value["permissionDecision"], "deny");
    assert!(
        value["permissionDecisionReason"]
            .as_str()
            .unwrap()
            .contains("control-plane writable local roots")
    );
}

#[test]
fn denies_write_tool_for_read_only_control_plane_config_root() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let home = temp_dir.path().join("home");
    let config_root = home.join(".config").join("gh");
    fs::create_dir_all(&config_root).unwrap();

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _home = EnvRestore::set("HOME", home.to_str().unwrap());
    let input = json!({
        "toolName": "Write",
        "cwd": "/workspace",
        "toolArgs": {
            "file_path": config_root.join("hosts.yml"),
            "content": "github.com: {}\n"
        }
    })
    .to_string();

    let output = handle(&input).unwrap();
    let value: Value = serde_json::from_str(&output).unwrap();

    assert_eq!(value["permissionDecision"], "deny");
}

#[test]
fn denies_write_tool_for_read_only_control_plane_ssh_root() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let home = temp_dir.path().join("home");
    let ssh_root = home.join(".ssh");
    fs::create_dir_all(&ssh_root).unwrap();

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _home = EnvRestore::set("HOME", home.to_str().unwrap());
    let input = json!({
        "toolName": "Write",
        "cwd": "/workspace",
        "toolArgs": {
            "file_path": ssh_root.join("config"),
            "content": "Host *\n"
        }
    })
    .to_string();

    let output = handle(&input).unwrap();
    let value: Value = serde_json::from_str(&output).unwrap();

    assert_eq!(value["permissionDecision"], "deny");
}

#[cfg(unix)]
#[test]
fn denies_read_tool_when_control_plane_local_symlink_points_outside() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let copilot_home = temp_dir.path().join("copilot-home");
    let session_state = copilot_home.join("session-state");
    let outside = temp_dir.path().join("outside");
    fs::create_dir_all(&session_state).unwrap();
    fs::create_dir_all(&outside).unwrap();
    fs::write(outside.join("secret.txt"), "secret\n").unwrap();
    std::os::unix::fs::symlink(
        outside.join("secret.txt"),
        session_state.join("secret-link"),
    )
    .unwrap();

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _copilot_home = EnvRestore::set("COPILOT_HOME", copilot_home.to_str().unwrap());
    let input = json!({
        "toolName": "Read",
        "cwd": "/workspace",
        "toolArgs": {
            "file_path": session_state.join("secret-link")
        }
    })
    .to_string();

    let output = handle(&input).unwrap();
    let value: Value = serde_json::from_str(&output).unwrap();

    assert_eq!(value["permissionDecision"], "deny");
    assert!(
        value["permissionDecisionReason"]
            .as_str()
            .unwrap()
            .contains("copying from the Exec Pod would not preserve path semantics")
    );
}

#[test]
fn denies_read_tool_when_path_traversal_escapes_workspace() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let helper_path = temp_dir.path().join("control-plane-session-exec");
    write_executable(
        &helper_path,
        "#!/usr/bin/env bash\nset -euo pipefail\nprintf 'unexpected helper call\\n' >&2\nexit 1\n",
    );
    let cache_dir = temp_dir.path().join("hook-cache");

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _session_exec = EnvRestore::set(
        "CONTROL_PLANE_SESSION_EXEC_BIN",
        helper_path.to_str().unwrap(),
    );
    let _session_key = EnvRestore::set("CONTROL_PLANE_HOOK_SESSION_KEY", "session-123");
    let _cache_root = EnvRestore::set("CONTROL_PLANE_HOOK_TMP_ROOT", cache_dir.to_str().unwrap());
    let _workspace = EnvRestore::set("CONTROL_PLANE_WORKSPACE_MOUNT_PATH", "/workspace");

    let output = handle(
            r#"{"toolName":"Read","cwd":"/workspace","toolArgs":{"file_path":"/workspace/../etc/config"}}"#,
        )
        .unwrap();
    let value: Value = serde_json::from_str(&output).unwrap();

    assert_eq!(value["permissionDecision"], "deny");
    assert!(
        value["permissionDecisionReason"]
            .as_str()
            .unwrap()
            .contains("copying from the Exec Pod would not preserve path semantics")
    );
    assert!(!cache_dir.exists());
}

#[test]
fn denies_write_tool_for_near_workspace_prefix() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let helper_path = temp_dir.path().join("control-plane-session-exec");
    write_executable(
        &helper_path,
        "#!/usr/bin/env bash\nset -euo pipefail\nprintf 'unexpected helper call\\n' >&2\nexit 1\n",
    );
    let cache_dir = temp_dir.path().join("hook-cache");

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _session_exec = EnvRestore::set(
        "CONTROL_PLANE_SESSION_EXEC_BIN",
        helper_path.to_str().unwrap(),
    );
    let _session_key = EnvRestore::set("CONTROL_PLANE_HOOK_SESSION_KEY", "session-123");
    let _cache_root = EnvRestore::set("CONTROL_PLANE_HOOK_TMP_ROOT", cache_dir.to_str().unwrap());
    let _workspace = EnvRestore::set("CONTROL_PLANE_WORKSPACE_MOUNT_PATH", "/workspace");

    let output = handle(
            r#"{"toolName":"Write","cwd":"/workspace","toolArgs":{"file_path":"/workspace-other/file.txt","content":"outside\n"}}"#,
        )
        .unwrap();
    let value: Value = serde_json::from_str(&output).unwrap();

    assert_eq!(value["permissionDecision"], "deny");
    assert!(
        value["permissionDecisionReason"]
            .as_str()
            .unwrap()
            .contains("copying from the Exec Pod would not preserve path semantics")
    );
    assert!(!cache_dir.exists());
}

#[test]
fn passes_read_tool_through_when_normalized_relative_path_stays_in_workspace() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let helper_path = temp_dir.path().join("control-plane-session-exec");
    write_executable(
        &helper_path,
        "#!/usr/bin/env bash\nset -euo pipefail\nprintf 'unexpected helper call\\n' >&2\nexit 1\n",
    );

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _session_exec = EnvRestore::set(
        "CONTROL_PLANE_SESSION_EXEC_BIN",
        helper_path.to_str().unwrap(),
    );
    let workspace = temp_dir.path().join("workspace");
    let subdir = workspace.join("subdir");
    fs::create_dir_all(&subdir).unwrap();
    let _workspace = EnvRestore::set(
        "CONTROL_PLANE_WORKSPACE_MOUNT_PATH",
        workspace.to_str().unwrap(),
    );
    let input = json!({
        "toolName": "Read",
        "cwd": subdir,
        "toolArgs": {
            "file_path": "../shared.txt"
        }
    })
    .to_string();

    assert!(handle(&input).is_none());
}

#[cfg(unix)]
#[test]
fn denies_read_tool_when_workspace_symlink_points_outside() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let workspace = temp_dir.path().join("workspace");
    let outside = temp_dir.path().join("outside");
    fs::create_dir_all(&workspace).unwrap();
    fs::create_dir_all(&outside).unwrap();
    fs::write(outside.join("secret.txt"), "secret\n").unwrap();
    std::os::unix::fs::symlink(outside.join("secret.txt"), workspace.join("secret-link")).unwrap();

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _workspace = EnvRestore::set(
        "CONTROL_PLANE_WORKSPACE_MOUNT_PATH",
        workspace.to_str().unwrap(),
    );
    let input = json!({
        "toolName": "Read",
        "cwd": workspace,
        "toolArgs": {
            "file_path": temp_dir.path().join("workspace").join("secret-link")
        }
    })
    .to_string();

    let output = handle(&input).unwrap();
    let value: Value = serde_json::from_str(&output).unwrap();

    assert_eq!(value["permissionDecision"], "deny");
    assert!(
        value["permissionDecisionReason"]
            .as_str()
            .unwrap()
            .contains("copying from the Exec Pod would not preserve path semantics")
    );
}

#[cfg(unix)]
#[test]
fn denies_write_tool_when_workspace_parent_symlink_points_outside() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let workspace = temp_dir.path().join("workspace");
    let outside = temp_dir.path().join("outside");
    fs::create_dir_all(&workspace).unwrap();
    fs::create_dir_all(&outside).unwrap();
    std::os::unix::fs::symlink(&outside, workspace.join("outside-link")).unwrap();

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _workspace = EnvRestore::set(
        "CONTROL_PLANE_WORKSPACE_MOUNT_PATH",
        workspace.to_str().unwrap(),
    );
    let input = json!({
        "toolName": "Write",
        "cwd": workspace,
        "toolArgs": {
            "file_path": temp_dir.path().join("workspace").join("outside-link").join("new.txt"),
            "content": "outside\n"
        }
    })
    .to_string();

    let output = handle(&input).unwrap();
    let value: Value = serde_json::from_str(&output).unwrap();

    assert_eq!(value["permissionDecision"], "deny");
    assert!(
        value["permissionDecisionReason"]
            .as_str()
            .unwrap()
            .contains("copying from the Exec Pod would not preserve path semantics")
    );
}

#[cfg(unix)]
#[test]
fn passes_read_tool_through_when_workspace_symlink_stays_inside() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let workspace = temp_dir.path().join("workspace");
    let target_dir = workspace.join("target");
    fs::create_dir_all(&target_dir).unwrap();
    fs::write(target_dir.join("shared.txt"), "shared\n").unwrap();
    std::os::unix::fs::symlink(target_dir.join("shared.txt"), workspace.join("shared-link"))
        .unwrap();

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _workspace = EnvRestore::set(
        "CONTROL_PLANE_WORKSPACE_MOUNT_PATH",
        workspace.to_str().unwrap(),
    );
    let input = json!({
        "toolName": "Read",
        "cwd": workspace,
        "toolArgs": {
            "file_path": temp_dir.path().join("workspace").join("shared-link")
        }
    })
    .to_string();

    assert!(handle(&input).is_none());
}

#[cfg(unix)]
#[test]
fn denies_read_tool_when_workspace_symlink_then_parent_escapes() {
    let _env_lock = lock_env();
    let temp_dir = TempDir::new().unwrap();
    let workspace = temp_dir.path().join("workspace");
    let link_parent = workspace.join("a").join("b");
    fs::create_dir_all(&link_parent).unwrap();
    std::os::unix::fs::symlink(&workspace, link_parent.join("link")).unwrap();

    let _fast_exec = EnvRestore::set("CONTROL_PLANE_FAST_EXECUTION_ENABLED", "1");
    let _workspace = EnvRestore::set(
        "CONTROL_PLANE_WORKSPACE_MOUNT_PATH",
        workspace.to_str().unwrap(),
    );
    let input = json!({
        "toolName": "Read",
        "cwd": workspace,
        "toolArgs": {
            "file_path": temp_dir
                .path()
                .join("workspace")
                .join("a")
                .join("b")
                .join("link")
                .join("..")
                .join("..")
                .join("etc")
                .join("passwd")
        }
    })
    .to_string();

    let output = handle(&input).unwrap();
    let value: Value = serde_json::from_str(&output).unwrap();

    assert_eq!(value["permissionDecision"], "deny");
    assert!(
        value["permissionDecisionReason"]
            .as_str()
            .unwrap()
            .contains("copying from the Exec Pod would not preserve path semantics")
    );
}
