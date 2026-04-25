use crate::error::{ToolError, ToolResult};

use super::COMMAND_NAME;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum CommandArgs {
    Prepare {
        session_key: String,
        refresh: bool,
    },
    Proxy {
        session_key: String,
        cwd: String,
        command_base64: String,
    },
    Cleanup {
        session_key: String,
    },
}

pub(super) fn parse_args(args: &[String]) -> ToolResult<CommandArgs> {
    let Some(subcommand) = args.first() else {
        return Err(ToolError::new(64, COMMAND_NAME, "missing subcommand"));
    };

    let mut session_key = String::new();
    let mut refresh = false;
    let mut cwd = String::new();
    let mut command_base64 = String::new();
    let mut index = 1usize;
    while index < args.len() {
        match args[index].as_str() {
            "--session-key" => {
                let value = args.get(index + 1).ok_or_else(|| {
                    ToolError::new(64, COMMAND_NAME, "--session-key requires a value")
                })?;
                session_key = value.clone();
                index += 2;
            }
            "--refresh" => {
                refresh = true;
                index += 1;
            }
            "--cwd" => {
                let value = args
                    .get(index + 1)
                    .ok_or_else(|| ToolError::new(64, COMMAND_NAME, "--cwd requires a value"))?;
                cwd = value.clone();
                index += 2;
            }
            "--command-base64" => {
                let value = args.get(index + 1).ok_or_else(|| {
                    ToolError::new(64, COMMAND_NAME, "--command-base64 requires a value")
                })?;
                command_base64 = value.clone();
                index += 2;
            }
            other => {
                return Err(ToolError::new(
                    64,
                    COMMAND_NAME,
                    format!("unknown option: {other}"),
                ));
            }
        }
    }

    if session_key.is_empty() {
        return Err(ToolError::new(
            64,
            COMMAND_NAME,
            "--session-key is required",
        ));
    }

    match subcommand.as_str() {
        "prepare" => Ok(CommandArgs::Prepare {
            session_key,
            refresh,
        }),
        "proxy" => {
            if cwd.is_empty() {
                return Err(ToolError::new(
                    64,
                    COMMAND_NAME,
                    "--cwd is required for proxy",
                ));
            }
            if command_base64.is_empty() {
                return Err(ToolError::new(
                    64,
                    COMMAND_NAME,
                    "--command-base64 is required for proxy",
                ));
            }
            Ok(CommandArgs::Proxy {
                session_key,
                cwd,
                command_base64,
            })
        }
        "cleanup" => Ok(CommandArgs::Cleanup { session_key }),
        other => Err(ToolError::new(
            64,
            COMMAND_NAME,
            format!("unknown subcommand: {other}"),
        )),
    }
}

pub(super) fn print_usage() {
    println!(
        "Usage:\n  control-plane-session-exec prepare --session-key KEY [--refresh]\n  control-plane-session-exec proxy --session-key KEY --cwd PATH --command-base64 BASE64\n  control-plane-session-exec cleanup --session-key KEY"
    );
}
