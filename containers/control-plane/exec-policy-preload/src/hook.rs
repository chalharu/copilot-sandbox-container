use crate::config;
use crate::policy;
use crate::shell;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::path::PathBuf;

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct HookDecision {
    #[serde(rename = "permissionDecision")]
    pub permission_decision: String,
    #[serde(rename = "permissionDecisionReason")]
    pub permission_decision_reason: String,
}

#[derive(Debug, Deserialize)]
struct HookInput {
    cwd: Option<String>,
    #[serde(rename = "toolName")]
    tool_name: Option<String>,
    #[serde(rename = "toolArgs")]
    tool_args: Option<Value>,
}

pub fn evaluate_pre_tool_use(raw_input: &str) -> Result<Option<HookDecision>, String> {
    let input = parse_hook_input(raw_input)?;
    let tool_name = input.tool_name.unwrap_or_default();
    if tool_name != "bash" {
        return Ok(None);
    }

    let cwd = input
        .cwd
        .filter(|cwd| !cwd.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
    let repo_root = config::discover_repo_root(&cwd).unwrap_or(cwd);
    let rules = config::load_rules(Some(repo_root.as_path()))?;
    let tool_args = parse_tool_args(input.tool_args)?;

    let Some(command) = tool_args.get("command").and_then(Value::as_str) else {
        return Ok(None);
    };
    let invocations = shell::parse_shell_command(command);
    let matched_reason = policy::match_hook_rule(&rules, &invocations);

    Ok(matched_reason.map(|reason| HookDecision {
        permission_decision: "deny".to_string(),
        permission_decision_reason: reason,
    }))
}

fn parse_hook_input(raw_input: &str) -> Result<HookInput, String> {
    if raw_input.trim().is_empty() {
        return Ok(HookInput {
            cwd: None,
            tool_name: None,
            tool_args: None,
        });
    }

    serde_json::from_str(raw_input)
        .map_err(|error| format!("Failed to parse preToolUse hook input JSON: {error}"))
}

fn parse_tool_args(tool_args: Option<Value>) -> Result<Map<String, Value>, String> {
    match tool_args {
        None | Some(Value::Null) => Ok(Map::new()),
        Some(Value::String(raw)) => {
            let value: Value = serde_json::from_str(&raw)
                .map_err(|error| format!("Failed to parse preToolUse toolArgs JSON: {error}"))?;
            match value {
                Value::Object(map) => Ok(map),
                _ => Err("preToolUse toolArgs must decode to a JSON object.".to_string()),
            }
        }
        Some(Value::Object(map)) => Ok(map),
        Some(_) => {
            Err("preToolUse toolArgs must be a JSON object or JSON object string.".to_string())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{HookDecision, evaluate_pre_tool_use};
    use serde_json::json;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::time::{SystemTime, UNIX_EPOCH};

    fn setup_repo(prefix: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let repo = std::env::temp_dir().join(format!("{prefix}-{unique}"));
        fs::create_dir_all(repo.join(".git")).unwrap();
        fs::create_dir_all(repo.join(".github")).unwrap();
        repo
    }

    fn hook_input(repo: &Path, command: &str, tool_name: &str) -> String {
        json!({
            "cwd": repo,
            "toolName": tool_name,
            "toolArgs": json!({ "command": command }).to_string(),
        })
        .to_string()
    }

    #[test]
    fn denies_git_commit_no_verify_variants() {
        let repo = setup_repo("pre-tool-use-commit");

        let long_form = evaluate_pre_tool_use(&hook_input(
            &repo,
            "git commit --no-verify -m \"skip hooks\"",
            "bash",
        ))
        .unwrap();
        let short_form = evaluate_pre_tool_use(&hook_input(
            &repo,
            "git commit -n -m \"skip hooks\"",
            "bash",
        ))
        .unwrap();
        let stacked_short_form = evaluate_pre_tool_use(&hook_input(
            &repo,
            "git commit -a -n -m \"skip hooks\"",
            "bash",
        ))
        .unwrap();
        let clustered_short_form =
            evaluate_pre_tool_use(&hook_input(&repo, "git commit -nm \"skip hooks\"", "bash"))
                .unwrap();
        let attached_cluster_form =
            evaluate_pre_tool_use(&hook_input(&repo, "git commit -mn", "bash")).unwrap();

        assert_eq!(
            long_form,
            Some(HookDecision {
                permission_decision: "deny".to_string(),
                permission_decision_reason: "git commit --no-verify is blocked by control-plane policy. Run git commit without --no-verify so hooks stay enforced.".to_string(),
            })
        );
        assert_eq!(short_form, long_form);
        assert_eq!(stacked_short_form, long_form);
        assert_eq!(clustered_short_form, long_form);
        assert_eq!(attached_cluster_form, long_form);
    }

    #[test]
    fn denies_push_force_and_no_verify_but_allows_force_with_lease() {
        let repo = setup_repo("pre-tool-use-push");

        let no_verify = evaluate_pre_tool_use(&hook_input(
            &repo,
            "git push origin HEAD --no-verify",
            "bash",
        ))
        .unwrap()
        .unwrap();
        let force = evaluate_pre_tool_use(&hook_input(
            &repo,
            "FOO=1 git -C . push -f origin HEAD",
            "bash",
        ))
        .unwrap()
        .unwrap();
        let force_with_lease = evaluate_pre_tool_use(&hook_input(
            &repo,
            "git push --force-with-lease origin HEAD",
            "bash",
        ))
        .unwrap();

        assert!(
            no_verify
                .permission_decision_reason
                .contains("git push --no-verify")
        );
        assert!(
            force
                .permission_decision_reason
                .contains("Force pushes are blocked")
        );
        assert_eq!(force_with_lease, None);
    }

    #[test]
    fn denies_git_config_environment_overrides() {
        let repo = setup_repo("pre-tool-use-env");

        let decision = evaluate_pre_tool_use(&hook_input(
            &repo,
            "GIT_CONFIG_GLOBAL=/tmp/evil git status --short",
            "bash",
        ))
        .unwrap()
        .unwrap();

        assert!(
            decision
                .permission_decision_reason
                .contains("Protected environment overrides")
        );
    }

    #[test]
    fn denies_git_hooks_path_config_overrides() {
        let repo = setup_repo("pre-tool-use-hooks-path");

        let dash_c = evaluate_pre_tool_use(&hook_input(
            &repo,
            "git -c core.hooksPath=/tmp/evil commit -m \"skip hooks\"",
            "bash",
        ))
        .unwrap()
        .unwrap();
        let config_env = evaluate_pre_tool_use(&hook_input(
            &repo,
            "HOOKS=/tmp/evil git --config-env=core.hooksPath=HOOKS status --short",
            "bash",
        ))
        .unwrap()
        .unwrap();

        assert!(
            dash_c
                .permission_decision_reason
                .contains("core.hooksPath overrides")
        );
        assert_eq!(
            config_env.permission_decision_reason,
            dash_c.permission_decision_reason
        );
    }

    #[test]
    fn allows_safe_git_commands_and_non_bash_tools() {
        let repo = setup_repo("pre-tool-use-allow");

        let safe_git =
            evaluate_pre_tool_use(&hook_input(&repo, "git push -n origin HEAD", "bash")).unwrap();
        let non_bash =
            evaluate_pre_tool_use(&hook_input(&repo, "git push -f origin HEAD", "view")).unwrap();

        assert_eq!(safe_git, None);
        assert_eq!(non_bash, None);
    }

    #[test]
    fn ignores_tokens_after_double_dash() {
        let repo = setup_repo("pre-tool-use-double-dash");

        let double_dash = evaluate_pre_tool_use(&hook_input(
            &repo,
            "git commit --amend -- --no-verify",
            "bash",
        ))
        .unwrap();

        assert_eq!(double_dash, None);
    }

    #[test]
    fn unwraps_shell_wrappers_before_matching() {
        let repo = setup_repo("pre-tool-use-wrapper");

        let decision = evaluate_pre_tool_use(&hook_input(
            &repo,
            "bash -lc \"git commit --no-verify -m \\\"skip\\\"\"",
            "bash",
        ))
        .unwrap()
        .unwrap();

        assert!(
            decision
                .permission_decision_reason
                .contains("git commit --no-verify")
        );
    }

    #[test]
    fn merges_repo_local_rules() {
        let repo = setup_repo("pre-tool-use-repo-local");
        fs::write(
            repo.join(".github/pre-tool-use-rules.yaml"),
            r#"
commandRules:
  - rule: 'git(?:\x00[^\x00]+)*\x00status(?:\x00[^\x00]+)*\x00--short(?:\x00[^\x00]+)*'
    reason: repo-local policy
"#,
        )
        .unwrap();

        let decision = evaluate_pre_tool_use(&hook_input(&repo, "git status --short", "bash"))
            .unwrap()
            .unwrap();

        assert_eq!(decision.permission_decision_reason, "repo-local policy");
    }

    #[test]
    fn rejects_invalid_repo_local_rules() {
        let repo = setup_repo("pre-tool-use-invalid");
        fs::write(
            repo.join(".github/pre-tool-use-rules.yaml"),
            r#"
commandRules:
  - rule: '['
    reason: invalid
"#,
        )
        .unwrap();

        let error = evaluate_pre_tool_use(&hook_input(&repo, "git status", "bash")).unwrap_err();

        assert!(error.contains("invalid regex pattern"));
    }

    #[test]
    fn rejects_repo_local_rules_with_removed_group_fields() {
        let repo = setup_repo("pre-tool-use-removed-group-fields");
        fs::write(
            repo.join(".github/pre-tool-use-rules.yaml"),
            r#"
commandRules:
  - toolName: bash
    rule:
      git
    reason: invalid
"#,
        )
        .unwrap();

        let error = evaluate_pre_tool_use(&hook_input(&repo, "git status", "bash")).unwrap_err();

        assert!(error.contains("unknown field"));
        assert!(error.contains("toolName"));
    }
}
