use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ConversationId(pub String);

impl ConversationId {
    pub fn new() -> Self {
        Self(Uuid::new_v4().to_string())
    }
}

impl Default for ConversationId {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Conversation {
    pub id: ConversationId,
    pub character_id: String,
    pub title: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl Conversation {
    pub fn new(character_id: impl Into<String>, title: impl Into<String>) -> Self {
        let now = Utc::now();
        Self {
            id: ConversationId::new(),
            character_id: character_id.into(),
            title: title.into(),
            created_at: now,
            updated_at: now,
        }
    }
}
