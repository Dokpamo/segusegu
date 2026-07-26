use chrono::Utc;
use lorepia_domain::{
    Character, ConversationId, GenerationId, GenerationRequest, Message, MessageId, MessageRole,
    MessageStatus,
};

pub struct PromptPlanner;

impl PromptPlanner {
    pub fn plan(
        character: &Character,
        conversation_id: ConversationId,
        history: &[Message],
        model: impl Into<String>,
        temperature: f32,
        max_output_tokens: Option<u32>,
    ) -> GenerationRequest {
        let mut messages = Vec::with_capacity(history.len() + 1);
        messages.push(Message {
            id: MessageId::new(),
            conversation_id: conversation_id.clone(),
            parent_id: None,
            role: MessageRole::System,
            content: format!(
                "You are {}.\n\n{}",
                character.name.trim(),
                character.description.trim()
            ),
            status: MessageStatus::Complete,
            generation_id: None,
            created_at: Utc::now(),
        });
        messages.extend(
            history
                .iter()
                .filter(|message| message.role != MessageRole::System)
                .cloned(),
        );

        GenerationRequest {
            generation_id: GenerationId::new(),
            conversation_id,
            model: model.into(),
            messages,
            temperature: temperature.clamp(0.0, 2.0),
            max_output_tokens,
        }
    }
}

#[cfg(test)]
mod tests {
    use lorepia_domain::{Character, ConversationId, Message};

    use super::*;

    #[test]
    fn system_character_definition_is_first() {
        let character = Character::new("Segu", "A careful guide.", "a".repeat(64));
        let conversation_id = ConversationId::new();
        let user = Message::user(conversation_id.clone(), "Hello");
        let request = PromptPlanner::plan(
            &character,
            conversation_id,
            &[user],
            "model",
            3.0,
            Some(100),
        );

        assert_eq!(request.messages[0].role, MessageRole::System);
        assert!(request.messages[0].content.contains("Segu"));
        assert!((request.temperature - 2.0).abs() < f32::EPSILON);
    }
}
