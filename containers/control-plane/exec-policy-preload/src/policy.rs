use crate::command::{CommandInvocation, EnvBinding};
use crate::config::{CompiledConfig, CompiledRule, PROTECTED_ENVIRONMENT_REASON};
use std::ffi::OsStr;

pub fn match_hook_rule(
    config: &CompiledConfig,
    invocations: &[CommandInvocation],
) -> Option<String> {
    if protected_environment_overridden(&config.protected_environments, invocations) {
        return Some(PROTECTED_ENVIRONMENT_REASON.to_string());
    }

    config
        .command_rules
        .iter()
        .find_map(|rule| match_rule(rule, invocations))
}

pub fn match_exec_rule(config: &CompiledConfig, invocation: &CommandInvocation) -> Option<String> {
    if protected_environment_overridden(
        &config.protected_environments,
        std::slice::from_ref(invocation),
    ) {
        return Some(PROTECTED_ENVIRONMENT_REASON.to_string());
    }

    config
        .command_rules
        .iter()
        .find_map(|rule| match_rule(rule, std::slice::from_ref(invocation)))
}

fn match_rule(rule: &CompiledRule, invocations: &[CommandInvocation]) -> Option<String> {
    for invocation in invocations {
        let tokens = invocation.match_tokens();
        if rule_matches(rule, &tokens) {
            return Some(rule.reason.clone());
        }
    }
    None
}

fn rule_matches(rule: &CompiledRule, tokens: &[String]) -> bool {
    let Some(first_token) = tokens.first() else {
        return false;
    };
    if !rule.basename_pattern.is_match(first_token) {
        return false;
    }

    let (command_tokens, option_tokens): (Vec<_>, Vec<_>) = tokens
        .iter()
        .skip(1)
        .partition(|token| !token.starts_with('-'));

    if command_tokens.len() < rule.command_patterns.len() {
        return false;
    }
    for (pattern, token) in rule.command_patterns.iter().zip(command_tokens.iter()) {
        if !pattern.is_match(token) {
            return false;
        }
    }

    rule.option_patterns
        .iter()
        .all(|pattern| option_tokens.iter().any(|token| pattern.is_match(token)))
}

fn protected_environment_overridden(
    patterns: &[regex::Regex],
    invocations: &[CommandInvocation],
) -> bool {
    invocations.iter().any(|invocation| {
        invocation
            .env_bindings
            .iter()
            .any(|binding| protected_environment_binding_changed(patterns, binding))
    })
}

fn protected_environment_binding_changed(patterns: &[regex::Regex], binding: &EnvBinding) -> bool {
    patterns.iter().any(|regex| regex.is_match(&binding.name))
        && binding_differs_from_parent(binding)
}

fn binding_differs_from_parent(binding: &EnvBinding) -> bool {
    let current = std::env::var_os(&binding.name);
    match (binding.value.as_deref(), current) {
        (Some(value), Some(current)) => current != OsStr::new(value),
        (Some(_), None) => true,
        (None, Some(_)) => true,
        (None, None) => false,
    }
}

#[cfg(test)]
mod tests {
    use super::match_exec_rule;
    use crate::command::{CommandInvocation, EnvBinding};
    use crate::config::{CompiledConfig, CompiledRule};
    use regex::Regex;

    #[test]
    fn matches_command_rules_and_protected_environments() {
        unsafe {
            std::env::set_var("GIT_CONFIG_GLOBAL", "/managed");
        }
        let config = CompiledConfig {
            command_rules: vec![
                CompiledRule {
                    reason: "blocked".to_string(),
                    basename_pattern: Regex::new("^(?:git)$").unwrap(),
                    command_patterns: vec![Regex::new("^(?:commit)$").unwrap()],
                    option_patterns: vec![Regex::new("^(?:--no-verify|-n|-[^-]*n[^-]*)$").unwrap()],
                },
                CompiledRule {
                    reason: "hooks path blocked".to_string(),
                    basename_pattern: Regex::new("^(?:git)$").unwrap(),
                    command_patterns: Vec::new(),
                    option_patterns: vec![
                        Regex::new(
                            "^(?:--option-value=(?:-c|--config-env)=(?i:core\\.hookspath=.*))$",
                        )
                        .unwrap(),
                    ],
                },
            ],
            protected_environments: vec![Regex::new("^(?:GIT_CONFIG_GLOBAL)$").unwrap()],
        };
        let rule_invocation = CommandInvocation::from_exec(
            "git",
            &[
                "git".to_string(),
                "commit".to_string(),
                "--no-verify".to_string(),
            ],
            Vec::new(),
        )
        .unwrap();
        let reordered_rule_invocation = CommandInvocation::from_exec(
            "git",
            &[
                "git".to_string(),
                "commit".to_string(),
                "-nm".to_string(),
                "skip hooks".to_string(),
            ],
            Vec::new(),
        )
        .unwrap();
        let protected_env_invocation = CommandInvocation::from_exec(
            "git",
            &["git".to_string(), "status".to_string()],
            vec![EnvBinding {
                name: "GIT_CONFIG_GLOBAL".to_string(),
                value: Some("/tmp/evil".to_string()),
            }],
        )
        .unwrap();
        let managed_env_invocation = CommandInvocation::from_exec(
            "git",
            &["git".to_string(), "status".to_string()],
            vec![EnvBinding {
                name: "GIT_CONFIG_GLOBAL".to_string(),
                value: Some("/managed".to_string()),
            }],
        )
        .unwrap();
        let hooks_path_invocation = CommandInvocation::from_exec(
            "git",
            &[
                "git".to_string(),
                "-c".to_string(),
                "core.hooksPath=/tmp/evil".to_string(),
                "status".to_string(),
            ],
            Vec::new(),
        )
        .unwrap();

        assert_eq!(
            match_exec_rule(&config, &rule_invocation).as_deref(),
            Some("blocked")
        );
        assert_eq!(
            match_exec_rule(&config, &reordered_rule_invocation).as_deref(),
            Some("blocked")
        );
        assert!(
            match_exec_rule(&config, &protected_env_invocation)
                .as_deref()
                .unwrap()
                .contains("Protected environment overrides are blocked")
        );
        assert_eq!(match_exec_rule(&config, &managed_env_invocation), None);
        assert_eq!(
            match_exec_rule(&config, &hooks_path_invocation).as_deref(),
            Some("hooks path blocked")
        );
    }
}
