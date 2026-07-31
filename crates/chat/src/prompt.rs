use chrono::Utc;
use lorepia_domain::{
    Character, ConversationId, ConversationMode, CoreError, CoreResult, GenerationId,
    GenerationRequest, Message, MessageId, MessageRole, MessageStatus,
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

const CHAT_MODE_INSTRUCTION: &str = "Chat mode: Keep replies brief and conversational, speaking as the character. Never narrate, invent, or decide the user's actions, thoughts, feelings, dialogue, or choices.";
const STORY_MODE_INSTRUCTION: &str = "Story mode: Write an immersive scene using vivid but focused narration and character dialogue. Leave meaningful room for the user to act and choose; never decide the user's actions, thoughts, dialogue, or choices.";

pub struct PromptPlanner;

impl PromptPlanner {
    /// Plans a request using the default character-chat behavior.
    pub fn plan(
        character: &Character,
        conversation_id: ConversationId,
        history: &[Message],
        model: impl Into<String>,
        temperature: f32,
        max_output_tokens: Option<u32>,
    ) -> CoreResult<GenerationRequest> {
        Self::plan_with_mode(
            character,
            conversation_id,
            ConversationMode::Chat,
            history,
            model,
            temperature,
            max_output_tokens,
        )
    }

    /// Plans a request with behavior specific to the selected conversation mode.
    pub fn plan_with_mode(
        character: &Character,
        conversation_id: ConversationId,
        mode: ConversationMode,
        history: &[Message],
        model: impl Into<String>,
        temperature: f32,
        max_output_tokens: Option<u32>,
    ) -> CoreResult<GenerationRequest> {
        let character_name = character.name.trim();
        let character_description = character.description.trim();
        let mode_instruction = match mode {
            ConversationMode::Chat => CHAT_MODE_INSTRUCTION,
            ConversationMode::Story => STORY_MODE_INSTRUCTION,
        };
        let system_bytes = "You are "
            .len()
            .checked_add(character_name.len())
            .and_then(|size| size.checked_add(".\n\n".len()))
            .and_then(|size| size.checked_add(character_description.len()))
            .and_then(|size| size.checked_add("\n\n".len()))
            .and_then(|size| size.checked_add(mode_instruction.len()))
            .ok_or_else(|| CoreError::invalid("character prompt size overflow"))?;
        let system_chars = "You are "
            .chars()
            .count()
            .checked_add(character_name.chars().count())
            .and_then(|size| size.checked_add(".\n\n".chars().count()))
            .and_then(|size| size.checked_add(character_description.chars().count()))
            .and_then(|size| size.checked_add("\n\n".chars().count()))
            .and_then(|size| size.checked_add(mode_instruction.chars().count()))
            .ok_or_else(|| CoreError::invalid("character prompt size overflow"))?;
        if system_bytes > MAX_PROMPT_BYTES || system_chars > MAX_PROMPT_CHARS {
            return Err(prompt_limit_error());
        }
        let system_content =
            format!("You are {character_name}.\n\n{character_description}\n\n{mode_instruction}");

        let system_message = Message {
            id: MessageId::new(),
            conversation_id: conversation_id.clone(),
            parent_id: None,
            role: MessageRole::System,
            content: system_content,
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
    use lorepia_domain::{Character, ConversationId, ConversationMode, Message};

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
        assert!(
            request.messages[0]
                .content
                .contains("Keep replies brief and conversational")
        );
        assert!((request.temperature - 2.0).abs() < f32::EPSILON);
    }

    #[test]
    fn conversation_modes_produce_distinct_system_instructions() {
        let character = Character::new("Segu", "A careful guide.", "a".repeat(64));
        let conversation_id = ConversationId::new();

        let chat = PromptPlanner::plan_with_mode(
            &character,
            conversation_id.clone(),
            ConversationMode::Chat,
            &[],
            "model",
            1.0,
            None,
        )
        .expect("chat plan");
        let story = PromptPlanner::plan_with_mode(
            &character,
            conversation_id,
            ConversationMode::Story,
            &[],
            "model",
            1.0,
            None,
        )
        .expect("story plan");

        let chat_system = &chat.messages[0].content;
        let story_system = &story.messages[0].content;
        assert_ne!(chat_system, story_system);
        assert!(chat_system.contains("Never narrate, invent, or decide the user's actions"));
        assert!(story_system.contains("Write an immersive scene"));
        assert!(story_system.contains("room for the user to act and choose"));
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
        let system_chars = PromptPlanner::plan(
            &character,
            conversation_id.clone(),
            &[],
            "model",
            1.0,
            Some(100),
        )
        .expect("system-only plan")
        .messages[0]
            .content
            .chars()
            .count();
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

    #[test]
    fn mode_instruction_is_included_in_prompt_limits() {
        let conversation_id = ConversationId::new();
        let fixed_chars = format!("You are .\n\n\n\n{STORY_MODE_INSTRUCTION}")
            .chars()
            .count();
        let character = Character::new(
            "",
            "a".repeat(MAX_PROMPT_CHARS - fixed_chars),
            "a".repeat(64),
        );

        let exact = PromptPlanner::plan_with_mode(
            &character,
            conversation_id.clone(),
            ConversationMode::Story,
            &[],
            "model",
            1.0,
            None,
        )
        .expect("system prompt at exact character limit");
        let system = &exact.messages[0].content;
        assert_eq!(system.chars().count(), MAX_PROMPT_CHARS);
        assert!(system.len() <= MAX_PROMPT_BYTES);

        let oversized = Character::new("", format!("{}a", character.description), "a".repeat(64));
        let error = PromptPlanner::plan_with_mode(
            &oversized,
            conversation_id,
            ConversationMode::Story,
            &[],
            "model",
            1.0,
            None,
        )
        .expect_err("mode instruction must count toward the limit");
        assert_eq!(error.code, lorepia_domain::CoreErrorCode::InvalidInput);
    }
}
