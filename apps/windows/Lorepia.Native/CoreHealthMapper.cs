using System.Text.Json;

namespace Lorepia.Native;

internal static class CoreHealthMapper
{
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNameCaseInsensitive = false,
    };

    internal static CoreHealth Parse(string json)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(json);

        try
        {
            var health = JsonSerializer.Deserialize<CoreHealth>(json, Options)
                ?? throw new CoreInteropException(
                    "The native core returned an empty health-check payload.");

            if (string.IsNullOrWhiteSpace(health.CoreVersion))
            {
                throw new CoreInteropException(
                    "The health-check payload does not contain core_version.");
            }

            if (health.SchemaVersion < 0 || health.ActiveJobs < 0)
            {
                throw new CoreInteropException(
                    "The health-check payload contains an invalid negative value.");
            }

            return health;
        }
        catch (JsonException exception)
        {
            throw new CoreInteropException(
                "The native core returned invalid health-check JSON.",
                exception);
        }
    }
}
