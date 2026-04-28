use std::env;
use std::fs;
use std::io;
use std::path::{Component, Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedCwd {
    pub(crate) host: PathBuf,
    pub(crate) logical: PathBuf,
}
pub(crate) fn canonicalize_absolute_path(
    path: &Path,
    variable_name: &str,
) -> Result<PathBuf, String> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        env::current_dir()
            .map_err(|error| format!("failed to determine current directory: {error}"))?
            .join(path)
    };
    fs::canonicalize(&absolute).map_err(|error| {
        format!(
            "failed to resolve {variable_name} {}: {error}",
            absolute.display()
        )
    })
}

pub(crate) fn normalize_absolute_path(path: &Path, variable_name: &str) -> Result<PathBuf, String> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        env::current_dir()
            .map_err(|error| format!("failed to determine current directory: {error}"))?
            .join(path)
    };
    let normalized = normalize_path(&absolute);
    if normalized.is_absolute() {
        Ok(normalized)
    } else {
        Err(format!(
            "{variable_name} must resolve to an absolute path: {}",
            path.display()
        ))
    }
}

pub(crate) fn resolve_cwd(
    workspace_root: &Path,
    logical_workspace_root: &Path,
    raw_cwd: &str,
) -> Result<ResolvedCwd, String> {
    let logical = normalize_logical_cwd(logical_workspace_root, raw_cwd)?;
    let host = host_path_for_cwd(workspace_root, logical_workspace_root, &logical)?;
    let resolved_host = fs::canonicalize(&host)
        .map_err(|error| format!("failed to resolve cwd {}: {error}", host.display()))?;
    if resolved_host == workspace_root || resolved_host.starts_with(workspace_root) {
        Ok(ResolvedCwd {
            host: resolved_host,
            logical,
        })
    } else {
        Err(format!(
            "cwd must stay within {}: {}",
            workspace_root.display(),
            resolved_host.display()
        ))
    }
}

fn normalize_logical_cwd(workspace_root: &Path, raw_cwd: &str) -> Result<PathBuf, String> {
    let candidate = if raw_cwd.trim().is_empty() {
        workspace_root.to_path_buf()
    } else {
        let raw_path = Path::new(raw_cwd);
        if raw_path.is_absolute() {
            normalize_path(raw_path)
        } else {
            normalize_path(&workspace_root.join(raw_path))
        }
    };
    if candidate == workspace_root || candidate.starts_with(workspace_root) {
        Ok(candidate)
    } else {
        Err(format!(
            "cwd must stay within {}: {}",
            workspace_root.display(),
            candidate.display()
        ))
    }
}

fn host_path_for_cwd(
    workspace_root: &Path,
    logical_workspace_root: &Path,
    logical_cwd: &Path,
) -> Result<PathBuf, String> {
    let relative = logical_cwd
        .strip_prefix(logical_workspace_root)
        .map_err(|_| {
            format!(
                "cwd must stay within {}: {}",
                logical_workspace_root.display(),
                logical_cwd.display()
            )
        })?;
    Ok(workspace_root.join(relative))
}

pub(crate) fn host_path_for_logical(
    chroot_root: &Path,
    logical_workspace_root: &Path,
) -> Result<PathBuf, String> {
    nested_absolute_path(chroot_root, logical_workspace_root)
        .map_err(|error| format!("failed to derive chroot workspace root: {error}"))
}

pub(crate) fn nested_absolute_path(root: &Path, absolute_path: &Path) -> io::Result<PathBuf> {
    let suffix = strip_leading_slash(absolute_path);
    Ok(root.join(suffix))
}

pub(crate) fn strip_leading_slash(path: &Path) -> PathBuf {
    path.components()
        .filter_map(|component| match component {
            Component::Normal(value) => Some(value.to_os_string()),
            Component::CurDir => None,
            Component::ParentDir => Some(component.as_os_str().to_os_string()),
            Component::RootDir | Component::Prefix(_) => None,
        })
        .collect()
}

pub(crate) fn normalize_path(path: &Path) -> PathBuf {
    let mut parts = Vec::new();
    let mut absolute = false;

    for component in path.components() {
        match component {
            Component::RootDir => {
                absolute = true;
                parts.clear();
            }
            Component::CurDir => {}
            Component::ParentDir => {
                if !parts.is_empty() {
                    parts.pop();
                }
            }
            Component::Normal(segment) => parts.push(segment.to_os_string()),
            Component::Prefix(prefix) => {
                absolute = true;
                parts.clear();
                parts.push(prefix.as_os_str().to_os_string());
            }
        }
    }

    let mut normalized = if absolute {
        PathBuf::from("/")
    } else {
        PathBuf::new()
    };
    for part in parts {
        normalized.push(part);
    }
    if normalized.as_os_str().is_empty() {
        PathBuf::from(".")
    } else {
        normalized
    }
}

#[cfg(test)]
mod tests {
    use super::{nested_absolute_path, normalize_path, resolve_cwd};
    use crate::CHROOT_KUBERNETES_SERVICE_ACCOUNT_DIR;
    use std::path::{Path, PathBuf};
    use tempfile::TempDir;

    #[test]
    fn normalize_path_removes_dot_segments() {
        assert_eq!(
            normalize_path(Path::new("/workspace/./nested/../repo")),
            PathBuf::from("/workspace/repo")
        );
    }

    #[test]
    fn resolve_cwd_rejects_paths_outside_workspace() {
        let error = resolve_cwd(
            Path::new("/workspace"),
            Path::new("/workspace"),
            "/workspace/../tmp",
        )
        .expect_err("path should be rejected");
        assert_eq!(error, "cwd must stay within /workspace: /tmp");
    }

    #[cfg(unix)]
    #[test]
    fn resolve_cwd_rejects_symlink_escapes() {
        use std::os::unix::fs::symlink;

        let temp_dir = TempDir::new().unwrap();
        let workspace = temp_dir.path().join("workspace");
        let outside = temp_dir.path().join("outside");
        std::fs::create_dir_all(&workspace).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        symlink(&outside, workspace.join("escape")).unwrap();
        let workspace = std::fs::canonicalize(&workspace).unwrap();

        let error = resolve_cwd(
            &workspace,
            &workspace,
            workspace.join("escape").to_str().unwrap(),
        )
        .unwrap_err();
        assert_eq!(
            error,
            format!(
                "cwd must stay within {}: {}",
                workspace.display(),
                outside.display()
            )
        );
    }

    #[test]
    fn chroot_kubernetes_service_account_path_uses_run_directory() {
        let tempdir = TempDir::new().unwrap();

        assert_eq!(
            nested_absolute_path(
                tempdir.path(),
                Path::new(CHROOT_KUBERNETES_SERVICE_ACCOUNT_DIR)
            )
            .unwrap(),
            tempdir
                .path()
                .join("run/secrets/kubernetes.io/serviceaccount")
        );
    }
}
