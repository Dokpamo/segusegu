using System.Runtime.InteropServices;

namespace Lorepia.Native.Interop;

internal static class NativeMethods
{
    internal const string LibraryName = "lorepia_core";

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_abi_version",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern uint AbiVersion();

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_create",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreCreate(
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 1)]
        byte[] configurationJson,
        nuint configurationJsonLength,
        out IntPtr core);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_destroy",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern void CoreDestroy(IntPtr core);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_last_error_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreLastErrorJson(
        SafeCoreHandle? core,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_version",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreVersion(
        SafeCoreHandle core,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_health_check_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreHealthCheckJson(
        SafeCoreHandle core,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_inspect_import_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreInspectImportJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] stagedPath,
        nuint stagedPathLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_commit_import_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreCommitImportJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] inspectionId,
        nuint inspectionIdLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_discard_import",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreDiscardImport(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] inspectionId,
        nuint inspectionIdLength);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_list_characters_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreListCharactersJson(
        SafeCoreHandle core,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_get_character_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreGetCharacterJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] characterId,
        nuint characterIdLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_open_conversation_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreOpenConversationJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] characterId,
        nuint characterIdLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_list_conversations_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreListConversationsJson(
        SafeCoreHandle core,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_list_messages_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreListMessagesJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] conversationId,
        nuint conversationIdLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_send_message_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreSendMessageJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] conversationId,
        nuint conversationIdLength,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 4)]
        byte[] text,
        nuint textLength,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 6)]
        byte[] providerProfileId,
        nuint providerProfileIdLength,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 8)]
        byte[]? credential,
        nuint credentialLength,
        byte credentialPresent,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_cancel_generation",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreCancelGeneration(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] generationId,
        nuint generationIdLength);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_poll_events_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CorePollEventsJson(
        SafeCoreHandle core,
        uint maxEvents,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_get_settings_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreGetSettingsJson(
        SafeCoreHandle core,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_update_settings_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreUpdateSettingsJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] settingsJson,
        nuint settingsJsonLength);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_list_provider_profiles_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreListProviderProfilesJson(
        SafeCoreHandle core,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_upsert_provider_profile_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreUpsertProviderProfileJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] profileJson,
        nuint profileJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_delete_provider_profile",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreDeleteProviderProfile(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] profileId,
        nuint profileIdLength);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_buffer_free",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern void BufferFree(NativeBufferValue buffer);
}
