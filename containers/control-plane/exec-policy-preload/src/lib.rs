mod config;
mod git;

use libc::{c_char, c_int, c_void};
use std::ffi::CStr;
use std::path::Path;
use std::sync::OnceLock;

type ExecveFn =
    unsafe extern "C" fn(*const c_char, *const *const c_char, *const *const c_char) -> c_int;
type ExecveatFn = unsafe extern "C" fn(
    c_int,
    *const c_char,
    *const *const c_char,
    *const *const c_char,
    c_int,
) -> c_int;
type PosixSpawnFn = unsafe extern "C" fn(
    *mut libc::pid_t,
    *const c_char,
    *const libc::posix_spawn_file_actions_t,
    *const libc::posix_spawnattr_t,
    *const *mut c_char,
    *const *mut c_char,
) -> c_int;

struct PolicyEvaluation {
    deny_reason: Option<String>,
}

static EXECVE_SYMBOL: OnceLock<usize> = OnceLock::new();
static EXECVEAT_SYMBOL: OnceLock<usize> = OnceLock::new();
static POSIX_SPAWN_SYMBOL: OnceLock<usize> = OnceLock::new();
static POSIX_SPAWNP_SYMBOL: OnceLock<usize> = OnceLock::new();

#[no_mangle]
/// # Safety
///
/// This function replaces libc's `execve` via `LD_PRELOAD` and must be called
/// with the same valid pointers and C ABI contract that libc expects.
pub unsafe extern "C" fn execve(
    filename: *const c_char,
    argv: *const *const c_char,
    envp: *const *const c_char,
) -> c_int {
    if let Some(reason) = block_reason_for_exec(filename, argv) {
        emit_policy_message(&reason);
        set_errno(libc::EACCES);
        return -1;
    }

    real_execve()(filename, argv, envp)
}

#[no_mangle]
/// # Safety
///
/// This function replaces libc's `execveat` via `LD_PRELOAD` and must be called
/// with the same valid pointers, file descriptor, and flags that libc expects.
pub unsafe extern "C" fn execveat(
    dirfd: c_int,
    pathname: *const c_char,
    argv: *const *const c_char,
    envp: *const *const c_char,
    flags: c_int,
) -> c_int {
    if let Some(reason) = block_reason_for_exec(pathname, argv) {
        emit_policy_message(&reason);
        set_errno(libc::EACCES);
        return -1;
    }

    real_execveat()(dirfd, pathname, argv, envp, flags)
}

#[no_mangle]
/// # Safety
///
/// This function replaces libc's `posix_spawn` via `LD_PRELOAD` and must be
/// called with the same valid pointers and C ABI contract that libc expects.
pub unsafe extern "C" fn posix_spawn(
    pid: *mut libc::pid_t,
    path: *const c_char,
    file_actions: *const libc::posix_spawn_file_actions_t,
    attrp: *const libc::posix_spawnattr_t,
    argv: *const *mut c_char,
    envp: *const *mut c_char,
) -> c_int {
    if let Some(reason) = block_reason_for_exec(path, argv.cast()) {
        emit_policy_message(&reason);
        return libc::EACCES;
    }

    real_posix_spawn()(pid, path, file_actions, attrp, argv, envp)
}

#[no_mangle]
/// # Safety
///
/// This function replaces libc's `posix_spawnp` via `LD_PRELOAD` and must be
/// called with the same valid pointers and C ABI contract that libc expects.
pub unsafe extern "C" fn posix_spawnp(
    pid: *mut libc::pid_t,
    file: *const c_char,
    file_actions: *const libc::posix_spawn_file_actions_t,
    attrp: *const libc::posix_spawnattr_t,
    argv: *const *mut c_char,
    envp: *const *mut c_char,
) -> c_int {
    if let Some(reason) = block_reason_for_exec(file, argv.cast()) {
        emit_policy_message(&reason);
        return libc::EACCES;
    }

    real_posix_spawnp()(pid, file, file_actions, attrp, argv, envp)
}

fn block_reason_for_exec(path: *const c_char, argv: *const *const c_char) -> Option<String> {
    let command_path = path_to_string(path);
    let argv = argv_to_vec(argv);

    let cwd = std::env::current_dir().ok();
    match evaluate_exec_policy(&command_path, &argv, cwd.as_deref()) {
        Ok(evaluation) => evaluation.deny_reason,
        Err(error) if git::looks_like_git_invocation(&command_path, &argv) => Some(error),
        Err(_) => None,
    }
}

fn evaluate_exec_policy(
    command_path: &str,
    argv: &[String],
    cwd: Option<&Path>,
) -> Result<PolicyEvaluation, String> {
    let is_git_invocation = git::looks_like_git_invocation(command_path, argv);
    let repo_root = cwd.and_then(config::discover_repo_root);
    let rules = config::load_rules(repo_root.as_deref())?;
    let candidates = git::build_command_candidates(command_path, argv);

    let deny_reason = find_matching_reason(&rules, &candidates);

    let _ = is_git_invocation;
    Ok(PolicyEvaluation { deny_reason })
}

unsafe fn real_execve() -> ExecveFn {
    std::mem::transmute(*EXECVE_SYMBOL.get_or_init(|| resolve_symbol_or_abort(b"execve\0")))
}

unsafe fn real_execveat() -> ExecveatFn {
    std::mem::transmute(*EXECVEAT_SYMBOL.get_or_init(|| resolve_symbol_or_abort(b"execveat\0")))
}

unsafe fn real_posix_spawn() -> PosixSpawnFn {
    std::mem::transmute(
        *POSIX_SPAWN_SYMBOL.get_or_init(|| resolve_symbol_or_abort(b"posix_spawn\0")),
    )
}

unsafe fn real_posix_spawnp() -> PosixSpawnFn {
    std::mem::transmute(
        *POSIX_SPAWNP_SYMBOL.get_or_init(|| resolve_symbol_or_abort(b"posix_spawnp\0")),
    )
}

fn resolve_symbol_or_abort(name: &'static [u8]) -> usize {
    let symbol = unsafe { libc::dlsym(libc::RTLD_NEXT, name.as_ptr().cast()) };
    if symbol.is_null() {
        emit_raw_message("control-plane exec policy: failed to resolve libc symbol\n");
        std::process::abort();
    }
    symbol as usize
}

fn emit_policy_message(reason: &str) {
    emit_raw_message(&format!("control-plane exec policy: {reason}\n"));
}

fn emit_raw_message(message: &str) {
    let bytes = message.as_bytes();
    unsafe {
        libc::write(
            libc::STDERR_FILENO,
            bytes.as_ptr().cast::<c_void>(),
            bytes.len(),
        );
    }
}

fn path_to_string(path: *const c_char) -> String {
    if path.is_null() {
        return String::new();
    }

    unsafe { CStr::from_ptr(path) }
        .to_string_lossy()
        .into_owned()
}

fn argv_to_vec(argv: *const *const c_char) -> Vec<String> {
    if argv.is_null() {
        return Vec::new();
    }

    let mut collected = Vec::new();
    let mut index = 0;
    loop {
        let current = unsafe { *argv.add(index) };
        if current.is_null() {
            break;
        }
        collected.push(
            unsafe { CStr::from_ptr(current) }
                .to_string_lossy()
                .into_owned(),
        );
        index += 1;
    }

    collected
}

fn set_errno(value: c_int) {
    unsafe {
        *libc::__errno_location() = value;
    }
}

fn find_matching_reason(
    rules: &[config::CompiledPatternEntry],
    candidates: &[String],
) -> Option<String> {
    rules.iter().find_map(|entry| {
        entry
            .regexes
            .iter()
            .any(|regex| candidates.iter().any(|candidate| regex.is_match(candidate)))
            .then(|| entry.reason.clone())
    })
}

#[cfg(test)]
mod tests {
    use super::find_matching_reason;
    use crate::config::CompiledPatternEntry;
    use regex::Regex;

    #[test]
    fn matches_normalized_candidates_against_rules() {
        let rules = vec![CompiledPatternEntry {
            reason: "repo-local policy".to_string(),
            regexes: vec![Regex::new("^git status(?: .+)? --short(?: |$)").unwrap()],
        }];

        let reason = find_matching_reason(&rules, &[String::from("git status --short")]);

        assert_eq!(reason.as_deref(), Some("repo-local policy"));
    }
}
