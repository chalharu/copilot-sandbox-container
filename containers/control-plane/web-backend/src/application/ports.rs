use crate::domain::chat::{PromptInput, PromptOutput};
use async_trait::async_trait;

#[async_trait]
pub trait PromptGateway: Send + Sync {
    async fn prompt(&self, input: PromptInput) -> Result<PromptOutput, String>;
}
