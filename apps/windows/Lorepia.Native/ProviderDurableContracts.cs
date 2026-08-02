using System.Text.Json.Serialization;

namespace Lorepia.Native;

public static class ModelSyncStates
{
    public const string Created = "created";
    public const string Fetching = "fetching";
    public const string Interrupted = "interrupted";
    public const string DiffReadyAwaitingReview =
        "diff-ready-awaiting-review";
    public const string Committing = "committing";
    public const string Completed = "completed";
    public const string Failed = "failed";
    public const string Cancelled = "cancelled";
}

public sealed record ModelSyncStarted
{
    [JsonPropertyName("job_id")]
    public string JobId { get; init; } = string.Empty;
}

public sealed record ProviderConnectionConfigSnapshot
{
    [JsonPropertyName("api_base_path")]
    public string? ApiBasePath { get; init; }

    [JsonPropertyName("network_mode")]
    public ProviderNetworkMode NetworkMode { get; init; }

    [JsonPropertyName("local_network_approval")]
    public ProviderLocalNetworkApproval? LocalNetworkApproval { get; init; }

    [JsonPropertyName("values")]
    public IReadOnlyList<ConnectionConfigEntry> Values { get; init; } = [];
}

public sealed record ProviderCredentialScopeSnapshot
{
    [JsonPropertyName("allowed_origins")]
    public IReadOnlyList<string> AllowedOrigins { get; init; } = [];

    [JsonPropertyName("auth_binding")]
    public ProviderAuthBinding AuthBinding { get; init; } = new();

    [JsonPropertyName("redirect_policy")]
    public string RedirectPolicy { get; init; } = "deny";
}

public sealed record ProviderConnectionSnapshot
{
    [JsonPropertyName("id")]
    public string Id { get; init; } = string.Empty;

    [JsonPropertyName("template_id")]
    public string TemplateId { get; init; } = string.Empty;

    [JsonPropertyName("template_version")]
    public uint TemplateVersion { get; init; }

    [JsonPropertyName("display_name")]
    public string DisplayName { get; init; } = string.Empty;

    [JsonPropertyName("api_origin")]
    public string ApiOrigin { get; init; } = string.Empty;

    [JsonPropertyName("config")]
    public ProviderConnectionConfigSnapshot Config { get; init; } = new();

    [JsonPropertyName("credential_ref")]
    public string? CredentialRef { get; init; }

    [JsonPropertyName("credential_scope")]
    public ProviderCredentialScopeSnapshot? CredentialScope { get; init; }

    [JsonPropertyName("timeout_seconds")]
    public uint TimeoutSeconds { get; init; }

    [JsonPropertyName("status")]
    public ProviderConnectionStatus Status { get; init; }

    [JsonPropertyName("created_at")]
    public DateTimeOffset CreatedAt { get; init; }

    [JsonPropertyName("updated_at")]
    public DateTimeOffset UpdatedAt { get; init; }
}

public sealed record ModelSyncRouteSnapshot
{
    [JsonPropertyName("id")]
    public string Id { get; init; } = string.Empty;

    [JsonPropertyName("connection_id")]
    public string ConnectionId { get; init; } = string.Empty;

    [JsonPropertyName("api_family")]
    public ProviderApiFamily ApiFamily { get; init; }

    [JsonPropertyName("model_id")]
    public string ModelId { get; init; } = string.Empty;

    [JsonPropertyName("display_name")]
    public string? DisplayName { get; init; }

    [JsonPropertyName("route_config")]
    public ModelRouteConfig RouteConfig { get; init; } = new();

    [JsonPropertyName("status")]
    public ModelAvailability Status { get; init; }

    [JsonPropertyName("miss_count")]
    public uint MissCount { get; init; }

    [JsonPropertyName("raw_metadata")]
    public string? RawMetadata { get; init; }

    [JsonPropertyName("metadata_source")]
    public ModelMetadataSource MetadataSource { get; init; }

    [JsonPropertyName("metadata_observed_at")]
    public DateTimeOffset? MetadataObservedAt { get; init; }

    [JsonPropertyName("last_reconciled_sync_job_id")]
    public string? LastReconciledSyncJobId { get; init; }

    [JsonPropertyName("metadata_sync_job_id")]
    public string? MetadataSyncJobId { get; init; }

    [JsonPropertyName("first_seen_at")]
    public DateTimeOffset FirstSeenAt { get; init; }

    [JsonPropertyName("last_seen_at")]
    public DateTimeOffset? LastSeenAt { get; init; }
}

public sealed record ModelSyncSourceProvenance
{
    [JsonPropertyName("source")]
    public string Source { get; init; } = string.Empty;

    [JsonPropertyName("api_family")]
    public ProviderApiFamily ApiFamily { get; init; }

    [JsonPropertyName("api_origin")]
    public string ApiOrigin { get; init; } = string.Empty;

    [JsonPropertyName("endpoint_path")]
    public string EndpointPath { get; init; } = string.Empty;

    [JsonPropertyName("pages_fetched")]
    public uint PagesFetched { get; init; }

    [JsonPropertyName("response_bytes")]
    public ulong ResponseBytes { get; init; }
}

public sealed record ModelSyncDiff
{
    [JsonPropertyName("connection_id")]
    public string ConnectionId { get; init; } = string.Empty;

    [JsonPropertyName("expected_connection")]
    public ProviderConnectionSnapshot ExpectedConnection { get; init; } = new();

    [JsonPropertyName("expected_model_routes")]
    public IReadOnlyList<ModelSyncRouteSnapshot> ExpectedModelRoutes { get; init; } = [];

    [JsonPropertyName("observed_at")]
    public DateTimeOffset ObservedAt { get; init; }

    [JsonPropertyName("listed_routes")]
    public IReadOnlyList<ModelSyncRouteSnapshot> ListedRoutes { get; init; } = [];

    [JsonPropertyName("newly_seen_model_route_ids")]
    public IReadOnlyList<string> NewlySeenModelRouteIds { get; init; } = [];

    [JsonPropertyName("missing_model_route_ids")]
    public IReadOnlyList<string> MissingModelRouteIds { get; init; } = [];

    [JsonPropertyName("initial_presets")]
    public IReadOnlyList<GenerationPreset> InitialPresets { get; init; } = [];

    [JsonPropertyName("capability_observations")]
    public IReadOnlyList<CapabilityObservation> CapabilityObservations { get; init; } = [];

    [JsonPropertyName("routes_requiring_preset_configuration")]
    public IReadOnlyList<string> RoutesRequiringPresetConfiguration { get; init; } = [];

    [JsonPropertyName("provenance")]
    public ModelSyncSourceProvenance Provenance { get; init; } = new();
}

public sealed record ModelSyncReview
{
    [JsonPropertyName("sha256")]
    public string Sha256 { get; init; } = string.Empty;

    [JsonPropertyName("diff")]
    public ModelSyncDiff Diff { get; init; } = new();
}

public sealed record ModelSyncFailure
{
    [JsonPropertyName("code")]
    public string Code { get; init; } = string.Empty;

    [JsonPropertyName("message_key")]
    public string MessageKey { get; init; } = string.Empty;

    [JsonPropertyName("recoverable")]
    public bool Recoverable { get; init; }
}

public sealed record ModelSyncProgress
{
    [JsonPropertyName("completed_steps")]
    public uint CompletedSteps { get; init; }

    [JsonPropertyName("total_steps")]
    public uint TotalSteps { get; init; }

    [JsonPropertyName("message_key")]
    public string MessageKey { get; init; } = string.Empty;
}

public sealed record ModelSyncEvent
{
    [JsonPropertyName("version")]
    public uint Version { get; init; }

    [JsonPropertyName("job_id")]
    public string JobId { get; init; } = string.Empty;

    [JsonPropertyName("sequence")]
    public ulong Sequence { get; init; }

    [JsonPropertyName("job_revision")]
    public ulong JobRevision { get; init; }

    [JsonPropertyName("redaction_version")]
    public uint RedactionVersion { get; init; }

    [JsonPropertyName("state")]
    public string State { get; init; } = string.Empty;

    [JsonPropertyName("progress")]
    public ModelSyncProgress Progress { get; init; } = new();

    [JsonPropertyName("review_sha256")]
    public string? ReviewSha256 { get; init; }

    [JsonPropertyName("failure")]
    public ModelSyncFailure? Failure { get; init; }

    [JsonPropertyName("emitted_at")]
    public DateTimeOffset EmittedAt { get; init; }
}

public sealed record ModelSyncJob
{
    [JsonPropertyName("id")]
    public string Id { get; init; } = string.Empty;

    [JsonPropertyName("connection_id")]
    public string ConnectionId { get; init; } = string.Empty;

    [JsonPropertyName("state")]
    public string State { get; init; } = string.Empty;

    [JsonPropertyName("revision")]
    public ulong Revision { get; init; }

    [JsonPropertyName("review")]
    public ModelSyncReview? Review { get; init; }

    [JsonPropertyName("failure")]
    public ModelSyncFailure? Failure { get; init; }

    [JsonPropertyName("created_at")]
    public DateTimeOffset CreatedAt { get; init; }

    [JsonPropertyName("updated_at")]
    public DateTimeOffset UpdatedAt { get; init; }
}

[JsonConverter(typeof(SnakeCaseEnumConverter<CatalogChangeKind>))]
public enum CatalogChangeKind
{
    Added,
    Updated,
    Removed,
}

[JsonConverter(typeof(SnakeCaseEnumConverter<ManifestChangedSection>))]
public enum ManifestChangedSection
{
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

[JsonConverter(typeof(SnakeCaseEnumConverter<ModelChangedSection>))]
public enum ModelChangedSection
{
    Match,
    ApiFamily,
    MetadataVersion,
    Capabilities,
    Parameters,
    Lifecycle,
    Sources,
    Freshness,
}

public sealed record CatalogManifestDiff
{
    [JsonPropertyName("provider_template_id")]
    public string ProviderTemplateId { get; init; } = string.Empty;

    [JsonPropertyName("previous_manifest_version")]
    public uint? PreviousManifestVersion { get; init; }

    [JsonPropertyName("next_manifest_version")]
    public uint? NextManifestVersion { get; init; }

    [JsonPropertyName("previous_sha256")]
    public string? PreviousSha256 { get; init; }

    [JsonPropertyName("next_sha256")]
    public string? NextSha256 { get; init; }

    [JsonPropertyName("changed_sections")]
    public IReadOnlyList<ManifestChangedSection> ChangedSections { get; init; } = [];
}

public sealed record CatalogModelMetadataDiff
{
    [JsonPropertyName("model_entry_id")]
    public string ModelEntryId { get; init; } = string.Empty;

    [JsonPropertyName("provider_template_id")]
    public string ProviderTemplateId { get; init; } = string.Empty;

    [JsonPropertyName("previous_metadata_version")]
    public uint? PreviousMetadataVersion { get; init; }

    [JsonPropertyName("next_metadata_version")]
    public uint? NextMetadataVersion { get; init; }

    [JsonPropertyName("previous_sha256")]
    public string? PreviousSha256 { get; init; }

    [JsonPropertyName("next_sha256")]
    public string? NextSha256 { get; init; }

    [JsonPropertyName("changed_sections")]
    public IReadOnlyList<ModelChangedSection> ChangedSections { get; init; } = [];
}

public sealed record ProviderCatalogDiff
{
    [JsonPropertyName("diff_schema_version")]
    public uint DiffSchemaVersion { get; init; }

    [JsonPropertyName("from_revision")]
    public ulong FromRevision { get; init; }

    [JsonPropertyName("to_revision")]
    public ulong ToRevision { get; init; }

    [JsonPropertyName("added_provider_templates")]
    public IReadOnlyList<CatalogManifestDiff> AddedProviderTemplates
    {
        get;
        init;
    } = [];

    [JsonPropertyName("changed_provider_templates")]
    public IReadOnlyList<CatalogManifestDiff> ChangedProviderTemplates
    {
        get;
        init;
    } = [];

    [JsonPropertyName("removed_provider_templates")]
    public IReadOnlyList<CatalogManifestDiff> RemovedProviderTemplates
    {
        get;
        init;
    } = [];

    [JsonPropertyName("added_models")]
    public IReadOnlyList<CatalogModelMetadataDiff> AddedModels
    {
        get;
        init;
    } = [];

    [JsonPropertyName("changed_models")]
    public IReadOnlyList<CatalogModelMetadataDiff> ChangedModels
    {
        get;
        init;
    } = [];

    [JsonPropertyName("removed_models")]
    public IReadOnlyList<CatalogModelMetadataDiff> RemovedModels
    {
        get;
        init;
    } = [];
}

public sealed record ProviderCatalogStatus
{
    [JsonPropertyName("status_schema_version")]
    public uint StatusSchemaVersion { get; init; }

    [JsonPropertyName("state_version")]
    public ulong StateVersion { get; init; }

    [JsonPropertyName("active_revision")]
    public ulong ActiveRevision { get; init; }

    [JsonPropertyName("active_snapshot_sha256")]
    public string ActiveSnapshotSha256 { get; init; } = string.Empty;

    [JsonPropertyName("bundled_baseline_sha256")]
    public string BundledBaselineSha256 { get; init; } = string.Empty;

    [JsonPropertyName("snapshot_count")]
    public uint SnapshotCount { get; init; }

    [JsonPropertyName("signed_update_count")]
    public uint SignedUpdateCount { get; init; }

    [JsonPropertyName("highest_accepted_revision")]
    public ulong HighestAcceptedRevision { get; init; }

    [JsonPropertyName("latest_issued_at")]
    public DateTimeOffset? LatestIssuedAt { get; init; }

    [JsonPropertyName("active_signed_revisions")]
    public IReadOnlyList<ulong> ActiveSignedRevisions { get; init; } = [];
}

public sealed record ProviderCatalogRevisionSummary
{
    [JsonPropertyName("revision")]
    public ulong Revision { get; init; }

    [JsonPropertyName("captured_at")]
    public DateTimeOffset CapturedAt { get; init; }

    [JsonPropertyName("snapshot_sha256")]
    public string SnapshotSha256 { get; init; } = string.Empty;

    [JsonPropertyName("signed_revisions")]
    public IReadOnlyList<ulong> SignedRevisions { get; init; } = [];

    [JsonPropertyName("active")]
    public bool Active { get; init; }
}

[JsonConverter(typeof(SnakeCaseEnumConverter<ProviderCatalogActivationKind>))]
public enum ProviderCatalogActivationKind
{
    Import,
    Rollback,
}

public sealed record ProviderCatalogActivationSummary
{
    [JsonPropertyName("action_id")]
    public string ActionId { get; init; } = string.Empty;

    [JsonPropertyName("state_version")]
    public ulong StateVersion { get; init; }

    [JsonPropertyName("kind")]
    public ProviderCatalogActivationKind Kind { get; init; }

    [JsonPropertyName("from_revision")]
    public ulong? FromRevision { get; init; }

    [JsonPropertyName("to_revision")]
    public ulong ToRevision { get; init; }

    [JsonPropertyName("activated_at")]
    public DateTimeOffset ActivatedAt { get; init; }

    [JsonPropertyName("diff")]
    public ProviderCatalogDiff Diff { get; init; } = new();
}

public sealed record ProviderCatalogHistory
{
    [JsonPropertyName("history_schema_version")]
    public uint HistorySchemaVersion { get; init; }

    [JsonPropertyName("active_revision")]
    public ulong ActiveRevision { get; init; }

    [JsonPropertyName("revisions")]
    public IReadOnlyList<ProviderCatalogRevisionSummary> Revisions { get; init; } = [];

    [JsonPropertyName("activations")]
    public IReadOnlyList<ProviderCatalogActivationSummary> Activations { get; init; } = [];

    [JsonPropertyName("next_before_revision")]
    public ulong? NextBeforeRevision { get; init; }

    [JsonPropertyName("next_before_state_version")]
    public ulong? NextBeforeStateVersion { get; init; }
}

public sealed record ProviderCatalogImportResult
{
    [JsonPropertyName("signed_catalog_revision")]
    public ulong SignedCatalogRevision { get; init; }

    [JsonPropertyName("activated_revision")]
    public ulong ActivatedRevision { get; init; }

    [JsonPropertyName("diff")]
    public ProviderCatalogDiff Diff { get; init; } = new();

    [JsonPropertyName("status")]
    public ProviderCatalogStatus Status { get; init; } = new();
}

public sealed record ProviderCatalogImportReview
{
    [JsonPropertyName("plan_schema_version")]
    public uint PlanSchemaVersion { get; init; }

    [JsonPropertyName("action_id")]
    public string ActionId { get; init; } = string.Empty;

    [JsonPropertyName("expected_state_version")]
    public ulong ExpectedStateVersion { get; init; }

    [JsonPropertyName("expected_active_revision")]
    public ulong ExpectedActiveRevision { get; init; }

    [JsonPropertyName("expected_active_snapshot_sha256")]
    public string ExpectedActiveSnapshotSha256 { get; init; } = string.Empty;

    [JsonPropertyName("expected_highest_accepted_revision")]
    public ulong ExpectedHighestAcceptedRevision { get; init; }

    [JsonPropertyName("envelope_byte_count")]
    public ulong EnvelopeByteCount { get; init; }

    [JsonPropertyName("envelope_sha256")]
    public string EnvelopeSha256 { get; init; } = string.Empty;

    [JsonPropertyName("signing_key_id")]
    public string SigningKeyId { get; init; } = string.Empty;

    [JsonPropertyName("payload_sha256")]
    public string PayloadSha256 { get; init; } = string.Empty;

    [JsonPropertyName("signed_catalog_revision")]
    public ulong SignedCatalogRevision { get; init; }

    [JsonPropertyName("candidate_revision")]
    public ulong CandidateRevision { get; init; }

    [JsonPropertyName("candidate_snapshot_sha256")]
    public string CandidateSnapshotSha256 { get; init; } = string.Empty;

    [JsonPropertyName("prepared_at")]
    public DateTimeOffset PreparedAt { get; init; }

    [JsonPropertyName("expires_at")]
    public DateTimeOffset ExpiresAt { get; init; }

    [JsonPropertyName("diff")]
    public ProviderCatalogDiff Diff { get; init; } = new();
}

public sealed record ProviderCatalogImportPlan
{
    [JsonPropertyName("review")]
    public ProviderCatalogImportReview Review { get; init; } = new();

    [JsonPropertyName("plan_sha256")]
    public string PlanSha256 { get; init; } = string.Empty;

    [JsonPropertyName("plan_json")]
    public string PlanJson { get; init; } = string.Empty;
}

public sealed record ProviderCatalogRollbackPlan
{
    [JsonPropertyName("plan_schema_version")]
    public uint PlanSchemaVersion { get; init; }

    [JsonPropertyName("action_id")]
    public string ActionId { get; init; } = string.Empty;

    [JsonPropertyName("expected_state_version")]
    public ulong ExpectedStateVersion { get; init; }

    [JsonPropertyName("plan_sha256")]
    public string PlanSha256 { get; init; } = string.Empty;

    [JsonPropertyName("from_revision")]
    public ulong FromRevision { get; init; }

    [JsonPropertyName("to_revision")]
    public ulong ToRevision { get; init; }

    [JsonPropertyName("created_at")]
    public DateTimeOffset CreatedAt { get; init; }

    [JsonPropertyName("expires_at")]
    public DateTimeOffset ExpiresAt { get; init; }

    [JsonPropertyName("diff")]
    public ProviderCatalogDiff Diff { get; init; } = new();

    [JsonPropertyName("plan_json")]
    public string PlanJson { get; init; } = string.Empty;
}

public sealed record ProviderCatalogRollbackResult
{
    [JsonPropertyName("from_revision")]
    public ulong FromRevision { get; init; }

    [JsonPropertyName("activated_revision")]
    public ulong ActivatedRevision { get; init; }

    [JsonPropertyName("status")]
    public ProviderCatalogStatus Status { get; init; } = new();
}
