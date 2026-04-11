#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PromptInput {
    text: String,
}

impl PromptInput {
    pub fn new(text: String) -> Result<Self, String> {
        let normalized = text.trim();
        if normalized.is_empty() {
            return Err(String::from("prompt must not be empty"));
        }
        Ok(Self {
            text: normalized.to_string(),
        })
    }

    pub fn text(&self) -> &str {
        &self.text
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PromptOutput {
    pub text: String,
}
