using System.Text.Json;
using System.Text.Json.Serialization;

namespace Lorepia.Native;

public sealed record ImportWarning
{
    [JsonPropertyName("code")]
    public string Code { get; init; } = string.Empty;

    [JsonPropertyName("message")]
    public string Message { get; init; } = string.Empty;
}

public sealed record ImportImagePreview
{
    [JsonPropertyName("logical_asset_id")]
    public string LogicalAssetId { get; init; } = string.Empty;

    [JsonPropertyName("media_type")]
    public string MediaType { get; init; } = string.Empty;

    [JsonPropertyName("size_bytes")]
    public ulong SizeBytes { get; init; }
}

public sealed record ImportInspection
{
    [JsonPropertyName("id")]
    public string Id { get; init; } = string.Empty;

    [JsonPropertyName("kind")]
    public string Kind { get; init; } = string.Empty;

    [JsonPropertyName("display_name")]
    public string DisplayName { get; init; } = string.Empty;

    [JsonPropertyName("description")]
    public string Description { get; init; } = string.Empty;

    [JsonPropertyName("representative_image")]
    public ImportImagePreview? RepresentativeImage { get; init; }

    [JsonPropertyName("source_sha256")]
    public string SourceSha256 { get; init; } = string.Empty;

    [JsonPropertyName("source_size")]
    public ulong SourceSize { get; init; }

    [JsonPropertyName("estimated_stored_size")]
    public ulong EstimatedStoredSize { get; init; }

    [JsonPropertyName("asset_count")]
    public uint AssetCount { get; init; }

    [JsonPropertyName("warnings")]
    public IReadOnlyList<ImportWarning> Warnings { get; init; } = [];

    [JsonPropertyName("blocked_reasons")]
    public IReadOnlyList<string> BlockedReasons { get; init; } = [];

    [JsonPropertyName("unsupported_optional_fields")]
    public IReadOnlyList<string> UnsupportedOptionalFields { get; init; } = [];

    [JsonIgnore]
    public bool IsAllowed => BlockedReasons.Count == 0;
}

public sealed record Conversation
{
    [JsonPropertyName("id")]
    public string Id { get; init; } = string.Empty;

    [JsonPropertyName("character_id")]
    public string CharacterId { get; init; } = string.Empty;

    [JsonPropertyName("title")]
    public string Title { get; init; } = string.Empty;

    [JsonPropertyName("created_at")]
    public DateTimeOffset CreatedAt { get; init; }

    [JsonPropertyName("updated_at")]
    public DateTimeOffset UpdatedAt { get; init; }
}

public sealed record ConversationMessage
{
    [JsonPropertyName("id")]
    public string Id { get; init; } = string.Empty;

    [JsonPropertyName("conversation_id")]
    public string ConversationId { get; init; } = string.Empty;

    [JsonPropertyName("parent_id")]
    public string? ParentId { get; init; }

    [JsonPropertyName("role")]
    public string Role { get; init; } = string.Empty;

    [JsonPropertyName("content")]
    public string Content { get; init; } = string.Empty;

    [JsonPropertyName("status")]
    public string Status { get; init; } = string.Empty;

    [JsonPropertyName("generation_id")]
    public string? GenerationId { get; init; }

    [JsonPropertyName("created_at")]
    public DateTimeOffset CreatedAt { get; init; }
}

public sealed record ProviderProfile
{
    [JsonPropertyName("id")]
    public string Id { get; init; } = string.Empty;

    [JsonPropertyName("display_name")]
    public string DisplayName { get; init; } = string.Empty;

    [JsonPropertyName("base_url")]
    public string BaseUrl { get; init; } = string.Empty;

    [JsonPropertyName("model")]
    public string Model { get; init; } = string.Empty;

    [JsonPropertyName("timeout_seconds")]
    public uint TimeoutSeconds { get; init; }
}

public sealed record AppSettings
{
    [JsonPropertyName("preserve_partial_generations")]
    public bool PreservePartialGenerations { get; init; } = true;

    [JsonPropertyName("selected_provider_profile_id")]
    public string? SelectedProviderProfileId { get; init; }
}

public enum ChatEventType
{
    GenerationStarted,
    ReasoningDelta,
    TextDelta,
    UsageUpdated,
    MessageCommitted,
    GenerationCancelled,
    GenerationFailed,
    GenerationFinished,
}

public sealed record ChatEvent
{
    public uint EventVersion { get; init; }

    public string GenerationId { get; init; } = string.Empty;

    public string ConversationId { get; init; } = string.Empty;

    public ulong Sequence { get; init; }

    public DateTimeOffset EmittedAt { get; init; }

    public ChatEventType Type { get; init; }

    public string? Text { get; init; }

    public string? MessageId { get; init; }

    public string? MessageStatus { get; init; }

    public string? ErrorCode { get; init; }

    public string? ErrorMessage { get; init; }

    public ulong? InputTokens { get; init; }

    public ulong? OutputTokens { get; init; }
}

public sealed record ChatEventBatch(
    IReadOnlyList<ChatEvent> Events,
    ulong DroppedEvents);

internal sealed record ChatEventBatchPayload
{
    [JsonPropertyName("events")]
    public IReadOnlyList<ChatEventPayload> Events { get; init; } = [];

    [JsonPropertyName("dropped_events")]
    public ulong DroppedEvents { get; init; }
}

internal sealed record ChatEventPayload
{
    [JsonPropertyName("event_version")]
    public uint EventVersion { get; init; }

    [JsonPropertyName("generation_id")]
    public string GenerationId { get; init; } = string.Empty;

    [JsonPropertyName("conversation_id")]
    public string ConversationId { get; init; } = string.Empty;

    [JsonPropertyName("sequence")]
    public ulong Sequence { get; init; }

    [JsonPropertyName("emitted_at")]
    public DateTimeOffset EmittedAt { get; init; }

    [JsonPropertyName("kind")]
    public ChatEventKindPayload Kind { get; init; } = new();
}

internal sealed record ChatEventKindPayload
{
    [JsonPropertyName("type")]
    public string Type { get; init; } = string.Empty;

    [JsonPropertyName("payload")]
    public JsonElement Payload { get; init; }
}
