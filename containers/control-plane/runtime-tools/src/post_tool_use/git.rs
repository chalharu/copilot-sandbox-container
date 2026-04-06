use std::collections::HashSet;
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

pub fn get_git_dir(repo_root: &Path) -> PathBuf {
    let output = Command::new("git")
        .arg("rev-parse")
        .arg("--git-dir")
        .current_dir(repo_root)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output();
    match output {
        Ok(output) if output.status.success() => parse_git_dir_output(repo_root, &output.stdout),
        _ => repo_root.join(".git"),
    }
}

fn parse_git_dir_output(repo_root: &Path, stdout: &[u8]) -> PathBuf {
    let git_dir = String::from_utf8_lossy(stdout).trim().to_string();
    if git_dir.is_empty() {
        repo_root.join(".git")
    } else {
        repo_root.join(git_dir).canonicalize().unwrap_or_else(|_| repo_root.join(".git"))
    }
}

pub fn list_dirty_files(repo_root: &Path) -> Result<Vec<PathBuf>, String> {
    let candidates = [
        list_git_paths(repo_root, ["diff", "--name-only", "-z", "--diff-filter=ACMRTUXB"].as_slice())?,
        list_git_paths(repo_root, ["diff", "--cached", "--name-only", "-z", "--diff-filter=ACMRTUXB"].as_slice())?,
        list_git_paths(repo_root, ["ls-files", "--others", "--exclude-standard", "-z"].as_slice())?,
    ]
    .concat();

    let mut seen = HashSet::new();
    let mut files = Vec::new();
    for relative_path in candidates {
        if seen.insert(relative_path.clone()) {
            let path = repo_root.join(relative_path);
            if path.is_file() {
                files.push(path);
            }
        }
    }
    Ok(files)
}

fn list_git_paths(repo_root: &Path, args: &[&str]) -> Result<Vec<String>, String> {
    let output = Command::new("git")
        .args(args)
        .current_dir(repo_root)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .map_err(|error| format!("failed to run git {}: {error}", args.join(" ")))?;

    if output.status.success() {
        Ok(split_nul_separated(&output.stdout))
    } else {
        Ok(Vec::new())
    }
}

fn split_nul_separated(output: &[u8]) -> Vec<String> {
    String::from_utf8_lossy(output)
        .split('\0')
        .map(str::trim)
        .filter(|item| !item.is_empty())
        .map(ToOwned::to_owned)
        .collect()
}

pub fn to_relative_repo_path(repo_root: &Path, file_path: &Path) -> String {
    file_path
        .strip_prefix(repo_root)
        .unwrap_or(file_path)
        .to_string_lossy()
        .replace('\\', "/")
}
