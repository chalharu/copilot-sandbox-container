use regex::{Regex, bytes::Regex as BytesRegex};
use serde::Deserialize;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

pub const DEFAULT_RULES_PATH: &str =
    "/usr/local/share/control-plane/hooks/preToolUse/deny-rules.yaml";
const REPO_RULES_RELATIVE_PATH: &str = ".github/pre-tool-use-rules.yaml";

pub const PROTECTED_ENVIRONMENT_REASON: &str = "Protected environment overrides are blocked by control-plane policy. Use the managed environment provided by the control plane.";

#[derive(Clone, Debug, Default)]
pub struct CompiledConfig {
    pub command_rules: Vec<CompiledRule>,
    pub protected_environments: Vec<Regex>,
    pub file_access_rules: Vec<CompiledFileAccessRule>,
}

#[derive(Clone, Debug)]
pub struct CompiledRule {
    pub reason: String,
    pub pattern: BytesRegex,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CompiledFileAccessRule {
    pub path: String,
    pub reason: String,
    pub allowed_executables: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawConfig {
    #[serde(default, rename = "commandRules")]
    command_rules: Vec<RawRule>,
    #[serde(default, rename = "protectedEnvironments")]
    protected_environments: Vec<String>,
    #[serde(default, rename = "fileAccessRules")]
    file_access_rules: Vec<RawFileAccessRule>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawRule {
    rule: String,
    reason: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawFileAccessRule {
    path: String,
    reason: String,
    #[serde(default, rename = "allowedExecutables")]
    allowed_executables: Vec<String>,
}

static BUNDLED_RULES: OnceLock<Result<CompiledConfig, String>> = OnceLock::new();

pub fn discover_repo_root(start: &Path) -> Option<PathBuf> {
    let mut current = Some(start);
    while let Some(path) = current {
        if path.join(".git").exists() {
            return Some(path.to_path_buf());
        }
        current = path.parent();
    }
    None
}

pub fn resolve_rules_path() -> PathBuf {
    if let Ok(path) = std::env::var("CONTROL_PLANE_EXEC_POLICY_RULES_FILE") {
        let trimmed = path.trim();
        if !trimmed.is_empty() {
            return PathBuf::from(trimmed);
        }
    }

    let installed = PathBuf::from(DEFAULT_RULES_PATH);
    if installed.exists() {
        return installed;
    }

    for relative_path in [
        "../hooks/preToolUse/deny-rules.yaml",
        "./hooks/preToolUse/deny-rules.yaml",
    ] {
        let workspace_path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join(relative_path)
            .canonicalize()
            .unwrap_or_else(|_| Path::new(env!("CARGO_MANIFEST_DIR")).join(relative_path));
        if workspace_path.exists() {
            return workspace_path;
        }
    }

    installed
}

pub fn load_rules(repo_root: Option<&Path>) -> Result<CompiledConfig, String> {
    let mut config = load_bundled_rules()?.clone();
    if let Some(root) = repo_root {
        let repo_config = load_rule_file(&root.join(REPO_RULES_RELATIVE_PATH), true)?;
        merge_config(&mut config, repo_config);
    }
    Ok(config)
}

fn merge_config(config: &mut CompiledConfig, repo_config: CompiledConfig) {
    config.command_rules.extend(repo_config.command_rules);
    config
        .protected_environments
        .extend(repo_config.protected_environments);
    config
        .file_access_rules
        .extend(repo_config.file_access_rules);
}

fn load_bundled_rules() -> Result<&'static CompiledConfig, String> {
    match BUNDLED_RULES.get_or_init(|| load_rule_file(&resolve_rules_path(), false)) {
        Ok(config) => Ok(config),
        Err(error) => Err(error.clone()),
    }
}

fn load_rule_file(path: &Path, optional: bool) -> Result<CompiledConfig, String> {
    let read_result = if crate::policy_guard_active() {
        crate::with_policy_guard(|| fs::read_to_string(path))
    } else {
        fs::read_to_string(path)
    };

    let raw = match read_result {
        Ok(raw) => raw,
        Err(error) if optional && error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(CompiledConfig::default());
        }
        Err(error) => {
            return Err(format!(
                "failed to read exec policy rules at {}: {}",
                path.display(),
                error
            ));
        }
    };

    parse_config(&raw, path, optional)
}

fn parse_config(raw: &str, path: &Path, optional: bool) -> Result<CompiledConfig, String> {
    let config: RawConfig = serde_norway::from_str(raw).map_err(|error| {
        format!(
            "failed to parse exec policy rules at {}: {}",
            path.display(),
            error
        )
    })?;

    compile_config(config, path, optional)
}

fn compile_config(
    config: RawConfig,
    path: &Path,
    optional: bool,
) -> Result<CompiledConfig, String> {
    let command_rules = config
        .command_rules
        .into_iter()
        .enumerate()
        .map(|(rule_index, rule)| compile_rule(rule, path, rule_index))
        .collect::<Result<Vec<_>, _>>()?;

    let protected_environments = compile_patterns(
        config.protected_environments,
        &format!("protectedEnvironments in {}", path.display()),
    )?;
    let file_access_rules = config
        .file_access_rules
        .into_iter()
        .enumerate()
        .filter_map(|(rule_index, rule)| {
            compile_file_access_rule(rule, path, rule_index).transpose()
        })
        .collect::<Result<Vec<_>, _>>()?;

    if !optional
        && command_rules.is_empty()
        && protected_environments.is_empty()
        && file_access_rules.is_empty()
    {
        return Err(format!(
            "{} must define at least one commandRules entry, protectedEnvironments pattern, or fileAccessRules entry.",
            path.display()
        ));
    }

    Ok(CompiledConfig {
        command_rules,
        protected_environments,
        file_access_rules,
    })
}

fn compile_rule(rule: RawRule, path: &Path, rule_index: usize) -> Result<CompiledRule, String> {
    let description = format!("commandRule {} in {}", rule_index + 1, path.display());
    if rule.reason.trim().is_empty() {
        return Err(format!("{description} must define a non-empty reason."));
    }
    if rule.rule.is_empty() {
        return Err(format!(
            "{description} must define rule as a non-empty string."
        ));
    }

    Ok(CompiledRule {
        reason: rule.reason,
        pattern: compile_rule_pattern(rule.rule, &description)?,
    })
}

fn compile_file_access_rule(
    rule: RawFileAccessRule,
    path: &Path,
    rule_index: usize,
) -> Result<Option<CompiledFileAccessRule>, String> {
    let description = format!("fileAccessRule {} in {}", rule_index + 1, path.display());
    if rule.reason.trim().is_empty() {
        return Err(format!("{description} must define a non-empty reason."));
    }
    if rule.path.trim().is_empty() {
        return Err(format!(
            "{description} must define path as a non-empty string."
        ));
    }

    let expanded_path = expand_env_placeholders(&rule.path);
    if expanded_path.trim().is_empty() {
        return Ok(None);
    }

    let allowed_executables = rule
        .allowed_executables
        .into_iter()
        .enumerate()
        .map(|(index, entry)| compile_allowed_executable(entry, &description, index + 1))
        .collect::<Result<Vec<_>, _>>()?;

    Ok(Some(CompiledFileAccessRule {
        path: expanded_path,
        reason: rule.reason,
        allowed_executables,
    }))
}

fn compile_rule_pattern(entry: String, description: &str) -> Result<BytesRegex, String> {
    if entry.is_empty() {
        return Err(format!(
            "{description} must define rule as a non-empty string."
        ));
    }
    let expanded = expand_env_placeholders(&entry);
    let anchored = format!("^(?:{expanded})$");
    BytesRegex::new(&anchored)
        .map_err(|error| format!("invalid regex pattern in {description}: {error}"))
}

fn compile_allowed_executable(
    entry: String,
    description: &str,
    index: usize,
) -> Result<String, String> {
    let normalized = normalize_process_name(entry.trim());
    if normalized.is_empty() {
        return Err(format!(
            "allowedExecutables entry {} in {} must be a non-empty string.",
            index, description
        ));
    }

    Ok(normalized)
}

fn compile_patterns(entries: Vec<String>, description: &str) -> Result<Vec<Regex>, String> {
    entries
        .into_iter()
        .enumerate()
        .map(|(index, entry)| compile_pattern(entry, description, index + 1))
        .collect()
}

fn compile_pattern(entry: String, description: &str, index: usize) -> Result<Regex, String> {
    if entry.is_empty() {
        return Err(format!(
            "pattern {} in {} must be a non-empty string.",
            index, description
        ));
    }
    let expanded = expand_env_placeholders(&entry);
    let anchored = format!("^(?:{expanded})$");
    Regex::new(&anchored).map_err(|error| {
        format!(
            "invalid regex pattern {} in {}: {}",
            index, description, error
        )
    })
}

fn expand_env_placeholders(input: &str) -> String {
    static PLACEHOLDER_REGEX: OnceLock<Regex> = OnceLock::new();
    let placeholder_regex = PLACEHOLDER_REGEX
        .get_or_init(|| Regex::new(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}").expect("placeholder regex"));

    let mut expanded = String::with_capacity(input.len());
    let mut last = 0;
    for captures in placeholder_regex.captures_iter(input) {
        let Some(full_match) = captures.get(0) else {
            continue;
        };
        let Some(name_match) = captures.get(1) else {
            continue;
        };
        expanded.push_str(&input[last..full_match.start()]);
        let value = std::env::var(name_match.as_str()).unwrap_or_default();
        expanded.push_str(&regex::escape(&value));
        last = full_match.end();
    }
    expanded.push_str(&input[last..]);
    expanded
}

fn normalize_process_name(value: &str) -> String {
    Path::new(value)
        .file_name()
        .and_then(|entry| entry.to_str())
        .unwrap_or(value)
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::{discover_repo_root, merge_config, parse_config};
    use std::fs;
    use std::path::Path;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn parse_config_keeps_command_rules_and_protected_environments() {
        let yaml = r#"
commandRules:
  - rule: 'git(?:\x00[^\x00]+)*\x00commit(?:\x00[^\x00]+)*\x00(?:--no-verify|-[A-Za-z0-9]*n[A-Za-z0-9]*)(?:\x00[^\x00]+)*'
    reason: commit blocked
protectedEnvironments:
  - GIT_CONFIG_GLOBAL
fileAccessRules:
  - path: ${HOME}/.config/gh/hosts.yml
    reason: gh only
    allowedExecutables:
      - gh
"#;
        unsafe {
            std::env::set_var("HOME", "/home/copilot");
        }

        let config = parse_config(yaml, Path::new("/tmp/rules.yaml"), false).unwrap();

        assert_eq!(config.command_rules.len(), 1);
        assert_eq!(config.protected_environments.len(), 1);
        assert_eq!(config.file_access_rules.len(), 1);
        assert!(
            config.command_rules[0]
                .pattern
                .is_match(b"git\0commit\0--no-verify")
        );
        assert_eq!(
            config.file_access_rules[0].path,
            "/home/copilot/.config/gh/hosts.yml"
        );
        assert_eq!(
            config.file_access_rules[0].allowed_executables,
            vec!["gh".to_string()]
        );
    }

    #[test]
    fn parse_config_expands_env_placeholders() {
        unsafe {
            std::env::set_var("CONTROL_PLANE_TEST_ALLOWED_PATH", "/tmp/allowed");
        }
        let yaml = r#"
protectedEnvironments:
  - ${CONTROL_PLANE_TEST_ALLOWED_PATH}
"#;

        let config = parse_config(yaml, Path::new("/tmp/rules.yaml"), false).unwrap();

        assert!(config.protected_environments[0].is_match("/tmp/allowed"));
    }

    #[test]
    fn parse_config_rejects_removed_group_fields() {
        let yaml = r#"
commandRules:
  - toolName: bash
    column: command
    rules:
      - rule:
          - git
        reason: blocked
"#;

        let error = parse_config(yaml, Path::new("/tmp/rules.yaml"), false).unwrap_err();

        assert!(error.contains("unknown field"));
        assert!(error.contains("toolName"));
    }

    #[test]
    fn parse_config_allows_empty_optional_repo_config() {
        let config = parse_config("", Path::new("/tmp/repo-rules.yaml"), true).unwrap();

        assert!(config.command_rules.is_empty());
        assert!(config.protected_environments.is_empty());
        assert!(config.file_access_rules.is_empty());
    }

    #[test]
    fn parse_config_skips_empty_expanded_file_access_paths() {
        let yaml = r#"
fileAccessRules:
  - path: ${CONTROL_PLANE_TEST_DISABLED_PATH}
    reason: disabled when missing
"#;

        let config = parse_config(yaml, Path::new("/tmp/repo-rules.yaml"), true).unwrap();

        assert!(config.file_access_rules.is_empty());
    }

    #[test]
    fn merge_config_keeps_repo_local_file_access_rules() {
        let bundled_yaml = r#"
commandRules:
  - rule: 'git\x00status'
    reason: bundled command rule
protectedEnvironments:
  - GIT_CONFIG_GLOBAL
"#;
        let repo_yaml = r#"
fileAccessRules:
  - path: /tmp/secret-token
    reason: repo-local file rule
    allowedExecutables:
      - podman
"#;

        let mut bundled = parse_config(bundled_yaml, Path::new("/tmp/rules.yaml"), false).unwrap();
        let repo = parse_config(repo_yaml, Path::new("/tmp/repo-rules.yaml"), true).unwrap();

        merge_config(&mut bundled, repo);

        assert_eq!(bundled.command_rules.len(), 1);
        assert_eq!(bundled.protected_environments.len(), 1);
        assert_eq!(bundled.file_access_rules.len(), 1);
        assert_eq!(bundled.file_access_rules[0].path, "/tmp/secret-token");
        assert_eq!(
            bundled.file_access_rules[0].allowed_executables,
            vec!["podman".to_string()]
        );
    }

    #[test]
    fn discover_repo_root_walks_up_to_git_marker() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("control-plane-exec-policy-{unique}"));
        let nested = root.join("nested/deeper");

        fs::create_dir_all(&nested).unwrap();
        fs::create_dir_all(root.join(".git")).unwrap();

        let discovered = discover_repo_root(&nested);

        assert_eq!(discovered.as_deref(), Some(root.as_path()));
        fs::remove_dir_all(&root).unwrap();
    }
}
