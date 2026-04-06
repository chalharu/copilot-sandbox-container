#[derive(Debug)]
pub struct ToolError {
    pub code: i32,
    pub prefix: &'static str,
    pub message: String,
}

impl ToolError {
    pub fn new(code: i32, prefix: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            prefix,
            message: message.into(),
        }
    }
}

pub type ToolResult<T> = Result<T, ToolError>;
