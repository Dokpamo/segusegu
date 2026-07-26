//! High-level application API consumed by every platform binding.

mod app;
mod config;

pub use app::Core;
pub use config::CoreConfig;
pub use lorepia_chat::{ChatEvent, ChatEventKind};
pub use lorepia_domain::{
    AppSettings, Character, ContentKind, Conversation, ConversationBranch, ConversationBranchId,
    ConversationId, ConversationMode, ConversationState, CoreError, CoreErrorCode, CoreResult,
    GenerationId, GenerationRecord, GenerationStatus, GenerationUsage, HealthReport,
    ImportImagePreview, ImportInspection, ImportWarning, InspectionId, Message, MessageId,
    MessageRole, MessageStatus, ProviderProfile,
};
pub use lorepia_storage::DatabaseStats;

pub const CORE_API_VERSION: u32 = 3;

pub fn core_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
