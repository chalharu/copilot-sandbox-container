use std::process::ExitCode;

fn main() -> ExitCode {
    match control_plane_runtime_tools::invocation::dispatch_main() {
        Ok(code) => ExitCode::from(code as u8),
        Err(error) => {
            if error.prefix.is_empty() {
                eprintln!("{}", error.message);
            } else {
                eprintln!("{}: {}", error.prefix, error.message);
            }
            ExitCode::from(error.code as u8)
        }
    }
}
