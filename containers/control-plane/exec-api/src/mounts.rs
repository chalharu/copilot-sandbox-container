use nix::mount::{MsFlags, mount};
use std::fs;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use crate::paths::nested_absolute_path;
use crate::remote_home::{ensure_remote_home_dirs, resolve_remote_home_paths};
use crate::{
    CHROOT_KUBERNETES_SERVICE_ACCOUNT_DIR, DynError, KUBERNETES_SERVICE_ACCOUNT_DIR, with_context,
};

pub(crate) fn ensure_runtime_dirs(chroot_root: &Path, remote_home: &Path) -> Result<(), DynError> {
    for relative in ["proc", "dev", "run", "tmp", "var/tmp"] {
        let path = chroot_root.join(relative);
        with_context(fs::create_dir_all(&path), || {
            format!("failed to create runtime directory {}", path.display())
        })?;
    }
    for relative in ["tmp", "var/tmp"] {
        let path = chroot_root.join(relative);
        with_context(
            fs::set_permissions(&path, fs::Permissions::from_mode(0o1777)),
            || format!("failed to set sticky permissions on {}", path.display()),
        )?;
    }

    ensure_remote_home_dirs(&resolve_remote_home_paths(Some(chroot_root), remote_home)?)?;
    Ok(())
}

pub(crate) fn mount_runtime_filesystems(chroot_root: &Path) -> Result<(), DynError> {
    let dev_target = nested_absolute_path(chroot_root, Path::new("/dev"))?;
    let proc_target = nested_absolute_path(chroot_root, Path::new("/proc"))?;
    let run_target = nested_absolute_path(chroot_root, Path::new("/run"))?;
    bind_mount_if_missing(Path::new("/dev"), &dev_target)?;
    mount_proc_if_missing(&proc_target)?;
    mount_tmpfs_if_missing(&run_target, "mode=0755")?;
    bind_kubernetes_service_account_if_present(chroot_root)?;
    Ok(())
}

fn bind_kubernetes_service_account_if_present(chroot_root: &Path) -> Result<(), DynError> {
    let source = Path::new(KUBERNETES_SERVICE_ACCOUNT_DIR);
    if !source.is_dir() {
        return Ok(());
    }

    let target = nested_absolute_path(
        chroot_root,
        Path::new(CHROOT_KUBERNETES_SERVICE_ACCOUNT_DIR),
    )?;
    let parent = target.parent().ok_or_else(|| {
        io::Error::other(format!(
            "missing parent for Kubernetes service account mount {}",
            target.display()
        ))
    })?;
    with_context(fs::create_dir_all(parent), || {
        format!(
            "failed to create Kubernetes service account mount parent {}",
            parent.display()
        )
    })?;
    with_context(fs::create_dir_all(&target), || {
        format!(
            "failed to create Kubernetes service account mount target {}",
            target.display()
        )
    })?;
    bind_mount_if_missing(source, &target)
}

fn mountinfo_contains(target: &Path) -> Result<bool, DynError> {
    let target = target
        .to_str()
        .ok_or_else(|| io::Error::other("mount target must be valid UTF-8"))?;
    let mountinfo = fs::read_to_string("/proc/self/mountinfo")?;
    Ok(mountinfo
        .lines()
        .filter_map(parse_mountinfo_mount_point)
        .any(|mount_point| mount_point == target))
}

fn parse_mountinfo_mount_point(line: &str) -> Option<String> {
    let mount_point = line.split(" ").nth(4)?;
    decode_mountinfo_field(mount_point).ok()
}

fn decode_mountinfo_field(field: &str) -> io::Result<String> {
    let bytes = field.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;

    while index < bytes.len() {
        if let Some(value) = parse_mountinfo_escape(bytes, index)? {
            decoded.push(value);
            index += 4;
            continue;
        }

        decoded.push(bytes[index]);
        index += 1;
    }

    String::from_utf8(decoded).map_err(io::Error::other)
}

fn parse_mountinfo_escape(bytes: &[u8], index: usize) -> io::Result<Option<u8>> {
    if bytes.get(index) != Some(&b'\\') || index + 3 >= bytes.len() {
        return Ok(None);
    }

    let octal = &bytes[index + 1..index + 4];
    if !octal.iter().all(|value| matches!(value, b'0'..=b'7')) {
        return Ok(None);
    }

    let octal = std::str::from_utf8(octal).map_err(io::Error::other)?;
    let value = u8::from_str_radix(octal, 8).map_err(io::Error::other)?;
    Ok(Some(value))
}

fn bind_mount_if_missing(source: &Path, target: &Path) -> Result<(), DynError> {
    if mountinfo_contains(target)? {
        return Ok(());
    }

    with_context(
        mount(
            Some(source),
            target,
            Option::<&str>::None,
            MsFlags::MS_BIND | MsFlags::MS_REC,
            Option::<&str>::None,
        ),
        || {
            format!(
                "failed to bind-mount {} onto {}",
                source.display(),
                target.display()
            )
        },
    )?;
    Ok(())
}

fn mount_proc_if_missing(target: &Path) -> Result<(), DynError> {
    if mountinfo_contains(target)? {
        return Ok(());
    }

    with_context(
        mount(
            Some("proc"),
            target,
            Some("proc"),
            MsFlags::empty(),
            Option::<&str>::None,
        ),
        || format!("failed to mount proc at {}", target.display()),
    )?;
    Ok(())
}

fn mount_tmpfs_if_missing(target: &Path, options: &str) -> Result<(), DynError> {
    if mountinfo_contains(target)? {
        return Ok(());
    }

    with_context(
        mount(
            Some("tmpfs"),
            target,
            Some("tmpfs"),
            MsFlags::empty(),
            Some(options),
        ),
        || {
            format!(
                "failed to mount tmpfs at {} with options {options}",
                target.display()
            )
        },
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{ensure_runtime_dirs, parse_mountinfo_mount_point};
    use std::path::Path;
    use tempfile::TempDir;

    #[test]
    fn ensure_runtime_dirs_creates_run_directory() {
        let tempdir = TempDir::new().unwrap();
        ensure_runtime_dirs(tempdir.path(), Path::new("/root")).unwrap();

        assert!(tempdir.path().join("run").is_dir());
        assert!(tempdir.path().join("tmp").is_dir());
        assert!(tempdir.path().join("var/tmp").is_dir());
        assert!(tempdir.path().join("root/.config").is_dir());
        assert!(tempdir.path().join("root/.copilot").is_dir());
    }

    #[test]
    fn parse_mountinfo_mount_point_decodes_escaped_paths() {
        let line = "29 23 0:26 / /environment/root\\040with\\040spaces rw,nosuid - tmpfs tmpfs rw";

        assert_eq!(
            parse_mountinfo_mount_point(line).as_deref(),
            Some("/environment/root with spaces")
        );
    }
}
