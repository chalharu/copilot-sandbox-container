#[cfg(unix)]
use nix::unistd::{Gid, Uid, chdir, chroot, setgid, setuid};
use serde::{Deserialize, Serialize};
use std::env;
use std::ffi::OsString;
use std::io;
#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::AsyncWriteExt;
use tokio::process::Command as TokioCommand;
use tonic::{Code, Status};

use crate::paths::{ResolvedCwd, nested_absolute_path};
use crate::{
    CHROOT_EXEC_POLICY_LIBRARY_PATH, CHROOT_EXEC_POLICY_RULES_PATH, DEFAULT_EXEC_PATH, DynError,
    with_context,
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExecResult {
    pub stdout: String,
    pub stderr: String,
    #[serde(rename = "exitCode")]
    pub exit_code: i32,
}

pub(crate) fn run_in_chroot(
    chroot_root: &Path,
    program: &Path,
    args: &[OsString],
    envs: &[(OsString, OsString)],
) -> Result<(), DynError> {
    let mut command = std::process::Command::new(program);
    command.args(args);
    for (key, value) in envs {
        command.env(key, value);
    }
    command.stdin(Stdio::null());
    command.stdout(Stdio::inherit());
    command.stderr(Stdio::inherit());
    configure_chroot_command(&mut command, chroot_root, Path::new("/"), None, None).map_err(
        |error| {
            format!(
                "failed to configure chroot command {} in {}: {error}",
                program.display(),
                chroot_root.display()
            )
        },
    )?;
    let status = with_context(command.status(), || {
        format!(
            "failed to execute {} inside chroot {}",
            program.display(),
            chroot_root.display()
        )
    })?;
    if status.success() {
        Ok(())
    } else {
        Err(format!(
            "command {} failed in chroot {} with status {status}",
            program.display(),
            chroot_root.display()
        )
        .into())
    }
}
pub(crate) fn resolve_shell(chroot_root: Option<&Path>) -> Option<PathBuf> {
    let candidates = ["/bin/bash", "/usr/bin/bash", "/bin/sh", "/usr/bin/sh"];
    candidates.iter().find_map(|candidate| {
        let absolute = Path::new(candidate);
        if let Some(chroot_root) = chroot_root {
            nested_absolute_path(chroot_root, absolute)
                .ok()
                .filter(|path| path.is_file())
                .map(|_| absolute.to_path_buf())
        } else {
            absolute.is_file().then(|| absolute.to_path_buf())
        }
    })
}

pub(crate) fn managed_exec_path(runtime_path: Option<OsString>) -> OsString {
    match runtime_path {
        Some(path) if !path.is_empty() => path,
        _ => OsString::from(DEFAULT_EXEC_PATH),
    }
}

pub(crate) fn managed_shell_environment(
    remote_home: &Path,
    chrooted: bool,
) -> Vec<(&'static str, OsString)> {
    let mut env = vec![
        ("PATH", managed_exec_path(env::var_os("PATH"))),
        ("HOME", remote_home.as_os_str().to_os_string()),
        (
            "GIT_CONFIG_GLOBAL",
            remote_home.join(".gitconfig").into_os_string(),
        ),
    ];
    for key in ["CONTROL_PLANE_K8S_NAMESPACE", "CONTROL_PLANE_JOB_NAMESPACE"] {
        if let Some(value) = env::var_os(key) {
            env.push((key, value));
        }
    }
    if chrooted {
        env.push((
            "LD_PRELOAD",
            OsString::from(CHROOT_EXEC_POLICY_LIBRARY_PATH),
        ));
        env.push((
            "CONTROL_PLANE_EXEC_POLICY_RULES_FILE",
            OsString::from(CHROOT_EXEC_POLICY_RULES_PATH),
        ));
    }
    env
}

pub(crate) fn stdout_with_command_line(command: &str, stdout: &[u8]) -> String {
    let mut rendered = String::from("$ ");
    rendered.push_str(command);
    if !command.ends_with('\n') {
        rendered.push('\n');
    }
    rendered.push_str(&String::from_utf8_lossy(stdout));
    rendered
}

pub(crate) async fn run_shell_command(
    command: &str,
    cwd: &ResolvedCwd,
    exec_timeout: Duration,
    run_as_uid: u32,
    run_as_gid: u32,
    chroot_root: Option<&Path>,
    remote_home: &Path,
) -> Result<ExecResult, Status> {
    let shell = resolve_shell(chroot_root).ok_or_else(|| {
        Status::failed_precondition("no supported shell found (tried bash and sh variants)")
    })?;
    let mut process = TokioCommand::new(shell);
    process
        .arg("-lc")
        .arg(command)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for (key, value) in managed_shell_environment(remote_home, chroot_root.is_some()) {
        process.env(key, value);
    }
    process.kill_on_drop(true);
    configure_command_identity(
        &mut process,
        run_as_uid,
        run_as_gid,
        chroot_root,
        &cwd.host,
        &cwd.logical,
    )
    .map_err(|error| Status::new(Code::Internal, error.to_string()))?;
    let output = tokio::time::timeout(exec_timeout, process.output())
        .await
        .map_err(|_| {
            Status::deadline_exceeded(format!(
                "command exceeded execution timeout of {} seconds",
                exec_timeout.as_secs()
            ))
        })?
        .map_err(|error| Status::new(Code::Internal, error.to_string()))?;

    Ok(ExecResult {
        stdout: stdout_with_command_line(command, &output.stdout),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        exit_code: exit_code_from_status(output.status),
    })
}

fn post_tool_use_hook_path(remote_home: &Path) -> PathBuf {
    remote_home.join(".copilot/hooks/postToolUse/main")
}

pub(crate) async fn run_post_tool_use_hook(
    raw_input: &str,
    cwd: &ResolvedCwd,
    exec_timeout: Duration,
    run_as_uid: u32,
    run_as_gid: u32,
    chroot_root: Option<&Path>,
    remote_home: &Path,
) -> Result<ExecResult, Status> {
    let hook_path = post_tool_use_hook_path(remote_home);
    let mut process = TokioCommand::new(&hook_path);
    process
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for (key, value) in managed_shell_environment(remote_home, chroot_root.is_some()) {
        process.env(key, value);
    }
    process.env("CONTROL_PLANE_POST_TOOL_USE_FORWARD_ACTIVE", "1");
    process.kill_on_drop(true);
    configure_command_identity(
        &mut process,
        run_as_uid,
        run_as_gid,
        chroot_root,
        &cwd.host,
        &cwd.logical,
    )
    .map_err(|error| Status::new(Code::Internal, error.to_string()))?;
    let mut child = process
        .spawn()
        .map_err(|error| Status::new(Code::Internal, error.to_string()))?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(raw_input.as_bytes())
            .await
            .map_err(|error| Status::new(Code::Internal, error.to_string()))?;
    }
    let output = tokio::time::timeout(exec_timeout, child.wait_with_output())
        .await
        .map_err(|_| {
            Status::deadline_exceeded(format!(
                "postToolUse hook exceeded execution timeout of {} seconds",
                exec_timeout.as_secs()
            ))
        })?
        .map_err(|error| Status::new(Code::Internal, error.to_string()))?;

    Ok(ExecResult {
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        exit_code: exit_code_from_status(output.status),
    })
}

#[cfg(unix)]
fn configure_command_identity(
    process: &mut TokioCommand,
    run_as_uid: u32,
    run_as_gid: u32,
    chroot_root: Option<&Path>,
    host_cwd: &Path,
    logical_cwd: &Path,
) -> io::Result<()> {
    if let Some(chroot_root) = chroot_root {
        configure_chroot_command(
            process.as_std_mut(),
            chroot_root,
            logical_cwd,
            Some(run_as_uid),
            Some(run_as_gid),
        )?;
    } else {
        process.current_dir(host_cwd);
        process.uid(run_as_uid);
        process.gid(run_as_gid);
    }
    Ok(())
}

#[cfg(unix)]
fn configure_chroot_command(
    process: &mut std::process::Command,
    chroot_root: &Path,
    cwd: &Path,
    run_as_uid: Option<u32>,
    run_as_gid: Option<u32>,
) -> io::Result<()> {
    let chroot_root = chroot_root.to_path_buf();
    let cwd = cwd.to_path_buf();
    unsafe {
        process.pre_exec(move || {
            chroot(&chroot_root).map_err(io::Error::other)?;
            chdir(&cwd).map_err(io::Error::other)?;
            if let Some(run_as_gid) = run_as_gid {
                setgid(Gid::from_raw(run_as_gid)).map_err(io::Error::other)?;
            }
            if let Some(run_as_uid) = run_as_uid {
                setuid(Uid::from_raw(run_as_uid)).map_err(io::Error::other)?;
            }
            Ok(())
        });
    }
    Ok(())
}

#[cfg(not(unix))]
fn configure_command_identity(
    _process: &mut TokioCommand,
    _run_as_uid: u32,
    _run_as_gid: u32,
    _chroot_root: Option<&Path>,
    _host_cwd: &Path,
    _logical_cwd: &Path,
) -> io::Result<()> {
    Ok(())
}

#[cfg(unix)]
fn exit_code_from_status(status: std::process::ExitStatus) -> i32 {
    use std::os::unix::process::ExitStatusExt;

    status
        .code()
        .or_else(|| status.signal().map(|signal| 128 + signal))
        .unwrap_or(1)
}

#[cfg(not(unix))]
fn exit_code_from_status(status: std::process::ExitStatus) -> i32 {
    status.code().unwrap_or(1)
}

#[cfg(test)]
mod tests {
    use super::{managed_exec_path, managed_shell_environment, stdout_with_command_line};
    use crate::test_support::{ScopedEnvVar, env_lock};
    use crate::{
        CHROOT_EXEC_POLICY_LIBRARY_PATH, CHROOT_EXEC_POLICY_RULES_PATH, DEFAULT_EXEC_PATH,
    };
    use std::ffi::OsString;
    use std::path::Path;

    #[test]
    fn managed_shell_environment_enables_exec_policy_for_chroot() {
        let _env_lock = env_lock().lock().unwrap();
        let _path = ScopedEnvVar::set("PATH", Some("/runtime/bin:/usr/bin"));
        let env = managed_shell_environment(Path::new("/root"), true);
        assert!(env.contains(&("PATH", OsString::from("/runtime/bin:/usr/bin"))));
        assert!(env.contains(&("HOME", OsString::from("/root"))));
        assert!(env.contains(&("GIT_CONFIG_GLOBAL", OsString::from("/root/.gitconfig"))));
        assert!(env.contains(&(
            "LD_PRELOAD",
            OsString::from(CHROOT_EXEC_POLICY_LIBRARY_PATH),
        )));
        assert!(env.contains(&(
            "CONTROL_PLANE_EXEC_POLICY_RULES_FILE",
            OsString::from(CHROOT_EXEC_POLICY_RULES_PATH),
        )));
    }

    #[test]
    fn managed_shell_environment_skips_exec_policy_without_chroot() {
        let _env_lock = env_lock().lock().unwrap();
        let _path = ScopedEnvVar::set("PATH", Some("/tooling/bin:/usr/bin"));
        let env = managed_shell_environment(Path::new("/root"), false);
        assert!(env.contains(&("PATH", OsString::from("/tooling/bin:/usr/bin"))));
        assert!(env.contains(&("HOME", OsString::from("/root"))));
        assert!(env.contains(&("GIT_CONFIG_GLOBAL", OsString::from("/root/.gitconfig"))));
        assert!(!env.iter().any(|(key, _)| *key == "LD_PRELOAD"));
        assert!(
            !env.iter()
                .any(|(key, _)| *key == "CONTROL_PLANE_EXEC_POLICY_RULES_FILE")
        );
    }

    #[test]
    fn managed_exec_path_preserves_runtime_path() {
        assert_eq!(
            managed_exec_path(Some(OsString::from("/venv/bin:/usr/bin"))),
            OsString::from("/venv/bin:/usr/bin")
        );
    }

    #[test]
    fn managed_exec_path_falls_back_without_runtime_path() {
        assert_eq!(managed_exec_path(None), OsString::from(DEFAULT_EXEC_PATH));
        assert_eq!(
            managed_exec_path(Some(OsString::new())),
            OsString::from(DEFAULT_EXEC_PATH)
        );
    }

    #[test]
    fn managed_shell_environment_falls_back_to_default_path_without_runtime_path() {
        let _env_lock = env_lock().lock().unwrap();
        let _path = ScopedEnvVar::set("PATH", None);
        let env = managed_shell_environment(Path::new("/root"), false);
        assert!(env.contains(&("PATH", OsString::from(DEFAULT_EXEC_PATH))));
    }

    #[test]
    fn stdout_with_command_line_prefixes_command_output() {
        assert_eq!(
            stdout_with_command_line("printf 'hello\\n'", b"hello\n"),
            "$ printf 'hello\\n'\nhello\n"
        );
    }
}
