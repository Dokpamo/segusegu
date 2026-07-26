use lorepia_domain::{CoreError, CoreErrorCode, CoreResult, GenerationRequest, GenerationUsage};
use lorepia_providers::{Provider, ProviderEvent};
use tokio::sync::{mpsc, watch};

use crate::{ChatEvent, ChatEventKind};

/// Maximum cumulative UTF-8 bytes accepted from text and reasoning deltas.
pub const MAX_GENERATED_OUTPUT_BYTES: usize = 256 * 1024;
/// Maximum cumulative Unicode scalars accepted from text and reasoning deltas.
pub const MAX_GENERATED_OUTPUT_CHARS: usize = 64 * 1024;
/// Stable failure text emitted when a provider ignores the output safety bound.
pub const OUTPUT_LIMIT_ERROR_MESSAGE: &str =
    "provider output exceeded the 262144-byte or 65536-character safety limit";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GenerationOutcome {
    pub text: String,
    pub usage: GenerationUsage,
    pub last_sequence: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GenerationFailure {
    pub error: CoreError,
    pub partial_text: String,
    pub last_sequence: u64,
}

struct GenerationAccumulator {
    generation_id: lorepia_domain::GenerationId,
    conversation_id: lorepia_domain::ConversationId,
    text: String,
    output_bytes: usize,
    output_chars: usize,
    sequence: u64,
}

impl GenerationAccumulator {
    fn failure(&self, error: CoreError) -> GenerationFailure {
        GenerationFailure {
            error,
            partial_text: self.text.clone(),
            last_sequence: self.sequence,
        }
    }

    async fn forward(
        &mut self,
        event: ProviderEvent,
        events: &mpsc::Sender<ChatEvent>,
    ) -> CoreResult<()> {
        let delta = match &event {
            ProviderEvent::TextDelta(delta) | ProviderEvent::ReasoningDelta(delta) => delta,
        };
        let next_bytes = self
            .output_bytes
            .checked_add(delta.len())
            .ok_or_else(output_limit_error)?;
        let next_chars = self
            .output_chars
            .checked_add(delta.chars().count())
            .ok_or_else(output_limit_error)?;
        if next_bytes > MAX_GENERATED_OUTPUT_BYTES || next_chars > MAX_GENERATED_OUTPUT_CHARS {
            return Err(output_limit_error());
        }
        self.output_bytes = next_bytes;
        self.output_chars = next_chars;
        self.sequence = self.sequence.saturating_add(1);
        let kind = match event {
            ProviderEvent::TextDelta(delta) => {
                self.text.push_str(&delta);
                ChatEventKind::TextDelta(delta)
            }
            ProviderEvent::ReasoningDelta(delta) => ChatEventKind::ReasoningDelta(delta),
        };
        send_event(
            events,
            ChatEvent::new(
                self.generation_id.clone(),
                self.conversation_id.clone(),
                self.sequence,
                kind,
            ),
        )
        .await
    }
}

pub async fn run_generation(
    provider: &dyn Provider,
    request: GenerationRequest,
    credential: Option<&str>,
    events: mpsc::Sender<ChatEvent>,
    cancelled: watch::Receiver<bool>,
) -> Result<GenerationOutcome, GenerationFailure> {
    let mut state = GenerationAccumulator {
        generation_id: request.generation_id.clone(),
        conversation_id: request.conversation_id.clone(),
        text: String::new(),
        output_bytes: 0,
        output_chars: 0,
        sequence: 1,
    };
    send_event(
        &events,
        ChatEvent::new(
            state.generation_id.clone(),
            state.conversation_id.clone(),
            state.sequence,
            ChatEventKind::GenerationStarted,
        ),
    )
    .await
    .map_err(|error| state.failure(error))?;

    let result = collect_provider_events(
        provider, request, credential, &events, cancelled, &mut state,
    )
    .await?;
    match result {
        Ok(usage) => {
            state.sequence = state.sequence.saturating_add(1);
            send_event(
                &events,
                ChatEvent::new(
                    state.generation_id.clone(),
                    state.conversation_id.clone(),
                    state.sequence,
                    ChatEventKind::UsageUpdated(usage.clone()),
                ),
            )
            .await
            .map_err(|error| state.failure(error))?;
            Ok(GenerationOutcome {
                text: state.text,
                usage,
                last_sequence: state.sequence,
            })
        }
        Err(error) => Err(GenerationFailure {
            error,
            partial_text: state.text,
            last_sequence: state.sequence,
        }),
    }
}

async fn collect_provider_events(
    provider: &dyn Provider,
    request: GenerationRequest,
    credential: Option<&str>,
    events: &mpsc::Sender<ChatEvent>,
    cancelled: watch::Receiver<bool>,
    state: &mut GenerationAccumulator,
) -> Result<CoreResult<GenerationUsage>, GenerationFailure> {
    let (provider_sender, mut provider_events) = mpsc::channel(64);
    let generation = provider.generate(request, credential, provider_sender, cancelled);
    tokio::pin!(generation);
    let mut provider_open = true;
    let result = loop {
        tokio::select! {
            event = provider_events.recv(), if provider_open => {
                match event {
                    Some(event) => state
                        .forward(event, events)
                        .await
                        .map_err(|error| state.failure(error))?,
                    None => provider_open = false,
                }
            }
            result = &mut generation => break result,
        }
    };

    // Completion and the final delta may share one scheduler tick.
    while let Some(event) = provider_events.recv().await {
        state
            .forward(event, events)
            .await
            .map_err(|error| state.failure(error))?;
    }
    Ok(result)
}

fn output_limit_error() -> CoreError {
    CoreError::new(
        CoreErrorCode::ProviderUnavailable,
        OUTPUT_LIMIT_ERROR_MESSAGE,
        false,
    )
}

async fn send_event(events: &mpsc::Sender<ChatEvent>, event: ChatEvent) -> CoreResult<()> {
    events
        .send(event)
        .await
        .map_err(|_| lorepia_domain::CoreError::internal("chat event receiver closed"))
}

#[cfg(test)]
mod tests {
    use async_trait::async_trait;
    use lorepia_domain::{
        ConversationId, GenerationId, GenerationRequest, GenerationUsage, ProviderCapabilities,
    };
    use lorepia_providers::{ProviderEventSender, StaticProvider};

    use super::*;

    #[tokio::test]
    async fn emits_monotonic_sequence_and_collects_text() {
        let provider = StaticProvider::new("Hello");
        let (events, mut receiver) = mpsc::channel(16);
        let (_cancel, cancelled) = watch::channel(false);
        let request = GenerationRequest {
            generation_id: GenerationId::new(),
            conversation_id: ConversationId::new(),
            model: "static".to_owned(),
            messages: Vec::new(),
            temperature: 1.0,
            max_output_tokens: None,
        };

        let outcome = run_generation(&provider, request, None, events, cancelled)
            .await
            .expect("generation");
        assert_eq!(outcome.text, "Hello");
        assert!(outcome.last_sequence >= 2);

        let mut sequences = Vec::new();
        while let Ok(event) = receiver.try_recv() {
            sequences.push(event.sequence);
        }
        assert!(sequences.windows(2).all(|pair| pair[0] < pair[1]));
    }

    struct ChunkProvider {
        chunks: Vec<String>,
    }

    #[async_trait]
    impl Provider for ChunkProvider {
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
            _cancelled: watch::Receiver<bool>,
        ) -> CoreResult<GenerationUsage> {
            for chunk in &self.chunks {
                sink.send(ProviderEvent::TextDelta(chunk.clone()))
                    .await
                    .map_err(|_| CoreError::internal("provider event receiver closed"))?;
            }
            Ok(GenerationUsage::default())
        }
    }

    fn request() -> GenerationRequest {
        GenerationRequest {
            generation_id: GenerationId::new(),
            conversation_id: ConversationId::new(),
            model: "static".to_owned(),
            messages: Vec::new(),
            temperature: 1.0,
            max_output_tokens: Some(4_096),
        }
    }

    #[tokio::test]
    async fn accepts_output_at_the_exact_multibyte_utf8_boundary() {
        let output = "😀".repeat(MAX_GENERATED_OUTPUT_CHARS);
        assert_eq!(output.len(), MAX_GENERATED_OUTPUT_BYTES);
        let provider = ChunkProvider {
            chunks: vec![output.clone()],
        };
        let (events, _receiver) = mpsc::channel(16);
        let (_cancel, cancelled) = watch::channel(false);

        let outcome = run_generation(&provider, request(), None, events, cancelled)
            .await
            .expect("exact boundary");
        assert_eq!(outcome.text, output);
    }

    #[tokio::test]
    async fn rejects_complete_multibyte_scalar_over_limit_and_preserves_safe_partial() {
        let safe_partial = "😀".repeat(MAX_GENERATED_OUTPUT_CHARS);
        let provider = ChunkProvider {
            chunks: vec![safe_partial.clone(), "😀".to_owned()],
        };
        let (events, mut receiver) = mpsc::channel(16);
        let (_cancel, cancelled) = watch::channel(false);

        let failure = run_generation(&provider, request(), None, events, cancelled)
            .await
            .expect_err("provider must be bounded");
        assert_eq!(failure.error.code, CoreErrorCode::ProviderUnavailable);
        assert_eq!(failure.error.message, OUTPUT_LIMIT_ERROR_MESSAGE);
        assert!(!failure.error.recoverable);
        assert_eq!(failure.partial_text, safe_partial);
        assert_eq!(failure.partial_text.len(), MAX_GENERATED_OUTPUT_BYTES);

        let forwarded_text = std::iter::from_fn(|| receiver.try_recv().ok())
            .filter_map(|event| match event.kind {
                ChatEventKind::TextDelta(delta) => Some(delta),
                _ => None,
            })
            .collect::<String>();
        assert_eq!(forwarded_text, failure.partial_text);
    }

    #[tokio::test]
    async fn reasoning_and_text_share_one_cumulative_output_budget() {
        struct MixedProvider;

        #[async_trait]
        impl Provider for MixedProvider {
            fn capabilities(&self) -> ProviderCapabilities {
                ProviderCapabilities {
                    streaming: true,
                    reasoning: true,
                    max_context_tokens: None,
                }
            }

            async fn generate(
                &self,
                _request: GenerationRequest,
                _credential: Option<&str>,
                sink: ProviderEventSender,
                _cancelled: watch::Receiver<bool>,
            ) -> CoreResult<GenerationUsage> {
                sink.send(ProviderEvent::ReasoningDelta(
                    "😀".repeat(MAX_GENERATED_OUTPUT_CHARS - 1),
                ))
                .await
                .map_err(|_| CoreError::internal("provider event receiver closed"))?;
                sink.send(ProviderEvent::TextDelta("😀".to_owned()))
                    .await
                    .map_err(|_| CoreError::internal("provider event receiver closed"))?;
                sink.send(ProviderEvent::TextDelta("x".to_owned()))
                    .await
                    .map_err(|_| CoreError::internal("provider event receiver closed"))?;
                Ok(GenerationUsage::default())
            }
        }

        let (events, _receiver) = mpsc::channel(16);
        let (_cancel, cancelled) = watch::channel(false);
        let failure = run_generation(&MixedProvider, request(), None, events, cancelled)
            .await
            .expect_err("combined deltas must be bounded");
        assert_eq!(failure.error.message, OUTPUT_LIMIT_ERROR_MESSAGE);
        assert_eq!(failure.partial_text, "😀");
    }
}
