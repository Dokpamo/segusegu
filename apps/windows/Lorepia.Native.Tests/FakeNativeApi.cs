using Lorepia.Native.Interop;
using System.Runtime.InteropServices;
using System.Text;

namespace Lorepia.Native.Tests;

internal sealed class FakeNativeApi : INativeApi
{
    internal uint AbiVersion { get; set; } = CoreClient.SupportedAbiVersion;

    internal string Version { get; set; } = "0.1.0-test";

    internal string HealthJson { get; set; } =
        """
        {
          "core_version": "0.1.0-test",
          "database_open": true,
          "schema_version": 3,
          "data_root_writable": true,
          "staging_writable": true,
          "recovery_pending": false,
          "active_jobs": 2
        }
        """;

    internal string CharactersJson { get; set; } =
        """
        [
          {
            "id": "character-1",
            "name": "테스트 캐릭터",
            "description": "합성 테스트 데이터",
            "source_hash": "abc123",
            "avatar_asset_hash": null,
            "created_at": "2026-07-26T00:00:00Z",
            "future_field": "ignored"
          }
        ]
        """;

    internal string InspectionJson { get; set; } =
        """
        {
          "id": "inspection-1",
          "kind": "character_card_v3",
          "display_name": "테스트 캐릭터",
          "description": "합성 테스트 데이터",
          "representative_image": {
            "logical_asset_id": "assets/avatar.png",
            "media_type": "image/png",
            "size_bytes": 70
          },
          "source_sha256": "abc123",
          "source_size": 128,
          "estimated_stored_size": 256,
          "asset_count": 0,
          "warnings": [],
          "blocked_reasons": [],
          "unsupported_optional_fields": [
            "alternate_greetings",
            "creator"
          ]
        }
        """;

    internal string CharacterJson { get; set; } =
        """
        {
          "id": "character-1",
          "name": "테스트 캐릭터",
          "description": "합성 테스트 데이터",
          "source_hash": "abc123",
          "avatar_asset_hash": null,
          "created_at": "2026-07-26T00:00:00Z"
        }
        """;

    internal string ConversationJson { get; set; } =
        """
        {
          "id": "conversation-1",
          "character_id": "character-1",
          "title": "테스트 캐릭터",
          "created_at": "2026-07-26T00:00:00Z",
          "updated_at": "2026-07-26T00:00:00Z"
        }
        """;

    internal string ConversationsJson { get; set; } =
        """
        [
          {
            "id": "conversation-1",
            "character_id": "character-1",
            "title": "테스트 캐릭터",
            "created_at": "2026-07-26T00:00:00Z",
            "updated_at": "2026-07-26T00:00:00Z"
          }
        ]
        """;

    internal string MessagesJson { get; set; } =
        """
        [
          {
            "id": "message-1",
            "conversation_id": "conversation-1",
            "parent_id": null,
            "role": "user",
            "content": "안녕",
            "status": "complete",
            "generation_id": null,
            "created_at": "2026-07-26T00:00:00Z"
          }
        ]
        """;

    internal string GenerationJson { get; set; } = "\"generation-1\"";

    internal string EventsJson { get; set; } =
        """
        {
          "events": [
            {
              "event_version": 1,
              "generation_id": "generation-1",
              "conversation_id": "conversation-1",
              "sequence": 1,
              "emitted_at": "2026-07-26T00:00:00Z",
              "kind": {
                "type": "text_delta",
                "payload": "반가워"
              }
            }
          ],
          "dropped_events": 0
        }
        """;

    internal string SettingsJson { get; set; } =
        """
        {
          "preserve_partial_generations": true,
          "selected_provider_profile_id": "provider-1"
        }
        """;

    internal string ProviderProfilesJson { get; set; } =
        """
        [
          {
            "id": "provider-1",
            "display_name": "테스트 공급자",
            "base_url": "https://example.invalid/v1",
            "model": "test-model",
            "timeout_seconds": 30
          }
        ]
        """;

    internal string ProviderProfileJson { get; set; } =
        """
        {
          "id": "provider-1",
          "display_name": "테스트 공급자",
          "base_url": "https://example.invalid/v1",
          "model": "test-model",
          "timeout_seconds": 30
        }
        """;

    internal string? ConfigurationJson { get; private set; }

    internal string? LastStagedPath { get; private set; }

    internal string? LastInspectionId { get; private set; }

    internal string? LastConversationId { get; private set; }

    internal string? LastSentText { get; private set; }

    internal string? LastProviderProfileId { get; private set; }

    internal string? LastCredential { get; private set; }

    internal string? LastSettingsJson { get; private set; }

    internal string? LastProfileJson { get; private set; }

    internal string? LastDeletedProfileId { get; private set; }

    internal uint LastMaxEvents { get; private set; }

    internal int DiscardCount { get; private set; }

    internal int CancelCount { get; private set; }

    internal int CreateCount { get; private set; }

    internal int DestroyCount { get; private set; }

    internal int BufferFreeCount { get; private set; }

    internal Action? BeforeGetCoreVersion { get; set; }

    public uint GetAbiVersion() => AbiVersion;

    public SafeCoreHandle CreateCore(byte[] configurationJson)
    {
        ArgumentNullException.ThrowIfNull(configurationJson);
        CreateCount++;
        ConfigurationJson = Encoding.UTF8.GetString(configurationJson);
        return new SafeCoreHandle(
            new IntPtr(0x1234),
            _ => DestroyCount++);
    }

    public NativeBuffer GetCoreVersion(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);
        BeforeGetCoreVersion?.Invoke();
        return CreateBuffer(Version);
    }

    public NativeBuffer GetHealthCheckJson(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);
        return CreateBuffer(HealthJson);
    }

    public NativeBuffer GetCharactersJson(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);
        return CreateBuffer(CharactersJson);
    }

    public NativeBuffer InspectImportJson(
        SafeCoreHandle core,
        byte[] stagedPath)
    {
        ArgumentNullException.ThrowIfNull(core);
        LastStagedPath = Decode(stagedPath);
        return CreateBuffer(InspectionJson);
    }

    public NativeBuffer CommitImportJson(
        SafeCoreHandle core,
        byte[] inspectionId)
    {
        ArgumentNullException.ThrowIfNull(core);
        LastInspectionId = Decode(inspectionId);
        return CreateBuffer(CharacterJson);
    }

    public void DiscardImport(
        SafeCoreHandle core,
        byte[] inspectionId)
    {
        ArgumentNullException.ThrowIfNull(core);
        LastInspectionId = Decode(inspectionId);
        DiscardCount++;
    }

    public NativeBuffer GetCharacterJson(
        SafeCoreHandle core,
        byte[] characterId)
    {
        ArgumentNullException.ThrowIfNull(core);
        _ = Decode(characterId);
        return CreateBuffer(CharacterJson);
    }

    public NativeBuffer OpenConversationJson(
        SafeCoreHandle core,
        byte[] characterId)
    {
        ArgumentNullException.ThrowIfNull(core);
        _ = Decode(characterId);
        return CreateBuffer(ConversationJson);
    }

    public NativeBuffer GetConversationsJson(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);
        return CreateBuffer(ConversationsJson);
    }

    public NativeBuffer GetMessagesJson(
        SafeCoreHandle core,
        byte[] conversationId)
    {
        ArgumentNullException.ThrowIfNull(core);
        LastConversationId = Decode(conversationId);
        return CreateBuffer(MessagesJson);
    }

    public NativeBuffer SendMessageJson(
        SafeCoreHandle core,
        byte[] conversationId,
        byte[] text,
        byte[] providerProfileId,
        byte[]? credential)
    {
        ArgumentNullException.ThrowIfNull(core);
        LastConversationId = Decode(conversationId);
        LastSentText = Decode(text);
        LastProviderProfileId = Decode(providerProfileId);
        LastCredential = credential is null ? null : Decode(credential);
        return CreateBuffer(GenerationJson);
    }

    public void CancelGeneration(
        SafeCoreHandle core,
        byte[] generationId)
    {
        ArgumentNullException.ThrowIfNull(core);
        _ = Decode(generationId);
        CancelCount++;
    }

    public NativeBuffer PollEventsJson(
        SafeCoreHandle core,
        uint maxEvents)
    {
        ArgumentNullException.ThrowIfNull(core);
        LastMaxEvents = maxEvents;
        return CreateBuffer(EventsJson);
    }

    public NativeBuffer GetSettingsJson(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);
        return CreateBuffer(SettingsJson);
    }

    public void UpdateSettingsJson(
        SafeCoreHandle core,
        byte[] settingsJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        LastSettingsJson = Decode(settingsJson);
    }

    public NativeBuffer GetProviderProfilesJson(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);
        return CreateBuffer(ProviderProfilesJson);
    }

    public NativeBuffer UpsertProviderProfileJson(
        SafeCoreHandle core,
        byte[] profileJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        LastProfileJson = Decode(profileJson);
        return CreateBuffer(ProviderProfileJson);
    }

    public void DeleteProviderProfile(
        SafeCoreHandle core,
        byte[] profileId)
    {
        ArgumentNullException.ThrowIfNull(core);
        LastDeletedProfileId = Decode(profileId);
    }

    private NativeBuffer CreateBuffer(string text)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        var pointer = Marshal.AllocHGlobal(bytes.Length);
        if (bytes.Length > 0)
        {
            Marshal.Copy(bytes, 0, pointer, bytes.Length);
        }

        return new NativeBuffer(
            new NativeBufferValue(pointer, checked((nuint)bytes.Length)),
            value =>
            {
                BufferFreeCount++;
                Marshal.FreeHGlobal(value.Pointer);
            });
    }

    private static string Decode(byte[] bytes) =>
        Encoding.UTF8.GetString(bytes);
}
