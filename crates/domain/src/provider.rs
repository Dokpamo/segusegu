use serde::{Deserialize, Serialize};

use crate::{ConversationId, GenerationId, Message};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderCapabilities {
    pub streaming: bool,
    pub reasoning: bool,
    pub max_context_tokens: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderProfile {
    pub id: String,
    pub display_name: String,
    pub base_url: String,
    pub model: String,
    pub timeout_seconds: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GenerationRequest {
    pub generation_id: GenerationId,
    pub conversation_id: ConversationId,
    pub model: String,
    pub messages: Vec<Message>,
    pub temperature: f32,
    pub max_output_tokens: Option<u32>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct GenerationUsage {
    pub input_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
}
