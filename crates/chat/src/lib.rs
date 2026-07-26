//! Conversation planning and provider-neutral generation execution.

mod events;
mod generation;
mod prompt;

pub use events::{ChatEvent, ChatEventKind};
pub use generation::{
    GenerationFailure, GenerationOutcome, MAX_GENERATED_OUTPUT_BYTES, MAX_GENERATED_OUTPUT_CHARS,
    OUTPUT_LIMIT_ERROR_MESSAGE, run_generation,
};
pub use prompt::{
    MAX_HISTORY_MESSAGE_BYTES, MAX_HISTORY_MESSAGE_CHARS, MAX_PROMPT_BYTES, MAX_PROMPT_CHARS,
    MAX_PROMPT_MESSAGES, PromptPlanner,
};
