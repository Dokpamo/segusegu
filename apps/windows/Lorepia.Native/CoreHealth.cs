using System.Text.Json.Serialization;

namespace Lorepia.Native;

public sealed record CoreHealth
{
    [JsonPropertyName("core_version")]
    public string CoreVersion { get; init; } = string.Empty;

    [JsonPropertyName("database_open")]
    public bool DatabaseOpen { get; init; }

    [JsonPropertyName("schema_version")]
    public long SchemaVersion { get; init; }

    [JsonPropertyName("data_root_writable")]
    public bool DataRootWritable { get; init; }

    [JsonPropertyName("staging_writable")]
    public bool StagingWritable { get; init; }

    [JsonPropertyName("recovery_pending")]
    public bool RecoveryPending { get; init; }

    [JsonPropertyName("active_jobs")]
    public int ActiveJobs { get; init; }
}
