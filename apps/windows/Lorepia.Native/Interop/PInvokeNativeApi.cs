namespace Lorepia.Native.Interop;

internal sealed class PInvokeNativeApi : INativeApi
{
    private static readonly System.Text.Json.JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = false,
    };

    internal static PInvokeNativeApi Instance { get; } = new();

    private PInvokeNativeApi()
    {
        NativeLibraryResolver.EnsureRegistered();
    }

    public uint GetAbiVersion() => NativeMethods.AbiVersion();

    public SafeCoreHandle CreateCore(byte[] configurationJson)
    {
        ArgumentNullException.ThrowIfNull(configurationJson);

        var status = NativeMethods.CoreCreate(
            configurationJson,
            checked((nuint)configurationJson.Length),
            out var pointer);
        if (status != NativeStatus.Success)
        {
            if (pointer != IntPtr.Zero)
            {
                NativeMethods.CoreDestroy(pointer);
            }

            throw CreateFailure("lorepia_core_create", status, null);
        }

        return new SafeCoreHandle(pointer, NativeMethods.CoreDestroy);
    }

    public NativeBuffer GetCoreVersion(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);

        var status = NativeMethods.CoreVersion(core, out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_version",
            status,
            buffer,
            core);
    }

    public NativeBuffer GetHealthCheckJson(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);

        var status = NativeMethods.CoreHealthCheckJson(core, out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_health_check_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer InspectImportJson(
        SafeCoreHandle core,
        byte[] stagedPath)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(stagedPath);

        var status = NativeMethods.CoreInspectImportJson(
            core,
            stagedPath,
            checked((nuint)stagedPath.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_inspect_import_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer CommitImportJson(
        SafeCoreHandle core,
        byte[] inspectionId)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(inspectionId);

        var status = NativeMethods.CoreCommitImportJson(
            core,
            inspectionId,
            checked((nuint)inspectionId.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_commit_import_json",
            status,
            buffer,
            core);
    }

    public void DiscardImport(
        SafeCoreHandle core,
        byte[] inspectionId)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(inspectionId);

        var status = NativeMethods.CoreDiscardImport(
            core,
            inspectionId,
            checked((nuint)inspectionId.Length));
        ThrowIfFailed("lorepia_core_discard_import", status, core);
    }

    public NativeBuffer GetCharactersJson(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);

        var status = NativeMethods.CoreListCharactersJson(core, out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_list_characters_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer GetCharacterJson(
        SafeCoreHandle core,
        byte[] characterId)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(characterId);

        var status = NativeMethods.CoreGetCharacterJson(
            core,
            characterId,
            checked((nuint)characterId.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_get_character_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer OpenConversationJson(
        SafeCoreHandle core,
        byte[] characterId)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(characterId);

        var status = NativeMethods.CoreOpenConversationJson(
            core,
            characterId,
            checked((nuint)characterId.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_open_conversation_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer GetConversationsJson(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);

        var status = NativeMethods.CoreListConversationsJson(
            core,
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_list_conversations_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer GetMessagesJson(
        SafeCoreHandle core,
        byte[] conversationId)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(conversationId);

        var status = NativeMethods.CoreListMessagesJson(
            core,
            conversationId,
            checked((nuint)conversationId.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_list_messages_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer SendMessageJson(
        SafeCoreHandle core,
        byte[] conversationId,
        byte[] text,
        byte[] providerProfileId,
        byte[]? credential)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(conversationId);
        ArgumentNullException.ThrowIfNull(text);
        ArgumentNullException.ThrowIfNull(providerProfileId);

        var status = NativeMethods.CoreSendMessageJson(
            core,
            conversationId,
            checked((nuint)conversationId.Length),
            text,
            checked((nuint)text.Length),
            providerProfileId,
            checked((nuint)providerProfileId.Length),
            credential,
            checked((nuint)(credential?.Length ?? 0)),
            credential is null ? (byte)0 : (byte)1,
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_send_message_json",
            status,
            buffer,
            core);
    }

    public void CancelGeneration(
        SafeCoreHandle core,
        byte[] generationId)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(generationId);

        var status = NativeMethods.CoreCancelGeneration(
            core,
            generationId,
            checked((nuint)generationId.Length));
        ThrowIfFailed("lorepia_core_cancel_generation", status, core);
    }

    public NativeBuffer PollEventsJson(
        SafeCoreHandle core,
        uint maxEvents)
    {
        ArgumentNullException.ThrowIfNull(core);

        var status = NativeMethods.CorePollEventsJson(
            core,
            maxEvents,
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_poll_events_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer GetSettingsJson(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);

        var status = NativeMethods.CoreGetSettingsJson(core, out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_get_settings_json",
            status,
            buffer,
            core);
    }

    public void UpdateSettingsJson(
        SafeCoreHandle core,
        byte[] settingsJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(settingsJson);

        var status = NativeMethods.CoreUpdateSettingsJson(
            core,
            settingsJson,
            checked((nuint)settingsJson.Length));
        ThrowIfFailed("lorepia_core_update_settings_json", status, core);
    }

    public NativeBuffer GetProviderProfilesJson(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);

        var status = NativeMethods.CoreListProviderProfilesJson(
            core,
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_list_provider_profiles_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer UpsertProviderProfileJson(
        SafeCoreHandle core,
        byte[] profileJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(profileJson);

        var status = NativeMethods.CoreUpsertProviderProfileJson(
            core,
            profileJson,
            checked((nuint)profileJson.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_upsert_provider_profile_json",
            status,
            buffer,
            core);
    }

    public void DeleteProviderProfile(
        SafeCoreHandle core,
        byte[] profileId)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(profileId);

        var status = NativeMethods.CoreDeleteProviderProfile(
            core,
            profileId,
            checked((nuint)profileId.Length));
        ThrowIfFailed("lorepia_core_delete_provider_profile", status, core);
    }

    private static NativeBuffer OwnSuccessfulBuffer(
        string operation,
        int status,
        NativeBufferValue buffer,
        SafeCoreHandle core)
    {
        if (status != NativeStatus.Success)
        {
            if (buffer.Pointer != IntPtr.Zero || buffer.Length != 0)
            {
                NativeMethods.BufferFree(buffer);
            }

            throw CreateFailure(operation, status, core);
        }

        return new NativeBuffer(buffer, NativeMethods.BufferFree);
    }

    private static void ThrowIfFailed(
        string operation,
        int status,
        SafeCoreHandle core)
    {
        if (status != NativeStatus.Success)
        {
            throw CreateFailure(operation, status, core);
        }
    }

    private static CoreInteropException CreateFailure(
        string operation,
        int status,
        SafeCoreHandle? core)
    {
        NativeBufferValue buffer = default;
        try
        {
            var errorStatus = NativeMethods.CoreLastErrorJson(
                core,
                out buffer);
            if (errorStatus != NativeStatus.Success)
            {
                return new CoreInteropException(operation, status, null);
            }

            using var owned = new NativeBuffer(
                buffer,
                NativeMethods.BufferFree);
            buffer = default;
            var payload = System.Text.Json.JsonSerializer.Deserialize<NativeErrorPayload>(
                owned.ReadUtf8(),
                JsonOptions);
            return new CoreInteropException(operation, status, payload);
        }
        catch (Exception exception) when (
            exception is not AccessViolationException
            && exception is not CoreInteropException)
        {
            return new CoreInteropException(operation, status, null);
        }
        finally
        {
            if (buffer.Pointer != IntPtr.Zero || buffer.Length != 0)
            {
                NativeMethods.BufferFree(buffer);
            }
        }
    }
}
