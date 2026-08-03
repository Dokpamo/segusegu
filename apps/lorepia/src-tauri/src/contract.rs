//! Canonical webview IPC contract.
//!
//! All host paths and credential values are ingress-only or remain in Rust.

use lorepia_shell_api::{
    AppSettingsDto, ConversationModeDto, GenerationPresetDto, GenerationTargetDto, ModelRouteDto,
    ProviderConnectionDto, ProviderProfileDto, ProviderTemplateDto,
};
use serde::{Deserialize, Serialize};
use tauri_plugin_lorepia_platform::CredentialStatus;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ImportTicketDto {
    pub ticket_id: String,
    pub display_name: String,
    pub size_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TicketRequest {
    pub ticket_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InspectionRequest {
    pub inspection_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum DiscardImportRequest {
    Ticket { ticket_id: String },
    Inspection { inspection_id: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CharacterRequest {
    pub character_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConversationRequest {
    pub conversation_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CharacterConversationsRequest {
    pub character_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchMessagesRequest {
    pub branch_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GenerationRequest {
    pub generation_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ChatStreamRequest {
    pub stream_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SubscribeGenerationRequest {
    pub generation_id: String,
    pub conversation_id: String,
    pub branch_id: String,
    pub sequence_baseline: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum CredentialTarget {
    LegacyProfile { provider_profile_id: String },
    Connection { connection_id: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CredentialStatusRequest {
    pub target: CredentialTarget,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StoreCredentialRequest {
    pub target: CredentialTarget,
    pub credential: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CredentialStatusDto {
    pub status: CredentialStatus,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderOverviewDto {
    pub settings: AppSettingsDto,
    pub templates: Vec<ProviderTemplateDto>,
    pub connections: Vec<ProviderConnectionDto>,
    pub legacy_profiles: Vec<ProviderProfileDto>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ModelRoutesRequest {
    pub connection_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GenerationPresetsRequest {
    pub model_route_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PreviewProviderRequest {
    pub target: GenerationTargetDto,
}

const _: fn() = || {
    fn assert_serializable<T: Serialize>() {}
    assert_serializable::<ProviderOverviewDto>();
    assert_serializable::<Vec<ModelRouteDto>>();
    assert_serializable::<Vec<GenerationPresetDto>>();
    let _ = ConversationModeDto::Chat;
};
