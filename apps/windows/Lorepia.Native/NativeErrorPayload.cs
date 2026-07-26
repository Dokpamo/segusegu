using System.Text.Json.Serialization;

namespace Lorepia.Native;

internal sealed record NativeErrorPayload
{
    [JsonPropertyName("status")]
    public int Status { get; init; }

    [JsonPropertyName("code")]
    public string Code { get; init; } = string.Empty;

    [JsonPropertyName("message")]
    public string Message { get; init; } = string.Empty;

    [JsonPropertyName("recoverable")]
    public bool Recoverable { get; init; }

    [JsonPropertyName("operation_id")]
    public string OperationId { get; init; } = string.Empty;
}
