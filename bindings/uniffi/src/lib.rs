//! Thin `UniFFI` surface consumed by Android and Apple applications.

use std::{
    collections::HashMap,
    net::IpAddr,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use chrono::Utc;
use lorepia_core::{
    ApiFamily, AppSettings, AssistantCallEstimate, AssistantDraftReview, AssistantFailureKind,
    AssistantHostAction, AssistantManifestDraft, AuthBinding, BoundedJson, CanonicalOrigin,
    CapabilityKey, CapabilityObservation, CapabilityValue, CatalogChangeKind, CatalogDiffDto,
    Character, ChatEvent, ChatEventKind, Confidence, ConfidenceLevel, ConflictDisposition,
    ConnectionConfig, ConnectionConfigEntry, ConnectionConfigValue, ConnectionFieldSpec,
    ConnectionFieldType, ConnectionStatus, ContentKind, Conversation, ConversationBranch,
    ConversationBranchId, ConversationId, ConversationMode, ConversationState, Core, CoreConfig,
    CoreError, CoreErrorCode, CredentialRedirectPolicy, CredentialRef, CredentialScope,
    CurlAuthHint, DatabaseStats, DiscoveryActionEnvelope, DiscoveryActionId,
    DiscoveryActionRequired, DiscoveryApprovalDecision, DiscoveryApprovalGrant,
    DiscoveryApprovalId, DiscoveryApprovalRecord, DiscoveryAssistantCheckpoint,
    DiscoveryCandidateSummary, DiscoveryCommitAttemptId, DiscoveryCompensationKind,
    DiscoveryCompensationRecord, DiscoveryCompensationStatus, DiscoveryCompensationTarget,
    DiscoveryEventId, DiscoveryEvidenceKind, DiscoveryEvidenceRecord, DiscoveryFailure,
    DiscoveryOperationKind, DiscoveryOutboxEvent, DiscoveryPreviousSelection, DiscoveryProgress,
    DiscoveryProgressPhase, DiscoveryRecoveryResult, DiscoveryReviewChangeKind,
    DiscoveryReviewDiff, DiscoverySessionId, DiscoverySessionSnapshot, DiscoveryState,
    DiscoveryUnknownOutcomeResolution, DiscoveryWarning, DraftField, DraftPersistence,
    DraftReviewCheck, EffectiveCapability, EndpointPath, EvidenceConflict, EvidenceId,
    FieldConfidence, FieldEvidenceMapping, GenerationId, GenerationPreset, GenerationPresetId,
    GenerationPromptCacheMode, GenerationPromptCacheSettings, GenerationPromptCacheTtl,
    GenerationReasoningEffort, GenerationReasoningMode, GenerationReasoningSettings,
    GenerationReasoningSummary, GenerationTarget, HeaderName, HttpMethod, HttpUrl,
    ImportInspection, InspectionId, ManifestChangedSection, ManifestDiffDto, Message,
    MessageActionGeneration, MessageId, MessageRole, MessageStatus, ModelAvailability,
    ModelChangedSection, ModelMetadataDiffDto, ModelMetadataSource, ModelRoute, ModelRouteConfig,
    ModelRouteId, ModelSyncDiff, ModelSyncEvent, ModelSyncFailure, ModelSyncJob, ModelSyncJobId,
    ModelSyncReview, ModelSyncSourceProvenance, ModelSyncState, ObservationId, ObservationSource,
    ParameterChoice, ParameterCondition, ParameterConditionOperator, ParameterConflict,
    ParameterConflictKind, ParameterDefaultMode, ParameterIssue, ParameterIssueCode,
    ParameterLiteral, ParameterSpec, ParameterType, ParameterValue, ParameterValueState,
    PromptCacheControlModel, PromptCacheMode, PromptCacheTtl, ProviderCatalogActivationKind,
    ProviderCatalogActivationSummary, ProviderCatalogHistory, ProviderCatalogImportPlan,
    ProviderCatalogImportResult, ProviderCatalogImportReview, ProviderCatalogRevisionSummary,
    ProviderCatalogRollbackPlan, ProviderCatalogRollbackResult, ProviderCatalogStatus,
    ProviderConnection, ProviderConnectionDraft, ProviderConnectionId, ProviderDiscoveryAction,
    ProviderDiscoveryApprovalProposal, ProviderDiscoveryAssistantResumeAction,
    ProviderDiscoveryAssistantResumeBoundary, ProviderDiscoveryConnectionOptions,
    ProviderDiscoveryCurlInput, ProviderDiscoveryReviewProposal, ProviderLocalNetworkApproval,
    ProviderModelRefreshProvenance, ProviderModelRefreshResult, ProviderNetworkMode,
    ProviderParameterMapping, ProviderParameterTarget, ProviderProfile, ProviderTemplateId,
    ProviderTemplateView, ReasoningControlModel, ReasoningEffort, ReasoningMode,
    ReasoningSummaryMode, RequestBodyField, RequestBodyShape, RequestPreview,
    SanitizedDiscoveryInput, SecretCurlInput, StoredDiscoveryCandidate, SupportStatus,
    TemplateSource, ToolPolicy, UiControlState, UiFieldState, UiParameterLevel, UnresolvedQuestion,
    provider_discovery_action_envelope,
};
use tokio::sync::broadcast;

const BINDING_API_VERSION: u32 = 8;
const CHAT_EVENT_VERSION: u32 = lorepia_core::CHAT_EVENT_VERSION;
const PROVIDER_DISCOVERY_SNAPSHOT_SCHEMA_VERSION: u32 = 3;
const MAX_EVENT_BATCH_SIZE: u32 = 256;
const CURL_CREDENTIAL_HANDOFF_TTL: Duration = Duration::from_mins(2);
const MAX_CURL_CREDENTIAL_HANDOFFS: usize = 16;

uniffi::setup_scaffolding!();

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiCoreConfig {
    pub data_root: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiVersionInfo {
    pub core_version: String,
    pub core_api_version: u32,
    pub binding_api_version: u32,
    pub chat_event_version: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
#[allow(clippy::struct_excessive_bools)]
pub struct FfiHealthReport {
    pub core_version: String,
    pub database_open: bool,
    pub schema_version: u32,
    pub data_root_writable: bool,
    pub staging_writable: bool,
    pub recovery_pending: bool,
    pub active_jobs: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiCharacter {
    pub id: String,
    pub name: String,
    pub description: String,
    pub source_hash: String,
    pub avatar_asset_hash: Option<String>,
    pub created_at: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiImportWarning {
    pub code: String,
    pub message: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiImportImagePreview {
    pub logical_asset_id: String,
    pub media_type: String,
    pub size_bytes: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiImportInspection {
    pub id: String,
    pub content_kind: String,
    pub display_name: String,
    pub description: String,
    pub representative_image: Option<FfiImportImagePreview>,
    pub source_sha256: String,
    pub source_size: u64,
    pub estimated_stored_size: u64,
    pub asset_count: u32,
    pub warnings: Vec<FfiImportWarning>,
    pub blocked_reasons: Vec<String>,
    pub unsupported_optional_fields: Vec<String>,
    pub is_allowed: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiConversation {
    pub id: String,
    pub character_id: String,
    pub title: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiConversationBranch {
    pub id: String,
    pub conversation_id: String,
    pub title: Option<String>,
    pub fork_message_id: Option<String>,
    pub head_message_id: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiConversationState {
    pub conversation_id: String,
    pub active_branch_id: String,
    pub selected_mode: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessageActionGeneration {
    pub branch: FfiConversationBranch,
    pub generation_id: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessage {
    pub id: String,
    pub conversation_id: String,
    pub parent_id: Option<String>,
    pub role: String,
    pub content: String,
    pub status: String,
    pub generation_id: Option<String>,
    pub created_at: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiProviderProfile {
    pub id: String,
    pub display_name: String,
    pub base_url: String,
    pub model: String,
    pub timeout_seconds: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FfiAuthBinding {
    None,
    BearerHeader,
    HeaderApiKey { header_name: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiConnectionFieldType {
    Text,
    Integer,
    Boolean,
    Credential,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiConnectionFieldSpec {
    pub key: String,
    pub label_key: String,
    pub description_key: Option<String>,
    pub value_type: FfiConnectionFieldType,
    pub required: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FfiConnectionConfigValue {
    Text { value: String },
    Integer { value: i64 },
    Boolean { value: bool },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiConnectionConfigEntry {
    pub key: String,
    pub value: FfiConnectionConfigValue,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiParameterType {
    Boolean,
    Integer,
    Number,
    String,
    Enum,
    StringList,
    JsonSchema,
    StopSequenceList,
    ToolPolicy,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiToolPolicy {
    None,
    Auto,
    Required,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum FfiParameterLiteral {
    Boolean { value: bool },
    Integer { value: i64 },
    Number { value: f64 },
    String { value: String },
    Enum { value: String },
    StringList { values: Vec<String> },
    JsonSchema { value: String },
    StopSequenceList { values: Vec<String> },
    ToolPolicy { value: FfiToolPolicy },
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum FfiParameterValueState {
    InheritProviderDefault,
    Explicit { value: FfiParameterLiteral },
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FfiParameterValue {
    pub parameter_id: String,
    pub state: FfiParameterValueState,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FfiParameterChoice {
    pub value: FfiParameterLiteral,
    pub label_key: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiParameterDefaultMode {
    ProviderDefault,
    ExplicitRequired,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiParameterConditionOperator {
    Equals,
    NotEquals,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FfiParameterCondition {
    pub parameter_id: String,
    pub operator: FfiParameterConditionOperator,
    pub value: FfiParameterLiteral,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiParameterConflictKind {
    MutuallyExclusive,
    Requires,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiParameterConflict {
    pub parameter_id: String,
    pub kind: FfiParameterConflictKind,
    pub message_key: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiProviderParameterTarget {
    RequestBody,
    RequestHeader,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiProviderParameterMapping {
    pub target: FfiProviderParameterTarget,
    pub field_name: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiUiParameterLevel {
    Basic,
    Advanced,
    Expert,
    HiddenInternal,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FfiParameterSpec {
    pub id: String,
    pub label_key: String,
    pub description_key: Option<String>,
    pub value_type: FfiParameterType,
    pub allowed_values: Vec<FfiParameterChoice>,
    pub minimum: Option<f64>,
    pub maximum: Option<f64>,
    pub step: Option<f64>,
    pub default_mode: FfiParameterDefaultMode,
    pub visibility: Option<FfiParameterCondition>,
    pub conflicts: Vec<FfiParameterConflict>,
    pub provider_mapping: FfiProviderParameterMapping,
    pub level: FfiUiParameterLevel,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FfiProviderTemplate {
    pub id: String,
    pub display_name: String,
    pub manifest_version: u32,
    pub source: String,
    pub api_family: String,
    pub default_network_mode: FfiProviderNetworkMode,
    pub default_api_origin: Option<String>,
    pub requires_credential: bool,
    pub supports_model_listing: bool,
    pub auth_binding: FfiAuthBinding,
    pub connection_fields: Vec<FfiConnectionFieldSpec>,
    pub parameters: Vec<FfiParameterSpec>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiProviderNetworkMode {
    Public,
    LocalLoopback,
    ApprovedLocalNetwork,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiProviderLocalNetworkApproval {
    pub origin: String,
    pub addresses: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FfiProviderConnectionDraft {
    pub id: String,
    pub template_id: String,
    pub template_version: u32,
    pub display_name: String,
    pub api_origin: String,
    pub api_base_path: Option<String>,
    pub network_mode: FfiProviderNetworkMode,
    pub local_network_approval: Option<FfiProviderLocalNetworkApproval>,
    pub values: Vec<FfiConnectionConfigEntry>,
    pub approved_credential_origin: Option<String>,
    pub timeout_seconds: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiCredentialRedirectPolicy {
    Deny,
    FollowWithoutCredential,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiCredentialScope {
    pub allowed_origins: Vec<String>,
    pub auth_binding: FfiAuthBinding,
    pub redirect_policy: FfiCredentialRedirectPolicy,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FfiProviderConnection {
    pub id: String,
    pub template_id: String,
    pub template_version: u32,
    pub display_name: String,
    pub api_origin: String,
    pub api_base_path: Option<String>,
    pub network_mode: FfiProviderNetworkMode,
    pub local_network_approval: Option<FfiProviderLocalNetworkApproval>,
    pub values: Vec<FfiConnectionConfigEntry>,
    /// Whether the native vault contains the credential under this exact
    /// connection `id`. No arbitrary credential-reference string is accepted.
    pub credential_slot_ready: bool,
    pub credential_scope: Option<FfiCredentialScope>,
    pub approved_credential_origins: Vec<String>,
    pub timeout_seconds: u32,
    pub status: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiModelRouteConfig {
    pub deployment_id: Option<String>,
    pub region: Option<String>,
    pub endpoint_path: Option<String>,
    pub values: Vec<FfiConnectionConfigEntry>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FfiModelRoute {
    pub id: String,
    pub connection_id: String,
    pub api_family: String,
    pub model_id: String,
    pub display_name: Option<String>,
    pub route_config: FfiModelRouteConfig,
    pub availability: String,
    pub miss_count: u32,
    /// Canonical, bounded normalized metadata. This is never a wholesale
    /// provider response and never contains credential material.
    pub raw_metadata_json: Option<String>,
    pub metadata_source: String,
    pub metadata_observed_at: Option<String>,
    pub last_reconciled_sync_job_id: Option<String>,
    pub metadata_sync_job_id: Option<String>,
    pub first_seen_at: String,
    pub last_seen_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FfiGenerationPreset {
    pub id: String,
    pub model_route_id: String,
    pub display_name: String,
    pub parameter_value_count: u32,
    pub values: Vec<FfiParameterValue>,
    pub reasoning_mode: String,
    pub reasoning_effort: Option<String>,
    pub reasoning_budget_tokens: Option<u32>,
    pub reasoning_summary: String,
    pub preserve_opaque_reasoning_state: bool,
    pub prompt_cache_mode: String,
    pub prompt_cache_ttl: String,
    pub prompt_cache_custom_ttl_seconds: Option<u32>,
    pub prompt_cache_context_reference: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiParameterIssue {
    pub code: String,
    pub parameter_id: Option<String>,
    pub related_parameter_id: Option<String>,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiReasoningControl {
    pub state: String,
    pub mode: String,
    pub effort: Option<String>,
    pub budget_tokens: Option<u32>,
    pub summary: String,
    pub preserve_opaque_state: bool,
    pub allowed_modes: Vec<String>,
    pub allowed_efforts: Vec<String>,
    pub allowed_summaries: Vec<String>,
    pub minimum_budget_tokens: Option<u32>,
    pub maximum_budget_tokens: Option<u32>,
    pub effort_field: String,
    pub budget_field: String,
    pub summary_field: String,
    pub issues: Vec<FfiParameterIssue>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiPromptCacheControl {
    pub state: String,
    pub mode: String,
    pub ttl: String,
    pub custom_ttl_seconds: Option<u32>,
    pub context_reference: Option<String>,
    pub allowed_modes: Vec<String>,
    pub allowed_ttls: Vec<String>,
    pub supports_custom_ttl: bool,
    pub minimum_custom_ttl_seconds: Option<u32>,
    pub maximum_custom_ttl_seconds: Option<u32>,
    pub ttl_field: String,
    pub context_reference_field: String,
    pub issues: Vec<FfiParameterIssue>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiGenerationTarget {
    pub model_route_id: String,
    pub generation_preset_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiRequestBodyField {
    pub name: String,
    pub shape: FfiRequestBodyShape,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FfiRequestBodyShape {
    Null,
    Boolean,
    Number,
    String,
    Array {
        items: Vec<FfiRequestBodyShape>,
        truncated: bool,
    },
    Object {
        fields: Vec<FfiRequestBodyField>,
        truncated: bool,
    },
    Redacted,
    Truncated,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
#[allow(clippy::struct_excessive_bools)]
pub struct FfiRequestPreview {
    pub redaction_version: u32,
    pub method: String,
    pub origin: String,
    pub path: String,
    pub header_names: Vec<String>,
    pub query_parameter_names: Vec<String>,
    pub body_shape: Option<FfiRequestBodyShape>,
    pub body_truncated: bool,
    pub includes_private_message: bool,
    pub includes_credential_value: bool,
    pub includes_opaque_reasoning_state: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiProviderModelRefreshProvenance {
    pub source: String,
    pub api_family: String,
    pub api_origin: String,
    pub endpoint_path: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FfiProviderModelRefreshResult {
    pub connection_id: String,
    pub model_routes: Vec<FfiModelRoute>,
    pub newly_seen_model_route_ids: Vec<String>,
    pub missing_model_route_ids: Vec<String>,
    pub created_generation_preset_ids: Vec<String>,
    pub routes_requiring_preset_configuration: Vec<String>,
    pub provenance: FfiProviderModelRefreshProvenance,
    pub pages_fetched: u32,
    pub response_bytes: u64,
    pub observed_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiModelSyncFailure {
    pub code: String,
    pub message_key: String,
    pub recoverable: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiModelSyncProvenance {
    pub source: String,
    pub api_family: String,
    pub api_origin: String,
    pub endpoint_path: String,
    pub pages_fetched: u32,
    pub response_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FfiModelSyncReview {
    pub sha256: String,
    pub connection_id: String,
    pub expected_connection: FfiProviderConnection,
    pub observed_at: String,
    pub expected_model_routes: Vec<FfiModelRoute>,
    pub listed_routes: Vec<FfiModelRoute>,
    pub newly_seen_model_route_ids: Vec<String>,
    pub missing_model_route_ids: Vec<String>,
    pub initial_presets: Vec<FfiGenerationPreset>,
    pub capability_observations: Vec<FfiCapabilityObservation>,
    pub routes_requiring_preset_configuration: Vec<String>,
    pub provenance: FfiModelSyncProvenance,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FfiModelSyncJob {
    pub id: String,
    pub connection_id: String,
    pub state: String,
    pub revision: u64,
    pub review: Option<FfiModelSyncReview>,
    pub failure: Option<FfiModelSyncFailure>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiModelSyncEvent {
    pub version: u32,
    pub job_id: String,
    pub sequence: u64,
    pub job_revision: u64,
    pub redaction_version: u32,
    pub state: String,
    pub completed_steps: u32,
    pub total_steps: u32,
    pub message_key: String,
    pub review_sha256: Option<String>,
    pub failure: Option<FfiModelSyncFailure>,
    pub emitted_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiProviderCatalogStatus {
    pub status_schema_version: u32,
    pub state_version: u64,
    pub active_revision: u64,
    pub active_snapshot_sha256: String,
    pub bundled_baseline_sha256: String,
    pub snapshot_count: u32,
    pub signed_update_count: u32,
    pub highest_accepted_revision: u64,
    pub latest_issued_at: Option<String>,
    pub active_signed_revisions: Vec<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiProviderCatalogRevision {
    pub revision: u64,
    pub captured_at: String,
    pub snapshot_sha256: String,
    pub signed_revisions: Vec<u64>,
    pub active: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiProviderCatalogActivation {
    pub action_id: String,
    pub state_version: u64,
    pub kind: String,
    pub from_revision: Option<u64>,
    pub to_revision: u64,
    pub activated_at: String,
    pub diff: FfiProviderCatalogDiff,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiProviderCatalogHistory {
    pub history_schema_version: u32,
    pub active_revision: u64,
    pub revisions: Vec<FfiProviderCatalogRevision>,
    pub activations: Vec<FfiProviderCatalogActivation>,
    pub next_before_revision: Option<u64>,
    pub next_before_state_version: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiProviderCatalogTemplateChangedSection {
    DisplayName,
    ManifestVersion,
    ConnectionFields,
    ApiFamily,
    Sources,
    Origin,
    Authentication,
    Endpoints,
    Decoders,
    Parameters,
    Freshness,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiProviderCatalogModelChangedSection {
    Match,
    ApiFamily,
    MetadataVersion,
    Capabilities,
    Parameters,
    Lifecycle,
    Sources,
    Freshness,
}

/// Secret-free review entry for one provider-template catalog change.
///
/// The containing diff bucket identifies whether this entry is added, changed,
/// or removed. Catalog payloads, request headers, and credentials are never
/// exposed through this record.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiProviderCatalogTemplateDiffEntry {
    pub provider_template_id: String,
    pub previous_manifest_version: Option<u32>,
    pub next_manifest_version: Option<u32>,
    pub previous_sha256: Option<String>,
    pub next_sha256: Option<String>,
    pub changed_sections: Vec<FfiProviderCatalogTemplateChangedSection>,
}

/// Secret-free review entry for one model-metadata catalog change.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiProviderCatalogModelDiffEntry {
    pub model_entry_id: String,
    pub provider_template_id: String,
    pub previous_metadata_version: Option<u32>,
    pub next_metadata_version: Option<u32>,
    pub previous_sha256: Option<String>,
    pub next_sha256: Option<String>,
    pub changed_sections: Vec<FfiProviderCatalogModelChangedSection>,
}

/// Typed catalog diff for native review screens.
///
/// Separate buckets make the change direction explicit without requiring
/// native clients to decode internal catalog JSON or compare optional fields.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiProviderCatalogDiff {
    pub diff_schema_version: u32,
    pub from_revision: u64,
    pub to_revision: u64,
    pub added_provider_templates: Vec<FfiProviderCatalogTemplateDiffEntry>,
    pub changed_provider_templates: Vec<FfiProviderCatalogTemplateDiffEntry>,
    pub removed_provider_templates: Vec<FfiProviderCatalogTemplateDiffEntry>,
    pub added_models: Vec<FfiProviderCatalogModelDiffEntry>,
    pub changed_models: Vec<FfiProviderCatalogModelDiffEntry>,
    pub removed_models: Vec<FfiProviderCatalogModelDiffEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiProviderCatalogImportResult {
    pub signed_catalog_revision: u64,
    pub activated_revision: u64,
    pub diff: FfiProviderCatalogDiff,
    pub status: FfiProviderCatalogStatus,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiProviderCatalogImportReview {
    pub plan_schema_version: u32,
    pub action_id: String,
    pub expected_state_version: u64,
    pub expected_active_revision: u64,
    pub expected_active_snapshot_sha256: String,
    pub expected_highest_accepted_revision: u64,
    pub envelope_byte_count: u64,
    pub envelope_sha256: String,
    pub signing_key_id: String,
    pub payload_sha256: String,
    pub signed_catalog_revision: u64,
    pub candidate_revision: u64,
    pub candidate_snapshot_sha256: String,
    pub prepared_at: String,
    pub expires_at: String,
    pub diff: FfiProviderCatalogDiff,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiProviderCatalogImportPlan {
    pub review: FfiProviderCatalogImportReview,
    pub plan_sha256: String,
    /// Canonical opaque typed plan returned unchanged to activation.
    pub plan_json: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiProviderCatalogRollbackPlan {
    pub plan_schema_version: u32,
    pub action_id: String,
    pub expected_state_version: u64,
    pub plan_sha256: String,
    pub from_revision: u64,
    pub to_revision: u64,
    pub created_at: String,
    pub expires_at: String,
    pub diff: FfiProviderCatalogDiff,
    /// Canonical opaque plan returned unchanged to the activation method.
    pub plan_json: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiProviderCatalogRollbackResult {
    pub from_revision: u64,
    pub activated_revision: u64,
    pub status: FfiProviderCatalogStatus,
}

/// Persistable provider-discovery input.
///
/// Raw cURL text and credential material intentionally have no field in this
/// record. They are accepted, when needed, as separate request-scoped scalar
/// arguments on the relevant methods.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiProviderDiscoveryInput {
    /// Native-generated immutable identity used for both the Core connection
    /// graph and the OS credential-store key.
    pub connection_id: String,
    pub display_name: String,
    /// Optional for known-provider and cURL-only discovery. Core derives the
    /// sanitized origin before it creates the durable session.
    pub site_url: Option<String>,
    pub docs_url: Option<String>,
    /// Whether native has already stored credential material in the OS vault
    /// under the exact `connection_id` slot. The opaque Core reference is
    /// derived from `connection_id`; native cannot inject another reference.
    pub credential_slot_ready: bool,
    pub preferred_assistant_model_route_id: Option<String>,
    pub connection_options: FfiProviderDiscoveryConnectionOptions,
    pub supplied_evidence_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiProviderDiscoveryConnectionOptions {
    pub values: Vec<FfiConnectionConfigEntry>,
    pub api_base_path: Option<String>,
    pub timeout_seconds: u32,
    pub network_mode: FfiProviderNetworkMode,
    pub local_network_approval: Option<FfiProviderLocalNetworkApproval>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiProviderNetworkPolicy {
    pub network_mode: FfiProviderNetworkMode,
    pub local_network_approval: Option<FfiProviderLocalNetworkApproval>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FfiProviderDiscoverySource {
    KnownProvider { template_id: String },
    Site,
    Curl,
}

/// One-shot cURL inspection result.
///
/// Credential bytes deliberately have no field in this record. When
/// `credential_handoff_id` is present, native must immediately call
/// `take_provider_curl_credential` once and store the returned bytes in its OS
/// credential vault.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiProviderCurlInspection {
    pub inspection_schema_version: u32,
    pub sanitized_site_url: String,
    pub api_origin: String,
    pub method: String,
    pub path: String,
    pub header_names: Vec<String>,
    pub auth_binding_hint: Option<FfiAuthBinding>,
    pub api_family_hint: Option<String>,
    pub model_hint: Option<String>,
    pub stream_hint: Option<bool>,
    pub redacted_curl: String,
    pub credential_handoff_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryUnknownOutcomeResolution {
    ConfirmedNoEffect,
    ConfirmedCommitCompleted { connection_id: String },
    ConfirmedCompensated,
    ManuallyReconciledAsFailed,
}

/// Public, user-driven discovery actions only.
///
/// Internal network/assistant completion actions deliberately have no binding
/// representation and therefore cannot be injected by a native client.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FfiProviderDiscoveryAction {
    SelectTemplate {
        candidate_id: String,
    },
    ContinueWithoutTemplate,
    SupplyMoreEvidence {
        evidence_ids: Vec<String>,
    },
    RequestAssistant,
    ApproveAssistant {
        approval_id: String,
        approval_grant_sha256: String,
    },
    DeclineAssistant,
    ApproveCredentialOrigin {
        approval_id: String,
    },
    ApproveProbes {
        approval_id: String,
        approval_grant_sha256: String,
    },
    SkipProbes,
    ApproveReview {
        approval_id: String,
        commit_attempt_id: String,
        commit_plan_sha256: String,
        graph_sha256: String,
    },
    ResumeCompensation,
    RestartInterrupted,
    ResolveUnknownOutcome {
        approval_id: String,
        resolution: FfiDiscoveryUnknownOutcomeResolution,
    },
    Cancel,
}

/// A canonical action envelope prepared by Rust.
///
/// Native clients echo this record unchanged. `request_sha256` binds the
/// action ID and compare-and-swap revision to the exact typed action payload.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiProviderDiscoveryActionEnvelope {
    pub action_id: String,
    pub expected_revision: u64,
    pub request_sha256: String,
    pub action: FfiProviderDiscoveryAction,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiDiscoveryFailure {
    pub code: String,
    pub message_key: String,
    pub recoverable: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryProgressPhase {
    ProviderCandidates,
    Documents,
    Evidence,
    Models,
    Probes,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiDiscoveryProgress {
    pub phase: FfiDiscoveryProgressPhase,
    pub completed: u32,
    pub total: Option<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryOperationKind {
    ResolveKnownProvider,
    FetchDocuments,
    ExtractEvidence,
    BuildDeterministicManifestDraft,
    BuildAssistantManifestDraft,
    ValidateManifest,
    ListModels,
    ProbeCapabilities,
    AtomicCommit,
    Compensation,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryActionRequired {
    SelectTemplate,
    SupplyMoreEvidence,
    ApproveAssistant,
    ApproveCredentialOrigin,
    ApproveProbes,
    Review,
    RestartInterrupted {
        operation: FfiDiscoveryOperationKind,
    },
    ReconcileUnknownOutcome {
        operation: FfiDiscoveryOperationKind,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryStepState {
    Completed,
    Current,
    Pending,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiDiscoveryStep {
    pub id: String,
    pub title_key: String,
    pub state: FfiDiscoveryStepState,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryEvidenceKind {
    HtmlDocument,
    JsonDocument,
    YamlDocument,
    XmlDocument,
    PlainTextDocument,
    JsonSchema,
    OpenApi,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryCandidateSummary {
    ProviderTemplate {
        template_id: String,
        template_version: u32,
    },
    ApiOrigin {
        origin: String,
    },
    OfficialDocument {
        content_sha256: String,
    },
    ModelRoute {
        model_id: String,
    },
    ManifestDraft {
        schema_version: u32,
        manifest_sha256: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiDiscoveryCandidate {
    pub id: String,
    pub proposed_revision: u64,
    pub summary: FfiDiscoveryCandidateSummary,
    pub evidence_ids: Vec<String>,
    pub created_at: String,
}

/// A non-secret evidence index entry.
///
/// Source URLs, document bodies, extracted JSON, and request data are omitted
/// from the platform binding. The content digest and opaque evidence ID are
/// enough for user selection and approval binding.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiDiscoveryEvidence {
    pub id: String,
    pub kind: FfiDiscoveryEvidenceKind,
    pub content_sha256: String,
    pub fetched_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiDiscoveryProbeBudget {
    pub max_requests: u32,
    pub max_total_tokens_per_request: u64,
    pub max_output_tokens_per_request: u64,
    pub max_cost_micro_usd_per_request: u64,
    pub max_duration_millis_per_request: u64,
    pub max_calls_per_request: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryApprovalGrant {
    TemplateSelection {
        candidate_id: String,
    },
    AssistantConsent {
        assistant_model_route_id: String,
        evidence_ids: Vec<String>,
        allowed_document_origins: Vec<String>,
        max_calls: u32,
        max_input_tokens: u32,
        max_output_tokens: u32,
        max_tool_calls: u32,
        max_retries: u32,
        max_cost_micro_units: u64,
    },
    CredentialOrigin {
        origin: String,
        auth_binding: FfiAuthBinding,
        manifest_sha256: String,
    },
    CapabilityProbe {
        model_route_ids: Vec<String>,
        budget: FfiDiscoveryProbeBudget,
    },
    Review {
        review_sha256: String,
        graph_sha256: String,
    },
    UnknownOutcomeResolution {
        operation: FfiDiscoveryOperationKind,
        resolution: FfiDiscoveryUnknownOutcomeResolution,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryApprovalDecision {
    Approved,
    Rejected,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiDiscoveryApproval {
    pub id: String,
    pub session_revision: u64,
    pub decision: FfiDiscoveryApprovalDecision,
    pub grant: FfiDiscoveryApprovalGrant,
    pub created_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiDiscoveryApprovalProposal {
    pub approval_id: String,
    pub grant: FfiDiscoveryApprovalGrant,
    pub grant_sha256: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryReviewChangeKind {
    Add,
    Update,
    Deprecate,
    PreserveMissing,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryReviewTargetKind {
    ProviderTemplate,
    ProviderConnection,
    ModelRoute,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiDiscoveryReviewChange {
    pub kind: FfiDiscoveryReviewChangeKind,
    pub target_kind: FfiDiscoveryReviewTargetKind,
    pub target_id: String,
    pub summary_key: String,
    pub evidence_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiDiscoveryReview {
    pub sha256: String,
    pub graph_sha256: String,
    pub changes: Vec<FfiDiscoveryReviewChange>,
    pub unresolved_question_count: u32,
    pub warning_count: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiDiscoveryReviewProposal {
    pub review: FfiDiscoveryReview,
    pub approval: FfiDiscoveryApprovalProposal,
    pub commit_attempt_id: String,
    pub commit_plan_sha256: String,
    pub request_preview: Option<FfiRequestPreview>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryState {
    Draft,
    ResolvingKnownProvider,
    AwaitingTemplateSelection,
    FetchingDocuments,
    ExtractingEvidence,
    AwaitingMoreEvidence,
    AwaitingAssistantConsent,
    BuildingDeterministicManifestDraft,
    BuildingAssistantManifestDraft,
    ValidatingManifest,
    AwaitingCredentialOriginApproval,
    ListingModels,
    AwaitingProbeConsent,
    ProbingCapabilities,
    AwaitingReview,
    Committing,
    Compensating,
    Ready,
    Failed,
    Cancelled,
    Interrupted,
    UnknownOutcome,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryAssistantCheckpoint {
    Ready,
    AwaitingAssistant,
    AwaitingToolResult,
    AwaitingMoreEvidence,
    AwaitingRetryConsent,
    DraftReady,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryAssistantResumeAction {
    ApproveConsent,
    RunAssistant,
    WaitForAssistantOutcome,
    ResumeCoreHostAction,
    SupplyMoreEvidence,
    ApproveRetry,
    ReviewDraft,
    RestartInterrupted,
    ResolveUnknownOutcome,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FfiDiscoveryAssistantResumeBoundary {
    pub checkpoint: Option<FfiDiscoveryAssistantCheckpoint>,
    pub action: FfiDiscoveryAssistantResumeAction,
    pub questions: Vec<FfiDiscoveryAssistantQuestion>,
    pub draft_review: Option<FfiDiscoveryAssistantDraftReview>,
}

/// Aggregate, redacted view used by every native setup wizard.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FfiProviderDiscoverySnapshot {
    pub snapshot_schema_version: u32,
    pub session_id: String,
    /// Immutable identity selected before the session was created. Native uses
    /// this after process restart to reopen or remove the correct vault slot.
    pub pending_connection_id: String,
    pub pending_display_name: String,
    /// Exact secret-free connection policy persisted at begin. Native uses it
    /// after restart for supplemental inspection and must not substitute
    /// process defaults.
    pub connection_options: FfiProviderDiscoveryConnectionOptions,
    /// Exact opaque OS-vault slot, present only when this flow expects a
    /// credential. It is always identical to `pending_connection_id`.
    pub credential_slot_id: Option<String>,
    pub credential_slot_expected: bool,
    pub revision: u64,
    pub state: FfiDiscoveryState,
    pub next_event_sequence: u64,
    pub steps: Vec<FfiDiscoveryStep>,
    pub action_required: Option<FfiDiscoveryActionRequired>,
    pub active_operation_id: Option<String>,
    pub recovery_operation: Option<FfiDiscoveryOperationKind>,
    pub unknown_operation: Option<FfiDiscoveryOperationKind>,
    pub manifest_sha256: Option<String>,
    pub commit_plan_sha256: Option<String>,
    pub commit_attempt_id: Option<String>,
    pub committed_connection_id: Option<String>,
    pub cancellation_pending: bool,
    pub failure: Option<FfiDiscoveryFailure>,
    pub candidates: Vec<FfiDiscoveryCandidate>,
    pub evidence: Vec<FfiDiscoveryEvidence>,
    pub approvals: Vec<FfiDiscoveryApproval>,
    pub review: Option<FfiDiscoveryReview>,
    pub approval_proposal: Option<FfiDiscoveryApprovalProposal>,
    pub review_proposal: Option<FfiDiscoveryReviewProposal>,
    /// Exact durable setup-assistant boundary. Native clients must render this
    /// action directly and must not infer it from `state` or draft JSON.
    pub assistant_resume_boundary: Option<FfiDiscoveryAssistantResumeBoundary>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryWarning {
    AssistantDeclined,
    ProbesSkipped,
    CompensationRequired,
    ExplicitRestartRequired,
    UnknownExternalOutcome,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiDiscoveryEvent {
    pub event_version: u32,
    pub event_id: String,
    pub session_id: String,
    pub sequence: u64,
    pub session_revision: u64,
    pub state: FfiDiscoveryState,
    pub progress: Option<FfiDiscoveryProgress>,
    pub action_required: Option<FfiDiscoveryActionRequired>,
    pub warning: Option<FfiDiscoveryWarning>,
    pub action_id: String,
    pub failure: Option<FfiDiscoveryFailure>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiDiscoveryOutboxEvent {
    pub event: FfiDiscoveryEvent,
    pub delivery_attempts: u32,
    pub available_at: String,
    pub created_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiDiscoveryRecoveryResult {
    pub operation_id: String,
    pub session_id: String,
    pub state: FfiDiscoveryState,
    pub event: FfiDiscoveryEvent,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryCompensationKind {
    RemoveCredentialSlot,
    RemoveConnectionGraph,
    RestorePreviousSelection,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryCompensationStatus {
    Pending,
    InProgress,
    Completed,
    Failed,
    OutcomeUnknown,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryPreviousSelection {
    None,
    RouteAndPreset {
        model_route_id: String,
        generation_preset_id: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryCompensationTarget {
    RemoveCredentialSlot {
        connection_id: String,
        credential_ref: String,
    },
    RemoveConnectionGraph {
        connection_id: String,
    },
    RestorePreviousSelection {
        previous_selection: FfiDiscoveryPreviousSelection,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiDiscoveryCompensationStep {
    pub id: String,
    pub commit_attempt_id: String,
    pub ordinal: u32,
    pub action_id: String,
    pub kind: FfiDiscoveryCompensationKind,
    pub target: FfiDiscoveryCompensationTarget,
    pub status: FfiDiscoveryCompensationStatus,
    pub attempt_count: u32,
    pub last_failure: Option<FfiDiscoveryFailure>,
    pub created_at: String,
    pub updated_at: String,
    pub completed_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiDiscoveryAssistantCallEstimate {
    pub input_tokens: u64,
    pub maximum_output_tokens: u64,
    pub maximum_cost_micro_units: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryAssistantDraftField {
    ApiFamily,
    DefaultApiOrigin,
    Auth,
    GenerateEndpoint,
    ModelsEndpoint,
    ResponseDecoder,
    StreamingDecoder,
    Parameter { parameter_id: String },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiDiscoveryAssistantQuestion {
    pub id: String,
    pub field: Option<FfiDiscoveryAssistantDraftField>,
    pub question: String,
    pub required_evidence: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiDiscoveryAssistantEvidenceMapping {
    pub field: FfiDiscoveryAssistantDraftField,
    pub evidence_ids: Vec<String>,
    pub explanation: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryAssistantConfidenceLevel {
    Unknown,
    Low,
    Medium,
    High,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiDiscoveryAssistantFieldConfidence {
    pub field: FfiDiscoveryAssistantDraftField,
    pub level: FfiDiscoveryAssistantConfidenceLevel,
    pub rationale: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryAssistantConflictDisposition {
    Unresolved,
    Resolved {
        selected_evidence_id: String,
        rationale: String,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryAssistantApiFamily {
    OpenAiResponses,
    OpenAiChatCompletions,
    AnthropicMessages,
    GeminiGenerateContent,
    OllamaNative,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryAssistantManifestSourceKind {
    OfficialSite,
    OfficialDocumentation,
    SignedCatalog,
    UserSupplied,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryAssistantHttpMethod {
    Get,
    Post,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryAssistantDecoder {
    OpenAiJsonV1,
    OpenAiSseV1,
    AnthropicJsonV1,
    AnthropicSseV1,
    GeminiJsonV1,
    GeminiSseV1,
    OllamaJsonV1,
    OllamaJsonlV1,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiDiscoveryAssistantEvidenceConflict {
    pub field: FfiDiscoveryAssistantDraftField,
    pub evidence_ids: Vec<String>,
    pub disposition: FfiDiscoveryAssistantConflictDisposition,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiDiscoveryAssistantManifestSource {
    pub kind: FfiDiscoveryAssistantManifestSourceKind,
    pub url: String,
    pub content_sha256: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiDiscoveryAssistantEndpoint {
    pub method: FfiDiscoveryAssistantHttpMethod,
    pub path: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FfiDiscoveryAssistantManifest {
    pub schema_version: u32,
    pub api_family: FfiDiscoveryAssistantApiFamily,
    pub sources: Vec<FfiDiscoveryAssistantManifestSource>,
    pub default_api_origin: Option<String>,
    pub auth: FfiAuthBinding,
    pub models_endpoint: Option<FfiDiscoveryAssistantEndpoint>,
    pub generate_endpoint: FfiDiscoveryAssistantEndpoint,
    pub response_decoder: FfiDiscoveryAssistantDecoder,
    pub streaming_decoder: Option<FfiDiscoveryAssistantDecoder>,
    pub parameters: Vec<FfiParameterSpec>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FfiDiscoveryAssistantManifestDraft {
    pub manifest: FfiDiscoveryAssistantManifest,
    pub evidence_mappings: Vec<FfiDiscoveryAssistantEvidenceMapping>,
    pub conflicts: Vec<FfiDiscoveryAssistantEvidenceConflict>,
    pub unresolved_questions: Vec<FfiDiscoveryAssistantQuestion>,
    pub confidence: Vec<FfiDiscoveryAssistantFieldConfidence>,
    pub summary: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryAssistantDraftReviewCheck {
    ManifestValidation,
    UrlPolicyValidation,
    CredentialOriginApproval,
    UserReview,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiscoveryAssistantDraftPersistence {
    BlockedUntilChecksPass,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FfiDiscoveryAssistantDraftReview {
    pub draft: FfiDiscoveryAssistantManifestDraft,
    pub unresolved_conflicts: Vec<FfiDiscoveryAssistantDraftField>,
    pub required_checks: Vec<FfiDiscoveryAssistantDraftReviewCheck>,
    pub persistence: FfiDiscoveryAssistantDraftPersistence,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
#[allow(clippy::large_enum_variant)]
pub enum FfiDiscoveryAssistantHostAction {
    RequestMoreEvidence {
        session_id: String,
        questions: Vec<FfiDiscoveryAssistantQuestion>,
    },
    ReviewDraft {
        review: FfiDiscoveryAssistantDraftReview,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiCapabilityValue {
    pub kind: String,
    pub boolean_value: Option<bool>,
    pub integer_value: Option<u64>,
    pub enum_values: Vec<String>,
    /// Canonical JSON for read-only structured provider metadata.
    ///
    /// Native user overrides cannot submit this field; closed wire dialects
    /// come only from trusted provider/catalog/probe ingestion paths.
    pub structured_json: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiCapabilityObservation {
    pub id: String,
    pub model_route_id: String,
    pub key: String,
    pub value: FfiCapabilityValue,
    pub status: String,
    pub source: String,
    pub confidence: String,
    pub observed_at: String,
    pub expires_at: Option<String>,
    pub evidence_ref: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiCapabilityOverrideDraft {
    pub id: String,
    pub model_route_id: String,
    pub key: String,
    pub value: FfiCapabilityValue,
    pub status: String,
    pub expires_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiEffectiveCapability {
    pub selected: FfiCapabilityObservation,
    pub alternatives: Vec<FfiCapabilityObservation>,
    pub evaluated_at: String,
    pub selected_is_stale: bool,
    pub has_conflict: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiAppSettings {
    pub preserve_partial_generations: bool,
    pub selected_provider_profile_id: Option<String>,
    pub selected_model_route_id: Option<String>,
    pub selected_generation_preset_id: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiDatabaseStats {
    pub characters: u64,
    pub conversations: u64,
    pub messages: u64,
    pub pending_imports: u64,
}

/// A flat, versioned event representation that is forward-compatible across
/// Kotlin and Swift. Fields that do not apply to `kind` are `None`.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiChatEvent {
    pub event_version: u32,
    pub generation_id: String,
    pub conversation_id: String,
    pub branch_id: Option<String>,
    pub assistant_message_id: Option<String>,
    pub sequence: u64,
    pub emitted_at: String,
    pub kind: String,
    pub text: Option<String>,
    pub tool_call_id: Option<String>,
    pub tool_name: Option<String>,
    pub tool_arguments_delta: Option<String>,
    pub message_id: Option<String>,
    pub message_status: Option<String>,
    pub error_code: Option<String>,
    pub error_message: Option<String>,
    pub usage_input_tokens: Option<u64>,
    pub usage_cached_read_tokens: Option<u64>,
    pub usage_cached_write_tokens: Option<u64>,
    pub usage_output_tokens: Option<u64>,
    pub usage_reasoning_tokens: Option<u64>,
    pub usage_tool_tokens: Option<u64>,
    pub usage_provider_raw_summary: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiEventBatch {
    pub events: Vec<FfiChatEvent>,
    /// Number of events evicted before this poll could receive them.
    ///
    /// A non-zero value tells the platform to refresh persisted messages before
    /// applying subsequent deltas.
    pub dropped_event_count: u64,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FfiError {
    #[error("{code}: {detail}")]
    Core {
        code: String,
        detail: String,
        recoverable: bool,
        operation_id: String,
    },
}

impl From<CoreError> for FfiError {
    fn from(error: CoreError) -> Self {
        Self::Core {
            code: error.code.as_str().to_owned(),
            detail: error.message,
            recoverable: error.recoverable,
            operation_id: error.operation_id,
        }
    }
}

#[derive(uniffi::Object)]
pub struct LorepiaCore {
    core: Core,
    event_receiver: Mutex<broadcast::Receiver<ChatEvent>>,
    curl_credential_handoffs: Mutex<HashMap<String, EphemeralCredential>>,
}

struct EphemeralCredential {
    bytes: Vec<u8>,
    expires_at: Instant,
}

impl Drop for EphemeralCredential {
    fn drop(&mut self) {
        self.bytes.fill(0);
    }
}

#[uniffi::export]
pub fn core_version() -> String {
    lorepia_core::core_version().to_owned()
}

#[uniffi::export]
pub fn version_info() -> FfiVersionInfo {
    FfiVersionInfo {
        core_version: core_version(),
        core_api_version: lorepia_core::CORE_API_VERSION,
        binding_api_version: BINDING_API_VERSION,
        chat_event_version: CHAT_EVENT_VERSION,
    }
}

#[uniffi::export]
impl LorepiaCore {
    #[uniffi::constructor]
    pub fn open(config: FfiCoreConfig) -> Result<Arc<Self>, FfiError> {
        let core = Core::open(CoreConfig::new(config.data_root))?;
        let event_receiver = Mutex::new(core.subscribe_events());
        Ok(Arc::new(Self {
            core,
            event_receiver,
            curl_credential_handoffs: Mutex::new(HashMap::new()),
        }))
    }

    pub fn health_check(&self) -> Result<FfiHealthReport, FfiError> {
        let report = self.core.health_check()?;
        Ok(FfiHealthReport {
            core_version: report.core_version,
            database_open: report.database_open,
            schema_version: report.schema_version,
            data_root_writable: report.data_root_writable,
            staging_writable: report.staging_writable,
            recovery_pending: report.recovery_pending,
            active_jobs: report.active_jobs,
        })
    }

    pub fn inspect_import(&self, staged_path: String) -> Result<FfiImportInspection, FfiError> {
        self.core
            .inspect_import(staged_path)
            .map(map_inspection)
            .map_err(Into::into)
    }

    pub fn commit_import(&self, inspection_id: String) -> Result<FfiCharacter, FfiError> {
        self.core
            .commit_import(&InspectionId(inspection_id))
            .map(map_character)
            .map_err(Into::into)
    }

    pub fn discard_import(&self, inspection_id: String) -> Result<(), FfiError> {
        self.core
            .discard_import(&InspectionId(inspection_id))
            .map_err(Into::into)
    }

    pub fn list_characters(&self) -> Result<Vec<FfiCharacter>, FfiError> {
        self.core
            .list_characters()
            .map(|characters| characters.into_iter().map(map_character).collect())
            .map_err(Into::into)
    }

    pub fn get_character(&self, character_id: String) -> Result<FfiCharacter, FfiError> {
        self.core
            .get_character(&character_id)
            .map(map_character)
            .map_err(Into::into)
    }

    pub fn open_conversation(&self, character_id: String) -> Result<FfiConversation, FfiError> {
        self.core
            .open_conversation(&character_id)
            .map(map_conversation)
            .map_err(Into::into)
    }

    pub fn create_conversation(
        &self,
        character_id: String,
        title: String,
        mode: String,
    ) -> Result<FfiConversation, FfiError> {
        let mode = parse_conversation_mode(&mode)?;
        self.core
            .create_conversation(&character_id, title, mode)
            .map(map_conversation)
            .map_err(Into::into)
    }

    pub fn list_conversations(&self) -> Result<Vec<FfiConversation>, FfiError> {
        self.core
            .list_conversations()
            .map(|conversations| conversations.into_iter().map(map_conversation).collect())
            .map_err(Into::into)
    }

    pub fn list_conversations_for_character(
        &self,
        character_id: String,
    ) -> Result<Vec<FfiConversation>, FfiError> {
        self.core
            .list_conversations_for_character(&character_id)
            .map(|conversations| conversations.into_iter().map(map_conversation).collect())
            .map_err(Into::into)
    }

    pub fn get_conversation(&self, conversation_id: String) -> Result<FfiConversation, FfiError> {
        self.core
            .get_conversation(&ConversationId(conversation_id))
            .map(map_conversation)
            .map_err(Into::into)
    }

    pub fn get_conversation_state(
        &self,
        conversation_id: String,
    ) -> Result<FfiConversationState, FfiError> {
        self.core
            .get_conversation_state(&ConversationId(conversation_id))
            .map(map_conversation_state)
            .map_err(Into::into)
    }

    pub fn list_conversation_branches(
        &self,
        conversation_id: String,
    ) -> Result<Vec<FfiConversationBranch>, FfiError> {
        self.core
            .list_conversation_branches(&ConversationId(conversation_id))
            .map(|branches| branches.into_iter().map(map_conversation_branch).collect())
            .map_err(Into::into)
    }

    pub fn create_conversation_branch(
        &self,
        conversation_id: String,
        from_message_id: Option<String>,
        title: Option<String>,
    ) -> Result<FfiConversationBranch, FfiError> {
        let from_message_id = from_message_id.map(MessageId);
        self.core
            .create_conversation_branch(
                &ConversationId(conversation_id),
                from_message_id.as_ref(),
                title,
            )
            .map(map_conversation_branch)
            .map_err(Into::into)
    }

    pub fn select_conversation_branch(
        &self,
        conversation_id: String,
        branch_id: String,
    ) -> Result<FfiConversationState, FfiError> {
        self.core
            .select_conversation_branch(
                &ConversationId(conversation_id),
                &ConversationBranchId(branch_id),
            )
            .map(map_conversation_state)
            .map_err(Into::into)
    }

    pub fn set_conversation_mode(
        &self,
        conversation_id: String,
        mode: String,
    ) -> Result<FfiConversationState, FfiError> {
        let mode = parse_conversation_mode(&mode)?;
        self.core
            .set_conversation_mode(&ConversationId(conversation_id), mode)
            .map(map_conversation_state)
            .map_err(Into::into)
    }

    pub fn list_branch_messages(&self, branch_id: String) -> Result<Vec<FfiMessage>, FfiError> {
        self.core
            .list_branch_messages(&ConversationBranchId(branch_id))
            .map(|messages| messages.into_iter().map(map_message).collect())
            .map_err(Into::into)
    }

    pub fn list_messages(&self, conversation_id: String) -> Result<Vec<FfiMessage>, FfiError> {
        self.core
            .list_messages(&ConversationId(conversation_id))
            .map(|messages| messages.into_iter().map(map_message).collect())
            .map_err(Into::into)
    }

    pub fn send_message(
        &self,
        conversation_id: String,
        text: String,
        provider_profile_id: String,
        credential: Option<String>,
    ) -> Result<String, FfiError> {
        self.core
            .send_message(
                &ConversationId(conversation_id),
                &text,
                &provider_profile_id,
                credential,
            )
            .map(|generation_id| generation_id.0)
            .map_err(Into::into)
    }

    pub fn send_message_with_target(
        &self,
        conversation_id: String,
        text: String,
        target: FfiGenerationTarget,
        credential: Option<String>,
    ) -> Result<String, FfiError> {
        self.core
            .send_message_with_target(
                &ConversationId(conversation_id),
                &text,
                &unmap_generation_target(target),
                credential,
            )
            .map(|generation_id| generation_id.0)
            .map_err(Into::into)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn send_message_to_branch(
        &self,
        conversation_id: String,
        branch_id: String,
        expected_head: Option<String>,
        mode: String,
        text: String,
        provider_profile_id: String,
        credential: Option<String>,
    ) -> Result<String, FfiError> {
        let expected_head = expected_head.map(MessageId);
        let mode = parse_conversation_mode(&mode)?;
        self.core
            .send_message_to_branch(
                &ConversationId(conversation_id),
                &ConversationBranchId(branch_id),
                expected_head.as_ref(),
                mode,
                &text,
                &provider_profile_id,
                credential,
            )
            .map(|generation_id| generation_id.0)
            .map_err(Into::into)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn send_message_to_branch_with_target(
        &self,
        conversation_id: String,
        branch_id: String,
        expected_head: Option<String>,
        mode: String,
        text: String,
        target: FfiGenerationTarget,
        credential: Option<String>,
    ) -> Result<String, FfiError> {
        let expected_head = expected_head.map(MessageId);
        let mode = parse_conversation_mode(&mode)?;
        self.core
            .send_message_to_branch_with_target(
                &ConversationId(conversation_id),
                &ConversationBranchId(branch_id),
                expected_head.as_ref(),
                mode,
                &text,
                &unmap_generation_target(target),
                credential,
            )
            .map(|generation_id| generation_id.0)
            .map_err(Into::into)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn edit_user_message(
        &self,
        conversation_id: String,
        branch_id: String,
        expected_head: Option<String>,
        message_id: String,
        replacement_text: String,
        provider_profile_id: String,
        credential: Option<String>,
    ) -> Result<FfiMessageActionGeneration, FfiError> {
        let expected_head = expected_head.map(MessageId);
        self.core
            .edit_user_message(
                &ConversationId(conversation_id),
                &ConversationBranchId(branch_id),
                expected_head.as_ref(),
                &MessageId(message_id),
                &replacement_text,
                &provider_profile_id,
                credential,
            )
            .map(map_message_action_generation)
            .map_err(Into::into)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn edit_user_message_with_target(
        &self,
        conversation_id: String,
        branch_id: String,
        expected_head: Option<String>,
        message_id: String,
        replacement_text: String,
        target: FfiGenerationTarget,
        credential: Option<String>,
    ) -> Result<FfiMessageActionGeneration, FfiError> {
        let expected_head = expected_head.map(MessageId);
        self.core
            .edit_user_message_with_target(
                &ConversationId(conversation_id),
                &ConversationBranchId(branch_id),
                expected_head.as_ref(),
                &MessageId(message_id),
                &replacement_text,
                &unmap_generation_target(target),
                credential,
            )
            .map(map_message_action_generation)
            .map_err(Into::into)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn regenerate_assistant_message(
        &self,
        conversation_id: String,
        branch_id: String,
        expected_head: Option<String>,
        message_id: String,
        provider_profile_id: String,
        credential: Option<String>,
    ) -> Result<FfiMessageActionGeneration, FfiError> {
        let expected_head = expected_head.map(MessageId);
        self.core
            .regenerate_assistant_message(
                &ConversationId(conversation_id),
                &ConversationBranchId(branch_id),
                expected_head.as_ref(),
                &MessageId(message_id),
                &provider_profile_id,
                credential,
            )
            .map(map_message_action_generation)
            .map_err(Into::into)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn regenerate_assistant_message_with_target(
        &self,
        conversation_id: String,
        branch_id: String,
        expected_head: Option<String>,
        message_id: String,
        target: FfiGenerationTarget,
        credential: Option<String>,
    ) -> Result<FfiMessageActionGeneration, FfiError> {
        let expected_head = expected_head.map(MessageId);
        self.core
            .regenerate_assistant_message_with_target(
                &ConversationId(conversation_id),
                &ConversationBranchId(branch_id),
                expected_head.as_ref(),
                &MessageId(message_id),
                &unmap_generation_target(target),
                credential,
            )
            .map(map_message_action_generation)
            .map_err(Into::into)
    }

    pub fn remove_message_from_branch(
        &self,
        conversation_id: String,
        branch_id: String,
        expected_head: Option<String>,
        message_id: String,
    ) -> Result<FfiConversationBranch, FfiError> {
        let expected_head = expected_head.map(MessageId);
        self.core
            .remove_message_from_branch(
                &ConversationId(conversation_id),
                &ConversationBranchId(branch_id),
                expected_head.as_ref(),
                &MessageId(message_id),
            )
            .map(map_conversation_branch)
            .map_err(Into::into)
    }

    pub fn cancel_generation(&self, generation_id: String) -> Result<(), FfiError> {
        self.core
            .cancel_generation(&GenerationId(generation_id))
            .map_err(Into::into)
    }

    /// Drains up to `max_events` without blocking a platform UI thread.
    pub fn poll_events(&self, max_events: u32) -> Result<FfiEventBatch, FfiError> {
        if max_events == 0 || max_events > MAX_EVENT_BATCH_SIZE {
            return Err(CoreError::invalid(format!(
                "max_events must be between 1 and {MAX_EVENT_BATCH_SIZE}"
            ))
            .into());
        }
        let mut receiver = self
            .event_receiver
            .lock()
            .map_err(|_| FfiError::from(CoreError::internal("event receiver lock was poisoned")))?;
        let mut events = Vec::with_capacity(max_events as usize);
        let mut dropped_event_count = 0_u64;
        while events.len() < max_events as usize {
            match receiver.try_recv() {
                Ok(event) => events.push(map_chat_event(event)),
                Err(
                    broadcast::error::TryRecvError::Empty | broadcast::error::TryRecvError::Closed,
                ) => {
                    break;
                }
                Err(broadcast::error::TryRecvError::Lagged(skipped)) => {
                    dropped_event_count = dropped_event_count.saturating_add(skipped);
                }
            }
        }
        Ok(FfiEventBatch {
            events,
            dropped_event_count,
        })
    }

    pub fn list_provider_profiles(&self) -> Result<Vec<FfiProviderProfile>, FfiError> {
        self.core
            .list_provider_profiles()
            .map(|profiles| profiles.into_iter().map(map_provider_profile).collect())
            .map_err(Into::into)
    }

    pub fn upsert_provider_profile(
        &self,
        profile: FfiProviderProfile,
    ) -> Result<FfiProviderProfile, FfiError> {
        self.core
            .upsert_provider_profile(unmap_provider_profile(profile))
            .map(map_provider_profile)
            .map_err(Into::into)
    }

    pub fn delete_provider_profile(&self, profile_id: String) -> Result<(), FfiError> {
        self.core
            .delete_provider_profile(&profile_id)
            .map_err(Into::into)
    }

    pub fn list_provider_templates(&self) -> Result<Vec<FfiProviderTemplate>, FfiError> {
        self.core
            .list_provider_template_views()
            .map(|templates| {
                templates
                    .into_iter()
                    .map(map_provider_template_view)
                    .collect()
            })
            .map_err(Into::into)
    }

    pub fn inspect_provider_curl(
        &self,
        raw_curl: String,
        network_policy: FfiProviderNetworkPolicy,
    ) -> Result<FfiProviderCurlInspection, FfiError> {
        let connection_options = validate_provider_network_policy(network_policy)?;
        let inspection = self
            .core
            .inspect_provider_curl(SecretCurlInput::new(raw_curl), connection_options)?;
        let credential_handoff_id = if let Some(credential) = inspection.extracted_credential() {
            let handoff_id = DiscoveryActionId::new().as_str().to_owned();
            let mut handoffs = self
                .curl_credential_handoffs
                .lock()
                .map_err(|_| CoreError::internal("cURL credential handoff state is unavailable"))?;
            let now = Instant::now();
            handoffs.retain(|_, entry| entry.expires_at > now);
            if handoffs.len() >= MAX_CURL_CREDENTIAL_HANDOFFS
                && let Some(oldest_id) = handoffs
                    .iter()
                    .min_by_key(|(_, entry)| entry.expires_at)
                    .map(|(id, _)| id.clone())
            {
                handoffs.remove(&oldest_id);
            }
            handoffs.insert(
                handoff_id.clone(),
                EphemeralCredential {
                    bytes: credential.to_vec(),
                    expires_at: now + CURL_CREDENTIAL_HANDOFF_TTL,
                },
            );
            Some(handoff_id)
        } else {
            None
        };
        Ok(map_provider_curl_inspection(
            inspection,
            credential_handoff_id,
        ))
    }

    /// Takes one inspected cURL credential exactly once.
    ///
    /// The opaque handoff expires after two minutes and is kept only in this
    /// binding object's memory. Native must write the bytes directly to its OS
    /// credential vault and clear its temporary buffer.
    pub fn take_provider_curl_credential(
        &self,
        credential_handoff_id: String,
    ) -> Result<Option<Vec<u8>>, FfiError> {
        let mut handoffs = self
            .curl_credential_handoffs
            .lock()
            .map_err(|_| CoreError::internal("cURL credential handoff state is unavailable"))?;
        let Some(mut credential) = handoffs.remove(&credential_handoff_id) else {
            return Ok(None);
        };
        if credential.expires_at <= Instant::now() {
            return Ok(None);
        }
        Ok(Some(std::mem::take(&mut credential.bytes)))
    }

    pub fn begin_provider_discovery(
        &self,
        input: FfiProviderDiscoveryInput,
        source: FfiProviderDiscoverySource,
        raw_curl: Option<String>,
    ) -> Result<FfiProviderDiscoverySnapshot, FfiError> {
        let snapshot = match source {
            FfiProviderDiscoverySource::KnownProvider { template_id } => {
                if raw_curl.is_some() {
                    return Err(
                        CoreError::invalid("raw cURL is accepted only for cURL discovery").into(),
                    );
                }
                let input = unmap_provider_discovery_input(&self.core, input, Some(&template_id))?;
                self.core
                    .begin_provider_discovery_known(input, ProviderTemplateId::from(template_id))?
            }
            FfiProviderDiscoverySource::Site => {
                if raw_curl.is_some() {
                    return Err(
                        CoreError::invalid("raw cURL is accepted only for cURL discovery").into(),
                    );
                }
                let input = unmap_provider_discovery_input(&self.core, input, None)?;
                self.core.begin_provider_discovery_site(input)?
            }
            FfiProviderDiscoverySource::Curl => {
                let raw_curl = raw_curl.ok_or_else(|| {
                    CoreError::invalid("cURL discovery requires one request-scoped raw cURL")
                })?;
                let input = unmap_provider_discovery_curl_input(input)?;
                self.core
                    .begin_provider_discovery_curl(input, SecretCurlInput::new(raw_curl))?
            }
        };
        map_provider_discovery_snapshot(&self.core, snapshot).map_err(Into::into)
    }

    pub fn prepare_provider_discovery_action(
        &self,
        action_id: String,
        expected_revision: u64,
        action: FfiProviderDiscoveryAction,
    ) -> Result<FfiProviderDiscoveryActionEnvelope, FfiError> {
        let action = unmap_provider_discovery_action(action)?;
        let envelope = provider_discovery_action_envelope(
            parse_discovery_action_id(action_id)?,
            expected_revision,
            action,
        )?;
        Ok(map_provider_discovery_action_envelope(envelope))
    }

    pub fn get_provider_discovery(
        &self,
        session_id: String,
    ) -> Result<FfiProviderDiscoverySnapshot, FfiError> {
        let session_id = DiscoverySessionId::from(session_id);
        let snapshot = self.core.get_provider_discovery(&session_id)?;
        map_provider_discovery_snapshot(&self.core, snapshot).map_err(Into::into)
    }

    pub fn list_provider_discoveries(
        &self,
        limit: u32,
    ) -> Result<Vec<FfiProviderDiscoverySnapshot>, FfiError> {
        validate_discovery_list_limit(limit)?;
        self.core
            .list_provider_discoveries(limit)
            .and_then(|snapshots| {
                snapshots
                    .into_iter()
                    .map(|snapshot| map_provider_discovery_snapshot(&self.core, snapshot))
                    .collect()
            })
            .map_err(Into::into)
    }

    pub fn list_provider_discovery_candidates(
        &self,
        session_id: String,
    ) -> Result<Vec<FfiDiscoveryCandidate>, FfiError> {
        self.core
            .list_provider_discovery_candidates(&DiscoverySessionId::from(session_id))
            .map(|records| records.into_iter().map(map_discovery_candidate).collect())
            .map_err(Into::into)
    }

    pub fn list_provider_discovery_evidence(
        &self,
        session_id: String,
    ) -> Result<Vec<FfiDiscoveryEvidence>, FfiError> {
        self.core
            .list_provider_discovery_evidence(&DiscoverySessionId::from(session_id))
            .map(|records| records.into_iter().map(map_discovery_evidence).collect())
            .map_err(Into::into)
    }

    pub fn list_provider_discovery_approvals(
        &self,
        session_id: String,
    ) -> Result<Vec<FfiDiscoveryApproval>, FfiError> {
        self.core
            .list_provider_discovery_approvals(&DiscoverySessionId::from(session_id))
            .map(|records| records.into_iter().map(map_discovery_approval).collect())
            .map_err(Into::into)
    }

    pub fn get_provider_discovery_review(
        &self,
        session_id: String,
    ) -> Result<Option<FfiDiscoveryReview>, FfiError> {
        self.core
            .get_provider_discovery_review(&DiscoverySessionId::from(session_id))
            .and_then(|review| review.map(map_discovery_review).transpose())
            .map_err(Into::into)
    }

    pub fn get_provider_discovery_approval_proposal(
        &self,
        session_id: String,
    ) -> Result<Option<FfiDiscoveryApprovalProposal>, FfiError> {
        self.core
            .get_provider_discovery_approval_proposal(&DiscoverySessionId::from(session_id))
            .map(|proposal| proposal.map(map_discovery_approval_proposal))
            .map_err(Into::into)
    }

    pub fn get_provider_discovery_review_proposal(
        &self,
        session_id: String,
    ) -> Result<Option<FfiDiscoveryReviewProposal>, FfiError> {
        self.core
            .get_provider_discovery_review_proposal(&DiscoverySessionId::from(session_id))
            .and_then(|proposal| proposal.map(map_discovery_review_proposal).transpose())
            .map_err(Into::into)
    }

    /// Applies one canonical public action.
    ///
    /// `target_credential` is an optional request-scoped vault read used only
    /// by an approved provider probe. It is never persisted or returned.
    pub fn continue_provider_discovery(
        &self,
        session_id: String,
        envelope: FfiProviderDiscoveryActionEnvelope,
        target_credential: Option<String>,
    ) -> Result<FfiProviderDiscoverySnapshot, FfiError> {
        let session_id = DiscoverySessionId::from(session_id);
        let envelope = unmap_provider_discovery_action_envelope(envelope)?;
        let snapshot = self.core.continue_provider_discovery(
            &session_id,
            envelope,
            target_credential.as_deref(),
        )?;
        map_provider_discovery_snapshot(&self.core, snapshot).map_err(Into::into)
    }

    pub fn supply_provider_discovery_document_evidence(
        &self,
        session_id: String,
        expected_revision: u64,
        document_url: String,
    ) -> Result<FfiProviderDiscoverySnapshot, FfiError> {
        let source = lorepia_core::ProviderDiscoveryAdditionalEvidence::document_url(
            parse_http_url(document_url, "document_url")?,
        );
        let snapshot = self.core.supply_provider_discovery_evidence(
            &DiscoverySessionId::from(session_id),
            expected_revision,
            source,
        )?;
        map_provider_discovery_snapshot(&self.core, snapshot).map_err(Into::into)
    }

    pub fn supply_provider_discovery_curl_evidence(
        &self,
        session_id: String,
        expected_revision: u64,
        raw_curl: String,
    ) -> Result<FfiProviderDiscoverySnapshot, FfiError> {
        let source =
            lorepia_core::ProviderDiscoveryAdditionalEvidence::curl(SecretCurlInput::new(raw_curl));
        let snapshot = self.core.supply_provider_discovery_evidence(
            &DiscoverySessionId::from(session_id),
            expected_revision,
            source,
        )?;
        map_provider_discovery_snapshot(&self.core, snapshot).map_err(Into::into)
    }

    pub fn cancel_provider_discovery(
        &self,
        session_id: String,
        expected_revision: u64,
    ) -> Result<FfiProviderDiscoverySnapshot, FfiError> {
        let snapshot = self
            .core
            .cancel_provider_discovery(&DiscoverySessionId::from(session_id), expected_revision)?;
        map_provider_discovery_snapshot(&self.core, snapshot).map_err(Into::into)
    }

    pub fn commit_provider_discovery(
        &self,
        session_id: String,
        credential_reference_confirmed: bool,
    ) -> Result<FfiProviderConnection, FfiError> {
        self.core
            .commit_provider_discovery(
                &DiscoverySessionId::from(session_id),
                credential_reference_confirmed,
            )
            .map(map_provider_connection)
            .map_err(Into::into)
    }

    pub fn list_provider_discovery_compensation_steps(
        &self,
        commit_attempt_id: String,
    ) -> Result<Vec<FfiDiscoveryCompensationStep>, FfiError> {
        self.core
            .list_provider_discovery_compensation_steps(&parse_discovery_commit_attempt_id(
                commit_attempt_id,
            )?)
            .map(|steps| {
                steps
                    .into_iter()
                    .map(map_discovery_compensation_step)
                    .collect()
            })
            .map_err(Into::into)
    }

    pub fn continue_provider_discovery_compensation(
        &self,
        session_id: String,
    ) -> Result<FfiProviderDiscoverySnapshot, FfiError> {
        let snapshot = self
            .core
            .continue_provider_discovery_compensation(&DiscoverySessionId::from(session_id))?;
        map_provider_discovery_snapshot(&self.core, snapshot).map_err(Into::into)
    }

    /// Claims the one native-owned credential deletion step.
    ///
    /// The returned typed target is the only OS-vault slot native may delete.
    pub fn start_provider_discovery_credential_compensation(
        &self,
        session_id: String,
        step_id: String,
    ) -> Result<FfiDiscoveryCompensationStep, FfiError> {
        self.core
            .start_provider_discovery_credential_compensation(
                &DiscoverySessionId::from(session_id),
                &step_id,
            )
            .map(map_discovery_compensation_step)
            .map_err(Into::into)
    }

    pub fn complete_provider_discovery_credential_compensation(
        &self,
        session_id: String,
        step_id: String,
    ) -> Result<FfiProviderDiscoverySnapshot, FfiError> {
        let snapshot = self
            .core
            .complete_provider_discovery_credential_compensation(
                &DiscoverySessionId::from(session_id),
                &step_id,
            )?;
        map_provider_discovery_snapshot(&self.core, snapshot).map_err(Into::into)
    }

    pub fn fail_provider_discovery_credential_compensation(
        &self,
        session_id: String,
        step_id: String,
        failure: FfiDiscoveryFailure,
    ) -> Result<FfiProviderDiscoverySnapshot, FfiError> {
        let snapshot = self.core.fail_provider_discovery_credential_compensation(
            &DiscoverySessionId::from(session_id),
            &step_id,
            unmap_discovery_failure(failure),
        )?;
        map_provider_discovery_snapshot(&self.core, snapshot).map_err(Into::into)
    }

    pub fn mark_provider_discovery_credential_compensation_unknown(
        &self,
        session_id: String,
        step_id: String,
    ) -> Result<FfiProviderDiscoverySnapshot, FfiError> {
        let snapshot = self
            .core
            .mark_provider_discovery_credential_compensation_unknown(
                &DiscoverySessionId::from(session_id),
                &step_id,
            )?;
        map_provider_discovery_snapshot(&self.core, snapshot).map_err(Into::into)
    }

    pub fn resume_provider_discovery_compensation(
        &self,
        session_id: String,
    ) -> Result<FfiProviderDiscoverySnapshot, FfiError> {
        let snapshot = self
            .core
            .resume_provider_discovery_compensation(&DiscoverySessionId::from(session_id))?;
        map_provider_discovery_snapshot(&self.core, snapshot).map_err(Into::into)
    }

    pub fn recover_provider_discoveries(
        &self,
    ) -> Result<Vec<FfiDiscoveryRecoveryResult>, FfiError> {
        self.core
            .recover_provider_discovery(Utc::now())
            .map(|records| {
                records
                    .into_iter()
                    .map(map_discovery_recovery_result)
                    .collect()
            })
            .map_err(Into::into)
    }

    pub fn poll_provider_discovery_events(
        &self,
        limit: u32,
    ) -> Result<Vec<FfiDiscoveryOutboxEvent>, FfiError> {
        validate_discovery_list_limit(limit)?;
        self.core
            .poll_provider_discovery_events(limit, Utc::now())
            .map(|events| events.into_iter().map(map_discovery_outbox_event).collect())
            .map_err(Into::into)
    }

    pub fn ack_provider_discovery_event(&self, event_id: String) -> Result<bool, FfiError> {
        self.core
            .ack_provider_discovery_event(&parse_discovery_event_id(event_id)?, Utc::now())
            .map_err(Into::into)
    }

    /// Runs one provider-discovery assistant turn inside Core.
    ///
    /// `assistant_credential` is request-scoped secret material obtained from
    /// the native vault. It is never retained in a DTO, event, or snapshot.
    pub fn run_provider_discovery_assistant_turn(
        &self,
        session_id: String,
        estimate: FfiDiscoveryAssistantCallEstimate,
        assistant_credential: Option<String>,
    ) -> Result<FfiDiscoveryAssistantHostAction, FfiError> {
        self.core
            .run_provider_discovery_assistant_turn(
                &DiscoverySessionId::from(session_id),
                AssistantCallEstimate {
                    input_tokens: estimate.input_tokens,
                    maximum_output_tokens: estimate.maximum_output_tokens,
                    maximum_cost_micro_units: estimate.maximum_cost_micro_units,
                },
                assistant_credential.as_deref(),
            )
            .and_then(map_discovery_assistant_host_action)
            .map_err(Into::into)
    }

    /// Resumes one durably pending allowlisted assistant tool action entirely
    /// inside Core. No raw tool call or tool-result payload crosses `UniFFI`.
    pub fn resume_provider_discovery_assistant_core_host_action(
        &self,
        session_id: String,
    ) -> Result<FfiProviderDiscoverySnapshot, FfiError> {
        let snapshot = self
            .core
            .resume_provider_discovery_assistant_core_host_action(&DiscoverySessionId::from(
                session_id,
            ))?;
        map_provider_discovery_snapshot(&self.core, snapshot).map_err(Into::into)
    }

    pub fn approve_provider_discovery_assistant_retry(
        &self,
        session_id: String,
    ) -> Result<FfiProviderDiscoverySnapshot, FfiError> {
        let snapshot = self
            .core
            .approve_provider_discovery_assistant_retry(&DiscoverySessionId::from(session_id))?;
        map_provider_discovery_snapshot(&self.core, snapshot).map_err(Into::into)
    }

    pub fn request_provider_discovery_assistant_revision(
        &self,
        session_id: String,
    ) -> Result<FfiProviderDiscoverySnapshot, FfiError> {
        let snapshot = self
            .core
            .request_provider_discovery_assistant_revision(&DiscoverySessionId::from(session_id))?;
        map_provider_discovery_snapshot(&self.core, snapshot).map_err(Into::into)
    }

    pub fn accept_provider_discovery_assistant_draft(
        &self,
        session_id: String,
    ) -> Result<FfiProviderDiscoverySnapshot, FfiError> {
        let snapshot = self
            .core
            .accept_provider_discovery_assistant_draft(&DiscoverySessionId::from(session_id))?;
        map_provider_discovery_snapshot(&self.core, snapshot).map_err(Into::into)
    }

    pub fn record_provider_discovery_assistant_failure(
        &self,
        session_id: String,
        kind: String,
        retryable: bool,
    ) -> Result<FfiProviderDiscoverySnapshot, FfiError> {
        let snapshot = self.core.record_provider_discovery_assistant_failure(
            &DiscoverySessionId::from(session_id),
            parse_assistant_failure_kind(&kind)?,
            retryable,
        )?;
        map_provider_discovery_snapshot(&self.core, snapshot).map_err(Into::into)
    }

    pub fn create_provider_connection(
        &self,
        draft: FfiProviderConnectionDraft,
    ) -> Result<FfiProviderConnection, FfiError> {
        let draft = unmap_provider_connection_draft(draft)?;
        self.core
            .create_provider_connection(draft)
            .map(map_provider_connection)
            .map_err(Into::into)
    }

    pub fn list_provider_connections(&self) -> Result<Vec<FfiProviderConnection>, FfiError> {
        self.core
            .list_provider_connections()
            .map(|connections| {
                connections
                    .into_iter()
                    .map(map_provider_connection)
                    .collect()
            })
            .map_err(Into::into)
    }

    pub fn upsert_provider_connection(
        &self,
        connection: FfiProviderConnection,
    ) -> Result<FfiProviderConnection, FfiError> {
        let connection = unmap_provider_connection(connection)?;
        self.core
            .upsert_provider_connection(connection)
            .map(map_provider_connection)
            .map_err(Into::into)
    }

    pub fn delete_provider_connection(&self, connection_id: String) -> Result<(), FfiError> {
        self.core
            .delete_provider_connection(&ProviderConnectionId::from(connection_id))
            .map_err(Into::into)
    }

    pub fn list_model_routes(&self, connection_id: String) -> Result<Vec<FfiModelRoute>, FfiError> {
        self.core
            .list_model_routes(&ProviderConnectionId::from(connection_id))
            .map(|routes| routes.into_iter().map(map_model_route).collect())
            .map_err(Into::into)
    }

    #[allow(deprecated)]
    pub fn refresh_provider_models(
        &self,
        connection_id: String,
        credential: Option<String>,
    ) -> Result<FfiProviderModelRefreshResult, FfiError> {
        self.core
            .refresh_provider_models(
                &ProviderConnectionId::from(connection_id),
                credential.as_deref(),
            )
            .map(map_provider_model_refresh_result)
            .map_err(Into::into)
    }

    pub fn start_provider_model_sync(
        &self,
        connection_id: String,
        credential: Option<String>,
    ) -> Result<String, FfiError> {
        self.core
            .start_provider_model_sync(&ProviderConnectionId::from(connection_id), credential)
            .map(ModelSyncJobId::into_inner)
            .map_err(Into::into)
    }

    pub fn get_provider_model_sync(&self, job_id: String) -> Result<FfiModelSyncJob, FfiError> {
        self.core
            .get_provider_model_sync(&ModelSyncJobId::from(job_id))
            .map(map_model_sync_job)
            .map_err(Into::into)
    }

    pub fn list_provider_model_syncs(
        &self,
        connection_id: String,
        limit: u32,
    ) -> Result<Vec<FfiModelSyncJob>, FfiError> {
        self.core
            .list_provider_model_syncs(&ProviderConnectionId::from(connection_id), limit)
            .map(|jobs| jobs.into_iter().map(map_model_sync_job).collect())
            .map_err(Into::into)
    }

    pub fn approve_provider_model_sync(
        &self,
        job_id: String,
        review_sha256: String,
    ) -> Result<FfiModelSyncJob, FfiError> {
        self.core
            .approve_provider_model_sync(&ModelSyncJobId::from(job_id), &review_sha256)
            .map(map_model_sync_job)
            .map_err(Into::into)
    }

    pub fn cancel_provider_model_sync(&self, job_id: String) -> Result<FfiModelSyncJob, FfiError> {
        self.core
            .cancel_provider_model_sync(&ModelSyncJobId::from(job_id))
            .map(map_model_sync_job)
            .map_err(Into::into)
    }

    pub fn poll_provider_model_sync_job_events(
        &self,
        job_id: String,
        limit: u32,
    ) -> Result<Vec<FfiModelSyncEvent>, FfiError> {
        self.core
            .poll_provider_model_sync_events(&ModelSyncJobId::from(job_id), limit)
            .map(|events| events.into_iter().map(map_model_sync_event).collect())
            .map_err(Into::into)
    }

    pub fn ack_provider_model_sync_event(
        &self,
        job_id: String,
        sequence: u64,
    ) -> Result<bool, FfiError> {
        self.core
            .ack_provider_model_sync_event(&ModelSyncJobId::from(job_id), sequence)
            .map_err(Into::into)
    }

    pub fn provider_catalog_status(&self) -> Result<FfiProviderCatalogStatus, FfiError> {
        self.core
            .provider_catalog_status()
            .map(map_provider_catalog_status)
            .map_err(Into::into)
    }

    pub fn provider_catalog_history(
        &self,
        limit: u32,
        before_revision: Option<u64>,
        before_state_version: Option<u64>,
    ) -> Result<FfiProviderCatalogHistory, FfiError> {
        self.core
            .provider_catalog_history(limit, before_revision, before_state_version)
            .map(map_provider_catalog_history)
            .map_err(Into::into)
    }

    pub fn prepare_signed_provider_catalog_import(
        &self,
        envelope_json: Vec<u8>,
    ) -> Result<FfiProviderCatalogImportPlan, FfiError> {
        self.core
            .prepare_signed_provider_catalog_import(&envelope_json)
            .and_then(map_provider_catalog_import_plan)
            .map_err(Into::into)
    }

    pub fn activate_signed_provider_catalog_import(
        &self,
        plan: FfiProviderCatalogImportPlan,
        envelope_json: Vec<u8>,
    ) -> Result<FfiProviderCatalogImportResult, FfiError> {
        let plan = unmap_provider_catalog_import_plan(plan)?;
        self.core
            .activate_signed_provider_catalog_import(&plan, &envelope_json)
            .map(map_provider_catalog_import_result)
            .map_err(Into::into)
    }

    pub fn diff_provider_catalog_revisions(
        &self,
        from_revision: u64,
        to_revision: u64,
    ) -> Result<FfiProviderCatalogDiff, FfiError> {
        self.core
            .diff_provider_catalog_revisions(from_revision, to_revision)
            .map(map_provider_catalog_diff)
            .map_err(Into::into)
    }

    pub fn prepare_provider_catalog_rollback(
        &self,
        target_revision: u64,
    ) -> Result<FfiProviderCatalogRollbackPlan, FfiError> {
        self.core
            .prepare_provider_catalog_rollback(target_revision)
            .and_then(map_provider_catalog_rollback_plan)
            .map_err(Into::into)
    }

    pub fn activate_provider_catalog_rollback(
        &self,
        plan: FfiProviderCatalogRollbackPlan,
    ) -> Result<FfiProviderCatalogRollbackResult, FfiError> {
        let plan = unmap_provider_catalog_rollback_plan(plan)?;
        self.core
            .activate_provider_catalog_rollback(&plan)
            .map(map_provider_catalog_rollback_result)
            .map_err(Into::into)
    }

    pub fn upsert_model_route(&self, route: FfiModelRoute) -> Result<FfiModelRoute, FfiError> {
        let route = unmap_model_route(route)?;
        self.core
            .upsert_model_route(route)
            .map(map_model_route)
            .map_err(Into::into)
    }

    pub fn delete_model_route(&self, model_route_id: String) -> Result<(), FfiError> {
        self.core
            .delete_model_route(&ModelRouteId::from(model_route_id))
            .map_err(Into::into)
    }

    pub fn list_capability_observations(
        &self,
        model_route_id: String,
    ) -> Result<Vec<FfiCapabilityObservation>, FfiError> {
        self.core
            .list_capability_observations(&ModelRouteId::from(model_route_id))
            .map(|observations| {
                observations
                    .into_iter()
                    .map(map_capability_observation)
                    .collect()
            })
            .map_err(Into::into)
    }

    pub fn effective_capability(
        &self,
        model_route_id: String,
        key: String,
    ) -> Result<Option<FfiEffectiveCapability>, FfiError> {
        self.core
            .effective_capability(
                &ModelRouteId::from(model_route_id),
                parse_capability_key(&key)?,
            )
            .map(|capability| capability.map(map_effective_capability))
            .map_err(Into::into)
    }

    pub fn effective_parameter_specs(
        &self,
        model_route_id: String,
    ) -> Result<Vec<FfiParameterSpec>, FfiError> {
        self.core
            .effective_parameter_specs(&ModelRouteId::from(model_route_id))
            .map(|specs| specs.into_iter().map(map_parameter_spec).collect())
            .map_err(Into::into)
    }

    pub fn upsert_user_capability_override(
        &self,
        draft: FfiCapabilityOverrideDraft,
    ) -> Result<FfiCapabilityObservation, FfiError> {
        self.core
            .upsert_user_capability_override(unmap_capability_override(draft)?)
            .map(map_capability_observation)
            .map_err(Into::into)
    }

    pub fn delete_user_capability_override(
        &self,
        model_route_id: String,
        observation_id: String,
    ) -> Result<(), FfiError> {
        self.core
            .delete_user_capability_override(
                &ModelRouteId::from(model_route_id),
                &ObservationId::from(observation_id),
            )
            .map_err(Into::into)
    }

    pub fn list_generation_presets(
        &self,
        model_route_id: String,
    ) -> Result<Vec<FfiGenerationPreset>, FfiError> {
        self.core
            .list_generation_presets(&ModelRouteId::from(model_route_id))
            .map(|presets| presets.into_iter().map(map_generation_preset).collect())
            .map_err(Into::into)
    }

    pub fn upsert_generation_preset(
        &self,
        preset: FfiGenerationPreset,
    ) -> Result<FfiGenerationPreset, FfiError> {
        let preset = unmap_generation_preset(preset)?;
        self.core
            .upsert_generation_preset(preset)
            .map(map_generation_preset)
            .map_err(Into::into)
    }

    pub fn validate_generation_preset(
        &self,
        model_route_id: String,
        generation_preset_id: String,
    ) -> Result<(), FfiError> {
        self.core
            .validate_generation_preset(
                &ModelRouteId::from(model_route_id),
                &GenerationPresetId::from(generation_preset_id),
            )
            .map_err(Into::into)
    }

    pub fn validate_generation_preset_candidate(
        &self,
        preset: FfiGenerationPreset,
    ) -> Result<(), FfiError> {
        let preset = unmap_generation_preset(preset)?;
        self.core
            .validate_generation_preset_candidate(&preset)
            .map_err(Into::into)
    }

    pub fn render_reasoning_control_for_preset(
        &self,
        preset: FfiGenerationPreset,
    ) -> Result<FfiReasoningControl, FfiError> {
        let preset = unmap_generation_preset(preset)?;
        self.core
            .render_reasoning_control_for_preset(&preset)
            .map(map_reasoning_control)
            .map_err(Into::into)
    }

    pub fn render_prompt_cache_control_for_preset(
        &self,
        preset: FfiGenerationPreset,
    ) -> Result<FfiPromptCacheControl, FfiError> {
        let preset = unmap_generation_preset(preset)?;
        self.core
            .render_prompt_cache_control_for_preset(&preset)
            .map(map_prompt_cache_control)
            .map_err(Into::into)
    }

    pub fn preview_provider_request(
        &self,
        model_route_id: String,
        generation_preset_id: String,
    ) -> Result<FfiRequestPreview, FfiError> {
        self.core
            .preview_provider_request(
                &ModelRouteId::from(model_route_id),
                &GenerationPresetId::from(generation_preset_id),
            )
            .map(map_request_preview)
            .map_err(Into::into)
    }

    pub fn preview_provider_request_candidate(
        &self,
        preset: FfiGenerationPreset,
    ) -> Result<FfiRequestPreview, FfiError> {
        let preset = unmap_generation_preset(preset)?;
        self.core
            .preview_provider_request_candidate(&preset)
            .map(map_request_preview)
            .map_err(Into::into)
    }

    pub fn delete_generation_preset(&self, generation_preset_id: String) -> Result<(), FfiError> {
        self.core
            .delete_generation_preset(&GenerationPresetId::from(generation_preset_id))
            .map_err(Into::into)
    }

    pub fn select_generation_target(
        &self,
        target: Option<FfiGenerationTarget>,
    ) -> Result<FfiAppSettings, FfiError> {
        self.core
            .select_generation_target(target.map(unmap_generation_target))
            .map(map_settings)
            .map_err(Into::into)
    }

    pub fn get_settings(&self) -> Result<FfiAppSettings, FfiError> {
        self.core
            .get_settings()
            .map(map_settings)
            .map_err(Into::into)
    }

    pub fn update_settings(&self, settings: FfiAppSettings) -> Result<FfiAppSettings, FfiError> {
        let settings = unmap_settings(settings);
        self.core.update_settings(&settings)?;
        self.core
            .get_settings()
            .map(map_settings)
            .map_err(Into::into)
    }

    pub fn database_stats(&self) -> Result<FfiDatabaseStats, FfiError> {
        self.core
            .database_stats()
            .map(map_database_stats)
            .map_err(Into::into)
    }
}

fn map_character(character: Character) -> FfiCharacter {
    FfiCharacter {
        id: character.id,
        name: character.name,
        description: character.description,
        source_hash: character.source_hash,
        avatar_asset_hash: character.avatar_asset_hash,
        created_at: character.created_at.to_rfc3339(),
    }
}

fn map_inspection(inspection: ImportInspection) -> FfiImportInspection {
    let is_allowed = inspection.is_allowed();
    FfiImportInspection {
        id: inspection.id.0,
        content_kind: map_content_kind(inspection.kind).to_owned(),
        display_name: inspection.display_name,
        description: inspection.description,
        representative_image: inspection
            .representative_image
            .map(|image| FfiImportImagePreview {
                logical_asset_id: image.logical_asset_id,
                media_type: image.media_type,
                size_bytes: image.size_bytes,
            }),
        source_sha256: inspection.source_sha256,
        source_size: inspection.source_size,
        estimated_stored_size: inspection.estimated_stored_size,
        asset_count: inspection.asset_count,
        warnings: inspection
            .warnings
            .into_iter()
            .map(|warning| FfiImportWarning {
                code: warning.code,
                message: warning.message,
            })
            .collect(),
        blocked_reasons: inspection.blocked_reasons,
        unsupported_optional_fields: inspection.unsupported_optional_fields,
        is_allowed,
    }
}

const fn map_content_kind(kind: ContentKind) -> &'static str {
    match kind {
        ContentKind::CharacterCardV3 => "character_card_v3",
        ContentKind::CharxPackage => "charx_package",
    }
}

fn map_conversation(conversation: Conversation) -> FfiConversation {
    FfiConversation {
        id: conversation.id.0,
        character_id: conversation.character_id,
        title: conversation.title,
        created_at: conversation.created_at.to_rfc3339(),
        updated_at: conversation.updated_at.to_rfc3339(),
    }
}

fn map_conversation_branch(branch: ConversationBranch) -> FfiConversationBranch {
    FfiConversationBranch {
        id: branch.id.0,
        conversation_id: branch.conversation_id.0,
        title: branch.title,
        fork_message_id: branch.fork_message_id.map(|id| id.0),
        head_message_id: branch.head_message_id.map(|id| id.0),
        created_at: branch.created_at.to_rfc3339(),
        updated_at: branch.updated_at.to_rfc3339(),
    }
}

fn map_message_action_generation(action: MessageActionGeneration) -> FfiMessageActionGeneration {
    FfiMessageActionGeneration {
        branch: map_conversation_branch(action.branch),
        generation_id: action.generation_id.0,
    }
}

fn map_conversation_state(state: ConversationState) -> FfiConversationState {
    FfiConversationState {
        conversation_id: state.conversation_id.0,
        active_branch_id: state.active_branch_id.0,
        selected_mode: map_conversation_mode(state.selected_mode).to_owned(),
        updated_at: state.updated_at.to_rfc3339(),
    }
}

const fn map_conversation_mode(mode: ConversationMode) -> &'static str {
    match mode {
        ConversationMode::Chat => "chat",
        ConversationMode::Story => "story",
    }
}

fn parse_conversation_mode(mode: &str) -> Result<ConversationMode, FfiError> {
    match mode {
        "chat" => Ok(ConversationMode::Chat),
        "story" => Ok(ConversationMode::Story),
        _ => Err(CoreError::invalid("conversation mode must be `chat` or `story`").into()),
    }
}

fn map_message(message: Message) -> FfiMessage {
    FfiMessage {
        id: message.id.0,
        conversation_id: message.conversation_id.0,
        parent_id: message.parent_id.map(|id| id.0),
        role: map_message_role(message.role).to_owned(),
        content: message.content,
        status: map_message_status(message.status).to_owned(),
        generation_id: message.generation_id.map(|id| id.0),
        created_at: message.created_at.to_rfc3339(),
    }
}

const fn map_message_role(role: MessageRole) -> &'static str {
    match role {
        MessageRole::System => "system",
        MessageRole::User => "user",
        MessageRole::Assistant => "assistant",
    }
}

const fn map_message_status(status: MessageStatus) -> &'static str {
    match status {
        MessageStatus::Pending => "pending",
        MessageStatus::Complete => "complete",
        MessageStatus::Cancelled => "cancelled",
        MessageStatus::Failed => "failed",
    }
}

fn map_provider_profile(profile: ProviderProfile) -> FfiProviderProfile {
    FfiProviderProfile {
        id: profile.id,
        display_name: profile.display_name,
        base_url: profile.base_url,
        model: profile.model,
        timeout_seconds: profile.timeout_seconds,
    }
}

fn unmap_provider_profile(profile: FfiProviderProfile) -> ProviderProfile {
    ProviderProfile {
        id: profile.id,
        display_name: profile.display_name,
        base_url: profile.base_url,
        model: profile.model,
        timeout_seconds: profile.timeout_seconds,
    }
}

fn validate_discovery_list_limit(limit: u32) -> Result<(), CoreError> {
    if limit == 0 || limit > 256 {
        return Err(CoreError::invalid(
            "provider discovery limit must be between 1 and 256",
        ));
    }
    Ok(())
}

fn parse_discovery_action_id(value: String) -> Result<DiscoveryActionId, FfiError> {
    DiscoveryActionId::parse(value)
        .map_err(|_| CoreError::invalid("discovery action identifier is invalid").into())
}

fn parse_discovery_approval_id(value: String) -> Result<DiscoveryApprovalId, FfiError> {
    DiscoveryApprovalId::parse(value)
        .map_err(|_| CoreError::invalid("discovery approval identifier is invalid").into())
}

fn parse_discovery_commit_attempt_id(value: String) -> Result<DiscoveryCommitAttemptId, FfiError> {
    DiscoveryCommitAttemptId::parse(value)
        .map_err(|_| CoreError::invalid("discovery commit attempt identifier is invalid").into())
}

fn parse_discovery_event_id(value: String) -> Result<DiscoveryEventId, FfiError> {
    DiscoveryEventId::parse(value)
        .map_err(|_| CoreError::invalid("discovery event identifier is invalid").into())
}

fn parse_http_url(value: String, field: &str) -> Result<HttpUrl, FfiError> {
    HttpUrl::parse(&value)
        .map_err(|_| CoreError::invalid(format!("{field} is not an allowed HTTP URL")).into())
}

fn unmap_local_network_approval(
    approval: FfiProviderLocalNetworkApproval,
) -> Result<ProviderLocalNetworkApproval, FfiError> {
    let origin = CanonicalOrigin::parse(&approval.origin)
        .map_err(|error| CoreError::invalid(format!("invalid local network origin: {error}")))?;
    let addresses = approval
        .addresses
        .into_iter()
        .map(|address| {
            address.parse::<IpAddr>().map_err(|_| {
                CoreError::invalid("local network approval contains an invalid IP address").into()
            })
        })
        .collect::<Result<Vec<_>, FfiError>>()?;
    Ok(ProviderLocalNetworkApproval { origin, addresses })
}

fn map_local_network_approval(
    approval: ProviderLocalNetworkApproval,
) -> FfiProviderLocalNetworkApproval {
    FfiProviderLocalNetworkApproval {
        origin: approval.origin.as_str().to_owned(),
        addresses: approval
            .addresses
            .into_iter()
            .map(|address| address.to_string())
            .collect(),
    }
}

fn unmap_provider_discovery_connection_options(
    options: FfiProviderDiscoveryConnectionOptions,
) -> Result<ProviderDiscoveryConnectionOptions, FfiError> {
    let api_base_path = options
        .api_base_path
        .as_deref()
        .map(EndpointPath::parse)
        .transpose()
        .map_err(|error| {
            CoreError::invalid(format!("invalid provider discovery API base path: {error}"))
        })?;
    let options = ProviderDiscoveryConnectionOptions {
        values: options
            .values
            .into_iter()
            .map(unmap_connection_config_entry)
            .collect(),
        api_base_path,
        timeout_seconds: options.timeout_seconds,
        network_mode: unmap_provider_network_mode(options.network_mode),
        local_network_approval: options
            .local_network_approval
            .map(unmap_local_network_approval)
            .transpose()?,
    };
    options
        .validate()
        .map_err(|error| CoreError::invalid(format!("invalid connection options: {error}")))?;
    Ok(options)
}

fn validate_provider_network_policy(
    policy: FfiProviderNetworkPolicy,
) -> Result<ProviderDiscoveryConnectionOptions, FfiError> {
    let options = ProviderDiscoveryConnectionOptions {
        network_mode: unmap_provider_network_mode(policy.network_mode),
        local_network_approval: policy
            .local_network_approval
            .map(unmap_local_network_approval)
            .transpose()?,
        ..ProviderDiscoveryConnectionOptions::default()
    };
    options
        .validate()
        .map_err(|error| CoreError::invalid(format!("invalid network policy: {error}")))?;
    Ok(options)
}

fn default_site_url_for_template(core: &Core, template_id: &str) -> Result<HttpUrl, FfiError> {
    let view = core
        .list_provider_template_views()?
        .into_iter()
        .find(|view| view.template.id.as_str() == template_id)
        .ok_or_else(|| {
            CoreError::new(
                lorepia_core::CoreErrorCode::NotFound,
                "provider template was not found",
                false,
            )
        })?;
    let origin = view
        .template
        .default_manifest
        .default_api_origin
        .ok_or_else(|| CoreError::invalid("known provider template has no default API origin"))?;
    parse_http_url(
        format!("{}/", origin.as_str().trim_end_matches('/')),
        "site_url",
    )
}

fn unmap_provider_discovery_input(
    core: &Core,
    input: FfiProviderDiscoveryInput,
    known_template_id: Option<&str>,
) -> Result<SanitizedDiscoveryInput, FfiError> {
    let connection_id = ProviderConnectionId::from(input.connection_id);
    let connection_options = unmap_provider_discovery_connection_options(input.connection_options)?;
    let site_url = match input.site_url {
        Some(site_url) => parse_http_url(site_url, "site_url")?,
        None => match known_template_id {
            Some(template_id) => default_site_url_for_template(core, template_id)?,
            None => return Err(CoreError::invalid("site discovery requires site_url").into()),
        },
    };
    let docs_url = input
        .docs_url
        .map(|url| parse_http_url(url, "docs_url"))
        .transpose()?;
    Ok(SanitizedDiscoveryInput {
        credential_ref: input
            .credential_slot_ready
            .then(|| CredentialRef(connection_id.as_str().to_owned())),
        connection_id,
        display_name: input.display_name,
        site_url,
        docs_url,
        preferred_assistant: input
            .preferred_assistant_model_route_id
            .map(ModelRouteId::from),
        connection_options,
        supplied_evidence_ids: input
            .supplied_evidence_ids
            .into_iter()
            .map(EvidenceId::from)
            .collect(),
    })
}

fn unmap_provider_discovery_curl_input(
    input: FfiProviderDiscoveryInput,
) -> Result<ProviderDiscoveryCurlInput, FfiError> {
    if input.site_url.is_some() {
        return Err(CoreError::invalid(
            "cURL discovery derives site_url and must not receive a separate site_url",
        )
        .into());
    }
    let docs_url = input
        .docs_url
        .map(|url| parse_http_url(url, "docs_url"))
        .transpose()?;
    let connection_id = ProviderConnectionId::from(input.connection_id);
    let connection_options = unmap_provider_discovery_connection_options(input.connection_options)?;
    Ok(ProviderDiscoveryCurlInput {
        credential_ref: input
            .credential_slot_ready
            .then(|| CredentialRef(connection_id.as_str().to_owned())),
        connection_id,
        display_name: input.display_name,
        docs_url,
        preferred_assistant: input
            .preferred_assistant_model_route_id
            .map(ModelRouteId::from),
        connection_options,
        supplied_evidence_ids: input
            .supplied_evidence_ids
            .into_iter()
            .map(EvidenceId::from)
            .collect(),
    })
}

fn unmap_discovery_unknown_outcome_resolution(
    resolution: FfiDiscoveryUnknownOutcomeResolution,
) -> DiscoveryUnknownOutcomeResolution {
    match resolution {
        FfiDiscoveryUnknownOutcomeResolution::ConfirmedNoEffect => {
            DiscoveryUnknownOutcomeResolution::ConfirmedNoEffect
        }
        FfiDiscoveryUnknownOutcomeResolution::ConfirmedCommitCompleted { connection_id } => {
            DiscoveryUnknownOutcomeResolution::ConfirmedCommitCompleted {
                connection_id: ProviderConnectionId::from(connection_id),
            }
        }
        FfiDiscoveryUnknownOutcomeResolution::ConfirmedCompensated => {
            DiscoveryUnknownOutcomeResolution::ConfirmedCompensated
        }
        FfiDiscoveryUnknownOutcomeResolution::ManuallyReconciledAsFailed => {
            DiscoveryUnknownOutcomeResolution::ManuallyReconciledAsFailed
        }
    }
}

fn map_discovery_unknown_outcome_resolution(
    resolution: DiscoveryUnknownOutcomeResolution,
) -> FfiDiscoveryUnknownOutcomeResolution {
    match resolution {
        DiscoveryUnknownOutcomeResolution::ConfirmedNoEffect => {
            FfiDiscoveryUnknownOutcomeResolution::ConfirmedNoEffect
        }
        DiscoveryUnknownOutcomeResolution::ConfirmedCommitCompleted { connection_id } => {
            FfiDiscoveryUnknownOutcomeResolution::ConfirmedCommitCompleted {
                connection_id: connection_id.into_inner(),
            }
        }
        DiscoveryUnknownOutcomeResolution::ConfirmedCompensated => {
            FfiDiscoveryUnknownOutcomeResolution::ConfirmedCompensated
        }
        DiscoveryUnknownOutcomeResolution::ManuallyReconciledAsFailed => {
            FfiDiscoveryUnknownOutcomeResolution::ManuallyReconciledAsFailed
        }
    }
}

fn unmap_provider_discovery_action(
    action: FfiProviderDiscoveryAction,
) -> Result<ProviderDiscoveryAction, FfiError> {
    Ok(match action {
        FfiProviderDiscoveryAction::SelectTemplate { candidate_id } => {
            ProviderDiscoveryAction::SelectTemplate {
                candidate_id: lorepia_core::DiscoveryCandidateId::parse(candidate_id)
                    .map_err(|_| CoreError::invalid("discovery candidate identifier is invalid"))?,
            }
        }
        FfiProviderDiscoveryAction::ContinueWithoutTemplate => {
            ProviderDiscoveryAction::ContinueWithoutTemplate
        }
        FfiProviderDiscoveryAction::SupplyMoreEvidence { evidence_ids } => {
            ProviderDiscoveryAction::SupplyMoreEvidence {
                evidence_ids: evidence_ids.into_iter().map(EvidenceId::from).collect(),
            }
        }
        FfiProviderDiscoveryAction::RequestAssistant => ProviderDiscoveryAction::RequestAssistant,
        FfiProviderDiscoveryAction::ApproveAssistant {
            approval_id,
            approval_grant_sha256,
        } => ProviderDiscoveryAction::ApproveAssistant {
            approval_id: parse_discovery_approval_id(approval_id)?,
            approval_grant_sha256,
        },
        FfiProviderDiscoveryAction::DeclineAssistant => ProviderDiscoveryAction::DeclineAssistant,
        FfiProviderDiscoveryAction::ApproveCredentialOrigin { approval_id } => {
            ProviderDiscoveryAction::ApproveCredentialOrigin {
                approval_id: parse_discovery_approval_id(approval_id)?,
            }
        }
        FfiProviderDiscoveryAction::ApproveProbes {
            approval_id,
            approval_grant_sha256,
        } => ProviderDiscoveryAction::ApproveProbes {
            approval_id: parse_discovery_approval_id(approval_id)?,
            approval_grant_sha256,
        },
        FfiProviderDiscoveryAction::SkipProbes => ProviderDiscoveryAction::SkipProbes,
        FfiProviderDiscoveryAction::ApproveReview {
            approval_id,
            commit_attempt_id,
            commit_plan_sha256,
            graph_sha256,
        } => ProviderDiscoveryAction::ApproveReview {
            approval_id: parse_discovery_approval_id(approval_id)?,
            commit_attempt_id: parse_discovery_commit_attempt_id(commit_attempt_id)?,
            commit_plan_sha256,
            graph_sha256,
        },
        FfiProviderDiscoveryAction::ResumeCompensation => {
            ProviderDiscoveryAction::ResumeCompensation
        }
        FfiProviderDiscoveryAction::RestartInterrupted => {
            ProviderDiscoveryAction::RestartInterrupted
        }
        FfiProviderDiscoveryAction::ResolveUnknownOutcome {
            approval_id,
            resolution,
        } => ProviderDiscoveryAction::ResolveUnknownOutcome {
            approval_id: parse_discovery_approval_id(approval_id)?,
            resolution: unmap_discovery_unknown_outcome_resolution(resolution),
        },
        FfiProviderDiscoveryAction::Cancel => ProviderDiscoveryAction::Cancel,
    })
}

fn map_provider_discovery_action(
    action: ProviderDiscoveryAction,
) -> Result<FfiProviderDiscoveryAction, CoreError> {
    match action {
        ProviderDiscoveryAction::SelectTemplate { candidate_id } => {
            Ok(FfiProviderDiscoveryAction::SelectTemplate {
                candidate_id: candidate_id.as_str().to_owned(),
            })
        }
        ProviderDiscoveryAction::ContinueWithoutTemplate => {
            Ok(FfiProviderDiscoveryAction::ContinueWithoutTemplate)
        }
        ProviderDiscoveryAction::SupplyMoreEvidence { evidence_ids } => {
            Ok(FfiProviderDiscoveryAction::SupplyMoreEvidence {
                evidence_ids: evidence_ids
                    .into_iter()
                    .map(EvidenceId::into_inner)
                    .collect(),
            })
        }
        ProviderDiscoveryAction::RequestAssistant => {
            Ok(FfiProviderDiscoveryAction::RequestAssistant)
        }
        ProviderDiscoveryAction::ApproveAssistant {
            approval_id,
            approval_grant_sha256,
        } => Ok(FfiProviderDiscoveryAction::ApproveAssistant {
            approval_id: approval_id.as_str().to_owned(),
            approval_grant_sha256,
        }),
        ProviderDiscoveryAction::DeclineAssistant => {
            Ok(FfiProviderDiscoveryAction::DeclineAssistant)
        }
        ProviderDiscoveryAction::ApproveCredentialOrigin { approval_id } => {
            Ok(FfiProviderDiscoveryAction::ApproveCredentialOrigin {
                approval_id: approval_id.as_str().to_owned(),
            })
        }
        ProviderDiscoveryAction::ApproveProbes {
            approval_id,
            approval_grant_sha256,
        } => Ok(FfiProviderDiscoveryAction::ApproveProbes {
            approval_id: approval_id.as_str().to_owned(),
            approval_grant_sha256,
        }),
        ProviderDiscoveryAction::SkipProbes => Ok(FfiProviderDiscoveryAction::SkipProbes),
        ProviderDiscoveryAction::ApproveReview {
            approval_id,
            commit_attempt_id,
            commit_plan_sha256,
            graph_sha256,
        } => Ok(FfiProviderDiscoveryAction::ApproveReview {
            approval_id: approval_id.as_str().to_owned(),
            commit_attempt_id: commit_attempt_id.as_str().to_owned(),
            commit_plan_sha256,
            graph_sha256,
        }),
        ProviderDiscoveryAction::ResumeCompensation => {
            Ok(FfiProviderDiscoveryAction::ResumeCompensation)
        }
        ProviderDiscoveryAction::RestartInterrupted => {
            Ok(FfiProviderDiscoveryAction::RestartInterrupted)
        }
        ProviderDiscoveryAction::ResolveUnknownOutcome {
            approval_id,
            resolution,
        } => Ok(FfiProviderDiscoveryAction::ResolveUnknownOutcome {
            approval_id: approval_id.as_str().to_owned(),
            resolution: map_discovery_unknown_outcome_resolution(resolution),
        }),
        ProviderDiscoveryAction::Cancel => Ok(FfiProviderDiscoveryAction::Cancel),
        _ => Err(CoreError::invalid(
            "internal discovery action has no public binding representation",
        )),
    }
}

fn map_provider_discovery_action_envelope(
    envelope: DiscoveryActionEnvelope,
) -> FfiProviderDiscoveryActionEnvelope {
    let action = map_provider_discovery_action(envelope.action)
        .expect("Rust-prepared public discovery action must map to its binding form");
    FfiProviderDiscoveryActionEnvelope {
        action_id: envelope.id.as_str().to_owned(),
        expected_revision: envelope.expected_revision,
        request_sha256: envelope.request_sha256,
        action,
    }
}

fn unmap_provider_discovery_action_envelope(
    envelope: FfiProviderDiscoveryActionEnvelope,
) -> Result<DiscoveryActionEnvelope, FfiError> {
    Ok(DiscoveryActionEnvelope {
        id: parse_discovery_action_id(envelope.action_id)?,
        expected_revision: envelope.expected_revision,
        request_sha256: envelope.request_sha256,
        action: unmap_provider_discovery_action(envelope.action)?,
    })
}

fn map_provider_curl_inspection(
    inspection: lorepia_core::ProviderCurlInspection,
    credential_handoff_id: Option<String>,
) -> FfiProviderCurlInspection {
    let evidence = inspection.evidence();
    let auth_binding_hint = map_curl_auth_binding_hint(inspection.auth_hints());
    FfiProviderCurlInspection {
        inspection_schema_version: 1,
        sanitized_site_url: inspection.site_url().as_str().to_owned(),
        api_origin: inspection.origin().as_str().to_owned(),
        method: match evidence.method {
            HttpMethod::Get => "GET",
            HttpMethod::Post => "POST",
        }
        .to_owned(),
        path: evidence.path.as_str().to_owned(),
        header_names: evidence
            .header_names
            .iter()
            .map(|header| header.as_str().to_owned())
            .collect(),
        auth_binding_hint,
        api_family_hint: evidence
            .api_family_candidates
            .first()
            .copied()
            .map(|family| api_family_name(family).to_owned()),
        model_hint: evidence.model_hint.clone(),
        stream_hint: evidence.stream_hint,
        redacted_curl: inspection.redacted_curl().to_owned(),
        credential_handoff_id,
    }
}

fn map_curl_auth_binding_hint(hints: &[CurlAuthHint]) -> Option<FfiAuthBinding> {
    let mut selected = None;
    for hint in hints {
        let candidate = match hint {
            CurlAuthHint::BearerHeader | CurlAuthHint::AuthorizationHeader => {
                FfiAuthBinding::BearerHeader
            }
            CurlAuthHint::ApiKeyHeader { header_name } => FfiAuthBinding::HeaderApiKey {
                header_name: header_name.as_str().to_owned(),
            },
            CurlAuthHint::CookieHeader { .. } | CurlAuthHint::ApiKeyQuery { .. } => continue,
        };
        if selected
            .as_ref()
            .is_some_and(|current| current != &candidate)
        {
            return None;
        }
        selected = Some(candidate);
    }
    selected
}

const fn map_discovery_state(state: DiscoveryState) -> FfiDiscoveryState {
    match state {
        DiscoveryState::Draft => FfiDiscoveryState::Draft,
        DiscoveryState::ResolvingKnownProvider => FfiDiscoveryState::ResolvingKnownProvider,
        DiscoveryState::AwaitingTemplateSelection => FfiDiscoveryState::AwaitingTemplateSelection,
        DiscoveryState::FetchingDocuments => FfiDiscoveryState::FetchingDocuments,
        DiscoveryState::ExtractingEvidence => FfiDiscoveryState::ExtractingEvidence,
        DiscoveryState::AwaitingMoreEvidence => FfiDiscoveryState::AwaitingMoreEvidence,
        DiscoveryState::AwaitingAssistantConsent => FfiDiscoveryState::AwaitingAssistantConsent,
        DiscoveryState::BuildingDeterministicManifestDraft => {
            FfiDiscoveryState::BuildingDeterministicManifestDraft
        }
        DiscoveryState::BuildingAssistantManifestDraft => {
            FfiDiscoveryState::BuildingAssistantManifestDraft
        }
        DiscoveryState::ValidatingManifest => FfiDiscoveryState::ValidatingManifest,
        DiscoveryState::AwaitingCredentialOriginApproval => {
            FfiDiscoveryState::AwaitingCredentialOriginApproval
        }
        DiscoveryState::ListingModels => FfiDiscoveryState::ListingModels,
        DiscoveryState::AwaitingProbeConsent => FfiDiscoveryState::AwaitingProbeConsent,
        DiscoveryState::ProbingCapabilities => FfiDiscoveryState::ProbingCapabilities,
        DiscoveryState::AwaitingReview => FfiDiscoveryState::AwaitingReview,
        DiscoveryState::Committing => FfiDiscoveryState::Committing,
        DiscoveryState::Compensating => FfiDiscoveryState::Compensating,
        DiscoveryState::Ready => FfiDiscoveryState::Ready,
        DiscoveryState::Failed => FfiDiscoveryState::Failed,
        DiscoveryState::Cancelled => FfiDiscoveryState::Cancelled,
        DiscoveryState::Interrupted => FfiDiscoveryState::Interrupted,
        DiscoveryState::UnknownOutcome => FfiDiscoveryState::UnknownOutcome,
    }
}

const fn map_discovery_operation(operation: DiscoveryOperationKind) -> FfiDiscoveryOperationKind {
    match operation {
        DiscoveryOperationKind::ResolveKnownProvider => {
            FfiDiscoveryOperationKind::ResolveKnownProvider
        }
        DiscoveryOperationKind::FetchDocuments => FfiDiscoveryOperationKind::FetchDocuments,
        DiscoveryOperationKind::ExtractEvidence => FfiDiscoveryOperationKind::ExtractEvidence,
        DiscoveryOperationKind::BuildDeterministicManifestDraft => {
            FfiDiscoveryOperationKind::BuildDeterministicManifestDraft
        }
        DiscoveryOperationKind::BuildAssistantManifestDraft => {
            FfiDiscoveryOperationKind::BuildAssistantManifestDraft
        }
        DiscoveryOperationKind::ValidateManifest => FfiDiscoveryOperationKind::ValidateManifest,
        DiscoveryOperationKind::ListModels => FfiDiscoveryOperationKind::ListModels,
        DiscoveryOperationKind::ProbeCapabilities => FfiDiscoveryOperationKind::ProbeCapabilities,
        DiscoveryOperationKind::AtomicCommit => FfiDiscoveryOperationKind::AtomicCommit,
        DiscoveryOperationKind::Compensation => FfiDiscoveryOperationKind::Compensation,
    }
}

fn map_discovery_failure(failure: DiscoveryFailure) -> FfiDiscoveryFailure {
    FfiDiscoveryFailure {
        code: failure.code,
        message_key: failure.message_key,
        recoverable: failure.recoverable,
    }
}

fn map_discovery_action_required(action: DiscoveryActionRequired) -> FfiDiscoveryActionRequired {
    match action {
        DiscoveryActionRequired::SelectTemplate => FfiDiscoveryActionRequired::SelectTemplate,
        DiscoveryActionRequired::SupplyMoreEvidence => {
            FfiDiscoveryActionRequired::SupplyMoreEvidence
        }
        DiscoveryActionRequired::ApproveAssistant => FfiDiscoveryActionRequired::ApproveAssistant,
        DiscoveryActionRequired::ApproveCredentialOrigin => {
            FfiDiscoveryActionRequired::ApproveCredentialOrigin
        }
        DiscoveryActionRequired::ApproveProbes => FfiDiscoveryActionRequired::ApproveProbes,
        DiscoveryActionRequired::Review => FfiDiscoveryActionRequired::Review,
        DiscoveryActionRequired::RestartInterrupted { operation } => {
            FfiDiscoveryActionRequired::RestartInterrupted {
                operation: map_discovery_operation(operation),
            }
        }
        DiscoveryActionRequired::ReconcileUnknownOutcome { operation } => {
            FfiDiscoveryActionRequired::ReconcileUnknownOutcome {
                operation: map_discovery_operation(operation),
            }
        }
    }
}

fn action_required_for_snapshot(
    snapshot: &DiscoverySessionSnapshot,
) -> Option<FfiDiscoveryActionRequired> {
    match snapshot.session.state {
        DiscoveryState::AwaitingTemplateSelection => {
            Some(FfiDiscoveryActionRequired::SelectTemplate)
        }
        DiscoveryState::AwaitingMoreEvidence => {
            Some(FfiDiscoveryActionRequired::SupplyMoreEvidence)
        }
        DiscoveryState::AwaitingAssistantConsent => {
            Some(FfiDiscoveryActionRequired::ApproveAssistant)
        }
        DiscoveryState::AwaitingCredentialOriginApproval => {
            Some(FfiDiscoveryActionRequired::ApproveCredentialOrigin)
        }
        DiscoveryState::AwaitingProbeConsent => Some(FfiDiscoveryActionRequired::ApproveProbes),
        DiscoveryState::AwaitingReview => Some(FfiDiscoveryActionRequired::Review),
        DiscoveryState::Interrupted => snapshot.session.recovery.as_ref().map(|recovery| {
            FfiDiscoveryActionRequired::RestartInterrupted {
                operation: map_discovery_operation(recovery.operation),
            }
        }),
        DiscoveryState::UnknownOutcome => snapshot.session.unknown_operation.map(|operation| {
            FfiDiscoveryActionRequired::ReconcileUnknownOutcome {
                operation: map_discovery_operation(operation),
            }
        }),
        _ => None,
    }
}

fn discovery_phase_rank(state: DiscoveryState) -> usize {
    match state {
        DiscoveryState::Draft
        | DiscoveryState::ResolvingKnownProvider
        | DiscoveryState::AwaitingTemplateSelection => 0,
        DiscoveryState::FetchingDocuments
        | DiscoveryState::ExtractingEvidence
        | DiscoveryState::AwaitingMoreEvidence => 1,
        DiscoveryState::AwaitingAssistantConsent
        | DiscoveryState::BuildingDeterministicManifestDraft
        | DiscoveryState::BuildingAssistantManifestDraft
        | DiscoveryState::ValidatingManifest
        | DiscoveryState::AwaitingCredentialOriginApproval => 2,
        DiscoveryState::ListingModels
        | DiscoveryState::AwaitingProbeConsent
        | DiscoveryState::ProbingCapabilities => 3,
        DiscoveryState::AwaitingReview => 4,
        DiscoveryState::Committing
        | DiscoveryState::Compensating
        | DiscoveryState::Ready
        | DiscoveryState::Failed
        | DiscoveryState::Cancelled
        | DiscoveryState::Interrupted
        | DiscoveryState::UnknownOutcome => 5,
    }
}

fn discovery_steps(state: DiscoveryState) -> Vec<FfiDiscoveryStep> {
    let current = discovery_phase_rank(state);
    [
        ("provider", "provider.discovery.step.provider"),
        ("evidence", "provider.discovery.step.evidence"),
        ("manifest", "provider.discovery.step.manifest"),
        ("models", "provider.discovery.step.models"),
        ("review", "provider.discovery.step.review"),
        ("commit", "provider.discovery.step.commit"),
    ]
    .into_iter()
    .enumerate()
    .map(|(index, (id, title_key))| FfiDiscoveryStep {
        id: id.to_owned(),
        title_key: title_key.to_owned(),
        state: if state == DiscoveryState::Ready || index < current {
            FfiDiscoveryStepState::Completed
        } else if index == current {
            FfiDiscoveryStepState::Current
        } else {
            FfiDiscoveryStepState::Pending
        },
    })
    .collect()
}

fn map_discovery_candidate(record: StoredDiscoveryCandidate) -> FfiDiscoveryCandidate {
    let candidate = record.candidate;
    let summary = match candidate.summary {
        DiscoveryCandidateSummary::ProviderTemplate {
            template_id,
            template_version,
        } => FfiDiscoveryCandidateSummary::ProviderTemplate {
            template_id: template_id.into_inner(),
            template_version,
        },
        DiscoveryCandidateSummary::ApiOrigin { origin } => {
            FfiDiscoveryCandidateSummary::ApiOrigin {
                origin: origin.as_str().to_owned(),
            }
        }
        DiscoveryCandidateSummary::OfficialDocument { content_sha256, .. } => {
            FfiDiscoveryCandidateSummary::OfficialDocument { content_sha256 }
        }
        DiscoveryCandidateSummary::ModelRoute { model_id } => {
            FfiDiscoveryCandidateSummary::ModelRoute { model_id }
        }
        DiscoveryCandidateSummary::ManifestDraft {
            schema_version,
            manifest_sha256,
        } => FfiDiscoveryCandidateSummary::ManifestDraft {
            schema_version,
            manifest_sha256,
        },
    };
    FfiDiscoveryCandidate {
        id: candidate.id.as_str().to_owned(),
        proposed_revision: record.proposed_revision,
        summary,
        evidence_ids: candidate
            .evidence_ids
            .into_iter()
            .map(EvidenceId::into_inner)
            .collect(),
        created_at: candidate.created_at.to_rfc3339(),
    }
}

const fn map_discovery_evidence_kind(kind: DiscoveryEvidenceKind) -> FfiDiscoveryEvidenceKind {
    match kind {
        DiscoveryEvidenceKind::HtmlDocument => FfiDiscoveryEvidenceKind::HtmlDocument,
        DiscoveryEvidenceKind::JsonDocument => FfiDiscoveryEvidenceKind::JsonDocument,
        DiscoveryEvidenceKind::YamlDocument => FfiDiscoveryEvidenceKind::YamlDocument,
        DiscoveryEvidenceKind::XmlDocument => FfiDiscoveryEvidenceKind::XmlDocument,
        DiscoveryEvidenceKind::PlainTextDocument => FfiDiscoveryEvidenceKind::PlainTextDocument,
        DiscoveryEvidenceKind::JsonSchema => FfiDiscoveryEvidenceKind::JsonSchema,
        DiscoveryEvidenceKind::OpenApi => FfiDiscoveryEvidenceKind::OpenApi,
    }
}

fn map_discovery_evidence(record: DiscoveryEvidenceRecord) -> FfiDiscoveryEvidence {
    FfiDiscoveryEvidence {
        id: record.id.into_inner(),
        kind: map_discovery_evidence_kind(record.kind),
        content_sha256: record.content_sha256,
        fetched_at: record.fetched_at.to_rfc3339(),
    }
}

fn map_discovery_approval_grant(grant: DiscoveryApprovalGrant) -> FfiDiscoveryApprovalGrant {
    match grant {
        DiscoveryApprovalGrant::TemplateSelection { candidate_id } => {
            FfiDiscoveryApprovalGrant::TemplateSelection {
                candidate_id: candidate_id.as_str().to_owned(),
            }
        }
        DiscoveryApprovalGrant::AssistantConsent {
            assistant_route_id,
            evidence_ids,
            allowed_document_origins,
            max_calls,
            max_input_tokens,
            max_output_tokens,
            max_tool_calls,
            max_retries,
            max_cost_micro_units,
        } => FfiDiscoveryApprovalGrant::AssistantConsent {
            assistant_model_route_id: assistant_route_id.into_inner(),
            evidence_ids: evidence_ids
                .into_iter()
                .map(EvidenceId::into_inner)
                .collect(),
            allowed_document_origins: allowed_document_origins
                .into_iter()
                .map(|origin| origin.as_str().to_owned())
                .collect(),
            max_calls,
            max_input_tokens,
            max_output_tokens,
            max_tool_calls,
            max_retries,
            max_cost_micro_units,
        },
        DiscoveryApprovalGrant::CredentialOrigin {
            origin,
            auth_binding,
            manifest_sha256,
        } => FfiDiscoveryApprovalGrant::CredentialOrigin {
            origin: origin.as_str().to_owned(),
            auth_binding: map_auth_binding(auth_binding),
            manifest_sha256,
        },
        DiscoveryApprovalGrant::CapabilityProbe {
            model_route_ids,
            budget,
        } => FfiDiscoveryApprovalGrant::CapabilityProbe {
            model_route_ids: model_route_ids
                .into_iter()
                .map(ModelRouteId::into_inner)
                .collect(),
            budget: FfiDiscoveryProbeBudget {
                max_requests: budget.max_requests,
                max_total_tokens_per_request: budget.max_total_tokens_per_request,
                max_output_tokens_per_request: budget.max_output_tokens_per_request,
                max_cost_micro_usd_per_request: budget.max_cost_micro_usd_per_request,
                max_duration_millis_per_request: budget.max_duration_millis_per_request,
                max_calls_per_request: budget.max_calls_per_request,
            },
        },
        DiscoveryApprovalGrant::Review {
            review_sha256,
            graph_sha256,
        } => FfiDiscoveryApprovalGrant::Review {
            review_sha256,
            graph_sha256,
        },
        DiscoveryApprovalGrant::UnknownOutcomeResolution {
            operation,
            resolution,
        } => FfiDiscoveryApprovalGrant::UnknownOutcomeResolution {
            operation: map_discovery_operation(operation),
            resolution: map_discovery_unknown_outcome_resolution(resolution),
        },
    }
}

fn map_discovery_approval(record: DiscoveryApprovalRecord) -> FfiDiscoveryApproval {
    FfiDiscoveryApproval {
        id: record.id.as_str().to_owned(),
        session_revision: record.session_revision,
        decision: match record.decision {
            DiscoveryApprovalDecision::Approved => FfiDiscoveryApprovalDecision::Approved,
            DiscoveryApprovalDecision::Rejected => FfiDiscoveryApprovalDecision::Rejected,
        },
        grant: map_discovery_approval_grant(record.grant),
        created_at: record.created_at.to_rfc3339(),
    }
}

fn map_discovery_review(review: DiscoveryReviewDiff) -> Result<FfiDiscoveryReview, CoreError> {
    Ok(FfiDiscoveryReview {
        sha256: review.sha256,
        graph_sha256: review.graph_sha256,
        changes: review
            .changes
            .into_iter()
            .map(|change| {
                let target_kind = match change.target_kind.as_str() {
                    "provider_template" => FfiDiscoveryReviewTargetKind::ProviderTemplate,
                    "provider_connection" => FfiDiscoveryReviewTargetKind::ProviderConnection,
                    "model_route" => FfiDiscoveryReviewTargetKind::ModelRoute,
                    _ => {
                        return Err(CoreError::new(
                            CoreErrorCode::StorageCorrupted,
                            "provider discovery review contains an unknown target kind",
                            false,
                        ));
                    }
                };
                Ok(FfiDiscoveryReviewChange {
                    kind: match change.kind {
                        DiscoveryReviewChangeKind::Add => FfiDiscoveryReviewChangeKind::Add,
                        DiscoveryReviewChangeKind::Update => FfiDiscoveryReviewChangeKind::Update,
                        DiscoveryReviewChangeKind::Deprecate => {
                            FfiDiscoveryReviewChangeKind::Deprecate
                        }
                        DiscoveryReviewChangeKind::PreserveMissing => {
                            FfiDiscoveryReviewChangeKind::PreserveMissing
                        }
                    },
                    target_kind,
                    target_id: change.target_id,
                    summary_key: change.summary_key,
                    evidence_ids: change
                        .evidence_ids
                        .into_iter()
                        .map(EvidenceId::into_inner)
                        .collect(),
                })
            })
            .collect::<Result<Vec<_>, CoreError>>()?,
        unresolved_question_count: review.unresolved_question_count,
        warning_count: review.warning_count,
    })
}

fn map_discovery_approval_proposal(
    proposal: ProviderDiscoveryApprovalProposal,
) -> FfiDiscoveryApprovalProposal {
    FfiDiscoveryApprovalProposal {
        approval_id: proposal.id.as_str().to_owned(),
        grant: map_discovery_approval_grant(proposal.grant),
        grant_sha256: proposal.grant_sha256,
    }
}

fn map_discovery_review_proposal(
    proposal: ProviderDiscoveryReviewProposal,
) -> Result<FfiDiscoveryReviewProposal, CoreError> {
    Ok(FfiDiscoveryReviewProposal {
        review: map_discovery_review(proposal.review)?,
        approval: map_discovery_approval_proposal(proposal.approval),
        commit_attempt_id: proposal.commit_attempt_id.as_str().to_owned(),
        commit_plan_sha256: proposal.commit_plan_sha256,
        request_preview: proposal.request_preview.map(map_request_preview),
    })
}

fn map_discovery_progress(progress: DiscoveryProgress) -> FfiDiscoveryProgress {
    FfiDiscoveryProgress {
        phase: match progress.phase {
            DiscoveryProgressPhase::ProviderCandidates => {
                FfiDiscoveryProgressPhase::ProviderCandidates
            }
            DiscoveryProgressPhase::Documents => FfiDiscoveryProgressPhase::Documents,
            DiscoveryProgressPhase::Evidence => FfiDiscoveryProgressPhase::Evidence,
            DiscoveryProgressPhase::Models => FfiDiscoveryProgressPhase::Models,
            DiscoveryProgressPhase::Probes => FfiDiscoveryProgressPhase::Probes,
        },
        completed: progress.completed,
        total: progress.total,
    }
}

const fn map_discovery_warning(warning: DiscoveryWarning) -> FfiDiscoveryWarning {
    match warning {
        DiscoveryWarning::AssistantDeclined => FfiDiscoveryWarning::AssistantDeclined,
        DiscoveryWarning::ProbesSkipped => FfiDiscoveryWarning::ProbesSkipped,
        DiscoveryWarning::CompensationRequired => FfiDiscoveryWarning::CompensationRequired,
        DiscoveryWarning::ExplicitRestartRequired => FfiDiscoveryWarning::ExplicitRestartRequired,
        DiscoveryWarning::UnknownExternalOutcome => FfiDiscoveryWarning::UnknownExternalOutcome,
    }
}

fn map_discovery_event(event: lorepia_core::ProviderDiscoveryEvent) -> FfiDiscoveryEvent {
    FfiDiscoveryEvent {
        event_version: event.version,
        event_id: event.id.as_str().to_owned(),
        session_id: event.session_id.into_inner(),
        sequence: event.sequence,
        session_revision: event.session_revision,
        state: map_discovery_state(event.state),
        progress: event.progress.map(map_discovery_progress),
        action_required: event.action_required.map(map_discovery_action_required),
        warning: event.warning.map(map_discovery_warning),
        action_id: event.action_id.as_str().to_owned(),
        failure: event.failure.map(map_discovery_failure),
    }
}

fn map_discovery_outbox_event(event: DiscoveryOutboxEvent) -> FfiDiscoveryOutboxEvent {
    FfiDiscoveryOutboxEvent {
        event: map_discovery_event(event.event),
        delivery_attempts: event.delivery_attempts,
        available_at: event.available_at.to_rfc3339(),
        created_at: event.created_at.to_rfc3339(),
    }
}

fn map_discovery_recovery_result(result: DiscoveryRecoveryResult) -> FfiDiscoveryRecoveryResult {
    FfiDiscoveryRecoveryResult {
        operation_id: result.operation_id.as_str().to_owned(),
        session_id: result.session_id.into_inner(),
        state: map_discovery_state(result.state),
        event: map_discovery_event(result.event),
    }
}

fn unmap_discovery_failure(failure: FfiDiscoveryFailure) -> DiscoveryFailure {
    DiscoveryFailure {
        code: failure.code,
        message_key: failure.message_key,
        recoverable: failure.recoverable,
    }
}

fn map_discovery_previous_selection(
    selection: DiscoveryPreviousSelection,
) -> FfiDiscoveryPreviousSelection {
    match selection {
        DiscoveryPreviousSelection::None => FfiDiscoveryPreviousSelection::None,
        DiscoveryPreviousSelection::RouteAndPreset {
            model_route_id,
            generation_preset_id,
        } => FfiDiscoveryPreviousSelection::RouteAndPreset {
            model_route_id: model_route_id.into_inner(),
            generation_preset_id: generation_preset_id.into_inner(),
        },
    }
}

fn map_discovery_compensation_target(
    target: DiscoveryCompensationTarget,
) -> FfiDiscoveryCompensationTarget {
    match target {
        DiscoveryCompensationTarget::RemoveCredentialSlot {
            connection_id,
            credential_ref,
        } => FfiDiscoveryCompensationTarget::RemoveCredentialSlot {
            connection_id: connection_id.into_inner(),
            credential_ref: credential_ref.as_str().to_owned(),
        },
        DiscoveryCompensationTarget::RemoveConnectionGraph { connection_id } => {
            FfiDiscoveryCompensationTarget::RemoveConnectionGraph {
                connection_id: connection_id.into_inner(),
            }
        }
        DiscoveryCompensationTarget::RestorePreviousSelection { previous_selection } => {
            FfiDiscoveryCompensationTarget::RestorePreviousSelection {
                previous_selection: map_discovery_previous_selection(previous_selection),
            }
        }
    }
}

const fn map_discovery_compensation_kind(
    kind: DiscoveryCompensationKind,
) -> FfiDiscoveryCompensationKind {
    match kind {
        DiscoveryCompensationKind::RemoveCredentialSlot => {
            FfiDiscoveryCompensationKind::RemoveCredentialSlot
        }
        DiscoveryCompensationKind::RemoveConnectionGraph => {
            FfiDiscoveryCompensationKind::RemoveConnectionGraph
        }
        DiscoveryCompensationKind::RestorePreviousSelection => {
            FfiDiscoveryCompensationKind::RestorePreviousSelection
        }
    }
}

const fn map_discovery_compensation_status(
    status: DiscoveryCompensationStatus,
) -> FfiDiscoveryCompensationStatus {
    match status {
        DiscoveryCompensationStatus::Pending => FfiDiscoveryCompensationStatus::Pending,
        DiscoveryCompensationStatus::InProgress => FfiDiscoveryCompensationStatus::InProgress,
        DiscoveryCompensationStatus::Completed => FfiDiscoveryCompensationStatus::Completed,
        DiscoveryCompensationStatus::Failed => FfiDiscoveryCompensationStatus::Failed,
        DiscoveryCompensationStatus::OutcomeUnknown => {
            FfiDiscoveryCompensationStatus::OutcomeUnknown
        }
    }
}

fn map_discovery_compensation_step(
    record: DiscoveryCompensationRecord,
) -> FfiDiscoveryCompensationStep {
    FfiDiscoveryCompensationStep {
        id: record.id,
        commit_attempt_id: record.commit_attempt_id.as_str().to_owned(),
        ordinal: record.ordinal,
        action_id: record.action_id.as_str().to_owned(),
        kind: map_discovery_compensation_kind(record.kind),
        target: map_discovery_compensation_target(record.step.target),
        status: map_discovery_compensation_status(record.status),
        attempt_count: record.attempt_count,
        last_failure: record.last_failure.map(map_discovery_failure),
        created_at: record.created_at.to_rfc3339(),
        updated_at: record.updated_at.to_rfc3339(),
        completed_at: record.completed_at.map(|time| time.to_rfc3339()),
    }
}

fn map_provider_discovery_snapshot(
    core: &Core,
    snapshot: DiscoverySessionSnapshot,
) -> Result<FfiProviderDiscoverySnapshot, CoreError> {
    let session_id = snapshot.session.id.clone();
    let assistant_resume_boundary = core
        .get_provider_discovery_assistant_resume_boundary(&session_id)?
        .map(map_discovery_assistant_resume_boundary);
    let candidates = core
        .list_provider_discovery_candidates(&session_id)?
        .into_iter()
        .map(map_discovery_candidate)
        .collect();
    let evidence = core
        .list_provider_discovery_evidence(&session_id)?
        .into_iter()
        .map(map_discovery_evidence)
        .collect();
    let approvals = core
        .list_provider_discovery_approvals(&session_id)?
        .into_iter()
        .map(map_discovery_approval)
        .collect();
    let approval_proposal = core
        .get_provider_discovery_approval_proposal(&session_id)?
        .map(map_discovery_approval_proposal);
    let review_proposal = core
        .get_provider_discovery_review_proposal(&session_id)?
        .map(map_discovery_review_proposal)
        .transpose()?;
    let state = snapshot.session.state;
    let pending_connection_id = snapshot.session.input.connection_id.as_str().to_owned();
    let pending_display_name = snapshot.session.input.display_name.clone();
    let connection_options = map_provider_discovery_connection_options(
        snapshot.session.input.connection_options.clone(),
    );
    let credential_slot_id = snapshot
        .session
        .input
        .credential_ref
        .as_ref()
        .map(|reference| reference.as_str().to_owned());
    let credential_slot_expected = credential_slot_id.is_some();
    Ok(FfiProviderDiscoverySnapshot {
        snapshot_schema_version: PROVIDER_DISCOVERY_SNAPSHOT_SCHEMA_VERSION,
        session_id: session_id.into_inner(),
        pending_connection_id,
        pending_display_name,
        connection_options,
        credential_slot_id,
        credential_slot_expected,
        revision: snapshot.session.revision,
        state: map_discovery_state(state),
        next_event_sequence: snapshot.session.next_event_sequence,
        steps: discovery_steps(state),
        action_required: action_required_for_snapshot(&snapshot),
        active_operation_id: snapshot
            .active_operation_id
            .map(|id| id.as_str().to_owned()),
        recovery_operation: snapshot
            .session
            .recovery
            .map(|recovery| map_discovery_operation(recovery.operation)),
        unknown_operation: snapshot
            .session
            .unknown_operation
            .map(map_discovery_operation),
        manifest_sha256: snapshot.session.manifest_sha256,
        commit_plan_sha256: snapshot.session.commit_plan_sha256,
        commit_attempt_id: snapshot
            .session
            .commit_attempt_id
            .map(|id| id.as_str().to_owned()),
        committed_connection_id: snapshot
            .session
            .committed_connection_id
            .map(ProviderConnectionId::into_inner),
        cancellation_pending: snapshot.session.cancellation_pending,
        failure: snapshot.session.failure.map(map_discovery_failure),
        candidates,
        evidence,
        approvals,
        review: snapshot.review.map(map_discovery_review).transpose()?,
        approval_proposal,
        review_proposal,
        assistant_resume_boundary,
        created_at: snapshot.created_at.to_rfc3339(),
        updated_at: snapshot.updated_at.to_rfc3339(),
    })
}

fn map_provider_discovery_connection_options(
    options: ProviderDiscoveryConnectionOptions,
) -> FfiProviderDiscoveryConnectionOptions {
    FfiProviderDiscoveryConnectionOptions {
        values: options
            .values
            .into_iter()
            .map(map_connection_config_entry)
            .collect(),
        api_base_path: options.api_base_path.map(|path| path.as_str().to_owned()),
        timeout_seconds: options.timeout_seconds,
        network_mode: map_provider_network_mode(options.network_mode),
        local_network_approval: options
            .local_network_approval
            .map(map_local_network_approval),
    }
}

const fn map_discovery_assistant_checkpoint(
    checkpoint: DiscoveryAssistantCheckpoint,
) -> FfiDiscoveryAssistantCheckpoint {
    match checkpoint {
        DiscoveryAssistantCheckpoint::Ready => FfiDiscoveryAssistantCheckpoint::Ready,
        DiscoveryAssistantCheckpoint::AwaitingAssistant => {
            FfiDiscoveryAssistantCheckpoint::AwaitingAssistant
        }
        DiscoveryAssistantCheckpoint::AwaitingToolResult => {
            FfiDiscoveryAssistantCheckpoint::AwaitingToolResult
        }
        DiscoveryAssistantCheckpoint::AwaitingMoreEvidence => {
            FfiDiscoveryAssistantCheckpoint::AwaitingMoreEvidence
        }
        DiscoveryAssistantCheckpoint::AwaitingRetryConsent => {
            FfiDiscoveryAssistantCheckpoint::AwaitingRetryConsent
        }
        DiscoveryAssistantCheckpoint::DraftReady => FfiDiscoveryAssistantCheckpoint::DraftReady,
    }
}

const fn map_discovery_assistant_resume_action(
    action: ProviderDiscoveryAssistantResumeAction,
) -> FfiDiscoveryAssistantResumeAction {
    match action {
        ProviderDiscoveryAssistantResumeAction::ApproveConsent => {
            FfiDiscoveryAssistantResumeAction::ApproveConsent
        }
        ProviderDiscoveryAssistantResumeAction::RunAssistant => {
            FfiDiscoveryAssistantResumeAction::RunAssistant
        }
        ProviderDiscoveryAssistantResumeAction::WaitForAssistantOutcome => {
            FfiDiscoveryAssistantResumeAction::WaitForAssistantOutcome
        }
        ProviderDiscoveryAssistantResumeAction::ResumeCoreHostAction => {
            FfiDiscoveryAssistantResumeAction::ResumeCoreHostAction
        }
        ProviderDiscoveryAssistantResumeAction::SupplyMoreEvidence => {
            FfiDiscoveryAssistantResumeAction::SupplyMoreEvidence
        }
        ProviderDiscoveryAssistantResumeAction::ApproveRetry => {
            FfiDiscoveryAssistantResumeAction::ApproveRetry
        }
        ProviderDiscoveryAssistantResumeAction::ReviewDraft => {
            FfiDiscoveryAssistantResumeAction::ReviewDraft
        }
        ProviderDiscoveryAssistantResumeAction::RestartInterrupted => {
            FfiDiscoveryAssistantResumeAction::RestartInterrupted
        }
        ProviderDiscoveryAssistantResumeAction::ResolveUnknownOutcome => {
            FfiDiscoveryAssistantResumeAction::ResolveUnknownOutcome
        }
    }
}

fn map_discovery_assistant_resume_boundary(
    boundary: ProviderDiscoveryAssistantResumeBoundary,
) -> FfiDiscoveryAssistantResumeBoundary {
    FfiDiscoveryAssistantResumeBoundary {
        checkpoint: boundary.checkpoint.map(map_discovery_assistant_checkpoint),
        action: map_discovery_assistant_resume_action(boundary.action),
        questions: boundary
            .questions
            .into_iter()
            .map(map_discovery_assistant_question)
            .collect(),
        draft_review: boundary
            .draft_review
            .map(map_discovery_assistant_draft_review),
    }
}

fn map_discovery_assistant_draft_field(field: DraftField) -> FfiDiscoveryAssistantDraftField {
    match field {
        DraftField::ApiFamily => FfiDiscoveryAssistantDraftField::ApiFamily,
        DraftField::DefaultApiOrigin => FfiDiscoveryAssistantDraftField::DefaultApiOrigin,
        DraftField::Auth => FfiDiscoveryAssistantDraftField::Auth,
        DraftField::GenerateEndpoint => FfiDiscoveryAssistantDraftField::GenerateEndpoint,
        DraftField::ModelsEndpoint => FfiDiscoveryAssistantDraftField::ModelsEndpoint,
        DraftField::ResponseDecoder => FfiDiscoveryAssistantDraftField::ResponseDecoder,
        DraftField::StreamingDecoder => FfiDiscoveryAssistantDraftField::StreamingDecoder,
        DraftField::Parameter(parameter_id) => FfiDiscoveryAssistantDraftField::Parameter {
            parameter_id: parameter_id.into_inner(),
        },
    }
}

fn map_discovery_assistant_question(question: UnresolvedQuestion) -> FfiDiscoveryAssistantQuestion {
    FfiDiscoveryAssistantQuestion {
        id: question.id,
        field: question.field.map(map_discovery_assistant_draft_field),
        question: question.question,
        required_evidence: question.required_evidence,
    }
}

fn map_discovery_assistant_evidence_mapping(
    mapping: FieldEvidenceMapping,
) -> FfiDiscoveryAssistantEvidenceMapping {
    FfiDiscoveryAssistantEvidenceMapping {
        field: map_discovery_assistant_draft_field(mapping.field),
        evidence_ids: mapping
            .evidence_ids
            .into_iter()
            .map(EvidenceId::into_inner)
            .collect(),
        explanation: mapping.explanation,
    }
}

const fn map_discovery_assistant_confidence_level(
    level: ConfidenceLevel,
) -> FfiDiscoveryAssistantConfidenceLevel {
    match level {
        ConfidenceLevel::Unknown => FfiDiscoveryAssistantConfidenceLevel::Unknown,
        ConfidenceLevel::Low => FfiDiscoveryAssistantConfidenceLevel::Low,
        ConfidenceLevel::Medium => FfiDiscoveryAssistantConfidenceLevel::Medium,
        ConfidenceLevel::High => FfiDiscoveryAssistantConfidenceLevel::High,
    }
}

fn map_discovery_assistant_field_confidence(
    confidence: FieldConfidence,
) -> FfiDiscoveryAssistantFieldConfidence {
    FfiDiscoveryAssistantFieldConfidence {
        field: map_discovery_assistant_draft_field(confidence.field),
        level: map_discovery_assistant_confidence_level(confidence.level),
        rationale: confidence.rationale,
    }
}

fn map_discovery_assistant_conflict(
    conflict: EvidenceConflict,
) -> FfiDiscoveryAssistantEvidenceConflict {
    let disposition = match conflict.disposition {
        ConflictDisposition::Unresolved => FfiDiscoveryAssistantConflictDisposition::Unresolved,
        ConflictDisposition::Resolved {
            selected_evidence_id,
            rationale,
        } => FfiDiscoveryAssistantConflictDisposition::Resolved {
            selected_evidence_id: selected_evidence_id.into_inner(),
            rationale,
        },
    };
    FfiDiscoveryAssistantEvidenceConflict {
        field: map_discovery_assistant_draft_field(conflict.field),
        evidence_ids: conflict
            .evidence_ids
            .into_iter()
            .map(EvidenceId::into_inner)
            .collect(),
        disposition,
    }
}

const fn map_discovery_assistant_api_family(family: ApiFamily) -> FfiDiscoveryAssistantApiFamily {
    match family {
        ApiFamily::OpenAiResponses => FfiDiscoveryAssistantApiFamily::OpenAiResponses,
        ApiFamily::OpenAiChatCompletions => FfiDiscoveryAssistantApiFamily::OpenAiChatCompletions,
        ApiFamily::AnthropicMessages => FfiDiscoveryAssistantApiFamily::AnthropicMessages,
        ApiFamily::GeminiGenerateContent => FfiDiscoveryAssistantApiFamily::GeminiGenerateContent,
        ApiFamily::OllamaNative => FfiDiscoveryAssistantApiFamily::OllamaNative,
    }
}

const fn map_discovery_assistant_manifest_source_kind(
    kind: lorepia_core::ManifestSourceKind,
) -> FfiDiscoveryAssistantManifestSourceKind {
    match kind {
        lorepia_core::ManifestSourceKind::OfficialSite => {
            FfiDiscoveryAssistantManifestSourceKind::OfficialSite
        }
        lorepia_core::ManifestSourceKind::OfficialDocumentation => {
            FfiDiscoveryAssistantManifestSourceKind::OfficialDocumentation
        }
        lorepia_core::ManifestSourceKind::SignedCatalog => {
            FfiDiscoveryAssistantManifestSourceKind::SignedCatalog
        }
        lorepia_core::ManifestSourceKind::UserSupplied => {
            FfiDiscoveryAssistantManifestSourceKind::UserSupplied
        }
    }
}

const fn map_discovery_assistant_http_method(
    method: HttpMethod,
) -> FfiDiscoveryAssistantHttpMethod {
    match method {
        HttpMethod::Get => FfiDiscoveryAssistantHttpMethod::Get,
        HttpMethod::Post => FfiDiscoveryAssistantHttpMethod::Post,
    }
}

const fn map_discovery_assistant_decoder(
    decoder: lorepia_core::DecoderId,
) -> FfiDiscoveryAssistantDecoder {
    match decoder {
        lorepia_core::DecoderId::OpenAiJsonV1 => FfiDiscoveryAssistantDecoder::OpenAiJsonV1,
        lorepia_core::DecoderId::OpenAiSseV1 => FfiDiscoveryAssistantDecoder::OpenAiSseV1,
        lorepia_core::DecoderId::AnthropicJsonV1 => FfiDiscoveryAssistantDecoder::AnthropicJsonV1,
        lorepia_core::DecoderId::AnthropicSseV1 => FfiDiscoveryAssistantDecoder::AnthropicSseV1,
        lorepia_core::DecoderId::GeminiJsonV1 => FfiDiscoveryAssistantDecoder::GeminiJsonV1,
        lorepia_core::DecoderId::GeminiSseV1 => FfiDiscoveryAssistantDecoder::GeminiSseV1,
        lorepia_core::DecoderId::OllamaJsonV1 => FfiDiscoveryAssistantDecoder::OllamaJsonV1,
        lorepia_core::DecoderId::OllamaJsonlV1 => FfiDiscoveryAssistantDecoder::OllamaJsonlV1,
    }
}

fn map_discovery_assistant_manifest_draft(
    draft: AssistantManifestDraft,
) -> FfiDiscoveryAssistantManifestDraft {
    let manifest = draft.manifest;
    let models_endpoint = manifest
        .endpoints
        .models
        .map(|endpoint| FfiDiscoveryAssistantEndpoint {
            method: map_discovery_assistant_http_method(endpoint.method),
            path: endpoint.path.as_str().to_owned(),
        });
    let generate_endpoint = FfiDiscoveryAssistantEndpoint {
        method: map_discovery_assistant_http_method(manifest.endpoints.generate.method),
        path: manifest.endpoints.generate.path.as_str().to_owned(),
    };
    let mapped_manifest = FfiDiscoveryAssistantManifest {
        schema_version: manifest.schema_version,
        api_family: map_discovery_assistant_api_family(manifest.api_family),
        sources: manifest
            .sources
            .into_iter()
            .map(|source| FfiDiscoveryAssistantManifestSource {
                kind: map_discovery_assistant_manifest_source_kind(source.kind),
                url: source.url.as_str().to_owned(),
                content_sha256: source.content_sha256,
            })
            .collect(),
        default_api_origin: manifest
            .default_api_origin
            .map(|origin| origin.as_str().to_owned()),
        auth: map_auth_binding(manifest.auth),
        models_endpoint,
        generate_endpoint,
        response_decoder: map_discovery_assistant_decoder(manifest.decoders.response),
        streaming_decoder: manifest
            .decoders
            .streaming
            .map(map_discovery_assistant_decoder),
        parameters: manifest
            .parameters
            .into_iter()
            .map(map_parameter_spec)
            .collect(),
    };
    FfiDiscoveryAssistantManifestDraft {
        manifest: mapped_manifest,
        evidence_mappings: draft
            .evidence_mappings
            .into_iter()
            .map(map_discovery_assistant_evidence_mapping)
            .collect(),
        conflicts: draft
            .conflicts
            .into_iter()
            .map(map_discovery_assistant_conflict)
            .collect(),
        unresolved_questions: draft
            .unresolved_questions
            .into_iter()
            .map(map_discovery_assistant_question)
            .collect(),
        confidence: draft
            .confidence
            .into_iter()
            .map(map_discovery_assistant_field_confidence)
            .collect(),
        summary: draft.summary,
    }
}

const fn map_discovery_assistant_review_check(
    check: DraftReviewCheck,
) -> FfiDiscoveryAssistantDraftReviewCheck {
    match check {
        DraftReviewCheck::ManifestValidation => {
            FfiDiscoveryAssistantDraftReviewCheck::ManifestValidation
        }
        DraftReviewCheck::UrlPolicyValidation => {
            FfiDiscoveryAssistantDraftReviewCheck::UrlPolicyValidation
        }
        DraftReviewCheck::CredentialOriginApproval => {
            FfiDiscoveryAssistantDraftReviewCheck::CredentialOriginApproval
        }
        DraftReviewCheck::UserReview => FfiDiscoveryAssistantDraftReviewCheck::UserReview,
    }
}

fn map_discovery_assistant_draft_review(
    review: AssistantDraftReview,
) -> FfiDiscoveryAssistantDraftReview {
    let persistence = match review.requirements.persistence {
        DraftPersistence::BlockedUntilChecksPass => {
            FfiDiscoveryAssistantDraftPersistence::BlockedUntilChecksPass
        }
    };
    FfiDiscoveryAssistantDraftReview {
        draft: map_discovery_assistant_manifest_draft(review.draft),
        unresolved_conflicts: review
            .unresolved_conflicts
            .into_iter()
            .map(map_discovery_assistant_draft_field)
            .collect(),
        required_checks: review
            .requirements
            .required_checks
            .into_iter()
            .map(map_discovery_assistant_review_check)
            .collect(),
        persistence,
    }
}

fn map_discovery_assistant_host_action(
    action: AssistantHostAction,
) -> Result<FfiDiscoveryAssistantHostAction, CoreError> {
    match action {
        AssistantHostAction::ExecuteTool { .. } => Err(CoreError::internal(
            "setup assistant tool execution escaped the Core-owned tool loop",
        )),
        AssistantHostAction::RequestMoreEvidence {
            session_id,
            questions,
        } => Ok(FfiDiscoveryAssistantHostAction::RequestMoreEvidence {
            session_id: session_id.into_inner(),
            questions: questions
                .into_iter()
                .map(map_discovery_assistant_question)
                .collect(),
        }),
        AssistantHostAction::ReviewDraft(review) => {
            Ok(FfiDiscoveryAssistantHostAction::ReviewDraft {
                review: map_discovery_assistant_draft_review(*review),
            })
        }
    }
}

fn parse_assistant_failure_kind(value: &str) -> Result<AssistantFailureKind, FfiError> {
    match value {
        "transport" => Ok(AssistantFailureKind::Transport),
        "timeout" => Ok(AssistantFailureKind::Timeout),
        "rate_limited" => Ok(AssistantFailureKind::RateLimited),
        "invalid_structured_output" => Ok(AssistantFailureKind::InvalidStructuredOutput),
        "draft_revision_required" => Ok(AssistantFailureKind::DraftRevisionRequired),
        "provider_rejected" => Ok(AssistantFailureKind::ProviderRejected),
        "internal" => Ok(AssistantFailureKind::Internal),
        _ => Err(CoreError::invalid("assistant failure kind is invalid").into()),
    }
}

fn map_provider_template_view(view: ProviderTemplateView) -> FfiProviderTemplate {
    let ProviderTemplateView {
        template,
        default_network_mode,
    } = view;
    let requires_credential = !matches!(&template.default_manifest.auth, AuthBinding::None);
    let supports_model_listing = template.default_manifest.endpoints.models.is_some();
    FfiProviderTemplate {
        id: template.id.into_inner(),
        display_name: template.display_name,
        manifest_version: template.manifest_version,
        source: template_source_name(template.source).to_owned(),
        api_family: api_family_name(template.api_family).to_owned(),
        default_network_mode: map_provider_network_mode(default_network_mode),
        default_api_origin: template
            .default_manifest
            .default_api_origin
            .map(|origin| origin.as_str().to_owned()),
        requires_credential,
        supports_model_listing,
        auth_binding: map_auth_binding(template.default_manifest.auth),
        connection_fields: template
            .connection_fields
            .into_iter()
            .map(map_connection_field_spec)
            .collect(),
        parameters: template
            .default_manifest
            .parameters
            .into_iter()
            .map(map_parameter_spec)
            .collect(),
    }
}

fn map_auth_binding(binding: AuthBinding) -> FfiAuthBinding {
    match binding {
        AuthBinding::None => FfiAuthBinding::None,
        AuthBinding::BearerHeader => FfiAuthBinding::BearerHeader,
        AuthBinding::HeaderApiKey { header_name } => FfiAuthBinding::HeaderApiKey {
            header_name: header_name.as_str().to_owned(),
        },
    }
}

fn unmap_auth_binding(binding: FfiAuthBinding) -> Result<AuthBinding, FfiError> {
    match binding {
        FfiAuthBinding::None => Ok(AuthBinding::None),
        FfiAuthBinding::BearerHeader => Ok(AuthBinding::BearerHeader),
        FfiAuthBinding::HeaderApiKey { header_name } => {
            let header_name = HeaderName::parse(&header_name).map_err(|error| {
                CoreError::invalid(format!("invalid credential header name: {error}"))
            })?;
            Ok(AuthBinding::HeaderApiKey { header_name })
        }
    }
}

const fn map_connection_field_type(value_type: ConnectionFieldType) -> FfiConnectionFieldType {
    match value_type {
        ConnectionFieldType::Text => FfiConnectionFieldType::Text,
        ConnectionFieldType::Integer => FfiConnectionFieldType::Integer,
        ConnectionFieldType::Boolean => FfiConnectionFieldType::Boolean,
        ConnectionFieldType::Credential => FfiConnectionFieldType::Credential,
    }
}

fn map_connection_field_spec(spec: ConnectionFieldSpec) -> FfiConnectionFieldSpec {
    FfiConnectionFieldSpec {
        key: spec.key,
        label_key: spec.label_key,
        description_key: spec.description_key,
        value_type: map_connection_field_type(spec.value_type),
        required: spec.required,
    }
}

fn map_connection_config_value(value: ConnectionConfigValue) -> FfiConnectionConfigValue {
    match value {
        ConnectionConfigValue::Text(value) => FfiConnectionConfigValue::Text { value },
        ConnectionConfigValue::Integer(value) => FfiConnectionConfigValue::Integer { value },
        ConnectionConfigValue::Boolean(value) => FfiConnectionConfigValue::Boolean { value },
    }
}

fn unmap_connection_config_value(value: FfiConnectionConfigValue) -> ConnectionConfigValue {
    match value {
        FfiConnectionConfigValue::Text { value } => ConnectionConfigValue::Text(value),
        FfiConnectionConfigValue::Integer { value } => ConnectionConfigValue::Integer(value),
        FfiConnectionConfigValue::Boolean { value } => ConnectionConfigValue::Boolean(value),
    }
}

fn map_connection_config_entry(entry: ConnectionConfigEntry) -> FfiConnectionConfigEntry {
    FfiConnectionConfigEntry {
        key: entry.key,
        value: map_connection_config_value(entry.value),
    }
}

fn unmap_connection_config_entry(entry: FfiConnectionConfigEntry) -> ConnectionConfigEntry {
    ConnectionConfigEntry {
        key: entry.key,
        value: unmap_connection_config_value(entry.value),
    }
}

const fn map_parameter_type(value_type: ParameterType) -> FfiParameterType {
    match value_type {
        ParameterType::Boolean => FfiParameterType::Boolean,
        ParameterType::Integer => FfiParameterType::Integer,
        ParameterType::Number => FfiParameterType::Number,
        ParameterType::String => FfiParameterType::String,
        ParameterType::Enum => FfiParameterType::Enum,
        ParameterType::StringList => FfiParameterType::StringList,
        ParameterType::JsonSchema => FfiParameterType::JsonSchema,
        ParameterType::StopSequenceList => FfiParameterType::StopSequenceList,
        ParameterType::ToolPolicy => FfiParameterType::ToolPolicy,
    }
}

const fn map_tool_policy(policy: ToolPolicy) -> FfiToolPolicy {
    match policy {
        ToolPolicy::None => FfiToolPolicy::None,
        ToolPolicy::Auto => FfiToolPolicy::Auto,
        ToolPolicy::Required => FfiToolPolicy::Required,
    }
}

const fn unmap_tool_policy(policy: FfiToolPolicy) -> ToolPolicy {
    match policy {
        FfiToolPolicy::None => ToolPolicy::None,
        FfiToolPolicy::Auto => ToolPolicy::Auto,
        FfiToolPolicy::Required => ToolPolicy::Required,
    }
}

fn map_parameter_literal(value: ParameterLiteral) -> FfiParameterLiteral {
    match value {
        ParameterLiteral::Boolean(value) => FfiParameterLiteral::Boolean { value },
        ParameterLiteral::Integer(value) => FfiParameterLiteral::Integer { value },
        ParameterLiteral::Number(value) => FfiParameterLiteral::Number { value },
        ParameterLiteral::String(value) => FfiParameterLiteral::String { value },
        ParameterLiteral::Enum(value) => FfiParameterLiteral::Enum { value },
        ParameterLiteral::StringList(values) => FfiParameterLiteral::StringList { values },
        ParameterLiteral::JsonSchema(value) => FfiParameterLiteral::JsonSchema { value },
        ParameterLiteral::StopSequenceList(values) => {
            FfiParameterLiteral::StopSequenceList { values }
        }
        ParameterLiteral::ToolPolicy(value) => FfiParameterLiteral::ToolPolicy {
            value: map_tool_policy(value),
        },
    }
}

fn unmap_parameter_literal(value: FfiParameterLiteral) -> ParameterLiteral {
    match value {
        FfiParameterLiteral::Boolean { value } => ParameterLiteral::Boolean(value),
        FfiParameterLiteral::Integer { value } => ParameterLiteral::Integer(value),
        FfiParameterLiteral::Number { value } => ParameterLiteral::Number(value),
        FfiParameterLiteral::String { value } => ParameterLiteral::String(value),
        FfiParameterLiteral::Enum { value } => ParameterLiteral::Enum(value),
        FfiParameterLiteral::StringList { values } => ParameterLiteral::StringList(values),
        FfiParameterLiteral::JsonSchema { value } => ParameterLiteral::JsonSchema(value),
        FfiParameterLiteral::StopSequenceList { values } => {
            ParameterLiteral::StopSequenceList(values)
        }
        FfiParameterLiteral::ToolPolicy { value } => {
            ParameterLiteral::ToolPolicy(unmap_tool_policy(value))
        }
    }
}

fn map_parameter_value_state(state: ParameterValueState) -> FfiParameterValueState {
    match state {
        ParameterValueState::InheritProviderDefault => {
            FfiParameterValueState::InheritProviderDefault
        }
        ParameterValueState::Explicit(value) => FfiParameterValueState::Explicit {
            value: map_parameter_literal(value),
        },
    }
}

fn unmap_parameter_value_state(state: FfiParameterValueState) -> ParameterValueState {
    match state {
        FfiParameterValueState::InheritProviderDefault => {
            ParameterValueState::InheritProviderDefault
        }
        FfiParameterValueState::Explicit { value } => {
            ParameterValueState::Explicit(unmap_parameter_literal(value))
        }
    }
}

fn map_parameter_value(value: ParameterValue) -> FfiParameterValue {
    FfiParameterValue {
        parameter_id: value.parameter_id.into_inner(),
        state: map_parameter_value_state(value.state),
    }
}

fn unmap_parameter_value(value: FfiParameterValue) -> ParameterValue {
    ParameterValue {
        parameter_id: value.parameter_id.into(),
        state: unmap_parameter_value_state(value.state),
    }
}

fn map_parameter_choice(choice: ParameterChoice) -> FfiParameterChoice {
    FfiParameterChoice {
        value: map_parameter_literal(choice.value),
        label_key: choice.label_key,
    }
}

const fn map_parameter_default_mode(mode: ParameterDefaultMode) -> FfiParameterDefaultMode {
    match mode {
        ParameterDefaultMode::ProviderDefault => FfiParameterDefaultMode::ProviderDefault,
        ParameterDefaultMode::ExplicitRequired => FfiParameterDefaultMode::ExplicitRequired,
    }
}

const fn map_parameter_condition_operator(
    operator: ParameterConditionOperator,
) -> FfiParameterConditionOperator {
    match operator {
        ParameterConditionOperator::Equals => FfiParameterConditionOperator::Equals,
        ParameterConditionOperator::NotEquals => FfiParameterConditionOperator::NotEquals,
    }
}

fn map_parameter_condition(condition: ParameterCondition) -> FfiParameterCondition {
    FfiParameterCondition {
        parameter_id: condition.parameter_id.into_inner(),
        operator: map_parameter_condition_operator(condition.operator),
        value: map_parameter_literal(condition.value),
    }
}

const fn map_parameter_conflict_kind(kind: ParameterConflictKind) -> FfiParameterConflictKind {
    match kind {
        ParameterConflictKind::MutuallyExclusive => FfiParameterConflictKind::MutuallyExclusive,
        ParameterConflictKind::Requires => FfiParameterConflictKind::Requires,
    }
}

fn map_parameter_conflict(conflict: ParameterConflict) -> FfiParameterConflict {
    FfiParameterConflict {
        parameter_id: conflict.parameter_id.into_inner(),
        kind: map_parameter_conflict_kind(conflict.kind),
        message_key: conflict.message_key,
    }
}

const fn map_provider_parameter_target(
    target: ProviderParameterTarget,
) -> FfiProviderParameterTarget {
    match target {
        ProviderParameterTarget::RequestBody => FfiProviderParameterTarget::RequestBody,
        ProviderParameterTarget::RequestHeader => FfiProviderParameterTarget::RequestHeader,
    }
}

fn map_provider_parameter_mapping(
    mapping: ProviderParameterMapping,
) -> FfiProviderParameterMapping {
    FfiProviderParameterMapping {
        target: map_provider_parameter_target(mapping.target),
        field_name: mapping.field_name,
    }
}

const fn map_ui_parameter_level(level: UiParameterLevel) -> FfiUiParameterLevel {
    match level {
        UiParameterLevel::Basic => FfiUiParameterLevel::Basic,
        UiParameterLevel::Advanced => FfiUiParameterLevel::Advanced,
        UiParameterLevel::Expert => FfiUiParameterLevel::Expert,
        UiParameterLevel::HiddenInternal => FfiUiParameterLevel::HiddenInternal,
    }
}

fn map_parameter_spec(spec: ParameterSpec) -> FfiParameterSpec {
    FfiParameterSpec {
        id: spec.id.into_inner(),
        label_key: spec.label_key,
        description_key: spec.description_key,
        value_type: map_parameter_type(spec.value_type),
        allowed_values: spec
            .allowed_values
            .into_iter()
            .map(map_parameter_choice)
            .collect(),
        minimum: spec.minimum,
        maximum: spec.maximum,
        step: spec.step,
        default_mode: map_parameter_default_mode(spec.default_mode),
        visibility: spec.visibility.map(map_parameter_condition),
        conflicts: spec
            .conflicts
            .into_iter()
            .map(map_parameter_conflict)
            .collect(),
        provider_mapping: map_provider_parameter_mapping(spec.provider_mapping),
        level: map_ui_parameter_level(spec.level),
    }
}

fn unmap_provider_connection_draft(
    draft: FfiProviderConnectionDraft,
) -> Result<ProviderConnectionDraft, FfiError> {
    let api_origin = CanonicalOrigin::parse(&draft.api_origin)
        .map_err(|error| CoreError::invalid(format!("invalid provider API origin: {error}")))?;
    let api_base_path = draft
        .api_base_path
        .as_deref()
        .map(EndpointPath::parse)
        .transpose()
        .map_err(|error| CoreError::invalid(format!("invalid provider API base path: {error}")))?;
    let approved_credential_origin = draft
        .approved_credential_origin
        .as_deref()
        .map(CanonicalOrigin::parse)
        .transpose()
        .map_err(|error| {
            CoreError::invalid(format!("invalid approved credential origin: {error}"))
        })?;
    let network_mode = unmap_provider_network_mode(draft.network_mode);
    Ok(ProviderConnectionDraft {
        id: ProviderConnectionId::from(draft.id),
        template_id: draft.template_id.into(),
        template_version: draft.template_version,
        display_name: draft.display_name,
        api_origin,
        api_base_path,
        network_mode,
        local_network_approval: draft
            .local_network_approval
            .map(unmap_local_network_approval)
            .transpose()?,
        values: draft
            .values
            .into_iter()
            .map(unmap_connection_config_entry)
            .collect(),
        approved_credential_origin,
        timeout_seconds: draft.timeout_seconds,
    })
}

fn map_provider_connection(connection: ProviderConnection) -> FfiProviderConnection {
    let approved_credential_origins = connection
        .credential_scope
        .as_ref()
        .map(|scope| {
            scope
                .allowed_origins
                .iter()
                .map(|origin| origin.as_str().to_owned())
                .collect()
        })
        .unwrap_or_default();
    FfiProviderConnection {
        id: connection.id.into_inner(),
        template_id: connection.template_id.into_inner(),
        template_version: connection.template_version,
        display_name: connection.display_name,
        api_origin: connection.api_origin.as_str().to_owned(),
        api_base_path: connection
            .config
            .api_base_path
            .map(|path| path.as_str().to_owned()),
        network_mode: map_provider_network_mode(connection.config.network_mode),
        local_network_approval: connection
            .config
            .local_network_approval
            .map(map_local_network_approval),
        values: connection
            .config
            .values
            .into_iter()
            .map(map_connection_config_entry)
            .collect(),
        credential_slot_ready: connection.credential_ref.is_some(),
        credential_scope: connection.credential_scope.map(map_credential_scope),
        approved_credential_origins,
        timeout_seconds: connection.timeout_seconds,
        status: connection_status_name(connection.status).to_owned(),
        created_at: connection.created_at.to_rfc3339(),
        updated_at: connection.updated_at.to_rfc3339(),
    }
}

const fn map_credential_redirect_policy(
    policy: CredentialRedirectPolicy,
) -> FfiCredentialRedirectPolicy {
    match policy {
        CredentialRedirectPolicy::Deny => FfiCredentialRedirectPolicy::Deny,
        CredentialRedirectPolicy::FollowWithoutCredential => {
            FfiCredentialRedirectPolicy::FollowWithoutCredential
        }
    }
}

const fn unmap_credential_redirect_policy(
    policy: FfiCredentialRedirectPolicy,
) -> CredentialRedirectPolicy {
    match policy {
        FfiCredentialRedirectPolicy::Deny => CredentialRedirectPolicy::Deny,
        FfiCredentialRedirectPolicy::FollowWithoutCredential => {
            CredentialRedirectPolicy::FollowWithoutCredential
        }
    }
}

fn map_credential_scope(scope: CredentialScope) -> FfiCredentialScope {
    FfiCredentialScope {
        allowed_origins: scope
            .allowed_origins
            .into_iter()
            .map(|origin| origin.as_str().to_owned())
            .collect(),
        auth_binding: map_auth_binding(scope.auth_binding),
        redirect_policy: map_credential_redirect_policy(scope.redirect_policy),
    }
}

fn unmap_credential_scope(scope: FfiCredentialScope) -> Result<CredentialScope, FfiError> {
    Ok(CredentialScope {
        allowed_origins: scope
            .allowed_origins
            .into_iter()
            .map(|origin| {
                CanonicalOrigin::parse(&origin).map_err(|error| {
                    CoreError::invalid(format!("invalid credential scope origin: {error}")).into()
                })
            })
            .collect::<Result<Vec<_>, FfiError>>()?,
        auth_binding: unmap_auth_binding(scope.auth_binding)?,
        redirect_policy: unmap_credential_redirect_policy(scope.redirect_policy),
    })
}

fn unmap_provider_connection(
    connection: FfiProviderConnection,
) -> Result<ProviderConnection, FfiError> {
    let api_origin = CanonicalOrigin::parse(&connection.api_origin)
        .map_err(|error| CoreError::invalid(format!("invalid provider API origin: {error}")))?;
    let api_base_path = connection
        .api_base_path
        .as_deref()
        .map(EndpointPath::parse)
        .transpose()
        .map_err(|error| CoreError::invalid(format!("invalid provider API base path: {error}")))?;
    let connection_id = ProviderConnectionId::from(connection.id);
    let credential_ref = connection
        .credential_slot_ready
        .then(|| CredentialRef(connection_id.as_str().to_owned()));
    let approved_credential_origins = connection
        .approved_credential_origins
        .into_iter()
        .map(|origin| {
            CanonicalOrigin::parse(&origin).map_err(|error| {
                CoreError::invalid(format!("invalid approved credential origin: {error}")).into()
            })
        })
        .collect::<Result<Vec<_>, FfiError>>()?;
    let credential_scope = connection
        .credential_scope
        .map(unmap_credential_scope)
        .transpose()?;
    let scope_origins = credential_scope
        .as_ref()
        .map(|scope| scope.allowed_origins.as_slice())
        .unwrap_or_default();
    if approved_credential_origins.as_slice() != scope_origins {
        return Err(CoreError::invalid(
            "approved_credential_origins must match credential_scope.allowed_origins",
        )
        .into());
    }
    let created_at = connection
        .created_at
        .parse()
        .map_err(|error| CoreError::invalid(format!("invalid connection created_at: {error}")))?;
    let updated_at = connection
        .updated_at
        .parse()
        .map_err(|error| CoreError::invalid(format!("invalid connection updated_at: {error}")))?;
    Ok(ProviderConnection {
        id: connection_id,
        template_id: connection.template_id.into(),
        template_version: connection.template_version,
        display_name: connection.display_name,
        api_origin,
        config: ConnectionConfig {
            api_base_path,
            network_mode: unmap_provider_network_mode(connection.network_mode),
            local_network_approval: connection
                .local_network_approval
                .map(unmap_local_network_approval)
                .transpose()?,
            values: connection
                .values
                .into_iter()
                .map(unmap_connection_config_entry)
                .collect(),
        },
        credential_ref,
        credential_scope,
        timeout_seconds: connection.timeout_seconds,
        status: parse_connection_status(&connection.status)?,
        created_at,
        updated_at,
    })
}

fn map_model_route(route: ModelRoute) -> FfiModelRoute {
    FfiModelRoute {
        id: route.id.into_inner(),
        connection_id: route.connection_id.into_inner(),
        api_family: api_family_name(route.api_family).to_owned(),
        model_id: route.model_id,
        display_name: route.display_name,
        route_config: map_model_route_config(route.route_config),
        availability: model_availability_name(route.status).to_owned(),
        miss_count: route.miss_count,
        raw_metadata_json: route.raw_metadata.map(BoundedJson::into_inner),
        metadata_source: model_metadata_source_name(route.metadata_source).to_owned(),
        metadata_observed_at: route
            .metadata_observed_at
            .map(|timestamp| timestamp.to_rfc3339()),
        last_reconciled_sync_job_id: route
            .last_reconciled_sync_job_id
            .map(ModelSyncJobId::into_inner),
        metadata_sync_job_id: route.metadata_sync_job_id.map(ModelSyncJobId::into_inner),
        first_seen_at: route.first_seen_at.to_rfc3339(),
        last_seen_at: route.last_seen_at.map(|timestamp| timestamp.to_rfc3339()),
    }
}

fn map_provider_model_refresh_result(
    result: ProviderModelRefreshResult,
) -> FfiProviderModelRefreshResult {
    FfiProviderModelRefreshResult {
        connection_id: result.connection_id.into_inner(),
        model_routes: result
            .model_routes
            .into_iter()
            .map(map_model_route)
            .collect(),
        newly_seen_model_route_ids: result
            .newly_seen_model_route_ids
            .into_iter()
            .map(ModelRouteId::into_inner)
            .collect(),
        missing_model_route_ids: result
            .missing_model_route_ids
            .into_iter()
            .map(ModelRouteId::into_inner)
            .collect(),
        created_generation_preset_ids: result
            .created_generation_preset_ids
            .into_iter()
            .map(GenerationPresetId::into_inner)
            .collect(),
        routes_requiring_preset_configuration: result
            .routes_requiring_preset_configuration
            .into_iter()
            .map(ModelRouteId::into_inner)
            .collect(),
        provenance: map_provider_model_refresh_provenance(result.provenance),
        pages_fetched: result.pages_fetched,
        response_bytes: result.response_bytes,
        observed_at: result.observed_at.to_rfc3339(),
    }
}

fn map_provider_model_refresh_provenance(
    provenance: ProviderModelRefreshProvenance,
) -> FfiProviderModelRefreshProvenance {
    FfiProviderModelRefreshProvenance {
        source: provenance.source,
        api_family: api_family_name(provenance.api_family).to_owned(),
        api_origin: provenance.api_origin.as_str().to_owned(),
        endpoint_path: provenance.endpoint_path.as_str().to_owned(),
    }
}

fn map_model_sync_failure(failure: ModelSyncFailure) -> FfiModelSyncFailure {
    FfiModelSyncFailure {
        code: failure.code,
        message_key: failure.message_key,
        recoverable: failure.recoverable,
    }
}

fn map_model_sync_provenance(provenance: ModelSyncSourceProvenance) -> FfiModelSyncProvenance {
    FfiModelSyncProvenance {
        source: provenance.source,
        api_family: api_family_name(provenance.api_family).to_owned(),
        api_origin: provenance.api_origin.as_str().to_owned(),
        endpoint_path: provenance.endpoint_path.as_str().to_owned(),
        pages_fetched: provenance.pages_fetched,
        response_bytes: provenance.response_bytes,
    }
}

fn map_model_sync_review(review: ModelSyncReview) -> FfiModelSyncReview {
    let ModelSyncReview { sha256, diff } = review;
    let ModelSyncDiff {
        connection_id,
        expected_connection,
        expected_model_routes,
        observed_at,
        listed_routes,
        newly_seen_model_route_ids,
        missing_model_route_ids,
        initial_presets,
        capability_observations,
        routes_requiring_preset_configuration,
        provenance,
    } = diff;
    FfiModelSyncReview {
        sha256,
        connection_id: connection_id.into_inner(),
        expected_connection: map_provider_connection(expected_connection),
        observed_at: observed_at.to_rfc3339(),
        expected_model_routes: expected_model_routes
            .into_iter()
            .map(map_model_route)
            .collect(),
        listed_routes: listed_routes.into_iter().map(map_model_route).collect(),
        newly_seen_model_route_ids: newly_seen_model_route_ids
            .into_iter()
            .map(ModelRouteId::into_inner)
            .collect(),
        missing_model_route_ids: missing_model_route_ids
            .into_iter()
            .map(ModelRouteId::into_inner)
            .collect(),
        initial_presets: initial_presets
            .into_iter()
            .map(map_generation_preset)
            .collect(),
        capability_observations: capability_observations
            .into_iter()
            .map(map_capability_observation)
            .collect(),
        routes_requiring_preset_configuration: routes_requiring_preset_configuration
            .into_iter()
            .map(ModelRouteId::into_inner)
            .collect(),
        provenance: map_model_sync_provenance(provenance),
    }
}

fn map_model_sync_job(job: ModelSyncJob) -> FfiModelSyncJob {
    FfiModelSyncJob {
        id: job.id.into_inner(),
        connection_id: job.connection_id.into_inner(),
        state: model_sync_state_name(job.state).to_owned(),
        revision: job.revision,
        review: job.review.map(map_model_sync_review),
        failure: job.failure.map(map_model_sync_failure),
        created_at: job.created_at.to_rfc3339(),
        updated_at: job.updated_at.to_rfc3339(),
    }
}

fn map_model_sync_event(event: ModelSyncEvent) -> FfiModelSyncEvent {
    FfiModelSyncEvent {
        version: event.version,
        job_id: event.job_id.into_inner(),
        sequence: event.sequence,
        job_revision: event.job_revision,
        redaction_version: event.redaction_version,
        state: model_sync_state_name(event.state).to_owned(),
        completed_steps: event.progress.completed_steps,
        total_steps: event.progress.total_steps,
        message_key: event.progress.message_key,
        review_sha256: event.review_sha256,
        failure: event.failure.map(map_model_sync_failure),
        emitted_at: event.emitted_at.to_rfc3339(),
    }
}

const fn model_sync_state_name(state: ModelSyncState) -> &'static str {
    match state {
        ModelSyncState::Created => "created",
        ModelSyncState::Fetching => "fetching",
        ModelSyncState::Interrupted => "interrupted",
        ModelSyncState::DiffReadyAwaitingReview => "diff_ready_awaiting_review",
        ModelSyncState::Committing => "committing",
        ModelSyncState::Completed => "completed",
        ModelSyncState::Failed => "failed",
        ModelSyncState::Cancelled => "cancelled",
    }
}

fn map_provider_catalog_status(status: ProviderCatalogStatus) -> FfiProviderCatalogStatus {
    FfiProviderCatalogStatus {
        status_schema_version: status.status_schema_version,
        state_version: status.state_version,
        active_revision: status.active_revision,
        active_snapshot_sha256: status.active_snapshot_sha256,
        bundled_baseline_sha256: status.bundled_baseline_sha256,
        snapshot_count: status.snapshot_count,
        signed_update_count: status.signed_update_count,
        highest_accepted_revision: status.highest_accepted_revision,
        latest_issued_at: status
            .latest_issued_at
            .map(|timestamp| timestamp.to_rfc3339()),
        active_signed_revisions: status.active_signed_revisions,
    }
}

fn map_provider_catalog_revision(
    revision: ProviderCatalogRevisionSummary,
) -> FfiProviderCatalogRevision {
    FfiProviderCatalogRevision {
        revision: revision.revision,
        captured_at: revision.captured_at.to_rfc3339(),
        snapshot_sha256: revision.snapshot_sha256,
        signed_revisions: revision.signed_revisions,
        active: revision.active,
    }
}

fn map_provider_catalog_activation(
    activation: ProviderCatalogActivationSummary,
) -> FfiProviderCatalogActivation {
    FfiProviderCatalogActivation {
        action_id: activation.action_id,
        state_version: activation.state_version,
        kind: match activation.kind {
            ProviderCatalogActivationKind::Import => "import",
            ProviderCatalogActivationKind::Rollback => "rollback",
        }
        .to_owned(),
        from_revision: activation.from_revision,
        to_revision: activation.to_revision,
        activated_at: activation.activated_at.to_rfc3339(),
        diff: map_provider_catalog_diff(activation.diff),
    }
}

fn map_provider_catalog_history(history: ProviderCatalogHistory) -> FfiProviderCatalogHistory {
    FfiProviderCatalogHistory {
        history_schema_version: history.history_schema_version,
        active_revision: history.active_revision,
        revisions: history
            .revisions
            .into_iter()
            .map(map_provider_catalog_revision)
            .collect(),
        activations: history
            .activations
            .into_iter()
            .map(map_provider_catalog_activation)
            .collect(),
        next_before_revision: history.next_before_revision,
        next_before_state_version: history.next_before_state_version,
    }
}

fn map_provider_catalog_template_changed_section(
    section: ManifestChangedSection,
) -> FfiProviderCatalogTemplateChangedSection {
    match section {
        ManifestChangedSection::DisplayName => {
            FfiProviderCatalogTemplateChangedSection::DisplayName
        }
        ManifestChangedSection::ManifestVersion => {
            FfiProviderCatalogTemplateChangedSection::ManifestVersion
        }
        ManifestChangedSection::ConnectionFields => {
            FfiProviderCatalogTemplateChangedSection::ConnectionFields
        }
        ManifestChangedSection::ApiFamily => FfiProviderCatalogTemplateChangedSection::ApiFamily,
        ManifestChangedSection::Sources => FfiProviderCatalogTemplateChangedSection::Sources,
        ManifestChangedSection::Origin => FfiProviderCatalogTemplateChangedSection::Origin,
        ManifestChangedSection::Authentication => {
            FfiProviderCatalogTemplateChangedSection::Authentication
        }
        ManifestChangedSection::Endpoints => FfiProviderCatalogTemplateChangedSection::Endpoints,
        ManifestChangedSection::Decoders => FfiProviderCatalogTemplateChangedSection::Decoders,
        ManifestChangedSection::Parameters => FfiProviderCatalogTemplateChangedSection::Parameters,
        ManifestChangedSection::Freshness => FfiProviderCatalogTemplateChangedSection::Freshness,
    }
}

fn map_provider_catalog_model_changed_section(
    section: ModelChangedSection,
) -> FfiProviderCatalogModelChangedSection {
    match section {
        ModelChangedSection::Match => FfiProviderCatalogModelChangedSection::Match,
        ModelChangedSection::ApiFamily => FfiProviderCatalogModelChangedSection::ApiFamily,
        ModelChangedSection::MetadataVersion => {
            FfiProviderCatalogModelChangedSection::MetadataVersion
        }
        ModelChangedSection::Capabilities => FfiProviderCatalogModelChangedSection::Capabilities,
        ModelChangedSection::Parameters => FfiProviderCatalogModelChangedSection::Parameters,
        ModelChangedSection::Lifecycle => FfiProviderCatalogModelChangedSection::Lifecycle,
        ModelChangedSection::Sources => FfiProviderCatalogModelChangedSection::Sources,
        ModelChangedSection::Freshness => FfiProviderCatalogModelChangedSection::Freshness,
    }
}

fn map_provider_catalog_template_diff_entry(
    entry: ManifestDiffDto,
) -> FfiProviderCatalogTemplateDiffEntry {
    FfiProviderCatalogTemplateDiffEntry {
        provider_template_id: entry.provider_template_id.into_inner(),
        previous_manifest_version: entry.previous_manifest_version,
        next_manifest_version: entry.next_manifest_version,
        previous_sha256: entry.previous_sha256,
        next_sha256: entry.next_sha256,
        changed_sections: entry
            .changed_sections
            .into_iter()
            .map(map_provider_catalog_template_changed_section)
            .collect(),
    }
}

fn map_provider_catalog_model_diff_entry(
    entry: ModelMetadataDiffDto,
) -> FfiProviderCatalogModelDiffEntry {
    FfiProviderCatalogModelDiffEntry {
        model_entry_id: entry.model_entry_id,
        provider_template_id: entry.provider_template_id.into_inner(),
        previous_metadata_version: entry.previous_metadata_version,
        next_metadata_version: entry.next_metadata_version,
        previous_sha256: entry.previous_sha256,
        next_sha256: entry.next_sha256,
        changed_sections: entry
            .changed_sections
            .into_iter()
            .map(map_provider_catalog_model_changed_section)
            .collect(),
    }
}

fn map_provider_catalog_diff(diff: CatalogDiffDto) -> FfiProviderCatalogDiff {
    let mut mapped = FfiProviderCatalogDiff {
        diff_schema_version: diff.diff_schema_version,
        from_revision: diff.from_revision,
        to_revision: diff.to_revision,
        added_provider_templates: Vec::new(),
        changed_provider_templates: Vec::new(),
        removed_provider_templates: Vec::new(),
        added_models: Vec::new(),
        changed_models: Vec::new(),
        removed_models: Vec::new(),
    };

    for entry in diff.manifest_changes {
        let change = entry.change;
        let entry = map_provider_catalog_template_diff_entry(entry);
        match change {
            CatalogChangeKind::Added => mapped.added_provider_templates.push(entry),
            CatalogChangeKind::Updated => mapped.changed_provider_templates.push(entry),
            CatalogChangeKind::Removed => mapped.removed_provider_templates.push(entry),
        }
    }
    for entry in diff.model_changes {
        let change = entry.change;
        let entry = map_provider_catalog_model_diff_entry(entry);
        match change {
            CatalogChangeKind::Added => mapped.added_models.push(entry),
            CatalogChangeKind::Updated => mapped.changed_models.push(entry),
            CatalogChangeKind::Removed => mapped.removed_models.push(entry),
        }
    }

    mapped
}

fn map_provider_catalog_import_result(
    result: ProviderCatalogImportResult,
) -> FfiProviderCatalogImportResult {
    FfiProviderCatalogImportResult {
        signed_catalog_revision: result.signed_catalog_revision,
        activated_revision: result.activated_revision,
        diff: map_provider_catalog_diff(result.diff),
        status: map_provider_catalog_status(result.status),
    }
}

fn map_provider_catalog_import_review(
    review: ProviderCatalogImportReview,
) -> FfiProviderCatalogImportReview {
    FfiProviderCatalogImportReview {
        plan_schema_version: review.plan_schema_version,
        action_id: review.action_id,
        expected_state_version: review.expected_state_version,
        expected_active_revision: review.expected_active_revision,
        expected_active_snapshot_sha256: review.expected_active_snapshot_sha256,
        expected_highest_accepted_revision: review.expected_highest_accepted_revision,
        envelope_byte_count: review.envelope_byte_count,
        envelope_sha256: review.envelope_sha256,
        signing_key_id: review.signing_key_id,
        payload_sha256: review.payload_sha256,
        signed_catalog_revision: review.signed_catalog_revision,
        candidate_revision: review.candidate_revision,
        candidate_snapshot_sha256: review.candidate_snapshot_sha256,
        prepared_at: review.prepared_at.to_rfc3339(),
        expires_at: review.expires_at.to_rfc3339(),
        diff: map_provider_catalog_diff(review.diff),
    }
}

fn map_provider_catalog_import_plan(
    plan: ProviderCatalogImportPlan,
) -> Result<FfiProviderCatalogImportPlan, CoreError> {
    let plan_json = encode_binding_json(&plan, "provider catalog import plan")?;
    Ok(FfiProviderCatalogImportPlan {
        review: map_provider_catalog_import_review(plan.review),
        plan_sha256: plan.plan_sha256,
        plan_json,
    })
}

fn unmap_provider_catalog_import_plan(
    visible: FfiProviderCatalogImportPlan,
) -> Result<ProviderCatalogImportPlan, FfiError> {
    let parsed: ProviderCatalogImportPlan = serde_json::from_str(&visible.plan_json)
        .map_err(|_| CoreError::invalid("provider catalog import plan JSON is invalid"))?;
    let remapped = map_provider_catalog_import_plan(parsed.clone())?;
    if remapped != visible {
        return Err(CoreError::invalid(
            "provider catalog import plan fields do not match the reviewed plan",
        )
        .into());
    }
    Ok(parsed)
}

fn map_provider_catalog_rollback_plan(
    plan: ProviderCatalogRollbackPlan,
) -> Result<FfiProviderCatalogRollbackPlan, CoreError> {
    let plan_json = encode_binding_json(&plan, "provider catalog rollback plan")?;
    Ok(FfiProviderCatalogRollbackPlan {
        plan_schema_version: plan.plan_schema_version,
        action_id: plan.action_id,
        expected_state_version: plan.expected_state_version,
        plan_sha256: plan.plan_sha256,
        from_revision: plan.catalog_plan.from_revision,
        to_revision: plan.catalog_plan.to_revision,
        created_at: plan.catalog_plan.created_at.to_rfc3339(),
        expires_at: plan.catalog_plan.expires_at.to_rfc3339(),
        diff: map_provider_catalog_diff(plan.catalog_plan.diff),
        plan_json,
    })
}

fn unmap_provider_catalog_rollback_plan(
    visible: FfiProviderCatalogRollbackPlan,
) -> Result<ProviderCatalogRollbackPlan, FfiError> {
    let parsed: ProviderCatalogRollbackPlan = serde_json::from_str(&visible.plan_json)
        .map_err(|_| CoreError::invalid("provider catalog rollback plan JSON is invalid"))?;
    let remapped = map_provider_catalog_rollback_plan(parsed.clone())?;
    if remapped != visible {
        return Err(CoreError::invalid(
            "provider catalog rollback plan fields do not match the reviewed plan",
        )
        .into());
    }
    Ok(parsed)
}

fn map_provider_catalog_rollback_result(
    result: ProviderCatalogRollbackResult,
) -> FfiProviderCatalogRollbackResult {
    FfiProviderCatalogRollbackResult {
        from_revision: result.from_revision,
        activated_revision: result.activated_revision,
        status: map_provider_catalog_status(result.status),
    }
}

fn encode_binding_json(value: &impl serde::Serialize, label: &str) -> Result<String, CoreError> {
    serde_json::to_string(value)
        .map_err(|_| CoreError::internal(format!("{label} could not be serialized")))
}

fn map_capability_value(value: CapabilityValue) -> FfiCapabilityValue {
    match value {
        CapabilityValue::Boolean(value) => FfiCapabilityValue {
            kind: "boolean".to_owned(),
            boolean_value: Some(value),
            integer_value: None,
            enum_values: Vec::new(),
            structured_json: None,
        },
        CapabilityValue::Integer(value) => FfiCapabilityValue {
            kind: "integer".to_owned(),
            boolean_value: None,
            integer_value: Some(value),
            enum_values: Vec::new(),
            structured_json: None,
        },
        CapabilityValue::EnumValues(values) => FfiCapabilityValue {
            kind: "enum_values".to_owned(),
            boolean_value: None,
            integer_value: None,
            enum_values: values,
            structured_json: None,
        },
        CapabilityValue::Structured(value) => FfiCapabilityValue {
            kind: "structured".to_owned(),
            boolean_value: None,
            integer_value: None,
            enum_values: Vec::new(),
            structured_json: Some(value.to_string()),
        },
    }
}

fn unmap_user_capability_value(value: FfiCapabilityValue) -> Result<CapabilityValue, FfiError> {
    let no_boolean = value.boolean_value.is_none();
    let no_integer = value.integer_value.is_none();
    let no_enums = value.enum_values.is_empty();
    let no_structured = value.structured_json.is_none();
    match value.kind.as_str() {
        "boolean" if no_integer && no_enums && no_structured => value
            .boolean_value
            .map(CapabilityValue::Boolean)
            .ok_or_else(|| CoreError::invalid("boolean capability value is missing").into()),
        "integer" if no_boolean && no_enums && no_structured => value
            .integer_value
            .map(CapabilityValue::Integer)
            .ok_or_else(|| CoreError::invalid("integer capability value is missing").into()),
        "enum_values" if no_boolean && no_integer && no_structured => {
            if value.enum_values.is_empty()
                || value.enum_values.iter().any(|item| item.trim().is_empty())
            {
                return Err(CoreError::invalid(
                    "enum capability values must contain non-empty entries",
                )
                .into());
            }
            Ok(CapabilityValue::EnumValues(value.enum_values))
        }
        "structured" => Err(CoreError::invalid(
            "structured capability metadata is read-only in native bindings",
        )
        .into()),
        _ => Err(CoreError::invalid(
            "capability value fields do not match its boolean, integer, or enum_values kind",
        )
        .into()),
    }
}

fn map_capability_observation(observation: CapabilityObservation) -> FfiCapabilityObservation {
    FfiCapabilityObservation {
        id: observation.id.into_inner(),
        model_route_id: observation.model_route_id.into_inner(),
        key: capability_key_name(observation.key).to_owned(),
        value: map_capability_value(observation.value),
        status: support_status_name(observation.status).to_owned(),
        source: observation_source_name(observation.source).to_owned(),
        confidence: confidence_name(observation.confidence).to_owned(),
        observed_at: observation.observed_at.to_rfc3339(),
        expires_at: observation
            .expires_at
            .map(|timestamp| timestamp.to_rfc3339()),
        evidence_ref: observation.evidence_ref.map(EvidenceId::into_inner),
    }
}

fn unmap_capability_override(
    draft: FfiCapabilityOverrideDraft,
) -> Result<CapabilityObservation, FfiError> {
    let expires_at = draft
        .expires_at
        .map(|timestamp| {
            timestamp.parse().map_err(|error| {
                CoreError::invalid(format!("invalid capability expiry timestamp: {error}"))
            })
        })
        .transpose()?;
    Ok(CapabilityObservation {
        id: ObservationId::from(draft.id),
        model_route_id: ModelRouteId::from(draft.model_route_id),
        key: parse_capability_key(&draft.key)?,
        value: unmap_user_capability_value(draft.value)?,
        status: parse_user_override_status(&draft.status)?,
        source: ObservationSource::UserOverride,
        confidence: Confidence::High,
        observed_at: Utc::now(),
        expires_at,
        evidence_ref: None,
    })
}

fn map_effective_capability(capability: EffectiveCapability) -> FfiEffectiveCapability {
    FfiEffectiveCapability {
        selected: map_capability_observation(capability.selected),
        alternatives: capability
            .alternatives
            .into_iter()
            .map(map_capability_observation)
            .collect(),
        evaluated_at: capability.evaluated_at.to_rfc3339(),
        selected_is_stale: capability.selected_is_stale,
        has_conflict: capability.has_conflict,
    }
}

const fn capability_key_name(key: CapabilityKey) -> &'static str {
    match key {
        CapabilityKey::Streaming => "streaming",
        CapabilityKey::Reasoning => "reasoning",
        CapabilityKey::PromptCaching => "prompt_caching",
        CapabilityKey::ToolCalling => "tool_calling",
        CapabilityKey::ParallelToolCalling => "parallel_tool_calling",
        CapabilityKey::StructuredOutput => "structured_output",
        CapabilityKey::JsonMode => "json_mode",
        CapabilityKey::ImageInput => "image_input",
        CapabilityKey::AudioInput => "audio_input",
        CapabilityKey::AudioOutput => "audio_output",
        CapabilityKey::Logprobs => "logprobs",
        CapabilityKey::Seed => "seed",
        CapabilityKey::Batch => "batch",
        CapabilityKey::Background => "background",
        CapabilityKey::ContextWindow => "context_window",
        CapabilityKey::MaxOutputTokens => "max_output_tokens",
    }
}

fn parse_capability_key(value: &str) -> Result<CapabilityKey, FfiError> {
    match value {
        "streaming" => Ok(CapabilityKey::Streaming),
        "reasoning" => Ok(CapabilityKey::Reasoning),
        "prompt_caching" => Ok(CapabilityKey::PromptCaching),
        "tool_calling" => Ok(CapabilityKey::ToolCalling),
        "parallel_tool_calling" => Ok(CapabilityKey::ParallelToolCalling),
        "structured_output" => Ok(CapabilityKey::StructuredOutput),
        "json_mode" => Ok(CapabilityKey::JsonMode),
        "image_input" => Ok(CapabilityKey::ImageInput),
        "audio_input" => Ok(CapabilityKey::AudioInput),
        "audio_output" => Ok(CapabilityKey::AudioOutput),
        "logprobs" => Ok(CapabilityKey::Logprobs),
        "seed" => Ok(CapabilityKey::Seed),
        "batch" => Ok(CapabilityKey::Batch),
        "background" => Ok(CapabilityKey::Background),
        "context_window" => Ok(CapabilityKey::ContextWindow),
        "max_output_tokens" => Ok(CapabilityKey::MaxOutputTokens),
        _ => Err(CoreError::invalid("unknown capability key").into()),
    }
}

const fn support_status_name(status: SupportStatus) -> &'static str {
    match status {
        SupportStatus::Verified => "verified",
        SupportStatus::Documented => "documented",
        SupportStatus::Inferred => "inferred",
        SupportStatus::Unsupported => "unsupported",
        SupportStatus::Unknown => "unknown",
        SupportStatus::Conditional => "conditional",
    }
}

fn parse_user_override_status(value: &str) -> Result<SupportStatus, FfiError> {
    match value {
        "verified" => Ok(SupportStatus::Verified),
        "unsupported" => Ok(SupportStatus::Unsupported),
        "unknown" => Ok(SupportStatus::Unknown),
        "conditional" => Ok(SupportStatus::Conditional),
        _ => Err(CoreError::invalid(
            "user override status must be verified, unsupported, unknown, or conditional",
        )
        .into()),
    }
}

const fn observation_source_name(source: ObservationSource) -> &'static str {
    match source {
        ObservationSource::ProviderApi => "provider_api",
        ObservationSource::OfficialDocumentation => "official_documentation",
        ObservationSource::SignedLorepiaCatalog => "signed_lorepia_catalog",
        ObservationSource::CapabilityProbe => "capability_probe",
        ObservationSource::UserOverride => "user_override",
        ObservationSource::LlmInference => "llm_inference",
    }
}

const fn confidence_name(confidence: Confidence) -> &'static str {
    match confidence {
        Confidence::Low => "low",
        Confidence::Medium => "medium",
        Confidence::High => "high",
    }
}

fn map_model_route_config(config: ModelRouteConfig) -> FfiModelRouteConfig {
    FfiModelRouteConfig {
        deployment_id: config.deployment_id,
        region: config.region,
        endpoint_path: config.endpoint_path.map(|path| path.as_str().to_owned()),
        values: config
            .values
            .into_iter()
            .map(map_connection_config_entry)
            .collect(),
    }
}

fn unmap_model_route_config(config: FfiModelRouteConfig) -> Result<ModelRouteConfig, FfiError> {
    let endpoint_path = config
        .endpoint_path
        .as_deref()
        .map(EndpointPath::parse)
        .transpose()
        .map_err(|error| CoreError::invalid(format!("invalid model endpoint path: {error}")))?;
    Ok(ModelRouteConfig {
        deployment_id: config.deployment_id,
        region: config.region,
        endpoint_path,
        values: config
            .values
            .into_iter()
            .map(unmap_connection_config_entry)
            .collect(),
    })
}

fn unmap_model_route(route: FfiModelRoute) -> Result<ModelRoute, FfiError> {
    let first_seen_at = route
        .first_seen_at
        .parse()
        .map_err(|error| CoreError::invalid(format!("invalid model first_seen_at: {error}")))?;
    let last_seen_at = route
        .last_seen_at
        .map(|timestamp| {
            timestamp
                .parse()
                .map_err(|error| CoreError::invalid(format!("invalid model last_seen_at: {error}")))
        })
        .transpose()?;
    let metadata_observed_at = route
        .metadata_observed_at
        .map(|timestamp| {
            timestamp.parse().map_err(|error| {
                CoreError::invalid(format!("invalid model metadata_observed_at: {error}"))
            })
        })
        .transpose()?;
    Ok(ModelRoute {
        id: route.id.into(),
        connection_id: route.connection_id.into(),
        api_family: parse_api_family(&route.api_family)?,
        model_id: route.model_id,
        display_name: route.display_name,
        route_config: unmap_model_route_config(route.route_config)?,
        status: parse_model_availability(&route.availability)?,
        miss_count: route.miss_count,
        raw_metadata: route
            .raw_metadata_json
            .map(BoundedJson::parse)
            .transpose()
            .map_err(CoreError::invalid)?,
        metadata_source: parse_model_metadata_source(&route.metadata_source)?,
        metadata_observed_at,
        last_reconciled_sync_job_id: route.last_reconciled_sync_job_id.map(Into::into),
        metadata_sync_job_id: route.metadata_sync_job_id.map(Into::into),
        first_seen_at,
        last_seen_at,
    })
}

fn map_generation_preset(preset: GenerationPreset) -> FfiGenerationPreset {
    let (prompt_cache_ttl, prompt_cache_custom_ttl_seconds) = match preset.prompt_cache.ttl {
        GenerationPromptCacheTtl::ProviderDefault => ("provider_default", None),
        GenerationPromptCacheTtl::Short => ("short", None),
        GenerationPromptCacheTtl::Long => ("long", None),
        GenerationPromptCacheTtl::CustomSeconds(seconds) => ("custom_seconds", Some(seconds)),
    };
    FfiGenerationPreset {
        id: preset.id.into_inner(),
        model_route_id: preset.model_route_id.into_inner(),
        display_name: preset.display_name,
        parameter_value_count: u32::try_from(preset.values.len()).unwrap_or(u32::MAX),
        values: preset.values.into_iter().map(map_parameter_value).collect(),
        reasoning_mode: reasoning_mode_name(preset.reasoning.mode).to_owned(),
        reasoning_effort: preset
            .reasoning
            .effort
            .map(|effort| reasoning_effort_name(effort).to_owned()),
        reasoning_budget_tokens: preset.reasoning.budget_tokens,
        reasoning_summary: reasoning_summary_name(preset.reasoning.summary).to_owned(),
        preserve_opaque_reasoning_state: preset.reasoning.preserve_opaque_state,
        prompt_cache_mode: prompt_cache_mode_name(preset.prompt_cache.mode).to_owned(),
        prompt_cache_ttl: prompt_cache_ttl.to_owned(),
        prompt_cache_custom_ttl_seconds,
        prompt_cache_context_reference: preset.prompt_cache.context_reference,
        created_at: preset.created_at.to_rfc3339(),
        updated_at: preset.updated_at.to_rfc3339(),
    }
}

fn map_parameter_issue(issue: ParameterIssue) -> FfiParameterIssue {
    FfiParameterIssue {
        code: parameter_issue_code_name(issue.code).to_owned(),
        parameter_id: issue
            .parameter_id
            .map(lorepia_core::ParameterId::into_inner),
        related_parameter_id: issue
            .related_parameter_id
            .map(lorepia_core::ParameterId::into_inner),
        message: issue.message,
    }
}

fn map_reasoning_control(control: ReasoningControlModel) -> FfiReasoningControl {
    let budget_bounds = control.budget_bounds;
    FfiReasoningControl {
        state: ui_control_state_name(control.state).to_owned(),
        mode: provider_reasoning_mode_name(control.settings.mode).to_owned(),
        effort: control
            .settings
            .effort
            .map(|effort| provider_reasoning_effort_name(effort).to_owned()),
        budget_tokens: control.settings.budget_tokens,
        summary: provider_reasoning_summary_name(control.settings.summary).to_owned(),
        preserve_opaque_state: control.settings.preserve_opaque_state,
        allowed_modes: control
            .allowed_modes
            .into_iter()
            .map(|mode| provider_reasoning_mode_name(mode).to_owned())
            .collect(),
        allowed_efforts: control
            .allowed_efforts
            .into_iter()
            .map(|effort| provider_reasoning_effort_name(effort).to_owned())
            .collect(),
        allowed_summaries: control
            .allowed_summaries
            .into_iter()
            .map(|summary| provider_reasoning_summary_name(summary).to_owned())
            .collect(),
        minimum_budget_tokens: budget_bounds.map(|bounds| bounds.minimum),
        maximum_budget_tokens: budget_bounds.map(|bounds| bounds.maximum),
        effort_field: ui_field_state_name(control.effort_field).to_owned(),
        budget_field: ui_field_state_name(control.budget_field).to_owned(),
        summary_field: ui_field_state_name(control.summary_field).to_owned(),
        issues: control
            .issues
            .into_iter()
            .map(map_parameter_issue)
            .collect(),
    }
}

fn map_prompt_cache_control(control: PromptCacheControlModel) -> FfiPromptCacheControl {
    let custom_bounds = control.custom_ttl_bounds;
    let (ttl, custom_ttl_seconds) = provider_prompt_cache_ttl_parts(control.settings.ttl);
    FfiPromptCacheControl {
        state: ui_control_state_name(control.state).to_owned(),
        mode: provider_prompt_cache_mode_name(control.settings.mode).to_owned(),
        ttl: ttl.to_owned(),
        custom_ttl_seconds,
        context_reference: control.settings.context_reference,
        allowed_modes: control
            .allowed_modes
            .into_iter()
            .map(|mode| provider_prompt_cache_mode_name(mode).to_owned())
            .collect(),
        allowed_ttls: control
            .allowed_ttls
            .into_iter()
            .map(|ttl| provider_prompt_cache_ttl_parts(ttl).0.to_owned())
            .collect(),
        supports_custom_ttl: control.supports_custom_ttl,
        minimum_custom_ttl_seconds: custom_bounds.map(|bounds| bounds.minimum_seconds),
        maximum_custom_ttl_seconds: custom_bounds.map(|bounds| bounds.maximum_seconds),
        ttl_field: ui_field_state_name(control.ttl_field).to_owned(),
        context_reference_field: ui_field_state_name(control.context_reference_field).to_owned(),
        issues: control
            .issues
            .into_iter()
            .map(map_parameter_issue)
            .collect(),
    }
}

fn map_request_body_field(field: &RequestBodyField) -> FfiRequestBodyField {
    FfiRequestBodyField {
        name: field.name().to_owned(),
        shape: map_request_body_shape(field.shape()),
    }
}

fn map_request_body_shape(shape: &RequestBodyShape) -> FfiRequestBodyShape {
    match shape {
        RequestBodyShape::Null => FfiRequestBodyShape::Null,
        RequestBodyShape::Boolean => FfiRequestBodyShape::Boolean,
        RequestBodyShape::Number => FfiRequestBodyShape::Number,
        RequestBodyShape::String => FfiRequestBodyShape::String,
        RequestBodyShape::Array { items, truncated } => FfiRequestBodyShape::Array {
            items: items.iter().map(map_request_body_shape).collect(),
            truncated: *truncated,
        },
        RequestBodyShape::Object { fields, truncated } => FfiRequestBodyShape::Object {
            fields: fields.iter().map(map_request_body_field).collect(),
            truncated: *truncated,
        },
        RequestBodyShape::Redacted => FfiRequestBodyShape::Redacted,
        RequestBodyShape::Truncated => FfiRequestBodyShape::Truncated,
    }
}

fn map_request_preview(preview: RequestPreview) -> FfiRequestPreview {
    FfiRequestPreview {
        redaction_version: 1,
        method: match preview.method() {
            HttpMethod::Get => "GET",
            HttpMethod::Post => "POST",
        }
        .to_owned(),
        origin: preview.origin().as_str().to_owned(),
        path: preview.path().as_str().to_owned(),
        header_names: preview
            .header_names()
            .iter()
            .map(|name| name.as_str().to_owned())
            .collect(),
        query_parameter_names: preview.query_parameter_names().to_vec(),
        body_shape: preview.body().map(map_request_body_shape),
        body_truncated: preview.body_truncated(),
        includes_private_message: false,
        includes_credential_value: false,
        includes_opaque_reasoning_state: false,
    }
}

const fn ui_control_state_name(state: UiControlState) -> &'static str {
    match state {
        UiControlState::Hidden => "hidden",
        UiControlState::Ready => "ready",
        UiControlState::Invalid => "invalid",
    }
}

const fn ui_field_state_name(state: UiFieldState) -> &'static str {
    match state {
        UiFieldState::Hidden => "hidden",
        UiFieldState::Enabled => "enabled",
        UiFieldState::Required => "required",
    }
}

const fn provider_reasoning_mode_name(mode: ReasoningMode) -> &'static str {
    match mode {
        ReasoningMode::ProviderDefault => "provider_default",
        ReasoningMode::Disabled => "disabled",
        ReasoningMode::Automatic => "automatic",
        ReasoningMode::Enabled => "enabled",
    }
}

const fn provider_reasoning_effort_name(effort: ReasoningEffort) -> &'static str {
    match effort {
        ReasoningEffort::Minimal => "minimal",
        ReasoningEffort::Low => "low",
        ReasoningEffort::Medium => "medium",
        ReasoningEffort::High => "high",
        ReasoningEffort::ExtraHigh => "extra_high",
        ReasoningEffort::Maximum => "maximum",
    }
}

const fn provider_reasoning_summary_name(summary: ReasoningSummaryMode) -> &'static str {
    match summary {
        ReasoningSummaryMode::ProviderDefault => "provider_default",
        ReasoningSummaryMode::Disabled => "disabled",
        ReasoningSummaryMode::Automatic => "automatic",
        ReasoningSummaryMode::Concise => "concise",
        ReasoningSummaryMode::Detailed => "detailed",
    }
}

const fn provider_prompt_cache_mode_name(mode: PromptCacheMode) -> &'static str {
    match mode {
        PromptCacheMode::ProviderDefault => "provider_default",
        PromptCacheMode::Automatic => "automatic",
        PromptCacheMode::ExplicitBreakpoints => "explicit_breakpoints",
        PromptCacheMode::ExplicitContext => "explicit_context",
        PromptCacheMode::DisabledIfSupported => "disabled_if_supported",
    }
}

const fn provider_prompt_cache_ttl_parts(ttl: PromptCacheTtl) -> (&'static str, Option<u32>) {
    match ttl {
        PromptCacheTtl::ProviderDefault => ("provider_default", None),
        PromptCacheTtl::Short => ("short", None),
        PromptCacheTtl::Long => ("long", None),
        PromptCacheTtl::CustomSeconds(seconds) => ("custom_seconds", Some(seconds)),
    }
}

const fn parameter_issue_code_name(code: ParameterIssueCode) -> &'static str {
    match code {
        ParameterIssueCode::InvalidDefinition => "invalid_definition",
        ParameterIssueCode::DuplicateParameter => "duplicate_parameter",
        ParameterIssueCode::UnknownParameter => "unknown_parameter",
        ParameterIssueCode::DuplicateValue => "duplicate_value",
        ParameterIssueCode::RequiredValueMissing => "required_value_missing",
        ParameterIssueCode::TypeMismatch => "type_mismatch",
        ParameterIssueCode::OutOfBounds => "out_of_bounds",
        ParameterIssueCode::InvalidStep => "invalid_step",
        ParameterIssueCode::InvalidChoice => "invalid_choice",
        ParameterIssueCode::InvalidJsonSchema => "invalid_json_schema",
        ParameterIssueCode::HiddenValue => "hidden_value",
        ParameterIssueCode::MutuallyExclusive => "mutually_exclusive",
        ParameterIssueCode::MissingRequirement => "missing_requirement",
        ParameterIssueCode::UnsupportedMapping => "unsupported_mapping",
        ParameterIssueCode::ConflictingRequestField => "conflicting_request_field",
        ParameterIssueCode::UnsupportedReasoning => "unsupported_reasoning",
        ParameterIssueCode::UnsupportedPromptCache => "unsupported_prompt_cache",
        ParameterIssueCode::InvalidPromptCacheReference => "invalid_prompt_cache_reference",
    }
}

fn unmap_generation_preset(preset: FfiGenerationPreset) -> Result<GenerationPreset, FfiError> {
    let actual_parameter_value_count = u32::try_from(preset.values.len())
        .map_err(|_| CoreError::invalid("generation preset contains too many parameter values"))?;
    if preset.parameter_value_count != actual_parameter_value_count {
        return Err(CoreError::invalid(
            "parameter_value_count must match the number of typed parameter values",
        )
        .into());
    }
    let prompt_cache_ttl = parse_prompt_cache_ttl(
        &preset.prompt_cache_ttl,
        preset.prompt_cache_custom_ttl_seconds,
    )?;
    let created_at = preset
        .created_at
        .parse()
        .map_err(|error| CoreError::invalid(format!("invalid preset created_at: {error}")))?;
    let updated_at = preset
        .updated_at
        .parse()
        .map_err(|error| CoreError::invalid(format!("invalid preset updated_at: {error}")))?;
    Ok(GenerationPreset {
        id: preset.id.into(),
        model_route_id: preset.model_route_id.into(),
        display_name: preset.display_name,
        values: preset
            .values
            .into_iter()
            .map(unmap_parameter_value)
            .collect(),
        reasoning: GenerationReasoningSettings {
            mode: parse_reasoning_mode(&preset.reasoning_mode)?,
            effort: preset
                .reasoning_effort
                .as_deref()
                .map(parse_reasoning_effort)
                .transpose()?,
            budget_tokens: preset.reasoning_budget_tokens,
            summary: parse_reasoning_summary(&preset.reasoning_summary)?,
            preserve_opaque_state: preset.preserve_opaque_reasoning_state,
        },
        prompt_cache: GenerationPromptCacheSettings {
            mode: parse_prompt_cache_mode(&preset.prompt_cache_mode)?,
            ttl: prompt_cache_ttl,
            context_reference: preset.prompt_cache_context_reference,
        },
        created_at,
        updated_at,
    })
}

const fn reasoning_mode_name(mode: GenerationReasoningMode) -> &'static str {
    match mode {
        GenerationReasoningMode::ProviderDefault => "provider_default",
        GenerationReasoningMode::Disabled => "disabled",
        GenerationReasoningMode::Automatic => "automatic",
        GenerationReasoningMode::Enabled => "enabled",
    }
}

const fn reasoning_effort_name(effort: GenerationReasoningEffort) -> &'static str {
    match effort {
        GenerationReasoningEffort::Minimal => "minimal",
        GenerationReasoningEffort::Low => "low",
        GenerationReasoningEffort::Medium => "medium",
        GenerationReasoningEffort::High => "high",
        GenerationReasoningEffort::ExtraHigh => "extra_high",
        GenerationReasoningEffort::Maximum => "maximum",
    }
}

const fn reasoning_summary_name(summary: GenerationReasoningSummary) -> &'static str {
    match summary {
        GenerationReasoningSummary::ProviderDefault => "provider_default",
        GenerationReasoningSummary::Disabled => "disabled",
        GenerationReasoningSummary::Automatic => "automatic",
        GenerationReasoningSummary::Concise => "concise",
        GenerationReasoningSummary::Detailed => "detailed",
    }
}

const fn prompt_cache_mode_name(mode: GenerationPromptCacheMode) -> &'static str {
    match mode {
        GenerationPromptCacheMode::ProviderDefault => "provider_default",
        GenerationPromptCacheMode::Automatic => "automatic",
        GenerationPromptCacheMode::ExplicitBreakpoints => "explicit_breakpoints",
        GenerationPromptCacheMode::ExplicitContext => "explicit_context",
        GenerationPromptCacheMode::DisabledIfSupported => "disabled_if_supported",
    }
}

fn parse_reasoning_mode(value: &str) -> Result<GenerationReasoningMode, FfiError> {
    match value {
        "provider_default" => Ok(GenerationReasoningMode::ProviderDefault),
        "disabled" => Ok(GenerationReasoningMode::Disabled),
        "automatic" => Ok(GenerationReasoningMode::Automatic),
        "enabled" => Ok(GenerationReasoningMode::Enabled),
        _ => Err(CoreError::invalid(
            "reasoning mode must be provider_default, disabled, automatic, or enabled",
        )
        .into()),
    }
}

fn parse_reasoning_effort(value: &str) -> Result<GenerationReasoningEffort, FfiError> {
    match value {
        "minimal" => Ok(GenerationReasoningEffort::Minimal),
        "low" => Ok(GenerationReasoningEffort::Low),
        "medium" => Ok(GenerationReasoningEffort::Medium),
        "high" => Ok(GenerationReasoningEffort::High),
        "extra_high" => Ok(GenerationReasoningEffort::ExtraHigh),
        "maximum" => Ok(GenerationReasoningEffort::Maximum),
        _ => Err(CoreError::invalid(
            "reasoning effort must be minimal, low, medium, high, extra_high, or maximum",
        )
        .into()),
    }
}

fn parse_reasoning_summary(value: &str) -> Result<GenerationReasoningSummary, FfiError> {
    match value {
        "provider_default" => Ok(GenerationReasoningSummary::ProviderDefault),
        "disabled" => Ok(GenerationReasoningSummary::Disabled),
        "automatic" => Ok(GenerationReasoningSummary::Automatic),
        "concise" => Ok(GenerationReasoningSummary::Concise),
        "detailed" => Ok(GenerationReasoningSummary::Detailed),
        _ => Err(CoreError::invalid(
            "reasoning summary must be provider_default, disabled, automatic, concise, or detailed",
        )
        .into()),
    }
}

fn parse_prompt_cache_mode(value: &str) -> Result<GenerationPromptCacheMode, FfiError> {
    match value {
        "provider_default" => Ok(GenerationPromptCacheMode::ProviderDefault),
        "automatic" => Ok(GenerationPromptCacheMode::Automatic),
        "explicit_breakpoints" => Ok(GenerationPromptCacheMode::ExplicitBreakpoints),
        "explicit_context" => Ok(GenerationPromptCacheMode::ExplicitContext),
        "disabled_if_supported" => Ok(GenerationPromptCacheMode::DisabledIfSupported),
        _ => Err(CoreError::invalid(
            "prompt cache mode must be provider_default, automatic, explicit_breakpoints, explicit_context, or disabled_if_supported",
        )
        .into()),
    }
}

fn parse_prompt_cache_ttl(
    value: &str,
    custom_seconds: Option<u32>,
) -> Result<GenerationPromptCacheTtl, FfiError> {
    match (value, custom_seconds) {
        ("provider_default", None) => Ok(GenerationPromptCacheTtl::ProviderDefault),
        ("short", None) => Ok(GenerationPromptCacheTtl::Short),
        ("long", None) => Ok(GenerationPromptCacheTtl::Long),
        ("custom_seconds", Some(seconds)) => Ok(GenerationPromptCacheTtl::CustomSeconds(seconds)),
        ("custom_seconds", None) => Err(CoreError::invalid(
            "custom prompt cache TTL requires prompt_cache_custom_ttl_seconds",
        )
        .into()),
        ("provider_default" | "short" | "long", Some(_)) => Err(CoreError::invalid(
            "prompt_cache_custom_ttl_seconds is valid only for custom_seconds TTL",
        )
        .into()),
        _ => Err(CoreError::invalid(
            "prompt cache TTL must be provider_default, short, long, or custom_seconds",
        )
        .into()),
    }
}

fn parse_api_family(value: &str) -> Result<ApiFamily, FfiError> {
    match value {
        "openai_responses" => Ok(ApiFamily::OpenAiResponses),
        "openai_chat_completions" => Ok(ApiFamily::OpenAiChatCompletions),
        "anthropic_messages" => Ok(ApiFamily::AnthropicMessages),
        "gemini_generate_content" => Ok(ApiFamily::GeminiGenerateContent),
        "ollama_native" => Ok(ApiFamily::OllamaNative),
        _ => Err(CoreError::invalid(
            "API family must be openai_responses, openai_chat_completions, anthropic_messages, gemini_generate_content, or ollama_native",
        )
        .into()),
    }
}

const fn api_family_name(family: ApiFamily) -> &'static str {
    match family {
        ApiFamily::OpenAiResponses => "openai_responses",
        ApiFamily::OpenAiChatCompletions => "openai_chat_completions",
        ApiFamily::AnthropicMessages => "anthropic_messages",
        ApiFamily::GeminiGenerateContent => "gemini_generate_content",
        ApiFamily::OllamaNative => "ollama_native",
    }
}

const fn template_source_name(source: TemplateSource) -> &'static str {
    match source {
        TemplateSource::BuiltIn => "built_in",
        TemplateSource::SignedCatalog => "signed_catalog",
        TemplateSource::UserDiscovered => "user_discovered",
    }
}

const fn map_provider_network_mode(mode: ProviderNetworkMode) -> FfiProviderNetworkMode {
    match mode {
        ProviderNetworkMode::Public => FfiProviderNetworkMode::Public,
        ProviderNetworkMode::LocalLoopback => FfiProviderNetworkMode::LocalLoopback,
        ProviderNetworkMode::ApprovedLocalNetwork => FfiProviderNetworkMode::ApprovedLocalNetwork,
    }
}

const fn unmap_provider_network_mode(mode: FfiProviderNetworkMode) -> ProviderNetworkMode {
    match mode {
        FfiProviderNetworkMode::Public => ProviderNetworkMode::Public,
        FfiProviderNetworkMode::LocalLoopback => ProviderNetworkMode::LocalLoopback,
        FfiProviderNetworkMode::ApprovedLocalNetwork => ProviderNetworkMode::ApprovedLocalNetwork,
    }
}

const fn connection_status_name(status: ConnectionStatus) -> &'static str {
    match status {
        ConnectionStatus::Untested => "untested",
        ConnectionStatus::Connected => "connected",
        ConnectionStatus::AuthFailed => "auth_failed",
        ConnectionStatus::Unavailable => "unavailable",
    }
}

fn parse_connection_status(value: &str) -> Result<ConnectionStatus, FfiError> {
    match value {
        "untested" => Ok(ConnectionStatus::Untested),
        "connected" => Ok(ConnectionStatus::Connected),
        "auth_failed" => Ok(ConnectionStatus::AuthFailed),
        "unavailable" => Ok(ConnectionStatus::Unavailable),
        _ => Err(CoreError::invalid(
            "connection status must be untested, connected, auth_failed, or unavailable",
        )
        .into()),
    }
}

const fn model_availability_name(availability: ModelAvailability) -> &'static str {
    match availability {
        ModelAvailability::Available => "available",
        ModelAvailability::MissingTemporarily => "missing_temporarily",
        ModelAvailability::DocumentedOnly => "documented_only",
        ModelAvailability::AccessDenied => "access_denied",
        ModelAvailability::Deprecated => "deprecated",
        ModelAvailability::Retired => "retired",
        ModelAvailability::Unknown => "unknown",
    }
}

fn parse_model_availability(value: &str) -> Result<ModelAvailability, FfiError> {
    match value {
        "available" => Ok(ModelAvailability::Available),
        "missing_temporarily" => Ok(ModelAvailability::MissingTemporarily),
        "documented_only" => Ok(ModelAvailability::DocumentedOnly),
        "access_denied" => Ok(ModelAvailability::AccessDenied),
        "deprecated" => Ok(ModelAvailability::Deprecated),
        "retired" => Ok(ModelAvailability::Retired),
        "unknown" => Ok(ModelAvailability::Unknown),
        _ => Err(CoreError::invalid(
            "model availability must be available, missing_temporarily, documented_only, access_denied, deprecated, retired, or unknown",
        )
        .into()),
    }
}

const fn model_metadata_source_name(source: ModelMetadataSource) -> &'static str {
    match source {
        ModelMetadataSource::Legacy => "legacy",
        ModelMetadataSource::ProviderApi => "provider_api",
        ModelMetadataSource::OfficialDocumentation => "official_documentation",
        ModelMetadataSource::SignedCatalog => "signed_catalog",
        ModelMetadataSource::CapabilityProbe => "capability_probe",
        ModelMetadataSource::UserOverride => "user_override",
    }
}

fn parse_model_metadata_source(value: &str) -> Result<ModelMetadataSource, FfiError> {
    match value {
        "legacy" => Ok(ModelMetadataSource::Legacy),
        "provider_api" => Ok(ModelMetadataSource::ProviderApi),
        "official_documentation" => Ok(ModelMetadataSource::OfficialDocumentation),
        "signed_catalog" => Ok(ModelMetadataSource::SignedCatalog),
        "capability_probe" => Ok(ModelMetadataSource::CapabilityProbe),
        "user_override" => Ok(ModelMetadataSource::UserOverride),
        _ => Err(CoreError::invalid(format!("unknown model metadata source: {value}")).into()),
    }
}

fn unmap_generation_target(target: FfiGenerationTarget) -> GenerationTarget {
    GenerationTarget {
        model_route_id: ModelRouteId::from(target.model_route_id),
        generation_preset_id: GenerationPresetId::from(target.generation_preset_id),
    }
}

fn map_settings(settings: AppSettings) -> FfiAppSettings {
    FfiAppSettings {
        preserve_partial_generations: settings.preserve_partial_generations,
        selected_provider_profile_id: settings.selected_provider_profile_id,
        selected_model_route_id: settings
            .selected_model_route_id
            .map(ModelRouteId::into_inner),
        selected_generation_preset_id: settings
            .selected_generation_preset_id
            .map(GenerationPresetId::into_inner),
    }
}

fn unmap_settings(settings: FfiAppSettings) -> AppSettings {
    AppSettings {
        preserve_partial_generations: settings.preserve_partial_generations,
        selected_provider_profile_id: settings.selected_provider_profile_id,
        selected_model_route_id: settings.selected_model_route_id.map(Into::into),
        selected_generation_preset_id: settings.selected_generation_preset_id.map(Into::into),
    }
}

fn map_database_stats(stats: DatabaseStats) -> FfiDatabaseStats {
    FfiDatabaseStats {
        characters: stats.characters,
        conversations: stats.conversations,
        messages: stats.messages,
        pending_imports: stats.pending_imports,
    }
}

fn map_chat_event(event: ChatEvent) -> FfiChatEvent {
    let mut text = None;
    let mut tool_call_id = None;
    let mut tool_name = None;
    let mut tool_arguments_delta = None;
    let mut message_id = None;
    let mut message_status = None;
    let mut error_code = None;
    let mut error_message = None;
    let mut usage_input_tokens = None;
    let mut usage_cached_read_tokens = None;
    let mut usage_cached_write_tokens = None;
    let mut usage_output_tokens = None;
    let mut usage_reasoning_tokens = None;
    let mut usage_tool_tokens = None;
    let mut usage_provider_raw_summary = None;
    let kind = match event.kind {
        ChatEventKind::GenerationStarted => "generation_started",
        ChatEventKind::ReasoningDelta(delta) => {
            text = Some(delta);
            "reasoning_delta"
        }
        ChatEventKind::TextDelta(delta) => {
            text = Some(delta);
            "text_delta"
        }
        ChatEventKind::ToolCallStarted { id, name } => {
            tool_call_id = Some(id.into_inner());
            tool_name = Some(name.into_inner());
            "tool_call_started"
        }
        ChatEventKind::ToolCallArgumentsDelta { id, delta } => {
            tool_call_id = Some(id.into_inner());
            tool_arguments_delta = Some(delta.into_inner());
            "tool_call_arguments_delta"
        }
        ChatEventKind::ToolCallCompleted { id } => {
            tool_call_id = Some(id.into_inner());
            "tool_call_completed"
        }
        ChatEventKind::UsageUpdated(usage) => {
            usage_input_tokens = usage.input_tokens;
            usage_cached_read_tokens = usage.cached_read_tokens;
            usage_cached_write_tokens = usage.cached_write_tokens;
            usage_output_tokens = usage.output_tokens;
            usage_reasoning_tokens = usage.reasoning_tokens;
            usage_tool_tokens = usage.tool_tokens;
            usage_provider_raw_summary = usage
                .provider_raw_summary
                .map(lorepia_core::BoundedJson::into_inner);
            "usage_updated"
        }
        ChatEventKind::MessageCommitted {
            message_id: committed_message_id,
            status,
        } => {
            message_id = Some(committed_message_id.0);
            message_status = Some(map_message_status(status).to_owned());
            "message_committed"
        }
        ChatEventKind::GenerationCancelled => "generation_cancelled",
        ChatEventKind::GenerationFailed { code, message } => {
            error_code = Some(code);
            error_message = Some(message);
            "generation_failed"
        }
        ChatEventKind::GenerationFinished => "generation_finished",
    };
    FfiChatEvent {
        event_version: event.event_version,
        generation_id: event.generation_id.0,
        conversation_id: event.conversation_id.0,
        branch_id: event.branch_id.map(|id| id.0),
        assistant_message_id: event.assistant_message_id.map(|id| id.0),
        sequence: event.sequence,
        emitted_at: event.emitted_at.to_rfc3339(),
        kind: kind.to_owned(),
        text,
        tool_call_id,
        tool_name,
        tool_arguments_delta,
        message_id,
        message_status,
        error_code,
        error_message,
        usage_input_tokens,
        usage_cached_read_tokens,
        usage_cached_write_tokens,
        usage_output_tokens,
        usage_reasoning_tokens,
        usage_tool_tokens,
        usage_provider_raw_summary,
    }
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        io::{Read, Write},
        net::{TcpListener, TcpStream},
        sync::mpsc,
        thread,
        time::{Duration, Instant},
    };

    use lorepia_core::{
        BoundedJson, CoreErrorCode, GenerationUsage, MessageId, MessageRole, MessageStatus,
        ToolCallArgumentsDelta, ToolCallId, ToolName,
    };
    use tempfile::{NamedTempFile, tempdir};

    use super::*;

    #[test]
    fn discovery_assistant_resume_boundary_is_closed_and_typed() {
        let mapped =
            map_discovery_assistant_resume_boundary(ProviderDiscoveryAssistantResumeBoundary {
                checkpoint: Some(DiscoveryAssistantCheckpoint::AwaitingToolResult),
                action: ProviderDiscoveryAssistantResumeAction::ResumeCoreHostAction,
                questions: Vec::new(),
                draft_review: None,
            });
        assert_eq!(
            mapped.checkpoint,
            Some(FfiDiscoveryAssistantCheckpoint::AwaitingToolResult)
        );
        assert_eq!(
            mapped.action,
            FfiDiscoveryAssistantResumeAction::ResumeCoreHostAction
        );
        assert!(mapped.questions.is_empty());
        assert!(mapped.draft_review.is_none());

        assert_eq!(
            [
                ProviderDiscoveryAssistantResumeAction::ApproveConsent,
                ProviderDiscoveryAssistantResumeAction::RunAssistant,
                ProviderDiscoveryAssistantResumeAction::WaitForAssistantOutcome,
                ProviderDiscoveryAssistantResumeAction::ResumeCoreHostAction,
                ProviderDiscoveryAssistantResumeAction::SupplyMoreEvidence,
                ProviderDiscoveryAssistantResumeAction::ApproveRetry,
                ProviderDiscoveryAssistantResumeAction::ReviewDraft,
                ProviderDiscoveryAssistantResumeAction::RestartInterrupted,
                ProviderDiscoveryAssistantResumeAction::ResolveUnknownOutcome,
            ]
            .map(map_discovery_assistant_resume_action),
            [
                FfiDiscoveryAssistantResumeAction::ApproveConsent,
                FfiDiscoveryAssistantResumeAction::RunAssistant,
                FfiDiscoveryAssistantResumeAction::WaitForAssistantOutcome,
                FfiDiscoveryAssistantResumeAction::ResumeCoreHostAction,
                FfiDiscoveryAssistantResumeAction::SupplyMoreEvidence,
                FfiDiscoveryAssistantResumeAction::ApproveRetry,
                FfiDiscoveryAssistantResumeAction::ReviewDraft,
                FfiDiscoveryAssistantResumeAction::RestartInterrupted,
                FfiDiscoveryAssistantResumeAction::ResolveUnknownOutcome,
            ]
        );
    }

    #[test]
    fn discovery_connection_options_survive_restart_projection_exactly() {
        let options = ProviderDiscoveryConnectionOptions {
            values: vec![ConnectionConfigEntry {
                key: "tenant".to_owned(),
                value: ConnectionConfigValue::Text("seoul".to_owned()),
            }],
            api_base_path: Some(EndpointPath::parse("/v1").expect("base path")),
            timeout_seconds: 45,
            network_mode: ProviderNetworkMode::ApprovedLocalNetwork,
            local_network_approval: Some(ProviderLocalNetworkApproval {
                origin: CanonicalOrigin::parse("http://192.168.1.20:11434").expect("local origin"),
                addresses: vec!["192.168.1.20".parse().expect("local address")],
            }),
        };

        let mapped = map_provider_discovery_connection_options(options.clone());
        assert_eq!(mapped.api_base_path.as_deref(), Some("/v1"));
        assert_eq!(mapped.timeout_seconds, 45);
        assert_eq!(
            mapped.network_mode,
            FfiProviderNetworkMode::ApprovedLocalNetwork
        );
        let approval = mapped
            .local_network_approval
            .as_ref()
            .expect("local approval");
        assert_eq!(approval.origin, "http://192.168.1.20:11434");
        assert_eq!(approval.addresses, ["192.168.1.20".to_owned()]);
        assert_eq!(
            unmap_provider_discovery_connection_options(mapped).expect("round trip"),
            options
        );
    }

    #[test]
    fn native_binding_declares_no_opaque_reasoning_payload_dto() {
        let source = include_str!("lib.rs");
        for declaration in [
            ["pub enum FfiOpaque", "ReasoningState"].concat(),
            ["pub struct FfiOpaque", "ReasoningState"].concat(),
            ["pub type FfiOpaque", "ReasoningState"].concat(),
        ] {
            assert!(
                !source.contains(&declaration),
                "provider-native opaque reasoning payloads are internal-only"
            );
        }

        let preview = FfiRequestPreview {
            redaction_version: 1,
            method: "POST".to_owned(),
            origin: "https://api.openai.com".to_owned(),
            path: "/v1/responses".to_owned(),
            header_names: Vec::new(),
            query_parameter_names: Vec::new(),
            body_shape: None,
            body_truncated: false,
            includes_private_message: false,
            includes_credential_value: false,
            includes_opaque_reasoning_state: false,
        };
        assert!(!preview.includes_opaque_reasoning_state);
    }

    fn assert_bytes_absent_from_tree(root: &std::path::Path, canary: &[u8]) {
        for entry in fs::read_dir(root).expect("read test data root") {
            let path = entry.expect("read data-root entry").path();
            if path.is_dir() {
                assert_bytes_absent_from_tree(&path, canary);
                continue;
            }
            let bytes = fs::read(&path).expect("read test data file");
            assert!(
                !bytes.windows(canary.len()).any(|window| window == canary),
                "credential canary persisted in {}",
                path.display()
            );
        }
    }

    #[test]
    fn curl_inspection_uses_expiring_take_once_credential_handoff() {
        let root = tempdir().expect("temp root");
        let core = LorepiaCore::open(FfiCoreConfig {
            data_root: root.path().to_string_lossy().into_owned(),
        })
        .expect("open");
        let credential = b"sk-curl-canary-never-log".to_vec();
        let raw_curl = format!(
            "curl -X POST 'https://api.openai.com/v1/chat/completions' \
             -H 'Authorization: Bearer {}' \
             -H 'Content-Type: application/json' \
             -d '{{\"model\":\"example-model\",\"messages\":[],\"stream\":true}}'",
            String::from_utf8_lossy(&credential)
        );
        let inspection = core
            .inspect_provider_curl(
                raw_curl,
                FfiProviderNetworkPolicy {
                    network_mode: FfiProviderNetworkMode::Public,
                    local_network_approval: None,
                },
            )
            .expect("inspect");

        let debug = format!("{inspection:?}");
        assert!(
            !debug
                .as_bytes()
                .windows(credential.len())
                .any(|window| window == credential.as_slice())
        );
        let handoff_id = inspection
            .credential_handoff_id
            .expect("credential handoff");
        assert_eq!(
            core.take_provider_curl_credential(handoff_id.clone())
                .expect("take"),
            Some(credential.clone())
        );
        assert_eq!(
            core.take_provider_curl_credential(handoff_id)
                .expect("second take"),
            None
        );
        assert_bytes_absent_from_tree(root.path(), &credential);
    }

    #[test]
    fn provider_catalog_diff_is_typed_and_bucketed_for_native_review() {
        let template_entry = |id: &str, change: CatalogChangeKind| ManifestDiffDto {
            provider_template_id: ProviderTemplateId::from(id),
            change,
            previous_manifest_version: (change != CatalogChangeKind::Added).then_some(1),
            next_manifest_version: (change != CatalogChangeKind::Removed).then_some(2),
            previous_sha256: (change != CatalogChangeKind::Added).then(|| format!("{id}-old")),
            next_sha256: (change != CatalogChangeKind::Removed).then(|| format!("{id}-new")),
            changed_sections: vec![
                ManifestChangedSection::Authentication,
                ManifestChangedSection::Endpoints,
            ],
        };
        let model_entry = |id: &str, change: CatalogChangeKind| ModelMetadataDiffDto {
            model_entry_id: id.to_owned(),
            provider_template_id: ProviderTemplateId::from("provider"),
            change,
            previous_metadata_version: (change != CatalogChangeKind::Added).then_some(3),
            next_metadata_version: (change != CatalogChangeKind::Removed).then_some(4),
            previous_sha256: (change != CatalogChangeKind::Added).then(|| format!("{id}-old")),
            next_sha256: (change != CatalogChangeKind::Removed).then(|| format!("{id}-new")),
            changed_sections: vec![
                ModelChangedSection::Capabilities,
                ModelChangedSection::Parameters,
            ],
        };
        let mapped = map_provider_catalog_diff(CatalogDiffDto {
            diff_schema_version: 1,
            from_revision: 7,
            to_revision: 8,
            manifest_changes: vec![
                template_entry("provider-added", CatalogChangeKind::Added),
                template_entry("provider-changed", CatalogChangeKind::Updated),
                template_entry("provider-removed", CatalogChangeKind::Removed),
            ],
            model_changes: vec![
                model_entry("model-added", CatalogChangeKind::Added),
                model_entry("model-changed", CatalogChangeKind::Updated),
                model_entry("model-removed", CatalogChangeKind::Removed),
            ],
        });

        assert_eq!(mapped.diff_schema_version, 1);
        assert_eq!((mapped.from_revision, mapped.to_revision), (7, 8));
        assert_eq!(
            mapped.added_provider_templates[0].provider_template_id,
            "provider-added"
        );
        assert!(
            mapped.added_provider_templates[0]
                .previous_manifest_version
                .is_none()
        );
        assert_eq!(
            mapped.changed_provider_templates[0].changed_sections,
            [
                FfiProviderCatalogTemplateChangedSection::Authentication,
                FfiProviderCatalogTemplateChangedSection::Endpoints,
            ]
        );
        assert!(
            mapped.removed_provider_templates[0]
                .next_manifest_version
                .is_none()
        );
        assert_eq!(mapped.added_models[0].model_entry_id, "model-added");
        assert_eq!(
            mapped.changed_models[0].changed_sections,
            [
                FfiProviderCatalogModelChangedSection::Capabilities,
                FfiProviderCatalogModelChangedSection::Parameters,
            ]
        );
        assert_eq!(mapped.removed_models[0].model_entry_id, "model-removed");
        assert!(mapped.removed_models[0].next_sha256.is_none());
    }

    fn read_request(stream: &mut TcpStream) -> String {
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .expect("request timeout");
        let mut request = Vec::new();
        let mut buffer = [0_u8; 4_096];
        loop {
            let read = stream.read(&mut buffer).expect("read request");
            if read == 0 {
                return String::from_utf8_lossy(&request).into_owned();
            }
            request.extend_from_slice(&buffer[..read]);
            let Some(header_end) = request.windows(4).position(|value| value == b"\r\n\r\n") else {
                continue;
            };
            let headers = String::from_utf8_lossy(&request[..header_end]);
            let content_length = headers
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().ok())
                        .flatten()
                })
                .unwrap_or(0);
            if request.len() >= header_end + 4 + content_length {
                return String::from_utf8_lossy(&request).into_owned();
            }
        }
    }

    fn spawn_completed_provider() -> (String, mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind provider");
        let address = listener.local_addr().expect("provider address");
        let (request_sender, request_receiver) = mpsc::channel();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept provider request");
            let request = read_request(&mut stream);
            request_sender
                .send(request)
                .expect("record provider request");
            let body = concat!(
                "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"응답😀\"}}]}\n\n",
                "data: {\"choices\":[{\"index\":0,\"delta\":{},",
                "\"finish_reason\":\"stop\"}]}\n\n",
                "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":9,\"completion_tokens\":2}}\n\n",
                "data: [DONE]\n\n"
            );
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            )
            .expect("write provider response");
        });
        (format!("http://{address}/v1"), request_receiver)
    }

    fn spawn_stalling_provider() -> (String, mpsc::Receiver<String>, mpsc::Sender<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind provider");
        let address = listener.local_addr().expect("provider address");
        let (ready_sender, ready_receiver) = mpsc::channel();
        let (stop_sender, stop_receiver) = mpsc::channel();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept provider request");
            let request = read_request(&mut stream);
            let event =
                "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"부분😀\"}}]}\n\n";
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n{:X}\r\n{}\r\n",
                event.len(),
                event
            )
            .expect("write provider chunk");
            stream.flush().expect("flush provider chunk");
            ready_sender.send(request).expect("provider ready");
            let _ = stop_receiver.recv_timeout(Duration::from_secs(5));
            let _ = stream.write_all(b"0\r\n\r\n");
        });
        (format!("http://{address}/v1"), ready_receiver, stop_sender)
    }

    fn assert_post_request_path(request: &str, expected_path: &str) {
        let request_line = request.lines().next().expect("HTTP request line");
        let mut parts = request_line.split_ascii_whitespace();
        assert_eq!(parts.next(), Some("POST"));
        assert_eq!(parts.next(), Some(expected_path));
        assert_eq!(parts.next(), Some("HTTP/1.1"));
        assert_eq!(parts.next(), None);
    }

    fn import_character(
        core: &LorepiaCore,
        root: &std::path::Path,
        name: &str,
        description: &str,
    ) -> FfiCharacter {
        let mut card = NamedTempFile::new_in(root).expect("card");
        write!(
            card,
            r#"{{"spec":"chara_card_v3","data":{{"name":"{name}","description":"{description}"}}}}"#
        )
        .expect("write");
        card.flush().expect("flush");
        let inspection = core
            .inspect_import(card.path().to_string_lossy().into_owned())
            .expect("inspect");
        core.commit_import(inspection.id).expect("commit")
    }

    fn poll_until(
        core: &LorepiaCore,
        generation_id: &str,
        terminal_kind: &str,
    ) -> Vec<FfiChatEvent> {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut received = Vec::new();
        loop {
            let batch = core.poll_events(64).expect("poll events");
            received.extend(
                batch
                    .events
                    .into_iter()
                    .filter(|event| event.generation_id == generation_id),
            );
            if received.iter().any(|event| event.kind == terminal_kind) {
                return received;
            }
            assert!(Instant::now() < deadline, "{terminal_kind} did not arrive");
            thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn opens_core_and_maps_version_health_and_empty_event_batch() {
        let root = tempdir().expect("temp root");
        let core = LorepiaCore::open(FfiCoreConfig {
            data_root: root.path().to_string_lossy().into_owned(),
        })
        .expect("open");
        let health = core.health_check().expect("health");
        assert!(health.database_open);
        assert_eq!(health.core_version, core_version());
        let versions = version_info();
        assert_eq!(versions.core_version, core_version());
        assert_eq!(versions.core_api_version, lorepia_core::CORE_API_VERSION);
        assert_eq!(versions.core_api_version, 8);
        assert_eq!(versions.binding_api_version, BINDING_API_VERSION);
        assert_eq!(versions.binding_api_version, 8);
        assert_eq!(PROVIDER_DISCOVERY_SNAPSHOT_SCHEMA_VERSION, 3);
        assert_eq!(versions.chat_event_version, CHAT_EVENT_VERSION);
        assert_eq!(versions.chat_event_version, 4);
        assert!(core.poll_events(16).expect("poll").events.is_empty());
        let stats = core.database_stats().expect("database stats");
        assert_eq!(stats.characters, 0);
        assert_eq!(stats.conversations, 0);
        assert_eq!(stats.messages, 0);
        assert_eq!(stats.pending_imports, 0);
    }

    #[test]
    fn exposes_import_character_conversation_and_discard_flows() {
        let root = tempdir().expect("temp root");
        let core = LorepiaCore::open(FfiCoreConfig {
            data_root: root.path().to_string_lossy().into_owned(),
        })
        .expect("open");
        let mut card = NamedTempFile::new_in(root.path()).expect("card");
        write!(
            card,
            r#"{{"spec":"chara_card_v3","data":{{"name":"Binding Test","description":"Synthetic"}}}}"#
        )
        .expect("write");
        card.flush().expect("flush");

        let inspection = core
            .inspect_import(card.path().to_string_lossy().into_owned())
            .expect("inspect");
        assert_eq!(inspection.content_kind, "character_card_v3");
        assert!(inspection.is_allowed);
        assert_eq!(inspection.display_name, "Binding Test");
        assert!(inspection.representative_image.is_none());
        assert!(inspection.unsupported_optional_fields.is_empty());
        let character = core.commit_import(inspection.id).expect("commit");
        assert_eq!(
            core.get_character(character.id.clone()).expect("get").id,
            character.id
        );
        assert_eq!(core.list_characters().expect("list").len(), 1);

        let conversation = core
            .open_conversation(character.id)
            .expect("open conversation");
        assert_eq!(
            core.list_conversations().expect("conversations")[0].id,
            conversation.id
        );
        assert!(
            core.list_messages(conversation.id)
                .expect("messages")
                .is_empty()
        );

        let second = core
            .inspect_import(card.path().to_string_lossy().into_owned())
            .expect("second inspect");
        core.discard_import(second.id).expect("discard");
        assert!(
            fs::read_dir(root.path().join("staging"))
                .expect("staging")
                .next()
                .is_none()
        );
    }

    #[test]
    fn exposes_multiple_rooms_persisted_modes_and_branch_selection() {
        let root = tempdir().expect("temp root");
        let core = LorepiaCore::open(FfiCoreConfig {
            data_root: root.path().to_string_lossy().into_owned(),
        })
        .expect("open");
        let character = import_character(&core, root.path(), "분기 캐릭터", "합성 테스트");

        let chat = core
            .create_conversation(character.id.clone(), "대화방".to_owned(), "chat".to_owned())
            .expect("create chat room");
        let story = core
            .create_conversation(
                character.id.clone(),
                "스토리방".to_owned(),
                "story".to_owned(),
            )
            .expect("create story room");

        assert_ne!(chat.id, story.id);
        assert_eq!(
            core.list_conversations_for_character(character.id)
                .expect("character rooms")
                .len(),
            2
        );
        assert_eq!(
            core.get_conversation(story.id.clone())
                .expect("get story room")
                .title,
            "스토리방"
        );

        let initial_state = core
            .get_conversation_state(story.id.clone())
            .expect("initial state");
        assert_eq!(initial_state.selected_mode, "story");
        let initial_branches = core
            .list_conversation_branches(story.id.clone())
            .expect("initial branches");
        assert_eq!(initial_branches.len(), 1);
        assert_eq!(
            initial_branches[0].id, initial_state.active_branch_id,
            "new rooms select their root branch"
        );

        let fork = core
            .create_conversation_branch(story.id.clone(), None, Some("다른 시작".to_owned()))
            .expect("create branch");
        assert_eq!(fork.conversation_id, story.id);
        assert_eq!(fork.title.as_deref(), Some("다른 시작"));
        assert!(fork.fork_message_id.is_none());
        assert!(fork.head_message_id.is_none());
        assert!(
            core.list_branch_messages(fork.id.clone())
                .expect("empty branch")
                .is_empty()
        );

        let selected = core
            .select_conversation_branch(story.id.clone(), fork.id.clone())
            .expect("select branch");
        assert_eq!(selected.active_branch_id, fork.id);
        assert_eq!(selected.selected_mode, "story");
        let chat_mode = core
            .set_conversation_mode(story.id.clone(), "chat".to_owned())
            .expect("set chat mode");
        assert_eq!(chat_mode.selected_mode, "chat");

        for invalid in ["Story", " story", "", "unknown"] {
            let error = core
                .set_conversation_mode(story.id.clone(), invalid.to_owned())
                .expect_err("reject unsupported mode");
            let FfiError::Core { code, .. } = error;
            assert_eq!(code, "invalid_input");
        }
        assert_eq!(
            core.get_conversation_state(story.id)
                .expect("unchanged mode")
                .selected_mode,
            "chat"
        );
    }

    #[test]
    fn maps_representative_image_and_unsupported_optional_fields() {
        let root = tempdir().expect("temp root");
        let core = LorepiaCore::open(FfiCoreConfig {
            data_root: root.path().to_string_lossy().into_owned(),
        })
        .expect("open");
        let package = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../testdata/packages/with-avatar.charx");
        let package_inspection = core
            .inspect_import(package.to_string_lossy().into_owned())
            .expect("inspect package");
        let image = package_inspection
            .representative_image
            .expect("representative image");
        assert_eq!(image.logical_asset_id, "assets/avatar.png");
        assert_eq!(image.media_type, "image/png");
        assert_eq!(image.size_bytes, 70);
        core.discard_import(package_inspection.id)
            .expect("discard package");

        let mut card = NamedTempFile::new_in(root.path()).expect("card");
        write!(
            card,
            r#"{{"spec":"chara_card_v3","data":{{
                "name":"Optional",
                "description":"Consumed",
                "personality":"Unused",
                "creator":"Synthetic"
            }}}}"#
        )
        .expect("write");
        card.flush().expect("flush");
        let card_inspection = core
            .inspect_import(card.path().to_string_lossy().into_owned())
            .expect("inspect card");
        assert!(card_inspection.representative_image.is_none());
        assert_eq!(
            card_inspection.unsupported_optional_fields,
            ["creator", "personality"]
        );
        core.discard_import(card_inspection.id)
            .expect("discard card");
    }

    #[test]
    fn exposes_provider_profiles_and_settings() {
        let root = tempdir().expect("temp root");
        let core = LorepiaCore::open(FfiCoreConfig {
            data_root: root.path().to_string_lossy().into_owned(),
        })
        .expect("open");
        let profile = FfiProviderProfile {
            id: "local".to_owned(),
            display_name: "Local Test".to_owned(),
            base_url: "https://api.openai.com/v1".to_owned(),
            model: "synthetic".to_owned(),
            timeout_seconds: 15,
        };
        assert_eq!(
            core.upsert_provider_profile(profile)
                .expect("save profile")
                .id,
            "local"
        );
        assert_eq!(core.list_provider_profiles().expect("profiles").len(), 1);

        let settings = core
            .update_settings(FfiAppSettings {
                preserve_partial_generations: false,
                selected_provider_profile_id: Some("local".to_owned()),
                selected_model_route_id: None,
                selected_generation_preset_id: None,
            })
            .expect("update settings");
        assert!(!settings.preserve_partial_generations);
        assert_eq!(
            settings.selected_provider_profile_id.as_deref(),
            Some("local")
        );
        core.delete_provider_profile("local".to_owned())
            .expect("delete profile");
        assert!(
            core.get_settings()
                .expect("settings")
                .selected_provider_profile_id
                .is_none()
        );
    }

    #[test]
    fn maps_typed_connection_fields_and_complete_parameter_specs() {
        let root = tempdir().expect("temp root");
        let core = LorepiaCore::open(FfiCoreConfig {
            data_root: root.path().to_string_lossy().into_owned(),
        })
        .expect("open");
        let templates = core.list_provider_templates().expect("templates");
        let openai = templates
            .iter()
            .find(|template| template.id == "openai-responses-v1")
            .expect("OpenAI template");
        assert_eq!(openai.auth_binding, FfiAuthBinding::BearerHeader);
        assert!(openai.requires_credential);
        assert!(openai.supports_model_listing);
        assert!(openai.connection_fields.iter().any(|field| {
            field.key == "api_key"
                && field.value_type == FfiConnectionFieldType::Credential
                && field.required
        }));
        assert!(openai.parameters.iter().any(|parameter| {
            parameter.id == "temperature"
                && parameter.value_type == FfiParameterType::Number
                && parameter.provider_mapping.target == FfiProviderParameterTarget::RequestBody
        }));

        let mapped = map_parameter_spec(ParameterSpec {
            id: "response_style".into(),
            label_key: "provider.parameter.response_style".to_owned(),
            description_key: Some("provider.parameter.response_style.description".to_owned()),
            value_type: ParameterType::Enum,
            allowed_values: vec![ParameterChoice {
                value: ParameterLiteral::Enum("concise".to_owned()),
                label_key: "provider.parameter.response_style.concise".to_owned(),
            }],
            minimum: None,
            maximum: None,
            step: None,
            default_mode: ParameterDefaultMode::ExplicitRequired,
            visibility: Some(ParameterCondition {
                parameter_id: "reasoning".into(),
                operator: ParameterConditionOperator::Equals,
                value: ParameterLiteral::Boolean(true),
            }),
            conflicts: vec![ParameterConflict {
                parameter_id: "verbosity".into(),
                kind: ParameterConflictKind::MutuallyExclusive,
                message_key: "provider.parameter.response_style.conflict".to_owned(),
            }],
            provider_mapping: ProviderParameterMapping {
                target: ProviderParameterTarget::RequestHeader,
                field_name: "x-response-style".to_owned(),
            },
            level: UiParameterLevel::Advanced,
        });
        assert_eq!(mapped.id, "response_style");
        assert_eq!(mapped.value_type, FfiParameterType::Enum);
        assert_eq!(
            mapped.allowed_values,
            [FfiParameterChoice {
                value: FfiParameterLiteral::Enum {
                    value: "concise".to_owned(),
                },
                label_key: "provider.parameter.response_style.concise".to_owned(),
            }]
        );
        assert_eq!(
            mapped.visibility,
            Some(FfiParameterCondition {
                parameter_id: "reasoning".to_owned(),
                operator: FfiParameterConditionOperator::Equals,
                value: FfiParameterLiteral::Boolean { value: true },
            })
        );
        assert_eq!(
            mapped.conflicts,
            [FfiParameterConflict {
                parameter_id: "verbosity".to_owned(),
                kind: FfiParameterConflictKind::MutuallyExclusive,
                message_key: "provider.parameter.response_style.conflict".to_owned(),
            }]
        );
        assert_eq!(
            mapped.provider_mapping,
            FfiProviderParameterMapping {
                target: FfiProviderParameterTarget::RequestHeader,
                field_name: "x-response-style".to_owned(),
            }
        );
        assert_eq!(mapped.level, FfiUiParameterLevel::Advanced);
    }

    #[test]
    fn round_trips_every_typed_configuration_and_parameter_literal_variant() {
        let configuration_values = vec![
            ConnectionConfigValue::Text(String::new()),
            ConnectionConfigValue::Integer(i64::MIN),
            ConnectionConfigValue::Boolean(false),
        ];
        for value in configuration_values {
            assert_eq!(
                unmap_connection_config_value(map_connection_config_value(value.clone())),
                value
            );
        }

        let literals = vec![
            ParameterLiteral::Boolean(false),
            ParameterLiteral::Integer(i64::MIN),
            ParameterLiteral::Number(-0.0),
            ParameterLiteral::String(String::new()),
            ParameterLiteral::Enum("automatic".to_owned()),
            ParameterLiteral::StringList(Vec::new()),
            ParameterLiteral::JsonSchema("{}".to_owned()),
            ParameterLiteral::StopSequenceList(vec!["끝".to_owned(), "😀".to_owned()]),
            ParameterLiteral::ToolPolicy(ToolPolicy::Required),
        ];
        for literal in literals {
            let round_trip = unmap_parameter_literal(map_parameter_literal(literal.clone()));
            assert_eq!(round_trip, literal);
            if let ParameterLiteral::Number(value) = round_trip {
                assert_eq!(value.to_bits(), (-0.0_f64).to_bits());
            }
        }

        for state in [
            ParameterValueState::InheritProviderDefault,
            ParameterValueState::Explicit(ParameterLiteral::StringList(Vec::new())),
        ] {
            assert_eq!(
                unmap_parameter_value_state(map_parameter_value_state(state.clone())),
                state
            );
        }
    }

    #[test]
    #[allow(clippy::too_many_lines)]
    fn round_trips_full_connection_route_and_preset_records() {
        let connection = FfiProviderConnection {
            id: "connection".to_owned(),
            template_id: "template".to_owned(),
            template_version: 7,
            display_name: "Typed connection".to_owned(),
            api_origin: "https://api.example.test".to_owned(),
            api_base_path: Some("/v2".to_owned()),
            network_mode: FfiProviderNetworkMode::Public,
            local_network_approval: None,
            values: vec![
                FfiConnectionConfigEntry {
                    key: "tenant".to_owned(),
                    value: FfiConnectionConfigValue::Text {
                        value: "seoul".to_owned(),
                    },
                },
                FfiConnectionConfigEntry {
                    key: "retries".to_owned(),
                    value: FfiConnectionConfigValue::Integer { value: 3 },
                },
                FfiConnectionConfigEntry {
                    key: "stream".to_owned(),
                    value: FfiConnectionConfigValue::Boolean { value: true },
                },
            ],
            credential_slot_ready: true,
            credential_scope: Some(FfiCredentialScope {
                allowed_origins: vec!["https://api.example.test".to_owned()],
                auth_binding: FfiAuthBinding::HeaderApiKey {
                    header_name: "x-api-key".to_owned(),
                },
                redirect_policy: FfiCredentialRedirectPolicy::FollowWithoutCredential,
            }),
            approved_credential_origins: vec!["https://api.example.test".to_owned()],
            timeout_seconds: 42,
            status: "connected".to_owned(),
            created_at: "2026-07-31T00:00:00+00:00".to_owned(),
            updated_at: "2026-07-31T01:00:00+00:00".to_owned(),
        };
        assert_eq!(
            map_provider_connection(
                unmap_provider_connection(connection.clone()).expect("unmap connection")
            ),
            connection
        );

        let route = FfiModelRoute {
            id: "route".to_owned(),
            connection_id: "connection".to_owned(),
            api_family: "anthropic_messages".to_owned(),
            model_id: "model-2026".to_owned(),
            display_name: Some("Typed model".to_owned()),
            route_config: FfiModelRouteConfig {
                deployment_id: Some("deployment".to_owned()),
                region: Some("ap-northeast-2".to_owned()),
                endpoint_path: Some("/v2/messages".to_owned()),
                values: vec![FfiConnectionConfigEntry {
                    key: "priority".to_owned(),
                    value: FfiConnectionConfigValue::Integer { value: 5 },
                }],
            },
            availability: "documented_only".to_owned(),
            miss_count: 2,
            raw_metadata_json: Some("{\"context_window\":128000}".to_owned()),
            metadata_source: "official_documentation".to_owned(),
            metadata_observed_at: Some("2026-07-31T01:30:00+00:00".to_owned()),
            last_reconciled_sync_job_id: Some("sync-check".to_owned()),
            metadata_sync_job_id: Some("sync-metadata".to_owned()),
            first_seen_at: "2026-07-31T00:00:00+00:00".to_owned(),
            last_seen_at: Some("2026-07-31T02:00:00+00:00".to_owned()),
        };
        assert_eq!(
            map_model_route(unmap_model_route(route.clone()).expect("unmap route")),
            route
        );

        let preset = FfiGenerationPreset {
            id: "preset".to_owned(),
            model_route_id: "route".to_owned(),
            display_name: "Typed preset".to_owned(),
            parameter_value_count: 3,
            values: vec![
                FfiParameterValue {
                    parameter_id: "temperature".to_owned(),
                    state: FfiParameterValueState::Explicit {
                        value: FfiParameterLiteral::Number { value: 0.25 },
                    },
                },
                FfiParameterValue {
                    parameter_id: "stop".to_owned(),
                    state: FfiParameterValueState::Explicit {
                        value: FfiParameterLiteral::StopSequenceList {
                            values: vec!["END".to_owned()],
                        },
                    },
                },
                FfiParameterValue {
                    parameter_id: "tools".to_owned(),
                    state: FfiParameterValueState::InheritProviderDefault,
                },
            ],
            reasoning_mode: "enabled".to_owned(),
            reasoning_effort: Some("extra_high".to_owned()),
            reasoning_budget_tokens: Some(4_096),
            reasoning_summary: "detailed".to_owned(),
            preserve_opaque_reasoning_state: false,
            prompt_cache_mode: "explicit_context".to_owned(),
            prompt_cache_ttl: "custom_seconds".to_owned(),
            prompt_cache_custom_ttl_seconds: Some(900),
            prompt_cache_context_reference: Some("context-v1".to_owned()),
            created_at: "2026-07-31T00:00:00+00:00".to_owned(),
            updated_at: "2026-07-31T03:00:00+00:00".to_owned(),
        };
        assert_eq!(
            map_generation_preset(unmap_generation_preset(preset.clone()).expect("unmap preset")),
            preset
        );
    }

    #[test]
    fn rejects_inconsistent_round_trip_summary_fields() {
        let connection = FfiProviderConnection {
            id: "connection".to_owned(),
            template_id: "template".to_owned(),
            template_version: 1,
            display_name: "Invalid".to_owned(),
            api_origin: "https://api.example.test".to_owned(),
            api_base_path: None,
            network_mode: FfiProviderNetworkMode::Public,
            local_network_approval: None,
            values: Vec::new(),
            credential_slot_ready: true,
            credential_scope: Some(FfiCredentialScope {
                allowed_origins: vec!["https://api.example.test".to_owned()],
                auth_binding: FfiAuthBinding::BearerHeader,
                redirect_policy: FfiCredentialRedirectPolicy::Deny,
            }),
            approved_credential_origins: Vec::new(),
            timeout_seconds: 30,
            status: "untested".to_owned(),
            created_at: "2026-07-31T00:00:00+00:00".to_owned(),
            updated_at: "2026-07-31T00:00:00+00:00".to_owned(),
        };
        let FfiError::Core { code, .. } =
            unmap_provider_connection(connection).expect_err("mismatched credential scope");
        assert_eq!(code, "invalid_input");

        let preset = FfiGenerationPreset {
            id: "preset".to_owned(),
            model_route_id: "route".to_owned(),
            display_name: "Invalid".to_owned(),
            parameter_value_count: 1,
            values: Vec::new(),
            reasoning_mode: "provider_default".to_owned(),
            reasoning_effort: None,
            reasoning_budget_tokens: None,
            reasoning_summary: "provider_default".to_owned(),
            preserve_opaque_reasoning_state: true,
            prompt_cache_mode: "provider_default".to_owned(),
            prompt_cache_ttl: "custom_seconds".to_owned(),
            prompt_cache_custom_ttl_seconds: None,
            prompt_cache_context_reference: None,
            created_at: "2026-07-31T00:00:00+00:00".to_owned(),
            updated_at: "2026-07-31T00:00:00+00:00".to_owned(),
        };
        let FfiError::Core { code, .. } =
            unmap_generation_preset(preset).expect_err("mismatched parameter count");
        assert_eq!(code, "invalid_input");

        let FfiError::Core { code, .. } = unmap_auth_binding(FfiAuthBinding::HeaderApiKey {
            header_name: "bad header".to_owned(),
        })
        .expect_err("invalid header");
        assert_eq!(code, "invalid_input");
    }

    #[test]
    #[allow(clippy::too_many_lines)]
    fn provider_connection_route_and_preset_crud_round_trip_typed_values() {
        let root = tempdir().expect("temp root");
        let core = LorepiaCore::open(FfiCoreConfig {
            data_root: root.path().to_string_lossy().into_owned(),
        })
        .expect("open");
        let template = core
            .list_provider_templates()
            .expect("templates")
            .into_iter()
            .find(|template| template.id == "ollama-native-v1")
            .expect("Ollama template");
        let api_origin = template
            .default_api_origin
            .clone()
            .expect("Ollama default origin");
        let mut connection = core
            .create_provider_connection(FfiProviderConnectionDraft {
                id: "typed-ollama".to_owned(),
                template_id: template.id,
                template_version: template.manifest_version,
                display_name: "Local typed provider".to_owned(),
                api_origin: api_origin.clone(),
                api_base_path: Some("/api".to_owned()),
                network_mode: FfiProviderNetworkMode::LocalLoopback,
                local_network_approval: None,
                values: vec![FfiConnectionConfigEntry {
                    key: "api_base_url".to_owned(),
                    value: FfiConnectionConfigValue::Text { value: api_origin },
                }],
                approved_credential_origin: None,
                timeout_seconds: 20,
            })
            .expect("create connection");
        assert_eq!(connection.values.len(), 1);
        assert!(!connection.credential_slot_ready);
        assert!(connection.credential_scope.is_none());
        connection.display_name = "Updated local provider".to_owned();
        connection.status = "connected".to_owned();
        connection = core
            .upsert_provider_connection(connection)
            .expect("upsert connection");
        assert_eq!(connection.display_name, "Updated local provider");
        assert_eq!(
            connection.status, "untested",
            "native callers cannot forge a tested connection status"
        );
        assert_eq!(
            core.list_provider_connections()
                .expect("connections")
                .as_slice(),
            [connection.clone()]
        );

        let route = core
            .upsert_model_route(FfiModelRoute {
                id: "typed-ollama:model".to_owned(),
                connection_id: connection.id.clone(),
                api_family: "ollama_native".to_owned(),
                model_id: "synthetic:latest".to_owned(),
                display_name: Some("Synthetic model".to_owned()),
                route_config: FfiModelRouteConfig {
                    deployment_id: Some("local".to_owned()),
                    region: Some("loopback".to_owned()),
                    endpoint_path: Some("/chat".to_owned()),
                    values: vec![
                        FfiConnectionConfigEntry {
                            key: "replicas".to_owned(),
                            value: FfiConnectionConfigValue::Integer { value: 1 },
                        },
                        FfiConnectionConfigEntry {
                            key: "stream".to_owned(),
                            value: FfiConnectionConfigValue::Boolean { value: true },
                        },
                    ],
                },
                availability: "available".to_owned(),
                miss_count: 0,
                raw_metadata_json: None,
                metadata_source: "legacy".to_owned(),
                metadata_observed_at: None,
                last_reconciled_sync_job_id: None,
                metadata_sync_job_id: None,
                first_seen_at: "2026-07-31T00:00:00+00:00".to_owned(),
                last_seen_at: Some("2026-07-31T00:00:00+00:00".to_owned()),
            })
            .expect("upsert route");
        assert_eq!(
            core.list_model_routes(connection.id.clone())
                .expect("routes")
                .as_slice(),
            std::slice::from_ref(&route)
        );
        let observed_at = Utc::now();
        core.core
            .record_provider_api_capability_observations(vec![CapabilityObservation {
                id: ObservationId::from("typed-ollama-reasoning"),
                model_route_id: ModelRouteId::from(route.id.clone()),
                key: CapabilityKey::Reasoning,
                value: CapabilityValue::Structured(serde_json::json!({
                    "dialect": "ollama_level",
                    "efforts": ["low", "medium", "high"],
                    "supports_disabled": true
                })),
                status: SupportStatus::Verified,
                source: ObservationSource::ProviderApi,
                confidence: Confidence::High,
                observed_at,
                expires_at: Some(observed_at + chrono::Duration::hours(1)),
                evidence_ref: None,
            }])
            .expect("store exact provider reasoning dialect");

        let preset_input = FfiGenerationPreset {
            id: "typed-ollama:model:balanced".to_owned(),
            model_route_id: route.id.clone(),
            display_name: "Balanced".to_owned(),
            parameter_value_count: 3,
            values: vec![
                FfiParameterValue {
                    parameter_id: "temperature".to_owned(),
                    state: FfiParameterValueState::Explicit {
                        value: FfiParameterLiteral::Number { value: 0.5 },
                    },
                },
                FfiParameterValue {
                    parameter_id: "max_output_tokens".to_owned(),
                    state: FfiParameterValueState::Explicit {
                        value: FfiParameterLiteral::Integer { value: 512 },
                    },
                },
                FfiParameterValue {
                    parameter_id: "top_p".to_owned(),
                    state: FfiParameterValueState::InheritProviderDefault,
                },
            ],
            reasoning_mode: "enabled".to_owned(),
            reasoning_effort: Some("medium".to_owned()),
            reasoning_budget_tokens: None,
            reasoning_summary: "provider_default".to_owned(),
            preserve_opaque_reasoning_state: false,
            prompt_cache_mode: "provider_default".to_owned(),
            prompt_cache_ttl: "provider_default".to_owned(),
            prompt_cache_custom_ttl_seconds: None,
            prompt_cache_context_reference: None,
            created_at: "2026-07-31T00:00:00+00:00".to_owned(),
            updated_at: "2026-07-31T00:00:00+00:00".to_owned(),
        };
        let mut unsupported_preset = preset_input.clone();
        unsupported_preset.preserve_opaque_reasoning_state = true;
        let FfiError::Core { code, detail, .. } = core
            .upsert_generation_preset(unsupported_preset)
            .expect_err("exact Ollama template must reject opaque reasoning state");
        assert_eq!(code, "invalid_input");
        assert_eq!(
            detail,
            "opaque reasoning state preservation is not supported by this exact provider template"
        );
        assert!(
            core.list_generation_presets(route.id.clone())
                .expect("presets after rejected opaque state")
                .is_empty()
        );

        let preset = core
            .upsert_generation_preset(preset_input)
            .expect("upsert preset");
        assert_eq!(preset.values.len(), 3);
        assert_eq!(
            core.list_generation_presets(route.id.clone())
                .expect("presets")
                .as_slice(),
            std::slice::from_ref(&preset)
        );
        let settings = core
            .select_generation_target(Some(FfiGenerationTarget {
                model_route_id: route.id.clone(),
                generation_preset_id: preset.id.clone(),
            }))
            .expect("select target");
        assert_eq!(
            settings.selected_model_route_id.as_deref(),
            Some(route.id.as_str())
        );
        assert_eq!(
            settings.selected_generation_preset_id.as_deref(),
            Some(preset.id.as_str())
        );

        core.delete_generation_preset(preset.id)
            .expect("delete preset");
        assert!(
            core.list_generation_presets(route.id.clone())
                .expect("presets after delete")
                .is_empty()
        );
        core.delete_model_route(route.id).expect("delete route");
        assert!(
            core.list_model_routes(connection.id.clone())
                .expect("routes after delete")
                .is_empty()
        );
        core.delete_provider_connection(connection.id)
            .expect("delete connection");
        assert!(
            core.list_provider_connections()
                .expect("connections after delete")
                .is_empty()
        );
    }

    #[test]
    fn round_trips_large_unicode_nullable_values_enums_and_empty_lists() {
        let root = tempdir().expect("temp root");
        let core = LorepiaCore::open(FfiCoreConfig {
            data_root: root.path().to_string_lossy().into_owned(),
        })
        .expect("open");
        assert!(core.list_characters().expect("characters").is_empty());
        assert!(core.list_conversations().expect("conversations").is_empty());
        assert!(
            core.list_provider_profiles()
                .expect("provider profiles")
                .is_empty()
        );
        assert!(
            core.get_settings()
                .expect("settings")
                .selected_provider_profile_id
                .is_none()
        );

        let name = "세구 😀 e\u{301}";
        let description = "큰문자열😀".repeat(8_192);
        let character = import_character(&core, root.path(), name, &description);
        assert_eq!(character.name, name);
        assert_eq!(character.description, description);
        assert!(character.avatar_asset_hash.is_none());

        let conversation = core
            .open_conversation(character.id)
            .expect("open conversation");
        assert_eq!(conversation.title, name);
        assert!(
            core.list_messages(conversation.id)
                .expect("empty message list")
                .is_empty()
        );

        let error = core
            .get_character("missing-character".to_owned())
            .expect_err("missing character");
        let FfiError::Core {
            code,
            recoverable,
            operation_id,
            ..
        } = error;
        assert_eq!(code, "not_found");
        assert!(!recoverable);
        assert!(!operation_id.is_empty());

        assert_eq!(
            [
                MessageRole::System,
                MessageRole::User,
                MessageRole::Assistant
            ]
            .map(map_message_role),
            ["system", "user", "assistant"]
        );
        assert_eq!(
            [
                MessageStatus::Pending,
                MessageStatus::Complete,
                MessageStatus::Cancelled,
                MessageStatus::Failed
            ]
            .map(map_message_status),
            ["pending", "complete", "cancelled", "failed"]
        );
        assert_eq!(
            [ContentKind::CharacterCardV3, ContentKind::CharxPackage].map(map_content_kind),
            ["character_card_v3", "charx_package"]
        );
    }

    #[test]
    #[allow(clippy::too_many_lines)]
    fn maps_every_structured_event_variant_and_errors() {
        let generation_id = GenerationId("generation".to_owned());
        let conversation_id = ConversationId("conversation".to_owned());
        let branch_id = ConversationBranchId("branch".to_owned());
        let assistant_message_id = MessageId("assistant".to_owned());
        let kinds = vec![
            ChatEventKind::GenerationStarted,
            ChatEventKind::ReasoningDelta("생각".to_owned()),
            ChatEventKind::TextDelta("본문".to_owned()),
            ChatEventKind::ToolCallStarted {
                id: ToolCallId::parse("call-1").unwrap(),
                name: ToolName::parse("search_weather").unwrap(),
            },
            ChatEventKind::ToolCallArgumentsDelta {
                id: ToolCallId::parse("call-1").unwrap(),
                delta: ToolCallArgumentsDelta::parse(r#"{"city":"Seoul"}"#).unwrap(),
            },
            ChatEventKind::ToolCallCompleted {
                id: ToolCallId::parse("call-1").unwrap(),
            },
            ChatEventKind::UsageUpdated(GenerationUsage {
                input_tokens: Some(12),
                cached_read_tokens: Some(5),
                cached_write_tokens: Some(6),
                output_tokens: None,
                reasoning_tokens: Some(7),
                tool_tokens: Some(8),
                provider_raw_summary: Some(BoundedJson::parse(r#"{"total_tokens":38}"#).unwrap()),
            }),
            ChatEventKind::MessageCommitted {
                message_id: MessageId("message".to_owned()),
                status: MessageStatus::Complete,
            },
            ChatEventKind::GenerationCancelled,
            ChatEventKind::GenerationFailed {
                code: "network_unavailable".to_owned(),
                message: "offline".to_owned(),
            },
            ChatEventKind::GenerationFinished,
        ];
        let mapped = kinds
            .into_iter()
            .enumerate()
            .map(|(index, kind)| {
                map_chat_event(
                    ChatEvent::new(
                        generation_id.clone(),
                        conversation_id.clone(),
                        index as u64 + 1,
                        kind,
                    )
                    .with_route(branch_id.clone(), assistant_message_id.clone()),
                )
            })
            .collect::<Vec<_>>();
        assert_eq!(
            mapped
                .iter()
                .map(|event| event.kind.as_str())
                .collect::<Vec<_>>(),
            [
                "generation_started",
                "reasoning_delta",
                "text_delta",
                "tool_call_started",
                "tool_call_arguments_delta",
                "tool_call_completed",
                "usage_updated",
                "message_committed",
                "generation_cancelled",
                "generation_failed",
                "generation_finished",
            ]
        );
        assert_eq!(mapped[1].text.as_deref(), Some("생각"));
        assert_eq!(mapped[2].text.as_deref(), Some("본문"));
        assert_eq!(mapped[3].tool_call_id.as_deref(), Some("call-1"));
        assert_eq!(mapped[3].tool_name.as_deref(), Some("search_weather"));
        assert_eq!(
            mapped[4].tool_arguments_delta.as_deref(),
            Some(r#"{"city":"Seoul"}"#)
        );
        assert_eq!(mapped[5].tool_call_id.as_deref(), Some("call-1"));
        assert_eq!(mapped[6].usage_input_tokens, Some(12));
        assert_eq!(mapped[6].usage_cached_read_tokens, Some(5));
        assert_eq!(mapped[6].usage_cached_write_tokens, Some(6));
        assert_eq!(mapped[6].usage_output_tokens, None);
        assert_eq!(mapped[6].usage_reasoning_tokens, Some(7));
        assert_eq!(mapped[6].usage_tool_tokens, Some(8));
        assert_eq!(
            mapped[6].usage_provider_raw_summary.as_deref(),
            Some(r#"{"total_tokens":38}"#)
        );
        assert_eq!(mapped[7].message_id.as_deref(), Some("message"));
        assert_eq!(mapped[7].message_status.as_deref(), Some("complete"));
        assert_eq!(mapped[9].error_code.as_deref(), Some("network_unavailable"));
        assert_eq!(mapped[9].error_message.as_deref(), Some("offline"));
        assert!(
            mapped
                .iter()
                .all(|event| event.event_version == CHAT_EVENT_VERSION)
        );
        assert!(
            mapped
                .iter()
                .all(|event| event.branch_id.as_deref() == Some("branch"))
        );
        assert!(
            mapped
                .iter()
                .all(|event| event.assistant_message_id.as_deref() == Some("assistant"))
        );
        assert!(mapped[10].text.is_none());
        assert!(mapped[10].message_id.is_none());
        assert!(mapped[10].error_code.is_none());

        let error = FfiError::from(CoreError::new(
            CoreErrorCode::NetworkUnavailable,
            "offline",
            true,
        ));
        let FfiError::Core {
            code,
            detail,
            recoverable,
            operation_id,
        } = error;
        assert_eq!(code, "network_unavailable");
        assert_eq!(detail, "offline");
        assert!(recoverable);
        assert!(!operation_id.is_empty());
    }

    #[test]
    fn capability_binding_preserves_provenance_and_rejects_structured_user_input() {
        let observed_at = Utc::now();
        let observation = CapabilityObservation {
            id: ObservationId::from("capability-binding"),
            model_route_id: ModelRouteId::from("route-binding"),
            key: CapabilityKey::Streaming,
            value: CapabilityValue::Boolean(true),
            status: SupportStatus::Verified,
            source: ObservationSource::CapabilityProbe,
            confidence: Confidence::High,
            observed_at,
            expires_at: Some(observed_at + chrono::Duration::hours(1)),
            evidence_ref: None,
        };
        let mapped = map_capability_observation(observation);
        assert_eq!(mapped.key, "streaming");
        assert_eq!(mapped.source, "capability_probe");
        assert_eq!(mapped.value.kind, "boolean");
        assert_eq!(mapped.value.boolean_value, Some(true));

        let error = unmap_capability_override(FfiCapabilityOverrideDraft {
            id: "user-override".to_owned(),
            model_route_id: "route-binding".to_owned(),
            key: "reasoning".to_owned(),
            value: FfiCapabilityValue {
                kind: "structured".to_owned(),
                boolean_value: None,
                integer_value: None,
                enum_values: Vec::new(),
                structured_json: Some(r#"{"family":"invented"}"#.to_owned()),
            },
            status: "verified".to_owned(),
            expires_at: None,
        })
        .expect_err("native structured wire metadata must be rejected");
        assert!(error.to_string().contains("read-only"));
    }

    #[test]
    fn branch_send_routes_events_and_persists_only_on_the_selected_branch() {
        let root = tempdir().expect("temp root");
        let core = LorepiaCore::open(FfiCoreConfig {
            data_root: root.path().to_string_lossy().into_owned(),
        })
        .expect("open");
        let character = import_character(&core, root.path(), "분기 전송", "합성 테스트");
        let conversation = core
            .create_conversation(character.id, "스토리 분기".to_owned(), "story".to_owned())
            .expect("create conversation");
        let state = core
            .get_conversation_state(conversation.id.clone())
            .expect("conversation state");
        let (base_url, provider_requests) = spawn_completed_provider();
        let profile = core
            .upsert_provider_profile(FfiProviderProfile {
                id: "branch-send".to_owned(),
                display_name: "분기 제공자".to_owned(),
                base_url,
                model: "synthetic".to_owned(),
                timeout_seconds: 5,
            })
            .expect("save provider");

        let generation_id = core
            .send_message_to_branch(
                conversation.id.clone(),
                state.active_branch_id.clone(),
                None,
                "story".to_owned(),
                "분기 질문".to_owned(),
                profile.id,
                None,
            )
            .expect("send to branch");
        let provider_request = provider_requests
            .recv_timeout(Duration::from_secs(2))
            .expect("provider request");
        assert_post_request_path(&provider_request, "/v1/chat/completions");
        let events = poll_until(&core, &generation_id, "generation_finished");
        assert!(!events.is_empty());
        assert!(events.iter().all(|event| {
            event.event_version == CHAT_EVENT_VERSION
                && event.branch_id.as_deref() == Some(state.active_branch_id.as_str())
        }));
        let assistant_message_id = events
            .first()
            .and_then(|event| event.assistant_message_id.as_deref())
            .expect("assistant route id");
        assert!(
            events.iter().all(|event| {
                event.assistant_message_id.as_deref() == Some(assistant_message_id)
            })
        );

        let messages = core
            .list_branch_messages(state.active_branch_id)
            .expect("branch messages");
        assert_eq!(
            messages
                .iter()
                .map(|message| message.content.as_str())
                .collect::<Vec<_>>(),
            ["분기 질문", "응답😀"]
        );
        assert_eq!(
            messages.last().map(|message| message.id.as_str()),
            Some(assistant_message_id)
        );
    }

    #[test]
    #[allow(clippy::too_many_lines)]
    fn binding_message_actions_fork_refresh_and_logically_remove() {
        let root = tempdir().expect("temp root");
        let core = LorepiaCore::open(FfiCoreConfig {
            data_root: root.path().to_string_lossy().into_owned(),
        })
        .expect("open");
        let character = import_character(&core, root.path(), "메시지 액션", "합성 테스트");
        let conversation = core
            .create_conversation(character.id, "대화방".to_owned(), "story".to_owned())
            .expect("conversation");
        let state = core
            .get_conversation_state(conversation.id.clone())
            .expect("initial state");
        let profile_id = "message-actions".to_owned();
        let edit_profile_id = "message-actions-edit".to_owned();
        let (initial_base_url, initial_provider_requests) = spawn_completed_provider();
        core.upsert_provider_profile(FfiProviderProfile {
            id: profile_id.clone(),
            display_name: "합성 제공자".to_owned(),
            base_url: initial_base_url,
            model: "synthetic".to_owned(),
            timeout_seconds: 5,
        })
        .expect("provider");
        let initial_generation = core
            .send_message_to_branch(
                conversation.id.clone(),
                state.active_branch_id.clone(),
                None,
                "story".to_owned(),
                "원본 질문".to_owned(),
                profile_id.clone(),
                None,
            )
            .expect("initial generation");
        let initial_provider_request = initial_provider_requests
            .recv_timeout(Duration::from_secs(2))
            .expect("initial provider request");
        assert_post_request_path(&initial_provider_request, "/v1/chat/completions");
        poll_until(&core, &initial_generation, "generation_finished");
        let original = core
            .list_branch_messages(state.active_branch_id.clone())
            .expect("original messages");

        let (edit_base_url, edit_provider_requests) = spawn_completed_provider();
        core.upsert_provider_profile(FfiProviderProfile {
            id: edit_profile_id.clone(),
            display_name: "합성 제공자".to_owned(),
            base_url: edit_base_url,
            model: "synthetic".to_owned(),
            timeout_seconds: 5,
        })
        .expect("edit provider");
        let edited = core
            .edit_user_message(
                conversation.id.clone(),
                state.active_branch_id.clone(),
                Some(original[1].id.clone()),
                original[0].id.clone(),
                "수정 질문".to_owned(),
                edit_profile_id,
                None,
            )
            .expect("edit");
        assert_eq!(edited.branch.conversation_id, conversation.id);
        assert_ne!(edited.branch.id, state.active_branch_id);
        assert!(edited.branch.fork_message_id.is_none());
        let edit_provider_request = edit_provider_requests
            .recv_timeout(Duration::from_secs(2))
            .expect("edit provider request");
        assert_post_request_path(&edit_provider_request, "/v1/chat/completions");
        poll_until(&core, &edited.generation_id, "generation_finished");
        let edited_messages = core
            .list_branch_messages(edited.branch.id.clone())
            .expect("edited messages");
        assert_eq!(edited_messages[0].content, "수정 질문");
        assert_eq!(edited_messages[1].content, "응답😀");

        let rows_before_remove = core.database_stats().expect("stats").messages;
        let rewound = core
            .remove_message_from_branch(
                conversation.id.clone(),
                edited.branch.id.clone(),
                Some(edited_messages[1].id.clone()),
                edited_messages[1].id.clone(),
            )
            .expect("logical remove");
        assert_eq!(rewound.head_message_id, Some(edited_messages[0].id.clone()));
        assert_eq!(
            core.database_stats().expect("preserved stats").messages,
            rows_before_remove
        );
        assert_eq!(
            core.list_branch_messages(edited.branch.id)
                .expect("rewound messages")
                .len(),
            1
        );

        core.select_conversation_branch(conversation.id.clone(), state.active_branch_id.clone())
            .expect("select original");
        let regeneration_profile_id = "message-actions-regenerate".to_owned();
        let (regeneration_base_url, regeneration_provider_requests) = spawn_completed_provider();
        core.upsert_provider_profile(FfiProviderProfile {
            id: regeneration_profile_id.clone(),
            display_name: "합성 제공자".to_owned(),
            base_url: regeneration_base_url,
            model: "synthetic".to_owned(),
            timeout_seconds: 5,
        })
        .expect("regeneration provider");
        let regenerated = core
            .regenerate_assistant_message(
                conversation.id.clone(),
                state.active_branch_id.clone(),
                Some(original[1].id.clone()),
                original[1].id.clone(),
                regeneration_profile_id,
                None,
            )
            .expect("regenerate");
        let regeneration_provider_request = regeneration_provider_requests
            .recv_timeout(Duration::from_secs(2))
            .expect("regeneration provider request");
        assert_post_request_path(&regeneration_provider_request, "/v1/chat/completions");
        poll_until(&core, &regenerated.generation_id, "generation_finished");
        let regenerated_messages = core
            .list_branch_messages(regenerated.branch.id)
            .expect("regenerated messages");
        assert_eq!(regenerated_messages[0].content, "원본 질문");
        assert_ne!(regenerated_messages[0].id, original[0].id);
        let preserved_original = core
            .list_branch_messages(state.active_branch_id)
            .expect("preserved original");
        assert_eq!(
            preserved_original
                .iter()
                .map(|message| (&message.id, &message.content))
                .collect::<Vec<_>>(),
            original
                .iter()
                .map(|message| (&message.id, &message.content))
                .collect::<Vec<_>>()
        );
    }

    #[test]
    #[allow(clippy::too_many_lines)]
    fn live_binding_preserves_event_order_large_unicode_and_cancellation() {
        let root = tempdir().expect("temp root");
        let core = LorepiaCore::open(FfiCoreConfig {
            data_root: root.path().to_string_lossy().into_owned(),
        })
        .expect("open");
        let character = import_character(&core, root.path(), "세구", "바인딩 이벤트 테스트");
        let conversation = core
            .open_conversation(character.id)
            .expect("open conversation");

        let (completed_base_url, completed_provider_requests) = spawn_completed_provider();
        let profile = core
            .upsert_provider_profile(FfiProviderProfile {
                id: "completed".to_owned(),
                display_name: "완료 제공자".to_owned(),
                base_url: completed_base_url,
                model: "synthetic".to_owned(),
                timeout_seconds: 5,
            })
            .expect("save provider");
        let large_unicode_message = "질문😀".repeat(4_096);
        let generation_id = core
            .send_message(
                conversation.id.clone(),
                large_unicode_message.clone(),
                profile.id,
                None,
            )
            .expect("send message");
        let completed_provider_request = completed_provider_requests
            .recv_timeout(Duration::from_secs(2))
            .expect("completed provider request");
        assert_post_request_path(&completed_provider_request, "/v1/chat/completions");
        let events = poll_until(&core, &generation_id, "generation_finished");
        assert!(
            events
                .windows(2)
                .all(|pair| pair[0].sequence < pair[1].sequence)
        );
        assert_eq!(
            events.first().map(|event| event.kind.as_str()),
            Some("generation_started")
        );
        assert!(
            events
                .iter()
                .any(|event| event.kind == "text_delta" && event.text.as_deref() == Some("응답😀"))
        );
        assert!(events.iter().any(|event| event.kind == "usage_updated"
            && event.usage_input_tokens == Some(9)
            && event.usage_output_tokens == Some(2)));
        assert_eq!(
            events.last().map(|event| event.kind.as_str()),
            Some("generation_finished")
        );
        let messages = core
            .list_messages(conversation.id.clone())
            .expect("completed messages");
        assert_eq!(messages[0].content, large_unicode_message);
        assert_eq!(messages[0].role, "user");
        assert_eq!(messages[1].content, "응답😀");
        assert_eq!(messages[1].role, "assistant");
        assert_eq!(messages[1].status, "complete");
        assert!(messages[0].parent_id.is_none());
        assert!(messages[0].generation_id.is_none());
        assert!(messages[1].generation_id.is_some());

        let (base_url, provider_ready, provider_stop) = spawn_stalling_provider();
        let cancellation_profile = core
            .upsert_provider_profile(FfiProviderProfile {
                id: "cancellation".to_owned(),
                display_name: "취소 제공자".to_owned(),
                base_url,
                model: "synthetic".to_owned(),
                timeout_seconds: 5,
            })
            .expect("save cancellation provider");
        let character = core
            .list_characters()
            .expect("characters")
            .into_iter()
            .next()
            .expect("character");
        let cancellation_conversation = core
            .open_conversation(character.id)
            .expect("open cancellation conversation");
        let cancellation_id = core
            .send_message(
                cancellation_conversation.id.clone(),
                "중지해".to_owned(),
                cancellation_profile.id,
                None,
            )
            .expect("send cancellation message");
        let provider_request = provider_ready
            .recv_timeout(Duration::from_secs(2))
            .expect("provider started");
        assert_post_request_path(&provider_request, "/v1/chat/completions");

        let deadline = Instant::now() + Duration::from_secs(2);
        let mut cancellation_events = Vec::new();
        loop {
            let batch = core.poll_events(64).expect("poll partial event");
            cancellation_events.extend(
                batch
                    .events
                    .into_iter()
                    .filter(|event| event.generation_id == cancellation_id),
            );
            if cancellation_events
                .iter()
                .any(|event| event.kind == "text_delta")
            {
                break;
            }
            assert!(Instant::now() < deadline, "text delta did not arrive");
            thread::sleep(Duration::from_millis(10));
        }
        core.cancel_generation(cancellation_id.clone())
            .expect("cancel");
        cancellation_events.extend(poll_until(&core, &cancellation_id, "generation_cancelled"));
        let _ = provider_stop.send(());

        assert!(
            cancellation_events
                .windows(2)
                .all(|pair| pair[0].sequence < pair[1].sequence)
        );
        assert_eq!(
            cancellation_events.last().map(|event| event.kind.as_str()),
            Some("generation_cancelled")
        );
        let messages = core
            .list_messages(cancellation_conversation.id)
            .expect("cancelled messages");
        assert_eq!(messages[1].content, "부분😀");
        assert_eq!(messages[1].status, "cancelled");
    }

    #[test]
    fn validates_event_batch_bounds() {
        let root = tempdir().expect("temp root");
        let core = LorepiaCore::open(FfiCoreConfig {
            data_root: root.path().to_string_lossy().into_owned(),
        })
        .expect("open");
        for size in [0, MAX_EVENT_BATCH_SIZE + 1] {
            let error = core.poll_events(size).expect_err("invalid batch");
            let FfiError::Core { code, .. } = error;
            assert_eq!(code, "invalid_input");
        }
    }
}
