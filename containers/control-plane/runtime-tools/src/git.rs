use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

pub fn get_repo_root(cwd: &Path) -> PathBuf {
    let output = Command::new("git")
        .arg("rev-parse")
        .arg("--show-toplevel")
        .current_dir(cwd)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output();
    match output {
        Ok(output) if output.status.success() => parse_root_output(cwd, &output.stdout),
        _ => cwd.to_path_buf(),
    }
}

fn parse_root_output(cwd: &Path, stdout: &[u8]) -> PathBuf {
    let repo_root = String::from_utf8_lossy(stdout).trim().to_string();
    if repo_root.is_empty() {
        cwd.to_path_buf()
    } else {
        PathBuf::from(repo_root)
    }
}
