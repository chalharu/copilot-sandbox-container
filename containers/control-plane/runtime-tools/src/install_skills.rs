use std::collections::HashMap;
use std::ffi::OsStr;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Component, Path, PathBuf};

use git2::{
    Repository,
    build::{CheckoutBuilder, RepoBuilder},
};
use serde::Deserialize;
use tempfile::TempDir;

use crate::error::{ToolError, ToolResult};
use crate::support::set_mode;

const USAGE: &str = "usage: install-git-skills-from-manifest <manifest-path> <destination-root>";
const LICENSE_REFERENCE_MARKER: &str = "license: Complete terms in LICENSE.txt";
const LICENSE_DESTINATION_NAME: &str = "LICENSE.txt";
const REPOSITORY_LICENSE_CANDIDATES: &[&str] = &[
    "LICENSE.txt",
    "LICENSE",
    "LICENSE.md",
    "COPYING.txt",
    "COPYING",
    "COPYING.md",
];

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
        validate_repository(repository, manifest_path)?;
        validate_git_ref(git_ref, manifest_path, repository)?;
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
        let normalized_skill_path = normalize_skill_path(skill_path)?;
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
        ensure_referenced_license_file(
            &source_skill_dir,
            checkout_dir,
            &destination_dir,
            repository,
            git_ref,
            normalized_skill_path,
        )?;

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

fn normalize_skill_path(skill_path: &str) -> Result<&str, String> {
    let normalized_skill_path = skill_path.trim_matches('/');
    let path = Path::new(normalized_skill_path);
    let is_safe = !path.components().any(|component| {
        matches!(
            component,
            Component::ParentDir | Component::CurDir | Component::RootDir | Component::Prefix(_)
        )
    });
    if is_safe {
        Ok(normalized_skill_path)
    } else {
        Err(format!(
            "skill path must stay within repository checkout: {skill_path}"
        ))
    }
}

fn validate_repository(repository: &str, manifest_path: &Path) -> Result<(), String> {
    if repository.starts_with("https://") {
        Ok(())
    } else {
        Err(format!(
            "manifest entry in {} must use an https:// repository URL: {repository}",
            manifest_path.display()
        ))
    }
}

fn validate_git_ref(git_ref: &str, manifest_path: &Path, repository: &str) -> Result<(), String> {
    let valid = git_ref.chars().all(|character| {
        character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '/' | '-')
    });
    if valid && !git_ref.starts_with('-') {
        Ok(())
    } else {
        Err(format!(
            "manifest entry in {} has an invalid ref for {repository}: {git_ref}",
            manifest_path.display()
        ))
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

fn ensure_referenced_license_file(
    source_skill_dir: &Path,
    checkout_dir: &Path,
    destination_dir: &Path,
    repository: &str,
    git_ref: &str,
    normalized_skill_path: &str,
) -> Result<(), String> {
    let skill_manifest_path = destination_dir.join("SKILL.md");
    let skill_manifest = fs::read_to_string(&skill_manifest_path).map_err(|error| {
        format!(
            "failed to read skill manifest {}: {error}",
            skill_manifest_path.display()
        )
    })?;
    if !skill_manifest.contains(LICENSE_REFERENCE_MARKER) {
        return Ok(());
    }

    let destination_license_path = destination_dir.join(LICENSE_DESTINATION_NAME);
    if destination_license_path.is_file() {
        return Ok(());
    }

    let source_license_path =
        find_repository_license_file(source_skill_dir, checkout_dir).ok_or_else(|| {
            format!(
                "skill manifest references {LICENSE_DESTINATION_NAME} but no repository license file was found for manifest entry: {repository}@{git_ref}:{normalized_skill_path}"
            )
        })?;
    copy_file_with_mode(&source_license_path, &destination_license_path)
}

fn find_repository_license_file(source_skill_dir: &Path, checkout_dir: &Path) -> Option<PathBuf> {
    let mut current_dir = Some(source_skill_dir);

    while let Some(directory) = current_dir {
        for candidate in REPOSITORY_LICENSE_CANDIDATES {
            let candidate_path = directory.join(candidate);
            if candidate_path.is_file() {
                return Some(candidate_path);
            }
        }
        if directory == checkout_dir {
            break;
        }
        current_dir = directory
            .parent()
            .filter(|parent| parent.starts_with(checkout_dir));
    }

    None
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
    let repo = clone_repository(repository, checkout_dir)?;
    let object = resolve_checkout_object(&repo, git_ref)?;
    repo.checkout_tree(&object, Some(CheckoutBuilder::new().force()))
        .map_err(|error| format!("git checkout failed for {repository}@{git_ref}: {error}"))?;
    repo.set_head_detached(object.id())
        .map_err(|error| format!("failed to detach HEAD for {repository}@{git_ref}: {error}"))
}

fn clone_repository(repository: &str, checkout_dir: &Path) -> Result<Repository, String> {
    let mut builder = RepoBuilder::new();
    builder.clone(repository, checkout_dir).map_err(|error| {
        format!(
            "git clone failed for {repository} into {}: {error}",
            checkout_dir.display()
        )
    })
}

fn resolve_checkout_object<'a>(
    repo: &'a Repository,
    git_ref: &str,
) -> Result<git2::Object<'a>, String> {
    let candidates = [
        git_ref.to_string(),
        format!("refs/tags/{git_ref}"),
        format!("refs/remotes/origin/{git_ref}"),
        format!("origin/{git_ref}"),
    ];
    let mut last_error = None;
    for candidate in candidates {
        match repo.revparse_single(&candidate) {
            Ok(object) => return Ok(object),
            Err(error) => last_error = Some(error),
        }
    }
    match last_error {
        Some(error) => Err(format!(
            "failed to resolve requested ref {git_ref}: {error}"
        )),
        None => Err(format!("failed to resolve requested ref: {git_ref}")),
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

fn copy_file_with_mode(source_path: &Path, destination_path: &Path) -> Result<(), String> {
    let source_metadata = fs::symlink_metadata(source_path)
        .map_err(|error| format!("failed to inspect path {}: {error}", source_path.display()))?;
    if !source_metadata.is_file() {
        return Err(format!(
            "unsupported file type for copied license: {}",
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
    set_mode(destination_path, source_metadata.permissions().mode())
}

#[cfg(test)]
mod tests {
    use std::fs;

    use tempfile::TempDir;

    use crate::test_support::lock_env;

    use super::{SkillInstaller, install_from_manifest};

    #[test]
    fn rejects_duplicate_skill_names() {
        let _env_lock = lock_env();
        let destination_root = TempDir::new().unwrap();
        let first_repo = TempDir::new().unwrap();
        let second_repo = TempDir::new().unwrap();
        fs::create_dir_all(first_repo.path().join("skills/foo")).unwrap();
        fs::create_dir_all(second_repo.path().join("other/foo")).unwrap();
        fs::write(first_repo.path().join("skills/foo/SKILL.md"), "# foo\n").unwrap();
        fs::write(second_repo.path().join("other/foo/SKILL.md"), "# foo\n").unwrap();

        let mut installer = SkillInstaller::new(destination_root.path()).unwrap();
        installer
            .install_skill(
                first_repo.path(),
                "https://example.com/one.git",
                "abc",
                "skills/foo",
            )
            .unwrap();
        let error = installer
            .install_skill(
                second_repo.path(),
                "https://example.com/two.git",
                "def",
                "other/foo",
            )
            .unwrap_err();
        assert!(error.contains("Duplicate installed skill name"));
    }

    #[test]
    fn rejects_non_https_repositories() {
        let _env_lock = lock_env();
        let manifest_path = TempDir::new().unwrap();
        let destination_root = TempDir::new().unwrap();
        let manifest = manifest_path.path().join("external-skills.yaml");
        fs::write(
            &manifest,
            "- repository: ssh://example.com/one.git\n  ref: abc\n  skills:\n    - skills/foo\n",
        )
        .unwrap();

        let error = install_from_manifest(&manifest, destination_root.path()).unwrap_err();
        assert!(error.contains("must use an https:// repository URL"));
    }

    #[test]
    fn rejects_invalid_git_refs() {
        let _env_lock = lock_env();
        let manifest_path = TempDir::new().unwrap();
        let destination_root = TempDir::new().unwrap();
        let manifest = manifest_path.path().join("external-skills.yaml");
        fs::write(
            &manifest,
            "- repository: https://example.com/one.git\n  ref: --orphan\n  skills:\n    - skills/foo\n",
        )
        .unwrap();

        let error = install_from_manifest(&manifest, destination_root.path()).unwrap_err();
        assert!(error.contains("has an invalid ref"));
    }

    #[test]
    fn rejects_skill_path_traversal() {
        let _env_lock = lock_env();
        let destination_root = TempDir::new().unwrap();
        let checkout_root = TempDir::new().unwrap();
        let checkout_dir = checkout_root.path().join("repo");
        let escaped_dir = checkout_root.path().join("outside");
        fs::create_dir_all(&checkout_dir).unwrap();
        fs::create_dir_all(&escaped_dir).unwrap();
        fs::write(escaped_dir.join("SKILL.md"), "# outside\n").unwrap();

        let mut installer = SkillInstaller::new(destination_root.path()).unwrap();
        let error = installer
            .install_skill(
                &checkout_dir,
                "https://example.com/one.git",
                "abc",
                "../outside",
            )
            .unwrap_err();
        assert!(error.contains("must stay within repository checkout"));
    }

    #[test]
    fn copies_repository_license_when_skill_references_license_txt() {
        let _env_lock = lock_env();
        let destination_root = TempDir::new().unwrap();
        let checkout_root = TempDir::new().unwrap();
        let skill_dir = checkout_root
            .path()
            .join("plugins/frontend-design/skills/frontend-design");
        fs::create_dir_all(&skill_dir).unwrap();
        fs::write(checkout_root.path().join("LICENSE.md"), "upstream terms\n").unwrap();
        fs::write(
            skill_dir.join("SKILL.md"),
            "---\nname: frontend-design\nlicense: Complete terms in LICENSE.txt\n---\n",
        )
        .unwrap();

        let mut installer = SkillInstaller::new(destination_root.path()).unwrap();
        installer
            .install_skill(
                checkout_root.path(),
                "https://example.com/frontend.git",
                "main",
                "plugins/frontend-design/skills/frontend-design",
            )
            .unwrap();

        assert_eq!(
            fs::read_to_string(destination_root.path().join("frontend-design/LICENSE.txt"))
                .unwrap(),
            "upstream terms\n"
        );
    }

    #[test]
    fn rejects_skill_with_dangling_license_reference() {
        let _env_lock = lock_env();
        let destination_root = TempDir::new().unwrap();
        let checkout_root = TempDir::new().unwrap();
        let skill_dir = checkout_root
            .path()
            .join("plugins/frontend-design/skills/frontend-design");
        fs::create_dir_all(&skill_dir).unwrap();
        fs::write(
            skill_dir.join("SKILL.md"),
            "---\nname: frontend-design\nlicense: Complete terms in LICENSE.txt\n---\n",
        )
        .unwrap();

        let mut installer = SkillInstaller::new(destination_root.path()).unwrap();
        let error = installer
            .install_skill(
                checkout_root.path(),
                "https://example.com/frontend.git",
                "main",
                "plugins/frontend-design/skills/frontend-design",
            )
            .unwrap_err();

        assert!(error.contains("references LICENSE.txt"));
    }
}
