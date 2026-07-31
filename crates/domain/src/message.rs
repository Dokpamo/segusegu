use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{ConversationBranchId, ConversationId, ConversationMode};

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MessageId(pub String);

impl MessageId {
    pub fn new() -> Self {
        Self(Uuid::new_v4().to_string())
    }
}

impl Default for MessageId {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct GenerationId(pub String);

impl GenerationId {
    pub fn new() -> Self {
        Self(Uuid::new_v4().to_string())
    }
}

impl Default for GenerationId {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MessageRole {
    System,
    User,
    Assistant,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MessageStatus {
    Pending,
    Complete,
    Cancelled,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GenerationStatus {
    Running,
    Complete,
    Cancelled,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GenerationRecord {
    pub id: GenerationId,
    pub conversation_id: ConversationId,
    pub branch_id: ConversationBranchId,
    pub user_message_id: MessageId,
    pub assistant_message_id: Option<MessageId>,
    pub mode: ConversationMode,
    pub model: String,
    pub status: GenerationStatus,
    pub input_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
    pub error_code: Option<String>,
    pub started_at: DateTime<Utc>,
    pub finished_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Message {
    pub id: MessageId,
    pub conversation_id: ConversationId,
    pub parent_id: Option<MessageId>,
    pub role: MessageRole,
    pub content: String,
    pub status: MessageStatus,
    pub generation_id: Option<GenerationId>,
    pub created_at: DateTime<Utc>,
}

impl Message {
    pub fn user(conversation_id: ConversationId, content: impl Into<String>) -> Self {
        Self::user_after(conversation_id, None, content)
    }

    pub fn user_after(
        conversation_id: ConversationId,
        parent_id: Option<MessageId>,
        content: impl Into<String>,
    ) -> Self {
        Self {
            id: MessageId::new(),
            conversation_id,
            parent_id,
            role: MessageRole::User,
            content: content.into(),
            status: MessageStatus::Complete,
            generation_id: None,
            created_at: Utc::now(),
        }
    }

    pub fn pending_assistant(
        conversation_id: ConversationId,
        parent_id: MessageId,
        generation_id: GenerationId,
    ) -> Self {
        Self {
            id: MessageId::new(),
            conversation_id,
            parent_id: Some(parent_id),
            role: MessageRole::Assistant,
            content: String::new(),
            status: MessageStatus::Pending,
            generation_id: Some(generation_id),
            created_at: Utc::now(),
        }
    }
}
