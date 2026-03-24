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

    pub fn normalized_tokens(&self) -> Vec<String> {
        let mut tokens = Vec::with_capacity(self.args.len() + 1);
        tokens.push(self.executable_basename.clone());
        tokens.extend(normalize_args(&self.args));
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

// Keep value-taking option handling inside the parser so the YAML stays focused on policy.
const OPTIONS_WITH_VALUE: &[&str] = &[
    "-c",
    "-C",
    "-F",
    "-m",
    "-o",
    "-t",
    "--author",
    "--cleanup",
    "--config-env",
    "--date",
    "--exec",
    "--exec-path",
    "--file",
    "--fixup",
    "--git-dir",
    "--literal-pathspecs-from-file",
    "--message",
    "--namespace",
    "--pathspec-from-file",
    "--push-option",
    "--reedit-message",
    "--receive-pack",
    "--repo",
    "--reuse-message",
    "--squash",
    "--super-prefix",
    "--template",
    "--trailer",
    "--work-tree",
];

fn normalize_args(args: &[String]) -> Vec<String> {
    let mut normalized = Vec::new();
    let mut index = 0;

    while index < args.len() {
        let token = &args[index];
        if token == "--" {
            break;
        }

        if token == "-" || !token.starts_with('-') {
            normalized.push(token.clone());
            index += 1;
            continue;
        }

        if token.starts_with("--") {
            let option_name = token
                .split_once('=')
                .map(|(name, _)| name)
                .unwrap_or(token.as_str())
                .to_string();
            let consumes_next = !token.contains('=') && option_takes_value(&option_name);
            normalized.push(option_name);
            index += if consumes_next { 2 } else { 1 };
            continue;
        }

        let chars: Vec<char> = token.chars().collect();
        let mut consumes_next = false;
        for short_index in 1..chars.len() {
            let option_name = format!("-{}", chars[short_index]);
            normalized.push(option_name.clone());
            if option_takes_value(&option_name) {
                consumes_next = short_index == chars.len() - 1;
                break;
            }
        }

        index += 1;
        if consumes_next {
            index += 1;
        }
    }

    normalized
}

fn option_takes_value(token: &str) -> bool {
    OPTIONS_WITH_VALUE.contains(&token)
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

        let tokens = invocation.normalized_tokens();

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

        let tokens = invocation.normalized_tokens();

        assert!(tokens.contains(&"-n".to_string()));
        assert!(tokens.contains(&"-m".to_string()));
        assert!(!tokens.contains(&"message".to_string()));
    }

    #[test]
    fn stops_emitting_arg_facts_after_double_dash() {
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

        let tokens = invocation.normalized_tokens();

        assert!(tokens.contains(&"--no-verify".to_string()));
        assert!(!tokens.contains(&"--force".to_string()));
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
