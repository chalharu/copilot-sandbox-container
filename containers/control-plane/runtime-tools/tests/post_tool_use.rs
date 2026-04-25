use std::collections::BTreeMap;
use std::ffi::OsString;
use std::fs;
use std::io::Write;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::thread::sleep;
use std::time::Duration;

use serde_json::Value;
use tempfile::TempDir;

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_path_buf()
}

fn workspace_root_for(repo_root: &Path) -> PathBuf {
    repo_root
        .ancestors()
        .nth(2)
        .unwrap_or(repo_root)
        .to_path_buf()
}

fn workspace_root() -> PathBuf {
    workspace_root_for(&repo_root())
}

fn bundled_linters_config_path() -> PathBuf {
    repo_root().join("hooks/postToolUse/linters.json")
}

fn runtime_tool_bin() -> PathBuf {
    std::env::var_os("CARGO_BIN_EXE_control-plane-runtime-tool")
        .map(PathBuf::from)
        .expect("missing runtime tool binary path")
}

fn run_checked(command: &str, args: &[&str], cwd: &Path) {
    let mut path = OsString::new();
    let repo_bin = cwd.join("bin");
    if repo_bin.is_dir() {
        path.push(repo_bin.as_os_str());
        path.push(":");
    }
    path.push(std::env::var_os("PATH").unwrap_or_default());
    let output = Command::new(command)
        .args(args)
        .current_dir(cwd)
        .env("COPILOT_HOME", cwd.join(".copilot"))
        .env("PATH", path)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{} {} failed: {}",
        command,
        args.join(" "),
        String::from_utf8_lossy(&output.stderr)
    );
}

fn setup_repo(prefix: &str) -> TempDir {
    let repo = tempfile::Builder::new()
        .prefix(prefix)
        .tempdir_in(workspace_root())
        .unwrap();
    run_checked("git", &["init", "--quiet"], repo.path());
    run_checked("git", &["checkout", "-b", "fixture"], repo.path());
    run_checked("git", &["config", "user.name", "test"], repo.path());
    run_checked(
        "git",
        &["config", "user.email", "test@example.com"],
        repo.path(),
    );

    let hook_dir = repo.path().join(".copilot/hooks/postToolUse");
    fs::create_dir_all(repo.path().join(".github")).unwrap();
    fs::create_dir_all(&hook_dir).unwrap();
    write_executable(
        &hook_dir.join("main"),
        "#!/usr/bin/env bash\nset -euo pipefail\nexit 0\n",
    );
    fs::OpenOptions::new()
        .append(true)
        .open(repo.path().join(".git/info/exclude"))
        .unwrap()
        .write_all(b"bin/\nhook.log\n.copilot/hooks/\n")
        .unwrap();

    repo
}

#[test]
fn setup_repo_uses_non_protected_branch() {
    let repo = setup_repo("post-tool-use-branch-");
    let output = Command::new("git")
        .args(["branch", "--show-current"])
        .current_dir(repo.path())
        .output()
        .unwrap();

    assert!(output.status.success());
    assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), "fixture");
}

#[test]
fn workspace_root_falls_back_to_repo_root_for_shallow_layouts() {
    assert_eq!(
        workspace_root_for(Path::new("/build")),
        PathBuf::from("/build")
    );
    assert_eq!(
        workspace_root_for(Path::new("/workspace/containers/control-plane")),
        PathBuf::from("/workspace")
    );
}

#[derive(Clone)]
struct HookEnv {
    env: BTreeMap<String, String>,
    log_file: PathBuf,
}

#[derive(Clone)]
struct StubOptions {
    markdownlint: bool,
    biome: bool,
    biome_runtime_failure_mode: Option<&'static str>,
    oxlint: bool,
    eslint: bool,
    ruff: bool,
    containerized_bash: bool,
    hadolint: bool,
    second_tool: bool,
}

impl Default for StubOptions {
    fn default() -> Self {
        Self {
            markdownlint: true,
            biome: true,
            biome_runtime_failure_mode: None,
            oxlint: true,
            eslint: false,
            ruff: false,
            containerized_bash: false,
            hadolint: false,
            second_tool: false,
        }
    }
}

fn write_executable(file_path: &Path, content: &str) {
    if let Some(parent) = file_path.parent() {
        fs::create_dir_all(parent).unwrap();
    }
    fs::write(file_path, content).unwrap();
    let mut permissions = fs::metadata(file_path).unwrap().permissions();
    use std::os::unix::fs::PermissionsExt;
    permissions.set_mode(0o755);
    fs::set_permissions(file_path, permissions).unwrap();
}

fn install_runtime_hook(repo: &Path) {
    let hook_dir = repo.join(".copilot/hooks/postToolUse");
    let hook_path = hook_dir.join("main");

    fs::copy(bundled_linters_config_path(), hook_dir.join("linters.json")).unwrap();
    if hook_path.exists() {
        fs::remove_file(&hook_path).unwrap();
    }
    symlink(runtime_tool_bin(), &hook_path).unwrap();
}

fn create_tool_stubs(repo: &Path, options: StubOptions) -> HookEnv {
    let bin_dir = repo.join("bin");
    let log_file = repo.join("hook.log");

    install_runtime_hook(repo);
    fs::write(&log_file, "").unwrap();

    if options.markdownlint {
        write_executable(
            &bin_dir.join("markdownlint-cli2"),
            "#!/bin/sh\nprintf \"%s\\n\" \"$*\" >> \"$HOOK_LOG\"\nif [ \"$1\" = \"--fix\" ]; then\n  exit 0\nfi\nprintf \"remaining markdown issue in %s\\n\" \"$1\" >&2\nexit 1\n",
        );
    }
    if options.biome {
        write_executable(
            &bin_dir.join("control-plane-biome"),
            r#"#!/bin/sh
printf "control-plane-biome %s\n" "$*" >> "$HOOK_LOG"
mode="${BIOME_RUNTIME_FAILURE_MODE:-}"
if [ "$1" = "check" ] && [ "${2:-}" = "--write" ]; then
  file="$3"
  if [ "$mode" = "write" ] || [ "$mode" = "all" ]; then
    printf "biome runtime failed in %s\n" "$file" >&2
    exit 70
  fi
  if [ "$mode" = "signal-write" ] || [ "$mode" = "signal-all" ]; then
    kill -TERM "$$"
  fi
  exit 0
fi
file="${2:-}"
if [ "$mode" = "check" ] || [ "$mode" = "all" ]; then
  printf "biome runtime failed in %s\n" "$file" >&2
  exit 70
fi
if [ "$mode" = "signal-check" ] || [ "$mode" = "signal-all" ]; then
  kill -TERM "$$"
fi
printf "biome unresolved in %s\n" "$file" >&2
exit 1
"#,
        );
    }
    if options.oxlint {
        write_executable(
            &bin_dir.join("oxlint"),
            "#!/bin/sh\nprintf \"oxlint %s\\n\" \"$*\" >> \"$HOOK_LOG\"\nif [ \"$1\" = \"--fix\" ]; then\n  exit 0\nfi\nprintf \"oxlint unresolved in %s\\n\" \"$1\" >&2\nexit 1\n",
        );
    }
    if options.eslint {
        write_executable(
            &bin_dir.join("eslint"),
            "#!/bin/sh\nprintf \"eslint %s\\n\" \"$*\" >> \"$HOOK_LOG\"\nif [ \"$1\" = \"--fix\" ]; then\n  exit 0\nfi\nprintf \"eslint unresolved in %s\\n\" \"$1\" >&2\nexit 1\n",
        );
    }
    if options.ruff {
        write_executable(
            &bin_dir.join("ruff"),
            "#!/bin/sh\nprintf \"ruff %s\\n\" \"$*\" >> \"$HOOK_LOG\"\nif [ \"$1\" = \"format\" ]; then\n  exit 0\nfi\nif [ \"$1\" = \"check\" ] && [ \"$2\" = \"--fix\" ]; then\n  exit 0\nfi\nprintf \"ruff unresolved in %s\\n\" \"$2\" >&2\nexit 1\n",
        );
    }
    if options.containerized_bash {
        write_executable(
            &bin_dir.join("bash"),
            "#!/bin/sh\nprintf \"bash %s\\n\" \"$*\" >> \"$HOOK_LOG\"\nprintf \"NODE_COMPILE_CACHE=%s\\n\" \"$NODE_COMPILE_CACHE\" >> \"$HOOK_LOG\"\nprintf \"NPM_CONFIG_CACHE=%s\\n\" \"$NPM_CONFIG_CACHE\" >> \"$HOOK_LOG\"\nif [ \"$1\" = \"/usr/local/share/control-plane/hooks/postToolUse/control-plane-rust.sh\" ] && [ \"$2\" = \"fmt\" ]; then\n  exit 0\nfi\nif [ \"$1\" = \"/usr/local/share/control-plane/hooks/postToolUse/control-plane-rust.sh\" ] && [ \"$2\" = \"clippy-fix\" ]; then\n  exit 0\nfi\nif [ \"$1\" = \"/usr/local/share/control-plane/hooks/postToolUse/control-plane-rust.sh\" ] && [ \"$2\" = \"clippy\" ]; then\n  printf \"clippy unresolved\\n\" >&2\n  exit 1\nfi\nexec /usr/bin/bash \"$@\"\n",
        );
        write_executable(
            &bin_dir.join("yamllint"),
            "#!/bin/sh\nprintf \"yamllint %s\\n\" \"$*\" >> \"$HOOK_LOG\"\nprintf \"yamllint unresolved in %s\\n\" \"$3\" >&2\nexit 1\n",
        );
    }
    if options.hadolint {
        write_executable(
            &bin_dir.join("hadolint"),
            "#!/bin/sh\nprintf \"hadolint %s\\n\" \"$*\" >> \"$HOOK_LOG\"\nprintf \"hadolint unresolved in %s\\n\" \"$1\" >&2\nexit 1\n",
        );
    }
    if options.second_tool {
        write_executable(
            &bin_dir.join("second-tool"),
            "#!/bin/sh\nprintf \"second-tool %s\\n\" \"$*\" >> \"$HOOK_LOG\"\nexit 0\n",
        );
    }

    let mut env = BTreeMap::from([
        (
            "CONTROL_PLANE_HOOK_TMP_ROOT".to_string(),
            repo.join(".hook-cache").display().to_string(),
        ),
        (
            "CONTROL_PLANE_POST_TOOL_USE_FORWARD_ACTIVE".to_string(),
            "1".to_string(),
        ),
        (
            "PATH".to_string(),
            format!("{}:/usr/bin:/bin:/usr/sbin:/sbin", bin_dir.display()),
        ),
        ("HOOK_LOG".to_string(), log_file.display().to_string()),
    ]);
    if let Some(mode) = options.biome_runtime_failure_mode {
        env.insert("BIOME_RUNTIME_FAILURE_MODE".to_string(), mode.to_string());
    }
    HookEnv { env, log_file }
}

fn seed_repo(repo: &Path) {
    fs::write(repo.join("README.md"), "# Title\n").unwrap();
    fs::write(repo.join("index.ts"), "export const value = 1;\n").unwrap();
    run_checked("git", &["add", "README.md", "index.ts"], repo);
    run_checked("git", &["commit", "-m", "init"], repo);
}

fn make_files_dirty(repo: &Path) {
    fs::write(repo.join("README.md"), "# Title\n\nchanged\n").unwrap();
    fs::write(repo.join("index.ts"), "export const value=1\n").unwrap();
}

fn change_dirty_files_again(repo: &Path) {
    sleep(Duration::from_millis(20));
    fs::write(
        repo.join("README.md"),
        "# Title\n\nchanged\n\nchanged again\n",
    )
    .unwrap();
    fs::write(
        repo.join("index.ts"),
        "export const value=1\nconsole.log(value)\n",
    )
    .unwrap();
}

fn seed_python_rust_docker_repo(repo: &Path) {
    fs::create_dir_all(repo.join("src")).unwrap();
    fs::write(repo.join("app.py"), "value = 1\n").unwrap();
    fs::write(
        repo.join("sample.yaml"),
        "kind: Config\nmetadata:\n  name: demo\n",
    )
    .unwrap();
    fs::write(
        repo.join("Cargo.toml"),
        "[package]\nname = \"demo\"\nversion = \"0.1.0\"\nedition = \"2021\"\n",
    )
    .unwrap();
    fs::write(repo.join("src/lib.rs"), "pub fn value() -> i32 { 1 }\n").unwrap();
    fs::write(
        repo.join("Dockerfile"),
        "FROM alpine:3.20\nRUN echo hello\n",
    )
    .unwrap();
    run_checked(
        "git",
        &[
            "add",
            "app.py",
            "sample.yaml",
            "Cargo.toml",
            "src/lib.rs",
            "Dockerfile",
        ],
        repo,
    );
    run_checked("git", &["commit", "-m", "init"], repo);
}

fn make_python_rust_docker_dirty(repo: &Path) {
    fs::write(repo.join("app.py"), "value=1\n").unwrap();
    fs::write(
        repo.join("sample.yaml"),
        "kind Config\nmetadata:\n name demo\n",
    )
    .unwrap();
    fs::write(repo.join("src/lib.rs"), "pub fn value()->i32{1}\n").unwrap();
    fs::write(
        repo.join("Dockerfile"),
        "FROM alpine:3.20\nRUN apk add curl\n",
    )
    .unwrap();
}

fn run_hook(repo: &Path, hook_env: &HookEnv, tool_result_type: &str) -> Output {
    let hook_path = repo.join(".copilot/hooks/postToolUse/main");
    let input = serde_json::json!({
        "cwd": repo,
        "toolName": "bash",
        "toolResult": { "resultType": tool_result_type },
    })
    .to_string();
    let mut child = Command::new(&hook_path)
        .current_dir(repo)
        .envs(&hook_env.env)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

#[test]
fn linters_config_defines_language_pipelines() {
    let linters_config: Value =
        serde_json::from_str(&fs::read_to_string(bundled_linters_config_path()).unwrap()).unwrap();
    let tools = linters_config["tools"].as_array().unwrap();
    let pipelines = linters_config["pipelines"].as_array().unwrap();

    let markdownlint_fix_npx = tools
        .iter()
        .find(|tool| tool["id"] == "markdownlint-fix-npx")
        .unwrap();
    let biome_check_write = tools
        .iter()
        .find(|tool| tool["id"] == "biome-check-write")
        .unwrap();
    let biome_check = tools
        .iter()
        .find(|tool| tool["id"] == "biome-check")
        .unwrap();
    let control_plane_rust_fmt = tools
        .iter()
        .find(|tool| tool["id"] == "control-plane-rust-fmt")
        .unwrap();
    let yamllint_check = tools
        .iter()
        .find(|tool| tool["id"] == "yamllint-check")
        .unwrap();
    let markdown_pipeline = pipelines
        .iter()
        .find(|pipeline| pipeline["id"] == "markdown")
        .unwrap();
    let scripts_pipeline = pipelines
        .iter()
        .find(|pipeline| pipeline["id"] == "scripts")
        .unwrap();
    let json_pipeline = pipelines
        .iter()
        .find(|pipeline| pipeline["id"] == "json")
        .unwrap();
    let yaml_pipeline = pipelines
        .iter()
        .find(|pipeline| pipeline["id"] == "yaml")
        .unwrap();
    let rust_pipeline = pipelines
        .iter()
        .find(|pipeline| pipeline["id"] == "rust")
        .unwrap();
    let docker_pipeline = pipelines
        .iter()
        .find(|pipeline| pipeline["id"] == "dockerfile")
        .unwrap();

    assert_eq!(markdownlint_fix_npx["command"], "npx");
    assert_eq!(biome_check_write["command"], "control-plane-biome");
    assert_eq!(biome_check_write["runtimeFailureExitCodes"][0], 70);
    assert_eq!(biome_check["runtimeFailureExitCodes"][0], 70);
    assert_eq!(control_plane_rust_fmt["command"], "bash");
    assert_eq!(control_plane_rust_fmt["appendFiles"], true);
    assert_eq!(yamllint_check["command"], "yamllint");
    assert_eq!(markdown_pipeline["matcher"][0], "\\.(?:md|markdown)$");
    assert_eq!(json_pipeline["matcher"][0], "\\.(?:jsonc?)$");
    assert_eq!(
        json_pipeline["steps"][0]["runtimeFailureLabel"],
        "Biome hook runtime failed:"
    );
    assert_eq!(json_pipeline["steps"][1]["tools"][0], "biome-check");
    assert_eq!(
        scripts_pipeline["steps"][0]["runtimeFailureLabel"],
        "Biome hook runtime failed:"
    );
    assert_eq!(scripts_pipeline["steps"][1]["tools"][0], "oxlint-fix");
    assert_eq!(
        scripts_pipeline["steps"][4]["runtimeFailureLabel"],
        "JavaScript/TypeScript hook runtime failed:"
    );
    assert_eq!(yaml_pipeline["steps"][0]["tools"][0], "yamllint-check");
    assert_eq!(
        rust_pipeline["steps"][0]["tools"][0],
        "control-plane-rust-fmt"
    );
    assert_eq!(docker_pipeline["matcher"][1], "(?:^|/)[^/]+\\.Dockerfile$");
    assert_eq!(pipelines.len(), 7);
}

#[test]
fn hook_runs_incrementally() {
    let repo = setup_repo("post-tool-use-main-");
    seed_repo(repo.path());
    make_files_dirty(repo.path());

    let hook_env = create_tool_stubs(repo.path(), StubOptions::default());
    let first_run = run_hook(repo.path(), &hook_env, "success");
    let first_log = fs::read_to_string(&hook_env.log_file).unwrap();
    let second_run = run_hook(repo.path(), &hook_env, "success");
    let second_log = fs::read_to_string(&hook_env.log_file).unwrap();

    change_dirty_files_again(repo.path());
    let third_run = run_hook(repo.path(), &hook_env, "success");
    let third_log = fs::read_to_string(&hook_env.log_file).unwrap();

    assert_eq!(first_run.status.code(), Some(1));
    assert_eq!(second_run.status.code(), Some(0));
    assert_eq!(third_run.status.code(), Some(1));
    assert_eq!(first_log.trim().lines().count(), 7);
    assert_eq!(second_log.trim().lines().count(), 7);
    assert_eq!(third_log.trim().lines().count(), 14);
    assert!(first_log.contains("--fix README.md"));
    assert!(first_log.contains("control-plane-biome check --write index.ts"));
    assert!(first_log.contains("oxlint --fix index.ts"));
    let first_stderr = String::from_utf8_lossy(&first_run.stderr);
    assert!(first_stderr.contains("remaining markdown issue in README.md"));
    assert!(first_stderr.contains("Biome reported unresolved issues:"));
    assert!(first_stderr.contains("JavaScript/TypeScript linter reported unresolved issues:"));
    assert!(String::from_utf8_lossy(&second_run.stderr).is_empty());
    let third_stderr = String::from_utf8_lossy(&third_run.stderr);
    assert!(third_stderr.contains("README.md"));
    assert!(third_stderr.contains("index.ts"));
}

#[test]
fn hook_falls_back_from_oxlint_to_eslint() {
    let repo = setup_repo("post-tool-use-eslint-");
    seed_repo(repo.path());
    fs::write(repo.path().join("index.ts"), "export const value=1\n").unwrap();
    let hook_env = create_tool_stubs(
        repo.path(),
        StubOptions {
            oxlint: false,
            eslint: true,
            ..StubOptions::default()
        },
    );
    let result = run_hook(repo.path(), &hook_env, "success");
    let hook_log = fs::read_to_string(&hook_env.log_file).unwrap();

    assert_eq!(result.status.code(), Some(1));
    assert!(!hook_log.contains("oxlint --fix index.ts"));
    assert!(hook_log.contains("eslint --fix index.ts"));
    let stderr = String::from_utf8_lossy(&result.stderr);
    assert!(stderr.contains("JavaScript/TypeScript linter reported unresolved issues:"));
    assert!(stderr.contains("eslint unresolved in index.ts"));
}

#[test]
fn hook_stops_after_biome_runtime_failure() {
    let repo = setup_repo("post-tool-use-biome-runtime-");
    seed_repo(repo.path());
    make_files_dirty(repo.path());
    let hook_env = create_tool_stubs(
        repo.path(),
        StubOptions {
            biome_runtime_failure_mode: Some("check"),
            eslint: true,
            ..StubOptions::default()
        },
    );
    let first_result = run_hook(repo.path(), &hook_env, "success");
    let first_log = fs::read_to_string(&hook_env.log_file).unwrap();
    let first_stderr = String::from_utf8_lossy(&first_result.stderr);
    let second_result = run_hook(repo.path(), &hook_env, "success");
    let second_log = fs::read_to_string(&hook_env.log_file).unwrap();
    let second_stderr = String::from_utf8_lossy(&second_result.stderr);

    assert_eq!(first_result.status.code(), Some(70));
    assert_eq!(second_result.status.code(), Some(70));
    assert_eq!(
        first_log
            .matches("control-plane-biome check --write index.ts")
            .count(),
        2
    );
    assert_eq!(
        second_log.trim().lines().count(),
        first_log.trim().lines().count() * 2
    );
    assert!(first_log.contains("control-plane-biome check index.ts"));
    assert!(first_log.contains("oxlint --fix index.ts"));
    assert!(!first_log.contains("oxlint index.ts"));
    assert!(!first_log.contains("eslint --fix index.ts"));
    assert!(!first_log.contains("eslint index.ts"));
    assert!(first_stderr.contains("Biome hook runtime failed:"));
    assert!(first_stderr.contains("biome runtime failed in index.ts"));
    assert!(!first_stderr.contains("Biome reported unresolved issues:"));
    assert!(!first_stderr.contains("JavaScript/TypeScript linter reported unresolved issues:"));
    assert!(second_stderr.contains("Biome hook runtime failed:"));
}

#[test]
fn hook_treats_signal_terminated_biome_as_runtime_failure() {
    let repo = setup_repo("post-tool-use-biome-signal-");
    seed_repo(repo.path());
    make_files_dirty(repo.path());
    let hook_env = create_tool_stubs(
        repo.path(),
        StubOptions {
            biome_runtime_failure_mode: Some("signal-check"),
            eslint: true,
            ..StubOptions::default()
        },
    );
    let result = run_hook(repo.path(), &hook_env, "success");
    let hook_log = fs::read_to_string(&hook_env.log_file).unwrap();
    let stderr = String::from_utf8_lossy(&result.stderr);

    assert_eq!(result.status.code(), Some(70));
    assert!(stderr.contains("Biome hook runtime failed:"));
    assert!(stderr.contains("control-plane-biome terminated without an exit code"));
    assert!(!stderr.contains("Biome reported unresolved issues:"));
    assert!(!stderr.contains("JavaScript/TypeScript linter reported unresolved issues:"));
    assert!(!hook_log.contains("oxlint index.ts"));
}

#[test]
fn hook_runs_python_rust_yaml_and_dockerfile_pipelines() {
    let repo = setup_repo("post-tool-use-extra-");
    seed_python_rust_docker_repo(repo.path());
    make_python_rust_docker_dirty(repo.path());
    let hook_env = create_tool_stubs(
        repo.path(),
        StubOptions {
            markdownlint: false,
            biome: false,
            oxlint: false,
            eslint: false,
            ruff: true,
            containerized_bash: true,
            hadolint: true,
            ..StubOptions::default()
        },
    );
    let result = run_hook(repo.path(), &hook_env, "success");
    let hook_log = fs::read_to_string(&hook_env.log_file).unwrap();
    let stderr = String::from_utf8_lossy(&result.stderr);

    assert_eq!(result.status.code(), Some(1));
    assert!(hook_log.contains("ruff format app.py"));
    assert!(hook_log.contains("ruff check --fix app.py"));
    assert!(
        hook_log
            .contains("/usr/local/share/control-plane/hooks/postToolUse/control-plane-rust.sh fmt")
    );
    assert!(hook_log.contains(
        "/usr/local/share/control-plane/hooks/postToolUse/control-plane-rust.sh clippy-fix"
    ));
    assert!(
        hook_log.contains(
            "/usr/local/share/control-plane/hooks/postToolUse/control-plane-rust.sh clippy"
        )
    );
    assert!(hook_log.contains("yamllint -c .yamllint sample.yaml"));
    assert!(hook_log.contains("hadolint Dockerfile"));
    assert!(hook_log.contains("NODE_COMPILE_CACHE="));
    assert!(hook_log.contains("NPM_CONFIG_CACHE="));
    assert!(stderr.contains("Ruff reported unresolved issues:"));
    assert!(stderr.contains("Rust linter reported unresolved issues:"));
    assert!(stderr.contains("Yamllint reported unresolved issues:"));
    assert!(stderr.contains("Hadolint reported unresolved issues:"));
    assert!(stderr.contains("ruff unresolved in app.py"));
    assert!(stderr.contains("clippy unresolved"));
    assert!(stderr.contains("yamllint unresolved in sample.yaml"));
    assert!(stderr.contains("hadolint unresolved in Dockerfile"));
}

#[test]
fn hook_uses_repo_pipeline_overrides_with_bundled_tools() {
    let repo = setup_repo("post-tool-use-merge-");
    seed_repo(repo.path());
    make_files_dirty(repo.path());
    fs::write(
        repo.path().join(".github/linters.json"),
        serde_json::to_string_pretty(&serde_json::json!({
            "pipelines": [{
                "id": "scripts",
                "matcher": ["\\.(?:[cm]?[jt]s|[jt]sx)$"],
                "steps": [{ "tools": ["biome-check-write"] }]
            }]
        }))
        .unwrap(),
    )
    .unwrap();

    let hook_env = create_tool_stubs(
        repo.path(),
        StubOptions {
            biome: true,
            oxlint: false,
            eslint: false,
            ..StubOptions::default()
        },
    );
    let result = run_hook(repo.path(), &hook_env, "success");
    let hook_log = fs::read_to_string(&hook_env.log_file).unwrap();
    let stderr = String::from_utf8_lossy(&result.stderr);

    assert_eq!(result.status.code(), Some(1));
    assert!(hook_log.contains("--fix README.md"));
    assert!(hook_log.contains("biome check --write index.ts"));
    assert!(!hook_log.contains("oxlint --fix index.ts"));
    assert!(stderr.contains("remaining markdown issue in README.md"));
    assert!(!stderr.contains("JavaScript/TypeScript linter reported unresolved issues:"));
}

#[test]
fn hook_rejects_repo_defined_commands() {
    let repo = setup_repo("post-tool-use-reject-repo-tool-");
    seed_repo(repo.path());
    make_files_dirty(repo.path());
    fs::write(
        repo.path().join(".github/linters.json"),
        serde_json::to_string_pretty(&serde_json::json!({
            "tools": [{ "id": "repo-scripts-check", "command": "second-tool", "args": ["check"] }]
        }))
        .unwrap(),
    )
    .unwrap();

    let hook_env = create_tool_stubs(
        repo.path(),
        StubOptions {
            second_tool: true,
            ..StubOptions::default()
        },
    );
    let result = run_hook(repo.path(), &hook_env, "success");
    let stderr = String::from_utf8_lossy(&result.stderr);

    assert_eq!(result.status.code(), Some(1));
    assert!(
        stderr
            .contains("Repo linters config may only override bundled tool ids: repo-scripts-check")
    );
}

#[test]
fn hook_skips_work_when_tool_use_is_denied() {
    let repo = setup_repo("post-tool-use-denied-");
    seed_repo(repo.path());
    make_files_dirty(repo.path());

    let hook_env = create_tool_stubs(repo.path(), StubOptions::default());
    let result = run_hook(repo.path(), &hook_env, "denied");

    assert_eq!(result.status.code(), Some(0));
    if hook_env.log_file.exists() {
        assert!(fs::read_to_string(&hook_env.log_file).unwrap().is_empty());
    }
    assert!(result.stdout.is_empty());
    assert!(result.stderr.is_empty());
}
