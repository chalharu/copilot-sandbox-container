use crate::command::{CommandInvocation, EnvBinding, merge_env_bindings};

const MAX_COMMAND_UNWRAP_DEPTH: usize = 4;
const SHELL_COMMAND_SEPARATORS: &[&str] = &["&&", "||", ";", "|", "&"];
const SHELL_WRAPPER_OPTIONS_WITH_VALUE: &[&str] = &["-O", "-o", "--init-file", "--rcfile"];
const SHELL_WRAPPER_COMMANDS: &[&str] = &["bash", "sh", "/bin/bash", "/bin/sh"];

pub fn parse_shell_command(command: &str) -> Vec<CommandInvocation> {
    let mut invocations = Vec::new();
    parse_shell_command_recursive(command, 0, &[], &mut invocations);
    invocations
}

fn parse_shell_command_recursive(
    command: &str,
    depth: usize,
    inherited_env: &[EnvBinding],
    invocations: &mut Vec<CommandInvocation>,
) {
    if depth > MAX_COMMAND_UNWRAP_DEPTH {
        return;
    }

    for command_tokens in split_shell_commands(&tokenize_shell_command(command)) {
        if command_tokens.is_empty() {
            continue;
        }

        let parsed_command = parse_command_tokens(&command_tokens, inherited_env);
        if let Some(invocation) = parsed_command.invocation {
            invocations.push(invocation);
        }

        if let Some(nested_command) = parsed_command.nested_command
            && nested_command != command
        {
            parse_shell_command_recursive(
                &nested_command,
                depth + 1,
                &parsed_command.inherited_env,
                invocations,
            );
        }
    }
}

struct ParsedCommand {
    invocation: Option<CommandInvocation>,
    nested_command: Option<String>,
    inherited_env: Vec<EnvBinding>,
}

fn parse_command_tokens(command_tokens: &[String], inherited_env: &[EnvBinding]) -> ParsedCommand {
    let prefix = strip_invocation_prefixes(command_tokens);
    let base_env = if prefix.clear_environment {
        Vec::new()
    } else {
        inherited_env.to_vec()
    };
    let effective_env = merge_env_bindings(&base_env, &prefix.env_bindings);
    let invocation =
        CommandInvocation::from_tokens(&prefix.invocation_tokens, effective_env.clone());
    let nested_command = extract_shell_command_string(&prefix.invocation_tokens);

    ParsedCommand {
        invocation,
        nested_command,
        inherited_env: effective_env,
    }
}

struct InvocationPrefix {
    env_bindings: Vec<EnvBinding>,
    clear_environment: bool,
    invocation_tokens: Vec<String>,
}

fn tokenize_shell_command(command: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut quote: Option<char> = None;
    let mut chars = command.chars().peekable();

    while let Some(char) = chars.next() {
        if quote == Some('\'') {
            if char == '\'' {
                quote = None;
            } else {
                current.push(char);
            }
            continue;
        }

        if quote == Some('"') {
            if char == '"' {
                quote = None;
                continue;
            }
            if char == '\\' {
                if let Some(next_char) = chars.next() {
                    current.push(next_char);
                }
                continue;
            }
            current.push(char);
            continue;
        }

        if char == '\'' || char == '"' {
            quote = Some(char);
            continue;
        }

        if char == '\\' {
            if let Some(next_char) = chars.next() {
                current.push(next_char);
            }
            continue;
        }

        if char == '\n' {
            if !current.is_empty() {
                tokens.push(current.clone());
                current.clear();
            }
            tokens.push(";".to_string());
            continue;
        }

        if char.is_whitespace() {
            if !current.is_empty() {
                tokens.push(current.clone());
                current.clear();
            }
            continue;
        }

        if matches!(char, '&' | '|' | ';') {
            if !current.is_empty() {
                tokens.push(current.clone());
                current.clear();
            }

            if matches!(char, '&' | '|') && chars.peek() == Some(&char) {
                chars.next();
                tokens.push(format!("{char}{char}"));
            } else {
                tokens.push(char.to_string());
            }
            continue;
        }

        current.push(char);
    }

    if !current.is_empty() {
        tokens.push(current);
    }

    tokens
}

fn split_shell_commands(tokens: &[String]) -> Vec<Vec<String>> {
    let mut commands = Vec::new();
    let mut current = Vec::new();

    for token in tokens {
        if SHELL_COMMAND_SEPARATORS
            .iter()
            .any(|separator| separator == token)
        {
            if !current.is_empty() {
                commands.push(current);
                current = Vec::new();
            }
            continue;
        }
        current.push(token.clone());
    }

    if !current.is_empty() {
        commands.push(current);
    }

    commands
}

fn strip_invocation_prefixes(command_tokens: &[String]) -> InvocationPrefix {
    let mut index = 0;
    let mut env_bindings = Vec::new();
    let mut clear_environment = false;

    while index < command_tokens.len() {
        if let Some(binding) = parse_environment_assignment(&command_tokens[index]) {
            env_bindings.push(binding);
            index += 1;
            continue;
        }
        break;
    }

    if command_tokens.get(index).map(String::as_str) == Some("env") {
        index += 1;
        while index < command_tokens.len() {
            let token = &command_tokens[index];
            if token == "-i" {
                clear_environment = true;
                index += 1;
                continue;
            }
            if token == "-u" || token == "--unset" {
                if let Some(name) = command_tokens.get(index + 1) {
                    env_bindings.push(EnvBinding {
                        name: name.clone(),
                        value: None,
                    });
                }
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
            break;
        }
    }

    InvocationPrefix {
        env_bindings,
        clear_environment,
        invocation_tokens: command_tokens[index..].to_vec(),
    }
}

fn extract_shell_command_string(invocation_tokens: &[String]) -> Option<String> {
    if !is_shell_wrapper_command(invocation_tokens.first()?.as_str()) {
        return None;
    }

    let mut index = 1;
    while index < invocation_tokens.len() {
        let token = &invocation_tokens[index];
        if token == "--" {
            break;
        }
        if token == "-c" {
            return invocation_tokens.get(index + 1).cloned();
        }
        if token == "-" || !token.starts_with('-') {
            break;
        }
        if SHELL_WRAPPER_OPTIONS_WITH_VALUE
            .iter()
            .any(|option| option == token)
        {
            index += 2;
            continue;
        }
        if token.starts_with("--init-file=")
            || token.starts_with("--rcfile=")
            || (token.starts_with("-O") && token.len() > 2)
            || (token.starts_with("-o") && token.len() > 2)
        {
            index += 1;
            continue;
        }
        if token.starts_with("--") {
            index += 1;
            continue;
        }
        if token[1..].contains('c') {
            return invocation_tokens.get(index + 1).cloned();
        }
        index += 1;
    }

    None
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

fn is_shell_wrapper_command(token: &str) -> bool {
    SHELL_WRAPPER_COMMANDS
        .iter()
        .any(|candidate| candidate == &token)
        || token.ends_with("/bash")
        || token.ends_with("/sh")
}

#[cfg(test)]
mod tests {
    use super::parse_shell_command;

    #[test]
    fn unwraps_shell_wrappers_and_propagates_environment_assignments() {
        let invocations =
            parse_shell_command("GIT_CONFIG_GLOBAL=/tmp/evil bash -lc \"git status --short\"");

        let nested = invocations.last().unwrap();
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

    #[test]
    fn splits_command_chains() {
        let invocations = parse_shell_command("printf ok && git push -f origin HEAD");

        assert_eq!(invocations.len(), 2);
        assert_eq!(invocations[0].executable_basename, "printf");
        assert_eq!(invocations[1].executable_basename, "git");
    }
}
