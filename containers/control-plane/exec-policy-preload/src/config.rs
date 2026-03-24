use regex::Regex;
use serde::Deserialize;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

pub const DEFAULT_RULES_PATH: &str =
    "/usr/local/share/control-plane/hooks/preToolUse/deny-rules.yaml";
const REPO_RULES_RELATIVE_PATH: &str = ".github/pre-tool-use-rules.yaml";

#[derive(Clone, Debug, Default)]
pub struct CompiledNormalization {
    pub option_value_matchers: Vec<Regex>,
}

impl CompiledNormalization {
    pub fn matches_value_option(&self, token: &str) -> bool {
        self.option_value_matchers
            .iter()
            .any(|regex| regex.is_match(token))
    }
}

#[derive(Clone, Debug)]
pub struct CompiledRuleGroup {
    pub tool_name: String,
    pub column: String,
    pub normalization: CompiledNormalization,
    pub rules: Vec<CompiledRule>,
}

#[derive(Clone, Debug)]
pub struct CompiledRule {
    pub reason: String,
    pub all_patterns: Vec<Regex>,
    pub any_patterns: Vec<Regex>,
    pub protected_env: Vec<CompiledProtectedEnv>,
}

#[derive(Clone, Debug)]
pub struct CompiledProtectedEnv {
    pub name_patterns: Vec<Regex>,
    pub allow_value_patterns: Vec<Regex>,
}

#[derive(Debug, Default, Deserialize)]
struct RawNormalization {
    #[serde(default, rename = "optionValueMatchers")]
    option_value_matchers: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct RawRuleGroup {
    #[serde(rename = "toolName")]
    tool_name: String,
    column: String,
    #[serde(default)]
    normalization: RawNormalization,
    rules: Vec<RawRule>,
}

#[derive(Debug, Deserialize)]
struct RawRule {
    #[serde(default)]
    all: Vec<String>,
    #[serde(default)]
    any: Vec<String>,
    #[serde(default, rename = "protectedEnv")]
    protected_env: Vec<RawProtectedEnv>,
    reason: String,
}

#[derive(Debug, Deserialize)]
struct RawProtectedEnv {
    #[serde(default, rename = "namePatterns")]
    name_patterns: Vec<String>,
    #[serde(default, rename = "allowValuePatterns")]
    allow_value_patterns: Vec<String>,
}

static BUNDLED_RULES: OnceLock<Result<Vec<CompiledRuleGroup>, String>> = OnceLock::new();

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

pub fn load_rules(repo_root: Option<&Path>) -> Result<Vec<CompiledRuleGroup>, String> {
    let mut groups = load_bundled_rules()?.clone();
    if let Some(root) = repo_root {
        groups.extend(load_rule_file(&root.join(REPO_RULES_RELATIVE_PATH), true)?);
    }
    Ok(groups)
}

fn load_bundled_rules() -> Result<&'static Vec<CompiledRuleGroup>, String> {
    match BUNDLED_RULES.get_or_init(|| load_rule_file(&resolve_rules_path(), false)) {
        Ok(groups) => Ok(groups),
        Err(error) => Err(error.clone()),
    }
}

fn load_rule_file(path: &Path, optional: bool) -> Result<Vec<CompiledRuleGroup>, String> {
    let raw = match fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(error) if optional && error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(Vec::new());
        }
        Err(error) => {
            return Err(format!(
                "failed to read exec policy rules at {}: {}",
                path.display(),
                error
            ));
        }
    };

    parse_rule_groups(&raw, path)
}

fn parse_rule_groups(raw: &str, path: &Path) -> Result<Vec<CompiledRuleGroup>, String> {
    let groups: Vec<RawRuleGroup> = serde_yml::from_str(raw).map_err(|error| {
        format!(
            "failed to parse exec policy rules at {}: {}",
            path.display(),
            error
        )
    })?;

    groups
        .into_iter()
        .enumerate()
        .map(|(group_index, group)| compile_rule_group(group, path, group_index))
        .collect()
}

fn compile_rule_group(
    group: RawRuleGroup,
    path: &Path,
    group_index: usize,
) -> Result<CompiledRuleGroup, String> {
    let description = format!("group {} in {}", group_index + 1, path.display());
    if group.tool_name.trim().is_empty() {
        return Err(format!("{description} must define a non-empty toolName."));
    }
    if group.column.trim().is_empty() {
        return Err(format!("{description} must define a non-empty column."));
    }
    if group.rules.is_empty() {
        return Err(format!(
            "{description} must define rules as a non-empty array."
        ));
    }

    Ok(CompiledRuleGroup {
        tool_name: group.tool_name,
        column: group.column,
        normalization: CompiledNormalization {
            option_value_matchers: compile_patterns(
                group.normalization.option_value_matchers,
                &format!("normalization.optionValueMatchers in {description}"),
            )?,
        },
        rules: group
            .rules
            .into_iter()
            .enumerate()
            .map(|(rule_index, rule)| compile_rule(rule, path, group_index, rule_index))
            .collect::<Result<Vec<_>, _>>()?,
    })
}

fn compile_rule(
    rule: RawRule,
    path: &Path,
    group_index: usize,
    rule_index: usize,
) -> Result<CompiledRule, String> {
    let description = format!(
        "rule {} in group {} of {}",
        rule_index + 1,
        group_index + 1,
        path.display()
    );
    if rule.reason.trim().is_empty() {
        return Err(format!("{description} must define a non-empty reason."));
    }
    if rule.all.is_empty() && rule.any.is_empty() && rule.protected_env.is_empty() {
        return Err(format!(
            "{description} must define at least one of all, any, or protectedEnv."
        ));
    }

    Ok(CompiledRule {
        reason: rule.reason,
        all_patterns: compile_patterns(rule.all, &format!("all in {description}"))?,
        any_patterns: compile_patterns(rule.any, &format!("any in {description}"))?,
        protected_env: rule
            .protected_env
            .into_iter()
            .enumerate()
            .map(|(env_index, entry)| compile_protected_env(entry, &description, env_index))
            .collect::<Result<Vec<_>, _>>()?,
    })
}

fn compile_protected_env(
    entry: RawProtectedEnv,
    rule_description: &str,
    env_index: usize,
) -> Result<CompiledProtectedEnv, String> {
    let description = format!("protectedEnv {} in {rule_description}", env_index + 1);
    if entry.name_patterns.is_empty() {
        return Err(format!(
            "{description} must define namePatterns as a non-empty array."
        ));
    }

    Ok(CompiledProtectedEnv {
        name_patterns: compile_patterns(
            entry.name_patterns,
            &format!("namePatterns in {description}"),
        )?,
        allow_value_patterns: compile_patterns(
            entry.allow_value_patterns,
            &format!("allowValuePatterns in {description}"),
        )?,
    })
}

fn compile_patterns(entries: Vec<String>, description: &str) -> Result<Vec<Regex>, String> {
    entries
        .into_iter()
        .enumerate()
        .map(|(index, entry)| {
            if entry.is_empty() {
                return Err(format!(
                    "pattern {} in {} must be a non-empty string.",
                    index + 1,
                    description
                ));
            }
            let expanded = expand_env_placeholders(&entry);
            Regex::new(&expanded).map_err(|error| {
                format!(
                    "invalid regex pattern {} in {}: {}",
                    index + 1,
                    description,
                    error
                )
            })
        })
        .collect()
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
    use super::{discover_repo_root, parse_rule_groups};
    use std::fs;
    use std::path::Path;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn parse_rule_groups_keeps_generic_rule_groups() {
        let yaml = r#"
- toolName: bash
  column: command
  normalization:
    optionValueMatchers:
      - '^-m$'
  rules:
    - all:
        - '^basename:git$'
        - '^arg:commit$'
      any:
        - '^arg:--no-verify$'
        - '^arg:-n$'
      reason: commit blocked
"#;

        let groups = parse_rule_groups(yaml, Path::new("/tmp/rules.yaml")).unwrap();

        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].rules.len(), 1);
        assert_eq!(groups[0].normalization.option_value_matchers.len(), 1);
    }

    #[test]
    fn parse_rule_groups_expands_env_placeholders() {
        unsafe {
            std::env::set_var("CONTROL_PLANE_TEST_ALLOWED_PATH", "/tmp/allowed");
        }
        let yaml = r#"
- toolName: bash
  column: command
  rules:
    - protectedEnv:
        - namePatterns:
            - '^GIT_CONFIG_GLOBAL$'
          allowValuePatterns:
            - '^${CONTROL_PLANE_TEST_ALLOWED_PATH}$'
      reason: env blocked
"#;

        let groups = parse_rule_groups(yaml, Path::new("/tmp/rules.yaml")).unwrap();

        assert!(
            groups[0].rules[0].protected_env[0].allow_value_patterns[0].is_match("/tmp/allowed")
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
