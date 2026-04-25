use std::time::Duration;

use crate::error::{ToolError, ToolResult};

#[derive(Debug)]
pub(super) struct JobCommandArgs {
    pub(super) namespace: String,
    pub(super) job_name: String,
    pub(super) timeout: Duration,
}

#[derive(Debug)]
enum ParsedArg {
    Namespace(String),
    JobName(String),
    Timeout(Duration),
}

pub(super) fn parse_job_command_args(
    command_name: &'static str,
    args: &[String],
) -> ToolResult<JobCommandArgs> {
    let mut namespace = "default".to_string();
    let mut job_name = String::new();
    let mut timeout = Duration::from_secs(300);
    let mut index = 0usize;

    while index < args.len() {
        let (parsed_arg, next_index) = parse_arg(command_name, args, index)?;
        apply_parsed_arg(parsed_arg, &mut namespace, &mut job_name, &mut timeout);
        index = next_index;
    }

    if job_name.is_empty() {
        return Err(ToolError::new(64, command_name, "--job-name is required"));
    }
    validate_namespace(command_name, &namespace)?;
    validate_job_name(command_name, &job_name)?;

    Ok(JobCommandArgs {
        namespace,
        job_name,
        timeout,
    })
}

pub(super) fn print_usage(command_name: &str) {
    match command_name {
        "k8s-job-wait" => {
            println!("Usage:\n  k8s-job-wait --namespace NAME --job-name NAME [--timeout 300s]")
        }
        "k8s-job-pod" => println!("Usage:\n  k8s-job-pod --namespace NAME --job-name NAME"),
        "k8s-job-logs" => println!("Usage:\n  k8s-job-logs --namespace NAME --job-name NAME"),
        _ => {}
    }
}

fn parse_arg(
    command_name: &'static str,
    args: &[String],
    index: usize,
) -> ToolResult<(ParsedArg, usize)> {
    match args[index].as_str() {
        "--namespace" => Ok((
            ParsedArg::Namespace(require_value(command_name, args, index, "--namespace")?.clone()),
            index + 2,
        )),
        "--job-name" => Ok((
            ParsedArg::JobName(require_value(command_name, args, index, "--job-name")?.clone()),
            index + 2,
        )),
        "--timeout" => {
            let value = require_value(command_name, args, index, "--timeout")?;
            Ok((
                ParsedArg::Timeout(
                    parse_timeout_duration(value)
                        .map_err(|message| ToolError::new(64, command_name, message))?,
                ),
                index + 2,
            ))
        }
        other => Err(ToolError::new(
            64,
            command_name,
            format!("unknown option: {other}"),
        )),
    }
}

fn apply_parsed_arg(
    parsed_arg: ParsedArg,
    namespace: &mut String,
    job_name: &mut String,
    timeout: &mut Duration,
) {
    match parsed_arg {
        ParsedArg::Namespace(value) => *namespace = value,
        ParsedArg::JobName(value) => *job_name = value,
        ParsedArg::Timeout(value) => *timeout = value,
    }
}

fn require_value<'a>(
    command_name: &'static str,
    args: &'a [String],
    index: usize,
    flag: &str,
) -> ToolResult<&'a String> {
    args.get(index + 1)
        .ok_or_else(|| ToolError::new(64, command_name, format!("{flag} requires a value")))
}

fn parse_timeout_duration(raw_value: &str) -> Result<Duration, String> {
    if raw_value.is_empty() {
        return Err("--timeout requires a value".to_string());
    }

    let split_at = raw_value
        .find(|character: char| !character.is_ascii_digit())
        .unwrap_or(raw_value.len());
    let (digits, suffix) = raw_value.split_at(split_at);
    if digits.is_empty() {
        return Err(format!("invalid timeout value: {raw_value}"));
    }

    let amount: u64 = digits
        .parse()
        .map_err(|_| format!("invalid timeout value: {raw_value}"))?;
    let seconds = match suffix {
        "" | "s" => amount,
        "m" => amount.saturating_mul(60),
        "h" => amount.saturating_mul(60 * 60),
        _ => return Err(format!("invalid timeout value: {raw_value}")),
    };
    Ok(Duration::from_secs(seconds))
}

fn validate_job_name(command_name: &'static str, job_name: &str) -> ToolResult<()> {
    if is_dns_subdomain(job_name) {
        Ok(())
    } else {
        Err(ToolError::new(
            64,
            command_name,
            format!("invalid Kubernetes job name: {job_name}"),
        ))
    }
}

fn validate_namespace(command_name: &'static str, namespace: &str) -> ToolResult<()> {
    if is_dns_label(namespace) {
        Ok(())
    } else {
        Err(ToolError::new(
            64,
            command_name,
            format!("invalid Kubernetes namespace: {namespace}"),
        ))
    }
}

fn is_dns_subdomain(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 253
        && value.bytes().all(|character| {
            character.is_ascii_lowercase()
                || character.is_ascii_digit()
                || matches!(character, b'.' | b'-')
        })
        && !value.starts_with(['.', '-'])
        && !value.ends_with(['.', '-'])
        && value.split('.').all(is_dns_label)
}

fn is_dns_label(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 63
        && value.bytes().all(|character| {
            character.is_ascii_lowercase() || character.is_ascii_digit() || character == b'-'
        })
        && !value.starts_with('-')
        && !value.ends_with('-')
}
