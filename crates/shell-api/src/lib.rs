//! UI-safe adapter over Lorepia's existing high-level Core contract.
//!
//! This crate deliberately does not redefine product behavior. Collection
//! methods remain whole-`Vec` operations, message mutations retain
//! `expected_head`, and chat events retain Core's current event version and
//! variants. Host paths and credentials are represented only by
//! non-serializable Rust boundary types.

mod api;
mod catalog;
mod discovery;
mod dto;
mod error;
mod model_sync;
mod provider;
mod sensitive;
mod stream;

pub use api::{
    CreateConversationBranchInput, CreateConversationInput, EditUserMessageInput,
    GenerationSelectionInput, RegenerateAssistantMessageInput, RemoveMessageInput,
    SelectConversationBranchInput, SendMessageInput, SetConversationModeInput, ShellApi,
    StartedGeneration, StartedMessageAction,
};
pub use catalog::{
    ProviderCatalogActivationSummaryDto, ProviderCatalogDiffDto, ProviderCatalogHistoryDto,
    ProviderCatalogImportPlanDto, ProviderCatalogImportResultDto, ProviderCatalogImportReviewDto,
    ProviderCatalogRevisionSummaryDto, ProviderCatalogRollbackPlanDto,
    ProviderCatalogRollbackResultDto, ProviderCatalogStatusDto,
};
pub use discovery::{
    BeginProviderDiscoveryCurlInput, BeginProviderDiscoveryInput,
    BeginProviderDiscoverySourceInput, ContinueProviderDiscoveryActionInput,
    ContinueProviderDiscoveryInput, DiscoveryActionRequiredDto, DiscoveryApprovalBindingDto,
    DiscoveryApprovalGrantDto, DiscoveryApprovalRecordDto,
    DiscoveryAssistantConflictDispositionDto, DiscoveryAssistantDraftFieldDto,
    DiscoveryAssistantDraftReviewDto, DiscoveryAssistantEndpointDto,
    DiscoveryAssistantEvidenceConflictDto, DiscoveryAssistantEvidenceMappingDto,
    DiscoveryAssistantFailureKindInput, DiscoveryAssistantFieldConfidenceDto,
    DiscoveryAssistantHostActionDto, DiscoveryAssistantInterruptionOutcomeInput,
    DiscoveryAssistantManifestDraftDto, DiscoveryAssistantManifestDto,
    DiscoveryAssistantManifestSourceDto, DiscoveryAssistantQuestionDto,
    DiscoveryAssistantResumeBoundaryDto, DiscoveryCandidateDto, DiscoveryCandidateSummaryDto,
    DiscoveryCompensationRecordDto, DiscoveryEvidenceDto, DiscoveryFailureDto,
    DiscoveryOutboxEventDto, DiscoveryProgressDto, DiscoveryRecoveryResultDto,
    DiscoveryReviewChangeDto, DiscoveryReviewDto, DiscoveryStepDto,
    DiscoveryUnknownOutcomeResolutionInput, ProviderDiscoveryApprovalProposalDto,
    ProviderDiscoveryConnectionOptionsDto, ProviderDiscoveryConnectionOptionsInput,
    ProviderDiscoveryEventDto, ProviderDiscoveryReviewProposalDto, ProviderDiscoverySessionDto,
};
pub use dto::{
    BootstrapDto, CharacterDto, ChatEventDto, ChatEventKindDto, ContentKindDto,
    ConversationBranchDto, ConversationDto, ConversationModeDto, ConversationStateDto,
    GenerationStartedDto, GenerationTargetDto, GenerationUsageDto, HealthDto,
    ImportImagePreviewDto, ImportInspectionDto, ImportWarningDto, MessageActionGenerationDto,
    MessageDto, MessageRoleDto, MessageStatusDto,
};
pub use error::{ShellError, ShellErrorCode, ShellResult};
pub use model_sync::{
    ModelSyncDiffDto, ModelSyncEventDto, ModelSyncFailureDto, ModelSyncJobDto,
    ModelSyncProgressDto, ModelSyncReviewDto, ModelSyncSourceProvenanceDto, ModelSyncStartedDto,
};
pub use provider::{
    ApiFamilyInput, AppSettingsDto, AuthBindingDto, CacheTtlBoundsDto, CapabilityKeyInput,
    CapabilityObservationDto, CapabilityOverrideStatusInput, CapabilityOverrideValueInput,
    CapabilityValueDto, ConnectionConfigEntryDto, ConnectionConfigValueDto, ConnectionFieldSpecDto,
    CreateProviderConnectionInput, CredentialScopeDto, EffectiveCapabilityDto, GenerationPresetDto,
    GenerationPresetInput, GenerationReasoningSettingsDto, ModelAvailabilityInput,
    ModelRouteConfigDto, ModelRouteDto, ParameterChoiceDto, ParameterConditionDto,
    ParameterConflictDto, ParameterIssueDto, ParameterLiteralDto, ParameterSpecDto,
    ParameterValueDto, ParameterValueStateDto, PromptCacheControlDto, PromptCacheSettingsDto,
    PromptCacheTtlDto, ProviderConnectionDto, ProviderLocalNetworkApprovalDto,
    ProviderLocalNetworkApprovalInput, ProviderNetworkModeInput, ProviderParameterMappingDto,
    ProviderProfileDto, ProviderTemplateDto, ReasoningControlDto, RequestBodyFieldDto,
    RequestBodyShapeDto, RequestPreviewDto, TokenBudgetBoundsDto, UpdateProviderConnectionInput,
    UpsertCapabilityOverrideInput, UpsertModelRouteInput,
};
pub use sensitive::{
    GenerationCredential, SecretCredential, SecretProviderCurl, SignedCatalogEnvelope,
    StagedImportFile,
};
pub use stream::{ChatEventStream, ChatStreamItem, ReconcileReason, ReconciliationRequiredDto};
