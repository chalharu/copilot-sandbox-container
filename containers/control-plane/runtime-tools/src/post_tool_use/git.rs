pub use crate::git::{get_git_dir, get_repo_root, list_dirty_files};

use std::path::Path;

pub fn to_relative_repo_path(repo_root: &Path, file_path: &Path) -> String {
    file_path
        .strip_prefix(repo_root)
        .unwrap_or(file_path)
        .to_string_lossy()
        .replace('\\', "/")
}
