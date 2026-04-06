use std::env;

use crate::support::{DEFAULT_SESSION_EXEC_BIN, parent_process_id};

pub fn fast_execution_enabled() -> bool {
    matches!(
        env::var("CONTROL_PLANE_FAST_EXECUTION_ENABLED")
            .ok()
            .as_deref(),
        Some("1")
    )
}

pub fn session_exec_bin() -> String {
    env::var("CONTROL_PLANE_SESSION_EXEC_BIN")
        .unwrap_or_else(|_| DEFAULT_SESSION_EXEC_BIN.to_string())
}

pub fn session_key() -> String {
    env::var("CONTROL_PLANE_HOOK_SESSION_KEY")
        .ok()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| parent_process_id().unwrap_or(0).to_string())
}
