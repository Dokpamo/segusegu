using Lorepia.Native.Interop;
using System.Text;
using System.Text.Json;
using System.Threading;

namespace Lorepia.Native;

public sealed class CoreClient : IDisposable
{
    public const uint SupportedAbiVersion = 2;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling =
            System.Text.Json.Serialization.JsonUnmappedMemberHandling.Skip,
    };

    private readonly INativeApi nativeApi;
    private readonly SafeCoreHandle core;
    private readonly object callGate = new();
    private int disposed;

    private CoreClient(
        INativeApi nativeApi,
        SafeCoreHandle core,
        uint abiVersion)
    {
        this.nativeApi = nativeApi;
        this.core = core;
        AbiVersion = abiVersion;
    }

    public uint AbiVersion { get; }

    public static CoreClient Open(string dataRoot)
    {
        return Open(PInvokeNativeApi.Instance, dataRoot);
    }

    internal static CoreClient Open(
        INativeApi nativeApi,
        string dataRoot)
    {
        ArgumentNullException.ThrowIfNull(nativeApi);
        ArgumentException.ThrowIfNullOrWhiteSpace(dataRoot);

        if (!Path.IsPathFullyQualified(dataRoot))
        {
            throw new ArgumentException(
                "The LorePia data root must be an absolute path.",
                nameof(dataRoot));
        }

        var normalizedDataRoot = Path.GetFullPath(dataRoot);
        var configurationJson = JsonSerializer.SerializeToUtf8Bytes(
            new CoreConfiguration(normalizedDataRoot),
            JsonOptions);

        var abiVersion = nativeApi.GetAbiVersion();
        if (abiVersion != SupportedAbiVersion)
        {
            throw new CoreInteropException(
                $"Unsupported LorePia C ABI version {abiVersion}; expected {SupportedAbiVersion}.");
        }

        var core = nativeApi.CreateCore(configurationJson);
        if (core.IsInvalid)
        {
            core.Dispose();
            throw new CoreInteropException(
                "The native core could not create a core handle.");
        }

        return new CoreClient(nativeApi, core, abiVersion);
    }

    public string GetCoreVersion()
    {
        return Invoke(() =>
        {
            using var buffer = nativeApi.GetCoreVersion(core);
            var version = buffer.ReadUtf8();
            if (string.IsNullOrWhiteSpace(version))
            {
                throw new CoreInteropException(
                    "The native core returned an empty version string.");
            }

            return version;
        });
    }

    public CoreHealth GetHealthCheck()
    {
        return Invoke(() =>
        {
            using var buffer = nativeApi.GetHealthCheckJson(core);
            return CoreHealthMapper.Parse(buffer.ReadUtf8());
        });
    }

    public ImportInspection InspectImport(string stagedPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(stagedPath);
        if (!Path.IsPathFullyQualified(stagedPath))
        {
            throw new ArgumentException(
                "The staged import path must be absolute.",
                nameof(stagedPath));
        }

        return Invoke(() =>
        {
            using var buffer = nativeApi.InspectImportJson(
                core,
                Utf8(Path.GetFullPath(stagedPath)));
            var inspection = Parse<ImportInspection>(
                buffer.ReadUtf8(),
                "import-inspection");
            Require(inspection.Id, "inspection id");
            Require(inspection.Kind, "inspection kind");
            Require(inspection.SourceSha256, "inspection source_sha256");
            if (inspection.RepresentativeImage is { } image)
            {
                Require(image.LogicalAssetId, "representative image logical_asset_id");
                Require(image.MediaType, "representative image media_type");
            }
            return inspection;
        });
    }

    public CharacterSummary CommitImport(string inspectionId)
    {
        RequireArgument(inspectionId, nameof(inspectionId));
        return Invoke(() =>
        {
            using var buffer = nativeApi.CommitImportJson(
                core,
                Utf8(inspectionId));
            return ParseCharacter(buffer.ReadUtf8(), "committed character");
        });
    }

    public void DiscardImport(string inspectionId)
    {
        RequireArgument(inspectionId, nameof(inspectionId));
        Invoke(() => nativeApi.DiscardImport(core, Utf8(inspectionId)));
    }

    public IReadOnlyList<CharacterSummary> ListCharacters()
    {
        return Invoke(() =>
        {
            using var buffer = nativeApi.GetCharactersJson(core);
            return CharacterSummaryMapper.Parse(buffer.ReadUtf8());
        });
    }

    public CharacterSummary GetCharacter(string characterId)
    {
        RequireArgument(characterId, nameof(characterId));
        return Invoke(() =>
        {
            using var buffer = nativeApi.GetCharacterJson(
                core,
                Utf8(characterId));
            return ParseCharacter(buffer.ReadUtf8(), "character");
        });
    }

    public Conversation OpenConversation(string characterId)
    {
        RequireArgument(characterId, nameof(characterId));
        return Invoke(() =>
        {
            using var buffer = nativeApi.OpenConversationJson(
                core,
                Utf8(characterId));
            return ParseConversation(buffer.ReadUtf8());
        });
    }

    public IReadOnlyList<Conversation> ListConversations()
    {
        return Invoke(() =>
        {
            using var buffer = nativeApi.GetConversationsJson(core);
            var conversations = Parse<List<Conversation>>(
                buffer.ReadUtf8(),
                "conversation-list");
            foreach (var conversation in conversations)
            {
                ValidateConversation(conversation);
            }

            return conversations;
        });
    }

    public IReadOnlyList<ConversationMessage> ListMessages(
        string conversationId)
    {
        RequireArgument(conversationId, nameof(conversationId));
        return Invoke(() =>
        {
            using var buffer = nativeApi.GetMessagesJson(
                core,
                Utf8(conversationId));
            var messages = Parse<List<ConversationMessage>>(
                buffer.ReadUtf8(),
                "message-list");
            foreach (var message in messages)
            {
                Require(message.Id, "message id");
                Require(message.ConversationId, "message conversation_id");
                Require(message.Role, "message role");
                Require(message.Status, "message status");
            }

            return messages;
        });
    }

    public string SendMessage(
        string conversationId,
        string text,
        string providerProfileId,
        string? credential)
    {
        RequireArgument(conversationId, nameof(conversationId));
        RequireArgument(text, nameof(text));
        RequireArgument(providerProfileId, nameof(providerProfileId));
        if (credential is not null && credential.Length == 0)
        {
            credential = null;
        }

        var credentialBytes = credential is null ? null : Utf8(credential);
        try
        {
            return Invoke(() =>
            {
                using var buffer = nativeApi.SendMessageJson(
                    core,
                    Utf8(conversationId),
                    Utf8(text),
                    Utf8(providerProfileId),
                    credentialBytes);
                var generationId = Parse<string>(
                    buffer.ReadUtf8(),
                    "generation id");
                Require(generationId, "generation id");
                return generationId;
            });
        }
        finally
        {
            if (credentialBytes is not null)
            {
                System.Security.Cryptography.CryptographicOperations.ZeroMemory(
                    credentialBytes);
            }
        }
    }

    public void CancelGeneration(string generationId)
    {
        RequireArgument(generationId, nameof(generationId));
        Invoke(() => nativeApi.CancelGeneration(core, Utf8(generationId)));
    }

    public ChatEventBatch PollEvents(uint maxEvents = 128)
    {
        if (maxEvents is 0 or > 1024)
        {
            throw new ArgumentOutOfRangeException(
                nameof(maxEvents),
                "Event batch size must be between 1 and 1024.");
        }

        return Invoke(() =>
        {
            using var buffer = nativeApi.PollEventsJson(core, maxEvents);
            var payload = Parse<ChatEventBatchPayload>(
                buffer.ReadUtf8(),
                "chat-event batch");
            return new ChatEventBatch(
                payload.Events.Select(MapEvent).ToArray(),
                payload.DroppedEvents);
        });
    }

    public AppSettings GetSettings()
    {
        return Invoke(() =>
        {
            using var buffer = nativeApi.GetSettingsJson(core);
            return Parse<AppSettings>(buffer.ReadUtf8(), "app settings");
        });
    }

    public void UpdateSettings(AppSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        Invoke(() => nativeApi.UpdateSettingsJson(
            core,
            JsonSerializer.SerializeToUtf8Bytes(settings, JsonOptions)));
    }

    public IReadOnlyList<ProviderProfile> ListProviderProfiles()
    {
        return Invoke(() =>
        {
            using var buffer = nativeApi.GetProviderProfilesJson(core);
            var profiles = Parse<List<ProviderProfile>>(
                buffer.ReadUtf8(),
                "provider-profile list");
            foreach (var profile in profiles)
            {
                ValidateProviderProfile(profile);
            }

            return profiles;
        });
    }

    public ProviderProfile UpsertProviderProfile(ProviderProfile profile)
    {
        ArgumentNullException.ThrowIfNull(profile);
        ValidateProviderProfile(profile);
        return Invoke(() =>
        {
            using var buffer = nativeApi.UpsertProviderProfileJson(
                core,
                JsonSerializer.SerializeToUtf8Bytes(profile, JsonOptions));
            var normalized = Parse<ProviderProfile>(
                buffer.ReadUtf8(),
                "provider profile");
            ValidateProviderProfile(normalized);
            return normalized;
        });
    }

    public void DeleteProviderProfile(string profileId)
    {
        RequireArgument(profileId, nameof(profileId));
        Invoke(() => nativeApi.DeleteProviderProfile(
            core,
            Utf8(profileId)));
    }

    public void Dispose()
    {
        lock (callGate)
        {
            if (Interlocked.Exchange(ref disposed, 1) == 0)
            {
                core.Dispose();
            }
        }
    }

    private T Invoke<T>(Func<T> operation)
    {
        lock (callGate)
        {
            ThrowIfDisposed();
            return operation();
        }
    }

    private void Invoke(Action operation)
    {
        lock (callGate)
        {
            ThrowIfDisposed();
            operation();
        }
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(
            Volatile.Read(ref disposed) != 0,
            this);
    }

    private static CharacterSummary ParseCharacter(
        string json,
        string payloadName)
    {
        var character = Parse<CharacterSummary>(json, payloadName);
        Require(character.Id, $"{payloadName} id");
        Require(character.Name, $"{payloadName} name");
        Require(character.SourceHash, $"{payloadName} source_hash");
        return character;
    }

    private static Conversation ParseConversation(string json)
    {
        var conversation = Parse<Conversation>(json, "conversation");
        ValidateConversation(conversation);
        return conversation;
    }

    private static void ValidateConversation(Conversation conversation)
    {
        Require(conversation.Id, "conversation id");
        Require(conversation.CharacterId, "conversation character_id");
        Require(conversation.Title, "conversation title");
    }

    private static void ValidateProviderProfile(ProviderProfile profile)
    {
        Require(profile.Id, "provider profile id");
        Require(profile.DisplayName, "provider profile display_name");
        Require(profile.BaseUrl, "provider profile base_url");
        Require(profile.Model, "provider profile model");
        if (profile.TimeoutSeconds is 0 or > 600)
        {
            throw new CoreInteropException(
                "A provider profile timeout_seconds must be between 1 and 600.");
        }
    }

    private static ChatEvent MapEvent(ChatEventPayload payload)
    {
        if (payload.EventVersion is not 1 and not 2)
        {
            throw new CoreInteropException(
                $"Unsupported chat event version {payload.EventVersion}.");
        }

        Require(payload.GenerationId, "chat event generation_id");
        Require(payload.ConversationId, "chat event conversation_id");
        var result = new ChatEvent
        {
            EventVersion = payload.EventVersion,
            GenerationId = payload.GenerationId,
            ConversationId = payload.ConversationId,
            BranchId = payload.BranchId,
            AssistantMessageId = payload.AssistantMessageId,
            Sequence = payload.Sequence,
            EmittedAt = payload.EmittedAt,
        };

        return payload.Kind.Type switch
        {
            "generation_started" => result with
            {
                Type = ChatEventType.GenerationStarted,
            },
            "reasoning_delta" => result with
            {
                Type = ChatEventType.ReasoningDelta,
                Text = ReadStringPayload(payload.Kind, "reasoning_delta"),
            },
            "text_delta" => result with
            {
                Type = ChatEventType.TextDelta,
                Text = ReadStringPayload(payload.Kind, "text_delta"),
            },
            "usage_updated" => result with
            {
                Type = ChatEventType.UsageUpdated,
                InputTokens = ReadOptionalUInt64(
                    payload.Kind.Payload,
                    "input_tokens"),
                OutputTokens = ReadOptionalUInt64(
                    payload.Kind.Payload,
                    "output_tokens"),
            },
            "message_committed" => result with
            {
                Type = ChatEventType.MessageCommitted,
                MessageId = ReadRequiredString(
                    payload.Kind.Payload,
                    "message_id"),
                MessageStatus = ReadRequiredString(
                    payload.Kind.Payload,
                    "status"),
            },
            "generation_cancelled" => result with
            {
                Type = ChatEventType.GenerationCancelled,
            },
            "generation_failed" => result with
            {
                Type = ChatEventType.GenerationFailed,
                ErrorCode = ReadRequiredString(payload.Kind.Payload, "code"),
                ErrorMessage = ReadRequiredString(
                    payload.Kind.Payload,
                    "message"),
            },
            "generation_finished" => result with
            {
                Type = ChatEventType.GenerationFinished,
            },
            _ => throw new CoreInteropException(
                $"Unsupported chat event type '{payload.Kind.Type}'."),
        };
    }

    private static string ReadStringPayload(
        ChatEventKindPayload payload,
        string eventType)
    {
        if (payload.Payload.ValueKind != JsonValueKind.String)
        {
            throw new CoreInteropException(
                $"The {eventType} event payload must be a string.");
        }

        return payload.Payload.GetString() ?? string.Empty;
    }

    private static string ReadRequiredString(
        JsonElement payload,
        string property)
    {
        if (payload.ValueKind != JsonValueKind.Object
            || !payload.TryGetProperty(property, out var value)
            || value.ValueKind != JsonValueKind.String
            || string.IsNullOrWhiteSpace(value.GetString()))
        {
            throw new CoreInteropException(
                $"A chat event payload is missing {property}.");
        }

        return value.GetString()!;
    }

    private static ulong? ReadOptionalUInt64(
        JsonElement payload,
        string property)
    {
        if (payload.ValueKind != JsonValueKind.Object
            || !payload.TryGetProperty(property, out var value)
            || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        if (value.ValueKind != JsonValueKind.Number
            || !value.TryGetUInt64(out var parsed))
        {
            throw new CoreInteropException(
                $"A chat usage payload has invalid {property}.");
        }

        return parsed;
    }

    private static T Parse<T>(string json, string payloadName)
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            throw new CoreInteropException(
                $"The native core returned an empty {payloadName} payload.");
        }

        try
        {
            return JsonSerializer.Deserialize<T>(json, JsonOptions)
                ?? throw new CoreInteropException(
                    $"The native core returned a null {payloadName} payload.");
        }
        catch (JsonException exception)
        {
            throw new CoreInteropException(
                $"The native core returned invalid {payloadName} JSON.",
                exception);
        }
    }

    private static byte[] Utf8(string value) => Encoding.UTF8.GetBytes(value);

    private static void RequireArgument(string value, string parameterName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(value, parameterName);
    }

    private static void Require(string value, string field)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new CoreInteropException(
                $"The native core payload is missing {field}.");
        }
    }

    private sealed record CoreConfiguration(
        [property: System.Text.Json.Serialization.JsonPropertyName("data_root")]
        string DataRoot);
}
