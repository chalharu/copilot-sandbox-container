use std::collections::HashSet;
use std::path::{Path, PathBuf};

use git2::{Repository, StatusOptions};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteInfo {
    pub name: String,
    pub url: String,
}

pub fn get_repo_root(cwd: &Path) -> PathBuf {
    discover_repository(cwd)
        .and_then(|repo| repo_root_from_repository(&repo))
        .unwrap_or_else(|| cwd.to_path_buf())
}

pub fn get_git_dir(repo_root: &Path) -> PathBuf {
    discover_repository(repo_root)
        .and_then(|repo| {
            repo.path()
                .canonicalize()
                .ok()
                .or_else(|| Some(repo.path().to_path_buf()))
        })
        .unwrap_or_else(|| repo_root.join(".git"))
}

pub fn list_dirty_files(repo_root: &Path) -> Result<Vec<PathBuf>, String> {
    let repo = Repository::discover(repo_root).map_err(|error| {
        format!(
            "failed to open git repository at {}: {error}",
            repo_root.display()
        )
    })?;
    let workdir = repo
        .workdir()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| repo_root.to_path_buf());
    let mut status_options = StatusOptions::new();
    status_options
        .include_untracked(true)
        .recurse_untracked_dirs(true)
        .include_ignored(false)
        .include_unmodified(false)
        .renames_head_to_index(true)
        .renames_index_to_workdir(true);
    let statuses = repo.statuses(Some(&mut status_options)).map_err(|error| {
        format!(
            "failed to read git status for {}: {error}",
            repo_root.display()
        )
    })?;

    let mut seen = HashSet::new();
    let mut files = Vec::new();
    for entry in statuses.iter() {
        let Some(relative_path) = entry.path() else {
            continue;
        };
        if !seen.insert(relative_path.to_string()) {
            continue;
        }
        let path = workdir.join(relative_path);
        if path.is_file() {
            files.push(path);
        }
    }
    Ok(files)
}

pub fn list_remotes(repo_root: &Path) -> Vec<RemoteInfo> {
    let Some(repo) = discover_repository(repo_root) else {
        return Vec::new();
    };
    let Ok(remote_names) = repo.remotes() else {
        return Vec::new();
    };

    let mut remotes = remote_names
        .iter()
        .flatten()
        .filter_map(|name| {
            let remote = repo.find_remote(name).ok()?;
            let url = remote.url()?.to_string();
            Some(RemoteInfo {
                name: name.to_string(),
                url,
            })
        })
        .collect::<Vec<_>>();
    remotes.sort_by(|left, right| left.name.cmp(&right.name).then(left.url.cmp(&right.url)));
    remotes
}

fn discover_repository(path: &Path) -> Option<Repository> {
    Repository::discover(path).ok()
}

fn repo_root_from_repository(repo: &Repository) -> Option<PathBuf> {
    repo.workdir()
        .map(normalize_path)
        .or_else(|| repo.path().parent().map(normalize_path))
}

fn normalize_path(path: &Path) -> PathBuf {
    path.components().collect()
}
