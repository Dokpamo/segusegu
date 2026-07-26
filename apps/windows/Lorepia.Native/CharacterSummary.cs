using System.Text.Json.Serialization;

namespace Lorepia.Native;

public sealed record CharacterSummary
{
    [JsonPropertyName("id")]
    public string Id { get; init; } = string.Empty;

    [JsonPropertyName("name")]
    public string Name { get; init; } = string.Empty;

    [JsonPropertyName("description")]
    public string Description { get; init; } = string.Empty;

    [JsonPropertyName("source_hash")]
    public string SourceHash { get; init; } = string.Empty;

    [JsonPropertyName("avatar_asset_hash")]
    public string? AvatarAssetHash { get; init; }

    [JsonPropertyName("created_at")]
    public DateTimeOffset CreatedAt { get; init; }
}
