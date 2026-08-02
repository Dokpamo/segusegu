using System.Text.Json.Serialization;

namespace Lorepia.Native;

public sealed record ProviderCurlInspection
{
    [JsonPropertyName("inspection_schema_version")]
    public uint InspectionSchemaVersion { get; init; }

    [JsonPropertyName("sanitized_site_url")]
    public string SanitizedSiteUrl { get; init; } = string.Empty;

    [JsonPropertyName("api_origin")]
    public string ApiOrigin { get; init; } = string.Empty;

    [JsonPropertyName("method")]
    public string Method { get; init; } = string.Empty;

    [JsonPropertyName("path")]
    public string Path { get; init; } = string.Empty;

    [JsonPropertyName("header_names")]
    public IReadOnlyList<string> HeaderNames { get; init; } = [];

    [JsonPropertyName("auth_binding_hint")]
    public ProviderAuthBinding? AuthBindingHint { get; init; }

    [JsonPropertyName("api_family_hint")]
    public string? ApiFamilyHint { get; init; }

    [JsonPropertyName("model_hint")]
    public string? ModelHint { get; init; }

    [JsonPropertyName("stream_hint")]
    public bool? StreamHint { get; init; }

    [JsonPropertyName("redacted_curl")]
    public string RedactedCurl { get; init; } = string.Empty;

    [JsonPropertyName("credential_present")]
    public bool CredentialPresent { get; init; }
}

public sealed record ProviderDiscoveryConnectionOptions
{
    [JsonPropertyName("values")]
    public IReadOnlyList<ConnectionConfigEntry> Values { get; init; } = [];

    [JsonPropertyName("api_base_path")]
    public string? ApiBasePath { get; init; }

    [JsonPropertyName("timeout_seconds")]
    public uint TimeoutSeconds { get; init; } = 60;

    [JsonPropertyName("network_mode")]
    public ProviderNetworkMode NetworkMode { get; init; }

    [JsonPropertyName("local_network_approval")]
    public ProviderLocalNetworkApproval? LocalNetworkApproval { get; init; }
}

public sealed record ProviderDiscoveryInput
{
    [JsonPropertyName("connection_id")]
    public string ConnectionId { get; init; } = string.Empty;

    [JsonPropertyName("display_name")]
    public string DisplayName { get; init; } = string.Empty;

    [JsonPropertyName("site_url")]
    public string? SiteUrl { get; init; }

    [JsonPropertyName("docs_url")]
    public string? DocsUrl { get; init; }

    [JsonPropertyName("credential_slot_ready")]
    public bool CredentialSlotReady { get; init; }

    [JsonPropertyName("preferred_assistant_model_route_id")]
    public string? PreferredAssistantModelRouteId { get; init; }

    [JsonPropertyName("connection_options")]
    public ProviderDiscoveryConnectionOptions ConnectionOptions { get; init; } =
        new();

    [JsonPropertyName("supplied_evidence_ids")]
    public IReadOnlyList<string> SuppliedEvidenceIds { get; init; } = [];
}

public sealed record ProviderDiscoverySource
{
    [JsonPropertyName("kind")]
    public string Kind { get; init; } = string.Empty;

    [JsonPropertyName("template_id")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? TemplateId { get; init; }
}

public sealed record ProviderDiscoveryFailure
{
    [JsonPropertyName("code")]
    public string Code { get; init; } = string.Empty;

    [JsonPropertyName("message_key")]
    public string MessageKey { get; init; } = string.Empty;

    [JsonPropertyName("recoverable")]
    public bool Recoverable { get; init; }
}

public sealed record ProviderDiscoveryActionRequired
{
    [JsonPropertyName("kind")]
    public string Kind { get; init; } = string.Empty;

    [JsonPropertyName("operation")]
    public string? Operation { get; init; }
}

public sealed record ProviderDiscoveryStep
{
    [JsonPropertyName("id")]
    public string Id { get; init; } = string.Empty;

    [JsonPropertyName("title_key")]
    public string TitleKey { get; init; } = string.Empty;

    [JsonPropertyName("state")]
    public string State { get; init; } = string.Empty;
}

public sealed record ProviderDiscoveryCandidateSummary
{
    [JsonPropertyName("kind")]
    public string Kind { get; init; } = string.Empty;

    [JsonPropertyName("template_id")]
    public string? TemplateId { get; init; }

    [JsonPropertyName("template_version")]
    public uint? TemplateVersion { get; init; }

    [JsonPropertyName("origin")]
    public string? Origin { get; init; }

    [JsonPropertyName("content_sha256")]
    public string? ContentSha256 { get; init; }

    [JsonPropertyName("model_id")]
    public string? ModelId { get; init; }

    [JsonPropertyName("schema_version")]
    public uint? SchemaVersion { get; init; }

    [JsonPropertyName("manifest_sha256")]
    public string? ManifestSha256 { get; init; }
}

public sealed record ProviderDiscoveryCandidate
{
    [JsonPropertyName("id")]
    public string Id { get; init; } = string.Empty;

    [JsonPropertyName("proposed_revision")]
    public ulong ProposedRevision { get; init; }

    [JsonPropertyName("summary")]
    public ProviderDiscoveryCandidateSummary Summary { get; init; } = new();

    [JsonPropertyName("evidence_ids")]
    public IReadOnlyList<string> EvidenceIds { get; init; } = [];

    [JsonPropertyName("created_at")]
    public DateTimeOffset CreatedAt { get; init; }
}

public sealed record ProviderDiscoveryEvidence
{
    [JsonPropertyName("id")]
    public string Id { get; init; } = string.Empty;

    [JsonPropertyName("kind")]
    public string Kind { get; init; } = string.Empty;

    [JsonPropertyName("content_sha256")]
    public string ContentSha256 { get; init; } = string.Empty;

    [JsonPropertyName("fetched_at")]
    public DateTimeOffset FetchedAt { get; init; }
}

public sealed record ProviderDiscoveryProbeBudget
{
    [JsonPropertyName("max_requests")]
    public uint MaxRequests { get; init; }

    [JsonPropertyName("max_total_tokens_per_request")]
    public ulong MaxTotalTokensPerRequest { get; init; }

    [JsonPropertyName("max_output_tokens_per_request")]
    public ulong MaxOutputTokensPerRequest { get; init; }

    [JsonPropertyName("max_cost_micro_usd_per_request")]
    public ulong MaxCostMicroUsdPerRequest { get; init; }

    [JsonPropertyName("max_duration_millis_per_request")]
    public ulong MaxDurationMillisPerRequest { get; init; }

    [JsonPropertyName("max_calls_per_request")]
    public uint MaxCallsPerRequest { get; init; }
}

public sealed record ProviderDiscoveryApprovalGrant
{
    [JsonPropertyName("kind")]
    public string Kind { get; init; } = string.Empty;

    [JsonPropertyName("candidate_id")]
    public string? CandidateId { get; init; }

    [JsonPropertyName("assistant_model_route_id")]
    public string? AssistantModelRouteId { get; init; }

    [JsonPropertyName("evidence_ids")]
    public IReadOnlyList<string>? EvidenceIds { get; init; }

    [JsonPropertyName("allowed_document_origins")]
    public IReadOnlyList<string>? AllowedDocumentOrigins { get; init; }

    [JsonPropertyName("max_calls")]
    public uint? MaxCalls { get; init; }

    [JsonPropertyName("max_input_tokens")]
    public uint? MaxInputTokens { get; init; }

    [JsonPropertyName("max_output_tokens")]
    public uint? MaxOutputTokens { get; init; }

    [JsonPropertyName("max_tool_calls")]
    public uint? MaxToolCalls { get; init; }

    [JsonPropertyName("max_retries")]
    public uint? MaxRetries { get; init; }

    [JsonPropertyName("max_cost_micro_units")]
    public ulong? MaxCostMicroUnits { get; init; }

    [JsonPropertyName("origin")]
    public string? Origin { get; init; }

    [JsonPropertyName("auth_binding")]
    public ProviderAuthBinding? AuthBinding { get; init; }

    [JsonPropertyName("manifest_sha256")]
    public string? ManifestSha256 { get; init; }

    [JsonPropertyName("model_route_ids")]
    public IReadOnlyList<string>? ModelRouteIds { get; init; }

    [JsonPropertyName("budget")]
    public ProviderDiscoveryProbeBudget? Budget { get; init; }

    [JsonPropertyName("review_sha256")]
    public string? ReviewSha256 { get; init; }

    [JsonPropertyName("graph_sha256")]
    public string? GraphSha256 { get; init; }

    [JsonPropertyName("operation")]
    public string? Operation { get; init; }

    [JsonPropertyName("resolution")]
    public ProviderDiscoveryUnknownResolution? Resolution { get; init; }
}

public sealed record ProviderDiscoveryApproval
{
    [JsonPropertyName("id")]
    public string Id { get; init; } = string.Empty;

    [JsonPropertyName("session_revision")]
    public ulong SessionRevision { get; init; }

    [JsonPropertyName("decision")]
    public string Decision { get; init; } = string.Empty;

    [JsonPropertyName("grant")]
    public ProviderDiscoveryApprovalGrant Grant { get; init; } = new();

    [JsonPropertyName("created_at")]
    public DateTimeOffset CreatedAt { get; init; }
}

public sealed record ProviderDiscoveryApprovalProposal
{
    [JsonPropertyName("approval_id")]
    public string ApprovalId { get; init; } = string.Empty;

    [JsonPropertyName("grant")]
    public ProviderDiscoveryApprovalGrant Grant { get; init; } = new();

    [JsonPropertyName("grant_sha256")]
    public string GrantSha256 { get; init; } = string.Empty;
}

public sealed record ProviderDiscoveryReviewChange
{
    [JsonPropertyName("kind")]
    public string Kind { get; init; } = string.Empty;

    [JsonPropertyName("target_kind")]
    public string TargetKind { get; init; } = string.Empty;

    [JsonPropertyName("target_id")]
    public string TargetId { get; init; } = string.Empty;

    [JsonPropertyName("summary_key")]
    public string SummaryKey { get; init; } = string.Empty;

    [JsonPropertyName("evidence_ids")]
    public IReadOnlyList<string> EvidenceIds { get; init; } = [];
}

public sealed record ProviderDiscoveryReview
{
    [JsonPropertyName("sha256")]
    public string Sha256 { get; init; } = string.Empty;

    [JsonPropertyName("graph_sha256")]
    public string GraphSha256 { get; init; } = string.Empty;

    [JsonPropertyName("changes")]
    public IReadOnlyList<ProviderDiscoveryReviewChange> Changes { get; init; } =
        [];

    [JsonPropertyName("unresolved_question_count")]
    public uint UnresolvedQuestionCount { get; init; }

    [JsonPropertyName("warning_count")]
    public uint WarningCount { get; init; }
}

public sealed record ProviderDiscoveryReviewProposal
{
    [JsonPropertyName("review")]
    public ProviderDiscoveryReview Review { get; init; } = new();

    [JsonPropertyName("approval")]
    public ProviderDiscoveryApprovalProposal Approval { get; init; } = new();

    [JsonPropertyName("commit_attempt_id")]
    public string CommitAttemptId { get; init; } = string.Empty;

    [JsonPropertyName("commit_plan_sha256")]
    public string CommitPlanSha256 { get; init; } = string.Empty;

    [JsonPropertyName("request_preview")]
    public ProviderRequestPreview? RequestPreview { get; init; }
}

[JsonConverter(typeof(SnakeCaseEnumConverter<ProviderDiscoveryAssistantCheckpoint>))]
public enum ProviderDiscoveryAssistantCheckpoint
{
    Ready,
    AwaitingAssistant,
    AwaitingToolResult,
    AwaitingMoreEvidence,
    AwaitingRetryConsent,
    DraftReady,
}

[JsonConverter(typeof(SnakeCaseEnumConverter<ProviderDiscoveryAssistantResumeAction>))]
public enum ProviderDiscoveryAssistantResumeAction
{
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

public sealed record ProviderDiscoverySnapshot
{
    [JsonPropertyName("snapshot_schema_version")]
    public uint SnapshotSchemaVersion { get; init; }

    [JsonPropertyName("session_id")]
    public string SessionId { get; init; } = string.Empty;

    [JsonPropertyName("pending_connection_id")]
    public string PendingConnectionId { get; init; } = string.Empty;

    [JsonPropertyName("pending_display_name")]
    public string PendingDisplayName { get; init; } = string.Empty;

    [JsonRequired]
    [JsonPropertyName("connection_options")]
    public ProviderDiscoveryConnectionOptions ConnectionOptions { get; init; } =
        new();

    [JsonPropertyName("credential_slot_id")]
    public string? CredentialSlotId { get; init; }

    [JsonPropertyName("credential_slot_expected")]
    public bool CredentialSlotExpected { get; init; }

    [JsonPropertyName("revision")]
    public ulong Revision { get; init; }

    [JsonPropertyName("state")]
    public string State { get; init; } = string.Empty;

    [JsonPropertyName("next_event_sequence")]
    public ulong NextEventSequence { get; init; }

    [JsonPropertyName("steps")]
    public IReadOnlyList<ProviderDiscoveryStep> Steps { get; init; } = [];

    [JsonPropertyName("action_required")]
    public ProviderDiscoveryActionRequired? ActionRequired { get; init; }

    [JsonPropertyName("active_operation_id")]
    public string? ActiveOperationId { get; init; }

    [JsonPropertyName("recovery_operation")]
    public string? RecoveryOperation { get; init; }

    [JsonPropertyName("unknown_operation")]
    public string? UnknownOperation { get; init; }

    [JsonPropertyName("manifest_sha256")]
    public string? ManifestSha256 { get; init; }

    [JsonPropertyName("commit_plan_sha256")]
    public string? CommitPlanSha256 { get; init; }

    [JsonPropertyName("commit_attempt_id")]
    public string? CommitAttemptId { get; init; }

    [JsonPropertyName("committed_connection_id")]
    public string? CommittedConnectionId { get; init; }

    [JsonPropertyName("cancellation_pending")]
    public bool CancellationPending { get; init; }

    [JsonPropertyName("failure")]
    public ProviderDiscoveryFailure? Failure { get; init; }

    [JsonPropertyName("candidates")]
    public IReadOnlyList<ProviderDiscoveryCandidate> Candidates { get; init; } =
        [];

    [JsonPropertyName("evidence")]
    public IReadOnlyList<ProviderDiscoveryEvidence> Evidence { get; init; } = [];

    [JsonPropertyName("approvals")]
    public IReadOnlyList<ProviderDiscoveryApproval> Approvals { get; init; } =
        [];

    [JsonPropertyName("review")]
    public ProviderDiscoveryReview? Review { get; init; }

    [JsonPropertyName("approval_proposal")]
    public ProviderDiscoveryApprovalProposal? ApprovalProposal { get; init; }

    [JsonPropertyName("review_proposal")]
    public ProviderDiscoveryReviewProposal? ReviewProposal { get; init; }

    [JsonPropertyName("assistant_resume_boundary")]
    public ProviderDiscoveryAssistantResumeBoundary? AssistantResumeBoundary
    {
        get;
        init;
    }

    [JsonPropertyName("created_at")]
    public DateTimeOffset CreatedAt { get; init; }

    [JsonPropertyName("updated_at")]
    public DateTimeOffset UpdatedAt { get; init; }
}

public sealed record ProviderDiscoveryAction
{
    [JsonPropertyName("kind")]
    public string Kind { get; init; } = string.Empty;

    [JsonPropertyName("candidate_id")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? CandidateId { get; init; }

    [JsonPropertyName("evidence_ids")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public IReadOnlyList<string>? EvidenceIds { get; init; }

    [JsonPropertyName("approval_id")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? ApprovalId { get; init; }

    [JsonPropertyName("approval_grant_sha256")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? ApprovalGrantSha256 { get; init; }

    [JsonPropertyName("commit_attempt_id")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? CommitAttemptId { get; init; }

    [JsonPropertyName("commit_plan_sha256")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? CommitPlanSha256 { get; init; }

    [JsonPropertyName("graph_sha256")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? GraphSha256 { get; init; }

    [JsonPropertyName("resolution")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public ProviderDiscoveryUnknownResolution? Resolution { get; init; }
}

public sealed record ProviderDiscoveryUnknownResolution
{
    [JsonPropertyName("resolution")]
    public string Resolution { get; init; } = string.Empty;

    [JsonPropertyName("connection_id")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? ConnectionId { get; init; }
}

public sealed record ProviderDiscoveryActionEnvelope
{
    [JsonPropertyName("action_id")]
    public string ActionId { get; init; } = string.Empty;

    [JsonPropertyName("expected_revision")]
    public ulong ExpectedRevision { get; init; }

    [JsonPropertyName("request_sha256")]
    public string RequestSha256 { get; init; } = string.Empty;

    [JsonPropertyName("action")]
    public ProviderDiscoveryAction Action { get; init; } = new();
}

public sealed record ProviderDiscoveryProgress
{
    [JsonPropertyName("phase")]
    public string Phase { get; init; } = string.Empty;

    [JsonPropertyName("completed")]
    public uint Completed { get; init; }

    [JsonPropertyName("total")]
    public uint? Total { get; init; }
}

public sealed record ProviderDiscoveryEvent
{
    [JsonPropertyName("event_version")]
    public uint EventVersion { get; init; }

    [JsonPropertyName("event_id")]
    public string EventId { get; init; } = string.Empty;

    [JsonPropertyName("session_id")]
    public string SessionId { get; init; } = string.Empty;

    [JsonPropertyName("sequence")]
    public ulong Sequence { get; init; }

    [JsonPropertyName("session_revision")]
    public ulong SessionRevision { get; init; }

    [JsonPropertyName("state")]
    public string State { get; init; } = string.Empty;

    [JsonPropertyName("progress")]
    public ProviderDiscoveryProgress? Progress { get; init; }

    [JsonPropertyName("action_required")]
    public ProviderDiscoveryActionRequired? ActionRequired { get; init; }

    [JsonPropertyName("warning")]
    public string? Warning { get; init; }

    [JsonPropertyName("action_id")]
    public string ActionId { get; init; } = string.Empty;

    [JsonPropertyName("failure")]
    public ProviderDiscoveryFailure? Failure { get; init; }
}

public sealed record ProviderDiscoveryOutboxEvent
{
    [JsonPropertyName("event")]
    public ProviderDiscoveryEvent Event { get; init; } = new();

    [JsonPropertyName("delivery_attempts")]
    public uint DeliveryAttempts { get; init; }

    [JsonPropertyName("available_at")]
    public DateTimeOffset AvailableAt { get; init; }

    [JsonPropertyName("created_at")]
    public DateTimeOffset CreatedAt { get; init; }
}

public sealed record ProviderDiscoveryRecoveryResult
{
    [JsonPropertyName("operation_id")]
    public string OperationId { get; init; } = string.Empty;

    [JsonPropertyName("session_id")]
    public string SessionId { get; init; } = string.Empty;

    [JsonPropertyName("state")]
    public string State { get; init; } = string.Empty;

    [JsonPropertyName("event")]
    public ProviderDiscoveryEvent Event { get; init; } = new();
}

public sealed record ProviderDiscoveryPreviousSelection
{
    [JsonPropertyName("kind")]
    public string Kind { get; init; } = string.Empty;

    [JsonPropertyName("model_route_id")]
    public string? ModelRouteId { get; init; }

    [JsonPropertyName("generation_preset_id")]
    public string? GenerationPresetId { get; init; }
}

public sealed record ProviderDiscoveryCompensationTarget
{
    [JsonPropertyName("kind")]
    public string Kind { get; init; } = string.Empty;

    [JsonPropertyName("connection_id")]
    public string? ConnectionId { get; init; }

    [JsonPropertyName("credential_ref")]
    public string? CredentialRef { get; init; }

    [JsonPropertyName("previous_selection")]
    public ProviderDiscoveryPreviousSelection? PreviousSelection
    {
        get;
        init;
    }
}

public sealed record ProviderDiscoveryCompensationStep
{
    [JsonPropertyName("id")]
    public string Id { get; init; } = string.Empty;

    [JsonPropertyName("commit_attempt_id")]
    public string CommitAttemptId { get; init; } = string.Empty;

    [JsonPropertyName("ordinal")]
    public uint Ordinal { get; init; }

    [JsonPropertyName("action_id")]
    public string ActionId { get; init; } = string.Empty;

    [JsonPropertyName("kind")]
    public string Kind { get; init; } = string.Empty;

    [JsonPropertyName("target")]
    public ProviderDiscoveryCompensationTarget Target { get; init; } = new();

    [JsonPropertyName("status")]
    public string Status { get; init; } = string.Empty;

    [JsonPropertyName("attempt_count")]
    public uint AttemptCount { get; init; }

    [JsonPropertyName("last_failure")]
    public ProviderDiscoveryFailure? LastFailure { get; init; }

    [JsonPropertyName("created_at")]
    public DateTimeOffset CreatedAt { get; init; }

    [JsonPropertyName("updated_at")]
    public DateTimeOffset UpdatedAt { get; init; }

    [JsonPropertyName("completed_at")]
    public DateTimeOffset? CompletedAt { get; init; }
}

public sealed record ProviderDiscoveryAssistantCallEstimate
{
    [JsonPropertyName("input_tokens")]
    public ulong InputTokens { get; init; }

    [JsonPropertyName("maximum_output_tokens")]
    public ulong MaximumOutputTokens { get; init; }

    [JsonPropertyName("maximum_cost_micro_units")]
    public ulong MaximumCostMicroUnits { get; init; }
}

public sealed record ProviderDiscoveryAssistantDraftField
{
    [JsonPropertyName("kind")]
    public string Kind { get; init; } = string.Empty;

    [JsonPropertyName("parameter_id")]
    public string? ParameterId { get; init; }
}

public sealed record ProviderDiscoveryAssistantQuestion
{
    [JsonPropertyName("id")]
    public string Id { get; init; } = string.Empty;

    [JsonPropertyName("field")]
    public ProviderDiscoveryAssistantDraftField? Field { get; init; }

    [JsonPropertyName("question")]
    public string Question { get; init; } = string.Empty;

    [JsonPropertyName("required_evidence")]
    public string RequiredEvidence { get; init; } = string.Empty;
}

public sealed record ProviderDiscoveryAssistantEvidenceMapping
{
    [JsonPropertyName("field")]
    public ProviderDiscoveryAssistantDraftField Field { get; init; } = new();

    [JsonPropertyName("evidence_ids")]
    public IReadOnlyList<string> EvidenceIds { get; init; } = [];

    [JsonPropertyName("explanation")]
    public string Explanation { get; init; } = string.Empty;
}

public sealed record ProviderDiscoveryAssistantFieldConfidence
{
    [JsonPropertyName("field")]
    public ProviderDiscoveryAssistantDraftField Field { get; init; } = new();

    [JsonPropertyName("level")]
    public string Level { get; init; } = string.Empty;

    [JsonPropertyName("rationale")]
    public string Rationale { get; init; } = string.Empty;
}

public sealed record ProviderDiscoveryAssistantConflictDisposition
{
    [JsonPropertyName("status")]
    public string Status { get; init; } = string.Empty;

    [JsonPropertyName("selected_evidence_id")]
    public string? SelectedEvidenceId { get; init; }

    [JsonPropertyName("rationale")]
    public string? Rationale { get; init; }
}

public sealed record ProviderDiscoveryAssistantEvidenceConflict
{
    [JsonPropertyName("field")]
    public ProviderDiscoveryAssistantDraftField Field { get; init; } = new();

    [JsonPropertyName("evidence_ids")]
    public IReadOnlyList<string> EvidenceIds { get; init; } = [];

    [JsonPropertyName("disposition")]
    public ProviderDiscoveryAssistantConflictDisposition Disposition
    {
        get;
        init;
    } = new();
}

public sealed record ProviderDiscoveryAssistantManifestSource
{
    [JsonPropertyName("kind")]
    public string Kind { get; init; } = string.Empty;

    [JsonPropertyName("url")]
    public string Url { get; init; } = string.Empty;

    [JsonPropertyName("content_sha256")]
    public string? ContentSha256 { get; init; }
}

public sealed record ProviderDiscoveryAssistantEndpoint
{
    [JsonPropertyName("method")]
    public string Method { get; init; } = string.Empty;

    [JsonPropertyName("path")]
    public string Path { get; init; } = string.Empty;
}

public sealed record ProviderDiscoveryAssistantEndpoints
{
    [JsonPropertyName("models")]
    public ProviderDiscoveryAssistantEndpoint? Models { get; init; }

    [JsonPropertyName("generate")]
    public ProviderDiscoveryAssistantEndpoint Generate { get; init; } = new();
}

public sealed record ProviderDiscoveryAssistantDecoders
{
    [JsonPropertyName("response")]
    public string Response { get; init; } = string.Empty;

    [JsonPropertyName("streaming")]
    public string? Streaming { get; init; }
}

public sealed record ProviderDiscoveryAssistantManifest
{
    [JsonPropertyName("schema_version")]
    public uint SchemaVersion { get; init; }

    [JsonPropertyName("api_family")]
    public ProviderApiFamily ApiFamily { get; init; }

    [JsonPropertyName("sources")]
    public IReadOnlyList<ProviderDiscoveryAssistantManifestSource> Sources
    {
        get;
        init;
    } = [];

    [JsonPropertyName("default_api_origin")]
    public string? DefaultApiOrigin { get; init; }

    [JsonPropertyName("auth")]
    public ProviderAuthBinding Auth { get; init; } = new();

    [JsonPropertyName("endpoints")]
    public ProviderDiscoveryAssistantEndpoints Endpoints { get; init; } = new();

    [JsonPropertyName("decoders")]
    public ProviderDiscoveryAssistantDecoders Decoders { get; init; } = new();

    [JsonPropertyName("parameters")]
    public IReadOnlyList<ProviderParameterSpec> Parameters { get; init; } = [];
}

public sealed record ProviderDiscoveryAssistantManifestDraft
{
    [JsonPropertyName("manifest")]
    public ProviderDiscoveryAssistantManifest Manifest { get; init; } = new();

    [JsonPropertyName("evidence_mappings")]
    public IReadOnlyList<ProviderDiscoveryAssistantEvidenceMapping>
        EvidenceMappings
    { get; init; } = [];

    [JsonPropertyName("conflicts")]
    public IReadOnlyList<ProviderDiscoveryAssistantEvidenceConflict> Conflicts
    {
        get;
        init;
    } = [];

    [JsonPropertyName("unresolved_questions")]
    public IReadOnlyList<ProviderDiscoveryAssistantQuestion>
        UnresolvedQuestions
    { get; init; } = [];

    [JsonPropertyName("confidence")]
    public IReadOnlyList<ProviderDiscoveryAssistantFieldConfidence> Confidence
    {
        get;
        init;
    } = [];

    [JsonPropertyName("summary")]
    public string Summary { get; init; } = string.Empty;
}

public sealed record ProviderDiscoveryAssistantDraftRequirements
{
    [JsonPropertyName("required_checks")]
    public IReadOnlyList<string> RequiredChecks { get; init; } = [];

    [JsonPropertyName("persistence")]
    public string Persistence { get; init; } = string.Empty;
}

public sealed record ProviderDiscoveryAssistantDraftReview
{
    [JsonPropertyName("draft")]
    public ProviderDiscoveryAssistantManifestDraft Draft { get; init; } = new();

    [JsonPropertyName("unresolved_conflicts")]
    public IReadOnlyList<ProviderDiscoveryAssistantDraftField>
        UnresolvedConflicts
    { get; init; } = [];

    [JsonPropertyName("requirements")]
    public ProviderDiscoveryAssistantDraftRequirements Requirements
    {
        get;
        init;
    } = new();
}

public sealed record ProviderDiscoveryAssistantResumeBoundary
{
    [JsonPropertyName("checkpoint")]
    public ProviderDiscoveryAssistantCheckpoint? Checkpoint { get; init; }

    [JsonRequired]
    [JsonPropertyName("action")]
    public ProviderDiscoveryAssistantResumeAction Action { get; init; }

    [JsonPropertyName("questions")]
    public IReadOnlyList<ProviderDiscoveryAssistantQuestion> Questions
    {
        get;
        init;
    } = [];

    [JsonPropertyName("draft_review")]
    public ProviderDiscoveryAssistantDraftReview? DraftReview { get; init; }
}

public sealed record ProviderDiscoveryAssistantHostAction
{
    [JsonPropertyName("kind")]
    public string Kind { get; init; } = string.Empty;

    [JsonPropertyName("session_id")]
    public string? SessionId { get; init; }

    [JsonPropertyName("questions")]
    public IReadOnlyList<ProviderDiscoveryAssistantQuestion>? Questions
    {
        get;
        init;
    }

    [JsonPropertyName("draft_review")]
    public ProviderDiscoveryAssistantDraftReview? DraftReview { get; init; }
}
