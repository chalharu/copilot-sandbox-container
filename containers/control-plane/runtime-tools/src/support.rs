use std::env;
use std::fs;
use std::io::{self, Read};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Output;

pub const DEFAULT_SESSION_EXEC_BIN: &str = "/usr/local/bin/control-plane-session-exec";

pub fn read_stdin_string() -> io::Result<String> {
    let mut buffer = String::new();
    io::stdin().read_to_string(&mut buffer)?;
    Ok(buffer)
}

pub fn current_directory() -> PathBuf {
    env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

pub fn absolute_path(path: &Path) -> io::Result<PathBuf> {
    if path.is_absolute() {
        Ok(path.to_path_buf())
    } else {
        env::current_dir().map(|cwd| cwd.join(path))
    }
}

pub fn parent_process_id() -> Option<i64> {
    let ppid = unsafe { libc::getppid() };
    if ppid > 0 {
        Some(i64::from(ppid))
    } else {
        None
    }
}

pub fn output_message(output: &Output, fallback: &str) -> String {
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();

    if !stderr.is_empty() {
        stderr
    } else if !stdout.is_empty() {
        stdout
    } else {
        fallback.to_string()
    }
}

pub fn ensure_command(command_name: &str) -> io::Result<()> {
    let Some(path) = env::var_os("PATH") else {
        return not_found(command_name);
    };

    if env::split_paths(&path)
        .any(|directory| directory.join(command_name).is_file())
    {
        Ok(())
    } else {
        not_found(command_name)
    }
}

fn not_found(command_name: &str) -> io::Result<()> {
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        format!("{command_name} is required"),
    ))
}

pub fn set_mode(path: &Path, mode: u32) -> Result<(), String> {
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
        .map_err(|error| format!("failed to set permissions on {}: {error}", path.display()))
}

pub fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}
