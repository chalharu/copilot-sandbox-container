pub mod command;
pub mod config;
pub mod hook;
mod policy;
mod shell;

use command::{CommandInvocation, EnvBinding};
use libc::{c_char, c_int, c_void};
use std::cell::Cell;
use std::ffi::{CStr, OsString};
use std::path::{Path, PathBuf};
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
type OpenFn = unsafe extern "C" fn(*const c_char, c_int, libc::mode_t) -> c_int;
type OpenatFn = unsafe extern "C" fn(c_int, *const c_char, c_int, libc::mode_t) -> c_int;
type Open2Fn = unsafe extern "C" fn(*const c_char, c_int) -> c_int;
type Openat2Fn = unsafe extern "C" fn(c_int, *const c_char, c_int) -> c_int;
type FopenFn = unsafe extern "C" fn(*const c_char, *const c_char) -> *mut libc::FILE;
type FreopenFn =
    unsafe extern "C" fn(*const c_char, *const c_char, *mut libc::FILE) -> *mut libc::FILE;

static EXECVE_SYMBOL: OnceLock<usize> = OnceLock::new();
static EXECV_SYMBOL: OnceLock<usize> = OnceLock::new();
static EXECVP_SYMBOL: OnceLock<usize> = OnceLock::new();
static EXECVPE_SYMBOL: OnceLock<usize> = OnceLock::new();
static EXECVEAT_SYMBOL: OnceLock<usize> = OnceLock::new();
static POSIX_SPAWN_SYMBOL: OnceLock<usize> = OnceLock::new();
static POSIX_SPAWNP_SYMBOL: OnceLock<usize> = OnceLock::new();
static OPEN_SYMBOL: OnceLock<usize> = OnceLock::new();
static OPEN64_SYMBOL: OnceLock<usize> = OnceLock::new();
static OPENAT_SYMBOL: OnceLock<usize> = OnceLock::new();
static OPENAT64_SYMBOL: OnceLock<usize> = OnceLock::new();
static OPEN_2_SYMBOL: OnceLock<usize> = OnceLock::new();
static OPEN64_2_SYMBOL: OnceLock<usize> = OnceLock::new();
static OPENAT_2_SYMBOL: OnceLock<usize> = OnceLock::new();
static OPENAT64_2_SYMBOL: OnceLock<usize> = OnceLock::new();
static FOPEN_SYMBOL: OnceLock<usize> = OnceLock::new();
static FOPEN64_SYMBOL: OnceLock<usize> = OnceLock::new();
static FREOPEN_SYMBOL: OnceLock<usize> = OnceLock::new();
static FREOPEN64_SYMBOL: OnceLock<usize> = OnceLock::new();

const TRUSTED_SHELL_INTERPRETER_PATHS: &[&str] = &[
    "/usr/bin/bash",
    "/bin/bash",
    "/usr/bin/sh",
    "/bin/sh",
    "/usr/bin/dash",
    "/bin/dash",
];

thread_local! {
    static POLICY_EVALUATION_DEPTH: Cell<usize> = const { Cell::new(0) };
}

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

#[unsafe(no_mangle)]
/// # Safety
///
/// This function replaces libc's `open` via `LD_PRELOAD` and must be called
/// with the same valid pointers, flags, and mode value that libc expects.
pub unsafe extern "C" fn open(pathname: *const c_char, flags: c_int, mode: libc::mode_t) -> c_int {
    if let Some(reason) = block_reason_for_file_access(pathname, libc::AT_FDCWD) {
        emit_policy_message(&reason);
        set_errno(libc::EACCES);
        return -1;
    }

    unsafe { real_open()(pathname, flags, mode) }
}

#[unsafe(no_mangle)]
/// # Safety
///
/// This function replaces libc's `open64` via `LD_PRELOAD` and must be called
/// with the same valid pointers, flags, and mode value that libc expects.
pub unsafe extern "C" fn open64(
    pathname: *const c_char,
    flags: c_int,
    mode: libc::mode_t,
) -> c_int {
    if let Some(reason) = block_reason_for_file_access(pathname, libc::AT_FDCWD) {
        emit_policy_message(&reason);
        set_errno(libc::EACCES);
        return -1;
    }

    unsafe { real_open64()(pathname, flags, mode) }
}

#[unsafe(no_mangle)]
/// # Safety
///
/// This function replaces libc's `openat` via `LD_PRELOAD` and must be called
/// with the same valid dirfd, pointers, flags, and mode value that libc expects.
pub unsafe extern "C" fn openat(
    dirfd: c_int,
    pathname: *const c_char,
    flags: c_int,
    mode: libc::mode_t,
) -> c_int {
    if let Some(reason) = block_reason_for_file_access(pathname, dirfd) {
        emit_policy_message(&reason);
        set_errno(libc::EACCES);
        return -1;
    }

    unsafe { real_openat()(dirfd, pathname, flags, mode) }
}

#[unsafe(no_mangle)]
/// # Safety
///
/// This function replaces libc's `openat64` via `LD_PRELOAD` and must be called
/// with the same valid dirfd, pointers, flags, and mode value that libc expects.
pub unsafe extern "C" fn openat64(
    dirfd: c_int,
    pathname: *const c_char,
    flags: c_int,
    mode: libc::mode_t,
) -> c_int {
    if let Some(reason) = block_reason_for_file_access(pathname, dirfd) {
        emit_policy_message(&reason);
        set_errno(libc::EACCES);
        return -1;
    }

    unsafe { real_openat64()(dirfd, pathname, flags, mode) }
}

#[unsafe(no_mangle)]
/// # Safety
///
/// This function replaces glibc's `__open_2` via `LD_PRELOAD` and must be
/// called with the same valid pointers and flags that libc expects.
pub unsafe extern "C" fn __open_2(pathname: *const c_char, flags: c_int) -> c_int {
    if let Some(reason) = block_reason_for_file_access(pathname, libc::AT_FDCWD) {
        emit_policy_message(&reason);
        set_errno(libc::EACCES);
        return -1;
    }

    unsafe { real_open_2()(pathname, flags) }
}

#[unsafe(no_mangle)]
/// # Safety
///
/// This function replaces glibc's `__open64_2` via `LD_PRELOAD` and must be
/// called with the same valid pointers and flags that libc expects.
pub unsafe extern "C" fn __open64_2(pathname: *const c_char, flags: c_int) -> c_int {
    if let Some(reason) = block_reason_for_file_access(pathname, libc::AT_FDCWD) {
        emit_policy_message(&reason);
        set_errno(libc::EACCES);
        return -1;
    }

    unsafe { real_open64_2()(pathname, flags) }
}

#[unsafe(no_mangle)]
/// # Safety
///
/// This function replaces glibc's `__openat_2` via `LD_PRELOAD` and must be
/// called with the same valid dirfd, pointers, and flags that libc expects.
pub unsafe extern "C" fn __openat_2(dirfd: c_int, pathname: *const c_char, flags: c_int) -> c_int {
    if let Some(reason) = block_reason_for_file_access(pathname, dirfd) {
        emit_policy_message(&reason);
        set_errno(libc::EACCES);
        return -1;
    }

    unsafe { real_openat_2()(dirfd, pathname, flags) }
}

#[unsafe(no_mangle)]
/// # Safety
///
/// This function replaces glibc's `__openat64_2` via `LD_PRELOAD` and must be
/// called with the same valid dirfd, pointers, and flags that libc expects.
pub unsafe extern "C" fn __openat64_2(
    dirfd: c_int,
    pathname: *const c_char,
    flags: c_int,
) -> c_int {
    if let Some(reason) = block_reason_for_file_access(pathname, dirfd) {
        emit_policy_message(&reason);
        set_errno(libc::EACCES);
        return -1;
    }

    unsafe { real_openat64_2()(dirfd, pathname, flags) }
}

#[unsafe(no_mangle)]
/// # Safety
///
/// This function replaces libc's `fopen` via `LD_PRELOAD` and must be called
/// with the same valid pointers that libc expects.
pub unsafe extern "C" fn fopen(pathname: *const c_char, mode: *const c_char) -> *mut libc::FILE {
    if let Some(reason) = block_reason_for_file_access(pathname, libc::AT_FDCWD) {
        emit_policy_message(&reason);
        set_errno(libc::EACCES);
        return std::ptr::null_mut();
    }

    unsafe { real_fopen()(pathname, mode) }
}

#[unsafe(no_mangle)]
/// # Safety
///
/// This function replaces libc's `fopen64` via `LD_PRELOAD` and must be called
/// with the same valid pointers that libc expects.
pub unsafe extern "C" fn fopen64(pathname: *const c_char, mode: *const c_char) -> *mut libc::FILE {
    if let Some(reason) = block_reason_for_file_access(pathname, libc::AT_FDCWD) {
        emit_policy_message(&reason);
        set_errno(libc::EACCES);
        return std::ptr::null_mut();
    }

    unsafe { real_fopen64()(pathname, mode) }
}

#[unsafe(no_mangle)]
/// # Safety
///
/// This function replaces libc's `freopen` via `LD_PRELOAD` and must be called
/// with the same valid pointers that libc expects.
pub unsafe extern "C" fn freopen(
    pathname: *const c_char,
    mode: *const c_char,
    stream: *mut libc::FILE,
) -> *mut libc::FILE {
    if let Some(reason) = block_reason_for_file_access(pathname, libc::AT_FDCWD) {
        emit_policy_message(&reason);
        set_errno(libc::EACCES);
        return std::ptr::null_mut();
    }

    unsafe { real_freopen()(pathname, mode, stream) }
}

#[unsafe(no_mangle)]
/// # Safety
///
/// This function replaces libc's `freopen64` via `LD_PRELOAD` and must be
/// called with the same valid pointers that libc expects.
pub unsafe extern "C" fn freopen64(
    pathname: *const c_char,
    mode: *const c_char,
    stream: *mut libc::FILE,
) -> *mut libc::FILE {
    if let Some(reason) = block_reason_for_file_access(pathname, libc::AT_FDCWD) {
        emit_policy_message(&reason);
        set_errno(libc::EACCES);
        return std::ptr::null_mut();
    }

    unsafe { real_freopen64()(pathname, mode, stream) }
}

fn block_reason_for_exec(
    path: *const c_char,
    argv: *const *const c_char,
    envp: *const *const c_char,
) -> Option<String> {
    if policy_guard_active() {
        return None;
    }

    with_policy_guard(|| block_reason_for_exec_impl(path, argv, envp))
}

fn block_reason_for_exec_impl(
    path: *const c_char,
    argv: *const *const c_char,
    envp: *const *const c_char,
) -> Option<String> {
    let command_path = path_to_string(path);
    let argv = argv_to_vec(argv);
    let env_bindings = envp_to_bindings(envp);
    let rules = match load_rules_for_current_process() {
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

fn block_reason_for_file_access(path: *const c_char, dirfd: c_int) -> Option<String> {
    if policy_guard_active() {
        return None;
    }

    with_policy_guard(|| block_reason_for_file_access_impl(path, dirfd))
}

fn block_reason_for_file_access_impl(path: *const c_char, dirfd: c_int) -> Option<String> {
    let raw_path = path_to_string(path);
    let candidate_paths = resolve_candidate_paths(&raw_path, dirfd);
    if candidate_paths.is_empty() {
        return None;
    }

    let rules = match load_rules_for_current_process() {
        Ok(rules) => rules,
        Err(error) => {
            emit_policy_message(&format!("failed to load rules: {error}"));
            return None;
        }
    };

    let process_names_storage = current_process_names();
    let process_names = process_names_storage
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>();
    candidate_paths
        .iter()
        .find_map(|candidate| policy::match_file_access_rule(&rules, &process_names, candidate))
}

pub(crate) fn policy_guard_active() -> bool {
    POLICY_EVALUATION_DEPTH.with(|depth| depth.get() > 0)
}

pub(crate) fn with_policy_guard<T>(operation: impl FnOnce() -> T) -> T {
    POLICY_EVALUATION_DEPTH.with(|depth| {
        depth.set(depth.get() + 1);
        let result = operation();
        depth.set(depth.get() - 1);
        result
    })
}

fn load_rules_for_current_process() -> Result<config::CompiledConfig, String> {
    let cwd = std::env::current_dir().ok();
    let repo_root = cwd.as_deref().and_then(config::discover_repo_root).or(cwd);
    config::load_rules(repo_root.as_deref())
}

fn current_process_names() -> Vec<String> {
    let args = std::env::args_os().collect::<Vec<_>>();
    let current_exe = std::env::current_exe().ok();

    collect_process_names(&args, current_exe.as_deref())
}

fn collect_process_names(args: &[OsString], current_exe: Option<&Path>) -> Vec<String> {
    let mut names = Vec::new();
    let shell_script_interpreter = current_exe
        .map(is_shell_script_interpreter_path)
        .unwrap_or(false);

    if let Some(argv0) = args.first().and_then(os_string_to_non_empty_string) {
        push_unique_string(&mut names, argv0);
    }
    if let Some(exe_path) = current_exe.and_then(path_to_non_empty_string) {
        push_unique_string(&mut names, exe_path);
    }

    if shell_script_interpreter {
        for arg in args.iter().skip(1) {
            let Some(raw_arg) = arg.to_str() else {
                continue;
            };
            if raw_arg.is_empty() || raw_arg.starts_with('-') {
                continue;
            }
            if let Some(script_path) = os_string_to_non_empty_string(arg) {
                push_unique_string(&mut names, script_path);
                break;
            }
        }
    }

    names
}

fn os_string_to_non_empty_string(value: &OsString) -> Option<String> {
    let raw = value.to_str()?;
    if raw.is_empty() {
        return None;
    }

    Some(raw.to_string())
}

fn path_to_non_empty_string(value: &Path) -> Option<String> {
    let raw = value.to_str()?;
    if raw.is_empty() {
        return None;
    }

    Some(raw.to_string())
}

fn is_shell_script_interpreter_path(value: &Path) -> bool {
    if let Some(path) = value.to_str() {
        return TRUSTED_SHELL_INTERPRETER_PATHS.contains(&path);
    }

    false
}

fn resolve_candidate_paths(path: &str, dirfd: c_int) -> Vec<String> {
    if path.is_empty() {
        return Vec::new();
    }

    let mut candidates = Vec::new();
    push_unique_string(&mut candidates, path.to_string());

    let requested_path = Path::new(path);
    let resolved_path = if requested_path.is_absolute() {
        Some(requested_path.to_path_buf())
    } else {
        base_directory_for_dirfd(dirfd).map(|base_dir| base_dir.join(requested_path))
    };

    if let Some(resolved_path) = resolved_path {
        push_unique_string(
            &mut candidates,
            resolved_path.to_string_lossy().into_owned(),
        );
        if let Ok(canonical_path) = resolved_path.canonicalize() {
            push_unique_string(
                &mut candidates,
                canonical_path.to_string_lossy().into_owned(),
            );
        }
    }

    candidates
}

fn base_directory_for_dirfd(dirfd: c_int) -> Option<PathBuf> {
    if dirfd == libc::AT_FDCWD {
        return std::env::current_dir().ok();
    }

    std::fs::read_link(format!("/proc/self/fd/{dirfd}")).ok()
}

fn push_unique_string(values: &mut Vec<String>, value: String) {
    if !values.iter().any(|existing| existing == &value) {
        values.push(value);
    }
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

unsafe fn real_open() -> OpenFn {
    unsafe { std::mem::transmute(*OPEN_SYMBOL.get_or_init(|| resolve_symbol_or_abort(b"open\0"))) }
}

unsafe fn real_open64() -> OpenFn {
    unsafe {
        std::mem::transmute(*OPEN64_SYMBOL.get_or_init(|| resolve_symbol_or_abort(b"open64\0")))
    }
}

unsafe fn real_openat() -> OpenatFn {
    unsafe {
        std::mem::transmute(*OPENAT_SYMBOL.get_or_init(|| resolve_symbol_or_abort(b"openat\0")))
    }
}

unsafe fn real_openat64() -> OpenatFn {
    unsafe {
        std::mem::transmute(*OPENAT64_SYMBOL.get_or_init(|| resolve_symbol_or_abort(b"openat64\0")))
    }
}

unsafe fn real_open_2() -> Open2Fn {
    unsafe {
        std::mem::transmute(*OPEN_2_SYMBOL.get_or_init(|| resolve_symbol_or_abort(b"__open_2\0")))
    }
}

unsafe fn real_open64_2() -> Open2Fn {
    unsafe {
        std::mem::transmute(
            *OPEN64_2_SYMBOL.get_or_init(|| resolve_symbol_or_abort(b"__open64_2\0")),
        )
    }
}

unsafe fn real_openat_2() -> Openat2Fn {
    unsafe {
        std::mem::transmute(
            *OPENAT_2_SYMBOL.get_or_init(|| resolve_symbol_or_abort(b"__openat_2\0")),
        )
    }
}

unsafe fn real_openat64_2() -> Openat2Fn {
    unsafe {
        std::mem::transmute(
            *OPENAT64_2_SYMBOL.get_or_init(|| resolve_symbol_or_abort(b"__openat64_2\0")),
        )
    }
}

unsafe fn real_fopen() -> FopenFn {
    unsafe {
        std::mem::transmute(*FOPEN_SYMBOL.get_or_init(|| resolve_symbol_or_abort(b"fopen\0")))
    }
}

unsafe fn real_fopen64() -> FopenFn {
    unsafe {
        std::mem::transmute(*FOPEN64_SYMBOL.get_or_init(|| resolve_symbol_or_abort(b"fopen64\0")))
    }
}

unsafe fn real_freopen() -> FreopenFn {
    unsafe {
        std::mem::transmute(*FREOPEN_SYMBOL.get_or_init(|| resolve_symbol_or_abort(b"freopen\0")))
    }
}

unsafe fn real_freopen64() -> FreopenFn {
    unsafe {
        std::mem::transmute(
            *FREOPEN64_SYMBOL.get_or_init(|| resolve_symbol_or_abort(b"freopen64\0")),
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
    use super::collect_process_names;
    use crate::command::CommandInvocation;
    use crate::config::{CompiledConfig, CompiledRule};
    use crate::policy::match_exec_rule;
    use regex::{Regex, bytes::Regex as BytesRegex};
    use std::ffi::OsString;
    use std::path::Path;

    #[test]
    fn exec_rule_matching_uses_token_sequences() {
        let config = CompiledConfig {
            command_rules: vec![CompiledRule {
                reason: "blocked".to_string(),
                pattern: BytesRegex::new(
                    r"git(?:\x00[^\x00]+)*\x00push(?:\x00[^\x00]+)*\x00-f(?:\x00[^\x00]+)*",
                )
                .unwrap(),
            }],
            protected_environments: vec![Regex::new("^(?:GIT_CONFIG_GLOBAL)$").unwrap()],
            file_access_rules: Vec::new(),
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

    #[test]
    fn collect_process_names_keeps_absolute_binary_paths() {
        let names = collect_process_names(
            &[
                OsString::from("gh"),
                OsString::from("auth"),
                OsString::from("status"),
            ],
            Some(Path::new("/usr/bin/gh")),
        );

        assert_eq!(names, vec!["gh".to_string(), "/usr/bin/gh".to_string()]);
    }

    #[test]
    fn collect_process_names_uses_shell_script_path_instead_of_basename() {
        let names = collect_process_names(
            &[
                OsString::from("bash"),
                OsString::from("/usr/local/bin/podman"),
                OsString::from("pull"),
            ],
            Some(Path::new("/usr/bin/bash")),
        );

        assert_eq!(
            names,
            vec![
                "bash".to_string(),
                "/usr/bin/bash".to_string(),
                "/usr/local/bin/podman".to_string(),
            ]
        );
        assert!(!names.iter().any(|name| name == "podman"));
    }

    #[test]
    fn collect_process_names_does_not_trust_spoofed_shell_argv0() {
        let names = collect_process_names(
            &[
                OsString::from("bash"),
                OsString::from("/usr/bin/gh"),
                OsString::from("auth"),
            ],
            Some(Path::new("/tmp/not-a-shell")),
        );

        assert_eq!(
            names,
            vec!["bash".to_string(), "/tmp/not-a-shell".to_string()]
        );
        assert!(!names.iter().any(|name| name == "/usr/bin/gh"));
    }

    #[test]
    fn collect_process_names_does_not_trust_untrusted_shell_path() {
        let names = collect_process_names(
            &[
                OsString::from("/tmp/bash"),
                OsString::from("/usr/bin/gh"),
                OsString::from("auth"),
            ],
            Some(Path::new("/tmp/bash")),
        );

        assert_eq!(names, vec!["/tmp/bash".to_string()]);
        assert!(!names.iter().any(|name| name == "/usr/bin/gh"));
    }
}
