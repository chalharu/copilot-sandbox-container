use serde::Serialize;
use std::io::{self, Write};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ExecuteRequestLog<'a> {
    pub(crate) timestamp: u64,
    pub(crate) event: &'static str,
    pub(crate) request_id: u64,
    pub(crate) mode: &'static str,
    pub(crate) cwd: &'a str,
    pub(crate) command: &'a str,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ExecuteResponseLog<'a> {
    pub(crate) timestamp: u64,
    pub(crate) event: &'static str,
    pub(crate) request_id: u64,
    pub(crate) status: &'static str,
    pub(crate) mode: &'static str,
    pub(crate) cwd: &'a str,
    pub(crate) command: &'a str,
    pub(crate) exit_code: Option<i32>,
    pub(crate) stdout: Option<&'a str>,
    pub(crate) stderr: Option<&'a str>,
    pub(crate) grpc_code: Option<&'a str>,
    pub(crate) error: Option<&'a str>,
}

pub(crate) trait TrafficLogger: Send + Sync + std::fmt::Debug {
    fn log_line(&self, line: &str) -> Result<(), String>;
}

pub(crate) fn current_timestamp_ms() -> u64 {
    let elapsed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX)
}

pub(crate) fn format_log_line(timestamp_ms: u64, message: &str) -> String {
    format!("{timestamp_ms} control-plane-exec-api: {message}")
}

pub fn log_message(message: &str) {
    eprintln!("{}", format_log_line(current_timestamp_ms(), message));
}

#[derive(Debug, Default)]
pub(crate) struct StdoutTrafficLogger;

impl TrafficLogger for StdoutTrafficLogger {
    fn log_line(&self, line: &str) -> Result<(), String> {
        let stdout = io::stdout();
        let mut lock = stdout.lock();
        lock.write_all(line.as_bytes())
            .map_err(|error| format!("failed to write exec API traffic log: {error}"))?;
        lock.write_all(b"\n")
            .map_err(|error| format!("failed to write exec API traffic log newline: {error}"))?;
        lock.flush()
            .map_err(|error| format!("failed to flush exec API traffic log: {error}"))?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::format_log_line;

    #[test]
    fn format_log_line_prefixes_epoch_milliseconds() {
        assert_eq!(
            format_log_line(
                1_704_614_400_000,
                "listening on 127.0.0.1:7777 for /workspace"
            ),
            "1704614400000 control-plane-exec-api: listening on 127.0.0.1:7777 for /workspace"
        );
    }
}
