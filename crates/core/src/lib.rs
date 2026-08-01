//! High-level application API consumed by every platform binding.

mod app;
mod catalog;
mod config;
mod provider_discovery;
mod provider_discovery_deterministic;

pub use app::{
    Core, EffectiveCapability, ProviderModelRefreshProvenance, ProviderModelRefreshResult,
    ProviderTemplateView,
};
pub use catalog::{
    PROVIDER_CATALOG_HISTORY_SCHEMA_VERSION, PROVIDER_CATALOG_IMPORT_PLAN_SCHEMA_VERSION,
    PROVIDER_CATALOG_ROLLBACK_PLAN_SCHEMA_VERSION, PROVIDER_CATALOG_STATUS_SCHEMA_VERSION,
    ProviderCatalogActivationKind, ProviderCatalogActivationSummary, ProviderCatalogHistory,
    ProviderCatalogImportPlan, ProviderCatalogImportResult, ProviderCatalogImportReview,
    ProviderCatalogRevisionSummary, ProviderCatalogRollbackPlan, ProviderCatalogRollbackResult,
    ProviderCatalogStatus,
};
pub use config::CoreConfig;
pub use lorepia_chat::{CHAT_EVENT_VERSION, ChatEvent, ChatEventKind};
pub use lorepia_domain::discovery::*;
pub use lorepia_domain::{
    ApiFamily, AppSettings, AuthBinding, BoundedJson, CanonicalOrigin, CapabilityKey,
    CapabilityObservation, CapabilityValue, Character, Confidence, ConnectionConfig,
    ConnectionConfigEntry, ConnectionConfigValue, ConnectionFieldSpec, ConnectionFieldType,
    ConnectionStatus, ContentKind, Conversation, ConversationBranch, ConversationBranchId,
    ConversationId, ConversationMode, ConversationState, CoreError, CoreErrorCode, CoreResult,
    CredentialRedirectPolicy, CredentialRef, CredentialScope, DecoderId, DiscoverySessionId,
    EndpointPath, EvidenceId, GenerationId, GenerationPreset, GenerationPresetId,
    GenerationPromptCacheMode, GenerationPromptCacheSettings, GenerationPromptCacheTtl,
    GenerationReasoningEffort, GenerationReasoningMode, GenerationReasoningSettings,
    GenerationReasoningSummary, GenerationRecord, GenerationStatus, GenerationTarget,
    GenerationUsage, HeaderName, HealthReport, HttpMethod, HttpUrl, ImportImagePreview,
    ImportInspection, ImportWarning, InspectionId, ManifestSourceKind, Message,
    MessageActionGeneration, MessageId, MessageRole, MessageStatus, ModelAvailability,
    ModelMetadataSource, ModelRoute, ModelRouteConfig, ModelRouteId, ModelSyncDiff, ModelSyncEvent,
    ModelSyncFailure, ModelSyncJob, ModelSyncJobId, ModelSyncProgress, ModelSyncReview,
    ModelSyncSourceProvenance, ModelSyncState, ObservationId, ObservationSource, ParameterChoice,
    ParameterCondition, ParameterConditionOperator, ParameterConflict, ParameterConflictKind,
    ParameterDefaultMode, ParameterId, ParameterLiteral, ParameterSpec, ParameterType,
    ParameterValue, ParameterValueState, ProviderConnection, ProviderConnectionDraft,
    ProviderConnectionId, ProviderLocalNetworkApproval, ProviderNetworkMode,
    ProviderParameterMapping, ProviderParameterTarget, ProviderProfile, ProviderTemplate,
    ProviderTemplateId, SupportStatus, TemplateSource, ToolCallArgumentsDelta, ToolCallId,
    ToolName, ToolPolicy, UiParameterLevel,
};
pub use lorepia_domain::{MODEL_SYNC_EVENT_VERSION, MODEL_SYNC_REDACTION_VERSION};
pub use lorepia_providers::catalog::{
    CatalogChangeKind, CatalogDiffDto, CatalogRevisionSnapshot, ManifestChangedSection,
    ManifestDiffDto, ModelChangedSection, ModelMetadataDiffDto,
};
pub use lorepia_providers::parameter_mapping::{
    CacheTtlBounds, ParameterIssue, ParameterIssueCode, PromptCacheControlModel, PromptCacheMode,
    PromptCacheSettings, PromptCacheTtl, ReasoningControlModel, ReasoningEffort, ReasoningMode,
    ReasoningSettings, ReasoningSummaryMode, TokenBudgetBounds, UiControlState, UiFieldState,
};
pub use lorepia_providers::setup_assistant::{
    AssistantBudget, AssistantCallEstimate, AssistantConsentRequest, AssistantDraftReview,
    AssistantFailureKind, AssistantHostAction, AssistantManifestDraft, AssistantPromptPackage,
    AssistantState, AssistantToolCall, AssistantToolResult, AssistantTurn, ConfidenceLevel,
    ConflictDisposition, DraftField, DraftPersistence, DraftReviewCheck, DraftReviewRequirements,
    EvidenceConflict, FieldConfidence, FieldEvidenceMapping, UnresolvedQuestion,
};
pub use lorepia_providers::{
    BuiltInTemplateId, CurlAuthHint, ParsedCurlEvidence, RequestBodyField, RequestBodyShape,
    RequestPreview, SecretBytes, SecretCurlInput,
};
pub use lorepia_storage::{
    DatabaseStats, DiscoveryCompensationRecord, DiscoveryCompensationStatus, DiscoveryEvidenceKind,
    DiscoveryEvidenceRecord, DiscoveryOperationRecord, DiscoveryOperationStatus,
    DiscoveryOutboxEvent, DiscoveryRecoveryResult, DiscoverySessionSnapshot,
    StoredDiscoveryCandidate,
};
pub use provider_discovery::{
    ProviderCurlInspection, ProviderDiscoveryAdditionalEvidence, ProviderDiscoveryApprovalProposal,
    ProviderDiscoveryAssistantResumeAction, ProviderDiscoveryAssistantResumeBoundary,
    ProviderDiscoveryCurlInput, ProviderDiscoveryReviewProposal, ProviderDiscoverySource,
    provider_discovery_action_envelope,
};

pub const CORE_API_VERSION: u32 = 8;

pub fn core_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
