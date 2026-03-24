use std::path::Path;

const GIT_OPTIONS_WITH_VALUE: &[&str] = &[
    "-c",
    "-C",
    "--config-env",
    "--exec-path",
    "--git-dir",
    "--namespace",
    "--super-prefix",
    "--work-tree",
];

struct OptionSpec {
    short: &'static [&'static str],
    long: &'static [&'static str],
}

const EMPTY_OPTION_SPEC: OptionSpec = OptionSpec {
    short: &[],
    long: &[],
};

const COMMIT_OPTION_SPEC: OptionSpec = OptionSpec {
    short: &["-c", "-C", "-F", "-m", "-t"],
    long: &[
        "--author",
        "--cleanup",
        "--date",
        "--file",
        "--fixup",
        "--message",
        "--pathspec-from-file",
        "--reedit-message",
        "--reuse-message",
        "--squash",
        "--template",
        "--trailer",
    ],
};

const PUSH_OPTION_SPEC: OptionSpec = OptionSpec {
    short: &["-o"],
    long: &["--exec", "--push-option", "--receive-pack", "--repo"],
};

#[derive(Debug, PartialEq, Eq)]
struct ParsedGitCommand {
    subcommand: String,
    args: Vec<String>,
}

enum GitInvocationKind {
    Git,
    DirectSubcommand(String),
}

pub fn build_command_candidates(command_path: &str, argv: &[String]) -> Vec<String> {
    if let Some(parsed) = parse_git_invocation(command_path, argv) {
        return vec![
            format!("git {} {}", parsed.subcommand, parsed.args.join(" "))
                .trim()
                .to_string(),
        ];
    }

    let mut candidates = Vec::new();
    if !argv.is_empty() {
        push_unique(&mut candidates, argv.join(" "));
    } else if !command_path.is_empty() {
        push_unique(&mut candidates, command_path.to_string());
    }

    candidates
}

pub fn looks_like_git_invocation(command_path: &str, argv: &[String]) -> bool {
    detect_git_invocation(command_path, argv.first().map(String::as_str)).is_some()
}

fn parse_git_invocation(command_path: &str, argv: &[String]) -> Option<ParsedGitCommand> {
    match detect_git_invocation(command_path, argv.first().map(String::as_str))? {
        GitInvocationKind::Git => {
            let (subcommand, args) = extract_git_subcommand(argv.get(1..).unwrap_or(&[]))?;
            Some(ParsedGitCommand { subcommand, args })
        }
        GitInvocationKind::DirectSubcommand(subcommand) => Some(ParsedGitCommand {
            args: normalize_git_args(&subcommand, argv.get(1..).unwrap_or(&[])),
            subcommand,
        }),
    }
}

fn detect_git_invocation(command_path: &str, argv0: Option<&str>) -> Option<GitInvocationKind> {
    [Some(command_path), argv0]
        .into_iter()
        .flatten()
        .find_map(|candidate| {
            let base = basename(candidate);
            if base == "git" {
                return Some(GitInvocationKind::Git);
            }

            base.strip_prefix("git-")
                .filter(|subcommand| !subcommand.is_empty())
                .map(|subcommand| {
                    GitInvocationKind::DirectSubcommand(subcommand.to_ascii_lowercase())
                })
        })
}

fn basename(value: &str) -> &str {
    Path::new(value)
        .file_name()
        .and_then(|entry| entry.to_str())
        .unwrap_or(value)
}

fn extract_git_subcommand(args: &[String]) -> Option<(String, Vec<String>)> {
    let mut index = 0;

    while index < args.len() {
        let token = &args[index];
        if token == "--" {
            index += 1;
            break;
        }
        if token == "-" || !token.starts_with('-') {
            break;
        }
        if GIT_OPTIONS_WITH_VALUE.contains(&token.as_str())
            || token == "--literal-pathspecs-from-file"
        {
            index += 2;
            continue;
        }
        if token.starts_with("--config-env=")
            || token.starts_with("--exec-path=")
            || token.starts_with("--git-dir=")
            || token.starts_with("--namespace=")
            || token.starts_with("--super-prefix=")
            || token.starts_with("--work-tree=")
        {
            index += 1;
            continue;
        }
        index += 1;
    }

    let subcommand = args.get(index)?.to_ascii_lowercase();
    Some((
        subcommand.clone(),
        normalize_git_args(&subcommand, &args[index + 1..]),
    ))
}

fn normalize_git_args(subcommand: &str, args: &[String]) -> Vec<String> {
    let option_spec = option_spec_for(subcommand);
    let mut normalized = Vec::new();
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

        if let Some(option_name) = token.strip_prefix("--") {
            let option_name = match option_name.split_once('=') {
                Some((name, _)) => format!("--{name}"),
                None => token.clone(),
            };
            let consumes_next =
                !token.contains('=') && option_spec.long.contains(&option_name.as_str());
            normalized.push(option_name);
            index += if consumes_next { 2 } else { 1 };
            continue;
        }

        let bytes = token.as_bytes();
        let mut consumes_next = false;
        for short_index in 1..bytes.len() {
            let option_name = format!("-{}", bytes[short_index] as char);
            normalized.push(option_name.clone());
            if option_spec.short.contains(&option_name.as_str()) {
                consumes_next = short_index == bytes.len() - 1;
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

fn option_spec_for(subcommand: &str) -> &'static OptionSpec {
    match subcommand {
        "commit" => &COMMIT_OPTION_SPEC,
        "push" => &PUSH_OPTION_SPEC,
        _ => &EMPTY_OPTION_SPEC,
    }
}

fn push_unique(candidates: &mut Vec<String>, candidate: String) {
    if !candidate.is_empty() && !candidates.iter().any(|entry| entry == &candidate) {
        candidates.push(candidate);
    }
}

#[cfg(test)]
mod tests {
    use super::build_command_candidates;

    #[test]
    fn normalizes_commit_and_ignores_message_values() {
        let candidates = build_command_candidates(
            "/usr/bin/git",
            &[
                "git".to_string(),
                "commit".to_string(),
                "-m".to_string(),
                "-n".to_string(),
                "--no-verify".to_string(),
            ],
        );

        assert_eq!(candidates, vec!["git commit -m --no-verify"]);
    }

    #[test]
    fn stops_normalizing_after_double_dash() {
        let candidates = build_command_candidates(
            "git",
            &[
                "git".to_string(),
                "commit".to_string(),
                "--no-verify".to_string(),
                "--".to_string(),
                "--force".to_string(),
            ],
        );

        assert_eq!(candidates, vec!["git commit --no-verify"]);
    }

    #[test]
    fn normalizes_global_options_before_subcommand() {
        let candidates = build_command_candidates(
            "git",
            &[
                "git".to_string(),
                "-C".to_string(),
                ".".to_string(),
                "push".to_string(),
                "-f".to_string(),
                "origin".to_string(),
                "HEAD".to_string(),
            ],
        );

        assert_eq!(candidates, vec!["git push -f"]);
    }

    #[test]
    fn normalizes_direct_git_subcommand_binaries() {
        let candidates = build_command_candidates(
            "/usr/lib/git-core/git-push",
            &[
                "git-push".to_string(),
                "--force".to_string(),
                "origin".to_string(),
                "HEAD".to_string(),
            ],
        );

        assert_eq!(candidates, vec!["git push --force"]);
    }

    #[test]
    fn keeps_force_with_lease_distinct_from_force() {
        let candidates = build_command_candidates(
            "git",
            &[
                "git".to_string(),
                "push".to_string(),
                "--force-with-lease".to_string(),
                "origin".to_string(),
                "HEAD".to_string(),
            ],
        );

        assert_eq!(candidates, vec!["git push --force-with-lease"]);
    }
}
