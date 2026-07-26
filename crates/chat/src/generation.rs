use lorepia_domain::{CoreErrorCode, CoreResult, GenerationRequest, GenerationUsage};
use lorepia_providers::{Provider, ProviderEvent};
use tokio::sync::{mpsc, watch};

use crate::{ChatEvent, ChatEventKind};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GenerationOutcome {
    pub text: String,
    pub usage: GenerationUsage,
}

pub async fn run_generation(
    provider: &dyn Provider,
    request: GenerationRequest,
    credential: Option<&str>,
    events: mpsc::Sender<ChatEvent>,
    cancelled: watch::Receiver<bool>,
) -> CoreResult<GenerationOutcome> {
    let generation_id = request.generation_id.clone();
    let conversation_id = request.conversation_id.clone();
    let mut sequence = 1_u64;
    send_event(
        &events,
        ChatEvent::new(
            generation_id.clone(),
            conversation_id.clone(),
            sequence,
            ChatEventKind::GenerationStarted,
        ),
    )
    .await?;

    let (provider_sender, mut provider_events) = mpsc::channel(64);
    let generation = provider.generate(request, credential, provider_sender, cancelled);
    tokio::pin!(generation);
    let mut text = String::new();
    let mut provider_open = true;

    let result = loop {
        tokio::select! {
            event = provider_events.recv(), if provider_open => {
                match event {
                    Some(event) => {
                        forward_provider_event(
                            event,
                            &mut text,
                            &mut sequence,
                            &events,
                            &generation_id,
                            &conversation_id,
                        ).await?;
                    }
                    None => provider_open = false,
                }
            }
            result = &mut generation => {
                break result;
            }
        }
    };

    // A provider may enqueue its final delta and complete in the same scheduler
    // tick. Drain the bounded channel before publishing the terminal event.
    while let Some(event) = provider_events.recv().await {
        forward_provider_event(
            event,
            &mut text,
            &mut sequence,
            &events,
            &generation_id,
            &conversation_id,
        )
        .await?;
    }

    match result {
        Ok(usage) => {
            sequence = sequence.saturating_add(1);
            send_event(
                &events,
                ChatEvent::new(
                    generation_id.clone(),
                    conversation_id.clone(),
                    sequence,
                    ChatEventKind::UsageUpdated(usage.clone()),
                ),
            )
            .await?;
            sequence = sequence.saturating_add(1);
            send_event(
                &events,
                ChatEvent::new(
                    generation_id,
                    conversation_id,
                    sequence,
                    ChatEventKind::GenerationFinished,
                ),
            )
            .await?;
            Ok(GenerationOutcome { text, usage })
        }
        Err(error) => {
            sequence = sequence.saturating_add(1);
            let kind = if error.code == CoreErrorCode::Cancelled {
                ChatEventKind::GenerationCancelled
            } else {
                ChatEventKind::GenerationFailed {
                    code: error.code.as_str().to_owned(),
                    message: error.message.clone(),
                }
            };
            send_event(
                &events,
                ChatEvent::new(generation_id, conversation_id, sequence, kind),
            )
            .await?;
            Err(error)
        }
    }
}

async fn forward_provider_event(
    event: ProviderEvent,
    text: &mut String,
    sequence: &mut u64,
    events: &mpsc::Sender<ChatEvent>,
    generation_id: &lorepia_domain::GenerationId,
    conversation_id: &lorepia_domain::ConversationId,
) -> CoreResult<()> {
    *sequence = sequence.saturating_add(1);
    let kind = match event {
        ProviderEvent::TextDelta(delta) => {
            text.push_str(&delta);
            ChatEventKind::TextDelta(delta)
        }
        ProviderEvent::ReasoningDelta(delta) => ChatEventKind::ReasoningDelta(delta),
    };
    send_event(
        events,
        ChatEvent::new(
            generation_id.clone(),
            conversation_id.clone(),
            *sequence,
            kind,
        ),
    )
    .await
}

async fn send_event(events: &mpsc::Sender<ChatEvent>, event: ChatEvent) -> CoreResult<()> {
    events
        .send(event)
        .await
        .map_err(|_| lorepia_domain::CoreError::internal("chat event receiver closed"))
}

#[cfg(test)]
mod tests {
    use lorepia_domain::{ConversationId, GenerationId, GenerationRequest};
    use lorepia_providers::StaticProvider;

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

        let mut sequences = Vec::new();
        while let Ok(event) = receiver.try_recv() {
            sequences.push(event.sequence);
        }
        assert!(sequences.windows(2).all(|pair| pair[0] < pair[1]));
    }
}
