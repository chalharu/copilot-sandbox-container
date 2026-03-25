use std::path::Path;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EnvBinding {
    pub name: String,
    pub value: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CommandInvocation {
    pub executable: String,
    pub executable_basename: String,
    pub raw_tokens: Vec<String>,
    pub args: Vec<String>,
    pub env_bindings: Vec<EnvBinding>,
}

impl CommandInvocation {
    pub fn from_tokens(tokens: &[String], env_bindings: Vec<EnvBinding>) -> Option<Self> {
        let executable = tokens.first()?.clone();
        Some(Self {
            executable_basename: basename(&executable).to_string(),
            executable,
            raw_tokens: tokens.to_vec(),
            args: tokens.get(1..).unwrap_or(&[]).to_vec(),
            env_bindings,
        })
    }

    pub fn from_exec(path: &str, argv: &[String], env_bindings: Vec<EnvBinding>) -> Option<Self> {
        let executable = if path.is_empty() {
            argv.first()?.clone()
        } else {
            path.to_string()
        };
        let raw_tokens = if argv.is_empty() {
            vec![executable.clone()]
        } else {
            argv.to_vec()
        };

        Some(Self {
            executable_basename: basename(&executable).to_string(),
            executable,
            args: raw_tokens.get(1..).unwrap_or(&[]).to_vec(),
            raw_tokens,
            env_bindings,
        })
    }

    pub fn match_tokens(&self, options_with_value: &[String]) -> Vec<String> {
        let option_value_tokens = option_value_tokens(&self.args, options_with_value);
        let mut tokens = Vec::with_capacity(self.args.len() + 1 + option_value_tokens.len());
        tokens.push(self.executable_basename.clone());
        tokens.extend(matchable_args(&self.args, options_with_value));
        tokens.extend(option_value_tokens);
        tokens
    }

    pub fn unwrap_env_wrapper(&self) -> Option<Self> {
        if self.executable_basename != "env" {
            return None;
        }

        let prefix = strip_env_wrapper_prefix(&self.args)?;
        let base_env = if prefix.clear_environment {
            Vec::new()
        } else {
            self.env_bindings.clone()
        };
        let effective_env = merge_env_bindings(&base_env, &prefix.env_bindings);
        Self::from_tokens(&prefix.invocation_tokens, effective_env)
    }
}

pub fn merge_env_bindings(parent: &[EnvBinding], child: &[EnvBinding]) -> Vec<EnvBinding> {
    let mut merged = parent.to_vec();
    for binding in child {
        if let Some(index) = merged.iter().position(|entry| entry.name == binding.name) {
            merged[index] = binding.clone();
        } else {
            merged.push(binding.clone());
        }
    }
    merged
}

const OPTION_VALUE_TOKEN_PREFIX: &str = "--option-value=";

fn matchable_args(args: &[String], options_with_value: &[String]) -> Vec<String> {
    let mut matchable = Vec::new();
    let mut index = 0;

    while index < args.len() {
        let token = &args[index];
        if token == "--" {
            break;
        }

        if token == "-" || !token.starts_with('-') {
            matchable.push(token.clone());
            index += 1;
            continue;
        }

        if token.starts_with("--") {
            let option_name = token
                .split_once('=')
                .map(|(name, _)| name)
                .unwrap_or(token.as_str());
            let consumes_next =
                !token.contains('=') && option_takes_value(option_name, options_with_value);
            if token.contains('=') && option_takes_value(option_name, options_with_value) {
                matchable.push(option_name.to_string());
            } else {
                matchable.push(token.clone());
            }
            index += if consumes_next { 2 } else { 1 };
            continue;
        }

        let (sanitized_token, consumes_next) = sanitize_short_token(token, options_with_value);
        matchable.push(sanitized_token);

        index += 1;
        if consumes_next {
            index += 1;
        }
    }

    matchable
}

fn option_value_tokens(args: &[String], options_with_value: &[String]) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut index = 0;

    while index < args.len() {
        let token = &args[index];
        if token == "--" {
            break;
        }

        if token == "-" || !token.starts_with('-') {
            index += 1;
            continue;
        }

        if token.starts_with("--") {
            let (option_name, attached_value) = token
                .split_once('=')
                .map(|(name, value)| (name, Some(value)))
                .unwrap_or((token.as_str(), None));
            if option_takes_value(option_name, options_with_value) {
                if let Some(value) =
                    attached_value.or_else(|| args.get(index + 1).map(|value| value.as_str()))
                {
                    push_option_value_token(&mut tokens, option_name, value);
                }
                index += if attached_value.is_none() && args.get(index + 1).is_some() {
                    2
                } else {
                    1
                };
            } else {
                index += 1;
            }
            continue;
        }

        let analysis = analyze_short_token(token, options_with_value);
        if let Some(option_name) = analysis.value_option.as_deref()
            && let Some(value) = analysis
                .attached_value
                .as_deref()
                .or_else(|| args.get(index + 1).map(|value| value.as_str()))
        {
            push_option_value_token(&mut tokens, option_name, value);
        }
        index += 1;
        if analysis.consumes_next {
            index += 1;
        }
    }

    tokens
}

fn push_option_value_token(tokens: &mut Vec<String>, option_name: &str, value: &str) {
    let token = format!("{OPTION_VALUE_TOKEN_PREFIX}{option_name}={value}");
    if !tokens.contains(&token) {
        tokens.push(token);
    }
}

struct ShortTokenAnalysis {
    match_token: String,
    value_option: Option<String>,
    consumes_next: bool,
    attached_value: Option<String>,
}

fn analyze_short_token(token: &str, options_with_value: &[String]) -> ShortTokenAnalysis {
    let chars: Vec<char> = token.chars().collect();
    if chars.len() <= 1 {
        return ShortTokenAnalysis {
            match_token: token.to_string(),
            value_option: None,
            consumes_next: false,
            attached_value: None,
        };
    }

    let mut match_token = String::from("-");
    let mut value_option = None;
    let mut consumes_next = false;
    let mut attached_value = None;
    for short_index in 1..chars.len() {
        let short_flag = chars[short_index];
        match_token.push(short_flag);
        let option_name = format!("-{short_flag}");
        if option_takes_value(&option_name, options_with_value) {
            value_option = Some(option_name);
            consumes_next = short_index == chars.len() - 1;
            if !consumes_next {
                attached_value = Some(chars[short_index + 1..].iter().collect());
            }
            break;
        }
    }

    ShortTokenAnalysis {
        match_token,
        value_option,
        consumes_next,
        attached_value,
    }
}

fn sanitize_short_token(token: &str, options_with_value: &[String]) -> (String, bool) {
    let analysis = analyze_short_token(token, options_with_value);
    (analysis.match_token, analysis.consumes_next)
}

fn option_takes_value(token: &str, options_with_value: &[String]) -> bool {
    options_with_value.iter().any(|entry| entry == token)
}

struct EnvWrapperPrefix {
    env_bindings: Vec<EnvBinding>,
    clear_environment: bool,
    invocation_tokens: Vec<String>,
}

fn strip_env_wrapper_prefix(args: &[String]) -> Option<EnvWrapperPrefix> {
    let mut index = 0;
    let mut env_bindings = Vec::new();
    let mut clear_environment = false;

    while index < args.len() {
        let token = &args[index];
        if token == "-i" || token == "--ignore-environment" {
            clear_environment = true;
            index += 1;
            continue;
        }
        if token == "-u" || token == "--unset" {
            let name = args.get(index + 1)?.clone();
            env_bindings.push(EnvBinding { name, value: None });
            index += 2;
            continue;
        }
        if token == "-C" || token == "--chdir" {
            index += 2;
            continue;
        }
        if let Some(binding) = parse_environment_assignment(token) {
            env_bindings.push(binding);
            index += 1;
            continue;
        }
        if token.starts_with('-') {
            index += 1;
            continue;
        }
        break;
    }

    let invocation_tokens = args.get(index..)?.to_vec();
    if invocation_tokens.is_empty() {
        return None;
    }

    Some(EnvWrapperPrefix {
        env_bindings,
        clear_environment,
        invocation_tokens,
    })
}

fn parse_environment_assignment(token: &str) -> Option<EnvBinding> {
    let (name, value) = token.split_once('=')?;
    let mut chars = name.chars();
    let first = chars.next()?;
    if !(first == '_' || first.is_ascii_alphabetic()) {
        return None;
    }
    if !chars.all(|char| char == '_' || char.is_ascii_alphanumeric()) {
        return None;
    }

    Some(EnvBinding {
        name: name.to_string(),
        value: Some(value.to_string()),
    })
}

fn basename(value: &str) -> &str {
    Path::new(value)
        .file_name()
        .and_then(|entry| entry.to_str())
        .unwrap_or(value)
}

#[cfg(test)]
mod tests {
    use super::{CommandInvocation, EnvBinding};

    fn value_options(entries: &[&str]) -> Vec<String> {
        entries.iter().map(|entry| entry.to_string()).collect()
    }

    #[test]
    fn skips_option_values_and_keeps_flags() {
        let invocation = CommandInvocation::from_exec(
            "git",
            &[
                "git".to_string(),
                "commit".to_string(),
                "-m".to_string(),
                "-n".to_string(),
                "--no-verify".to_string(),
            ],
            Vec::new(),
        )
        .unwrap();

        let tokens = invocation.match_tokens(&value_options(&["-m"]));

        assert_eq!(tokens[0], "git");
        assert!(tokens.contains(&"commit".to_string()));
        assert!(tokens.contains(&"-m".to_string()));
        assert!(tokens.contains(&"--no-verify".to_string()));
        assert!(!tokens.contains(&"-n".to_string()));
    }

    #[test]
    fn handles_clustered_short_flags_with_value_taking_option() {
        let invocation = CommandInvocation::from_exec(
            "git",
            &[
                "git".to_string(),
                "commit".to_string(),
                "-nm".to_string(),
                "message".to_string(),
            ],
            Vec::new(),
        )
        .unwrap();

        let tokens = invocation.match_tokens(&value_options(&["-m"]));

        assert!(tokens.contains(&"-nm".to_string()));
        assert!(!tokens.contains(&"message".to_string()));
    }

    #[test]
    fn trims_attached_values_from_clustered_short_options() {
        let invocation = CommandInvocation::from_exec(
            "git",
            &[
                "git".to_string(),
                "commit".to_string(),
                "-mn".to_string(),
                "--no-verify".to_string(),
            ],
            Vec::new(),
        )
        .unwrap();

        let tokens = invocation.match_tokens(&value_options(&["-m"]));

        assert!(tokens.contains(&"-m".to_string()));
        assert!(!tokens.contains(&"-mn".to_string()));
        assert!(tokens.contains(&"--no-verify".to_string()));
    }

    #[test]
    fn stops_emitting_tokens_after_double_dash() {
        let invocation = CommandInvocation::from_exec(
            "git",
            &[
                "git".to_string(),
                "commit".to_string(),
                "--no-verify".to_string(),
                "--".to_string(),
                "--force".to_string(),
            ],
            Vec::new(),
        )
        .unwrap();

        let tokens = invocation.match_tokens(&value_options(&["--message"]));

        assert!(tokens.contains(&"--no-verify".to_string()));
        assert!(!tokens.contains(&"--force".to_string()));
    }

    #[test]
    fn emits_option_value_tokens_for_separate_and_long_values() {
        let invocation = CommandInvocation::from_exec(
            "git",
            &[
                "git".to_string(),
                "--config-env=credential.helper=HELPER".to_string(),
                "commit".to_string(),
                "-m".to_string(),
                "ship it".to_string(),
            ],
            Vec::new(),
        )
        .unwrap();

        let tokens = invocation.match_tokens(&value_options(&["-m", "--config-env"]));

        assert!(tokens.contains(&"commit".to_string()));
        assert!(tokens.contains(&"-m".to_string()));
        assert!(tokens.contains(&"--config-env".to_string()));
        assert!(tokens.contains(&"--option-value=-m=ship it".to_string()));
        assert!(
            tokens.contains(&"--option-value=--config-env=credential.helper=HELPER".to_string())
        );
    }

    #[test]
    fn emits_option_value_tokens_for_attached_short_values() {
        let invocation = CommandInvocation::from_exec(
            "git",
            &[
                "git".to_string(),
                "-ccore.hooksPath=/tmp/evil".to_string(),
                "status".to_string(),
            ],
            Vec::new(),
        )
        .unwrap();

        let tokens = invocation.match_tokens(&value_options(&["-c"]));

        assert!(tokens.contains(&"-c".to_string()));
        assert!(tokens.contains(&"status".to_string()));
        assert!(tokens.contains(&"--option-value=-c=core.hooksPath=/tmp/evil".to_string()));
    }

    #[test]
    fn emits_option_value_tokens_for_clustered_short_values() {
        let invocation = CommandInvocation::from_exec(
            "git",
            &[
                "git".to_string(),
                "commit".to_string(),
                "-nm".to_string(),
                "message".to_string(),
            ],
            Vec::new(),
        )
        .unwrap();

        let tokens = invocation.match_tokens(&value_options(&["-m"]));

        assert!(tokens.contains(&"commit".to_string()));
        assert!(tokens.contains(&"-nm".to_string()));
        assert!(tokens.contains(&"--option-value=-m=message".to_string()));
        assert!(!tokens.contains(&"message".to_string()));
    }

    #[test]
    fn unwraps_env_wrapper_into_nested_invocation() {
        let invocation = CommandInvocation::from_exec(
            "env",
            &[
                "env".to_string(),
                "GIT_CONFIG_GLOBAL=/tmp/evil".to_string(),
                "git".to_string(),
                "status".to_string(),
                "--short".to_string(),
            ],
            vec![EnvBinding {
                name: "GIT_CONFIG_GLOBAL".to_string(),
                value: Some("/managed".to_string()),
            }],
        )
        .unwrap();

        let nested = invocation.unwrap_env_wrapper().unwrap();

        assert_eq!(nested.executable_basename, "git");
        assert!(nested.args.contains(&"status".to_string()));
        assert!(
            nested
                .env_bindings
                .iter()
                .any(|binding| binding.name == "GIT_CONFIG_GLOBAL"
                    && binding.value.as_deref() == Some("/tmp/evil"))
        );
    }
}
