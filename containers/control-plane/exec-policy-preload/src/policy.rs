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

pub fn match_file_access_rule(
    config: &CompiledConfig,
    process_names: &[&str],
    path: &str,
) -> Option<String> {
    config.file_access_rules.iter().find_map(|rule| {
        if rule.path == path && !file_access_allowed(&rule.allowed_executables, process_names) {
            return Some(rule.reason.clone());
        }

        None
    })
}

fn match_rule(rule: &CompiledRule, invocations: &[CommandInvocation]) -> Option<String> {
    for invocation in invocations {
        if rule_matches(rule, invocation) {
            return Some(rule.reason.clone());
        }
    }
    None
}

fn rule_matches(rule: &CompiledRule, invocation: &CommandInvocation) -> bool {
    rule.pattern.is_match(&invocation.normalized_stream())
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

fn file_access_allowed(allowed_executables: &[String], process_names: &[&str]) -> bool {
    allowed_executables
        .iter()
        .any(|allowed| process_names.iter().any(|name| name == allowed))
}

#[cfg(test)]
mod tests {
    use super::{match_exec_rule, match_file_access_rule};
    use crate::command::{CommandInvocation, EnvBinding};
    use crate::config::{CompiledConfig, CompiledFileAccessRule, CompiledRule};
    use regex::{Regex, bytes::Regex as BytesRegex};

    #[test]
    fn matches_command_rules_and_protected_environments() {
        unsafe {
            std::env::set_var("GIT_CONFIG_GLOBAL", "/managed");
        }
        let config = CompiledConfig {
            command_rules: vec![
                CompiledRule {
                    reason: "blocked".to_string(),
                    pattern: BytesRegex::new(
                        r"git(?:\x00[^\x00]+)*\x00commit(?:\x00[^\x00]+)*\x00(?:--no-verify|-[A-Za-z0-9]*n[A-Za-z0-9]*)(?:\x00[^\x00]+)*",
                    )
                    .unwrap(),
                },
                CompiledRule {
                    reason: "hooks path blocked".to_string(),
                    pattern: BytesRegex::new(
                        r"git(?:\x00[^\x00]+)*\x00(?:-c\x00(?i:core\.hookspath=.*)|-c(?i:core\.hookspath=.*))(?:\x00[^\x00]+)*",
                    )
                    .unwrap(),
                },
            ],
            protected_environments: vec![Regex::new("^(?:GIT_CONFIG_GLOBAL)$").unwrap()],
            file_access_rules: vec![
                CompiledFileAccessRule {
                    path: "/run/secrets/dockerhub-token".to_string(),
                    reason: "dockerhub token blocked".to_string(),
                    allowed_executables: vec![
                        "podman".to_string(),
                        "control-plane-podman".to_string(),
                    ],
                },
                CompiledFileAccessRule {
                    path: "/home/copilot/.config/gh/hosts.yml".to_string(),
                    reason: "hosts file blocked".to_string(),
                    allowed_executables: vec!["gh".to_string()],
                },
            ],
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
        assert_eq!(
            match_file_access_rule(&config, &["bash"], "/run/secrets/dockerhub-token").as_deref(),
            Some("dockerhub token blocked")
        );
        assert_eq!(
            match_file_access_rule(
                &config,
                &["bash", "control-plane-podman"],
                "/run/secrets/dockerhub-token",
            ),
            None
        );
        assert_eq!(
            match_file_access_rule(&config, &["gh"], "/home/copilot/.config/gh/hosts.yml"),
            None
        );
        assert_eq!(
            match_file_access_rule(&config, &["bash"], "/home/copilot/.config/gh/hosts.yml")
                .as_deref(),
            Some("hosts file blocked")
        );
    }
}
