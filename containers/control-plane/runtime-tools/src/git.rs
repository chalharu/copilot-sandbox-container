use std::collections::HashSet;
use std::path::{Path, PathBuf};

use git2::{Repository, Status, StatusOptions};

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
    list_files_matching_status(repo_root, |_| true)
}

pub fn list_staged_files(repo_root: &Path) -> Result<Vec<PathBuf>, String> {
    list_files_matching_status(repo_root, |status| {
        status.intersects(
            Status::INDEX_NEW
                | Status::INDEX_MODIFIED
                | Status::INDEX_RENAMED
                | Status::INDEX_TYPECHANGE,
        )
    })
}

fn list_files_matching_status(
    repo_root: &Path,
    include_entry: impl Fn(Status) -> bool,
) -> Result<Vec<PathBuf>, String> {
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
        if !include_entry(entry.status()) {
            continue;
        }
        let Ok(relative_path) = entry.path() else {
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
        .filter_map(|name| {
            let name = name.ok().flatten()?;
            let remote = repo.find_remote(name).ok()?;
            let url = remote.url().ok()?.to_string();
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

#[cfg(test)]
mod tests {
    use super::{RemoteInfo, get_repo_root, list_dirty_files, list_remotes, list_staged_files};
    use git2::Repository;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn list_dirty_files_includes_untracked_files() {
        let temp_dir = tempdir().expect("create temp dir");
        let repo = Repository::init(temp_dir.path()).expect("init repo");
        let nested_dir = temp_dir.path().join("nested");
        let file_path = nested_dir.join("dirty.txt");

        fs::create_dir_all(&nested_dir).expect("create nested dir");
        fs::write(&file_path, "dirty").expect("write dirty file");

        let dirty_files = list_dirty_files(temp_dir.path()).expect("list dirty files");

        assert_eq!(get_repo_root(&nested_dir), temp_dir.path());
        assert!(repo.workdir().is_some());
        assert_eq!(dirty_files, vec![file_path]);
    }

    #[test]
    fn list_staged_files_excludes_unstaged_files() {
        let temp_dir = tempdir().expect("create temp dir");
        let repo = Repository::init(temp_dir.path()).expect("init repo");
        let staged_dir = temp_dir.path().join("packages/demo");
        let staged_file = staged_dir.join("index.ts");
        let unstaged_file = temp_dir.path().join("README.md");

        fs::create_dir_all(&staged_dir).expect("create staged dir");
        fs::write(&staged_file, "export const value = 1;\n").expect("write staged file");
        fs::write(&unstaged_file, "# dirty\n").expect("write unstaged file");
        let mut index = repo.index().expect("open index");
        index
            .add_path(std::path::Path::new("packages/demo/index.ts"))
            .expect("stage file");
        index.write().expect("write index");

        let staged_files = list_staged_files(temp_dir.path()).expect("list staged files");
        let dirty_files = list_dirty_files(temp_dir.path()).expect("list dirty files");

        assert_eq!(staged_files, vec![staged_file.clone()]);
        assert!(dirty_files.contains(&staged_file));
        assert!(dirty_files.contains(&unstaged_file));
    }

    #[test]
    fn list_remotes_returns_named_urls_in_sorted_order() {
        let temp_dir = tempdir().expect("create temp dir");
        let repo = Repository::init(temp_dir.path()).expect("init repo");
        repo.remote("upstream", "https://example.com/upstream.git")
            .expect("add upstream remote");
        repo.remote("origin", "https://example.com/origin.git")
            .expect("add origin remote");

        let remotes = list_remotes(temp_dir.path());

        assert_eq!(
            remotes,
            vec![
                RemoteInfo {
                    name: "origin".to_string(),
                    url: "https://example.com/origin.git".to_string(),
                },
                RemoteInfo {
                    name: "upstream".to_string(),
                    url: "https://example.com/upstream.git".to_string(),
                },
            ]
        );
    }
}
