use std::fs;
use std::os::unix::fs::PermissionsExt;

use crate::config::ServerConfig;
use crate::paths::nested_absolute_path;
use crate::{CHROOT_GIT_HOOKS_DIR, DynError};
use std::path::Path;

pub(crate) fn sync_git_hooks_into_chroot(config: &ServerConfig) -> Result<(), DynError> {
    let Some(chroot_root) = config.chroot_root.as_deref() else {
        return Ok(());
    };
    let Some(git_hooks_source) = config.git_hooks_source.as_deref() else {
        return Ok(());
    };

    let target = nested_absolute_path(chroot_root, Path::new(CHROOT_GIT_HOOKS_DIR))?;
    if target.exists() {
        fs::remove_dir_all(&target)?;
    }
    copy_directory_recursive(git_hooks_source, &target)?;
    set_directory_mode_recursive(&target, 0o755, 0o644)?;
    for hook_name in ["pre-commit", "pre-push"] {
        let hook_path = target.join(hook_name);
        if hook_path.is_file() {
            fs::set_permissions(hook_path, fs::Permissions::from_mode(0o755))?;
        }
    }
    Ok(())
}

fn copy_directory_recursive(source: &Path, target: &Path) -> Result<(), DynError> {
    fs::create_dir_all(target)?;
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let source_path = entry.path();
        let target_path = target.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            copy_directory_recursive(&source_path, &target_path)?;
        } else {
            fs::copy(&source_path, &target_path)?;
        }
    }
    Ok(())
}

fn set_directory_mode_recursive(
    path: &Path,
    directory_mode: u32,
    file_mode: u32,
) -> Result<(), DynError> {
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let entry_path = entry.path();
        if entry.file_type()?.is_dir() {
            fs::set_permissions(&entry_path, fs::Permissions::from_mode(directory_mode))?;
            set_directory_mode_recursive(&entry_path, directory_mode, file_mode)?;
        } else {
            fs::set_permissions(&entry_path, fs::Permissions::from_mode(file_mode))?;
        }
    }
    fs::set_permissions(path, fs::Permissions::from_mode(directory_mode))?;
    Ok(())
}
