use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command as StdCommand, Stdio};

use crate::config::ServerConfig;
use crate::git_hooks::sync_git_hooks_into_chroot;
use crate::mounts::{ensure_runtime_dirs, mount_runtime_filesystems};
use crate::packages::{install_required_packages, run_startup_script};
use crate::paths::strip_leading_slash;
use crate::remote_home::sync_remote_home_config;
use crate::{
    CHROOT_EXEC_POLICY_LIBRARY_PATH, CHROOT_EXEC_POLICY_RULES_PATH, CHROOT_KUBECTL_PATH,
    CHROOT_POST_TOOL_USE_HOOKS_PATH, CHROOT_RUNTIME_TOOL_PATH, DynError, with_context,
};

pub(crate) fn prepare_server_environment(config: &ServerConfig) -> Result<(), DynError> {
    let Some(chroot_root) = config.chroot_root.as_deref() else {
        return Ok(());
    };

    with_context(fs::create_dir_all(chroot_root), || {
        format!("failed to create chroot root {}", chroot_root.display())
    })?;
    let needs_bootstrap = !bootstrap_marker_path(chroot_root).is_file();
    if needs_bootstrap {
        seed_chroot_root(chroot_root, config)?;
    }
    ensure_runtime_dirs(chroot_root, &config.remote_home).map_err(|error| {
        format!(
            "failed to prepare runtime directories under {}: {error}",
            chroot_root.display()
        )
    })?;
    mount_runtime_filesystems(chroot_root).map_err(|error| {
        format!(
            "failed to mount runtime filesystems under {}: {error}",
            chroot_root.display()
        )
    })?;
    if needs_bootstrap {
        install_required_packages(chroot_root).map_err(|error| {
            format!(
                "failed to install required packages in {}: {error}",
                chroot_root.display()
            )
        })?;
    }
    sync_git_hooks_into_chroot(config).map_err(|error| {
        format!(
            "failed to sync git hooks into {}: {error}",
            chroot_root.display()
        )
    })?;
    sync_remote_home_config(config).map_err(|error| {
        format!(
            "failed to sync remote home config into {}: {error}",
            chroot_root.display()
        )
    })?;
    if let Some(startup_script) = config.startup_script.as_deref() {
        run_startup_script(chroot_root, startup_script).map_err(|error| {
            format!(
                "failed to run startup script in {}: {error}",
                chroot_root.display()
            )
        })?;
    }
    if needs_bootstrap {
        let marker_path = bootstrap_marker_path(chroot_root);
        with_context(fs::write(&marker_path, b"ready\n"), || {
            format!("failed to write bootstrap marker {}", marker_path.display())
        })?;
    }
    Ok(())
}

fn bootstrap_marker_path(chroot_root: &Path) -> PathBuf {
    chroot_root.join(".control-plane-ready")
}

fn seed_chroot_root(chroot_root: &Path, config: &ServerConfig) -> Result<(), DynError> {
    with_context(fs::create_dir_all(chroot_root), || {
        format!("failed to create bootstrap root {}", chroot_root.display())
    })?;
    reset_incomplete_bootstrap_root(chroot_root, config).map_err(|error| {
        format!(
            "failed to reset incomplete execution rootfs under {}: {error}",
            chroot_root.display()
        )
    })?;
    copy_rootfs(chroot_root, config).map_err(|error| {
        format!(
            "failed to seed execution rootfs into {}: {error}",
            chroot_root.display()
        )
    })?;
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum BootstrapResetAction {
    Remove,
    ClearContents,
    KeepSubtree,
    Descend,
}

pub(crate) fn reset_incomplete_bootstrap_root(
    chroot_root: &Path,
    config: &ServerConfig,
) -> Result<(), DynError> {
    let preserve_subtrees = preserved_bootstrap_subtrees(config)
        .into_iter()
        .map(|path| strip_leading_slash(&path))
        .collect::<Vec<_>>();
    let clear_dirs = [PathBuf::from("tmp"), PathBuf::from("var/tmp")];
    reset_bootstrap_directory(chroot_root, Path::new(""), &preserve_subtrees, &clear_dirs)
}

fn preserved_bootstrap_subtrees(config: &ServerConfig) -> Vec<PathBuf> {
    vec![
        config.logical_workspace_root.clone(),
        config.remote_home.join(".config/gh"),
        config.remote_home.join(".ssh"),
        PathBuf::from(CHROOT_KUBECTL_PATH),
        PathBuf::from(CHROOT_RUNTIME_TOOL_PATH),
        PathBuf::from(CHROOT_EXEC_POLICY_LIBRARY_PATH),
        PathBuf::from(CHROOT_EXEC_POLICY_RULES_PATH),
        PathBuf::from(CHROOT_POST_TOOL_USE_HOOKS_PATH),
    ]
}

fn reset_bootstrap_directory(
    path: &Path,
    relative_path: &Path,
    preserve_subtrees: &[PathBuf],
    clear_dirs: &[PathBuf],
) -> Result<(), DynError> {
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let entry_name = entry.file_name();
        let entry_relative = if relative_path.as_os_str().is_empty() {
            PathBuf::from(entry_name)
        } else {
            relative_path.join(entry_name)
        };
        let file_type = entry.file_type()?;
        match bootstrap_reset_action(&entry_relative, preserve_subtrees, clear_dirs) {
            BootstrapResetAction::KeepSubtree => {}
            BootstrapResetAction::ClearContents => {
                if !file_type.is_dir() {
                    return Err(io::Error::other(format!(
                        "expected resettable bootstrap directory at {}",
                        entry.path().display()
                    ))
                    .into());
                }
                clear_directory_contents(&entry.path())?;
            }
            BootstrapResetAction::Descend => {
                if !file_type.is_dir() {
                    return Err(io::Error::other(format!(
                        "expected bootstrap path ancestor to be a directory: {}",
                        entry.path().display()
                    ))
                    .into());
                }
                reset_bootstrap_directory(
                    &entry.path(),
                    &entry_relative,
                    preserve_subtrees,
                    clear_dirs,
                )?;
            }
            BootstrapResetAction::Remove => remove_path(&entry.path(), file_type)?,
        }
    }
    Ok(())
}

fn clear_directory_contents(path: &Path) -> Result<(), DynError> {
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        remove_path(&entry.path(), entry.file_type()?)?;
    }
    Ok(())
}

fn remove_path(path: &Path, file_type: fs::FileType) -> io::Result<()> {
    if file_type.is_dir() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    }
}

fn bootstrap_reset_action(
    relative_path: &Path,
    preserve_subtrees: &[PathBuf],
    clear_dirs: &[PathBuf],
) -> BootstrapResetAction {
    if preserve_subtrees.iter().any(|path| path == relative_path) {
        return BootstrapResetAction::KeepSubtree;
    }
    if clear_dirs.iter().any(|path| path == relative_path) {
        return BootstrapResetAction::ClearContents;
    }
    if preserve_subtrees
        .iter()
        .chain(clear_dirs.iter())
        .any(|path| path.starts_with(relative_path))
    {
        return BootstrapResetAction::Descend;
    }
    BootstrapResetAction::Remove
}

fn copy_rootfs(chroot_root: &Path, config: &ServerConfig) -> Result<(), DynError> {
    let mut archive = StdCommand::new("tar");
    archive.current_dir("/");
    archive.arg("cf").arg("-");
    for path in excluded_rootfs_paths(config) {
        archive.arg(format!(
            "--exclude=./{}",
            strip_leading_slash(path).display()
        ));
    }
    for entry in rootfs_archive_paths()? {
        archive.arg(entry);
    }
    archive.stdout(Stdio::piped());

    let mut archive_child = with_context(archive.spawn(), || {
        String::from("failed to start tar archive process")
    })?;
    let archive_stdout = archive_child
        .stdout
        .take()
        .ok_or_else(|| io::Error::other("missing tar stdout"))?;
    let extract_status = with_context(
        build_rootfs_extract_command(chroot_root)
            .stdin(Stdio::from(archive_stdout))
            .status(),
        || {
            format!(
                "failed to extract execution image rootfs into {}",
                chroot_root.display()
            )
        },
    )?;
    let archive_status = with_context(archive_child.wait(), || {
        String::from("failed to wait for tar archive process")
    })?;

    if !archive_status.success() {
        return Err(format!("tar archive process failed with status {archive_status}").into());
    }
    if !extract_status.success() {
        return Err(format!(
            "tar extract process failed with status {extract_status} while seeding {}",
            chroot_root.display()
        )
        .into());
    }
    Ok(())
}

fn rootfs_archive_paths() -> Result<Vec<PathBuf>, DynError> {
    let mut entries = fs::read_dir("/")?
        .map(|entry| entry.map(|value| Path::new(".").join(value.file_name())))
        .collect::<Result<Vec<_>, _>>()?;
    entries.sort();
    Ok(entries)
}

pub(crate) fn build_rootfs_extract_command(chroot_root: &Path) -> StdCommand {
    let mut command = StdCommand::new("tar");
    command
        .arg("xmf")
        .arg("-")
        // PVC-backed paths can reject restoring source owners, modes, or mtimes,
        // and Alpine/BusyBox tar does not support GNU-only --no-same-owner.
        // The chroot only needs a runnable filesystem; required runtime paths are
        // normalized explicitly after extraction.
        .arg("-m")
        .arg("-o")
        .arg("--no-same-permissions")
        .arg("-C")
        .arg(chroot_root);
    command
}

fn excluded_rootfs_paths(config: &ServerConfig) -> Vec<&Path> {
    let mut paths = vec![
        Path::new("/proc"),
        Path::new("/sys"),
        Path::new("/dev"),
        Path::new("/run"),
        Path::new("/tmp"),
        config.logical_workspace_root.as_path(),
        config.remote_home.as_path(),
    ];
    if let Some(environment_mount_path) = config.environment_mount_path.as_deref() {
        paths.push(environment_mount_path);
    }
    paths
}

#[cfg(test)]
mod tests {
    use super::{build_rootfs_extract_command, reset_incomplete_bootstrap_root};
    use crate::config::{RawServerConfig, build_server_config};
    use crate::test_support::write_stub_command;
    use crate::{
        CHROOT_COPILOT_HOOKS_DIR, CHROOT_EXEC_POLICY_LIBRARY_PATH, CHROOT_EXEC_POLICY_RULES_PATH,
        CHROOT_KUBECTL_PATH, CHROOT_POST_TOOL_USE_HOOKS_PATH, CHROOT_RUNTIME_TOOL_PATH,
    };
    use std::ffi::OsString;
    use std::fs;
    use std::path::Path;
    use tempfile::TempDir;

    #[test]
    fn incomplete_bootstrap_reset_preserves_workspace_and_managed_assets() {
        let chroot_root = TempDir::new().unwrap();
        let workspace_root = chroot_root.path().join("workspace/project");
        fs::create_dir_all(&workspace_root).unwrap();
        fs::write(workspace_root.join("keep.txt"), "keep").unwrap();
        fs::create_dir_all(chroot_root.path().join("tmp")).unwrap();
        fs::write(chroot_root.path().join("tmp/stale.txt"), "stale").unwrap();
        fs::create_dir_all(chroot_root.path().join("var/tmp")).unwrap();
        fs::write(chroot_root.path().join("var/tmp/stale.txt"), "stale").unwrap();
        fs::create_dir_all(chroot_root.path().join("bin")).unwrap();
        fs::write(chroot_root.path().join("bin/bash"), "").unwrap();
        fs::create_dir_all(chroot_root.path().join("etc")).unwrap();
        fs::write(chroot_root.path().join("etc/os-release"), "").unwrap();
        fs::create_dir_all(chroot_root.path().join("root/.config/gh")).unwrap();
        fs::write(chroot_root.path().join("root/.config/gh/hosts.yml"), "gh").unwrap();
        fs::create_dir_all(chroot_root.path().join("root/.config/control-plane")).unwrap();
        fs::write(
            chroot_root
                .path()
                .join("root/.config/control-plane/stale.txt"),
            "stale",
        )
        .unwrap();
        fs::create_dir_all(chroot_root.path().join("root/.ssh")).unwrap();
        fs::write(chroot_root.path().join("root/.ssh/config"), "ssh").unwrap();
        write_stub_command(chroot_root.path(), CHROOT_KUBECTL_PATH);
        write_stub_command(chroot_root.path(), CHROOT_RUNTIME_TOOL_PATH);
        write_stub_command(chroot_root.path(), CHROOT_EXEC_POLICY_LIBRARY_PATH);
        write_stub_command(chroot_root.path(), CHROOT_EXEC_POLICY_RULES_PATH);
        write_stub_command(
            chroot_root.path(),
            &format!("{CHROOT_POST_TOOL_USE_HOOKS_PATH}/control-plane-rust.sh"),
        );
        write_stub_command(
            chroot_root.path(),
            &format!("{CHROOT_COPILOT_HOOKS_DIR}/git/pre-commit"),
        );

        let config = build_server_config(RawServerConfig {
            port: "8080",
            workspace: Path::new("/workspace"),
            chroot_root: Some(chroot_root.path()),
            environment_mount: Some(Path::new("/environment")),
            git_hooks_source: Some(Path::new("/environment/hooks/git")),
            remote_home: Path::new("/root"),
            git_user_name: None,
            git_user_email: None,
            startup_script: None,
            mode: "exec",
            exec_api_token: String::from("token"),
            timeout_sec: "3600",
            run_as_uid: "1000",
            run_as_gid: "1000",
        })
        .unwrap();

        reset_incomplete_bootstrap_root(chroot_root.path(), &config).unwrap();

        assert!(
            chroot_root
                .path()
                .join("workspace/project/keep.txt")
                .is_file()
        );
        assert!(chroot_root.path().join("usr/local/bin/kubectl").is_file());
        assert!(
            chroot_root
                .path()
                .join("usr/local/bin/control-plane-runtime-tool")
                .is_file()
        );
        assert!(
            chroot_root
                .path()
                .join("usr/local/share/control-plane/hooks/postToolUse/control-plane-rust.sh")
                .is_file()
        );
        assert!(
            chroot_root
                .path()
                .join("usr/local/share/control-plane/hooks/preToolUse/deny-rules.yaml")
                .is_file()
        );
        assert!(
            chroot_root
                .path()
                .join("root/.config/gh/hosts.yml")
                .is_file()
        );
        assert!(chroot_root.path().join("root/.ssh/config").is_file());
        assert!(!chroot_root.path().join("bin").exists());
        assert!(!chroot_root.path().join("etc").exists());
        assert!(
            !chroot_root
                .path()
                .join("root/.config/control-plane")
                .exists()
        );
        assert!(
            !chroot_root
                .path()
                .join("usr/local/share/control-plane/hooks/git")
                .exists()
        );
        assert!(chroot_root.path().join("tmp").is_dir());
        assert!(!chroot_root.path().join("tmp/stale.txt").exists());
        assert!(chroot_root.path().join("var/tmp").is_dir());
        assert!(!chroot_root.path().join("var/tmp/stale.txt").exists());
    }

    #[test]
    fn rootfs_extract_command_uses_portable_metadata_flags() {
        let command = build_rootfs_extract_command(Path::new("/environment/root"));
        let args = command.get_args().map(OsString::from).collect::<Vec<_>>();

        assert_eq!(
            args,
            vec![
                OsString::from("xmf"),
                OsString::from("-"),
                OsString::from("-m"),
                OsString::from("-o"),
                OsString::from("--no-same-permissions"),
                OsString::from("-C"),
                OsString::from("/environment/root"),
            ]
        );
    }
}
