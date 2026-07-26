use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::ConversationId;

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
        Self {
            id: MessageId::new(),
            conversation_id,
            parent_id: None,
            role: MessageRole::User,
            content: content.into(),
            status: MessageStatus::Complete,
            generation_id: None,
            created_at: Utc::now(),
        }
    }
}
