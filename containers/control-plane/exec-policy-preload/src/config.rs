use regex::Regex;
use serde::Deserialize;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

pub const DEFAULT_RULES_PATH: &str =
    "/usr/local/share/control-plane/hooks/preToolUse/deny-rules.yaml";
const REPO_RULES_RELATIVE_PATH: &str = ".github/pre-tool-use-rules.yaml";

#[derive(Clone, Debug)]
pub struct CompiledPatternEntry {
    pub reason: String,
    pub regexes: Vec<Regex>,
}

#[derive(Debug, Deserialize)]
struct RawRuleGroup {
    #[serde(rename = "toolName")]
    tool_name: String,
    column: String,
    patterns: Vec<RawPatternEntry>,
}

#[derive(Debug, Deserialize)]
struct RawPatternEntry {
    patterns: Vec<String>,
    reason: String,
}

static BUNDLED_RULES: OnceLock<Result<Vec<CompiledPatternEntry>, String>> = OnceLock::new();

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
    PathBuf::from(DEFAULT_RULES_PATH)
}

pub fn load_rules(repo_root: Option<&Path>) -> Result<Vec<CompiledPatternEntry>, String> {
    let mut rules = load_bundled_rules()?.clone();
    if let Some(root) = repo_root {
        let repo_rules_path = root.join(REPO_RULES_RELATIVE_PATH);
        rules.extend(load_rule_file(&repo_rules_path, true)?);
    }
    Ok(rules)
}

fn load_bundled_rules() -> Result<&'static Vec<CompiledPatternEntry>, String> {
    match BUNDLED_RULES.get_or_init(|| load_rule_file(&resolve_rules_path(), false)) {
        Ok(rules) => Ok(rules),
        Err(error) => Err(error.clone()),
    }
}

fn load_rule_file(path: &Path, optional: bool) -> Result<Vec<CompiledPatternEntry>, String> {
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

fn parse_rule_groups(raw: &str, path: &Path) -> Result<Vec<CompiledPatternEntry>, String> {
    let groups: Vec<RawRuleGroup> = serde_yaml::from_str(raw).map_err(|error| {
        format!(
            "failed to parse exec policy rules at {}: {}",
            path.display(),
            error
        )
    })?;

    let mut entries = Vec::new();
    for (group_index, group) in groups.into_iter().enumerate() {
        validate_rule_group(&group, path, group_index)?;
        if group.tool_name != "bash" || group.column != "command" {
            continue;
        }

        for (pattern_index, pattern) in group.patterns.into_iter().enumerate() {
            entries.push(compile_pattern_entry(
                pattern,
                path,
                group_index,
                pattern_index,
            )?);
        }
    }

    Ok(entries)
}

fn validate_rule_group(
    group: &RawRuleGroup,
    path: &Path,
    group_index: usize,
) -> Result<(), String> {
    let description = format!("group {} in {}", group_index + 1, path.display());
    if group.tool_name.trim().is_empty() {
        return Err(format!("{description} must define a non-empty toolName."));
    }
    if group.column.trim().is_empty() {
        return Err(format!("{description} must define a non-empty column."));
    }
    if group.patterns.is_empty() {
        return Err(format!(
            "{description} must define patterns as a non-empty array."
        ));
    }
    Ok(())
}

fn compile_pattern_entry(
    pattern: RawPatternEntry,
    path: &Path,
    group_index: usize,
    pattern_index: usize,
) -> Result<CompiledPatternEntry, String> {
    let description = format!(
        "pattern {} in group {} of {}",
        pattern_index + 1,
        group_index + 1,
        path.display()
    );

    if pattern.reason.trim().is_empty() {
        return Err(format!("{description} must define a non-empty reason."));
    }
    if pattern.patterns.is_empty() || pattern.patterns.iter().any(|entry| entry.is_empty()) {
        return Err(format!(
            "{description} must define patterns as a non-empty array of strings."
        ));
    }

    let regexes = pattern
        .patterns
        .into_iter()
        .enumerate()
        .map(|(regex_index, entry)| {
            Regex::new(&entry).map_err(|error| {
                format!(
                    "invalid regex pattern {} in {}: {}",
                    regex_index + 1,
                    description,
                    error
                )
            })
        })
        .collect::<Result<Vec<_>, _>>()?;

    Ok(CompiledPatternEntry {
        reason: pattern.reason,
        regexes,
    })
}

#[cfg(test)]
mod tests {
    use super::{discover_repo_root, parse_rule_groups};
    use std::fs;
    use std::path::Path;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn parse_rule_groups_keeps_bash_command_entries_only() {
        let yaml = r#"
- toolName: bash
  column: command
  patterns:
    - patterns:
        - '^git push(?: .+)? -f(?: |$)'
      reason: force push blocked
- toolName: view
  column: path
  patterns:
    - patterns:
        - '.*'
      reason: ignored
"#;

        let rules = parse_rule_groups(yaml, Path::new("/tmp/rules.yaml")).unwrap();

        assert_eq!(rules.len(), 1);
        assert_eq!(rules[0].reason, "force push blocked");
        assert!(rules[0].regexes[0].is_match("git push -f origin HEAD"));
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
