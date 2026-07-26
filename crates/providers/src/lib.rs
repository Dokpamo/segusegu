//! Provider-neutral model generation and an OpenAI-compatible adapter.

mod openai_compatible;

use async_trait::async_trait;
use lorepia_domain::{CoreResult, GenerationRequest, GenerationUsage, ProviderCapabilities};
use tokio::sync::{mpsc, watch};

pub use openai_compatible::OpenAiCompatibleProvider;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProviderEvent {
    TextDelta(String),
    ReasoningDelta(String),
}

pub type ProviderEventSender = mpsc::Sender<ProviderEvent>;

#[async_trait]
pub trait Provider: Send + Sync {
    fn capabilities(&self) -> ProviderCapabilities;

    async fn generate(
        &self,
        request: GenerationRequest,
        credential: Option<&str>,
        sink: ProviderEventSender,
        cancelled: watch::Receiver<bool>,
    ) -> CoreResult<GenerationUsage>;
}

/// Deterministic provider used by unit tests and offline previews.
pub struct StaticProvider {
    response: String,
}

impl StaticProvider {
    pub fn new(response: impl Into<String>) -> Self {
        Self {
            response: response.into(),
        }
    }
}

#[async_trait]
impl Provider for StaticProvider {
    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities {
            streaming: true,
            reasoning: false,
            max_context_tokens: None,
        }
    }

    async fn generate(
        &self,
        _request: GenerationRequest,
        _credential: Option<&str>,
        sink: ProviderEventSender,
        cancelled: watch::Receiver<bool>,
    ) -> CoreResult<GenerationUsage> {
        if *cancelled.borrow() {
            return Err(lorepia_domain::CoreError::new(
                lorepia_domain::CoreErrorCode::Cancelled,
                "generation was cancelled",
                true,
            ));
        }
        sink.send(ProviderEvent::TextDelta(self.response.clone()))
            .await
            .map_err(|_| lorepia_domain::CoreError::internal("provider event receiver closed"))?;
        Ok(GenerationUsage {
            input_tokens: None,
            output_tokens: None,
        })
    }
}
