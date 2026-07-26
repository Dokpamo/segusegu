using System.Text.Json;

namespace Lorepia.Native;

internal static class CharacterSummaryMapper
{
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = System.Text.Json.Serialization.JsonUnmappedMemberHandling.Skip,
    };

    internal static IReadOnlyList<CharacterSummary> Parse(string json)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(json);

        try
        {
            var characters = JsonSerializer.Deserialize<List<CharacterSummary>>(
                json,
                Options)
                ?? throw new CoreInteropException(
                    "The native core returned an empty character-list payload.");

            foreach (var character in characters)
            {
                if (string.IsNullOrWhiteSpace(character.Id)
                    || string.IsNullOrWhiteSpace(character.Name)
                    || string.IsNullOrWhiteSpace(character.SourceHash))
                {
                    throw new CoreInteropException(
                        "A character-list entry is missing id, name, or source_hash.");
                }
            }

            return characters;
        }
        catch (JsonException exception)
        {
            throw new CoreInteropException(
                "The native core returned invalid character-list JSON.",
                exception);
        }
    }
}
