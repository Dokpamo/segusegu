using System.Text.Json;
using System.Text.Json.Serialization;

namespace Lorepia.Native;

public sealed class SnakeCaseEnumConverter<TEnum> : JsonStringEnumConverter<TEnum>
    where TEnum : struct, Enum
{
    public SnakeCaseEnumConverter()
        : base(JsonNamingPolicy.SnakeCaseLower, allowIntegerValues: false)
    {
    }
}

[JsonConverter(typeof(SnakeCaseEnumConverter<ProviderApiFamily>))]
public enum ProviderApiFamily
{
    OpenaiResponses,
    OpenaiChatCompletions,
    AnthropicMessages,
    GeminiGenerateContent,
    OllamaNative,
}

[JsonConverter(typeof(SnakeCaseEnumConverter<ProviderTemplateSource>))]
public enum ProviderTemplateSource
{
    BuiltIn,
    SignedCatalog,
    UserDiscovered,
}

[JsonConverter(typeof(SnakeCaseEnumConverter<ProviderNetworkMode>))]
public enum ProviderNetworkMode
{
    Public,
    LocalLoopback,
    ApprovedLocalNetwork,
}

[JsonConverter(typeof(SnakeCaseEnumConverter<ProviderConnectionStatus>))]
public enum ProviderConnectionStatus
{
    Untested,
    Connected,
    AuthFailed,
    Unavailable,
}

[JsonConverter(typeof(SnakeCaseEnumConverter<ModelAvailability>))]
public enum ModelAvailability
{
    Available,
    MissingTemporarily,
    DocumentedOnly,
    AccessDenied,
    Deprecated,
    Retired,
    Unknown,
}

[JsonConverter(typeof(SnakeCaseEnumConverter<ModelMetadataSource>))]
public enum ModelMetadataSource
{
    Legacy,
    ProviderApi,
    OfficialDocumentation,
    SignedCatalog,
    CapabilityProbe,
    UserOverride,
}

[JsonConverter(typeof(SnakeCaseEnumConverter<ConnectionFieldType>))]
public enum ConnectionFieldType
{
    Text,
    Integer,
    Boolean,
    Credential,
}

public sealed record ProviderAuthBinding
{
    [JsonPropertyName("kind")]
    public string Kind { get; init; } = "none";

    [JsonPropertyName("header_name")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? HeaderName { get; init; }
}

public sealed record ConnectionFieldSpec
{
    [JsonPropertyName("key")]
    public string Key { get; init; } = string.Empty;

    [JsonPropertyName("label_key")]
    public string LabelKey { get; init; } = string.Empty;

    [JsonPropertyName("description_key")]
    public string? DescriptionKey { get; init; }

    [JsonPropertyName("value_type")]
    public ConnectionFieldType ValueType { get; init; }

    [JsonPropertyName("required")]
    public bool Required { get; init; }
}

public sealed record ConnectionConfigValue
{
    [JsonPropertyName("type")]
    public string Type { get; init; } = string.Empty;

    [JsonPropertyName("value")]
    public JsonElement Value { get; init; }

    public static ConnectionConfigValue Text(string value) => new()
    {
        Type = "text",
        Value = JsonSerializer.SerializeToElement(value),
    };

    public static ConnectionConfigValue Integer(long value) => new()
    {
        Type = "integer",
        Value = JsonSerializer.SerializeToElement(value),
    };

    public static ConnectionConfigValue Boolean(bool value) => new()
    {
        Type = "boolean",
        Value = JsonSerializer.SerializeToElement(value),
    };
}

public sealed record ProviderLocalNetworkApproval
{
    [JsonPropertyName("origin")]
    public string Origin { get; init; } = string.Empty;

    [JsonPropertyName("addresses")]
    public IReadOnlyList<string> Addresses { get; init; } = [];
}

public sealed record ConnectionConfigEntry
{
    [JsonPropertyName("key")]
    public string Key { get; init; } = string.Empty;

    [JsonPropertyName("value")]
    public ConnectionConfigValue Value { get; init; } = new();
}

public sealed record ProviderParameterLiteral
{
    [JsonPropertyName("type")]
    public string Type { get; init; } = string.Empty;

    [JsonPropertyName("value")]
    public JsonElement Value { get; init; }
}

public sealed record ProviderParameterChoice
{
    [JsonPropertyName("value")]
    public ProviderParameterLiteral Value { get; init; } = new();

    [JsonPropertyName("label_key")]
    public string LabelKey { get; init; } = string.Empty;
}

public sealed record ProviderParameterCondition
{
    [JsonPropertyName("parameter_id")]
    public string ParameterId { get; init; } = string.Empty;

    [JsonPropertyName("operator")]
    public string Operator { get; init; } = string.Empty;

    [JsonPropertyName("value")]
    public ProviderParameterLiteral Value { get; init; } = new();
}

public sealed record ProviderParameterConflict
{
    [JsonPropertyName("parameter_id")]
    public string ParameterId { get; init; } = string.Empty;

    [JsonPropertyName("kind")]
    public string Kind { get; init; } = string.Empty;

    [JsonPropertyName("message_key")]
    public string MessageKey { get; init; } = string.Empty;
}

public sealed record ProviderParameterMapping
{
    [JsonPropertyName("target")]
    public string Target { get; init; } = string.Empty;

    [JsonPropertyName("field_name")]
    public string FieldName { get; init; } = string.Empty;
}

public sealed record ProviderParameterSpec
{
    [JsonPropertyName("id")]
    public string Id { get; init; } = string.Empty;

    [JsonPropertyName("label_key")]
    public string LabelKey { get; init; } = string.Empty;

    [JsonPropertyName("description_key")]
    public string? DescriptionKey { get; init; }

    [JsonPropertyName("value_type")]
    public string ValueType { get; init; } = string.Empty;

    [JsonPropertyName("allowed_values")]
    public IReadOnlyList<ProviderParameterChoice> AllowedValues { get; init; } = [];

    [JsonPropertyName("minimum")]
    public double? Minimum { get; init; }

    [JsonPropertyName("maximum")]
    public double? Maximum { get; init; }

    [JsonPropertyName("step")]
    public double? Step { get; init; }

    [JsonPropertyName("default_mode")]
    public string DefaultMode { get; init; } = string.Empty;

    [JsonPropertyName("visibility")]
    public ProviderParameterCondition? Visibility { get; init; }

    [JsonPropertyName("conflicts")]
    public IReadOnlyList<ProviderParameterConflict> Conflicts { get; init; } = [];

    [JsonPropertyName("provider_mapping")]
    public ProviderParameterMapping ProviderMapping { get; init; } = new();

    [JsonPropertyName("level")]
    public string Level { get; init; } = string.Empty;
}

public sealed record ProviderTemplate
{
    [JsonPropertyName("id")]
    public string Id { get; init; } = string.Empty;

    [JsonPropertyName("display_name")]
    public string DisplayName { get; init; } = string.Empty;

    [JsonPropertyName("manifest_version")]
    public uint ManifestVersion { get; init; }

    [JsonPropertyName("source")]
    public ProviderTemplateSource Source { get; init; }

    [JsonPropertyName("api_family")]
    public ProviderApiFamily ApiFamily { get; init; }

    [JsonPropertyName("default_api_origin")]
    public string? DefaultApiOrigin { get; init; }

    [JsonPropertyName("default_network_mode")]
    public ProviderNetworkMode DefaultNetworkMode { get; init; }

    [JsonPropertyName("requires_credential")]
    public bool RequiresCredential { get; init; }

    [JsonPropertyName("auth_binding")]
    public ProviderAuthBinding AuthBinding { get; init; } = new();

    [JsonPropertyName("supports_model_listing")]
    public bool SupportsModelListing { get; init; }

    [JsonPropertyName("connection_fields")]
    public IReadOnlyList<ConnectionFieldSpec> ConnectionFields { get; init; } = [];

    [JsonPropertyName("parameter_specs")]
    public IReadOnlyList<ProviderParameterSpec> ParameterSpecs { get; init; } = [];
}

public sealed record ProviderConnectionDraft
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

    [JsonPropertyName("api_base_path")]
    public string? ApiBasePath { get; init; }

    [JsonPropertyName("network_mode")]
    public ProviderNetworkMode NetworkMode { get; init; }

    [JsonPropertyName("local_network_approval")]
    public ProviderLocalNetworkApproval? LocalNetworkApproval { get; init; }

    [JsonPropertyName("values")]
    public IReadOnlyList<ConnectionConfigEntry> Values { get; init; } = [];

    [JsonPropertyName("approved_credential_origin")]
    public string? ApprovedCredentialOrigin { get; init; }

    [JsonPropertyName("timeout_seconds")]
    public uint TimeoutSeconds { get; init; } = 30;
}

public sealed record ProviderConnection
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

    [JsonPropertyName("api_base_path")]
    public string? ApiBasePath { get; init; }

    [JsonPropertyName("network_mode")]
    public ProviderNetworkMode NetworkMode { get; init; }

    [JsonPropertyName("local_network_approval")]
    public ProviderLocalNetworkApproval? LocalNetworkApproval { get; init; }

    [JsonPropertyName("values")]
    public IReadOnlyList<ConnectionConfigEntry> Values { get; init; } = [];

    [JsonPropertyName("credential_slot_required")]
    public bool CredentialSlotRequired { get; init; }

    [JsonPropertyName("credential_ref")]
    public string? CredentialRef { get; init; }

    [JsonPropertyName("auth_binding")]
    public ProviderAuthBinding AuthBinding { get; init; } = new();

    [JsonPropertyName("approved_credential_origins")]
    public IReadOnlyList<string> ApprovedCredentialOrigins { get; init; } = [];

    [JsonPropertyName("credential_redirect_policy")]
    public string CredentialRedirectPolicy { get; init; } = "deny";

    [JsonPropertyName("timeout_seconds")]
    public uint TimeoutSeconds { get; init; }

    [JsonPropertyName("status")]
    public ProviderConnectionStatus Status { get; init; }

    [JsonPropertyName("created_at")]
    public DateTimeOffset CreatedAt { get; init; }

    [JsonPropertyName("updated_at")]
    public DateTimeOffset UpdatedAt { get; init; }
}

public sealed record ModelRouteConfig
{
    [JsonPropertyName("deployment_id")]
    public string? DeploymentId { get; init; }

    [JsonPropertyName("region")]
    public string? Region { get; init; }

    [JsonPropertyName("endpoint_path")]
    public string? EndpointPath { get; init; }

    [JsonPropertyName("values")]
    public IReadOnlyList<ConnectionConfigEntry> Values { get; init; } = [];
}

public sealed record ModelRoute
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

    [JsonPropertyName("availability")]
    public ModelAvailability Availability { get; init; }

    [JsonPropertyName("miss_count")]
    public uint MissCount { get; init; }

    [JsonPropertyName("raw_metadata_json")]
    public string? RawMetadataJson { get; init; }

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

public sealed record ProviderParameterValueState
{
    [JsonPropertyName("state")]
    public string State { get; init; } = "inherit_provider_default";

    [JsonPropertyName("value")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public ProviderParameterLiteral? Value { get; init; }
}

public sealed record ProviderParameterValue
{
    [JsonPropertyName("parameter_id")]
    public string ParameterId { get; init; } = string.Empty;

    [JsonPropertyName("state")]
    public ProviderParameterValueState State { get; init; } = new();
}

public sealed record GenerationReasoningSettings
{
    [JsonPropertyName("mode")]
    public string Mode { get; init; } = "provider_default";

    [JsonPropertyName("effort")]
    public string? Effort { get; init; }

    [JsonPropertyName("budget_tokens")]
    public uint? BudgetTokens { get; init; }

    [JsonPropertyName("summary")]
    public string Summary { get; init; } = "provider_default";

    [JsonPropertyName("preserve_opaque_state")]
    public bool PreserveOpaqueState { get; init; }
}

public sealed record GenerationPromptCacheTtl
{
    [JsonPropertyName("kind")]
    public string Kind { get; init; } = "provider_default";

    [JsonPropertyName("seconds")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public uint? Seconds { get; init; }
}

public sealed record GenerationPromptCacheSettings
{
    [JsonPropertyName("mode")]
    public string Mode { get; init; } = "provider_default";

    [JsonPropertyName("ttl")]
    public GenerationPromptCacheTtl Ttl { get; init; } = new();

    [JsonPropertyName("context_reference")]
    public string? ContextReference { get; init; }
}

public sealed record ProviderParameterIssue
{
    [JsonPropertyName("code")]
    public string Code { get; init; } = string.Empty;

    [JsonPropertyName("parameter_id")]
    public string? ParameterId { get; init; }

    [JsonPropertyName("related_parameter_id")]
    public string? RelatedParameterId { get; init; }

    [JsonPropertyName("message")]
    public string Message { get; init; } = string.Empty;
}

public sealed record TokenBudgetBounds
{
    [JsonPropertyName("minimum")]
    public uint Minimum { get; init; }

    [JsonPropertyName("maximum")]
    public uint Maximum { get; init; }
}

public sealed record ReasoningControlModel
{
    [JsonPropertyName("state")]
    public string State { get; init; } = "hidden";

    [JsonPropertyName("settings")]
    public GenerationReasoningSettings Settings { get; init; } = new();

    [JsonPropertyName("allowed_modes")]
    public IReadOnlyList<string> AllowedModes { get; init; } = [];

    [JsonPropertyName("allowed_efforts")]
    public IReadOnlyList<string> AllowedEfforts { get; init; } = [];

    [JsonPropertyName("allowed_summaries")]
    public IReadOnlyList<string> AllowedSummaries { get; init; } = [];

    [JsonPropertyName("budget_bounds")]
    public TokenBudgetBounds? BudgetBounds { get; init; }

    [JsonPropertyName("effort_field")]
    public string EffortField { get; init; } = "hidden";

    [JsonPropertyName("budget_field")]
    public string BudgetField { get; init; } = "hidden";

    [JsonPropertyName("summary_field")]
    public string SummaryField { get; init; } = "hidden";

    [JsonPropertyName("issues")]
    public IReadOnlyList<ProviderParameterIssue> Issues { get; init; } = [];
}

public sealed record CacheTtlBounds
{
    [JsonPropertyName("minimum_seconds")]
    public uint MinimumSeconds { get; init; }

    [JsonPropertyName("maximum_seconds")]
    public uint MaximumSeconds { get; init; }
}

public sealed record PromptCacheControlModel
{
    [JsonPropertyName("state")]
    public string State { get; init; } = "hidden";

    [JsonPropertyName("settings")]
    public GenerationPromptCacheSettings Settings { get; init; } = new();

    [JsonPropertyName("allowed_modes")]
    public IReadOnlyList<string> AllowedModes { get; init; } = [];

    [JsonPropertyName("allowed_ttls")]
    public IReadOnlyList<GenerationPromptCacheTtl> AllowedTtls { get; init; } = [];

    [JsonPropertyName("supports_custom_ttl")]
    public bool SupportsCustomTtl { get; init; }

    [JsonPropertyName("custom_ttl_bounds")]
    public CacheTtlBounds? CustomTtlBounds { get; init; }

    [JsonPropertyName("ttl_field")]
    public string TtlField { get; init; } = "hidden";

    [JsonPropertyName("context_reference_field")]
    public string ContextReferenceField { get; init; } = "hidden";

    [JsonPropertyName("issues")]
    public IReadOnlyList<ProviderParameterIssue> Issues { get; init; } = [];
}

public sealed record GenerationPreset
{
    [JsonPropertyName("id")]
    public string Id { get; init; } = string.Empty;

    [JsonPropertyName("model_route_id")]
    public string ModelRouteId { get; init; } = string.Empty;

    [JsonPropertyName("display_name")]
    public string DisplayName { get; init; } = string.Empty;

    [JsonPropertyName("values")]
    public IReadOnlyList<ProviderParameterValue> Values { get; init; } = [];

    [JsonPropertyName("reasoning")]
    public GenerationReasoningSettings Reasoning { get; init; } = new();

    [JsonPropertyName("prompt_cache")]
    public GenerationPromptCacheSettings PromptCache { get; init; } = new();

    [JsonPropertyName("created_at")]
    public DateTimeOffset CreatedAt { get; init; }

    [JsonPropertyName("updated_at")]
    public DateTimeOffset UpdatedAt { get; init; }
}

public sealed record GenerationTarget
{
    [JsonPropertyName("model_route_id")]
    public string ModelRouteId { get; init; } = string.Empty;

    [JsonPropertyName("generation_preset_id")]
    public string GenerationPresetId { get; init; } = string.Empty;
}

public sealed record ProviderRequestBodyField
{
    [JsonPropertyName("name")]
    public string Name { get; init; } = string.Empty;

    [JsonPropertyName("shape")]
    public ProviderRequestBodyShape Shape { get; init; } = new();
}

public sealed record ProviderRequestBodyShape
{
    [JsonPropertyName("kind")]
    public string Kind { get; init; } = string.Empty;

    [JsonPropertyName("items")]
    public IReadOnlyList<ProviderRequestBodyShape>? Items { get; init; }

    [JsonPropertyName("fields")]
    public IReadOnlyList<ProviderRequestBodyField>? Fields { get; init; }

    [JsonPropertyName("truncated")]
    public bool? Truncated { get; init; }
}

public sealed record ProviderRequestShape
{
    [JsonPropertyName("method")]
    public string Method { get; init; } = string.Empty;

    [JsonPropertyName("origin")]
    public string Origin { get; init; } = string.Empty;

    [JsonPropertyName("path")]
    public string Path { get; init; } = string.Empty;

    [JsonPropertyName("header_names")]
    public IReadOnlyList<string> HeaderNames { get; init; } = [];

    [JsonPropertyName("body")]
    public ProviderRequestBodyShape? Body { get; init; }
}

public sealed record ProviderRequestPreview
{
    [JsonPropertyName("redaction_version")]
    public uint RedactionVersion { get; init; }

    [JsonPropertyName("preview")]
    public ProviderRequestShape Preview { get; init; } = new();

    [JsonPropertyName("includes_private_message")]
    public bool IncludesPrivateMessage { get; init; }

    [JsonPropertyName("includes_credential_value")]
    public bool IncludesCredentialValue { get; init; }

    [JsonPropertyName("includes_opaque_reasoning_state")]
    public bool IncludesOpaqueReasoningState { get; init; }
}

[JsonConverter(typeof(SnakeCaseEnumConverter<CapabilityKey>))]
public enum CapabilityKey
{
    Streaming,
    Reasoning,
    PromptCaching,
    ToolCalling,
    ParallelToolCalling,
    StructuredOutput,
    JsonMode,
    ImageInput,
    AudioInput,
    AudioOutput,
    Logprobs,
    Seed,
    Batch,
    Background,
    ContextWindow,
    MaxOutputTokens,
}

[JsonConverter(typeof(SnakeCaseEnumConverter<CapabilitySupportStatus>))]
public enum CapabilitySupportStatus
{
    Verified,
    Documented,
    Inferred,
    Unsupported,
    Unknown,
    Conditional,
}

[JsonConverter(typeof(SnakeCaseEnumConverter<CapabilityObservationSource>))]
public enum CapabilityObservationSource
{
    ProviderApi,
    OfficialDocumentation,
    SignedLorepiaCatalog,
    CapabilityProbe,
    UserOverride,
    LlmInference,
}

[JsonConverter(typeof(SnakeCaseEnumConverter<CapabilityConfidence>))]
public enum CapabilityConfidence
{
    Low,
    Medium,
    High,
}

public sealed record CapabilityValue
{
    [JsonPropertyName("type")]
    public string Type { get; init; } = string.Empty;

    [JsonPropertyName("value")]
    public JsonElement Value { get; init; }

    public static CapabilityValue Boolean(bool value) => new()
    {
        Type = "boolean",
        Value = JsonSerializer.SerializeToElement(value),
    };

    public static CapabilityValue Integer(ulong value) => new()
    {
        Type = "integer",
        Value = JsonSerializer.SerializeToElement(value),
    };

    public static CapabilityValue EnumValues(IReadOnlyList<string> values) => new()
    {
        Type = "enum_values",
        Value = JsonSerializer.SerializeToElement(values),
    };
}

public sealed record CapabilityObservation
{
    [JsonPropertyName("id")]
    public string Id { get; init; } = string.Empty;

    [JsonPropertyName("model_route_id")]
    public string ModelRouteId { get; init; } = string.Empty;

    [JsonPropertyName("key")]
    public CapabilityKey Key { get; init; }

    [JsonPropertyName("value")]
    public CapabilityValue Value { get; init; } = new();

    [JsonPropertyName("status")]
    public CapabilitySupportStatus Status { get; init; }

    [JsonPropertyName("source")]
    public CapabilityObservationSource Source { get; init; }

    [JsonPropertyName("confidence")]
    public CapabilityConfidence Confidence { get; init; }

    [JsonPropertyName("observed_at")]
    public DateTimeOffset ObservedAt { get; init; }

    [JsonPropertyName("expires_at")]
    public DateTimeOffset? ExpiresAt { get; init; }

    [JsonPropertyName("evidence_ref")]
    public string? EvidenceRef { get; init; }
}

public sealed record EffectiveCapability
{
    [JsonPropertyName("selected")]
    public CapabilityObservation Selected { get; init; } = new();

    [JsonPropertyName("alternatives")]
    public IReadOnlyList<CapabilityObservation> Alternatives { get; init; } = [];

    [JsonPropertyName("evaluated_at")]
    public DateTimeOffset EvaluatedAt { get; init; }

    [JsonPropertyName("selected_is_stale")]
    public bool SelectedIsStale { get; init; }

    [JsonPropertyName("has_conflict")]
    public bool HasConflict { get; init; }
}

public sealed record ProviderModelRefreshProvenance
{
    [JsonPropertyName("source")]
    public string Source { get; init; } = string.Empty;

    [JsonPropertyName("api_family")]
    public ProviderApiFamily ApiFamily { get; init; }

    [JsonPropertyName("api_origin")]
    public string ApiOrigin { get; init; } = string.Empty;

    [JsonPropertyName("endpoint_path")]
    public string EndpointPath { get; init; } = string.Empty;
}

public sealed record ProviderModelRefreshResult
{
    [JsonPropertyName("connection_id")]
    public string ConnectionId { get; init; } = string.Empty;

    [JsonPropertyName("model_routes")]
    public IReadOnlyList<ModelRoute> ModelRoutes { get; init; } = [];

    [JsonPropertyName("newly_seen_model_route_ids")]
    public IReadOnlyList<string> NewlySeenModelRouteIds { get; init; } = [];

    [JsonPropertyName("missing_model_route_ids")]
    public IReadOnlyList<string> MissingModelRouteIds { get; init; } = [];

    [JsonPropertyName("created_generation_preset_ids")]
    public IReadOnlyList<string> CreatedGenerationPresetIds { get; init; } = [];

    [JsonPropertyName("routes_requiring_preset_configuration")]
    public IReadOnlyList<string> RoutesRequiringPresetConfiguration { get; init; } = [];

    [JsonPropertyName("provenance")]
    public ProviderModelRefreshProvenance Provenance { get; init; } = new();

    [JsonPropertyName("pages_fetched")]
    public uint PagesFetched { get; init; }

    [JsonPropertyName("response_bytes")]
    public ulong ResponseBytes { get; init; }

    [JsonPropertyName("observed_at")]
    public DateTimeOffset ObservedAt { get; init; }
}
