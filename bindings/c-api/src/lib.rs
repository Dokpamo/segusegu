//! Stable C ABI consumed by the Windows P/Invoke wrapper.

#![allow(unsafe_code)]
#![deny(unsafe_op_in_unsafe_fn)]

use std::{
    cell::RefCell,
    panic::{AssertUnwindSafe, catch_unwind},
    path::Path,
    ptr, slice, str,
    sync::Mutex,
};

use lorepia_engine::{
    ApiFamily, AppSettings, AssistantDraftReview, AssistantHostAction, AuthBinding, BoundedJson,
    CanonicalOrigin, CapabilityKey, CapabilityObservation, CatalogChangeKind, CatalogDiffDto,
    ChatEvent, ConnectionConfig, ConnectionConfigEntry, ConnectionFieldSpec, ConnectionStatus,
    ConversationBranchId, ConversationId, ConversationMode, Core, CoreConfig, CoreError,
    CoreErrorCode, CoreResult, CredentialRedirectPolicy, CredentialRef, CredentialScope,
    CurlAuthHint, DiscoveryActionEnvelope, DiscoveryActionId, DiscoveryActionRequired,
    DiscoveryApprovalDecision, DiscoveryApprovalGrant, DiscoveryApprovalId,
    DiscoveryApprovalRecord, DiscoveryAssistantCheckpoint, DiscoveryCandidateSummary,
    DiscoveryCommitAttemptId, DiscoveryCompensationKind, DiscoveryCompensationRecord,
    DiscoveryCompensationStatus, DiscoveryCompensationTarget, DiscoveryEventId,
    DiscoveryEvidenceKind, DiscoveryEvidenceRecord, DiscoveryFailure, DiscoveryOperationKind,
    DiscoveryOutboxEvent, DiscoveryPreviousSelection, DiscoveryProgress, DiscoveryProgressPhase,
    DiscoveryRecoveryResult, DiscoveryReviewChangeKind, DiscoveryReviewDiff, DiscoverySessionId,
    DiscoverySessionSnapshot, DiscoveryState, DiscoveryUnknownOutcomeResolution, DiscoveryWarning,
    EffectiveCapability, EndpointPath, EvidenceId, GenerationId, GenerationPreset,
    GenerationPresetId, GenerationPromptCacheSettings, GenerationReasoningSettings,
    GenerationTarget, HttpMethod, HttpUrl, InspectionId, ManifestChangedSection, ManifestDiffDto,
    MessageId, ModelAvailability, ModelChangedSection, ModelMetadataDiffDto, ModelMetadataSource,
    ModelRoute, ModelRouteConfig, ModelRouteId, ModelSyncJobId, ObservationId, ParameterSpec,
    ParameterValue, ProviderCatalogActivationKind, ProviderCatalogActivationSummary,
    ProviderCatalogHistory, ProviderCatalogImportPlan, ProviderCatalogImportResult,
    ProviderCatalogImportReview, ProviderCatalogRevisionSummary, ProviderCatalogRollbackPlan,
    ProviderCatalogRollbackResult, ProviderCatalogStatus, ProviderConnection,
    ProviderConnectionDraft, ProviderConnectionId, ProviderDiscoveryAction,
    ProviderDiscoveryAdditionalEvidence, ProviderDiscoveryApprovalProposal,
    ProviderDiscoveryAssistantResumeAction, ProviderDiscoveryAssistantResumeBoundary,
    ProviderDiscoveryConnectionOptions, ProviderDiscoveryCurlInput,
    ProviderDiscoveryReviewProposal, ProviderLocalNetworkApproval, ProviderModelRefreshProvenance,
    ProviderModelRefreshResult, ProviderNetworkMode, ProviderProfile, ProviderTemplate,
    ProviderTemplateId, ProviderTemplateView, RequestBodyShape, RequestPreview,
    SanitizedDiscoveryInput, SecretCurlInput, StoredDiscoveryCandidate, TemplateSource,
    UnresolvedQuestion, provider_discovery_action_envelope,
};
use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;

pub const ABI_VERSION: u32 = 7;

const STATUS_OK: i32 = 0;
const STATUS_INVALID_ARGUMENT: i32 = 1;
const STATUS_UNSUPPORTED_CONTENT: i32 = 2;
const STATUS_UNSAFE_ARCHIVE: i32 = 3;
const STATUS_NOT_FOUND: i32 = 4;
const STATUS_PERMISSION_DENIED: i32 = 5;
const STATUS_STORAGE_UNAVAILABLE: i32 = 6;
const STATUS_STORAGE_CORRUPTED: i32 = 7;
const STATUS_PROVIDER_AUTH_FAILED: i32 = 8;
const STATUS_PROVIDER_RATE_LIMITED: i32 = 9;
const STATUS_PROVIDER_UNAVAILABLE: i32 = 10;
const STATUS_NETWORK_UNAVAILABLE: i32 = 11;
const STATUS_CANCELLED: i32 = 12;
const STATUS_INTERNAL_ERROR: i32 = 255;
const MAX_EVENT_BATCH_SIZE: u32 = 1_024;
const MAX_DISCOVERY_EVENT_BATCH_SIZE: u32 = 1_000;
const MAX_DISCOVERY_LIST_SIZE: u32 = 256;
const REQUEST_SCHEMA_VERSION: u32 = 1;
const PROVIDER_DISCOVERY_SNAPSHOT_SCHEMA_VERSION: u32 = 3;

thread_local! {
    static THREAD_LAST_ERROR: RefCell<Option<ErrorPayload>> = const { RefCell::new(None) };
}

#[repr(C)]
pub struct LorepiaBuffer {
    pub ptr: *mut u8,
    pub len: usize,
}

impl Default for LorepiaBuffer {
    fn default() -> Self {
        Self {
            ptr: ptr::null_mut(),
            len: 0,
        }
    }
}

pub struct LorepiaCoreHandle {
    core: Core,
    events: Mutex<broadcast::Receiver<ChatEvent>>,
    last_error: Mutex<Option<ErrorPayload>>,
}

#[derive(Deserialize)]
struct CApiConfig {
    data_root: String,
}

#[derive(Clone, Serialize)]
struct ErrorPayload {
    status: i32,
    code: String,
    message: String,
    recoverable: bool,
    operation_id: String,
}

impl ErrorPayload {
    fn from_core(error: CoreError) -> Self {
        Self {
            status: status_for_error(error.code),
            code: error.code.as_str().to_owned(),
            message: error.message,
            recoverable: error.recoverable,
            operation_id: error.operation_id,
        }
    }
}

#[derive(Serialize)]
struct EventBatch {
    events: Vec<ChatEvent>,
    dropped_events: u64,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct ProviderCurlInspectionDto {
    inspection_schema_version: u32,
    sanitized_site_url: String,
    api_origin: String,
    method: String,
    path: String,
    header_names: Vec<String>,
    auth_binding_hint: Option<AuthBinding>,
    api_family_hint: Option<String>,
    model_hint: Option<String>,
    stream_hint: Option<bool>,
    redacted_curl: String,
    credential_present: bool,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct DiscoveryFailureDto {
    code: String,
    message_key: String,
    recoverable: bool,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
enum DiscoveryStateDto {
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

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
enum DiscoveryOperationKindDto {
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

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
enum DiscoveryProgressPhaseDto {
    ProviderCandidates,
    Documents,
    Evidence,
    Models,
    Probes,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct DiscoveryProgressDto {
    phase: DiscoveryProgressPhaseDto,
    completed: u32,
    total: Option<u32>,
}

#[derive(Debug, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum DiscoveryActionRequiredDto {
    SelectTemplate,
    SupplyMoreEvidence,
    ApproveAssistant,
    ApproveCredentialOrigin,
    ApproveProbes,
    Review,
    RestartInterrupted {
        operation: DiscoveryOperationKindDto,
    },
    ReconcileUnknownOutcome {
        operation: DiscoveryOperationKindDto,
    },
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
enum DiscoveryStepStateDto {
    Completed,
    Current,
    Pending,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct DiscoveryStepDto {
    id: String,
    title_key: String,
    state: DiscoveryStepStateDto,
}

#[derive(Debug, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum DiscoveryCandidateSummaryDto {
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

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct DiscoveryCandidateDto {
    id: String,
    proposed_revision: u64,
    summary: DiscoveryCandidateSummaryDto,
    evidence_ids: Vec<String>,
    created_at: String,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
enum DiscoveryEvidenceKindDto {
    HtmlDocument,
    JsonDocument,
    YamlDocument,
    XmlDocument,
    PlainTextDocument,
    JsonSchema,
    OpenApi,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct DiscoveryEvidenceDto {
    id: String,
    kind: DiscoveryEvidenceKindDto,
    content_sha256: String,
    fetched_at: String,
}

#[derive(Debug, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum DiscoveryUnknownOutcomeResolutionDto {
    ConfirmedNoEffect,
    ConfirmedCommitCompleted { connection_id: String },
    ConfirmedCompensated,
    ManuallyReconciledAsFailed,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
#[allow(clippy::struct_field_names)]
struct DiscoveryProbeBudgetDto {
    max_requests: u32,
    max_total_tokens_per_request: u64,
    max_output_tokens_per_request: u64,
    max_cost_micro_usd_per_request: u64,
    max_duration_millis_per_request: u64,
    max_calls_per_request: u32,
}

#[derive(Debug, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum DiscoveryApprovalGrantDto {
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
        auth_binding: AuthBinding,
        manifest_sha256: String,
    },
    CapabilityProbe {
        model_route_ids: Vec<String>,
        budget: DiscoveryProbeBudgetDto,
    },
    Review {
        review_sha256: String,
        graph_sha256: String,
    },
    UnknownOutcomeResolution {
        operation: DiscoveryOperationKindDto,
        resolution: DiscoveryUnknownOutcomeResolutionDto,
    },
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
enum DiscoveryApprovalDecisionDto {
    Approved,
    Rejected,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct DiscoveryApprovalDto {
    id: String,
    session_revision: u64,
    decision: DiscoveryApprovalDecisionDto,
    grant: DiscoveryApprovalGrantDto,
    created_at: String,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct DiscoveryApprovalProposalDto {
    approval_id: String,
    grant: DiscoveryApprovalGrantDto,
    grant_sha256: String,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
enum DiscoveryReviewChangeKindDto {
    Add,
    Update,
    Deprecate,
    PreserveMissing,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
enum DiscoveryReviewTargetKindDto {
    ProviderTemplate,
    ProviderConnection,
    ModelRoute,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct DiscoveryReviewChangeDto {
    kind: DiscoveryReviewChangeKindDto,
    target_kind: DiscoveryReviewTargetKindDto,
    target_id: String,
    summary_key: String,
    evidence_ids: Vec<String>,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct DiscoveryReviewDto {
    sha256: String,
    graph_sha256: String,
    changes: Vec<DiscoveryReviewChangeDto>,
    unresolved_question_count: u32,
    warning_count: u32,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct DiscoveryReviewProposalDto {
    review: DiscoveryReviewDto,
    approval: DiscoveryApprovalProposalDto,
    commit_attempt_id: String,
    commit_plan_sha256: String,
    request_preview: Option<RequestPreviewDto>,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
enum DiscoveryAssistantCheckpointDto {
    Ready,
    AwaitingAssistant,
    AwaitingToolResult,
    AwaitingMoreEvidence,
    AwaitingRetryConsent,
    DraftReady,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
enum DiscoveryAssistantResumeActionDto {
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

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct DiscoveryAssistantResumeBoundaryDto {
    checkpoint: Option<DiscoveryAssistantCheckpointDto>,
    action: DiscoveryAssistantResumeActionDto,
    questions: Vec<UnresolvedQuestion>,
    draft_review: Option<AssistantDraftReview>,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct ProviderDiscoverySnapshotDto {
    snapshot_schema_version: u32,
    session_id: String,
    pending_connection_id: String,
    pending_display_name: String,
    connection_options: ProviderDiscoveryConnectionOptions,
    credential_slot_id: Option<String>,
    credential_slot_expected: bool,
    revision: u64,
    state: DiscoveryStateDto,
    next_event_sequence: u64,
    steps: Vec<DiscoveryStepDto>,
    action_required: Option<DiscoveryActionRequiredDto>,
    active_operation_id: Option<String>,
    recovery_operation: Option<DiscoveryOperationKindDto>,
    unknown_operation: Option<DiscoveryOperationKindDto>,
    manifest_sha256: Option<String>,
    commit_plan_sha256: Option<String>,
    commit_attempt_id: Option<String>,
    committed_connection_id: Option<String>,
    cancellation_pending: bool,
    failure: Option<DiscoveryFailureDto>,
    candidates: Vec<DiscoveryCandidateDto>,
    evidence: Vec<DiscoveryEvidenceDto>,
    approvals: Vec<DiscoveryApprovalDto>,
    review: Option<DiscoveryReviewDto>,
    approval_proposal: Option<DiscoveryApprovalProposalDto>,
    review_proposal: Option<DiscoveryReviewProposalDto>,
    assistant_resume_boundary: Option<DiscoveryAssistantResumeBoundaryDto>,
    created_at: String,
    updated_at: String,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct DiscoveryEventDto {
    event_version: u32,
    event_id: String,
    session_id: String,
    sequence: u64,
    session_revision: u64,
    state: DiscoveryStateDto,
    progress: Option<DiscoveryProgressDto>,
    action_required: Option<DiscoveryActionRequiredDto>,
    warning: Option<DiscoveryWarningDto>,
    action_id: String,
    failure: Option<DiscoveryFailureDto>,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct DiscoveryOutboxEventDto {
    event: DiscoveryEventDto,
    delivery_attempts: u32,
    available_at: String,
    created_at: String,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct DiscoveryRecoveryResultDto {
    operation_id: String,
    session_id: String,
    state: DiscoveryStateDto,
    event: DiscoveryEventDto,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
enum DiscoveryWarningDto {
    AssistantDeclined,
    ProbesSkipped,
    CompensationRequired,
    ExplicitRestartRequired,
    UnknownExternalOutcome,
}

#[derive(Debug, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum DiscoveryPreviousSelectionDto {
    None,
    RouteAndPreset {
        model_route_id: String,
        generation_preset_id: String,
    },
}

#[derive(Debug, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum DiscoveryCompensationTargetDto {
    RemoveCredentialSlot {
        connection_id: String,
        credential_ref: String,
    },
    RemoveConnectionGraph {
        connection_id: String,
    },
    RestorePreviousSelection {
        previous_selection: DiscoveryPreviousSelectionDto,
    },
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
enum DiscoveryCompensationKindDto {
    RemoveCredentialSlot,
    RemoveConnectionGraph,
    RestorePreviousSelection,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
enum DiscoveryCompensationStatusDto {
    Pending,
    InProgress,
    Completed,
    Failed,
    OutcomeUnknown,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct DiscoveryCompensationStepDto {
    id: String,
    commit_attempt_id: String,
    ordinal: u32,
    action_id: String,
    kind: DiscoveryCompensationKindDto,
    target: DiscoveryCompensationTargetDto,
    status: DiscoveryCompensationStatusDto,
    attempt_count: u32,
    last_failure: Option<DiscoveryFailureDto>,
    created_at: String,
    updated_at: String,
    completed_at: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum DiscoveryAssistantHostActionDto {
    RequestMoreEvidence {
        session_id: String,
        questions: Vec<UnresolvedQuestion>,
    },
    ReviewDraft {
        draft_review: Box<AssistantDraftReview>,
    },
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct VersionedRequest<T> {
    request_schema_version: u32,
    payload: T,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SelectGenerationTargetPayload {
    target: Option<GenerationTarget>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DeleteProviderConnectionPayload {
    connection_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct UpsertProviderConnectionPayload {
    id: String,
    template_id: String,
    template_version: u32,
    display_name: String,
    api_origin: String,
    api_base_path: Option<String>,
    network_mode: ProviderNetworkMode,
    #[serde(default)]
    local_network_approval: Option<ProviderLocalNetworkApproval>,
    #[serde(default)]
    values: Vec<ConnectionConfigEntry>,
    credential_slot_ready: bool,
    auth_binding: AuthBinding,
    #[serde(default)]
    approved_credential_origins: Vec<String>,
    credential_redirect_policy: CredentialRedirectPolicy,
    timeout_seconds: u32,
    status: ConnectionStatus,
    created_at: String,
    updated_at: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RefreshProviderModelsPayload {
    connection_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct StartProviderModelSyncPayload {
    connection_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProviderModelSyncJobPayload {
    job_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ListProviderModelSyncsPayload {
    connection_id: String,
    limit: u32,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ApproveProviderModelSyncPayload {
    job_id: String,
    review_sha256: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PollProviderModelSyncEventsPayload {
    job_id: String,
    limit: u32,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AckProviderModelSyncEventPayload {
    job_id: String,
    sequence: u64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProviderCatalogHistoryPayload {
    limit: u32,
    #[serde(default)]
    before_revision: Option<u64>,
    #[serde(default)]
    before_state_version: Option<u64>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProviderCatalogDiffPayload {
    from_revision: u64,
    to_revision: u64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PrepareProviderCatalogRollbackPayload {
    target_revision: u64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ActivateProviderCatalogRollbackPayload {
    plan_json: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ActivateSignedProviderCatalogImportPayload {
    plan_json: String,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct ProviderCatalogTemplateDiffDto {
    provider_template_id: String,
    previous_manifest_version: Option<u32>,
    next_manifest_version: Option<u32>,
    previous_sha256: Option<String>,
    next_sha256: Option<String>,
    changed_sections: Vec<String>,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct ProviderCatalogModelDiffDto {
    model_entry_id: String,
    provider_template_id: String,
    previous_metadata_version: Option<u32>,
    next_metadata_version: Option<u32>,
    previous_sha256: Option<String>,
    next_sha256: Option<String>,
    changed_sections: Vec<String>,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct ProviderCatalogDiffDto {
    diff_schema_version: u32,
    from_revision: u64,
    to_revision: u64,
    added_provider_templates: Vec<ProviderCatalogTemplateDiffDto>,
    changed_provider_templates: Vec<ProviderCatalogTemplateDiffDto>,
    removed_provider_templates: Vec<ProviderCatalogTemplateDiffDto>,
    added_models: Vec<ProviderCatalogModelDiffDto>,
    changed_models: Vec<ProviderCatalogModelDiffDto>,
    removed_models: Vec<ProviderCatalogModelDiffDto>,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct ProviderCatalogStatusDto {
    status_schema_version: u32,
    state_version: u64,
    active_revision: u64,
    active_snapshot_sha256: String,
    bundled_baseline_sha256: String,
    snapshot_count: u32,
    signed_update_count: u32,
    highest_accepted_revision: u64,
    latest_issued_at: Option<String>,
    active_signed_revisions: Vec<u64>,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct ProviderCatalogRevisionSummaryDto {
    revision: u64,
    captured_at: String,
    snapshot_sha256: String,
    signed_revisions: Vec<u64>,
    active: bool,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct ProviderCatalogActivationSummaryDto {
    action_id: String,
    state_version: u64,
    kind: String,
    from_revision: Option<u64>,
    to_revision: u64,
    activated_at: String,
    diff: ProviderCatalogDiffDto,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct ProviderCatalogHistoryDto {
    history_schema_version: u32,
    active_revision: u64,
    revisions: Vec<ProviderCatalogRevisionSummaryDto>,
    activations: Vec<ProviderCatalogActivationSummaryDto>,
    next_before_revision: Option<u64>,
    next_before_state_version: Option<u64>,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct ProviderCatalogImportReviewDto {
    plan_schema_version: u32,
    action_id: String,
    expected_state_version: u64,
    expected_active_revision: u64,
    expected_active_snapshot_sha256: String,
    expected_highest_accepted_revision: u64,
    envelope_byte_count: u64,
    envelope_sha256: String,
    signing_key_id: String,
    payload_sha256: String,
    signed_catalog_revision: u64,
    candidate_revision: u64,
    candidate_snapshot_sha256: String,
    prepared_at: String,
    expires_at: String,
    diff: ProviderCatalogDiffDto,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct ProviderCatalogImportPlanDto {
    review: ProviderCatalogImportReviewDto,
    plan_sha256: String,
    plan_json: String,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct ProviderCatalogImportResultDto {
    signed_catalog_revision: u64,
    activated_revision: u64,
    diff: ProviderCatalogDiffDto,
    status: ProviderCatalogStatusDto,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct ProviderCatalogRollbackPlanDto {
    plan_schema_version: u32,
    action_id: String,
    expected_state_version: u64,
    plan_sha256: String,
    from_revision: u64,
    to_revision: u64,
    created_at: String,
    expires_at: String,
    diff: ProviderCatalogDiffDto,
    plan_json: String,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct ProviderCatalogRollbackResultDto {
    from_revision: u64,
    activated_revision: u64,
    status: ProviderCatalogStatusDto,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct InspectProviderCurlPayload {
    connection_options: ProviderDiscoveryConnectionOptions,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ProviderDiscoveryInputPayload {
    connection_id: String,
    display_name: String,
    #[serde(default)]
    site_url: Option<String>,
    #[serde(default)]
    docs_url: Option<String>,
    credential_slot_ready: bool,
    #[serde(default)]
    preferred_assistant_model_route_id: Option<String>,
    connection_options: ProviderDiscoveryConnectionOptions,
    #[serde(default)]
    supplied_evidence_ids: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum ProviderDiscoverySourcePayload {
    KnownProvider { template_id: String },
    Site,
    Curl,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct BeginProviderDiscoveryPayload {
    input: ProviderDiscoveryInputPayload,
    source: ProviderDiscoverySourcePayload,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "resolution", rename_all = "snake_case", deny_unknown_fields)]
enum DiscoveryUnknownOutcomeResolutionPayload {
    ConfirmedNoEffect,
    ConfirmedCommitCompleted { connection_id: String },
    ConfirmedCompensated,
    ManuallyReconciledAsFailed,
}

/// User-driven actions accepted by the C ABI.
///
/// The internal completion variants from the domain state machine are
/// intentionally absent, so native callers cannot impersonate network,
/// assistant, probe, commit, or compensation results.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum ProviderDiscoveryPublicActionPayload {
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
        resolution: DiscoveryUnknownOutcomeResolutionPayload,
    },
    Cancel,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct PrepareProviderDiscoveryActionPayload {
    action_id: String,
    expected_revision: u64,
    action: ProviderDiscoveryPublicActionPayload,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct ProviderDiscoveryActionEnvelopeDto {
    action_id: String,
    expected_revision: u64,
    request_sha256: String,
    action: ProviderDiscoveryPublicActionPayload,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ContinueProviderDiscoveryPayload {
    session_id: String,
    action_id: String,
    expected_revision: u64,
    request_sha256: String,
    action: ProviderDiscoveryPublicActionPayload,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum ProviderDiscoveryAdditionalEvidencePayload {
    DocumentUrl { url: String },
    Curl,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct SupplyProviderDiscoveryEvidencePayload {
    session_id: String,
    expected_revision: u64,
    source: ProviderDiscoveryAdditionalEvidencePayload,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ProviderDiscoverySessionPayload {
    session_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ListProviderDiscoveriesPayload {
    limit: u32,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct CancelProviderDiscoveryPayload {
    session_id: String,
    expected_revision: u64,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct CommitProviderDiscoveryPayload {
    session_id: String,
    credential_reference_confirmed: bool,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct AckProviderDiscoveryEventPayload {
    event_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ListProviderDiscoveryCompensationPayload {
    commit_attempt_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ProviderDiscoveryCompensationStepPayload {
    session_id: String,
    step_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct FailProviderDiscoveryCompensationStepPayload {
    session_id: String,
    step_id: String,
    failure_code: String,
    failure_message_key: String,
    recoverable: bool,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RunProviderDiscoveryAssistantTurnPayload {
    session_id: String,
    estimate: lorepia_engine::AssistantCallEstimate,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RecordProviderDiscoveryAssistantFailurePayload {
    session_id: String,
    kind: lorepia_engine::AssistantFailureKind,
    retryable: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DeleteModelRoutePayload {
    model_route_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct EffectiveCapabilityPayload {
    model_route_id: String,
    key: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DeleteCapabilityOverridePayload {
    model_route_id: String,
    observation_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DeleteGenerationPresetPayload {
    generation_preset_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct GenerationPresetTargetPayload {
    model_route_id: String,
    generation_preset_id: String,
}

#[derive(Serialize)]
struct EffectiveCapabilityDto {
    selected: CapabilityObservation,
    alternatives: Vec<CapabilityObservation>,
    evaluated_at: String,
    selected_is_stale: bool,
    has_conflict: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SendMessageWithTargetPayload {
    conversation_id: String,
    text: String,
    target: GenerationTarget,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SendMessageToBranchWithTargetPayload {
    conversation_id: String,
    branch_id: String,
    #[serde(default)]
    expected_head: Option<String>,
    mode: ConversationMode,
    text: String,
    target: GenerationTarget,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct EditUserMessageWithTargetPayload {
    conversation_id: String,
    branch_id: String,
    #[serde(default)]
    expected_head: Option<String>,
    message_id: String,
    replacement_text: String,
    target: GenerationTarget,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RegenerateAssistantMessageWithTargetPayload {
    conversation_id: String,
    branch_id: String,
    #[serde(default)]
    expected_head: Option<String>,
    message_id: String,
    target: GenerationTarget,
}

#[derive(Serialize)]
struct ProviderTemplateDto {
    id: String,
    display_name: String,
    manifest_version: u32,
    source: String,
    api_family: String,
    default_network_mode: String,
    default_api_origin: Option<String>,
    requires_credential: bool,
    auth_binding: AuthBinding,
    supports_model_listing: bool,
    connection_fields: Vec<ConnectionFieldSpec>,
    parameter_specs: Vec<ParameterSpec>,
}

#[derive(Serialize)]
struct ProviderLocalNetworkApprovalDto {
    origin: String,
    addresses: Vec<String>,
}

#[derive(Serialize)]
struct ProviderConnectionDto {
    id: String,
    template_id: String,
    template_version: u32,
    display_name: String,
    api_origin: String,
    api_base_path: Option<String>,
    network_mode: String,
    local_network_approval: Option<ProviderLocalNetworkApprovalDto>,
    values: Vec<ConnectionConfigEntry>,
    credential_slot_required: bool,
    credential_ref: Option<String>,
    auth_binding: AuthBinding,
    approved_credential_origins: Vec<String>,
    credential_redirect_policy: String,
    timeout_seconds: u32,
    status: String,
    created_at: String,
    updated_at: String,
}

#[derive(Serialize)]
struct ModelRouteDto {
    id: String,
    connection_id: String,
    api_family: String,
    model_id: String,
    display_name: Option<String>,
    route_config: ModelRouteConfig,
    availability: String,
    miss_count: u32,
    raw_metadata_json: Option<String>,
    metadata_source: String,
    metadata_observed_at: Option<String>,
    last_reconciled_sync_job_id: Option<String>,
    metadata_sync_job_id: Option<String>,
    first_seen_at: String,
    last_seen_at: Option<String>,
}

#[derive(Serialize)]
struct GenerationPresetDto {
    id: String,
    model_route_id: String,
    display_name: String,
    values: Vec<ParameterValue>,
    reasoning: GenerationReasoningSettings,
    prompt_cache: GenerationPromptCacheSettings,
    created_at: String,
    updated_at: String,
}

#[derive(Serialize)]
struct ProviderModelRefreshProvenanceDto {
    source: String,
    api_family: String,
    api_origin: String,
    endpoint_path: String,
}

#[derive(Serialize)]
struct ProviderModelRefreshResultDto {
    connection_id: String,
    model_routes: Vec<ModelRouteDto>,
    newly_seen_model_route_ids: Vec<String>,
    missing_model_route_ids: Vec<String>,
    created_generation_preset_ids: Vec<String>,
    routes_requiring_preset_configuration: Vec<String>,
    provenance: ProviderModelRefreshProvenanceDto,
    pages_fetched: u32,
    response_bytes: u64,
    observed_at: String,
}

#[derive(Serialize)]
struct ModelSyncStartedDto {
    job_id: String,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct RequestBodyFieldDto {
    name: String,
    shape: RequestBodyShapeDto,
}

#[derive(Debug, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum RequestBodyShapeDto {
    Null,
    Boolean,
    Number,
    String,
    Array {
        items: Vec<RequestBodyShapeDto>,
        truncated: bool,
    },
    Object {
        fields: Vec<RequestBodyFieldDto>,
        truncated: bool,
    },
    Redacted,
    Truncated,
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
#[allow(clippy::struct_excessive_bools)]
struct RequestPreviewDto {
    redaction_version: u32,
    method: String,
    origin: String,
    path: String,
    header_names: Vec<String>,
    query_parameter_names: Vec<String>,
    body_shape: Option<RequestBodyShapeDto>,
    body_truncated: bool,
    includes_private_message: bool,
    includes_credential_value: bool,
    includes_opaque_reasoning_state: bool,
}

#[unsafe(no_mangle)]
pub extern "C" fn lorepia_abi_version() -> u32 {
    ABI_VERSION
}

/// Creates a core from UTF-8 JSON.
///
/// # Safety
///
/// `config_json` must reference `config_len` readable bytes and `out_core` must
/// be a valid writable pointer. The returned handle is owned by the caller and
/// must be destroyed exactly once with [`lorepia_core_destroy`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_create(
    config_json: *const u8,
    config_len: usize,
    out_core: *mut *mut LorepiaCoreHandle,
) -> i32 {
    clear_thread_error();
    if out_core.is_null() {
        return fail_without_handle(CoreError::invalid("out_core must not be null"));
    }
    // SAFETY: `out_core` was checked and is writable by caller contract.
    unsafe { out_core.write(ptr::null_mut()) };

    match catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller guarantees the input range is readable.
        let config_text = unsafe { read_utf8(config_json, config_len, "config_json") }?;
        let config: CApiConfig = serde_json::from_str(config_text)
            .map_err(|_| CoreError::invalid("config_json must be valid configuration JSON"))?;
        if config.data_root.trim().is_empty() || !Path::new(&config.data_root).is_absolute() {
            return Err(CoreError::invalid(
                "config_json.data_root must be a non-empty absolute path",
            ));
        }
        let core = Core::open(CoreConfig::new(config.data_root))?;
        let events = core.subscribe_events();
        let handle = Box::new(LorepiaCoreHandle {
            core,
            events: Mutex::new(events),
            last_error: Mutex::new(None),
        });
        // SAFETY: `out_core` is a valid writable pointer by caller contract.
        unsafe { out_core.write(Box::into_raw(handle)) };
        Ok(())
    })) {
        Ok(Ok(())) => STATUS_OK,
        Ok(Err(error)) => fail_without_handle(error),
        Err(_) => fail_without_handle(CoreError::internal(
            "panic was contained at the C ABI boundary",
        )),
    }
}

/// Destroys an owned core handle. A null handle is ignored.
///
/// # Safety
///
/// `core` must be null or a live handle returned by this library and not
/// previously destroyed. No call may race with destruction.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_destroy(core: *mut LorepiaCoreHandle) {
    if !core.is_null() {
        // SAFETY: guaranteed by the caller contract.
        drop(unsafe { Box::from_raw(core) });
    }
}

/// Returns the last structured error as UTF-8 JSON.
///
/// Pass a live handle for the most recent error on that handle. Pass null to
/// retrieve a create-time or null-handle error for the current thread. A JSON
/// `null` means there is no recorded error.
///
/// # Safety
///
/// A non-null `core` must be a live handle and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_last_error_json(
    core: *const LorepiaCoreHandle,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    if out_buffer.is_null() {
        return fail_without_handle(CoreError::invalid("out_buffer must not be null"));
    }
    // SAFETY: `out_buffer` is writable by caller contract.
    unsafe { out_buffer.write(LorepiaBuffer::default()) };

    match catch_unwind(AssertUnwindSafe(|| {
        let error = if core.is_null() {
            THREAD_LAST_ERROR.with(|slot| slot.borrow().clone())
        } else {
            // SAFETY: a non-null handle is live by caller contract.
            last_error(unsafe { &*core })
        };
        let bytes = serde_json::to_vec(&error)
            .map_err(|_| CoreError::internal("cannot serialize the last C ABI error"))?;
        // SAFETY: `out_buffer` was initialized above and remains writable.
        unsafe { write_buffer(out_buffer, bytes) }
    })) {
        Ok(Ok(())) => STATUS_OK,
        Ok(Err(error)) => fail_without_handle(error),
        Err(_) => fail_without_handle(CoreError::internal(
            "panic was contained while reading the last C ABI error",
        )),
    }
}

/// Returns the core version as an owned UTF-8 buffer.
///
/// # Safety
///
/// `core` must be a live handle and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_version(
    core: *const LorepiaCoreHandle,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        run_core_call(core, |handle| {
            prepare_output(out_buffer)?;
            write_buffer(
                out_buffer,
                lorepia_engine::core_version().as_bytes().to_vec(),
            )?;
            let _ = handle;
            Ok(())
        })
    }
}

/// Serializes the health report as UTF-8 JSON.
///
/// # Safety
///
/// `core` must be a live handle and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_health_check_json(
    core: *const LorepiaCoreHandle,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe { core_json(core, out_buffer, |handle| handle.core.health_check()) }
}

/// Inspects a staged content file and returns the review model as UTF-8 JSON.
///
/// # Safety
///
/// `core` must be live, `staged_path` must reference `staged_path_len` readable
/// UTF-8 bytes, and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_inspect_import_json(
    core: *const LorepiaCoreHandle,
    staged_path: *const u8,
    staged_path_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let path = read_utf8(staged_path, staged_path_len, "staged_path")?;
            handle.core.inspect_import(path)
        })
    }
}

/// Commits a previously approved inspection and returns the character as JSON.
///
/// # Safety
///
/// `core` must be live, `inspection_id` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_commit_import_json(
    core: *const LorepiaCoreHandle,
    inspection_id: *const u8,
    inspection_id_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let id = read_utf8(inspection_id, inspection_id_len, "inspection_id")?;
            handle.core.commit_import(&InspectionId(id.to_owned()))
        })
    }
}

/// Discards a pending inspection and its core-owned staging snapshot.
///
/// # Safety
///
/// `core` must be live and `inspection_id` must reference readable UTF-8 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_discard_import(
    core: *const LorepiaCoreHandle,
    inspection_id: *const u8,
    inspection_id_len: usize,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        run_core_call(core, |handle| {
            let id = read_utf8(inspection_id, inspection_id_len, "inspection_id")?;
            handle.core.discard_import(&InspectionId(id.to_owned()))
        })
    }
}

/// Serializes the local character list as UTF-8 JSON.
///
/// # Safety
///
/// `core` must be live and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_list_characters_json(
    core: *const LorepiaCoreHandle,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe { core_json(core, out_buffer, |handle| handle.core.list_characters()) }
}

/// Serializes one local character as UTF-8 JSON.
///
/// # Safety
///
/// `core` must be live, `character_id` must reference readable UTF-8 bytes, and
/// `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_get_character_json(
    core: *const LorepiaCoreHandle,
    character_id: *const u8,
    character_id_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let id = read_utf8(character_id, character_id_len, "character_id")?;
            handle.core.get_character(id)
        })
    }
}

/// Opens a new conversation for a character and returns it as UTF-8 JSON.
///
/// # Safety
///
/// `core` must be live, `character_id` must reference readable UTF-8 bytes, and
/// `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_open_conversation_json(
    core: *const LorepiaCoreHandle,
    character_id: *const u8,
    character_id_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let id = read_utf8(character_id, character_id_len, "character_id")?;
            handle.core.open_conversation(id)
        })
    }
}

/// Serializes all local conversations as UTF-8 JSON.
///
/// # Safety
///
/// `core` must be live and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_list_conversations_json(
    core: *const LorepiaCoreHandle,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe { core_json(core, out_buffer, |handle| handle.core.list_conversations()) }
}

/// Serializes all messages in a conversation as UTF-8 JSON.
///
/// # Safety
///
/// `core` must be live, `conversation_id` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_list_messages_json(
    core: *const LorepiaCoreHandle,
    conversation_id: *const u8,
    conversation_id_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let id = read_utf8(conversation_id, conversation_id_len, "conversation_id")?;
            handle.core.list_messages(&ConversationId(id.to_owned()))
        })
    }
}

/// Starts one generation and returns its generation ID as UTF-8 JSON.
///
/// Set `credential_present` to zero and pass a null pointer with zero length
/// when no credential is available. Set it to one for a present credential.
///
/// # Safety
///
/// `core` must be live. Every present text pointer must reference its declared
/// number of readable UTF-8 bytes. `out_buffer` must be writable.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn lorepia_core_send_message_json(
    core: *const LorepiaCoreHandle,
    conversation_id: *const u8,
    conversation_id_len: usize,
    text: *const u8,
    text_len: usize,
    provider_profile_id: *const u8,
    provider_profile_id_len: usize,
    credential: *const u8,
    credential_len: usize,
    credential_present: u8,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let conversation_id =
                read_utf8(conversation_id, conversation_id_len, "conversation_id")?;
            let text = read_utf8(text, text_len, "text")?;
            let provider_profile_id = read_utf8(
                provider_profile_id,
                provider_profile_id_len,
                "provider_profile_id",
            )?;
            let credential =
                read_optional_utf8(credential, credential_len, credential_present, "credential")?;
            handle.core.send_message(
                &ConversationId(conversation_id.to_owned()),
                text,
                provider_profile_id,
                credential.map(str::to_owned),
            )
        })
    }
}

/// Starts one generation using a versioned provider catalog target request.
///
/// `request_json` must be a schema-version-one envelope. The raw credential is
/// deliberately carried outside that JSON envelope and exists only for this
/// call.
///
/// # Safety
///
/// `core` must be live. Every present pointer must reference its declared
/// number of readable UTF-8 bytes. `out_buffer` must be writable.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn lorepia_core_send_message_with_target_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    credential: *const u8,
    credential_len: usize,
    credential_present: u8,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: SendMessageWithTargetPayload =
                parse_versioned_request(json, "request_json")?;
            let credential =
                read_optional_utf8(credential, credential_len, credential_present, "credential")?;
            handle.core.send_message_with_target(
                &ConversationId(payload.conversation_id),
                &payload.text,
                &payload.target,
                credential.map(str::to_owned),
            )
        })
    }
}

/// Starts one generation on an explicit branch using a versioned provider
/// catalog target request.
///
/// # Safety
///
/// `core` must be live. Every present pointer must reference its declared
/// number of readable UTF-8 bytes. `out_buffer` must be writable.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn lorepia_core_send_message_to_branch_with_target_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    credential: *const u8,
    credential_len: usize,
    credential_present: u8,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: SendMessageToBranchWithTargetPayload =
                parse_versioned_request(json, "request_json")?;
            let expected_head = payload.expected_head.map(MessageId);
            let credential =
                read_optional_utf8(credential, credential_len, credential_present, "credential")?;
            handle.core.send_message_to_branch_with_target(
                &ConversationId(payload.conversation_id),
                &ConversationBranchId(payload.branch_id),
                expected_head.as_ref(),
                payload.mode,
                &payload.text,
                &payload.target,
                credential.map(str::to_owned),
            )
        })
    }
}

/// Forks a branch from an edited user message and starts a target-based
/// generation.
///
/// # Safety
///
/// `core` must be live. Every present pointer must reference its declared
/// number of readable UTF-8 bytes. `out_buffer` must be writable.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn lorepia_core_edit_user_message_with_target_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    credential: *const u8,
    credential_len: usize,
    credential_present: u8,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: EditUserMessageWithTargetPayload =
                parse_versioned_request(json, "request_json")?;
            let expected_head = payload.expected_head.map(MessageId);
            let credential =
                read_optional_utf8(credential, credential_len, credential_present, "credential")?;
            handle.core.edit_user_message_with_target(
                &ConversationId(payload.conversation_id),
                &ConversationBranchId(payload.branch_id),
                expected_head.as_ref(),
                &MessageId(payload.message_id),
                &payload.replacement_text,
                &payload.target,
                credential.map(str::to_owned),
            )
        })
    }
}

/// Forks a branch and regenerates an assistant message using a provider catalog
/// target.
///
/// # Safety
///
/// `core` must be live. Every present pointer must reference its declared
/// number of readable UTF-8 bytes. `out_buffer` must be writable.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn lorepia_core_regenerate_assistant_message_with_target_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    credential: *const u8,
    credential_len: usize,
    credential_present: u8,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: RegenerateAssistantMessageWithTargetPayload =
                parse_versioned_request(json, "request_json")?;
            let expected_head = payload.expected_head.map(MessageId);
            let credential =
                read_optional_utf8(credential, credential_len, credential_present, "credential")?;
            handle.core.regenerate_assistant_message_with_target(
                &ConversationId(payload.conversation_id),
                &ConversationBranchId(payload.branch_id),
                expected_head.as_ref(),
                &MessageId(payload.message_id),
                &payload.target,
                credential.map(str::to_owned),
            )
        })
    }
}

/// Cancels an active generation.
///
/// # Safety
///
/// `core` must be live and `generation_id` must reference readable UTF-8 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_cancel_generation(
    core: *const LorepiaCoreHandle,
    generation_id: *const u8,
    generation_id_len: usize,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        run_core_call(core, |handle| {
            let id = read_utf8(generation_id, generation_id_len, "generation_id")?;
            handle.core.cancel_generation(&GenerationId(id.to_owned()))
        })
    }
}

/// Returns up to `max_events` queued events as one UTF-8 JSON batch.
///
/// The result has `events` and `dropped_events` fields. A non-zero
/// `dropped_events` value tells the caller to refresh persisted messages.
///
/// # Safety
///
/// `core` must be live and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_poll_events_json(
    core: *const LorepiaCoreHandle,
    max_events: u32,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            if max_events == 0 || max_events > MAX_EVENT_BATCH_SIZE {
                return Err(CoreError::invalid("max_events must be between 1 and 1024"));
            }
            let mut receiver = lock(&handle.events, "event receiver")?;
            let mut events = Vec::with_capacity(max_events as usize);
            let mut dropped_events = 0_u64;
            while events.len() < max_events as usize {
                match receiver.try_recv() {
                    Ok(event) => events.push(event),
                    Err(
                        broadcast::error::TryRecvError::Empty
                        | broadcast::error::TryRecvError::Closed,
                    ) => break,
                    Err(broadcast::error::TryRecvError::Lagged(count)) => {
                        dropped_events = dropped_events.saturating_add(count);
                    }
                }
            }
            Ok(EventBatch {
                events,
                dropped_events,
            })
        })
    }
}

/// Serializes the current app settings as UTF-8 JSON.
///
/// # Safety
///
/// `core` must be live and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_get_settings_json(
    core: *const LorepiaCoreHandle,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe { core_json(core, out_buffer, |handle| handle.core.get_settings()) }
}

/// Replaces app settings from UTF-8 JSON.
///
/// # Safety
///
/// `core` must be live and `settings_json` must reference readable UTF-8 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_update_settings_json(
    core: *const LorepiaCoreHandle,
    settings_json: *const u8,
    settings_json_len: usize,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        run_core_call(core, |handle| {
            let json = read_utf8(settings_json, settings_json_len, "settings_json")?;
            let settings: AppSettings = parse_json(json, "settings_json")?;
            handle.core.update_settings(&settings)
        })
    }
}

/// Serializes the built-in and installed provider templates as stable UTF-8
/// JSON DTOs.
///
/// # Safety
///
/// `core` must be live and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_list_provider_templates_json(
    core: *const LorepiaCoreHandle,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            handle.core.list_provider_template_views().map(|templates| {
                templates
                    .into_iter()
                    .map(map_provider_template_view)
                    .collect::<Vec<_>>()
            })
        })
    }
}

/// Creates a provider connection from a schema-version-one JSON envelope and
/// returns a credential-free connection DTO.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_create_provider_connection_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let draft: ProviderConnectionDraft = parse_versioned_request(json, "request_json")?;
            handle
                .core
                .create_provider_connection(draft)
                .map(map_provider_connection)
        })
    }
}

/// Serializes all provider connections as credential-free UTF-8 JSON DTOs.
///
/// # Safety
///
/// `core` must be live and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_list_provider_connections_json(
    core: *const LorepiaCoreHandle,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            handle.core.list_provider_connections().map(|connections| {
                connections
                    .into_iter()
                    .map(map_provider_connection)
                    .collect::<Vec<_>>()
            })
        })
    }
}

/// Creates or replaces a non-secret provider connection record using a
/// schema-version-one JSON envelope.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_upsert_provider_connection_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: UpsertProviderConnectionPayload =
                parse_versioned_request(json, "request_json")?;
            let connection = unmap_provider_connection(payload)?;
            handle
                .core
                .upsert_provider_connection(connection)
                .map(map_provider_connection)
        })
    }
}

/// Deletes a provider connection selected by a schema-version-one JSON
/// envelope.
///
/// # Safety
///
/// `core` must be live and `request_json` must reference readable UTF-8 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_delete_provider_connection_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        run_core_call(core, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: DeleteProviderConnectionPayload =
                parse_versioned_request(json, "request_json")?;
            handle
                .core
                .delete_provider_connection(&ProviderConnectionId::from(payload.connection_id))
        })
    }
}

/// Serializes all model routes for one provider connection as UTF-8 JSON DTOs.
///
/// # Safety
///
/// `core` must be live, `connection_id` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_list_model_routes_json(
    core: *const LorepiaCoreHandle,
    connection_id: *const u8,
    connection_id_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let connection_id = read_utf8(connection_id, connection_id_len, "connection_id")?;
            handle
                .core
                .list_model_routes(&ProviderConnectionId::from(connection_id))
                .map(|routes| routes.into_iter().map(map_model_route).collect::<Vec<_>>())
        })
    }
}

/// Creates or replaces one model route using a schema-version-one JSON
/// envelope.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_upsert_model_route_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let route: ModelRoute = parse_versioned_request(json, "request_json")?;
            handle.core.upsert_model_route(route).map(map_model_route)
        })
    }
}

/// Deletes one unreferenced model route using a schema-version-one JSON
/// envelope.
///
/// # Safety
///
/// `core` must be live and `request_json` must reference readable UTF-8 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_delete_model_route_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        run_core_call(core, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: DeleteModelRoutePayload = parse_versioned_request(json, "request_json")?;
            handle
                .core
                .delete_model_route(&ModelRouteId::from(payload.model_route_id))
        })
    }
}

/// Serializes source-attributed capability observations for one model route.
///
/// # Safety
///
/// `core` must be live, `model_route_id` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_list_capability_observations_json(
    core: *const LorepiaCoreHandle,
    model_route_id: *const u8,
    model_route_id_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let model_route_id = read_utf8(model_route_id, model_route_id_len, "model_route_id")?;
            handle
                .core
                .list_capability_observations(&ModelRouteId::from(model_route_id))
        })
    }
}

/// Serializes the effective capability and its visible alternatives.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_get_effective_capability_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: EffectiveCapabilityPayload =
                parse_versioned_request(json, "request_json")?;
            handle
                .core
                .effective_capability(
                    &ModelRouteId::from(payload.model_route_id),
                    parse_capability_key(&payload.key)?,
                )
                .map(|value| value.map(map_effective_capability))
        })
    }
}

/// Serializes the effective route-specific parameter contract after active
/// signed-catalog projection and freshness filtering.
///
/// # Safety
///
/// `core` must be live, `model_route_id` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_effective_parameter_specs_json(
    core: *const LorepiaCoreHandle,
    model_route_id: *const u8,
    model_route_id_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let model_route_id = read_utf8(model_route_id, model_route_id_len, "model_route_id")?;
            handle
                .core
                .effective_parameter_specs(&ModelRouteId::from(model_route_id))
        })
    }
}

/// Stores one local user capability override.
///
/// Trusted provider, catalog, documentation, probe, and assistant provenance
/// cannot be written through this entry point.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_upsert_user_capability_override_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let observation: CapabilityObservation = parse_versioned_request(json, "request_json")?;
            handle.core.upsert_user_capability_override(observation)
        })
    }
}

/// Deletes one local user capability override.
///
/// # Safety
///
/// `core` must be live and `request_json` must reference readable UTF-8 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_delete_user_capability_override_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        run_core_call(core, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: DeleteCapabilityOverridePayload =
                parse_versioned_request(json, "request_json")?;
            handle.core.delete_user_capability_override(
                &ModelRouteId::from(payload.model_route_id),
                &ObservationId::from(payload.observation_id),
            )
        })
    }
}

/// Fetches and atomically reconciles models for one connection.
///
/// The request is a schema-version-one JSON envelope containing only the
/// connection identifier. Credential material is a separate request-scoped
/// scalar and is never serialized in the request or result.
///
/// # Safety
///
/// `core` must be live. Every present pointer must reference its declared
/// number of readable UTF-8 bytes and `out_buffer` must be writable.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
#[allow(deprecated)]
pub unsafe extern "C" fn lorepia_core_refresh_provider_models_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    credential: *const u8,
    credential_len: usize,
    credential_present: u8,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: RefreshProviderModelsPayload =
                parse_versioned_request(json, "request_json")?;
            let credential =
                read_optional_utf8(credential, credential_len, credential_present, "credential")?;
            handle
                .core
                .refresh_provider_models(
                    &ProviderConnectionId::from(payload.connection_id),
                    credential,
                )
                .map(map_provider_model_refresh_result)
        })
    }
}

/// Starts one durable, review-gated model synchronization.
///
/// Credential material is a separate request-scoped scalar and is never a
/// member of the persisted job, review, event, or JSON request envelope.
///
/// # Safety
///
/// `core` must be live. Every present pointer must reference its declared
/// number of readable UTF-8 bytes and `out_buffer` must be writable.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn lorepia_core_start_provider_model_sync_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    credential: *const u8,
    credential_len: usize,
    credential_present: u8,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: StartProviderModelSyncPayload =
                parse_versioned_request(json, "request_json")?;
            let credential =
                read_optional_utf8(credential, credential_len, credential_present, "credential")?;
            handle
                .core
                .start_provider_model_sync(
                    &ProviderConnectionId::from(payload.connection_id),
                    credential.map(str::to_owned),
                )
                .map(|job_id| ModelSyncStartedDto {
                    job_id: job_id.into_inner(),
                })
        })
    }
}

/// Returns one durable model synchronization job and its reviewed diff.
///
/// # Safety
///
/// `core` must be live. `request_json` must reference readable UTF-8 and
/// `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_get_provider_model_sync_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: ProviderModelSyncJobPayload =
                parse_versioned_request(json, "request_json")?;
            handle
                .core
                .get_provider_model_sync(&ModelSyncJobId::from(payload.job_id))
        })
    }
}

/// Lists recent durable synchronization jobs for one connection so native
/// clients can recover awaiting-review and interrupted work after restart.
///
/// # Safety
///
/// `core` must be live. `request_json` must reference readable UTF-8 and
/// `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_list_provider_model_syncs_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: ListProviderModelSyncsPayload =
                parse_versioned_request(json, "request_json")?;
            handle.core.list_provider_model_syncs(
                &ProviderConnectionId::from(payload.connection_id),
                payload.limit,
            )
        })
    }
}

/// Approves the exact canonical review digest and atomically commits its diff.
///
/// # Safety
///
/// `core` must be live. `request_json` must reference readable UTF-8 and
/// `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_approve_provider_model_sync_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: ApproveProviderModelSyncPayload =
                parse_versioned_request(json, "request_json")?;
            handle.core.approve_provider_model_sync(
                &ModelSyncJobId::from(payload.job_id),
                &payload.review_sha256,
            )
        })
    }
}

/// Cancels a nonterminal model synchronization job.
///
/// # Safety
///
/// `core` must be live. `request_json` must reference readable UTF-8 and
/// `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_cancel_provider_model_sync_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: ProviderModelSyncJobPayload =
                parse_versioned_request(json, "request_json")?;
            handle
                .core
                .cancel_provider_model_sync(&ModelSyncJobId::from(payload.job_id))
        })
    }
}

/// Polls one model-sync job without consuming another job's events.
///
/// # Safety
///
/// `core` must be live. `request_json` must reference readable UTF-8 bytes and
/// `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_poll_provider_model_sync_job_events_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: PollProviderModelSyncEventsPayload =
                parse_versioned_request(json, "request_json")?;
            handle.core.poll_provider_model_sync_events(
                &ModelSyncJobId::from(payload.job_id),
                payload.limit,
            )
        })
    }
}

/// Acknowledges exactly one model-sync event identified by job and sequence.
///
/// # Safety
///
/// `core` must be live. `request_json` must reference readable UTF-8 bytes and
/// `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_ack_provider_model_sync_event_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: AckProviderModelSyncEventPayload =
                parse_versioned_request(json, "request_json")?;
            handle.core.ack_provider_model_sync_event(
                &ModelSyncJobId::from(payload.job_id),
                payload.sequence,
            )
        })
    }
}

/// Inspects one pasted cURL command without persisting the raw command or a
/// detected credential.
///
/// Safe metadata and credential material are returned in separate owned
/// buffers. The credential buffer is copied immediately to the native vault
/// and both buffers are disposed with [`lorepia_buffer_free`].
///
/// # Safety
///
/// `core` must be live, `request_json` and `raw_curl` must reference readable
/// UTF-8 bytes, and both output pointers must be writable, non-null, and
/// distinct.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_inspect_provider_curl_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    raw_curl: *const u8,
    raw_curl_len: usize,
    out_metadata: *mut LorepiaBuffer,
    out_credential: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        run_core_call(core, |handle| {
            if out_metadata == out_credential {
                return Err(CoreError::invalid(
                    "out_metadata and out_credential must be distinct",
                ));
            }
            prepare_output(out_metadata)?;
            prepare_output(out_credential)?;
            let request = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: InspectProviderCurlPayload =
                parse_versioned_request(request, "request_json")?;
            let raw_curl = read_utf8(raw_curl, raw_curl_len, "raw_curl")?;
            let inspection = handle.core.inspect_provider_curl(
                SecretCurlInput::from(raw_curl.to_owned()),
                payload.connection_options,
            )?;
            let metadata = map_provider_curl_inspection(&inspection);
            let metadata_bytes = serde_json::to_vec(&metadata)
                .map_err(|_| CoreError::internal("cannot serialize cURL inspection metadata"))?;
            let credential_bytes = inspection
                .extracted_credential()
                .map(<[u8]>::to_vec)
                .unwrap_or_default();
            write_buffer(out_metadata, metadata_bytes)?;
            write_buffer(out_credential, credential_bytes)
        })
    }
}

/// Begins provider discovery from a known template, a site, or one one-shot
/// cURL command and returns a secret-free aggregate snapshot.
///
/// # Safety
///
/// `core` must be live. `request_json` and every present cURL pointer must
/// reference the declared number of readable UTF-8 bytes. `out_buffer` must be
/// writable.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn lorepia_core_begin_provider_discovery_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    raw_curl: *const u8,
    raw_curl_len: usize,
    raw_curl_present: u8,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: BeginProviderDiscoveryPayload =
                parse_versioned_request(json, "request_json")?;
            let raw_curl =
                read_optional_utf8(raw_curl, raw_curl_len, raw_curl_present, "raw_curl")?;
            let snapshot = match payload.source {
                ProviderDiscoverySourcePayload::KnownProvider { template_id } => {
                    if raw_curl.is_some() {
                        return Err(CoreError::invalid(
                            "raw_curl must be absent for known-provider discovery",
                        ));
                    }
                    let input = unmap_provider_discovery_input(
                        &handle.core,
                        payload.input,
                        Some(&template_id),
                    )?;
                    handle.core.begin_provider_discovery_known(
                        input,
                        ProviderTemplateId::from(template_id),
                    )?
                }
                ProviderDiscoverySourcePayload::Site => {
                    if raw_curl.is_some() {
                        return Err(CoreError::invalid(
                            "raw_curl must be absent for site discovery",
                        ));
                    }
                    let input = unmap_provider_discovery_input(&handle.core, payload.input, None)?;
                    handle.core.begin_provider_discovery_site(input)?
                }
                ProviderDiscoverySourcePayload::Curl => {
                    let raw_curl = raw_curl.ok_or_else(|| {
                        CoreError::invalid("raw_curl must be present for cURL discovery")
                    })?;
                    let input = unmap_provider_discovery_curl_input(payload.input)?;
                    handle.core.begin_provider_discovery_curl(
                        input,
                        SecretCurlInput::from(raw_curl.to_owned()),
                    )?
                }
            };
            map_provider_discovery_snapshot(&handle.core, snapshot)
        })
    }
}

/// Builds the canonical hash-bound envelope for one closed public discovery
/// action.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_prepare_provider_discovery_action_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: PrepareProviderDiscoveryActionPayload =
                parse_versioned_request(json, "request_json")?;
            let public_action = payload.action.clone();
            let envelope = provider_discovery_action_envelope(
                parse_discovery_action_id(payload.action_id)?,
                payload.expected_revision,
                unmap_provider_discovery_action(payload.action)?,
            )?;
            let _ = handle;
            Ok(ProviderDiscoveryActionEnvelopeDto {
                action_id: envelope.id.as_str().to_owned(),
                expected_revision: envelope.expected_revision,
                request_sha256: envelope.request_sha256,
                action: public_action,
            })
        })
    }
}

/// Returns one secret-free provider-discovery aggregate.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_get_provider_discovery_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: ProviderDiscoverySessionPayload =
                parse_versioned_request(json, "request_json")?;
            let snapshot = handle
                .core
                .get_provider_discovery(&DiscoverySessionId::from(payload.session_id))?;
            map_provider_discovery_snapshot(&handle.core, snapshot)
        })
    }
}

/// Lists a bounded page of secret-free provider-discovery aggregates.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_list_provider_discoveries_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: ListProviderDiscoveriesPayload =
                parse_versioned_request(json, "request_json")?;
            validate_provider_discovery_list_limit(payload.limit)?;
            handle
                .core
                .list_provider_discoveries(payload.limit)?
                .into_iter()
                .map(|snapshot| map_provider_discovery_snapshot(&handle.core, snapshot))
                .collect::<CoreResult<Vec<_>>>()
        })
    }
}

/// Lists bounded, redacted candidates for one discovery session.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_list_provider_discovery_candidates_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: ProviderDiscoverySessionPayload =
                parse_versioned_request(json, "request_json")?;
            handle
                .core
                .list_provider_discovery_candidates(&DiscoverySessionId::from(payload.session_id))
                .map(|records| {
                    records
                        .into_iter()
                        .map(map_discovery_candidate)
                        .collect::<Vec<_>>()
                })
        })
    }
}

/// Lists redacted evidence metadata for one discovery session.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_list_provider_discovery_evidence_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: ProviderDiscoverySessionPayload =
                parse_versioned_request(json, "request_json")?;
            handle
                .core
                .list_provider_discovery_evidence(&DiscoverySessionId::from(payload.session_id))
                .map(|records| {
                    records
                        .into_iter()
                        .map(map_discovery_evidence)
                        .collect::<Vec<_>>()
                })
        })
    }
}

/// Lists immutable approval records for one discovery session.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_list_provider_discovery_approvals_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: ProviderDiscoverySessionPayload =
                parse_versioned_request(json, "request_json")?;
            handle
                .core
                .list_provider_discovery_approvals(&DiscoverySessionId::from(payload.session_id))
                .map(|records| {
                    records
                        .into_iter()
                        .map(map_discovery_approval)
                        .collect::<Vec<_>>()
                })
        })
    }
}

/// Returns the persisted review diff for one discovery session.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_get_provider_discovery_review_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: ProviderDiscoverySessionPayload =
                parse_versioned_request(json, "request_json")?;
            handle
                .core
                .get_provider_discovery_review(&DiscoverySessionId::from(payload.session_id))
                .and_then(|review| review.map(map_discovery_review).transpose())
        })
    }
}

/// Returns the exact immutable approval proposal for the current waiting state.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_get_provider_discovery_approval_proposal_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: ProviderDiscoverySessionPayload =
                parse_versioned_request(json, "request_json")?;
            handle
                .core
                .get_provider_discovery_approval_proposal(&DiscoverySessionId::from(
                    payload.session_id,
                ))
                .map(|proposal| proposal.map(map_discovery_approval_proposal))
        })
    }
}

/// Returns the review proposal, commit bindings, and scalar-free request
/// preview for the current waiting state.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_get_provider_discovery_review_proposal_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: ProviderDiscoverySessionPayload =
                parse_versioned_request(json, "request_json")?;
            handle
                .core
                .get_provider_discovery_review_proposal(&DiscoverySessionId::from(
                    payload.session_id,
                ))
                .and_then(|proposal| proposal.map(map_discovery_review_proposal).transpose())
        })
    }
}

/// Continues one discovery with a hash-bound public action and an optional
/// request-scoped credential.
///
/// # Safety
///
/// `core` must be live. Every present pointer must reference its declared
/// number of readable UTF-8 bytes and `out_buffer` must be writable.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn lorepia_core_continue_provider_discovery_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    credential: *const u8,
    credential_len: usize,
    credential_present: u8,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: ContinueProviderDiscoveryPayload =
                parse_versioned_request(json, "request_json")?;
            let credential =
                read_optional_utf8(credential, credential_len, credential_present, "credential")?;
            let session_id = DiscoverySessionId::from(payload.session_id);
            let envelope = DiscoveryActionEnvelope {
                id: parse_discovery_action_id(payload.action_id)?,
                expected_revision: payload.expected_revision,
                request_sha256: payload.request_sha256,
                action: unmap_provider_discovery_action(payload.action)?,
            };
            let snapshot =
                handle
                    .core
                    .continue_provider_discovery(&session_id, envelope, credential)?;
            map_provider_discovery_snapshot(&handle.core, snapshot)
        })
    }
}

/// Supplies one fresh, one-shot evidence source while discovery is waiting for
/// more evidence.
///
/// # Safety
///
/// `core` must be live. `request_json` and every present cURL pointer must
/// reference the declared number of readable UTF-8 bytes. `out_buffer` must be
/// writable.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn lorepia_core_supply_provider_discovery_evidence_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    raw_curl: *const u8,
    raw_curl_len: usize,
    raw_curl_present: u8,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: SupplyProviderDiscoveryEvidencePayload =
                parse_versioned_request(json, "request_json")?;
            let raw_curl =
                read_optional_utf8(raw_curl, raw_curl_len, raw_curl_present, "raw_curl")?;
            let source = match payload.source {
                ProviderDiscoveryAdditionalEvidencePayload::DocumentUrl { url } => {
                    if raw_curl.is_some() {
                        return Err(CoreError::invalid(
                            "raw_curl must be absent for document evidence",
                        ));
                    }
                    ProviderDiscoveryAdditionalEvidence::document_url(parse_discovery_http_url(
                        url,
                        "source.url",
                    )?)
                }
                ProviderDiscoveryAdditionalEvidencePayload::Curl => {
                    let raw_curl = raw_curl.ok_or_else(|| {
                        CoreError::invalid("raw_curl must be present for cURL evidence")
                    })?;
                    ProviderDiscoveryAdditionalEvidence::curl(SecretCurlInput::from(
                        raw_curl.to_owned(),
                    ))
                }
            };
            let snapshot = handle.core.supply_provider_discovery_evidence(
                &DiscoverySessionId::from(payload.session_id),
                payload.expected_revision,
                source,
            )?;
            map_provider_discovery_snapshot(&handle.core, snapshot)
        })
    }
}

/// Requests cancellation with an explicit compare-and-swap revision.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_cancel_provider_discovery_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: CancelProviderDiscoveryPayload =
                parse_versioned_request(json, "request_json")?;
            let snapshot = handle.core.cancel_provider_discovery(
                &DiscoverySessionId::from(payload.session_id),
                payload.expected_revision,
            )?;
            map_provider_discovery_snapshot(&handle.core, snapshot)
        })
    }
}

/// Executes an already approved commit and returns the committed, secret-free
/// provider connection.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_commit_provider_discovery_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: CommitProviderDiscoveryPayload =
                parse_versioned_request(json, "request_json")?;
            handle
                .core
                .commit_provider_discovery(
                    &DiscoverySessionId::from(payload.session_id),
                    payload.credential_reference_confirmed,
                )
                .map(map_provider_connection)
        })
    }
}

/// Marks unfinished discovery work interrupted or outcome-unknown without
/// replaying any external effect.
///
/// # Safety
///
/// `core` must be live and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_recover_provider_discoveries_json(
    core: *const LorepiaCoreHandle,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            handle
                .core
                .recover_provider_discovery(std::time::SystemTime::now().into())
                .map(|results| {
                    results
                        .into_iter()
                        .map(map_discovery_recovery_result)
                        .collect::<Vec<_>>()
                })
        })
    }
}

/// Polls a bounded batch of durable discovery events.
///
/// # Safety
///
/// `core` must be live and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_poll_provider_discovery_events_json(
    core: *const LorepiaCoreHandle,
    max_events: u32,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            if max_events == 0 || max_events > MAX_DISCOVERY_EVENT_BATCH_SIZE {
                return Err(CoreError::invalid("max_events must be between 1 and 1000"));
            }
            handle
                .core
                .poll_provider_discovery_events(max_events, std::time::SystemTime::now().into())
                .map(|events| {
                    events
                        .into_iter()
                        .map(map_discovery_outbox_event)
                        .collect::<Vec<_>>()
                })
        })
    }
}

/// Acknowledges one previously polled discovery event.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_ack_provider_discovery_event_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: AckProviderDiscoveryEventPayload =
                parse_versioned_request(json, "request_json")?;
            handle.core.ack_provider_discovery_event(
                &parse_discovery_event_id(payload.event_id)?,
                std::time::SystemTime::now().into(),
            )
        })
    }
}

/// Lists the immutable compensation recipe for one commit attempt.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_list_provider_discovery_compensation_steps_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: ListProviderDiscoveryCompensationPayload =
                parse_versioned_request(json, "request_json")?;
            handle
                .core
                .list_provider_discovery_compensation_steps(&parse_discovery_commit_attempt_id(
                    payload.commit_attempt_id,
                )?)
                .map(|steps| {
                    steps
                        .into_iter()
                        .map(map_discovery_compensation_step)
                        .collect::<Vec<_>>()
                })
        })
    }
}

/// Starts exactly one native-owned credential-slot compensation step.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_start_provider_discovery_credential_compensation_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: ProviderDiscoveryCompensationStepPayload =
                parse_versioned_request(json, "request_json")?;
            handle
                .core
                .start_provider_discovery_credential_compensation(
                    &DiscoverySessionId::from(payload.session_id),
                    &payload.step_id,
                )
                .map(map_discovery_compensation_step)
        })
    }
}

/// Confirms successful native credential-slot deletion and lets Core continue
/// its database-owned compensation steps.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_complete_provider_discovery_credential_compensation_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: ProviderDiscoveryCompensationStepPayload =
                parse_versioned_request(json, "request_json")?;
            let snapshot = handle
                .core
                .complete_provider_discovery_credential_compensation(
                    &DiscoverySessionId::from(payload.session_id),
                    &payload.step_id,
                )?;
            map_provider_discovery_snapshot(&handle.core, snapshot)
        })
    }
}

/// Records a stable redacted failure for one in-progress native credential
/// compensation step.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_fail_provider_discovery_credential_compensation_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: FailProviderDiscoveryCompensationStepPayload =
                parse_versioned_request(json, "request_json")?;
            let snapshot = handle
                .core
                .fail_provider_discovery_credential_compensation(
                    &DiscoverySessionId::from(payload.session_id),
                    &payload.step_id,
                    DiscoveryFailure {
                        code: payload.failure_code,
                        message_key: payload.failure_message_key,
                        recoverable: payload.recoverable,
                    },
                )?;
            map_provider_discovery_snapshot(&handle.core, snapshot)
        })
    }
}

/// Marks a native credential deletion outcome unknown without retrying it.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_mark_provider_discovery_credential_compensation_unknown_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: ProviderDiscoveryCompensationStepPayload =
                parse_versioned_request(json, "request_json")?;
            let snapshot = handle
                .core
                .mark_provider_discovery_credential_compensation_unknown(
                    &DiscoverySessionId::from(payload.session_id),
                    &payload.step_id,
                )?;
            map_provider_discovery_snapshot(&handle.core, snapshot)
        })
    }
}

/// Runs one bounded setup-assistant model turn through Core and returns only a
/// closed typed host action.
///
/// # Safety
///
/// `core` must be live. Every present pointer must reference its declared
/// number of readable UTF-8 bytes and `out_buffer` must be writable.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn lorepia_core_run_provider_discovery_assistant_turn_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    credential: *const u8,
    credential_len: usize,
    credential_present: u8,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: RunProviderDiscoveryAssistantTurnPayload =
                parse_versioned_request(json, "request_json")?;
            let credential =
                read_optional_utf8(credential, credential_len, credential_present, "credential")?;
            handle
                .core
                .run_provider_discovery_assistant_turn(
                    &DiscoverySessionId::from(payload.session_id),
                    payload.estimate,
                    credential,
                )
                .and_then(map_discovery_assistant_host_action)
        })
    }
}

/// Resumes one durably pending allowlisted setup-assistant tool action inside
/// Core. No raw tool call or tool-result payload crosses the C ABI.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_resume_provider_discovery_assistant_core_host_action_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: ProviderDiscoverySessionPayload =
                parse_versioned_request(json, "request_json")?;
            let snapshot = handle
                .core
                .resume_provider_discovery_assistant_core_host_action(&DiscoverySessionId::from(
                    payload.session_id,
                ))?;
            map_provider_discovery_snapshot(&handle.core, snapshot)
        })
    }
}

/// Approves one explicitly waiting setup-assistant retry.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_approve_provider_discovery_assistant_retry_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: ProviderDiscoverySessionPayload =
                parse_versioned_request(json, "request_json")?;
            let snapshot = handle.core.approve_provider_discovery_assistant_retry(
                &DiscoverySessionId::from(payload.session_id),
            )?;
            map_provider_discovery_snapshot(&handle.core, snapshot)
        })
    }
}

/// Requests revision of the current setup-assistant draft.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_request_provider_discovery_assistant_revision_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: ProviderDiscoverySessionPayload =
                parse_versioned_request(json, "request_json")?;
            let snapshot = handle.core.request_provider_discovery_assistant_revision(
                &DiscoverySessionId::from(payload.session_id),
            )?;
            map_provider_discovery_snapshot(&handle.core, snapshot)
        })
    }
}

/// Accepts the current setup-assistant draft for deterministic validation.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_accept_provider_discovery_assistant_draft_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: ProviderDiscoverySessionPayload =
                parse_versioned_request(json, "request_json")?;
            let snapshot = handle.core.accept_provider_discovery_assistant_draft(
                &DiscoverySessionId::from(payload.session_id),
            )?;
            map_provider_discovery_snapshot(&handle.core, snapshot)
        })
    }
}

/// Records one stable setup-assistant failure kind without provider text.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_record_provider_discovery_assistant_failure_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: RecordProviderDiscoveryAssistantFailurePayload =
                parse_versioned_request(json, "request_json")?;
            let snapshot = handle.core.record_provider_discovery_assistant_failure(
                &DiscoverySessionId::from(payload.session_id),
                payload.kind,
                payload.retryable,
            )?;
            map_provider_discovery_snapshot(&handle.core, snapshot)
        })
    }
}

/// Returns the active signed provider catalog status.
///
/// # Safety
///
/// `core` must be live and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_provider_catalog_status_json(
    core: *const LorepiaCoreHandle,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            handle
                .core
                .provider_catalog_status()
                .map(map_provider_catalog_status)
        })
    }
}

/// Returns a bounded page of provider catalog history.
///
/// # Safety
///
/// `core` must be live. `request_json` must reference readable UTF-8 and
/// `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_provider_catalog_history_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: ProviderCatalogHistoryPayload =
                parse_versioned_request(json, "request_json")?;
            handle
                .core
                .provider_catalog_history(
                    payload.limit,
                    payload.before_revision,
                    payload.before_state_version,
                )
                .map(map_provider_catalog_history)
        })
    }
}

/// Prepares a short-lived, state-bound review of one exact signed catalog
/// envelope without activating it.
///
/// # Safety
///
/// `core` must be live. `envelope_json` must reference readable UTF-8 bytes and
/// `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_prepare_signed_provider_catalog_import_json(
    core: *const LorepiaCoreHandle,
    envelope_json: *const u8,
    envelope_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let envelope = read_utf8(envelope_json, envelope_json_len, "envelope_json")?;
            handle
                .core
                .prepare_signed_provider_catalog_import(envelope.as_bytes())
                .and_then(map_provider_catalog_import_plan)
        })
    }
}

/// Activates an unchanged, unexpired signed-catalog import plan against the
/// exact envelope bytes retained by native UI.
///
/// # Safety
///
/// `core` must be live. `request_json` and `envelope_json` must reference
/// readable UTF-8 bytes and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_activate_signed_provider_catalog_import_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    envelope_json: *const u8,
    envelope_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let request = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: ActivateSignedProviderCatalogImportPayload =
                parse_versioned_request(request, "request_json")?;
            let plan: ProviderCatalogImportPlan =
                parse_json(&payload.plan_json, "request_json.payload.plan_json")?;
            let envelope = read_utf8(envelope_json, envelope_json_len, "envelope_json")?;
            handle
                .core
                .activate_signed_provider_catalog_import(&plan, envelope.as_bytes())
                .map(map_provider_catalog_import_result)
        })
    }
}

/// Diffs two immutable local provider catalog revisions.
///
/// # Safety
///
/// `core` must be live. `request_json` must reference readable UTF-8 and
/// `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_diff_provider_catalog_revisions_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: ProviderCatalogDiffPayload =
                parse_versioned_request(json, "request_json")?;
            handle
                .core
                .diff_provider_catalog_revisions(payload.from_revision, payload.to_revision)
                .map(map_provider_catalog_diff)
        })
    }
}

/// Creates a short-lived state-bound provider catalog rollback plan.
///
/// # Safety
///
/// `core` must be live. `request_json` must reference readable UTF-8 and
/// `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_prepare_provider_catalog_rollback_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: PrepareProviderCatalogRollbackPayload =
                parse_versioned_request(json, "request_json")?;
            handle
                .core
                .prepare_provider_catalog_rollback(payload.target_revision)
                .and_then(map_provider_catalog_rollback_plan)
        })
    }
}

/// Activates an unchanged, unexpired provider catalog rollback plan.
///
/// # Safety
///
/// `core` must be live. `request_json` must reference readable UTF-8 and
/// `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_activate_provider_catalog_rollback_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: ActivateProviderCatalogRollbackPayload =
                parse_versioned_request(json, "request_json")?;
            let plan: ProviderCatalogRollbackPlan =
                parse_json(&payload.plan_json, "request_json.payload.plan_json")?;
            handle
                .core
                .activate_provider_catalog_rollback(&plan)
                .map(map_provider_catalog_rollback_result)
        })
    }
}

/// Serializes all generation presets for one model route as UTF-8 JSON DTOs.
///
/// # Safety
///
/// `core` must be live, `model_route_id` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_list_generation_presets_json(
    core: *const LorepiaCoreHandle,
    model_route_id: *const u8,
    model_route_id_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let model_route_id = read_utf8(model_route_id, model_route_id_len, "model_route_id")?;
            handle
                .core
                .list_generation_presets(&ModelRouteId::from(model_route_id))
                .map(|presets| {
                    presets
                        .into_iter()
                        .map(map_generation_preset)
                        .collect::<Vec<_>>()
                })
        })
    }
}

/// Creates or replaces one generation preset using a schema-version-one JSON
/// envelope.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_upsert_generation_preset_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let preset: GenerationPreset = parse_versioned_request(json, "request_json")?;
            handle
                .core
                .upsert_generation_preset(preset)
                .map(map_generation_preset)
        })
    }
}

/// Validates a stored route/preset against the exact family request planner
/// without performing network work.
///
/// # Safety
///
/// `core` must be live and `request_json` must reference readable UTF-8 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_validate_generation_preset_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        run_core_call(core, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: GenerationPresetTargetPayload =
                parse_versioned_request(json, "request_json")?;
            handle.core.validate_generation_preset(
                &ModelRouteId::from(payload.model_route_id),
                &lorepia_engine::GenerationPresetId::from(payload.generation_preset_id),
            )
        })
    }
}

/// Validates an unsaved generation-preset candidate without mutating storage.
///
/// # Safety
///
/// `core` must be live and `request_json` must contain a readable
/// schema-version-one `GenerationPreset` envelope.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_validate_generation_preset_candidate_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        run_core_call(core, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let preset: GenerationPreset = parse_versioned_request(json, "request_json")?;
            handle.core.validate_generation_preset_candidate(&preset)
        })
    }
}

/// Returns Rust-derived, model-specific reasoning controls for an unsaved or
/// stored generation-preset candidate.
///
/// # Safety
///
/// `core` must be live, `request_json` must contain a readable
/// schema-version-one `GenerationPreset` envelope, and `out_buffer` must be
/// writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_render_reasoning_control_candidate_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let preset: GenerationPreset = parse_versioned_request(json, "request_json")?;
            handle.core.render_reasoning_control_for_preset(&preset)
        })
    }
}

/// Returns Rust-derived, model-specific prompt-cache controls for an unsaved
/// or stored generation-preset candidate.
///
/// # Safety
///
/// `core` must be live, `request_json` must contain a readable
/// schema-version-one `GenerationPreset` envelope, and `out_buffer` must be
/// writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_render_prompt_cache_control_candidate_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let preset: GenerationPreset = parse_versioned_request(json, "request_json")?;
            handle.core.render_prompt_cache_control_for_preset(&preset)
        })
    }
}

/// Returns a scalar-free, credential-free preview produced by the exact
/// adapter route and request plan used for generation.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_preview_provider_request_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: GenerationPresetTargetPayload =
                parse_versioned_request(json, "request_json")?;
            handle
                .core
                .preview_provider_request(
                    &ModelRouteId::from(payload.model_route_id),
                    &lorepia_engine::GenerationPresetId::from(payload.generation_preset_id),
                )
                .map(map_discovery_request_preview)
        })
    }
}

/// Returns the scalar-free provider request preview for an unsaved,
/// fully-validated generation-preset candidate.
///
/// # Safety
///
/// `core` must be live, `request_json` must contain a readable
/// schema-version-one `GenerationPreset` envelope, and `out_buffer` must be
/// writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_preview_provider_request_candidate_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let preset: GenerationPreset = parse_versioned_request(json, "request_json")?;
            handle
                .core
                .preview_provider_request_candidate(&preset)
                .map(map_discovery_request_preview)
        })
    }
}

/// Deletes one generation preset using a schema-version-one JSON envelope.
///
/// # Safety
///
/// `core` must be live and `request_json` must reference readable UTF-8 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_delete_generation_preset_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        run_core_call(core, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: DeleteGenerationPresetPayload =
                parse_versioned_request(json, "request_json")?;
            handle
                .core
                .delete_generation_preset(&lorepia_engine::GenerationPresetId::from(
                    payload.generation_preset_id,
                ))
        })
    }
}

/// Selects or clears the atomic model-route and generation-preset target using
/// a schema-version-one JSON envelope, returning the updated settings as JSON.
///
/// # Safety
///
/// `core` must be live, `request_json` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_select_generation_target_json(
    core: *const LorepiaCoreHandle,
    request_json: *const u8,
    request_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(request_json, request_json_len, "request_json")?;
            let payload: SelectGenerationTargetPayload =
                parse_versioned_request(json, "request_json")?;
            handle.core.select_generation_target(payload.target)
        })
    }
}

/// Serializes all provider profiles as UTF-8 JSON.
///
/// # Safety
///
/// `core` must be live and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_list_provider_profiles_json(
    core: *const LorepiaCoreHandle,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            handle.core.list_provider_profiles()
        })
    }
}

/// Creates or replaces a provider profile from UTF-8 JSON and returns the
/// normalized profile as UTF-8 JSON.
///
/// # Safety
///
/// `core` must be live, `profile_json` must reference readable UTF-8 bytes, and
/// `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_upsert_provider_profile_json(
    core: *const LorepiaCoreHandle,
    profile_json: *const u8,
    profile_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(profile_json, profile_json_len, "profile_json")?;
            let profile: ProviderProfile = parse_json(json, "profile_json")?;
            handle.core.upsert_provider_profile(profile)
        })
    }
}

/// Deletes a provider profile.
///
/// # Safety
///
/// `core` must be live and `profile_id` must reference readable UTF-8 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_delete_provider_profile(
    core: *const LorepiaCoreHandle,
    profile_id: *const u8,
    profile_id_len: usize,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        run_core_call(core, |handle| {
            let id = read_utf8(profile_id, profile_id_len, "profile_id")?;
            handle.core.delete_provider_profile(id)
        })
    }
}

/// Releases a buffer returned by this library. An empty buffer is ignored.
///
/// # Safety
///
/// `buffer` must be empty or an unmodified buffer returned by this library and
/// not previously freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_buffer_free(buffer: LorepiaBuffer) {
    if !buffer.ptr.is_null() && buffer.len != 0 {
        for index in 0..buffer.len {
            // SAFETY: the caller guarantees this is the original live buffer.
            // Volatile clearing ensures transient credential buffers are
            // overwritten before their allocation is released.
            unsafe { buffer.ptr.add(index).write_volatile(0) };
        }
        let raw = ptr::slice_from_raw_parts_mut(buffer.ptr, buffer.len);
        // SAFETY: guaranteed by the caller contract and allocated by
        // `write_buffer` as `Box<[u8]>`.
        drop(unsafe { Box::from_raw(raw) });
    }
}

unsafe fn core_json<T: Serialize>(
    core: *const LorepiaCoreHandle,
    out_buffer: *mut LorepiaBuffer,
    operation: impl FnOnce(&LorepiaCoreHandle) -> CoreResult<T>,
) -> i32 {
    // SAFETY: callers forward their documented pointer contracts.
    unsafe {
        run_core_call(core, |handle| {
            prepare_output(out_buffer)?;
            let value = operation(handle)?;
            let bytes = serde_json::to_vec(&value)
                .map_err(|_| CoreError::internal("cannot serialize C ABI response JSON"))?;
            write_buffer(out_buffer, bytes)
        })
    }
}

unsafe fn run_core_call(
    core: *const LorepiaCoreHandle,
    operation: impl FnOnce(&LorepiaCoreHandle) -> CoreResult<()>,
) -> i32 {
    if core.is_null() {
        return fail_without_handle(CoreError::invalid("core handle must not be null"));
    }
    // SAFETY: a non-null handle is live by caller contract.
    let handle = unsafe { &*core };
    replace_last_error(handle, None);
    match catch_unwind(AssertUnwindSafe(|| operation(handle))) {
        Ok(Ok(())) => STATUS_OK,
        Ok(Err(error)) => fail_with_handle(handle, error),
        Err(_) => fail_with_handle(
            handle,
            CoreError::internal("panic was contained at the C ABI boundary"),
        ),
    }
}

unsafe fn prepare_output(out_buffer: *mut LorepiaBuffer) -> CoreResult<()> {
    if out_buffer.is_null() {
        return Err(CoreError::invalid("out_buffer must not be null"));
    }
    // SAFETY: `out_buffer` is writable by caller contract.
    unsafe { out_buffer.write(LorepiaBuffer::default()) };
    Ok(())
}

unsafe fn write_buffer(out_buffer: *mut LorepiaBuffer, bytes: Vec<u8>) -> CoreResult<()> {
    if out_buffer.is_null() {
        return Err(CoreError::invalid("out_buffer must not be null"));
    }
    if bytes.is_empty() {
        // SAFETY: `out_buffer` is writable by caller contract.
        unsafe { out_buffer.write(LorepiaBuffer::default()) };
        return Ok(());
    }
    let mut boxed = bytes.into_boxed_slice();
    let buffer = LorepiaBuffer {
        ptr: boxed.as_mut_ptr(),
        len: boxed.len(),
    };
    std::mem::forget(boxed);
    // SAFETY: `out_buffer` is writable by caller contract.
    unsafe { out_buffer.write(buffer) };
    Ok(())
}

unsafe fn read_utf8<'a>(value: *const u8, value_len: usize, field: &str) -> CoreResult<&'a str> {
    if value.is_null() {
        return Err(CoreError::invalid(format!("{field} must not be null")));
    }
    // SAFETY: the caller guarantees that the input range is readable.
    let bytes = unsafe { slice::from_raw_parts(value, value_len) };
    str::from_utf8(bytes).map_err(|_| CoreError::invalid(format!("{field} must be valid UTF-8")))
}

unsafe fn read_optional_utf8<'a>(
    value: *const u8,
    value_len: usize,
    present: u8,
    field: &str,
) -> CoreResult<Option<&'a str>> {
    match present {
        0 if value.is_null() && value_len == 0 => Ok(None),
        0 => Err(CoreError::invalid(format!(
            "{field} must be null with zero length when absent"
        ))),
        1 => {
            // SAFETY: the present optional value follows the same contract as
            // a required UTF-8 input.
            unsafe { read_utf8(value, value_len, field) }.map(Some)
        }
        _ => Err(CoreError::invalid(format!(
            "{field}_present must be zero or one"
        ))),
    }
}

fn parse_versioned_request<T: for<'de> Deserialize<'de>>(json: &str, field: &str) -> CoreResult<T> {
    let request: VersionedRequest<serde_json::Value> = parse_json(json, field)?;
    if request.request_schema_version != REQUEST_SCHEMA_VERSION {
        return Err(CoreError::invalid(format!(
            "{field}.request_schema_version must be {REQUEST_SCHEMA_VERSION}"
        )));
    }
    serde_json::from_value(request.payload)
        .map_err(|_| CoreError::invalid(format!("{field} must be valid JSON")))
}

fn parse_json<T: for<'de> Deserialize<'de>>(json: &str, field: &str) -> CoreResult<T> {
    serde_json::from_str(json)
        .map_err(|_| CoreError::invalid(format!("{field} must be valid JSON")))
}

fn validate_provider_discovery_list_limit(limit: u32) -> CoreResult<()> {
    if limit == 0 || limit > MAX_DISCOVERY_LIST_SIZE {
        return Err(CoreError::invalid(
            "provider discovery limit must be between 1 and 256",
        ));
    }
    Ok(())
}

fn parse_discovery_action_id(value: String) -> CoreResult<DiscoveryActionId> {
    DiscoveryActionId::parse(value)
        .map_err(|_| CoreError::invalid("discovery action identifier is invalid"))
}

fn parse_discovery_approval_id(value: String) -> CoreResult<DiscoveryApprovalId> {
    DiscoveryApprovalId::parse(value)
        .map_err(|_| CoreError::invalid("discovery approval identifier is invalid"))
}

fn parse_discovery_commit_attempt_id(value: String) -> CoreResult<DiscoveryCommitAttemptId> {
    DiscoveryCommitAttemptId::parse(value)
        .map_err(|_| CoreError::invalid("discovery commit attempt identifier is invalid"))
}

fn parse_discovery_event_id(value: String) -> CoreResult<DiscoveryEventId> {
    DiscoveryEventId::parse(value)
        .map_err(|_| CoreError::invalid("discovery event identifier is invalid"))
}

fn parse_discovery_http_url(value: String, field: &str) -> CoreResult<HttpUrl> {
    HttpUrl::parse(&value)
        .map_err(|_| CoreError::invalid(format!("{field} is not an allowed HTTP URL")))
}

fn default_discovery_site_url(core: &Core, template_id: &str) -> CoreResult<HttpUrl> {
    let view = core
        .list_provider_template_views()?
        .into_iter()
        .find(|view| view.template.id.as_str() == template_id)
        .ok_or_else(|| {
            CoreError::new(
                CoreErrorCode::NotFound,
                "provider template was not found",
                false,
            )
        })?;
    let origin = view
        .template
        .default_manifest
        .default_api_origin
        .ok_or_else(|| CoreError::invalid("known provider template has no default API origin"))?;
    parse_discovery_http_url(
        format!("{}/", origin.as_str().trim_end_matches('/')),
        "site_url",
    )
}

fn discovery_credential_ref(
    connection_id: &str,
    credential_slot_ready: bool,
) -> Option<CredentialRef> {
    credential_slot_ready.then(|| CredentialRef(connection_id.to_owned()))
}

fn unmap_provider_connection(
    payload: UpsertProviderConnectionPayload,
) -> CoreResult<ProviderConnection> {
    let api_origin = CanonicalOrigin::parse(&payload.api_origin)
        .map_err(|error| CoreError::invalid(format!("invalid provider API origin: {error}")))?;
    let api_base_path = payload
        .api_base_path
        .as_deref()
        .map(EndpointPath::parse)
        .transpose()
        .map_err(|error| CoreError::invalid(format!("invalid provider API base path: {error}")))?;
    let connection_id = ProviderConnectionId::from(payload.id);
    let credential_ref =
        discovery_credential_ref(connection_id.as_str(), payload.credential_slot_ready);
    if !payload.credential_slot_ready && !payload.approved_credential_origins.is_empty() {
        return Err(CoreError::invalid(
            "approved credential origins require a ready credential slot",
        ));
    }
    let approved_credential_origins = payload
        .approved_credential_origins
        .into_iter()
        .map(|origin| {
            CanonicalOrigin::parse(&origin).map_err(|error| {
                CoreError::invalid(format!("invalid approved credential origin: {error}"))
            })
        })
        .collect::<CoreResult<Vec<_>>>()?;
    let credential_scope = payload.credential_slot_ready.then_some(CredentialScope {
        allowed_origins: approved_credential_origins,
        auth_binding: payload.auth_binding,
        redirect_policy: payload.credential_redirect_policy,
    });
    let created_at = payload
        .created_at
        .parse()
        .map_err(|error| CoreError::invalid(format!("invalid connection created_at: {error}")))?;
    let updated_at = payload
        .updated_at
        .parse()
        .map_err(|error| CoreError::invalid(format!("invalid connection updated_at: {error}")))?;
    Ok(ProviderConnection {
        id: connection_id,
        template_id: ProviderTemplateId::from(payload.template_id),
        template_version: payload.template_version,
        display_name: payload.display_name,
        api_origin,
        config: ConnectionConfig {
            api_base_path,
            network_mode: payload.network_mode,
            local_network_approval: payload.local_network_approval,
            values: payload.values,
        },
        credential_ref,
        credential_scope,
        timeout_seconds: payload.timeout_seconds,
        status: payload.status,
        created_at,
        updated_at,
    })
}

fn unmap_provider_discovery_input(
    core: &Core,
    input: ProviderDiscoveryInputPayload,
    known_template_id: Option<&str>,
) -> CoreResult<SanitizedDiscoveryInput> {
    let ProviderDiscoveryInputPayload {
        connection_id,
        display_name,
        site_url,
        docs_url,
        credential_slot_ready,
        preferred_assistant_model_route_id,
        connection_options,
        supplied_evidence_ids,
    } = input;
    let site_url = match site_url {
        Some(site_url) => parse_discovery_http_url(site_url, "site_url")?,
        None => match known_template_id {
            Some(template_id) => default_discovery_site_url(core, template_id)?,
            None => return Err(CoreError::invalid("site discovery requires site_url")),
        },
    };
    let docs_url = docs_url
        .map(|url| parse_discovery_http_url(url, "docs_url"))
        .transpose()?;
    let credential_ref = discovery_credential_ref(&connection_id, credential_slot_ready);
    Ok(SanitizedDiscoveryInput {
        connection_id: ProviderConnectionId::from(connection_id),
        display_name,
        site_url,
        docs_url,
        credential_ref,
        preferred_assistant: preferred_assistant_model_route_id.map(ModelRouteId::from),
        connection_options,
        supplied_evidence_ids: supplied_evidence_ids
            .into_iter()
            .map(EvidenceId::from)
            .collect(),
    })
}

fn unmap_provider_discovery_curl_input(
    input: ProviderDiscoveryInputPayload,
) -> CoreResult<ProviderDiscoveryCurlInput> {
    let ProviderDiscoveryInputPayload {
        connection_id,
        display_name,
        site_url,
        docs_url,
        credential_slot_ready,
        preferred_assistant_model_route_id,
        connection_options,
        supplied_evidence_ids,
    } = input;
    if site_url.is_some() {
        return Err(CoreError::invalid(
            "cURL discovery derives site_url and must not receive a separate site_url",
        ));
    }
    let docs_url = docs_url
        .map(|url| parse_discovery_http_url(url, "docs_url"))
        .transpose()?;
    let credential_ref = discovery_credential_ref(&connection_id, credential_slot_ready);
    Ok(ProviderDiscoveryCurlInput {
        connection_id: ProviderConnectionId::from(connection_id),
        display_name,
        docs_url,
        credential_ref,
        preferred_assistant: preferred_assistant_model_route_id.map(ModelRouteId::from),
        connection_options,
        supplied_evidence_ids: supplied_evidence_ids
            .into_iter()
            .map(EvidenceId::from)
            .collect(),
    })
}

fn unmap_discovery_unknown_outcome_resolution(
    resolution: DiscoveryUnknownOutcomeResolutionPayload,
) -> DiscoveryUnknownOutcomeResolution {
    match resolution {
        DiscoveryUnknownOutcomeResolutionPayload::ConfirmedNoEffect => {
            DiscoveryUnknownOutcomeResolution::ConfirmedNoEffect
        }
        DiscoveryUnknownOutcomeResolutionPayload::ConfirmedCommitCompleted { connection_id } => {
            DiscoveryUnknownOutcomeResolution::ConfirmedCommitCompleted {
                connection_id: ProviderConnectionId::from(connection_id),
            }
        }
        DiscoveryUnknownOutcomeResolutionPayload::ConfirmedCompensated => {
            DiscoveryUnknownOutcomeResolution::ConfirmedCompensated
        }
        DiscoveryUnknownOutcomeResolutionPayload::ManuallyReconciledAsFailed => {
            DiscoveryUnknownOutcomeResolution::ManuallyReconciledAsFailed
        }
    }
}

fn unmap_provider_discovery_action(
    action: ProviderDiscoveryPublicActionPayload,
) -> CoreResult<ProviderDiscoveryAction> {
    Ok(match action {
        ProviderDiscoveryPublicActionPayload::SelectTemplate { candidate_id } => {
            ProviderDiscoveryAction::SelectTemplate {
                candidate_id: lorepia_engine::DiscoveryCandidateId::parse(candidate_id)
                    .map_err(|_| CoreError::invalid("discovery candidate identifier is invalid"))?,
            }
        }
        ProviderDiscoveryPublicActionPayload::ContinueWithoutTemplate => {
            ProviderDiscoveryAction::ContinueWithoutTemplate
        }
        ProviderDiscoveryPublicActionPayload::SupplyMoreEvidence { evidence_ids } => {
            ProviderDiscoveryAction::SupplyMoreEvidence {
                evidence_ids: evidence_ids.into_iter().map(EvidenceId::from).collect(),
            }
        }
        ProviderDiscoveryPublicActionPayload::RequestAssistant => {
            ProviderDiscoveryAction::RequestAssistant
        }
        ProviderDiscoveryPublicActionPayload::ApproveAssistant {
            approval_id,
            approval_grant_sha256,
        } => ProviderDiscoveryAction::ApproveAssistant {
            approval_id: parse_discovery_approval_id(approval_id)?,
            approval_grant_sha256,
        },
        ProviderDiscoveryPublicActionPayload::DeclineAssistant => {
            ProviderDiscoveryAction::DeclineAssistant
        }
        ProviderDiscoveryPublicActionPayload::ApproveCredentialOrigin { approval_id } => {
            ProviderDiscoveryAction::ApproveCredentialOrigin {
                approval_id: parse_discovery_approval_id(approval_id)?,
            }
        }
        ProviderDiscoveryPublicActionPayload::ApproveProbes {
            approval_id,
            approval_grant_sha256,
        } => ProviderDiscoveryAction::ApproveProbes {
            approval_id: parse_discovery_approval_id(approval_id)?,
            approval_grant_sha256,
        },
        ProviderDiscoveryPublicActionPayload::SkipProbes => ProviderDiscoveryAction::SkipProbes,
        ProviderDiscoveryPublicActionPayload::ApproveReview {
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
        ProviderDiscoveryPublicActionPayload::ResumeCompensation => {
            ProviderDiscoveryAction::ResumeCompensation
        }
        ProviderDiscoveryPublicActionPayload::RestartInterrupted => {
            ProviderDiscoveryAction::RestartInterrupted
        }
        ProviderDiscoveryPublicActionPayload::ResolveUnknownOutcome {
            approval_id,
            resolution,
        } => ProviderDiscoveryAction::ResolveUnknownOutcome {
            approval_id: parse_discovery_approval_id(approval_id)?,
            resolution: unmap_discovery_unknown_outcome_resolution(resolution),
        },
        ProviderDiscoveryPublicActionPayload::Cancel => ProviderDiscoveryAction::Cancel,
    })
}

fn map_curl_auth_binding_hint(hints: &[CurlAuthHint]) -> Option<AuthBinding> {
    let mut selected = None;
    for hint in hints {
        let candidate = match hint {
            CurlAuthHint::BearerHeader | CurlAuthHint::AuthorizationHeader => {
                AuthBinding::BearerHeader
            }
            CurlAuthHint::ApiKeyHeader { header_name } => AuthBinding::HeaderApiKey {
                header_name: header_name.clone(),
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

fn map_provider_curl_inspection(
    inspection: &lorepia_engine::ProviderCurlInspection,
) -> ProviderCurlInspectionDto {
    let evidence = inspection.evidence();
    ProviderCurlInspectionDto {
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
        auth_binding_hint: map_curl_auth_binding_hint(inspection.auth_hints()),
        api_family_hint: evidence
            .api_family_candidates
            .first()
            .copied()
            .map(|family| api_family_name(family).to_owned()),
        model_hint: evidence.model_hint.clone(),
        stream_hint: evidence.stream_hint,
        redacted_curl: inspection.redacted_curl().to_owned(),
        credential_present: inspection.extracted_credential().is_some(),
    }
}

const fn map_discovery_state(state: DiscoveryState) -> DiscoveryStateDto {
    match state {
        DiscoveryState::Draft => DiscoveryStateDto::Draft,
        DiscoveryState::ResolvingKnownProvider => DiscoveryStateDto::ResolvingKnownProvider,
        DiscoveryState::AwaitingTemplateSelection => DiscoveryStateDto::AwaitingTemplateSelection,
        DiscoveryState::FetchingDocuments => DiscoveryStateDto::FetchingDocuments,
        DiscoveryState::ExtractingEvidence => DiscoveryStateDto::ExtractingEvidence,
        DiscoveryState::AwaitingMoreEvidence => DiscoveryStateDto::AwaitingMoreEvidence,
        DiscoveryState::AwaitingAssistantConsent => DiscoveryStateDto::AwaitingAssistantConsent,
        DiscoveryState::BuildingDeterministicManifestDraft => {
            DiscoveryStateDto::BuildingDeterministicManifestDraft
        }
        DiscoveryState::BuildingAssistantManifestDraft => {
            DiscoveryStateDto::BuildingAssistantManifestDraft
        }
        DiscoveryState::ValidatingManifest => DiscoveryStateDto::ValidatingManifest,
        DiscoveryState::AwaitingCredentialOriginApproval => {
            DiscoveryStateDto::AwaitingCredentialOriginApproval
        }
        DiscoveryState::ListingModels => DiscoveryStateDto::ListingModels,
        DiscoveryState::AwaitingProbeConsent => DiscoveryStateDto::AwaitingProbeConsent,
        DiscoveryState::ProbingCapabilities => DiscoveryStateDto::ProbingCapabilities,
        DiscoveryState::AwaitingReview => DiscoveryStateDto::AwaitingReview,
        DiscoveryState::Committing => DiscoveryStateDto::Committing,
        DiscoveryState::Compensating => DiscoveryStateDto::Compensating,
        DiscoveryState::Ready => DiscoveryStateDto::Ready,
        DiscoveryState::Failed => DiscoveryStateDto::Failed,
        DiscoveryState::Cancelled => DiscoveryStateDto::Cancelled,
        DiscoveryState::Interrupted => DiscoveryStateDto::Interrupted,
        DiscoveryState::UnknownOutcome => DiscoveryStateDto::UnknownOutcome,
    }
}

const fn map_discovery_operation(operation: DiscoveryOperationKind) -> DiscoveryOperationKindDto {
    match operation {
        DiscoveryOperationKind::ResolveKnownProvider => {
            DiscoveryOperationKindDto::ResolveKnownProvider
        }
        DiscoveryOperationKind::FetchDocuments => DiscoveryOperationKindDto::FetchDocuments,
        DiscoveryOperationKind::ExtractEvidence => DiscoveryOperationKindDto::ExtractEvidence,
        DiscoveryOperationKind::BuildDeterministicManifestDraft => {
            DiscoveryOperationKindDto::BuildDeterministicManifestDraft
        }
        DiscoveryOperationKind::BuildAssistantManifestDraft => {
            DiscoveryOperationKindDto::BuildAssistantManifestDraft
        }
        DiscoveryOperationKind::ValidateManifest => DiscoveryOperationKindDto::ValidateManifest,
        DiscoveryOperationKind::ListModels => DiscoveryOperationKindDto::ListModels,
        DiscoveryOperationKind::ProbeCapabilities => DiscoveryOperationKindDto::ProbeCapabilities,
        DiscoveryOperationKind::AtomicCommit => DiscoveryOperationKindDto::AtomicCommit,
        DiscoveryOperationKind::Compensation => DiscoveryOperationKindDto::Compensation,
    }
}

fn map_discovery_failure(failure: DiscoveryFailure) -> DiscoveryFailureDto {
    DiscoveryFailureDto {
        code: failure.code,
        message_key: failure.message_key,
        recoverable: failure.recoverable,
    }
}

fn map_discovery_action_required(action: DiscoveryActionRequired) -> DiscoveryActionRequiredDto {
    match action {
        DiscoveryActionRequired::SelectTemplate => DiscoveryActionRequiredDto::SelectTemplate,
        DiscoveryActionRequired::SupplyMoreEvidence => {
            DiscoveryActionRequiredDto::SupplyMoreEvidence
        }
        DiscoveryActionRequired::ApproveAssistant => DiscoveryActionRequiredDto::ApproveAssistant,
        DiscoveryActionRequired::ApproveCredentialOrigin => {
            DiscoveryActionRequiredDto::ApproveCredentialOrigin
        }
        DiscoveryActionRequired::ApproveProbes => DiscoveryActionRequiredDto::ApproveProbes,
        DiscoveryActionRequired::Review => DiscoveryActionRequiredDto::Review,
        DiscoveryActionRequired::RestartInterrupted { operation } => {
            DiscoveryActionRequiredDto::RestartInterrupted {
                operation: map_discovery_operation(operation),
            }
        }
        DiscoveryActionRequired::ReconcileUnknownOutcome { operation } => {
            DiscoveryActionRequiredDto::ReconcileUnknownOutcome {
                operation: map_discovery_operation(operation),
            }
        }
    }
}

fn discovery_action_required_for_snapshot(
    snapshot: &DiscoverySessionSnapshot,
) -> Option<DiscoveryActionRequiredDto> {
    match snapshot.session.state {
        DiscoveryState::AwaitingTemplateSelection => {
            Some(DiscoveryActionRequiredDto::SelectTemplate)
        }
        DiscoveryState::AwaitingMoreEvidence => {
            Some(DiscoveryActionRequiredDto::SupplyMoreEvidence)
        }
        DiscoveryState::AwaitingAssistantConsent => {
            Some(DiscoveryActionRequiredDto::ApproveAssistant)
        }
        DiscoveryState::AwaitingCredentialOriginApproval => {
            Some(DiscoveryActionRequiredDto::ApproveCredentialOrigin)
        }
        DiscoveryState::AwaitingProbeConsent => Some(DiscoveryActionRequiredDto::ApproveProbes),
        DiscoveryState::AwaitingReview => Some(DiscoveryActionRequiredDto::Review),
        DiscoveryState::Interrupted => snapshot.session.recovery.as_ref().map(|recovery| {
            DiscoveryActionRequiredDto::RestartInterrupted {
                operation: map_discovery_operation(recovery.operation),
            }
        }),
        DiscoveryState::UnknownOutcome => snapshot.session.unknown_operation.map(|operation| {
            DiscoveryActionRequiredDto::ReconcileUnknownOutcome {
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

fn discovery_steps(state: DiscoveryState) -> Vec<DiscoveryStepDto> {
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
    .map(|(index, (id, title_key))| DiscoveryStepDto {
        id: id.to_owned(),
        title_key: title_key.to_owned(),
        state: if state == DiscoveryState::Ready || index < current {
            DiscoveryStepStateDto::Completed
        } else if index == current {
            DiscoveryStepStateDto::Current
        } else {
            DiscoveryStepStateDto::Pending
        },
    })
    .collect()
}

fn map_discovery_candidate(record: StoredDiscoveryCandidate) -> DiscoveryCandidateDto {
    let candidate = record.candidate;
    let summary = match candidate.summary {
        DiscoveryCandidateSummary::ProviderTemplate {
            template_id,
            template_version,
        } => DiscoveryCandidateSummaryDto::ProviderTemplate {
            template_id: template_id.into_inner(),
            template_version,
        },
        DiscoveryCandidateSummary::ApiOrigin { origin } => {
            DiscoveryCandidateSummaryDto::ApiOrigin {
                origin: origin.as_str().to_owned(),
            }
        }
        DiscoveryCandidateSummary::OfficialDocument { content_sha256, .. } => {
            DiscoveryCandidateSummaryDto::OfficialDocument { content_sha256 }
        }
        DiscoveryCandidateSummary::ModelRoute { model_id } => {
            DiscoveryCandidateSummaryDto::ModelRoute { model_id }
        }
        DiscoveryCandidateSummary::ManifestDraft {
            schema_version,
            manifest_sha256,
        } => DiscoveryCandidateSummaryDto::ManifestDraft {
            schema_version,
            manifest_sha256,
        },
    };
    DiscoveryCandidateDto {
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

const fn map_discovery_evidence_kind(kind: DiscoveryEvidenceKind) -> DiscoveryEvidenceKindDto {
    match kind {
        DiscoveryEvidenceKind::HtmlDocument => DiscoveryEvidenceKindDto::HtmlDocument,
        DiscoveryEvidenceKind::JsonDocument => DiscoveryEvidenceKindDto::JsonDocument,
        DiscoveryEvidenceKind::YamlDocument => DiscoveryEvidenceKindDto::YamlDocument,
        DiscoveryEvidenceKind::XmlDocument => DiscoveryEvidenceKindDto::XmlDocument,
        DiscoveryEvidenceKind::PlainTextDocument => DiscoveryEvidenceKindDto::PlainTextDocument,
        DiscoveryEvidenceKind::JsonSchema => DiscoveryEvidenceKindDto::JsonSchema,
        DiscoveryEvidenceKind::OpenApi => DiscoveryEvidenceKindDto::OpenApi,
    }
}

fn map_discovery_evidence(record: DiscoveryEvidenceRecord) -> DiscoveryEvidenceDto {
    DiscoveryEvidenceDto {
        id: record.id.into_inner(),
        kind: map_discovery_evidence_kind(record.kind),
        content_sha256: record.content_sha256,
        fetched_at: record.fetched_at.to_rfc3339(),
    }
}

fn map_discovery_unknown_outcome_resolution(
    resolution: DiscoveryUnknownOutcomeResolution,
) -> DiscoveryUnknownOutcomeResolutionDto {
    match resolution {
        DiscoveryUnknownOutcomeResolution::ConfirmedNoEffect => {
            DiscoveryUnknownOutcomeResolutionDto::ConfirmedNoEffect
        }
        DiscoveryUnknownOutcomeResolution::ConfirmedCommitCompleted { connection_id } => {
            DiscoveryUnknownOutcomeResolutionDto::ConfirmedCommitCompleted {
                connection_id: connection_id.into_inner(),
            }
        }
        DiscoveryUnknownOutcomeResolution::ConfirmedCompensated => {
            DiscoveryUnknownOutcomeResolutionDto::ConfirmedCompensated
        }
        DiscoveryUnknownOutcomeResolution::ManuallyReconciledAsFailed => {
            DiscoveryUnknownOutcomeResolutionDto::ManuallyReconciledAsFailed
        }
    }
}

fn map_discovery_approval_grant(grant: DiscoveryApprovalGrant) -> DiscoveryApprovalGrantDto {
    match grant {
        DiscoveryApprovalGrant::TemplateSelection { candidate_id } => {
            DiscoveryApprovalGrantDto::TemplateSelection {
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
        } => DiscoveryApprovalGrantDto::AssistantConsent {
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
        } => DiscoveryApprovalGrantDto::CredentialOrigin {
            origin: origin.as_str().to_owned(),
            auth_binding,
            manifest_sha256,
        },
        DiscoveryApprovalGrant::CapabilityProbe {
            model_route_ids,
            budget,
        } => DiscoveryApprovalGrantDto::CapabilityProbe {
            model_route_ids: model_route_ids
                .into_iter()
                .map(ModelRouteId::into_inner)
                .collect(),
            budget: DiscoveryProbeBudgetDto {
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
        } => DiscoveryApprovalGrantDto::Review {
            review_sha256,
            graph_sha256,
        },
        DiscoveryApprovalGrant::UnknownOutcomeResolution {
            operation,
            resolution,
        } => DiscoveryApprovalGrantDto::UnknownOutcomeResolution {
            operation: map_discovery_operation(operation),
            resolution: map_discovery_unknown_outcome_resolution(resolution),
        },
    }
}

fn map_discovery_approval(record: DiscoveryApprovalRecord) -> DiscoveryApprovalDto {
    DiscoveryApprovalDto {
        id: record.id.as_str().to_owned(),
        session_revision: record.session_revision,
        decision: match record.decision {
            DiscoveryApprovalDecision::Approved => DiscoveryApprovalDecisionDto::Approved,
            DiscoveryApprovalDecision::Rejected => DiscoveryApprovalDecisionDto::Rejected,
        },
        grant: map_discovery_approval_grant(record.grant),
        created_at: record.created_at.to_rfc3339(),
    }
}

fn map_discovery_review(review: DiscoveryReviewDiff) -> CoreResult<DiscoveryReviewDto> {
    Ok(DiscoveryReviewDto {
        sha256: review.sha256,
        graph_sha256: review.graph_sha256,
        changes: review
            .changes
            .into_iter()
            .map(|change| {
                let target_kind = match change.target_kind.as_str() {
                    "provider_template" => DiscoveryReviewTargetKindDto::ProviderTemplate,
                    "provider_connection" => DiscoveryReviewTargetKindDto::ProviderConnection,
                    "model_route" => DiscoveryReviewTargetKindDto::ModelRoute,
                    _ => {
                        return Err(CoreError::new(
                            CoreErrorCode::StorageCorrupted,
                            "provider discovery review contains an unknown target kind",
                            false,
                        ));
                    }
                };
                Ok(DiscoveryReviewChangeDto {
                    kind: match change.kind {
                        DiscoveryReviewChangeKind::Add => DiscoveryReviewChangeKindDto::Add,
                        DiscoveryReviewChangeKind::Update => DiscoveryReviewChangeKindDto::Update,
                        DiscoveryReviewChangeKind::Deprecate => {
                            DiscoveryReviewChangeKindDto::Deprecate
                        }
                        DiscoveryReviewChangeKind::PreserveMissing => {
                            DiscoveryReviewChangeKindDto::PreserveMissing
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
            .collect::<CoreResult<Vec<_>>>()?,
        unresolved_question_count: review.unresolved_question_count,
        warning_count: review.warning_count,
    })
}

fn map_discovery_approval_proposal(
    proposal: ProviderDiscoveryApprovalProposal,
) -> DiscoveryApprovalProposalDto {
    DiscoveryApprovalProposalDto {
        approval_id: proposal.id.as_str().to_owned(),
        grant: map_discovery_approval_grant(proposal.grant),
        grant_sha256: proposal.grant_sha256,
    }
}

fn map_request_body_shape(shape: &RequestBodyShape) -> RequestBodyShapeDto {
    match shape {
        RequestBodyShape::Null => RequestBodyShapeDto::Null,
        RequestBodyShape::Boolean => RequestBodyShapeDto::Boolean,
        RequestBodyShape::Number => RequestBodyShapeDto::Number,
        RequestBodyShape::String => RequestBodyShapeDto::String,
        RequestBodyShape::Array { items, truncated } => RequestBodyShapeDto::Array {
            items: items.iter().map(map_request_body_shape).collect(),
            truncated: *truncated,
        },
        RequestBodyShape::Object { fields, truncated } => RequestBodyShapeDto::Object {
            fields: fields
                .iter()
                .map(|field| RequestBodyFieldDto {
                    name: field.name().to_owned(),
                    shape: map_request_body_shape(field.shape()),
                })
                .collect(),
            truncated: *truncated,
        },
        RequestBodyShape::Redacted => RequestBodyShapeDto::Redacted,
        RequestBodyShape::Truncated => RequestBodyShapeDto::Truncated,
    }
}

fn map_discovery_request_preview(preview: RequestPreview) -> RequestPreviewDto {
    RequestPreviewDto {
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

fn map_discovery_review_proposal(
    proposal: ProviderDiscoveryReviewProposal,
) -> CoreResult<DiscoveryReviewProposalDto> {
    Ok(DiscoveryReviewProposalDto {
        review: map_discovery_review(proposal.review)?,
        approval: map_discovery_approval_proposal(proposal.approval),
        commit_attempt_id: proposal.commit_attempt_id.as_str().to_owned(),
        commit_plan_sha256: proposal.commit_plan_sha256,
        request_preview: proposal.request_preview.map(map_discovery_request_preview),
    })
}

fn map_discovery_progress(progress: DiscoveryProgress) -> DiscoveryProgressDto {
    DiscoveryProgressDto {
        phase: match progress.phase {
            DiscoveryProgressPhase::ProviderCandidates => {
                DiscoveryProgressPhaseDto::ProviderCandidates
            }
            DiscoveryProgressPhase::Documents => DiscoveryProgressPhaseDto::Documents,
            DiscoveryProgressPhase::Evidence => DiscoveryProgressPhaseDto::Evidence,
            DiscoveryProgressPhase::Models => DiscoveryProgressPhaseDto::Models,
            DiscoveryProgressPhase::Probes => DiscoveryProgressPhaseDto::Probes,
        },
        completed: progress.completed,
        total: progress.total,
    }
}

const fn map_discovery_warning(warning: DiscoveryWarning) -> DiscoveryWarningDto {
    match warning {
        DiscoveryWarning::AssistantDeclined => DiscoveryWarningDto::AssistantDeclined,
        DiscoveryWarning::ProbesSkipped => DiscoveryWarningDto::ProbesSkipped,
        DiscoveryWarning::CompensationRequired => DiscoveryWarningDto::CompensationRequired,
        DiscoveryWarning::ExplicitRestartRequired => DiscoveryWarningDto::ExplicitRestartRequired,
        DiscoveryWarning::UnknownExternalOutcome => DiscoveryWarningDto::UnknownExternalOutcome,
    }
}

fn map_discovery_event(event: lorepia_engine::ProviderDiscoveryEvent) -> DiscoveryEventDto {
    DiscoveryEventDto {
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

fn map_discovery_outbox_event(event: DiscoveryOutboxEvent) -> DiscoveryOutboxEventDto {
    DiscoveryOutboxEventDto {
        event: map_discovery_event(event.event),
        delivery_attempts: event.delivery_attempts,
        available_at: event.available_at.to_rfc3339(),
        created_at: event.created_at.to_rfc3339(),
    }
}

fn map_discovery_recovery_result(result: DiscoveryRecoveryResult) -> DiscoveryRecoveryResultDto {
    DiscoveryRecoveryResultDto {
        operation_id: result.operation_id.as_str().to_owned(),
        session_id: result.session_id.into_inner(),
        state: map_discovery_state(result.state),
        event: map_discovery_event(result.event),
    }
}

fn map_provider_discovery_snapshot(
    core: &Core,
    snapshot: DiscoverySessionSnapshot,
) -> CoreResult<ProviderDiscoverySnapshotDto> {
    let session_id = snapshot.session.id.clone();
    let assistant_resume_boundary = core
        .get_provider_discovery_assistant_resume_boundary(&session_id)?
        .map(map_discovery_assistant_resume_boundary);
    let pending_connection_id = snapshot.session.input.connection_id.as_str().to_owned();
    let connection_options = snapshot.session.input.connection_options.clone();
    let credential_slot_id = snapshot
        .session
        .input
        .credential_ref
        .as_ref()
        .map(|reference| reference.as_str().to_owned());
    let credential_slot_expected = credential_slot_id.is_some();
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
    let action_required = discovery_action_required_for_snapshot(&snapshot);
    Ok(ProviderDiscoverySnapshotDto {
        snapshot_schema_version: PROVIDER_DISCOVERY_SNAPSHOT_SCHEMA_VERSION,
        session_id: session_id.into_inner(),
        pending_connection_id,
        pending_display_name: snapshot.session.input.display_name.clone(),
        connection_options,
        credential_slot_id,
        credential_slot_expected,
        revision: snapshot.session.revision,
        state: map_discovery_state(state),
        next_event_sequence: snapshot.session.next_event_sequence,
        steps: discovery_steps(state),
        action_required,
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

const fn map_discovery_assistant_checkpoint(
    checkpoint: DiscoveryAssistantCheckpoint,
) -> DiscoveryAssistantCheckpointDto {
    match checkpoint {
        DiscoveryAssistantCheckpoint::Ready => DiscoveryAssistantCheckpointDto::Ready,
        DiscoveryAssistantCheckpoint::AwaitingAssistant => {
            DiscoveryAssistantCheckpointDto::AwaitingAssistant
        }
        DiscoveryAssistantCheckpoint::AwaitingToolResult => {
            DiscoveryAssistantCheckpointDto::AwaitingToolResult
        }
        DiscoveryAssistantCheckpoint::AwaitingMoreEvidence => {
            DiscoveryAssistantCheckpointDto::AwaitingMoreEvidence
        }
        DiscoveryAssistantCheckpoint::AwaitingRetryConsent => {
            DiscoveryAssistantCheckpointDto::AwaitingRetryConsent
        }
        DiscoveryAssistantCheckpoint::DraftReady => DiscoveryAssistantCheckpointDto::DraftReady,
    }
}

const fn map_discovery_assistant_resume_action(
    action: ProviderDiscoveryAssistantResumeAction,
) -> DiscoveryAssistantResumeActionDto {
    match action {
        ProviderDiscoveryAssistantResumeAction::ApproveConsent => {
            DiscoveryAssistantResumeActionDto::ApproveConsent
        }
        ProviderDiscoveryAssistantResumeAction::RunAssistant => {
            DiscoveryAssistantResumeActionDto::RunAssistant
        }
        ProviderDiscoveryAssistantResumeAction::WaitForAssistantOutcome => {
            DiscoveryAssistantResumeActionDto::WaitForAssistantOutcome
        }
        ProviderDiscoveryAssistantResumeAction::ResumeCoreHostAction => {
            DiscoveryAssistantResumeActionDto::ResumeCoreHostAction
        }
        ProviderDiscoveryAssistantResumeAction::SupplyMoreEvidence => {
            DiscoveryAssistantResumeActionDto::SupplyMoreEvidence
        }
        ProviderDiscoveryAssistantResumeAction::ApproveRetry => {
            DiscoveryAssistantResumeActionDto::ApproveRetry
        }
        ProviderDiscoveryAssistantResumeAction::ReviewDraft => {
            DiscoveryAssistantResumeActionDto::ReviewDraft
        }
        ProviderDiscoveryAssistantResumeAction::RestartInterrupted => {
            DiscoveryAssistantResumeActionDto::RestartInterrupted
        }
        ProviderDiscoveryAssistantResumeAction::ResolveUnknownOutcome => {
            DiscoveryAssistantResumeActionDto::ResolveUnknownOutcome
        }
    }
}

fn map_discovery_assistant_resume_boundary(
    boundary: ProviderDiscoveryAssistantResumeBoundary,
) -> DiscoveryAssistantResumeBoundaryDto {
    DiscoveryAssistantResumeBoundaryDto {
        checkpoint: boundary.checkpoint.map(map_discovery_assistant_checkpoint),
        action: map_discovery_assistant_resume_action(boundary.action),
        questions: boundary.questions,
        draft_review: boundary.draft_review,
    }
}

const fn map_discovery_compensation_kind(
    kind: DiscoveryCompensationKind,
) -> DiscoveryCompensationKindDto {
    match kind {
        DiscoveryCompensationKind::RemoveCredentialSlot => {
            DiscoveryCompensationKindDto::RemoveCredentialSlot
        }
        DiscoveryCompensationKind::RemoveConnectionGraph => {
            DiscoveryCompensationKindDto::RemoveConnectionGraph
        }
        DiscoveryCompensationKind::RestorePreviousSelection => {
            DiscoveryCompensationKindDto::RestorePreviousSelection
        }
    }
}

const fn map_discovery_compensation_status(
    status: DiscoveryCompensationStatus,
) -> DiscoveryCompensationStatusDto {
    match status {
        DiscoveryCompensationStatus::Pending => DiscoveryCompensationStatusDto::Pending,
        DiscoveryCompensationStatus::InProgress => DiscoveryCompensationStatusDto::InProgress,
        DiscoveryCompensationStatus::Completed => DiscoveryCompensationStatusDto::Completed,
        DiscoveryCompensationStatus::Failed => DiscoveryCompensationStatusDto::Failed,
        DiscoveryCompensationStatus::OutcomeUnknown => {
            DiscoveryCompensationStatusDto::OutcomeUnknown
        }
    }
}

fn map_discovery_previous_selection(
    previous_selection: DiscoveryPreviousSelection,
) -> DiscoveryPreviousSelectionDto {
    match previous_selection {
        DiscoveryPreviousSelection::None => DiscoveryPreviousSelectionDto::None,
        DiscoveryPreviousSelection::RouteAndPreset {
            model_route_id,
            generation_preset_id,
        } => DiscoveryPreviousSelectionDto::RouteAndPreset {
            model_route_id: model_route_id.into_inner(),
            generation_preset_id: generation_preset_id.into_inner(),
        },
    }
}

fn map_discovery_compensation_target(
    target: DiscoveryCompensationTarget,
) -> DiscoveryCompensationTargetDto {
    match target {
        DiscoveryCompensationTarget::RemoveCredentialSlot {
            connection_id,
            credential_ref,
        } => DiscoveryCompensationTargetDto::RemoveCredentialSlot {
            connection_id: connection_id.into_inner(),
            credential_ref: credential_ref.as_str().to_owned(),
        },
        DiscoveryCompensationTarget::RemoveConnectionGraph { connection_id } => {
            DiscoveryCompensationTargetDto::RemoveConnectionGraph {
                connection_id: connection_id.into_inner(),
            }
        }
        DiscoveryCompensationTarget::RestorePreviousSelection { previous_selection } => {
            DiscoveryCompensationTargetDto::RestorePreviousSelection {
                previous_selection: map_discovery_previous_selection(previous_selection),
            }
        }
    }
}

fn map_discovery_compensation_step(
    record: DiscoveryCompensationRecord,
) -> DiscoveryCompensationStepDto {
    let status = record.status;
    let step = record.step;
    DiscoveryCompensationStepDto {
        id: record.id,
        commit_attempt_id: record.commit_attempt_id.as_str().to_owned(),
        ordinal: record.ordinal,
        action_id: record.action_id.as_str().to_owned(),
        kind: map_discovery_compensation_kind(step.kind),
        target: map_discovery_compensation_target(step.target),
        status: map_discovery_compensation_status(status),
        attempt_count: record.attempt_count,
        last_failure: record.last_failure.map(map_discovery_failure),
        created_at: record.created_at.to_rfc3339(),
        updated_at: record.updated_at.to_rfc3339(),
        completed_at: record.completed_at.map(|value| value.to_rfc3339()),
    }
}

fn map_discovery_assistant_host_action(
    action: AssistantHostAction,
) -> CoreResult<DiscoveryAssistantHostActionDto> {
    match action {
        AssistantHostAction::ExecuteTool { .. } => Err(CoreError::internal(
            "setup assistant runner returned an unprogressable tool action",
        )),
        AssistantHostAction::RequestMoreEvidence {
            session_id,
            questions,
        } => Ok(DiscoveryAssistantHostActionDto::RequestMoreEvidence {
            session_id: session_id.into_inner(),
            questions,
        }),
        AssistantHostAction::ReviewDraft(review) => {
            Ok(DiscoveryAssistantHostActionDto::ReviewDraft {
                draft_review: review,
            })
        }
    }
}

const fn manifest_changed_section_name(section: ManifestChangedSection) -> &'static str {
    match section {
        ManifestChangedSection::DisplayName => "display_name",
        ManifestChangedSection::ManifestVersion => "manifest_version",
        ManifestChangedSection::ConnectionFields => "connection_fields",
        ManifestChangedSection::ApiFamily => "api_family",
        ManifestChangedSection::Sources => "sources",
        ManifestChangedSection::Origin => "origin",
        ManifestChangedSection::Authentication => "authentication",
        ManifestChangedSection::Endpoints => "endpoints",
        ManifestChangedSection::Decoders => "decoders",
        ManifestChangedSection::Parameters => "parameters",
        ManifestChangedSection::Freshness => "freshness",
    }
}

const fn model_changed_section_name(section: ModelChangedSection) -> &'static str {
    match section {
        ModelChangedSection::Match => "match",
        ModelChangedSection::ApiFamily => "api_family",
        ModelChangedSection::MetadataVersion => "metadata_version",
        ModelChangedSection::Capabilities => "capabilities",
        ModelChangedSection::Parameters => "parameters",
        ModelChangedSection::Lifecycle => "lifecycle",
        ModelChangedSection::Sources => "sources",
        ModelChangedSection::Freshness => "freshness",
    }
}

fn map_provider_catalog_template_diff(
    change: ManifestDiffDto,
) -> (CatalogChangeKind, ProviderCatalogTemplateDiffDto) {
    let kind = change.change;
    (
        kind,
        ProviderCatalogTemplateDiffDto {
            provider_template_id: change.provider_template_id.into_inner(),
            previous_manifest_version: change.previous_manifest_version,
            next_manifest_version: change.next_manifest_version,
            previous_sha256: change.previous_sha256,
            next_sha256: change.next_sha256,
            changed_sections: change
                .changed_sections
                .into_iter()
                .map(|section| manifest_changed_section_name(section).to_owned())
                .collect(),
        },
    )
}

fn map_provider_catalog_model_diff(
    change: ModelMetadataDiffDto,
) -> (CatalogChangeKind, ProviderCatalogModelDiffDto) {
    let kind = change.change;
    (
        kind,
        ProviderCatalogModelDiffDto {
            model_entry_id: change.model_entry_id,
            provider_template_id: change.provider_template_id.into_inner(),
            previous_metadata_version: change.previous_metadata_version,
            next_metadata_version: change.next_metadata_version,
            previous_sha256: change.previous_sha256,
            next_sha256: change.next_sha256,
            changed_sections: change
                .changed_sections
                .into_iter()
                .map(|section| model_changed_section_name(section).to_owned())
                .collect(),
        },
    )
}

fn map_provider_catalog_diff(diff: CatalogDiffDto) -> ProviderCatalogDiffDto {
    let mut added_provider_templates = Vec::new();
    let mut changed_provider_templates = Vec::new();
    let mut removed_provider_templates = Vec::new();
    for change in diff.manifest_changes {
        let (kind, change) = map_provider_catalog_template_diff(change);
        match kind {
            CatalogChangeKind::Added => added_provider_templates.push(change),
            CatalogChangeKind::Updated => changed_provider_templates.push(change),
            CatalogChangeKind::Removed => removed_provider_templates.push(change),
        }
    }
    let mut added_models = Vec::new();
    let mut changed_models = Vec::new();
    let mut removed_models = Vec::new();
    for change in diff.model_changes {
        let (kind, change) = map_provider_catalog_model_diff(change);
        match kind {
            CatalogChangeKind::Added => added_models.push(change),
            CatalogChangeKind::Updated => changed_models.push(change),
            CatalogChangeKind::Removed => removed_models.push(change),
        }
    }
    ProviderCatalogDiffDto {
        diff_schema_version: diff.diff_schema_version,
        from_revision: diff.from_revision,
        to_revision: diff.to_revision,
        added_provider_templates,
        changed_provider_templates,
        removed_provider_templates,
        added_models,
        changed_models,
        removed_models,
    }
}

fn map_provider_catalog_status(status: ProviderCatalogStatus) -> ProviderCatalogStatusDto {
    ProviderCatalogStatusDto {
        status_schema_version: status.status_schema_version,
        state_version: status.state_version,
        active_revision: status.active_revision,
        active_snapshot_sha256: status.active_snapshot_sha256,
        bundled_baseline_sha256: status.bundled_baseline_sha256,
        snapshot_count: status.snapshot_count,
        signed_update_count: status.signed_update_count,
        highest_accepted_revision: status.highest_accepted_revision,
        latest_issued_at: status.latest_issued_at.map(|value| value.to_rfc3339()),
        active_signed_revisions: status.active_signed_revisions,
    }
}

fn map_provider_catalog_revision_summary(
    revision: ProviderCatalogRevisionSummary,
) -> ProviderCatalogRevisionSummaryDto {
    ProviderCatalogRevisionSummaryDto {
        revision: revision.revision,
        captured_at: revision.captured_at.to_rfc3339(),
        snapshot_sha256: revision.snapshot_sha256,
        signed_revisions: revision.signed_revisions,
        active: revision.active,
    }
}

fn map_provider_catalog_activation_summary(
    activation: ProviderCatalogActivationSummary,
) -> ProviderCatalogActivationSummaryDto {
    ProviderCatalogActivationSummaryDto {
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

fn map_provider_catalog_history(history: ProviderCatalogHistory) -> ProviderCatalogHistoryDto {
    ProviderCatalogHistoryDto {
        history_schema_version: history.history_schema_version,
        active_revision: history.active_revision,
        revisions: history
            .revisions
            .into_iter()
            .map(map_provider_catalog_revision_summary)
            .collect(),
        activations: history
            .activations
            .into_iter()
            .map(map_provider_catalog_activation_summary)
            .collect(),
        next_before_revision: history.next_before_revision,
        next_before_state_version: history.next_before_state_version,
    }
}

fn map_provider_catalog_import_review(
    review: ProviderCatalogImportReview,
) -> ProviderCatalogImportReviewDto {
    ProviderCatalogImportReviewDto {
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
) -> CoreResult<ProviderCatalogImportPlanDto> {
    let plan_json = serde_json::to_string(&plan)
        .map_err(|_| CoreError::internal("catalog import plan could not be encoded"))?;
    Ok(ProviderCatalogImportPlanDto {
        review: map_provider_catalog_import_review(plan.review),
        plan_sha256: plan.plan_sha256,
        plan_json,
    })
}

fn map_provider_catalog_import_result(
    result: ProviderCatalogImportResult,
) -> ProviderCatalogImportResultDto {
    ProviderCatalogImportResultDto {
        signed_catalog_revision: result.signed_catalog_revision,
        activated_revision: result.activated_revision,
        diff: map_provider_catalog_diff(result.diff),
        status: map_provider_catalog_status(result.status),
    }
}

fn map_provider_catalog_rollback_plan(
    plan: ProviderCatalogRollbackPlan,
) -> CoreResult<ProviderCatalogRollbackPlanDto> {
    let plan_json = serde_json::to_string(&plan)
        .map_err(|_| CoreError::internal("catalog rollback plan could not be encoded"))?;
    Ok(ProviderCatalogRollbackPlanDto {
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

fn map_provider_catalog_rollback_result(
    result: ProviderCatalogRollbackResult,
) -> ProviderCatalogRollbackResultDto {
    ProviderCatalogRollbackResultDto {
        from_revision: result.from_revision,
        activated_revision: result.activated_revision,
        status: map_provider_catalog_status(result.status),
    }
}

fn map_provider_template_view(view: ProviderTemplateView) -> ProviderTemplateDto {
    let ProviderTemplateView {
        template,
        default_network_mode,
    } = view;
    let ProviderTemplate {
        id,
        display_name,
        manifest_version,
        source,
        api_family,
        connection_fields,
        default_manifest,
    } = template;
    let requires_credential = !matches!(&default_manifest.auth, AuthBinding::None);
    ProviderTemplateDto {
        id: id.into_inner(),
        display_name,
        manifest_version,
        source: template_source_name(source).to_owned(),
        api_family: api_family_name(api_family).to_owned(),
        default_network_mode: provider_network_mode_name(default_network_mode).to_owned(),
        default_api_origin: default_manifest
            .default_api_origin
            .map(|origin| origin.as_str().to_owned()),
        requires_credential,
        auth_binding: default_manifest.auth,
        supports_model_listing: default_manifest.endpoints.models.is_some(),
        connection_fields,
        parameter_specs: default_manifest.parameters,
    }
}

fn map_provider_local_network_approval(
    approval: ProviderLocalNetworkApproval,
) -> ProviderLocalNetworkApprovalDto {
    ProviderLocalNetworkApprovalDto {
        origin: approval.origin.as_str().to_owned(),
        addresses: approval
            .addresses
            .into_iter()
            .map(|address| address.to_string())
            .collect(),
    }
}

fn map_provider_connection(connection: ProviderConnection) -> ProviderConnectionDto {
    let credential_slot_required = connection.credential_scope.is_some();
    let credential_ref = connection
        .credential_ref
        .as_ref()
        .map(|reference| reference.as_str().to_owned());
    let auth_binding = connection
        .credential_scope
        .as_ref()
        .map_or(AuthBinding::None, |scope| scope.auth_binding.clone());
    let credential_redirect_policy = connection
        .credential_scope
        .as_ref()
        .map_or("deny", |scope| match scope.redirect_policy {
            lorepia_engine::CredentialRedirectPolicy::Deny => "deny",
            lorepia_engine::CredentialRedirectPolicy::FollowWithoutCredential => {
                "follow_without_credential"
            }
        })
        .to_owned();
    let approved_credential_origins = connection
        .credential_scope
        .map(|scope| {
            scope
                .allowed_origins
                .into_iter()
                .map(|origin| origin.as_str().to_owned())
                .collect()
        })
        .unwrap_or_default();
    ProviderConnectionDto {
        id: connection.id.into_inner(),
        template_id: connection.template_id.into_inner(),
        template_version: connection.template_version,
        display_name: connection.display_name,
        api_origin: connection.api_origin.as_str().to_owned(),
        api_base_path: connection
            .config
            .api_base_path
            .map(|path| path.as_str().to_owned()),
        network_mode: provider_network_mode_name(connection.config.network_mode).to_owned(),
        local_network_approval: connection
            .config
            .local_network_approval
            .map(map_provider_local_network_approval),
        values: connection.config.values,
        credential_slot_required,
        credential_ref,
        auth_binding,
        approved_credential_origins,
        credential_redirect_policy,
        timeout_seconds: connection.timeout_seconds,
        status: connection_status_name(connection.status).to_owned(),
        created_at: connection.created_at.to_rfc3339(),
        updated_at: connection.updated_at.to_rfc3339(),
    }
}

fn map_model_route(route: ModelRoute) -> ModelRouteDto {
    ModelRouteDto {
        id: route.id.into_inner(),
        connection_id: route.connection_id.into_inner(),
        api_family: api_family_name(route.api_family).to_owned(),
        model_id: route.model_id,
        display_name: route.display_name,
        route_config: route.route_config,
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
) -> ProviderModelRefreshResultDto {
    ProviderModelRefreshResultDto {
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
) -> ProviderModelRefreshProvenanceDto {
    ProviderModelRefreshProvenanceDto {
        source: provenance.source,
        api_family: api_family_name(provenance.api_family).to_owned(),
        api_origin: provenance.api_origin.as_str().to_owned(),
        endpoint_path: provenance.endpoint_path.as_str().to_owned(),
    }
}

fn map_generation_preset(preset: GenerationPreset) -> GenerationPresetDto {
    GenerationPresetDto {
        id: preset.id.into_inner(),
        model_route_id: preset.model_route_id.into_inner(),
        display_name: preset.display_name,
        values: preset.values,
        reasoning: preset.reasoning,
        prompt_cache: preset.prompt_cache,
        created_at: preset.created_at.to_rfc3339(),
        updated_at: preset.updated_at.to_rfc3339(),
    }
}

fn map_effective_capability(capability: EffectiveCapability) -> EffectiveCapabilityDto {
    EffectiveCapabilityDto {
        selected: capability.selected,
        alternatives: capability.alternatives,
        evaluated_at: capability.evaluated_at.to_rfc3339(),
        selected_is_stale: capability.selected_is_stale,
        has_conflict: capability.has_conflict,
    }
}

fn parse_capability_key(value: &str) -> CoreResult<CapabilityKey> {
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
        _ => Err(CoreError::invalid("unknown capability key")),
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

const fn provider_network_mode_name(mode: ProviderNetworkMode) -> &'static str {
    match mode {
        ProviderNetworkMode::Public => "public",
        ProviderNetworkMode::LocalLoopback => "local_loopback",
        ProviderNetworkMode::ApprovedLocalNetwork => "approved_local_network",
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

fn lock<'a, T>(mutex: &'a Mutex<T>, label: &str) -> CoreResult<std::sync::MutexGuard<'a, T>> {
    mutex
        .lock()
        .map_err(|_| CoreError::internal(format!("{label} lock was poisoned")))
}

fn last_error(handle: &LorepiaCoreHandle) -> Option<ErrorPayload> {
    match handle.last_error.lock() {
        Ok(error) => error.clone(),
        Err(poisoned) => poisoned.into_inner().clone(),
    }
}

fn replace_last_error(handle: &LorepiaCoreHandle, error: Option<ErrorPayload>) {
    match handle.last_error.lock() {
        Ok(mut slot) => *slot = error,
        Err(poisoned) => *poisoned.into_inner() = error,
    }
}

fn clear_thread_error() {
    THREAD_LAST_ERROR.with(|slot| {
        *slot.borrow_mut() = None;
    });
}

fn fail_without_handle(error: CoreError) -> i32 {
    let error = ErrorPayload::from_core(error);
    let status = error.status;
    THREAD_LAST_ERROR.with(|slot| {
        *slot.borrow_mut() = Some(error);
    });
    status
}

fn fail_with_handle(handle: &LorepiaCoreHandle, error: CoreError) -> i32 {
    let error = ErrorPayload::from_core(error);
    let status = error.status;
    replace_last_error(handle, Some(error));
    status
}

const fn status_for_error(code: CoreErrorCode) -> i32 {
    match code {
        CoreErrorCode::InvalidInput => STATUS_INVALID_ARGUMENT,
        CoreErrorCode::UnsupportedContent => STATUS_UNSUPPORTED_CONTENT,
        CoreErrorCode::UnsafeArchive => STATUS_UNSAFE_ARCHIVE,
        CoreErrorCode::NotFound => STATUS_NOT_FOUND,
        CoreErrorCode::PermissionDenied => STATUS_PERMISSION_DENIED,
        CoreErrorCode::StorageUnavailable => STATUS_STORAGE_UNAVAILABLE,
        CoreErrorCode::StorageCorrupted => STATUS_STORAGE_CORRUPTED,
        CoreErrorCode::ProviderAuthFailed => STATUS_PROVIDER_AUTH_FAILED,
        CoreErrorCode::ProviderRateLimited => STATUS_PROVIDER_RATE_LIMITED,
        CoreErrorCode::ProviderUnavailable => STATUS_PROVIDER_UNAVAILABLE,
        CoreErrorCode::NetworkUnavailable => STATUS_NETWORK_UNAVAILABLE,
        CoreErrorCode::Cancelled => STATUS_CANCELLED,
        CoreErrorCode::Internal => STATUS_INTERNAL_ERROR,
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

    use lorepia_engine::{
        BoundedJson, ChatEventKind, GenerationPresetId, GenerationUsage, ParameterId,
        ParameterLiteral, ParameterValueState,
    };
    use serde_json::Value;
    use tempfile::{NamedTempFile, tempdir};

    use super::*;

    #[test]
    fn discovery_requests_are_versioned_closed_and_secret_free() {
        let old = serde_json::json!({
            "request_schema_version": 0,
            "payload": {
                "session_id": "session"
            }
        })
        .to_string();
        let error =
            parse_versioned_request::<ProviderDiscoverySessionPayload>(&old, "request_json")
                .expect_err("old discovery request schema must fail closed");
        assert_eq!(
            error.message,
            "request_json.request_schema_version must be 1"
        );

        let internal_action = serde_json::json!({
            "request_schema_version": 1,
            "payload": {
                "action_id": "action",
                "expected_revision": 7,
                "action": {
                    "kind": "commit_succeeded",
                    "connection_id": "must-not-be-callable"
                }
            }
        })
        .to_string();
        assert!(
            parse_versioned_request::<PrepareProviderDiscoveryActionPayload>(
                &internal_action,
                "request_json",
            )
            .is_err(),
            "internal state-machine completion actions must have no C ABI form"
        );

        let credential_canary = "sk-curl-secret-canary";
        let curl_begin = serde_json::json!({
            "request_schema_version": 1,
            "payload": {
                "input": {
                    "connection_id": "connection",
                    "display_name": "Example",
                    "site_url": null,
                    "docs_url": null,
                    "credential_slot_ready": true,
                    "preferred_assistant_model_route_id": null,
                    "connection_options": {
                        "values": [],
                        "api_base_path": null,
                        "timeout_seconds": 60,
                        "network_mode": "public",
                        "local_network_approval": null
                    },
                    "supplied_evidence_ids": []
                },
                "source": {"kind": "curl"}
            }
        })
        .to_string();
        assert!(!curl_begin.contains(credential_canary));
        let parsed =
            parse_versioned_request::<BeginProviderDiscoveryPayload>(&curl_begin, "request_json")
                .expect("typed cURL discovery request");
        assert!(matches!(
            parsed.source,
            ProviderDiscoverySourcePayload::Curl
        ));

        let injected_slot = serde_json::json!({
            "request_schema_version": 1,
            "payload": {
                "input": {
                    "connection_id": "connection",
                    "display_name": "Example",
                    "site_url": "https://provider.example/",
                    "docs_url": null,
                    "credential_slot_ready": true,
                    "credential_ref": "attacker-selected-slot",
                    "preferred_assistant_model_route_id": null,
                    "connection_options": {
                        "values": [],
                        "api_base_path": null,
                        "timeout_seconds": 60,
                        "network_mode": "public",
                        "local_network_approval": null
                    },
                    "supplied_evidence_ids": []
                },
                "source": {"kind": "site"}
            }
        })
        .to_string();
        assert!(
            parse_versioned_request::<BeginProviderDiscoveryPayload>(
                &injected_slot,
                "request_json",
            )
            .is_err(),
            "native callers must not inject an arbitrary credential reference"
        );
    }

    #[test]
    fn discovery_control_flow_dtos_serialize_only_closed_wire_values() {
        let assistant_boundary =
            map_discovery_assistant_resume_boundary(ProviderDiscoveryAssistantResumeBoundary {
                checkpoint: Some(DiscoveryAssistantCheckpoint::AwaitingToolResult),
                action: ProviderDiscoveryAssistantResumeAction::ResumeCoreHostAction,
                questions: Vec::new(),
                draft_review: None,
            });
        let connection_options = ProviderDiscoveryConnectionOptions {
            values: vec![ConnectionConfigEntry {
                key: "tenant".to_owned(),
                value: lorepia_engine::ConnectionConfigValue::Text("seoul".to_owned()),
            }],
            api_base_path: Some(EndpointPath::parse("/v1").expect("base path")),
            timeout_seconds: 45,
            network_mode: ProviderNetworkMode::ApprovedLocalNetwork,
            local_network_approval: Some(ProviderLocalNetworkApproval {
                origin: CanonicalOrigin::parse("http://192.168.1.20:11434").expect("local origin"),
                addresses: vec!["192.168.1.20".parse().expect("local address")],
            }),
        };
        let value = serde_json::json!({
            "state": map_discovery_state(DiscoveryState::AwaitingReview),
            "operation": map_discovery_operation(DiscoveryOperationKind::AtomicCommit),
            "approval": DiscoveryApprovalDecisionDto::Approved,
            "review_change": DiscoveryReviewChangeKindDto::PreserveMissing,
            "review_target": DiscoveryReviewTargetKindDto::ProviderConnection,
            "compensation_kind":
                map_discovery_compensation_kind(DiscoveryCompensationKind::RemoveCredentialSlot),
            "compensation_status":
                map_discovery_compensation_status(DiscoveryCompensationStatus::OutcomeUnknown),
            "progress": DiscoveryProgressPhaseDto::ProviderCandidates,
            "warning": map_discovery_warning(DiscoveryWarning::UnknownExternalOutcome),
            "step": DiscoveryStepStateDto::Current,
            "evidence": map_discovery_evidence_kind(DiscoveryEvidenceKind::OpenApi),
            "assistant_boundary": assistant_boundary,
            "connection_options": connection_options,
        });
        assert_eq!(
            value,
            serde_json::json!({
                "state": "awaiting_review",
                "operation": "atomic_commit",
                "approval": "approved",
                "review_change": "preserve_missing",
                "review_target": "provider_connection",
                "compensation_kind": "remove_credential_slot",
                "compensation_status": "outcome_unknown",
                "progress": "provider_candidates",
                "warning": "unknown_external_outcome",
                "step": "current",
                "evidence": "open_api",
                "assistant_boundary": {
                    "checkpoint": "awaiting_tool_result",
                    "action": "resume_core_host_action",
                    "questions": [],
                    "draft_review": null,
                },
                "connection_options": {
                    "values": [{
                        "key": "tenant",
                        "value": {"type": "text", "value": "seoul"},
                    }],
                    "api_base_path": "/v1",
                    "timeout_seconds": 45,
                    "network_mode": "approved_local_network",
                    "local_network_approval": {
                        "origin": "http://192.168.1.20:11434",
                        "addresses": ["192.168.1.20"],
                    },
                },
            })
        );
    }

    #[test]
    fn c_binding_declares_no_opaque_reasoning_payload_dto() {
        let source = include_str!("lib.rs");
        for declaration in [
            ["struct Opaque", "ReasoningStateDto"].concat(),
            ["enum Opaque", "ReasoningStateDto"].concat(),
            ["type Opaque", "ReasoningStateDto"].concat(),
        ] {
            assert!(
                !source.contains(&declaration),
                "provider-native opaque reasoning payloads are internal-only"
            );
        }
    }

    #[test]
    fn catalog_diff_response_uses_typed_direction_buckets() {
        let hash_a = "a".repeat(64);
        let hash_b = "b".repeat(64);
        let diff = CatalogDiffDto {
            diff_schema_version: 1,
            from_revision: 4,
            to_revision: 5,
            manifest_changes: vec![
                ManifestDiffDto {
                    provider_template_id: ProviderTemplateId::from("provider-added"),
                    change: CatalogChangeKind::Added,
                    previous_manifest_version: None,
                    next_manifest_version: Some(1),
                    previous_sha256: None,
                    next_sha256: Some(hash_a.clone()),
                    changed_sections: vec![ManifestChangedSection::Endpoints],
                },
                ManifestDiffDto {
                    provider_template_id: ProviderTemplateId::from("provider-changed"),
                    change: CatalogChangeKind::Updated,
                    previous_manifest_version: Some(1),
                    next_manifest_version: Some(2),
                    previous_sha256: Some(hash_a.clone()),
                    next_sha256: Some(hash_b.clone()),
                    changed_sections: vec![ManifestChangedSection::Parameters],
                },
            ],
            model_changes: vec![ModelMetadataDiffDto {
                model_entry_id: "model-removed".to_owned(),
                provider_template_id: ProviderTemplateId::from("provider-changed"),
                change: CatalogChangeKind::Removed,
                previous_metadata_version: Some(3),
                next_metadata_version: None,
                previous_sha256: Some(hash_b),
                next_sha256: None,
                changed_sections: vec![ModelChangedSection::Lifecycle],
            }],
        };
        let value =
            serde_json::to_value(map_provider_catalog_diff(diff)).expect("typed catalog diff");
        assert_eq!(
            value["added_provider_templates"][0]["provider_template_id"],
            "provider-added"
        );
        assert_eq!(
            value["changed_provider_templates"][0]["changed_sections"][0],
            "parameters"
        );
        assert_eq!(
            value["removed_models"][0]["model_entry_id"],
            "model-removed"
        );
        let serialized = value.to_string();
        assert!(!serialized.contains("diff_json"));
        assert!(!serialized.contains("manifest_changes"));
        assert!(!serialized.contains("\"change\""));
    }

    #[test]
    fn request_preview_uses_recursive_typed_body_shape() {
        let root = tempdir().expect("temp root");
        // SAFETY: this test follows the documented handle and buffer lifetimes.
        unsafe {
            let handle = create_core(root.path());
            let (_connection, target) = create_catalog_target(
                handle,
                "http://127.0.0.1:21991/v1",
                "preview-connection",
                "preview-preset",
            );
            let request = serde_json::json!({
                "request_schema_version": 1,
                "payload": {
                    "model_route_id": target.model_route_id,
                    "generation_preset_id": target.generation_preset_id
                }
            })
            .to_string();
            let mut preview_buffer = LorepiaBuffer::default();
            let preview_status = lorepia_core_preview_provider_request_json(
                handle,
                request.as_ptr(),
                request.len(),
                &raw mut preview_buffer,
            );
            if preview_status != STATUS_OK {
                let error = json_call(|out| lorepia_core_last_error_json(handle, out));
                panic!("request preview failed with status {preview_status}: {error}");
            }
            let preview: Value =
                serde_json::from_str(&take_buffer(preview_buffer)).expect("request preview JSON");

            assert_eq!(preview["redaction_version"], 1);
            assert_eq!(preview["method"], "POST");
            assert_eq!(preview["body_shape"]["kind"], "object");
            assert!(preview["body_shape"]["fields"].is_array());
            assert_eq!(preview["includes_private_message"], false);
            assert_eq!(preview["includes_credential_value"], false);
            assert_eq!(preview["includes_opaque_reasoning_state"], false);
            assert!(preview.get("preview").is_none());
            assert!(preview.get("body_shape_json").is_none());
            let serialized = serde_json::to_string(&preview).expect("serialize request preview");
            assert!(!serialized.contains("c-abi-test-model"));
            assert!(!serialized.contains("\"value\":0.25"));

            lorepia_core_destroy(handle);
        }
    }

    fn file_tree_contains(root: &Path, needle: &[u8]) -> bool {
        let Ok(entries) = fs::read_dir(root) else {
            return false;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                if file_tree_contains(&path, needle) {
                    return true;
                }
            } else if fs::read(&path)
                .is_ok_and(|bytes| bytes.windows(needle.len()).any(|window| window == needle))
            {
                return true;
            }
        }
        false
    }

    #[test]
    fn curl_inspection_separates_secret_bytes_and_never_persists_them() {
        let root = tempdir().expect("temp root");
        let secret = "sk-curl-c-abi-canary";
        let raw_curl = format!(
            "curl 'https://api.openai.com/v1/chat/completions' \
             -H 'Authorization: Bearer {secret}' \
             -H 'Content-Type: application/json' \
             --data '{{\"model\":\"gpt-test\",\"stream\":true}}'"
        );
        let inspect_request = serde_json::json!({
            "request_schema_version": 1,
            "payload": {
                "connection_options": {
                    "values": [],
                    "api_base_path": null,
                    "timeout_seconds": 60,
                    "network_mode": "public",
                    "local_network_approval": null
                }
            }
        })
        .to_string();
        // SAFETY: this test follows the documented handle and buffer
        // ownership contracts.
        unsafe {
            let handle = create_core(root.path());
            let mut metadata = LorepiaBuffer::default();
            let mut credential = LorepiaBuffer::default();
            assert_eq!(
                lorepia_core_inspect_provider_curl_json(
                    handle,
                    inspect_request.as_ptr(),
                    inspect_request.len(),
                    raw_curl.as_ptr(),
                    raw_curl.len(),
                    &raw mut metadata,
                    &raw mut credential,
                ),
                STATUS_OK
            );
            let metadata_text = take_buffer(metadata);
            assert!(!metadata_text.contains(secret));
            let metadata_json: Value =
                serde_json::from_str(&metadata_text).expect("inspection metadata JSON");
            assert_eq!(metadata_json["credential_present"], true);
            assert!(
                !metadata_json["redacted_curl"]
                    .as_str()
                    .expect("redacted cURL")
                    .contains(secret)
            );
            let credential_bytes = slice::from_raw_parts(credential.ptr, credential.len).to_vec();
            assert_eq!(credential_bytes, secret.as_bytes());
            lorepia_buffer_free(credential);
            assert!(
                !file_tree_contains(root.path(), secret.as_bytes()),
                "credential canary must never enter Core persistence"
            );
            lorepia_core_destroy(handle);
        }
    }

    unsafe fn create_core(root: &Path) -> *mut LorepiaCoreHandle {
        let config = serde_json::json!({
            "data_root": root.to_string_lossy()
        })
        .to_string();
        let mut handle = ptr::null_mut();
        // SAFETY: the test passes valid pointers and owns the returned handle.
        let status = unsafe { lorepia_core_create(config.as_ptr(), config.len(), &raw mut handle) };
        assert_eq!(status, STATUS_OK);
        assert!(!handle.is_null());
        handle
    }

    unsafe fn take_buffer(buffer: LorepiaBuffer) -> String {
        // SAFETY: tests call this only for a live library-owned buffer.
        let bytes = unsafe { slice::from_raw_parts(buffer.ptr, buffer.len) };
        let text = str::from_utf8(bytes).expect("UTF-8 response").to_owned();
        // SAFETY: the buffer is freed exactly once.
        unsafe { lorepia_buffer_free(buffer) };
        text
    }

    unsafe fn json_call(call: impl FnOnce(*mut LorepiaBuffer) -> i32) -> Value {
        let mut buffer = LorepiaBuffer::default();
        assert_eq!(call(&raw mut buffer), STATUS_OK);
        // SAFETY: the successful call returned one owned JSON buffer.
        serde_json::from_str(&unsafe { take_buffer(buffer) }).expect("JSON response")
    }

    fn read_request(stream: &mut TcpStream) -> Vec<u8> {
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .expect("request timeout");
        let mut request = Vec::new();
        let mut buffer = [0_u8; 4_096];
        loop {
            let read = stream.read(&mut buffer).expect("read request");
            if read == 0 {
                return request;
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
                return request;
            }
        }
    }

    fn start_recording_sse_server(request_count: usize) -> (String, mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind SSE server");
        let address = listener.local_addr().expect("server address");
        let (request_sender, request_receiver) = mpsc::channel();
        thread::spawn(move || {
            for _ in 0..request_count {
                let (mut stream, _) = listener.accept().expect("accept request");
                let request = read_request(&mut stream);
                let _ = request_sender.send(String::from_utf8_lossy(&request).into_owned());
                let body = concat!(
                    "data: {\"choices\":[{\"index\":0,",
                    "\"delta\":{\"content\":\"Hello from ABI\"}}],",
                    "\"usage\":null}\n\n",
                    "data: {\"choices\":[{\"index\":0,",
                    "\"delta\":{},\"finish_reason\":\"stop\"}],",
                    "\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":5,",
                    "\"total_tokens\":16,\"prompt_tokens_details\":{\"cached_tokens\":7},",
                    "\"completion_tokens_details\":{\"reasoning_tokens\":3}}}\n\n",
                    "data: [DONE]\n\n"
                );
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n",
                )
                .expect("response head");
                write!(
                    stream,
                    "Content-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                )
                .expect("response body");
            }
        });
        (format!("http://{address}/v1"), request_receiver)
    }

    fn start_stalling_sse_server() -> (String, mpsc::Receiver<String>, mpsc::Sender<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind SSE server");
        let address = listener.local_addr().expect("server address");
        let (ready_sender, ready_receiver) = mpsc::channel();
        let (stop_sender, stop_receiver) = mpsc::channel();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept request");
            let request = read_request(&mut stream);
            let event =
                "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"부분😀\"}}]}\n\n";
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n",
            )
            .expect("response head");
            write!(
                stream,
                "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n{:X}\r\n{}\r\n",
                event.len(),
                event
            )
            .expect("response chunk");
            stream.flush().expect("flush response chunk");
            ready_sender
                .send(String::from_utf8_lossy(&request).into_owned())
                .expect("server ready");
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

    #[allow(clippy::too_many_lines)]
    unsafe fn create_catalog_target(
        handle: *mut LorepiaCoreHandle,
        base_url: &str,
        connection_id: &str,
        preset_id: &str,
    ) -> (Value, GenerationTarget) {
        let templates =
            unsafe { json_call(|out| lorepia_core_list_provider_templates_json(handle, out)) };
        let template = templates
            .as_array()
            .expect("templates")
            .iter()
            .find(|template| template["id"] == "openai-chat-compatible-v1")
            .expect("OpenAI chat-compatible template");
        let template_version = template["manifest_version"]
            .as_u64()
            .expect("template version");
        let api_origin = base_url
            .strip_suffix("/v1")
            .expect("test URL has the v1 base path");
        let request = serde_json::json!({
            "request_schema_version": 1,
            "payload": {
                "id": connection_id,
                "template_id": "openai-chat-compatible-v1",
                "template_version": template_version,
                "display_name": "C ABI local target",
                "api_origin": api_origin,
                "api_base_path": "/v1",
                "network_mode": "local_loopback",
                "values": [{
                    "key": "api_base_url",
                    "value": {
                        "type": "text",
                        "value": base_url
                    }
                }],
                "approved_credential_origin": api_origin,
                "timeout_seconds": 5
            }
        })
        .to_string();
        let connection = unsafe {
            json_call(|out| {
                lorepia_core_create_provider_connection_json(
                    handle,
                    request.as_ptr(),
                    request.len(),
                    out,
                )
            })
        };

        let connection_id = ProviderConnectionId::from(connection_id);
        // SAFETY: the test owns the live handle for the duration of these calls.
        let core = &unsafe { &*handle }.core;
        let saved_connection = core
            .list_provider_connections()
            .expect("provider connections")
            .into_iter()
            .find(|saved| saved.id == connection_id)
            .expect("saved provider connection");
        let observed_at = saved_connection.created_at;
        let route_id = ModelRouteId::from(format!("route-{}", connection_id.as_str()));
        core.upsert_model_route(ModelRoute {
            id: route_id.clone(),
            connection_id,
            api_family: ApiFamily::OpenAiChatCompletions,
            model_id: "c-abi-test-model".to_owned(),
            display_name: Some("C ABI test model".to_owned()),
            route_config: ModelRouteConfig::default(),
            status: ModelAvailability::Available,
            miss_count: 0,
            raw_metadata: None,
            metadata_source: ModelMetadataSource::Legacy,
            metadata_observed_at: None,
            last_reconciled_sync_job_id: None,
            metadata_sync_job_id: None,
            first_seen_at: observed_at,
            last_seen_at: Some(observed_at),
        })
        .expect("save model route");
        let generation_preset_id = GenerationPresetId::from(preset_id);
        core.upsert_generation_preset(GenerationPreset {
            id: generation_preset_id.clone(),
            model_route_id: route_id.clone(),
            display_name: "C ABI target preset".to_owned(),
            values: vec![
                ParameterValue {
                    parameter_id: ParameterId::from("temperature"),
                    state: ParameterValueState::Explicit(ParameterLiteral::Number(0.25)),
                },
                ParameterValue {
                    parameter_id: ParameterId::from("max_output_tokens"),
                    state: ParameterValueState::Explicit(ParameterLiteral::Integer(64)),
                },
            ],
            reasoning: GenerationReasoningSettings::default(),
            prompt_cache: GenerationPromptCacheSettings::default(),
            created_at: observed_at,
            updated_at: observed_at,
        })
        .expect("save generation preset");

        (
            connection,
            GenerationTarget {
                model_route_id: route_id,
                generation_preset_id,
            },
        )
    }

    unsafe fn assert_schema_version_rejected(
        handle: *mut LorepiaCoreHandle,
        status: i32,
        output: Option<&LorepiaBuffer>,
    ) {
        assert_eq!(status, STATUS_INVALID_ARGUMENT);
        if let Some(output) = output {
            assert!(output.ptr.is_null());
            assert_eq!(output.len, 0);
        }
        let error = unsafe { json_call(|out| lorepia_core_last_error_json(handle, out)) };
        assert_eq!(
            error,
            serde_json::json!({
                "status": STATUS_INVALID_ARGUMENT,
                "code": "invalid_input",
                "message": "request_json.request_schema_version must be 1",
                "recoverable": false,
                "operation_id": error["operation_id"]
            })
        );
        assert!(error["operation_id"].as_str().is_some());
    }

    #[test]
    fn c_abi_v7_rejects_old_schema_for_every_mutating_json_endpoint() {
        let root = tempdir().expect("temp root");
        // SAFETY: this test follows the documented handle and buffer lifetimes.
        unsafe {
            let handle = create_core(root.path());
            let old_request =
                serde_json::json!({"request_schema_version": 0, "payload": {}}).to_string();

            let mut output = LorepiaBuffer::default();
            let status = lorepia_core_create_provider_connection_json(
                handle,
                old_request.as_ptr(),
                old_request.len(),
                &raw mut output,
            );
            assert_schema_version_rejected(handle, status, Some(&output));

            let status = lorepia_core_delete_provider_connection_json(
                handle,
                old_request.as_ptr(),
                old_request.len(),
            );
            assert_schema_version_rejected(handle, status, None);

            output = LorepiaBuffer::default();
            let status = lorepia_core_select_generation_target_json(
                handle,
                old_request.as_ptr(),
                old_request.len(),
                &raw mut output,
            );
            assert_schema_version_rejected(handle, status, Some(&output));

            output = LorepiaBuffer::default();
            let status = lorepia_core_send_message_with_target_json(
                handle,
                old_request.as_ptr(),
                old_request.len(),
                ptr::null(),
                0,
                0,
                &raw mut output,
            );
            assert_schema_version_rejected(handle, status, Some(&output));

            output = LorepiaBuffer::default();
            let status = lorepia_core_send_message_to_branch_with_target_json(
                handle,
                old_request.as_ptr(),
                old_request.len(),
                ptr::null(),
                0,
                0,
                &raw mut output,
            );
            assert_schema_version_rejected(handle, status, Some(&output));

            output = LorepiaBuffer::default();
            let status = lorepia_core_edit_user_message_with_target_json(
                handle,
                old_request.as_ptr(),
                old_request.len(),
                ptr::null(),
                0,
                0,
                &raw mut output,
            );
            assert_schema_version_rejected(handle, status, Some(&output));

            output = LorepiaBuffer::default();
            let status = lorepia_core_regenerate_assistant_message_with_target_json(
                handle,
                old_request.as_ptr(),
                old_request.len(),
                ptr::null(),
                0,
                0,
                &raw mut output,
            );
            assert_schema_version_rejected(handle, status, Some(&output));

            output = LorepiaBuffer::default();
            let status = lorepia_core_resume_provider_discovery_assistant_core_host_action_json(
                handle,
                old_request.as_ptr(),
                old_request.len(),
                &raw mut output,
            );
            assert_schema_version_rejected(handle, status, Some(&output));

            lorepia_core_destroy(handle);
        }
    }

    #[test]
    fn c_abi_v7_event_dto_keeps_version_three_and_safe_usage_fields() {
        let root = tempdir().expect("temp root");
        // SAFETY: this test follows the documented handle and buffer lifetimes.
        unsafe {
            let handle = create_core(root.path());
            let (event_sender, event_receiver) = broadcast::channel(4);
            *(&*handle).events.lock().expect("event receiver") = event_receiver;
            let event = ChatEvent::new(
                GenerationId("generation-v4".to_owned()),
                ConversationId("conversation-v4".to_owned()),
                7,
                ChatEventKind::UsageUpdated(GenerationUsage {
                    input_tokens: Some(21),
                    cached_read_tokens: Some(13),
                    cached_write_tokens: Some(8),
                    output_tokens: Some(5),
                    reasoning_tokens: Some(3),
                    tool_tokens: Some(2),
                    provider_raw_summary: Some(
                        BoundedJson::parse(
                            r#"{"accepted_prediction_tokens":1,"finish_reason":"stop"}"#,
                        )
                        .expect("bounded usage summary"),
                    ),
                }),
            )
            .with_route(
                ConversationBranchId("branch-v4".to_owned()),
                MessageId("assistant-v4".to_owned()),
            );
            assert_eq!(event.event_version, 4);
            event_sender.send(event).expect("send test event");

            let batch = json_call(|out| lorepia_core_poll_events_json(handle, 4, out));
            assert_eq!(batch["dropped_events"], 0);
            let events = batch["events"].as_array().expect("event batch");
            assert_eq!(events.len(), 1);
            assert_eq!(events[0]["event_version"], 4);
            assert_eq!(events[0]["generation_id"], "generation-v4");
            assert_eq!(events[0]["conversation_id"], "conversation-v4");
            assert_eq!(events[0]["branch_id"], "branch-v4");
            assert_eq!(events[0]["assistant_message_id"], "assistant-v4");
            assert_eq!(events[0]["sequence"], 7);
            assert!(events[0]["emitted_at"].is_string());
            assert_eq!(
                events[0]["kind"],
                serde_json::json!({
                    "type": "usage_updated",
                    "payload": {
                        "input_tokens": 21,
                        "cached_read_tokens": 13,
                        "cached_write_tokens": 8,
                        "output_tokens": 5,
                        "reasoning_tokens": 3,
                        "tool_tokens": 2,
                        "provider_raw_summary":
                            "{\"accepted_prediction_tokens\":1,\"finish_reason\":\"stop\"}"
                    }
                })
            );

            lorepia_core_destroy(handle);
        }
    }

    #[test]
    #[allow(clippy::too_many_lines)]
    fn c_abi_v7_preserves_v3_import_chat_profiles_settings_and_events() {
        let root = tempdir().expect("temp root");
        // SAFETY: this test follows the documented handle and buffer lifetimes.
        unsafe {
            let handle = create_core(root.path());
            assert_eq!(lorepia_abi_version(), 7);
            assert_eq!(PROVIDER_DISCOVERY_SNAPSHOT_SCHEMA_VERSION, 3);

            let mut version_buffer = LorepiaBuffer::default();
            assert_eq!(
                lorepia_core_version(handle, &raw mut version_buffer),
                STATUS_OK
            );
            assert_eq!(take_buffer(version_buffer), lorepia_engine::core_version());

            let health = json_call(|out| lorepia_core_health_check_json(handle, out));
            assert_eq!(health["core_version"], lorepia_engine::core_version());
            assert_eq!(health["database_open"], true);
            assert_eq!(health["data_root_writable"], true);
            assert_eq!(health["staging_writable"], true);
            assert_eq!(
                json_call(|out| lorepia_core_list_characters_json(handle, out)),
                serde_json::json!([])
            );
            assert_eq!(
                json_call(|out| lorepia_core_list_conversations_json(handle, out)),
                serde_json::json!([])
            );
            assert_eq!(
                json_call(|out| lorepia_core_list_provider_profiles_json(handle, out)),
                serde_json::json!([])
            );
            assert!(
                json_call(|out| lorepia_core_get_settings_json(handle, out))
                    ["selected_provider_profile_id"]
                    .is_null()
            );

            let name = "세구 😀 e\u{301}";
            let description = "큰문자열😀".repeat(8_192);
            let mut card = NamedTempFile::new().expect("card file");
            write!(
                card,
                r#"{{"spec":"chara_card_v3","data":{{
                    "name":"{name}",
                    "description":"{description}",
                    "personality":"unused fallback",
                    "creator":"Synthetic"
                }}}}"#
            )
            .expect("write card");
            let path = card.path().to_string_lossy();

            let discarded = json_call(|out| {
                lorepia_core_inspect_import_json(handle, path.as_ptr(), path.len(), out)
            });
            let discarded_id = discarded["id"].as_str().expect("inspection id");
            assert_eq!(
                lorepia_core_discard_import(handle, discarded_id.as_ptr(), discarded_id.len()),
                STATUS_OK
            );

            let inspection = json_call(|out| {
                lorepia_core_inspect_import_json(handle, path.as_ptr(), path.len(), out)
            });
            assert_eq!(inspection["kind"], "character_card_v3");
            assert_eq!(inspection["display_name"], name);
            assert_eq!(inspection["description"], description);
            assert!(inspection["representative_image"].is_null());
            assert_eq!(
                inspection["unsupported_optional_fields"],
                serde_json::json!(["creator", "personality"])
            );
            let inspection_id = inspection["id"].as_str().expect("inspection id");
            let character = json_call(|out| {
                lorepia_core_commit_import_json(
                    handle,
                    inspection_id.as_ptr(),
                    inspection_id.len(),
                    out,
                )
            });
            let character_id = character["id"].as_str().expect("character id");
            assert!(character["avatar_asset_hash"].is_null());

            let fetched = json_call(|out| {
                lorepia_core_get_character_json(
                    handle,
                    character_id.as_ptr(),
                    character_id.len(),
                    out,
                )
            });
            assert_eq!(fetched["name"], name);
            assert_eq!(fetched["description"], description);
            let characters = json_call(|out| lorepia_core_list_characters_json(handle, out));
            assert_eq!(characters.as_array().expect("characters").len(), 1);

            let package = Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../testdata/packages/with-avatar.charx");
            let package_path = package.to_string_lossy();
            let package_inspection = json_call(|out| {
                lorepia_core_inspect_import_json(
                    handle,
                    package_path.as_ptr(),
                    package_path.len(),
                    out,
                )
            });
            assert_eq!(
                package_inspection["representative_image"],
                serde_json::json!({
                    "logical_asset_id": "assets/avatar.png",
                    "media_type": "image/png",
                    "size_bytes": 70
                })
            );
            let package_inspection_id = package_inspection["id"]
                .as_str()
                .expect("package inspection id");
            assert_eq!(
                lorepia_core_discard_import(
                    handle,
                    package_inspection_id.as_ptr(),
                    package_inspection_id.len()
                ),
                STATUS_OK
            );

            let conversation = json_call(|out| {
                lorepia_core_open_conversation_json(
                    handle,
                    character_id.as_ptr(),
                    character_id.len(),
                    out,
                )
            });
            assert_eq!(conversation["title"], name);
            let conversation_id = conversation["id"].as_str().expect("conversation id");
            let conversations = json_call(|out| lorepia_core_list_conversations_json(handle, out));
            assert_eq!(conversations.as_array().expect("conversations").len(), 1);
            assert_eq!(
                json_call(|out| {
                    lorepia_core_list_messages_json(
                        handle,
                        conversation_id.as_ptr(),
                        conversation_id.len(),
                        out,
                    )
                }),
                serde_json::json!([])
            );

            let (base_url, provider_requests) = start_recording_sse_server(1);
            let profile = serde_json::json!({
                "id": "local",
                "display_name": "Local test",
                "base_url": base_url,
                "model": "test",
                "timeout_seconds": 5
            })
            .to_string();
            let normalized = json_call(|out| {
                lorepia_core_upsert_provider_profile_json(
                    handle,
                    profile.as_ptr(),
                    profile.len(),
                    out,
                )
            });
            assert_eq!(normalized["id"], "local");
            let profiles = json_call(|out| lorepia_core_list_provider_profiles_json(handle, out));
            assert_eq!(profiles.as_array().expect("profiles").len(), 1);

            let settings = serde_json::json!({
                "preserve_partial_generations": false,
                "selected_provider_profile_id": "local"
            })
            .to_string();
            assert_eq!(
                lorepia_core_update_settings_json(handle, settings.as_ptr(), settings.len()),
                STATUS_OK
            );
            let loaded_settings = json_call(|out| lorepia_core_get_settings_json(handle, out));
            assert_eq!(loaded_settings["selected_provider_profile_id"], "local");

            let text = "질문😀".repeat(4_096);
            let profile_id = "local";
            let generation = json_call(|out| {
                lorepia_core_send_message_json(
                    handle,
                    conversation_id.as_ptr(),
                    conversation_id.len(),
                    text.as_ptr(),
                    text.len(),
                    profile_id.as_ptr(),
                    profile_id.len(),
                    ptr::null(),
                    0,
                    0,
                    out,
                )
            });
            let generation_id = generation.as_str().expect("generation id");
            let provider_request = provider_requests
                .recv_timeout(Duration::from_secs(2))
                .expect("provider request");
            assert_post_request_path(&provider_request, "/v1/chat/completions");

            let deadline = Instant::now() + Duration::from_secs(5);
            let mut finished = false;
            let mut terminal = false;
            let mut events = Vec::new();
            while Instant::now() < deadline {
                let batch = json_call(|out| lorepia_core_poll_events_json(handle, 64, out));
                let batch_events = batch["events"].as_array().expect("events");
                finished |= batch_events
                    .iter()
                    .any(|event| event["kind"]["type"] == "generation_finished");
                terminal |= batch_events.iter().any(|event| {
                    matches!(
                        event["kind"]["type"].as_str(),
                        Some("generation_finished" | "generation_failed" | "generation_cancelled")
                    )
                });
                events.extend(batch_events.iter().cloned());
                if terminal {
                    break;
                }
                thread::sleep(Duration::from_millis(10));
            }
            assert!(finished, "generation did not finish: {events:?}");
            assert!(events.iter().all(|event| {
                event["event_version"] == 4
                    && event["generation_id"] == generation_id
                    && event["conversation_id"] == conversation_id
                    && event["branch_id"].is_string()
                    && event["assistant_message_id"].is_string()
            }));

            let messages = json_call(|out| {
                lorepia_core_list_messages_json(
                    handle,
                    conversation_id.as_ptr(),
                    conversation_id.len(),
                    out,
                )
            });
            let messages = messages.as_array().expect("messages");
            assert_eq!(messages.len(), 2);
            assert_eq!(messages[0]["content"], text);
            assert_eq!(messages[0]["role"], "user");
            assert!(messages[0]["parent_id"].is_null());
            assert!(messages[0]["generation_id"].is_null());
            assert_eq!(messages[1]["content"], "Hello from ABI");
            assert_eq!(messages[1]["role"], "assistant");
            assert_eq!(messages[1]["status"], "complete");
            assert!(messages[1]["generation_id"].is_string());
            assert!(
                events
                    .windows(2)
                    .all(|pair| pair[0]["sequence"].as_u64() < pair[1]["sequence"].as_u64())
            );
            assert_eq!(events[0]["kind"]["type"], "generation_started");
            assert!(
                events
                    .iter()
                    .any(|event| event["kind"]["type"] == "text_delta")
            );
            assert_eq!(
                events.last().expect("terminal event")["kind"]["type"],
                "generation_finished"
            );

            let unknown_generation = "unknown";
            assert_eq!(
                lorepia_core_cancel_generation(
                    handle,
                    unknown_generation.as_ptr(),
                    unknown_generation.len()
                ),
                STATUS_NOT_FOUND
            );
            let error = json_call(|out| lorepia_core_last_error_json(handle, out));
            assert_eq!(error["code"], "not_found");
            assert_eq!(error["status"], STATUS_NOT_FOUND);

            assert_eq!(
                lorepia_core_delete_provider_profile(handle, profile_id.as_ptr(), profile_id.len()),
                STATUS_OK
            );
            lorepia_core_destroy(handle);
        }
    }

    #[test]
    #[allow(clippy::too_many_lines)]
    fn c_abi_cancels_generation_and_preserves_event_order() {
        let root = tempdir().expect("temp root");
        // SAFETY: this test follows the documented handle and buffer lifetimes.
        unsafe {
            let handle = create_core(root.path());
            let mut card = NamedTempFile::new().expect("card file");
            write!(
                card,
                r#"{{"spec":"chara_card_v3","data":{{"name":"취소 테스트","description":"Synthetic"}}}}"#
            )
            .expect("write card");
            let path = card.path().to_string_lossy();
            let inspection = json_call(|out| {
                lorepia_core_inspect_import_json(handle, path.as_ptr(), path.len(), out)
            });
            let inspection_id = inspection["id"].as_str().expect("inspection id");
            let character = json_call(|out| {
                lorepia_core_commit_import_json(
                    handle,
                    inspection_id.as_ptr(),
                    inspection_id.len(),
                    out,
                )
            });
            let character_id = character["id"].as_str().expect("character id");
            let conversation = json_call(|out| {
                lorepia_core_open_conversation_json(
                    handle,
                    character_id.as_ptr(),
                    character_id.len(),
                    out,
                )
            });
            let conversation_id = conversation["id"].as_str().expect("conversation id");

            let (base_url, provider_ready, provider_stop) = start_stalling_sse_server();
            let profile = serde_json::json!({
                "id": "cancellation",
                "display_name": "Cancellation test",
                "base_url": base_url,
                "model": "test",
                "timeout_seconds": 5
            })
            .to_string();
            let saved_profile = json_call(|out| {
                lorepia_core_upsert_provider_profile_json(
                    handle,
                    profile.as_ptr(),
                    profile.len(),
                    out,
                )
            });
            let profile_id = saved_profile["id"].as_str().expect("profile id");
            let text = "중지해";
            let generation = json_call(|out| {
                lorepia_core_send_message_json(
                    handle,
                    conversation_id.as_ptr(),
                    conversation_id.len(),
                    text.as_ptr(),
                    text.len(),
                    profile_id.as_ptr(),
                    profile_id.len(),
                    ptr::null(),
                    0,
                    0,
                    out,
                )
            });
            let generation_id = generation.as_str().expect("generation id");
            let provider_request = provider_ready
                .recv_timeout(Duration::from_secs(2))
                .expect("provider started streaming");
            assert_post_request_path(&provider_request, "/v1/chat/completions");

            let deadline = Instant::now() + Duration::from_secs(5);
            let mut events = Vec::new();
            loop {
                let batch = json_call(|out| lorepia_core_poll_events_json(handle, 64, out));
                events.extend(
                    batch["events"]
                        .as_array()
                        .expect("events")
                        .iter()
                        .filter(|event| event["generation_id"] == generation_id)
                        .cloned(),
                );
                if events
                    .iter()
                    .any(|event| event["kind"]["type"] == "text_delta")
                {
                    break;
                }
                assert!(Instant::now() < deadline, "text delta did not arrive");
                thread::sleep(Duration::from_millis(10));
            }

            assert_eq!(
                lorepia_core_cancel_generation(handle, generation_id.as_ptr(), generation_id.len(),),
                STATUS_OK
            );
            loop {
                let batch = json_call(|out| lorepia_core_poll_events_json(handle, 64, out));
                events.extend(
                    batch["events"]
                        .as_array()
                        .expect("events")
                        .iter()
                        .filter(|event| event["generation_id"] == generation_id)
                        .cloned(),
                );
                if events
                    .iter()
                    .any(|event| event["kind"]["type"] == "generation_cancelled")
                {
                    break;
                }
                assert!(
                    Instant::now() < deadline,
                    "cancellation event did not arrive"
                );
                thread::sleep(Duration::from_millis(10));
            }
            let _ = provider_stop.send(());

            assert!(
                events
                    .windows(2)
                    .all(|pair| pair[0]["sequence"].as_u64() < pair[1]["sequence"].as_u64())
            );
            assert_eq!(events[0]["kind"]["type"], "generation_started");
            assert_eq!(
                events.last().expect("terminal event")["kind"]["type"],
                "generation_cancelled"
            );
            let messages = json_call(|out| {
                lorepia_core_list_messages_json(
                    handle,
                    conversation_id.as_ptr(),
                    conversation_id.len(),
                    out,
                )
            });
            let messages = messages.as_array().expect("messages");
            assert_eq!(messages[1]["content"], "부분😀");
            assert_eq!(messages[1]["status"], "cancelled");
            lorepia_core_destroy(handle);
        }
    }

    #[test]
    fn invalid_utf8_and_create_failures_have_structured_errors() {
        let root = tempdir().expect("temp root");
        // SAFETY: this test follows the documented handle and buffer lifetimes.
        unsafe {
            let handle = create_core(root.path());
            let invalid = [0xff_u8];
            let mut output = LorepiaBuffer::default();
            assert_eq!(
                lorepia_core_get_character_json(
                    handle,
                    invalid.as_ptr(),
                    invalid.len(),
                    &raw mut output,
                ),
                STATUS_INVALID_ARGUMENT
            );
            assert!(output.ptr.is_null());
            let error = json_call(|out| lorepia_core_last_error_json(handle, out));
            assert_eq!(error["code"], "invalid_input");
            lorepia_core_destroy(handle);

            let invalid_config = b"not-json";
            let mut failed_handle = ptr::null_mut();
            assert_eq!(
                lorepia_core_create(
                    invalid_config.as_ptr(),
                    invalid_config.len(),
                    &raw mut failed_handle,
                ),
                STATUS_INVALID_ARGUMENT
            );
            assert!(failed_handle.is_null());
            let error = json_call(|out| lorepia_core_last_error_json(ptr::null(), out));
            assert_eq!(error["code"], "invalid_input");
        }
    }
}
