use crate::command::{CommandInvocation, EnvBinding};
use crate::config::{CompiledProtectedEnv, CompiledRule, CompiledRuleGroup};

pub fn match_hook_rule(
    groups: &[CompiledRuleGroup],
    tool_name: &str,
    column: &str,
    invocations: &[CommandInvocation],
) -> Option<String> {
    groups
        .iter()
        .filter(|group| group.tool_name == tool_name && group.column == column)
        .find_map(|group| match_group(group, invocations))
}

pub fn match_exec_rule(
    groups: &[CompiledRuleGroup],
    invocation: &CommandInvocation,
) -> Option<String> {
    groups
        .iter()
        .filter(|group| group.column == "command")
        .find_map(|group| match_group(group, std::slice::from_ref(invocation)))
}

fn match_group(group: &CompiledRuleGroup, invocations: &[CommandInvocation]) -> Option<String> {
    for invocation in invocations {
        let facts = invocation.facts(&group.normalization);
        for rule in &group.rules {
            if rule_matches(rule, &facts, &invocation.env_bindings) {
                return Some(rule.reason.clone());
            }
        }
    }
    None
}

fn rule_matches(rule: &CompiledRule, facts: &[String], env_bindings: &[EnvBinding]) -> bool {
    if !rule
        .all_patterns
        .iter()
        .all(|regex| facts.iter().any(|fact| regex.is_match(fact)))
    {
        return false;
    }

    if !rule.any_patterns.is_empty()
        && !rule
            .any_patterns
            .iter()
            .any(|regex| facts.iter().any(|fact| regex.is_match(fact)))
    {
        return false;
    }

    if rule.protected_env.is_empty() {
        return true;
    }

    rule.protected_env
        .iter()
        .any(|entry| protected_env_violated(entry, env_bindings))
}

fn protected_env_violated(entry: &CompiledProtectedEnv, env_bindings: &[EnvBinding]) -> bool {
    env_bindings.iter().any(|binding| {
        entry
            .name_patterns
            .iter()
            .any(|regex| regex.is_match(&binding.name))
            && match binding.value.as_deref() {
                Some(value) => {
                    entry.allow_value_patterns.is_empty()
                        || !entry
                            .allow_value_patterns
                            .iter()
                            .any(|regex| regex.is_match(value))
                }
                None => true,
            }
    })
}

#[cfg(test)]
mod tests {
    use super::match_exec_rule;
    use crate::command::{CommandInvocation, EnvBinding};
    use crate::config::{
        CompiledNormalization, CompiledProtectedEnv, CompiledRule, CompiledRuleGroup,
    };
    use regex::Regex;

    #[test]
    fn matches_generic_arg_rules_and_protected_env() {
        let groups = vec![CompiledRuleGroup {
            tool_name: "bash".to_string(),
            column: "command".to_string(),
            normalization: CompiledNormalization {
                option_value_matchers: vec![Regex::new("^-m$").unwrap()],
            },
            rules: vec![CompiledRule {
                reason: "blocked".to_string(),
                all_patterns: vec![Regex::new("^basename:git$").unwrap()],
                any_patterns: vec![Regex::new("^arg:--no-verify$").unwrap()],
                protected_env: vec![CompiledProtectedEnv {
                    name_patterns: vec![Regex::new("^GIT_CONFIG_GLOBAL$").unwrap()],
                    allow_value_patterns: vec![Regex::new("^/allowed$").unwrap()],
                }],
            }],
        }];
        let invocation = CommandInvocation::from_exec(
            "git",
            &[
                "git".to_string(),
                "commit".to_string(),
                "--no-verify".to_string(),
            ],
            vec![EnvBinding {
                name: "GIT_CONFIG_GLOBAL".to_string(),
                value: Some("/tmp/evil".to_string()),
            }],
        )
        .unwrap();

        let reason = match_exec_rule(&groups, &invocation);

        assert_eq!(reason.as_deref(), Some("blocked"));
    }
}
