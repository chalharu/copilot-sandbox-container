use crate::command::{CommandInvocation, EnvBinding};
use crate::config::{CompiledConfig, CompiledMatcher, CompiledRule, PROTECTED_ENVIRONMENT_REASON};
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
        let command_tokens = invocation.command_tokens();
        let option_tokens = invocation.option_tokens();
        if rule_matches(
            rule,
            &invocation.executable_basename,
            &command_tokens,
            &option_tokens,
            &invocation.args,
        ) {
            return Some(rule.reason.clone());
        }
    }
    None
}

fn rule_matches(
    rule: &CompiledRule,
    executable_basename: &str,
    command_tokens: &[String],
    option_tokens: &[String],
    raw_args: &[String],
) -> bool {
    if !rule.basename_pattern.is_match(executable_basename) {
        return false;
    }

    if command_tokens.len() < rule.command_patterns.len() {
        return false;
    }
    for (pattern, token) in rule.command_patterns.iter().zip(command_tokens.iter()) {
        if !pattern.is_match(token) {
            return false;
        }
    }

    if !rule
        .option_patterns
        .iter()
        .all(|pattern| option_tokens.iter().any(|token| pattern.is_match(token)))
    {
        return false;
    }

    if !rule
        .matcher_groups
        .iter()
        .all(|matcher| matcher_matches(matcher, command_tokens, option_tokens, raw_args))
    {
        return false;
    }

    argv_sequence_matches(&rule.argv_sequence_patterns, raw_args)
}

fn matcher_matches(
    matcher: &CompiledMatcher,
    command_tokens: &[String],
    option_tokens: &[String],
    raw_args: &[String],
) -> bool {
    match matcher {
        CompiledMatcher::Command(pattern) => command_tokens
            .first()
            .is_some_and(|token| pattern.is_match(token)),
        CompiledMatcher::Option(pattern) => {
            option_tokens.iter().any(|token| pattern.is_match(token))
        }
        CompiledMatcher::AllOf(matchers) => matchers
            .iter()
            .all(|matcher| matcher_matches(matcher, command_tokens, option_tokens, raw_args)),
        CompiledMatcher::AnyOf(matchers) => matchers
            .iter()
            .any(|matcher| matcher_matches(matcher, command_tokens, option_tokens, raw_args)),
        CompiledMatcher::SeqOf(patterns) => argv_sequence_matches(patterns, raw_args),
    }
}

fn argv_sequence_matches(patterns: &[regex::Regex], raw_args: &[String]) -> bool {
    if patterns.is_empty() {
        return true;
    }
    if patterns.len() > raw_args.len() {
        return false;
    }

    raw_args.windows(patterns.len()).any(|window| {
        patterns
            .iter()
            .zip(window.iter())
            .all(|(pattern, token)| pattern.is_match(token))
    })
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
    use crate::config::{CompiledConfig, CompiledMatcher, CompiledRule};
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
                    command_patterns: Vec::new(),
                    option_patterns: Vec::new(),
                    matcher_groups: vec![CompiledMatcher::AllOf(vec![
                        CompiledMatcher::Command(Regex::new("^(?:commit)$").unwrap()),
                        CompiledMatcher::AnyOf(vec![
                            CompiledMatcher::Option(Regex::new("^(?:--no-verify)$").unwrap()),
                            CompiledMatcher::Option(
                                Regex::new("^(?:-[A-Za-z0-9]*n[A-Za-z0-9]*)$").unwrap(),
                            ),
                        ]),
                    ])],
                    argv_sequence_patterns: Vec::new(),
                },
                CompiledRule {
                    reason: "hooks path blocked".to_string(),
                    basename_pattern: Regex::new("^(?:git)$").unwrap(),
                    command_patterns: Vec::new(),
                    option_patterns: Vec::new(),
                    matcher_groups: Vec::new(),
                    argv_sequence_patterns: vec![
                        Regex::new("^(?:-c)$").unwrap(),
                        Regex::new("^(?i:core\\.hookspath=.*)$").unwrap(),
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
        let attached_value_like_cluster_invocation = CommandInvocation::from_exec(
            "git",
            &[
                "git".to_string(),
                "commit".to_string(),
                "-mn".to_string(),
                "skip hooks".to_string(),
            ],
            Vec::new(),
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
            match_exec_rule(&config, &attached_value_like_cluster_invocation).as_deref(),
            Some("blocked")
        );
        assert_eq!(
            match_exec_rule(&config, &hooks_path_invocation).as_deref(),
            Some("hooks path blocked")
        );
    }
}
