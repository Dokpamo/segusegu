//! Platform-independent types shared by `LorePia`'s Rust crates.

mod character;
mod content;
mod conversation;
mod error;
mod health;
mod message;
mod provider;
mod settings;

pub use character::Character;
pub use content::{
    ContentKind, ImportImagePreview, ImportInspection, ImportLimits, ImportWarning, InspectionId,
};
pub use conversation::{
    Conversation, ConversationBranch, ConversationBranchId, ConversationId, ConversationMode,
    ConversationState, MessageActionGeneration,
};
pub use error::{CoreError, CoreErrorCode, CoreResult};
pub use health::HealthReport;
pub use message::{
    GenerationId, GenerationRecord, GenerationStatus, Message, MessageId, MessageRole,
    MessageStatus,
};
pub use provider::{GenerationRequest, GenerationUsage, ProviderCapabilities, ProviderProfile};
pub use settings::AppSettings;
