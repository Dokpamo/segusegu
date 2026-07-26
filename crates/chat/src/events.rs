use chrono::{DateTime, Utc};
use lorepia_domain::{ConversationId, GenerationId, GenerationUsage, MessageId, MessageStatus};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatEvent {
    pub event_version: u32,
    pub generation_id: GenerationId,
    pub conversation_id: ConversationId,
    pub sequence: u64,
    pub emitted_at: DateTime<Utc>,
    pub kind: ChatEventKind,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", content = "payload", rename_all = "snake_case")]
pub enum ChatEventKind {
    GenerationStarted,
    ReasoningDelta(String),
    TextDelta(String),
    UsageUpdated(GenerationUsage),
    MessageCommitted {
        message_id: MessageId,
        status: MessageStatus,
    },
    GenerationCancelled,
    GenerationFailed {
        code: String,
        message: String,
    },
    GenerationFinished,
}

impl ChatEvent {
    pub fn new(
        generation_id: GenerationId,
        conversation_id: ConversationId,
        sequence: u64,
        kind: ChatEventKind,
    ) -> Self {
        Self {
            event_version: 1,
            generation_id,
            conversation_id,
            sequence,
            emitted_at: Utc::now(),
            kind,
        }
    }
}
