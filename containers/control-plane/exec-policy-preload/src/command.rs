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

    pub fn command_tokens(&self) -> Vec<String> {
        command_tokens(&self.args)
    }

    pub fn option_tokens(&self) -> Vec<String> {
        option_tokens(&self.args)
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

fn command_tokens(args: &[String]) -> Vec<String> {
    let mut commands = Vec::new();

    for (index, token) in args.iter().enumerate() {
        if token == "--" {
            break;
        }
        if token == "-" || token.starts_with('-') {
            continue;
        }
        if index > 0 && previous_token_may_supply_value_to_command(&args[index - 1]) {
            continue;
        }
        commands.push(token.clone());
    }

    commands
}

fn option_tokens(args: &[String]) -> Vec<String> {
    let mut options = Vec::new();

    for token in args {
        if token == "--" {
            break;
        }
        if token == "-" || !token.starts_with('-') {
            continue;
        }
        push_unique(&mut options, token.clone());
    }

    options
}

fn previous_token_may_supply_value_to_command(token: &str) -> bool {
    is_standalone_short_option(token) || is_long_option_without_equals(token)
}

fn is_standalone_short_option(token: &str) -> bool {
    token.starts_with('-') && !token.starts_with("--") && token.chars().count() == 2
}

fn is_long_option_without_equals(token: &str) -> bool {
    token.starts_with("--") && token != "--" && !token.contains('=')
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

fn push_unique(tokens: &mut Vec<String>, token: String) {
    if !tokens.contains(&token) {
        tokens.push(token);
    }
}

#[cfg(test)]
mod tests {
    use super::{CommandInvocation, EnvBinding};

    #[test]
    fn keeps_raw_option_tokens_visible() {
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

        let options = invocation.option_tokens();

        assert!(invocation.command_tokens().contains(&"commit".to_string()));
        assert!(options.contains(&"-m".to_string()));
        assert!(options.contains(&"-n".to_string()));
        assert!(options.contains(&"--no-verify".to_string()));
    }

    #[test]
    fn keeps_clustered_short_options_intact() {
        let invocation = CommandInvocation::from_exec(
            "git",
            &[
                "git".to_string(),
                "commit".to_string(),
                "-nm".to_string(),
                "-mn".to_string(),
                "message".to_string(),
            ],
            Vec::new(),
        )
        .unwrap();

        let options = invocation.option_tokens();

        assert!(options.contains(&"-nm".to_string()));
        assert!(options.contains(&"-mn".to_string()));
    }

    #[test]
    fn filters_likely_option_values_out_of_command_tokens() {
        let invocation = CommandInvocation::from_exec(
            "git",
            &[
                "git".to_string(),
                "-c".to_string(),
                "core.hooksPath=/tmp/evil".to_string(),
                "--config-env".to_string(),
                "alias.status=foo".to_string(),
                "status".to_string(),
                "-m".to_string(),
                "message".to_string(),
            ],
            Vec::new(),
        )
        .unwrap();

        let commands = invocation.command_tokens();

        assert_eq!(commands, vec!["status".to_string()]);
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

        let options = invocation.option_tokens();

        assert!(options.contains(&"--no-verify".to_string()));
        assert!(!options.contains(&"--force".to_string()));
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
