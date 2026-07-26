//! Conversation planning and provider-neutral generation execution.

mod events;
mod generation;
mod prompt;

pub use events::{ChatEvent, ChatEventKind};
pub use generation::{GenerationOutcome, run_generation};
pub use prompt::PromptPlanner;
