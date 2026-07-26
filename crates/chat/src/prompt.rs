use chrono::Utc;
use lorepia_domain::{
    Character, ConversationId, CoreError, CoreResult, GenerationId, GenerationRequest, Message,
    MessageId, MessageRole, MessageStatus,
};

/// Maximum number of messages sent to a provider, including the system message.
pub const MAX_PROMPT_MESSAGES: usize = 128;
/// Maximum UTF-8 byte length of all prompt message contents.
pub const MAX_PROMPT_BYTES: usize = 512 * 1024;
/// Maximum Unicode scalar count of all prompt message contents.
pub const MAX_PROMPT_CHARS: usize = 128 * 1024;
/// Maximum UTF-8 byte length of one history item loaded for prompt planning.
pub const MAX_HISTORY_MESSAGE_BYTES: usize = 256 * 1024;
/// Maximum Unicode scalar count of one history item loaded for prompt planning.
pub const MAX_HISTORY_MESSAGE_CHARS: usize = 64 * 1024;

pub struct PromptPlanner;

impl PromptPlanner {
    pub fn plan(
        character: &Character,
        conversation_id: ConversationId,
        history: &[Message],
        model: impl Into<String>,
        temperature: f32,
        max_output_tokens: Option<u32>,
    ) -> CoreResult<GenerationRequest> {
        let character_name = character.name.trim();
        let character_description = character.description.trim();
        let system_bytes = "You are "
            .len()
            .checked_add(character_name.len())
            .and_then(|size| size.checked_add(".\n\n".len()))
            .and_then(|size| size.checked_add(character_description.len()))
            .ok_or_else(|| CoreError::invalid("character prompt size overflow"))?;
        let system_chars = "You are ".chars().count()
            + character_name.chars().count()
            + ".\n\n".chars().count()
            + character_description.chars().count();
        if system_bytes > MAX_PROMPT_BYTES || system_chars > MAX_PROMPT_CHARS {
            return Err(prompt_limit_error());
        }

        let system_message = Message {
            id: MessageId::new(),
            conversation_id: conversation_id.clone(),
            parent_id: None,
            role: MessageRole::System,
            content: format!("You are {character_name}.\n\n{character_description}"),
            status: MessageStatus::Complete,
            generation_id: None,
            created_at: Utc::now(),
        };

        let mut selected = Vec::with_capacity(history.len().min(MAX_PROMPT_MESSAGES - 1));
        let mut total_bytes = system_bytes;
        let mut total_chars = system_chars;
        for message in history
            .iter()
            .rev()
            .filter(|message| message.role != MessageRole::System)
        {
            if selected.len() == MAX_PROMPT_MESSAGES - 1 {
                break;
            }
            let message_bytes = message.content.len();
            let message_chars = message.content.chars().count();
            let Some(next_bytes) = total_bytes.checked_add(message_bytes) else {
                if selected.is_empty() {
                    return Err(prompt_limit_error());
                }
                break;
            };
            let Some(next_chars) = total_chars.checked_add(message_chars) else {
                if selected.is_empty() {
                    return Err(prompt_limit_error());
                }
                break;
            };
            if next_bytes > MAX_PROMPT_BYTES || next_chars > MAX_PROMPT_CHARS {
                if selected.is_empty() {
                    return Err(prompt_limit_error());
                }
                break;
            }
            total_bytes = next_bytes;
            total_chars = next_chars;
            selected.push(message.clone());
        }
        selected.reverse();

        let mut messages = Vec::with_capacity(selected.len() + 1);
        messages.push(system_message);
        messages.extend(selected);

        Ok(GenerationRequest {
            generation_id: GenerationId::new(),
            conversation_id,
            model: model.into(),
            messages,
            temperature: temperature.clamp(0.0, 2.0),
            max_output_tokens,
        })
    }
}

fn prompt_limit_error() -> CoreError {
    CoreError::invalid(format!(
        "prompt exceeds the {MAX_PROMPT_BYTES}-byte or {MAX_PROMPT_CHARS}-character limit"
    ))
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
        )
        .expect("plan");

        assert_eq!(request.messages[0].role, MessageRole::System);
        assert!(request.messages[0].content.contains("Segu"));
        assert!((request.temperature - 2.0).abs() < f32::EPSILON);
    }

    #[test]
    fn retains_only_a_bounded_recent_history_suffix() {
        let character = Character::new("Segu", "Guide", "a".repeat(64));
        let conversation_id = ConversationId::new();
        let history = (0..MAX_PROMPT_MESSAGES + 20)
            .map(|index| Message::user(conversation_id.clone(), format!("message-{index}")))
            .collect::<Vec<_>>();

        let request = PromptPlanner::plan(
            &character,
            conversation_id,
            &history,
            "model",
            1.0,
            Some(100),
        )
        .expect("plan");

        assert_eq!(request.messages.len(), MAX_PROMPT_MESSAGES);
        assert_eq!(
            request.messages.last().expect("latest").content,
            format!("message-{}", history.len() - 1)
        );
        assert!(
            !request
                .messages
                .iter()
                .any(|message| message.content == "message-0")
        );
    }

    #[test]
    fn prompt_character_limit_is_inclusive_at_a_multibyte_utf8_boundary() {
        let character = Character::new("", "", "a".repeat(64));
        let conversation_id = ConversationId::new();
        let system_chars = "You are .\n\n".chars().count();
        let user = Message::user(
            conversation_id.clone(),
            "😀".repeat(MAX_PROMPT_CHARS - system_chars),
        );

        let request = PromptPlanner::plan(
            &character,
            conversation_id.clone(),
            std::slice::from_ref(&user),
            "model",
            1.0,
            Some(100),
        )
        .expect("exact character limit");
        assert_eq!(request.messages.last().expect("user").content, user.content);

        let oversized = Message::user(conversation_id.clone(), format!("{}😀", user.content));
        let error = PromptPlanner::plan(
            &character,
            conversation_id,
            &[oversized],
            "model",
            1.0,
            Some(100),
        )
        .expect_err("one scalar over the boundary");
        assert_eq!(error.code, lorepia_domain::CoreErrorCode::InvalidInput);
        assert_eq!(
            error.message,
            "prompt exceeds the 524288-byte or 131072-character limit"
        );
    }
}
