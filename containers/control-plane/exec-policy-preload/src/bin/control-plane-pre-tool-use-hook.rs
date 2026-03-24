use control_plane_exec_policy::hook;
use std::io::{self, Read};

fn main() {
    let mut raw_input = String::new();
    if let Err(error) = io::stdin().read_to_string(&mut raw_input) {
        eprintln!("control-plane preToolUse hook: failed to read stdin: {error}");
        std::process::exit(1);
    }

    match hook::evaluate_pre_tool_use(&raw_input) {
        Ok(Some(decision)) => match serde_json::to_string(&decision) {
            Ok(output) => {
                print!("{output}");
            }
            Err(error) => {
                eprintln!("control-plane preToolUse hook: failed to serialize decision: {error}");
                std::process::exit(1);
            }
        },
        Ok(None) => {}
        Err(error) => {
            eprintln!("control-plane preToolUse hook: {error}");
            std::process::exit(1);
        }
    }
}
