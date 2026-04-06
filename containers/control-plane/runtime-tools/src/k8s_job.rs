use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::error::{ToolError, ToolResult};
use crate::support::{ensure_command, output_message};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum JobWaitStatus {
    Completed,
    Failed,
    TimedOut,
}

#[derive(Debug)]
struct JobCommandArgs {
    namespace: String,
    job_name: String,
    timeout: Duration,
}

pub fn run_wait(args: &[String]) -> ToolResult<i32> {
    if args.len() == 1 && args[0] == "--help" {
        print_usage("k8s-job-wait");
        return Ok(0);
    }

    let parsed = parse_job_command_args("k8s-job-wait", args)?;
    require_kubectl("k8s-job-wait")?;
    match wait_for_job(&parsed.namespace, &parsed.job_name, parsed.timeout)
        .map_err(|message| ToolError::new(1, "k8s-job-wait", message))?
    {
        JobWaitStatus::Completed => Ok(0),
        JobWaitStatus::Failed => {
            eprintln!("k8s-job-wait: job {} failed", parsed.job_name);
            Ok(1)
        }
        JobWaitStatus::TimedOut => {
            eprintln!("k8s-job-wait: timed out waiting for job {}", parsed.job_name);
            Ok(124)
        }
    }
}

pub fn run_pod(args: &[String]) -> ToolResult<i32> {
    if args.len() == 1 && args[0] == "--help" {
        print_usage("k8s-job-pod");
        return Ok(0);
    }

    let parsed = parse_job_command_args("k8s-job-pod", args)?;
    require_kubectl("k8s-job-pod")?;
    let pod_name = resolve_job_pod(&parsed.namespace, &parsed.job_name)
        .map_err(|message| ToolError::new(1, "k8s-job-pod", message))?;
    println!("{pod_name}");
    Ok(0)
}

pub fn run_logs(args: &[String]) -> ToolResult<i32> {
    if args.len() == 1 && args[0] == "--help" {
        print_usage("k8s-job-logs");
        return Ok(0);
    }

    let parsed = parse_job_command_args("k8s-job-logs", args)?;
    require_kubectl("k8s-job-logs")?;
    stream_job_logs(&parsed.namespace, &parsed.job_name)
        .map_err(|message| ToolError::new(1, "k8s-job-logs", message))
}

fn require_kubectl(command_name: &'static str) -> ToolResult<()> {
    ensure_command("kubectl").map_err(|error| ToolError::new(64, command_name, error.to_string()))
}

fn parse_job_command_args(command_name: &'static str, args: &[String]) -> ToolResult<JobCommandArgs> {
    let mut namespace = "default".to_string();
    let mut job_name = String::new();
    let mut timeout = Duration::from_secs(300);
    let mut index = 0usize;

    while index < args.len() {
        index = parse_arg(
            command_name,
            args,
            index,
            &mut namespace,
            &mut job_name,
            &mut timeout,
        )?;
    }

    if job_name.is_empty() {
        return Err(ToolError::new(64, command_name, "--job-name is required"));
    }

    Ok(JobCommandArgs {
        namespace,
        job_name,
        timeout,
    })
}

fn parse_arg(
    command_name: &'static str,
    args: &[String],
    index: usize,
    namespace: &mut String,
    job_name: &mut String,
    timeout: &mut Duration,
) -> ToolResult<usize> {
    match args[index].as_str() {
        "--namespace" => {
            *namespace = require_value(command_name, args, index, "--namespace")?.clone();
            Ok(index + 2)
        }
        "--job-name" => {
            *job_name = require_value(command_name, args, index, "--job-name")?.clone();
            Ok(index + 2)
        }
        "--timeout" => {
            let value = require_value(command_name, args, index, "--timeout")?;
            *timeout = parse_timeout_duration(value)
                .map_err(|message| ToolError::new(64, command_name, message))?;
            Ok(index + 2)
        }
        other => Err(ToolError::new(
            64,
            command_name,
            format!("unknown option: {other}"),
        )),
    }
}

fn require_value<'a>(
    command_name: &'static str,
    args: &'a [String],
    index: usize,
    flag: &str,
) -> ToolResult<&'a String> {
    args.get(index + 1).ok_or_else(|| {
        ToolError::new(64, command_name, format!("{flag} requires a value"))
    })
}

fn print_usage(command_name: &str) {
    match command_name {
        "k8s-job-wait" => {
            println!("Usage:\n  k8s-job-wait --namespace NAME --job-name NAME [--timeout 300s]")
        }
        "k8s-job-pod" => println!("Usage:\n  k8s-job-pod --namespace NAME --job-name NAME"),
        "k8s-job-logs" => println!("Usage:\n  k8s-job-logs --namespace NAME --job-name NAME"),
        _ => {}
    }
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

fn wait_for_job(namespace: &str, job_name: &str, timeout: Duration) -> Result<JobWaitStatus, String> {
    let started = Instant::now();
    loop {
        let conditions = read_job_conditions(namespace, job_name)?;
        if has_condition(&conditions, "Complete=True") {
            return Ok(JobWaitStatus::Completed);
        }
        if has_condition(&conditions, "Failed=True") {
            return Ok(JobWaitStatus::Failed);
        }
        if started.elapsed() >= timeout {
            return Ok(JobWaitStatus::TimedOut);
        }
        std::thread::sleep(Duration::from_secs(1));
    }
}

fn read_job_conditions(namespace: &str, job_name: &str) -> Result<String, String> {
    let output = Command::new("kubectl")
        .arg("get")
        .arg("job")
        .arg(job_name)
        .arg("--namespace")
        .arg(namespace)
        .arg("-o")
        .arg(r#"jsonpath={range .status.conditions[*]}{.type}={.status}{"\n"}{end}"#)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .map_err(|error| format!("failed to run kubectl get job {job_name}: {error}"))?;
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

fn has_condition(conditions: &str, expected: &str) -> bool {
    conditions.lines().any(|line| line.trim() == expected)
}

fn resolve_job_pod(namespace: &str, job_name: &str) -> Result<String, String> {
    let output = Command::new("kubectl")
        .arg("get")
        .arg("pods")
        .arg("--namespace")
        .arg(namespace)
        .arg("--selector")
        .arg(format!("job-name={job_name}"))
        .arg("-o")
        .arg("jsonpath={.items[0].metadata.name}")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|error| format!("failed to run kubectl get pods for {job_name}: {error}"))?;

    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    } else {
        Err(output_message(&output, "failed to resolve job pod"))
    }
}

fn stream_job_logs(namespace: &str, job_name: &str) -> Result<i32, String> {
    let pod_name = resolve_job_pod(namespace, job_name)?;
    if pod_name.is_empty() {
        return Err(format!("could not resolve pod for job {job_name}"));
    }

    let status = Command::new("kubectl")
        .arg("logs")
        .arg("--namespace")
        .arg(namespace)
        .arg(&pod_name)
        .status()
        .map_err(|error| format!("failed to run kubectl logs for {pod_name}: {error}"))?;
    Ok(status.code().unwrap_or(1))
}

#[cfg(test)]
mod tests {
    use std::env;
    use std::time::Duration;

    use tempfile::TempDir;

    use crate::support::shell_quote;
    use crate::test_support::{EnvRestore, lock_env, write_executable};

    use super::{JobWaitStatus, resolve_job_pod, wait_for_job};

    #[test]
    fn detects_completion() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let kubectl_path = temp_dir.path().join("kubectl");
        let state_path = temp_dir.path().join("state");
        write_executable(
            &kubectl_path,
            &format!(
                "#!/usr/bin/env bash\nset -euo pipefail\ncount=0\nif [[ -f {} ]]; then count=$(cat {}); fi\ncount=$((count + 1))\nprintf '%s' \"$count\" > {}\nif [[ \"$count\" -ge 2 ]]; then printf 'Complete=True\\n'; fi\n",
                shell_quote(state_path.to_str().unwrap()),
                shell_quote(state_path.to_str().unwrap()),
                shell_quote(state_path.to_str().unwrap())
            ),
        );
        let path_value = format!(
            "{}:{}",
            temp_dir.path().display(),
            env::var("PATH").unwrap_or_default()
        );
        let _path = EnvRestore::set("PATH", &path_value);

        let status = wait_for_job("default", "demo", Duration::from_secs(3)).unwrap();
        assert_eq!(status, JobWaitStatus::Completed);
    }

    #[test]
    fn returns_first_pod_name() {
        let _env_lock = lock_env();
        let temp_dir = TempDir::new().unwrap();
        let kubectl_path = temp_dir.path().join("kubectl");
        write_executable(
            &kubectl_path,
            "#!/usr/bin/env bash\nset -euo pipefail\nprintf 'demo-pod'\n",
        );
        let path_value = format!(
            "{}:{}",
            temp_dir.path().display(),
            env::var("PATH").unwrap_or_default()
        );
        let _path = EnvRestore::set("PATH", &path_value);

        let pod_name = resolve_job_pod("default", "demo").unwrap();
        assert_eq!(pod_name, "demo-pod");
    }
}
