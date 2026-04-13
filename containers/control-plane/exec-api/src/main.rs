use base64::Engine as _;
use control_plane_exec_api::{
    DynError, check_health, execute_remote, load_server_config_from_env, log_message, serve,
};
use std::time::Duration;

fn usage() -> &'static str {
    "Usage:\n  control-plane-exec-api serve\n  control-plane-exec-api health --addr URL [--timeout-sec SECONDS]\n  control-plane-exec-api exec --addr URL --token TOKEN --cwd PATH --command-base64 BASE64 [--timeout-sec SECONDS]\n"
}

enum Command {
    Serve,
    Health {
        addr: String,
        timeout_sec: u64,
    },
    Exec {
        addr: String,
        token: String,
        cwd: String,
        command_base64: String,
        timeout_sec: u64,
    },
}

#[tokio::main(flavor = "multi_thread")]
async fn main() {
    if let Err(error) = run().await {
        log_message(&error.to_string());
        std::process::exit(1);
    }
}

async fn run() -> Result<(), DynError> {
    let command = parse_args(std::env::args().skip(1))?;
    match command {
        Command::Serve => {
            let config =
                load_server_config_from_env().map_err(|error| -> DynError { error.into() })?;
            serve(config).await?;
        }
        Command::Health { addr, timeout_sec } => {
            check_health(&addr, Duration::from_secs(timeout_sec)).await?;
        }
        Command::Exec {
            addr,
            token,
            cwd,
            command_base64,
            timeout_sec,
        } => {
            let command = String::from_utf8(
                base64::engine::general_purpose::STANDARD.decode(command_base64)?,
            )?;
            let result = execute_remote(
                &addr,
                Duration::from_secs(timeout_sec),
                &token,
                &cwd,
                &command,
            )
            .await?;
            serde_json::to_writer(std::io::stdout(), &result)?;
        }
    }
    Ok(())
}

fn parse_args(args: impl Iterator<Item = String>) -> Result<Command, DynError> {
    let arguments = args.collect::<Vec<_>>();
    let Some(subcommand) = arguments.first().map(String::as_str) else {
        return Err(usage().into());
    };

    match subcommand {
        "--help" | "-h" => Err(usage().into()),
        "serve" => {
            if arguments.len() != 1 {
                return Err(usage().into());
            }
            Ok(Command::Serve)
        }
        "health" => {
            let mut addr = String::new();
            let mut timeout_sec = 2;
            parse_named_options(&arguments[1..], |flag, value| match flag {
                "--addr" => {
                    addr = value.to_owned();
                    Ok(())
                }
                "--timeout-sec" => {
                    timeout_sec = value.parse()?;
                    Ok(())
                }
                _ => Err(format!("unknown option: {flag}").into()),
            })?;

            if addr.is_empty() {
                return Err(String::from("--addr is required for health").into());
            }

            Ok(Command::Health { addr, timeout_sec })
        }
        "exec" => {
            let mut addr = String::new();
            let mut token = String::new();
            let mut cwd = String::new();
            let mut command_base64 = String::new();
            let mut timeout_sec = 3600;
            parse_named_options(&arguments[1..], |flag, value| match flag {
                "--addr" => {
                    addr = value.to_owned();
                    Ok(())
                }
                "--token" => {
                    token = value.to_owned();
                    Ok(())
                }
                "--cwd" => {
                    cwd = value.to_owned();
                    Ok(())
                }
                "--command-base64" => {
                    command_base64 = value.to_owned();
                    Ok(())
                }
                "--timeout-sec" => {
                    timeout_sec = value.parse()?;
                    Ok(())
                }
                _ => Err(format!("unknown option: {flag}").into()),
            })?;

            if addr.is_empty() {
                return Err(String::from("--addr is required for exec").into());
            }
            if token.is_empty() {
                return Err(String::from("--token is required for exec").into());
            }
            if cwd.is_empty() {
                return Err(String::from("--cwd is required for exec").into());
            }
            if command_base64.is_empty() {
                return Err(String::from("--command-base64 is required for exec").into());
            }

            Ok(Command::Exec {
                addr,
                token,
                cwd,
                command_base64,
                timeout_sec,
            })
        }
        _ => Err(format!("unknown subcommand: {subcommand}\n{}", usage()).into()),
    }
}

fn parse_named_options<F>(arguments: &[String], mut assign: F) -> Result<(), DynError>
where
    F: FnMut(&str, &str) -> Result<(), DynError>,
{
    if !arguments.len().is_multiple_of(2) {
        return Err(usage().into());
    }

    let mut index = 0;
    while index < arguments.len() {
        let flag = &arguments[index];
        if !flag.starts_with("--") {
            return Err(format!("expected option flag, got: {flag}").into());
        }
        let value = &arguments[index + 1];
        assign(flag, value)?;
        index += 2;
    }

    Ok(())
}
