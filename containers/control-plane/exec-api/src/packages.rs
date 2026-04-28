use std::ffi::OsString;
use std::io;
use std::path::{Path, PathBuf};

use crate::DynError;
use crate::command::{resolve_shell, run_in_chroot};
use crate::paths::nested_absolute_path;

pub(crate) fn install_required_packages(chroot_root: &Path) -> Result<(), DynError> {
    if required_commands_present(chroot_root) {
        return Ok(());
    }

    if let Some(apk_path) = resolve_chroot_command(chroot_root, &["/sbin/apk", "/bin/apk"]) {
        let packages = apk_required_packages();
        run_in_chroot(chroot_root, &apk_path, &packages, &[])?;
        return Ok(());
    }

    if let Some(apt_get_path) =
        resolve_chroot_command(chroot_root, &["/usr/bin/apt-get", "/bin/apt-get"])
    {
        let noninteractive = [(
            OsString::from("DEBIAN_FRONTEND"),
            OsString::from("noninteractive"),
        )];
        let update_args = [
            OsString::from("update"),
            OsString::from("-o"),
            OsString::from("Acquire::Retries=3"),
        ];
        let install_args = apt_required_packages();
        run_in_chroot(chroot_root, &apt_get_path, &update_args, &noninteractive)?;
        run_in_chroot(chroot_root, &apt_get_path, &install_args, &noninteractive)?;
        return Ok(());
    }

    Err(io::Error::other("unsupported execution image package manager: need apk or apt-get").into())
}

pub(crate) fn apk_required_packages() -> Vec<OsString> {
    vec![
        OsString::from("add"),
        OsString::from("--no-cache"),
        OsString::from("bash"),
        OsString::from("git"),
        OsString::from("github-cli"),
        OsString::from("kubectl"),
        OsString::from("ca-certificates"),
        OsString::from("openssh-client"),
    ]
}

pub(crate) fn apt_required_packages() -> Vec<OsString> {
    vec![
        OsString::from("install"),
        OsString::from("-y"),
        OsString::from("--no-install-recommends"),
        OsString::from("bash"),
        OsString::from("ca-certificates"),
        OsString::from("git"),
        OsString::from("gh"),
        OsString::from("openssh-client"),
    ]
}

pub(crate) fn run_startup_script(chroot_root: &Path, startup_script: &str) -> Result<(), DynError> {
    if startup_script.trim().is_empty() {
        return Ok(());
    }

    let shell = resolve_shell(Some(chroot_root))
        .ok_or_else(|| io::Error::other("no supported shell found for startup script"))?;
    run_in_chroot(
        chroot_root,
        &shell,
        &[OsString::from("-lc"), OsString::from(startup_script)],
        &[],
    )
}

pub(crate) fn required_commands_present(chroot_root: &Path) -> bool {
    ["/bin/bash", "/usr/bin/git", "/usr/bin/gh", "/usr/bin/ssh"]
        .iter()
        .all(|candidate| resolve_chroot_command(chroot_root, &[*candidate]).is_some())
        && resolve_chroot_command(chroot_root, &["/usr/bin/kubectl", "/usr/local/bin/kubectl"])
            .is_some()
}

fn resolve_chroot_command(chroot_root: &Path, candidates: &[&str]) -> Option<PathBuf> {
    candidates.iter().find_map(|candidate| {
        let absolute = Path::new(candidate);
        nested_absolute_path(chroot_root, absolute)
            .ok()
            .filter(|path| path.is_file())
            .map(|_| absolute.to_path_buf())
    })
}

#[cfg(test)]
mod tests {
    use super::{apt_required_packages, required_commands_present};
    use crate::test_support::write_stub_command;
    use std::ffi::OsString;
    use tempfile::TempDir;

    #[test]
    fn required_commands_present_requires_kubectl_in_chroot() {
        let chroot_root = TempDir::new().unwrap();
        for command_path in ["/bin/bash", "/usr/bin/git", "/usr/bin/gh", "/usr/bin/ssh"] {
            write_stub_command(chroot_root.path(), command_path);
        }
        assert!(!required_commands_present(chroot_root.path()));
        write_stub_command(chroot_root.path(), "/usr/local/bin/kubectl");
        assert!(required_commands_present(chroot_root.path()));
    }

    #[test]
    fn apt_required_packages_skip_kubectl_package() {
        let packages = apt_required_packages();

        assert!(!packages.contains(&OsString::from("kubectl")));
        assert!(!packages.contains(&OsString::from("kubernetes-client")));
    }
}
