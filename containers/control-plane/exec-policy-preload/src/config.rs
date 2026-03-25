use regex::Regex;
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
    pub options_with_value: Vec<String>,
}

#[derive(Clone, Debug)]
pub struct CompiledRule {
    pub reason: String,
    pub basename_pattern: Regex,
    pub command_patterns: Vec<Regex>,
    pub option_patterns: Vec<Regex>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawConfig {
    #[serde(default, rename = "commandRules")]
    command_rules: Vec<RawRule>,
    #[serde(default, rename = "protectedEnvironments")]
    protected_environments: Vec<String>,
    #[serde(default, rename = "optionsWithValue")]
    options_with_value: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawRule {
    rule: Vec<String>,
    reason: String,
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
        config.command_rules.extend(repo_config.command_rules);
        config
            .protected_environments
            .extend(repo_config.protected_environments);
        config
            .options_with_value
            .extend(repo_config.options_with_value);
        config.options_with_value.sort();
        config.options_with_value.dedup();
    }
    Ok(config)
}

fn load_bundled_rules() -> Result<&'static CompiledConfig, String> {
    match BUNDLED_RULES.get_or_init(|| load_rule_file(&resolve_rules_path(), false)) {
        Ok(config) => Ok(config),
        Err(error) => Err(error.clone()),
    }
}

fn load_rule_file(path: &Path, optional: bool) -> Result<CompiledConfig, String> {
    let raw = match fs::read_to_string(path) {
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
    let mut options_with_value = compile_option_names(
        config.options_with_value,
        &format!("optionsWithValue in {}", path.display()),
    )?;
    options_with_value.sort();
    options_with_value.dedup();

    if !optional
        && command_rules.is_empty()
        && protected_environments.is_empty()
        && options_with_value.is_empty()
    {
        return Err(format!(
            "{} must define at least one commandRules entry, protectedEnvironments pattern, or optionsWithValue entry.",
            path.display()
        ));
    }

    Ok(CompiledConfig {
        command_rules,
        protected_environments,
        options_with_value,
    })
}

fn compile_rule(rule: RawRule, path: &Path, rule_index: usize) -> Result<CompiledRule, String> {
    let description = format!("commandRule {} in {}", rule_index + 1, path.display());
    if rule.reason.trim().is_empty() {
        return Err(format!("{description} must define a non-empty reason."));
    }
    if rule.rule.is_empty() {
        return Err(format!(
            "{description} must define rule as a non-empty array."
        ));
    }
    let mut raw_patterns = rule.rule.into_iter();
    let basename = raw_patterns
        .next()
        .expect("rule must contain at least one pattern after validation");
    let remaining_patterns: Vec<String> = raw_patterns.collect();

    Ok(CompiledRule {
        reason: rule.reason,
        basename_pattern: compile_pattern(basename, &format!("basename in {description}"), 1)?,
        command_patterns: remaining_patterns
            .iter()
            .enumerate()
            .filter(|(_, entry)| !entry.starts_with('-'))
            .map(|(index, entry)| {
                compile_pattern(
                    entry.clone(),
                    &format!("command patterns in {description}"),
                    index + 2,
                )
            })
            .collect::<Result<Vec<_>, _>>()?,
        option_patterns: remaining_patterns
            .into_iter()
            .enumerate()
            .filter(|(_, entry)| entry.starts_with('-'))
            .map(|(index, entry)| {
                compile_pattern(
                    entry,
                    &format!("option patterns in {description}"),
                    index + 2,
                )
            })
            .collect::<Result<Vec<_>, _>>()?,
    })
}

fn compile_patterns(entries: Vec<String>, description: &str) -> Result<Vec<Regex>, String> {
    entries
        .into_iter()
        .enumerate()
        .map(|(index, entry)| compile_pattern(entry, description, index + 1))
        .collect()
}

fn compile_option_names(entries: Vec<String>, description: &str) -> Result<Vec<String>, String> {
    entries
        .into_iter()
        .enumerate()
        .map(|(index, entry)| {
            let expanded = expand_env_placeholders(&entry);
            let trimmed = expanded.trim();
            if trimmed.is_empty() {
                return Err(format!(
                    "option {} in {} must be a non-empty string.",
                    index + 1,
                    description
                ));
            }
            if !trimmed.starts_with('-') {
                return Err(format!(
                    "option {} in {} must start with '-': {}",
                    index + 1,
                    description,
                    trimmed
                ));
            }
            Ok(trimmed.to_string())
        })
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

#[cfg(test)]
mod tests {
    use super::{discover_repo_root, parse_config};
    use std::fs;
    use std::path::Path;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn parse_config_keeps_command_rules_and_protected_environments() {
        let yaml = r#"
commandRules:
  - rule:
      - git
      - commit
      - --no-verify|-n
    reason: commit blocked
protectedEnvironments:
  - GIT_CONFIG_GLOBAL
optionsWithValue:
  - -m
"#;

        let config = parse_config(yaml, Path::new("/tmp/rules.yaml"), false).unwrap();

        assert_eq!(config.command_rules.len(), 1);
        assert_eq!(config.protected_environments.len(), 1);
        assert_eq!(config.options_with_value, vec!["-m".to_string()]);
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
    fn parse_config_rejects_non_option_options_with_value_entries() {
        let yaml = r#"
commandRules:
  - rule:
      - git
      - status
    reason: status blocked
optionsWithValue:
  - message
"#;

        let error = parse_config(yaml, Path::new("/tmp/rules.yaml"), false).unwrap_err();

        assert!(error.contains("optionsWithValue"));
        assert!(error.contains("must start with '-'"));
    }

    #[test]
    fn parse_config_allows_empty_optional_repo_config() {
        let config = parse_config("", Path::new("/tmp/repo-rules.yaml"), true).unwrap();

        assert!(config.command_rules.is_empty());
        assert!(config.protected_environments.is_empty());
        assert!(config.options_with_value.is_empty());
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
