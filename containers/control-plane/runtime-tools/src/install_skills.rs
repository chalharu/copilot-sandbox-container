use std::collections::HashMap;
use std::ffi::OsStr;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use serde::Deserialize;
use tempfile::TempDir;

use crate::error::{ToolError, ToolResult};
use crate::support::{ensure_command, output_message, set_mode};

const USAGE: &str = "usage: install-git-skills-from-manifest <manifest-path> <destination-root>";

#[derive(Debug, Deserialize)]
struct ExternalSkillManifestEntry {
    repository: String,
    #[serde(rename = "ref")]
    git_ref: String,
    skills: Vec<String>,
}

pub fn run(args: &[String]) -> ToolResult<i32> {
    if args.len() == 1 && args[0] == "--help" {
        println!("{USAGE}");
        return Ok(0);
    }
    let [manifest_path, destination_root] = args else {
        return Err(ToolError::new(
            64,
            "install-git-skills-from-manifest",
            USAGE,
        ));
    };

    install_from_manifest(Path::new(manifest_path), Path::new(destination_root))
        .map_err(|message| ToolError::new(1, "install-git-skills-from-manifest", message))?;
    Ok(0)
}

fn install_from_manifest(manifest_path: &Path, destination_root: &Path) -> Result<(), String> {
    ensure_command("git").map_err(|error| error.to_string())?;
    ensure_manifest_exists(manifest_path)?;
    fs::create_dir_all(destination_root).map_err(|error| {
        format!(
            "failed to create destination root {}: {error}",
            destination_root.display()
        )
    })?;

    let entries = load_manifest(manifest_path)?;
    let mut installer = SkillInstaller::new(destination_root)?;
    for entry in entries {
        installer.install_entry(entry, manifest_path)?;
    }
    installer.finish(manifest_path)
}

fn ensure_manifest_exists(manifest_path: &Path) -> Result<(), String> {
    if manifest_path.is_file() {
        Ok(())
    } else {
        Err(format!(
            "Manifest path does not exist: {}",
            manifest_path.display()
        ))
    }
}

fn load_manifest(manifest_path: &Path) -> Result<Vec<ExternalSkillManifestEntry>, String> {
    let manifest_raw = fs::read_to_string(manifest_path).map_err(|error| {
        format!(
            "failed to read manifest {}: {error}",
            manifest_path.display()
        )
    })?;
    serde_yaml::from_str(&manifest_raw).map_err(|error| {
        format!(
            "failed to parse manifest {}: {error}",
            manifest_path.display()
        )
    })
}

struct SkillInstaller {
    checkout_root: TempDir,
    destination_root: PathBuf,
    checkout_dirs: HashMap<(String, String), PathBuf>,
    installed_skills: HashMap<String, String>,
    installed_count: usize,
}

impl SkillInstaller {
    fn new(destination_root: &Path) -> Result<Self, String> {
        let checkout_root = TempDir::new()
            .map_err(|error| format!("failed to create checkout directory: {error}"))?;
        Ok(Self {
            checkout_root,
            destination_root: destination_root.to_path_buf(),
            checkout_dirs: HashMap::new(),
            installed_skills: HashMap::new(),
            installed_count: 0,
        })
    }

    fn install_entry(
        &mut self,
        entry: ExternalSkillManifestEntry,
        manifest_path: &Path,
    ) -> Result<(), String> {
        let repository = require_non_empty(&entry.repository, "repository", manifest_path, None)?;
        let git_ref = require_non_empty(&entry.git_ref, "ref", manifest_path, Some(repository))?;
        let checkout_dir = self.checkout_dir(repository, git_ref)?;

        for skill_path in entry.skills {
            self.install_skill(&checkout_dir, repository, git_ref, &skill_path)?;
        }
        Ok(())
    }

    fn checkout_dir(&mut self, repository: &str, git_ref: &str) -> Result<PathBuf, String> {
        let key = (repository.to_string(), git_ref.to_string());
        if let Some(path) = self.checkout_dirs.get(&key) {
            return Ok(path.clone());
        }

        let target_dir = self
            .checkout_root
            .path()
            .join(format!("repo-{}", self.checkout_dirs.len()));
        clone_checkout(repository, git_ref, &target_dir)?;
        self.checkout_dirs.insert(key, target_dir.clone());
        Ok(target_dir)
    }

    fn install_skill(
        &mut self,
        checkout_dir: &Path,
        repository: &str,
        git_ref: &str,
        skill_path: &str,
    ) -> Result<(), String> {
        let normalized_skill_path = skill_path.trim_matches('/');
        let skill_name = skill_name(normalized_skill_path)?;
        let installed_from = format!("{repository}@{git_ref}:{normalized_skill_path}");
        reject_duplicate_skill(&self.installed_skills, &skill_name, &installed_from)?;

        let source_skill_dir = checkout_dir.join(normalized_skill_path);
        require_skill_manifest(
            &source_skill_dir,
            repository,
            git_ref,
            normalized_skill_path,
        )?;
        let destination_dir = self.destination_root.join(&skill_name);
        replace_skill_dir(&source_skill_dir, &destination_dir)?;

        self.installed_skills.insert(skill_name, installed_from);
        self.installed_count += 1;
        Ok(())
    }

    fn finish(self, manifest_path: &Path) -> Result<(), String> {
        if self.installed_count == 0 {
            Err(format!(
                "Manifest did not define any skills: {}",
                manifest_path.display()
            ))
        } else {
            Ok(())
        }
    }
}

fn require_non_empty<'a>(
    value: &'a str,
    field: &str,
    manifest_path: &Path,
    repository: Option<&str>,
) -> Result<&'a str, String> {
    let trimmed = value.trim();
    if !trimmed.is_empty() {
        return Ok(trimmed);
    }

    match repository {
        Some(repository) => Err(format!(
            "manifest entry in {} is missing {field} for {repository}",
            manifest_path.display()
        )),
        None => Err(format!(
            "manifest entry in {} is missing {field}",
            manifest_path.display()
        )),
    }
}

fn skill_name(skill_path: &str) -> Result<String, String> {
    let skill_name = Path::new(skill_path)
        .file_name()
        .and_then(OsStr::to_str)
        .unwrap_or_default()
        .to_string();
    if skill_name.is_empty() {
        Err(format!(
            "Could not determine skill name from path: {skill_path}"
        ))
    } else {
        Ok(skill_name)
    }
}

fn reject_duplicate_skill(
    installed_skills: &HashMap<String, String>,
    skill_name: &str,
    installed_from: &str,
) -> Result<(), String> {
    if let Some(first) = installed_skills.get(skill_name) {
        Err(format!(
            "Duplicate installed skill name: {skill_name}\n  first: {first}\n  next:  {installed_from}"
        ))
    } else {
        Ok(())
    }
}

fn require_skill_manifest(
    source_skill_dir: &Path,
    repository: &str,
    git_ref: &str,
    normalized_skill_path: &str,
) -> Result<(), String> {
    if source_skill_dir.join("SKILL.md").is_file() {
        Ok(())
    } else {
        Err(format!(
            "Missing SKILL.md for manifest entry: {repository}@{git_ref}:{normalized_skill_path}"
        ))
    }
}

fn replace_skill_dir(source_skill_dir: &Path, destination_dir: &Path) -> Result<(), String> {
    if destination_dir.exists() {
        fs::remove_dir_all(destination_dir).map_err(|error| {
            format!(
                "failed to remove existing skill directory {}: {error}",
                destination_dir.display()
            )
        })?;
    }
    copy_dir_recursive(source_skill_dir, destination_dir)
}

fn clone_checkout(repository: &str, git_ref: &str, checkout_dir: &Path) -> Result<(), String> {
    run_git(
        ["clone", repository, checkout_dir.to_str().unwrap()],
        repository,
        "clone",
    )?;
    run_git(
        [
            "-C",
            checkout_dir.to_str().unwrap(),
            "checkout",
            "--detach",
            git_ref,
        ],
        &format!("{repository}@{git_ref}"),
        "checkout",
    )
}

fn run_git<const N: usize>(args: [&str; N], target: &str, action: &str) -> Result<(), String> {
    let output = Command::new("git")
        .args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .map_err(|error| format!("failed to run git {action} for {target}: {error}"))?;

    if output.status.success() {
        Ok(())
    } else {
        Err(format!(
            "git {action} failed for {target}: {}",
            output_message(&output, &format!("unknown git {action} failure"))
        ))
    }
}

fn copy_dir_recursive(source: &Path, destination: &Path) -> Result<(), String> {
    let metadata = fs::symlink_metadata(source).map_err(|error| {
        format!(
            "failed to inspect source directory {}: {error}",
            source.display()
        )
    })?;
    if !metadata.is_dir() {
        return Err(format!("source is not a directory: {}", source.display()));
    }

    fs::create_dir_all(destination).map_err(|error| {
        format!(
            "failed to create destination directory {}: {error}",
            destination.display()
        )
    })?;
    set_mode(destination, metadata.permissions().mode())?;

    for entry in fs::read_dir(source)
        .map_err(|error| format!("failed to read directory {}: {error}", source.display()))?
    {
        let entry = entry.map_err(|error| {
            format!(
                "failed to read directory entry in {}: {error}",
                source.display()
            )
        })?;
        copy_dir_entry(&entry.path(), &destination.join(entry.file_name()))?;
    }
    Ok(())
}

fn copy_dir_entry(source_path: &Path, destination_path: &Path) -> Result<(), String> {
    let entry_metadata = fs::symlink_metadata(source_path)
        .map_err(|error| format!("failed to inspect path {}: {error}", source_path.display()))?;
    if entry_metadata.is_dir() {
        return copy_dir_recursive(source_path, destination_path);
    }
    if !entry_metadata.is_file() {
        return Err(format!(
            "unsupported file type in skill directory: {}",
            source_path.display()
        ));
    }

    fs::copy(source_path, destination_path).map_err(|error| {
        format!(
            "failed to copy {} to {}: {error}",
            source_path.display(),
            destination_path.display()
        )
    })?;
    set_mode(destination_path, entry_metadata.permissions().mode())
}

#[cfg(test)]
mod tests {
    use std::env;
    use std::fs;

    use tempfile::TempDir;

    use crate::test_support::{EnvRestore, lock_env, write_executable};

    use super::install_from_manifest;

    #[test]
    fn rejects_duplicate_skill_names() {
        let _env_lock = lock_env();
        let manifest_path = TempDir::new().unwrap();
        let destination_root = TempDir::new().unwrap();
        let bin_dir = TempDir::new().unwrap();
        let manifest = manifest_path.path().join("external-skills.yaml");
        let git_path = bin_dir.path().join("git");
        write_executable(
            &git_path,
            "#!/usr/bin/env bash\nset -euo pipefail\nif [[ \"$1\" == clone ]]; then\n  repo=\"$2\"\n  target=\"$3\"\n  mkdir -p \"$target\"\n  case \"$repo\" in\n    https://example.com/one.git)\n      mkdir -p \"$target/skills/foo\"\n      printf '# foo\\n' > \"$target/skills/foo/SKILL.md\"\n      ;;\n    https://example.com/two.git)\n      mkdir -p \"$target/other/foo\"\n      printf '# foo\\n' > \"$target/other/foo/SKILL.md\"\n      ;;\n    *)\n      printf 'unexpected repository: %s\\n' \"$repo\" >&2\n      exit 1\n      ;;\n  esac\n  exit 0\nfi\nif [[ \"$1\" == -C ]]; then\n  exit 0\nfi\nprintf 'unexpected git args: %s\\n' \"$*\" >&2\nexit 1\n",
        );
        fs::write(
            &manifest,
            "- repository: https://example.com/one.git\n  ref: abc\n  skills:\n    - skills/foo\n- repository: https://example.com/two.git\n  ref: def\n  skills:\n    - other/foo\n",
        )
        .unwrap();
        let path_value = format!(
            "{}:{}",
            bin_dir.path().display(),
            env::var("PATH").unwrap_or_default()
        );
        let _path = EnvRestore::set("PATH", &path_value);

        let error = install_from_manifest(&manifest, destination_root.path()).unwrap_err();
        assert!(error.contains("Duplicate installed skill name"));
    }
}
