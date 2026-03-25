pub mod command;
pub mod config;
pub mod hook;
mod policy;
mod shell;

use command::{CommandInvocation, EnvBinding};
use libc::{c_char, c_int, c_void};
use std::ffi::CStr;
use std::sync::OnceLock;

type ExecveFn =
    unsafe extern "C" fn(*const c_char, *const *const c_char, *const *const c_char) -> c_int;
type ExecvFn = unsafe extern "C" fn(*const c_char, *const *const c_char) -> c_int;
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

static EXECVE_SYMBOL: OnceLock<usize> = OnceLock::new();
static EXECV_SYMBOL: OnceLock<usize> = OnceLock::new();
static EXECVP_SYMBOL: OnceLock<usize> = OnceLock::new();
static EXECVPE_SYMBOL: OnceLock<usize> = OnceLock::new();
static EXECVEAT_SYMBOL: OnceLock<usize> = OnceLock::new();
static POSIX_SPAWN_SYMBOL: OnceLock<usize> = OnceLock::new();
static POSIX_SPAWNP_SYMBOL: OnceLock<usize> = OnceLock::new();

#[unsafe(no_mangle)]
/// # Safety
///
/// This function replaces libc's `execve` via `LD_PRELOAD` and must be called
/// with the same valid pointers and C ABI contract that libc expects.
pub unsafe extern "C" fn execve(
    filename: *const c_char,
    argv: *const *const c_char,
    envp: *const *const c_char,
) -> c_int {
    if let Some(reason) = block_reason_for_exec(filename, argv, envp) {
        emit_policy_message(&reason);
        set_errno(libc::EACCES);
        return -1;
    }

    unsafe { real_execve()(filename, argv, envp) }
}

#[unsafe(no_mangle)]
/// # Safety
///
/// This function replaces libc's `execv` via `LD_PRELOAD` and must be called
/// with the same valid pointers and C ABI contract that libc expects.
pub unsafe extern "C" fn execv(path: *const c_char, argv: *const *const c_char) -> c_int {
    if let Some(reason) = block_reason_for_exec(path, argv, std::ptr::null()) {
        emit_policy_message(&reason);
        set_errno(libc::EACCES);
        return -1;
    }

    unsafe { real_execv()(path, argv) }
}

#[unsafe(no_mangle)]
/// # Safety
///
/// This function replaces libc's `execvp` via `LD_PRELOAD` and must be called
/// with the same valid pointers and C ABI contract that libc expects.
pub unsafe extern "C" fn execvp(file: *const c_char, argv: *const *const c_char) -> c_int {
    if let Some(reason) = block_reason_for_exec(file, argv, std::ptr::null()) {
        emit_policy_message(&reason);
        set_errno(libc::EACCES);
        return -1;
    }

    unsafe { real_execvp()(file, argv) }
}

#[unsafe(no_mangle)]
/// # Safety
///
/// This function replaces libc's `execvpe` via `LD_PRELOAD` and must be called
/// with the same valid pointers and C ABI contract that libc expects.
pub unsafe extern "C" fn execvpe(
    file: *const c_char,
    argv: *const *const c_char,
    envp: *const *const c_char,
) -> c_int {
    if let Some(reason) = block_reason_for_exec(file, argv, envp) {
        emit_policy_message(&reason);
        set_errno(libc::EACCES);
        return -1;
    }

    unsafe { real_execvpe()(file, argv, envp) }
}

#[unsafe(no_mangle)]
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
    if let Some(reason) = block_reason_for_exec(pathname, argv, envp) {
        emit_policy_message(&reason);
        set_errno(libc::EACCES);
        return -1;
    }

    unsafe { real_execveat()(dirfd, pathname, argv, envp, flags) }
}

#[unsafe(no_mangle)]
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
    if let Some(reason) = block_reason_for_exec(path, argv.cast(), envp.cast()) {
        emit_policy_message(&reason);
        return libc::EACCES;
    }

    unsafe { real_posix_spawn()(pid, path, file_actions, attrp, argv, envp) }
}

#[unsafe(no_mangle)]
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
    if let Some(reason) = block_reason_for_exec(file, argv.cast(), envp.cast()) {
        emit_policy_message(&reason);
        return libc::EACCES;
    }

    unsafe { real_posix_spawnp()(pid, file, file_actions, attrp, argv, envp) }
}

fn block_reason_for_exec(
    path: *const c_char,
    argv: *const *const c_char,
    envp: *const *const c_char,
) -> Option<String> {
    let command_path = path_to_string(path);
    let argv = argv_to_vec(argv);
    let env_bindings = envp_to_bindings(envp);
    let cwd = std::env::current_dir().ok();
    let repo_root = cwd.as_deref().and_then(config::discover_repo_root).or(cwd);

    let rules = match config::load_rules(repo_root.as_deref()) {
        Ok(rules) => rules,
        Err(error) => {
            emit_policy_message(&format!("failed to load rules: {error}"));
            return None;
        }
    };

    let mut invocation = CommandInvocation::from_exec(&command_path, &argv, env_bindings)?;
    for _ in 0..4 {
        if let Some(reason) = policy::match_exec_rule(&rules, &invocation) {
            return Some(reason);
        }
        let Some(next_invocation) = invocation.unwrap_env_wrapper() else {
            break;
        };
        invocation = next_invocation;
    }
    None
}

unsafe fn real_execve() -> ExecveFn {
    unsafe {
        std::mem::transmute(*EXECVE_SYMBOL.get_or_init(|| resolve_symbol_or_abort(b"execve\0")))
    }
}

unsafe fn real_execv() -> ExecvFn {
    unsafe {
        std::mem::transmute(*EXECV_SYMBOL.get_or_init(|| resolve_symbol_or_abort(b"execv\0")))
    }
}

unsafe fn real_execvp() -> ExecvFn {
    unsafe {
        std::mem::transmute(*EXECVP_SYMBOL.get_or_init(|| resolve_symbol_or_abort(b"execvp\0")))
    }
}

unsafe fn real_execvpe() -> ExecveFn {
    unsafe {
        std::mem::transmute(*EXECVPE_SYMBOL.get_or_init(|| resolve_symbol_or_abort(b"execvpe\0")))
    }
}

unsafe fn real_execveat() -> ExecveatFn {
    unsafe {
        std::mem::transmute(*EXECVEAT_SYMBOL.get_or_init(|| resolve_symbol_or_abort(b"execveat\0")))
    }
}

unsafe fn real_posix_spawn() -> PosixSpawnFn {
    unsafe {
        std::mem::transmute(
            *POSIX_SPAWN_SYMBOL.get_or_init(|| resolve_symbol_or_abort(b"posix_spawn\0")),
        )
    }
}

unsafe fn real_posix_spawnp() -> PosixSpawnFn {
    unsafe {
        std::mem::transmute(
            *POSIX_SPAWNP_SYMBOL.get_or_init(|| resolve_symbol_or_abort(b"posix_spawnp\0")),
        )
    }
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

fn envp_to_bindings(envp: *const *const c_char) -> Vec<EnvBinding> {
    if envp.is_null() {
        return std::env::vars()
            .map(|(name, value)| EnvBinding {
                name,
                value: Some(value),
            })
            .collect();
    }

    let mut bindings = Vec::new();
    let mut index = 0;
    loop {
        let current = unsafe { *envp.add(index) };
        if current.is_null() {
            break;
        }
        let raw = unsafe { CStr::from_ptr(current) }
            .to_string_lossy()
            .into_owned();
        if let Some((name, value)) = raw.split_once('=') {
            bindings.push(EnvBinding {
                name: name.to_string(),
                value: Some(value.to_string()),
            });
        }
        index += 1;
    }
    bindings
}

fn set_errno(value: c_int) {
    unsafe {
        *libc::__errno_location() = value;
    }
}

#[cfg(test)]
mod tests {
    use crate::command::CommandInvocation;
    use crate::config::{CompiledConfig, CompiledRule};
    use crate::policy::match_exec_rule;
    use regex::Regex;

    #[test]
    fn exec_rule_matching_uses_token_sequences() {
        let config = CompiledConfig {
            command_rules: vec![CompiledRule {
                reason: "blocked".to_string(),
                basename_pattern: Regex::new("^(?:git)$").unwrap(),
                command_patterns: vec![Regex::new("^(?:push)$").unwrap()],
                option_patterns: vec![Regex::new("^(?:-f)$").unwrap()],
            }],
            protected_environments: vec![Regex::new("^(?:GIT_CONFIG_GLOBAL)$").unwrap()],
        };
        let invocation = CommandInvocation::from_exec(
            "git",
            &["git".to_string(), "push".to_string(), "-f".to_string()],
            Vec::new(),
        )
        .unwrap();

        assert_eq!(
            match_exec_rule(&config, &invocation).as_deref(),
            Some("blocked")
        );
    }
}
