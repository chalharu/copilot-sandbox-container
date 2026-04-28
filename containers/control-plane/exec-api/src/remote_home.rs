use nix::unistd::{Gid, Uid, chown};
use std::ffi::CString;
use std::fs;
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use crate::config::ServerConfig;
use crate::paths::nested_absolute_path;
use crate::{CHROOT_COPILOT_HOOKS_DIR, DynError, REMOTE_CARGO_TARGET_DIR, with_context};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RemoteHomePaths {
    home_dir: PathBuf,
    cargo_home_dir: PathBuf,
    cargo_config_path: PathBuf,
    config_dir: PathBuf,
    copilot_dir: PathBuf,
    copilot_hooks_path: PathBuf,
    gitconfig_path: PathBuf,
}
pub(crate) fn sync_remote_home_config(config: &ServerConfig) -> Result<(), DynError> {
    let Some(chroot_root) = config.chroot_root.as_deref() else {
        return Ok(());
    };

    let paths = resolve_remote_home_paths(chroot_root, &config.remote_home)?;
    ensure_remote_home_dirs(&paths)?;
    prepare_remote_home_for_update(&paths)?;
    ensure_symlink_path(
        &paths.copilot_hooks_path,
        Path::new(CHROOT_COPILOT_HOOKS_DIR),
    )?;
    with_context(
        fs::write(&paths.cargo_config_path, render_remote_cargo_config()),
        || {
            format!(
                "failed to write remote cargo config {}",
                paths.cargo_config_path.display()
            )
        },
    )?;
    with_context(
        fs::write(
            &paths.gitconfig_path,
            render_remote_git_config(&config.git_user_name, &config.git_user_email),
        ),
        || {
            format!(
                "failed to write remote git config {}",
                paths.gitconfig_path.display()
            )
        },
    )?;
    set_path_mode(&paths.cargo_config_path, 0o644, "remote cargo config")?;
    set_path_mode(&paths.gitconfig_path, 0o640, "remote git config")?;
    finalize_remote_home_permissions(&paths, config.run_as_uid, config.run_as_gid)?;
    Ok(())
}

pub(crate) fn resolve_remote_home_paths(
    chroot_root: &Path,
    remote_home: &Path,
) -> Result<RemoteHomePaths, DynError> {
    let home_dir = nested_absolute_path(chroot_root, remote_home)?;
    let cargo_home_dir = home_dir.join(".cargo");
    let cargo_config_path = cargo_home_dir.join("config.toml");
    let config_dir = home_dir.join(".config");
    let copilot_dir = home_dir.join(".copilot");
    let copilot_hooks_path = copilot_dir.join("hooks");
    let gitconfig_path = home_dir.join(".gitconfig");
    Ok(RemoteHomePaths {
        home_dir,
        cargo_home_dir,
        cargo_config_path,
        config_dir,
        copilot_dir,
        copilot_hooks_path,
        gitconfig_path,
    })
}

pub(crate) fn ensure_remote_home_dirs(paths: &RemoteHomePaths) -> Result<(), DynError> {
    with_context(fs::create_dir_all(&paths.cargo_home_dir), || {
        format!(
            "failed to create remote cargo directory {}",
            paths.cargo_home_dir.display()
        )
    })?;
    with_context(fs::create_dir_all(&paths.config_dir), || {
        format!(
            "failed to create remote config directory {}",
            paths.config_dir.display()
        )
    })?;
    with_context(fs::create_dir_all(&paths.copilot_dir), || {
        format!(
            "failed to create remote Copilot directory {}",
            paths.copilot_dir.display()
        )
    })?;
    Ok(())
}

fn prepare_remote_home_for_update(paths: &RemoteHomePaths) -> Result<(), DynError> {
    for path in [
        &paths.home_dir,
        &paths.cargo_home_dir,
        &paths.config_dir,
        &paths.copilot_dir,
    ] {
        set_path_owner(path, 0, 0, "remote home path")?;
    }
    if paths.cargo_config_path.exists() {
        set_path_owner(&paths.cargo_config_path, 0, 0, "remote cargo config")?;
    }
    if paths.gitconfig_path.exists() {
        set_path_owner(&paths.gitconfig_path, 0, 0, "remote git config")?;
    }
    Ok(())
}

fn finalize_remote_home_permissions(
    paths: &RemoteHomePaths,
    uid: u32,
    gid: u32,
) -> Result<(), DynError> {
    for (path, owner_uid, description) in [
        (&paths.home_dir, 0, "remote home"),
        (&paths.cargo_home_dir, uid, "remote cargo directory"),
        (&paths.config_dir, uid, "remote config directory"),
        (&paths.copilot_dir, 0, "remote Copilot directory"),
        (&paths.cargo_config_path, uid, "remote cargo config"),
        (&paths.gitconfig_path, 0, "remote git config"),
    ] {
        set_path_owner(path, owner_uid, gid, description)?;
    }
    for (path, mode, description) in [
        (&paths.home_dir, 0o1770, "remote home"),
        (&paths.copilot_dir, 0o1770, "remote Copilot directory"),
        (&paths.gitconfig_path, 0o640, "remote git config"),
    ] {
        set_path_mode(path, mode, description)?;
    }
    set_symlink_owner(
        &paths.copilot_hooks_path,
        0,
        gid,
        "remote Copilot hooks symlink",
    )?;
    Ok(())
}

fn ensure_symlink_path(link_path: &Path, target_path: &Path) -> Result<(), DynError> {
    if let Ok(metadata) = fs::symlink_metadata(link_path) {
        if metadata.file_type().is_symlink() {
            if fs::read_link(link_path)? == target_path {
                return Ok(());
            }
            fs::remove_file(link_path)?;
        } else if metadata.is_dir() {
            fs::remove_dir_all(link_path)?;
        } else {
            fs::remove_file(link_path)?;
        }
    }

    std::os::unix::fs::symlink(target_path, link_path)?;
    Ok(())
}

fn set_path_owner(path: &Path, uid: u32, gid: u32, description: &str) -> Result<(), DynError> {
    with_context(
        chown(path, Some(Uid::from_raw(uid)), Some(Gid::from_raw(gid))),
        || {
            format!(
                "failed to set ownership on {description} {}",
                path.display()
            )
        },
    )?;
    Ok(())
}

fn set_symlink_owner(path: &Path, uid: u32, gid: u32, description: &str) -> Result<(), DynError> {
    let path_bytes = path.as_os_str().as_bytes();
    let path_cstr = CString::new(path_bytes).map_err(|_| {
        format!(
            "failed to prepare {description} {} for ownership update",
            path.display()
        )
    })?;
    if unsafe { libc::lchown(path_cstr.as_ptr(), uid, gid) } != 0 {
        return Err(format!(
            "failed to set ownership on {description} {}: {}",
            path.display(),
            io::Error::last_os_error()
        )
        .into());
    }
    Ok(())
}

fn set_path_mode(path: &Path, mode: u32, description: &str) -> Result<(), DynError> {
    with_context(
        fs::set_permissions(path, fs::Permissions::from_mode(mode)),
        || {
            format!(
                "failed to set mode {mode:o} on {description} {}",
                path.display()
            )
        },
    )?;
    Ok(())
}

pub(crate) fn render_remote_git_config(
    git_user_name: &Option<String>,
    git_user_email: &Option<String>,
) -> String {
    let mut content = String::from(
        "[core]\n    hooksPath = /usr/local/share/control-plane/hooks/git\n[credential \"https://github.com\"]\n    helper =\n    helper = !gh auth git-credential\n[credential \"https://gist.github.com\"]\n    helper =\n    helper = !gh auth git-credential\n",
    );
    if git_user_name.is_some() || git_user_email.is_some() {
        content.push_str("[user]\n");
        if let Some(name) = git_user_name {
            content.push_str(&format!("    name = {name}\n"));
        }
        if let Some(email) = git_user_email {
            content.push_str(&format!("    email = {email}\n"));
        }
    }
    content
}

pub(crate) fn render_remote_cargo_config() -> String {
    format!("[build]\ntarget-dir = \"{REMOTE_CARGO_TARGET_DIR}\"\n")
}

#[cfg(test)]
mod tests {
    use super::{render_remote_cargo_config, render_remote_git_config, sync_remote_home_config};
    use crate::CHROOT_COPILOT_HOOKS_DIR;
    use crate::config::{RawServerConfig, build_server_config};
    use std::fs;
    use std::path::{Path, PathBuf};
    use tempfile::TempDir;

    #[test]
    fn remote_git_config_uses_chroot_hook_path() {
        let rendered = render_remote_git_config(
            &Some(String::from("Copilot")),
            &Some(String::from("copilot@example.com")),
        );
        assert!(rendered.contains("hooksPath = /usr/local/share/control-plane/hooks/git"));
        assert!(rendered.contains("name = Copilot"));
        assert!(rendered.contains("email = copilot@example.com"));
    }

    #[cfg(unix)]
    #[test]
    fn sync_remote_home_config_replaces_stale_copilot_hooks_directory_with_symlink() {
        use nix::unistd::Uid;

        if !Uid::effective().is_root() {
            return;
        }

        let workspace = TempDir::new().unwrap();
        let chroot_root = TempDir::new().unwrap();
        let config = build_server_config(RawServerConfig {
            port: "8080",
            workspace: workspace.path(),
            chroot_root: Some(chroot_root.path()),
            environment_mount: None,
            git_hooks_source: None,
            remote_home: Path::new("/root"),
            git_user_name: Some(String::from("Copilot")),
            git_user_email: Some(String::from("copilot@example.com")),
            startup_script: None,
            mode: "exec",
            exec_api_token: String::from("token"),
            timeout_sec: "3600",
            run_as_uid: "1000",
            run_as_gid: "1000",
        })
        .unwrap();
        let hooks_dir = chroot_root.path().join("root/.copilot/hooks");

        fs::create_dir_all(&hooks_dir).unwrap();
        fs::write(hooks_dir.join("stale.txt"), "stale\n").unwrap();

        sync_remote_home_config(&config).unwrap();

        assert_eq!(
            fs::read_link(&hooks_dir).unwrap(),
            PathBuf::from(CHROOT_COPILOT_HOOKS_DIR)
        );
        assert_eq!(
            fs::read_to_string(chroot_root.path().join("root/.cargo/config.toml")).unwrap(),
            render_remote_cargo_config()
        );
    }
}
