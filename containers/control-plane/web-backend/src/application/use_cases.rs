use crate::application::ports::PromptGateway;
use crate::domain::chat::{PromptInput, PromptOutput};
use std::sync::Arc;

#[derive(Clone)]
pub struct SubmitPromptUseCase {
    gateway: Arc<dyn PromptGateway>,
}

impl SubmitPromptUseCase {
    pub fn new(gateway: Arc<dyn PromptGateway>) -> Self {
        Self { gateway }
    }

    pub async fn execute(&self, prompt: String) -> Result<PromptOutput, String> {
        let input = PromptInput::new(prompt)?;
        self.gateway.prompt(input).await
    }
}

#[cfg(test)]
mod tests {
    use super::SubmitPromptUseCase;
    use crate::application::ports::PromptGateway;
    use crate::domain::chat::{PromptInput, PromptOutput};
    use async_trait::async_trait;
    use std::sync::Arc;

    struct FakePromptGateway {
        response: Result<PromptOutput, String>,
    }

    #[async_trait]
    impl PromptGateway for FakePromptGateway {
        async fn prompt(&self, _input: PromptInput) -> Result<PromptOutput, String> {
            self.response.clone()
        }
    }

    #[tokio::test]
    async fn rejects_empty_prompt() {
        let gateway = Arc::new(FakePromptGateway {
            response: Ok(PromptOutput {
                text: String::from("unused"),
            }),
        });
        let use_case = SubmitPromptUseCase::new(gateway);

        let result = use_case.execute(String::from("   ")).await;

        assert_eq!(result, Err(String::from("prompt must not be empty")));
    }

    #[tokio::test]
    async fn returns_gateway_response() {
        let gateway = Arc::new(FakePromptGateway {
            response: Ok(PromptOutput {
                text: String::from("reply"),
            }),
        });
        let use_case = SubmitPromptUseCase::new(gateway);

        let result = use_case.execute(String::from("hello")).await;

        assert_eq!(
            result,
            Ok(PromptOutput {
                text: String::from("reply"),
            })
        );
    }
}

