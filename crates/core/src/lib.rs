//! High-level application API consumed by every platform binding.

mod app;
mod config;

pub use app::Core;
pub use config::CoreConfig;
pub use lorepia_chat::{ChatEvent, ChatEventKind};
pub use lorepia_domain::{
    AppSettings, Character, Conversation, ConversationId, CoreError, CoreErrorCode, CoreResult,
    GenerationId, HealthReport, ImportInspection, InspectionId, Message, ProviderProfile,
};
pub use lorepia_storage::DatabaseStats;

pub const CORE_API_VERSION: u32 = 1;

pub fn core_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
