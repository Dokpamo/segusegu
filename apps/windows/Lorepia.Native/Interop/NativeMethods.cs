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
        EntryPoint = "lorepia_core_send_message_with_target_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreSendMessageWithTargetJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 4)]
        byte[]? credential,
        nuint credentialLength,
        byte credentialPresent,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_send_message_to_branch_with_target_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreSendMessageToBranchWithTargetJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 4)]
        byte[]? credential,
        nuint credentialLength,
        byte credentialPresent,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_edit_user_message_with_target_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreEditUserMessageWithTargetJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 4)]
        byte[]? credential,
        nuint credentialLength,
        byte credentialPresent,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_regenerate_assistant_message_with_target_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreRegenerateAssistantMessageWithTargetJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 4)]
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
        EntryPoint = "lorepia_core_list_provider_templates_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreListProviderTemplatesJson(
        SafeCoreHandle core,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_create_provider_connection_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreCreateProviderConnectionJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_list_provider_connections_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreListProviderConnectionsJson(
        SafeCoreHandle core,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_upsert_provider_connection_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreUpsertProviderConnectionJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_delete_provider_connection_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreDeleteProviderConnectionJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_list_model_routes_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreListModelRoutesJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] connectionId,
        nuint connectionIdLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_upsert_model_route_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreUpsertModelRouteJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_delete_model_route_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreDeleteModelRouteJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_list_capability_observations_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreListCapabilityObservationsJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] modelRouteId,
        nuint modelRouteIdLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_get_effective_capability_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreGetEffectiveCapabilityJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_effective_parameter_specs_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreEffectiveParameterSpecsJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] modelRouteId,
        nuint modelRouteIdLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_upsert_user_capability_override_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreUpsertUserCapabilityOverrideJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_delete_user_capability_override_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreDeleteUserCapabilityOverrideJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_refresh_provider_models_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreRefreshProviderModelsJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 4)]
        byte[]? credential,
        nuint credentialLength,
        byte credentialPresent,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_start_provider_model_sync_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreStartProviderModelSyncJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 4)]
        byte[]? credential,
        nuint credentialLength,
        byte credentialPresent,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_get_provider_model_sync_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreGetProviderModelSyncJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_list_provider_model_syncs_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreListProviderModelSyncsJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_approve_provider_model_sync_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreApproveProviderModelSyncJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_cancel_provider_model_sync_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreCancelProviderModelSyncJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_poll_provider_model_sync_job_events_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CorePollProviderModelSyncJobEventsJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_ack_provider_model_sync_event_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreAckProviderModelSyncEventJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_inspect_provider_curl_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreInspectProviderCurlJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 4)]
        byte[] rawCurl,
        nuint rawCurlLength,
        out NativeBufferValue metadata,
        out NativeBufferValue credential);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_begin_provider_discovery_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreBeginProviderDiscoveryJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 4)]
        byte[]? rawCurl,
        nuint rawCurlLength,
        byte rawCurlPresent,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_prepare_provider_discovery_action_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CorePrepareProviderDiscoveryActionJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_get_provider_discovery_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreGetProviderDiscoveryJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_list_provider_discoveries_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreListProviderDiscoveriesJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_list_provider_discovery_candidates_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreListProviderDiscoveryCandidatesJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_list_provider_discovery_evidence_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreListProviderDiscoveryEvidenceJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_list_provider_discovery_approvals_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreListProviderDiscoveryApprovalsJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_get_provider_discovery_review_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreGetProviderDiscoveryReviewJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_get_provider_discovery_approval_proposal_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreGetProviderDiscoveryApprovalProposalJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_get_provider_discovery_review_proposal_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreGetProviderDiscoveryReviewProposalJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_continue_provider_discovery_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreContinueProviderDiscoveryJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 4)]
        byte[]? credential,
        nuint credentialLength,
        byte credentialPresent,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_supply_provider_discovery_evidence_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreSupplyProviderDiscoveryEvidenceJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 4)]
        byte[]? rawCurl,
        nuint rawCurlLength,
        byte rawCurlPresent,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_cancel_provider_discovery_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreCancelProviderDiscoveryJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_commit_provider_discovery_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreCommitProviderDiscoveryJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_recover_provider_discoveries_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreRecoverProviderDiscoveriesJson(
        SafeCoreHandle core,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_poll_provider_discovery_events_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CorePollProviderDiscoveryEventsJson(
        SafeCoreHandle core,
        uint maxEvents,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_ack_provider_discovery_event_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreAckProviderDiscoveryEventJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_list_provider_discovery_compensation_steps_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreListProviderDiscoveryCompensationStepsJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_start_provider_discovery_credential_compensation_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreStartProviderDiscoveryCredentialCompensationJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_complete_provider_discovery_credential_compensation_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreCompleteProviderDiscoveryCredentialCompensationJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_fail_provider_discovery_credential_compensation_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreFailProviderDiscoveryCredentialCompensationJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_mark_provider_discovery_credential_compensation_unknown_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreMarkProviderDiscoveryCredentialCompensationUnknownJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_run_provider_discovery_assistant_turn_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreRunProviderDiscoveryAssistantTurnJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 4)]
        byte[]? credential,
        nuint credentialLength,
        byte credentialPresent,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_resume_provider_discovery_assistant_core_host_action_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreResumeProviderDiscoveryAssistantCoreHostActionJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_approve_provider_discovery_assistant_retry_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreApproveProviderDiscoveryAssistantRetryJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_request_provider_discovery_assistant_revision_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreRequestProviderDiscoveryAssistantRevisionJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_accept_provider_discovery_assistant_draft_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreAcceptProviderDiscoveryAssistantDraftJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_record_provider_discovery_assistant_failure_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreRecordProviderDiscoveryAssistantFailureJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_provider_catalog_status_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreProviderCatalogStatusJson(
        SafeCoreHandle core,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_provider_catalog_history_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreProviderCatalogHistoryJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_prepare_signed_provider_catalog_import_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CorePrepareSignedProviderCatalogImportJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] envelopeJson,
        nuint envelopeJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_activate_signed_provider_catalog_import_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreActivateSignedProviderCatalogImportJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 4)]
        byte[] envelopeJson,
        nuint envelopeJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_diff_provider_catalog_revisions_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreDiffProviderCatalogRevisionsJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_prepare_provider_catalog_rollback_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CorePrepareProviderCatalogRollbackJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_activate_provider_catalog_rollback_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreActivateProviderCatalogRollbackJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_list_generation_presets_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreListGenerationPresetsJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] modelRouteId,
        nuint modelRouteIdLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_upsert_generation_preset_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreUpsertGenerationPresetJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_validate_generation_preset_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreValidateGenerationPresetJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_validate_generation_preset_candidate_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreValidateGenerationPresetCandidateJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_render_reasoning_control_candidate_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreRenderReasoningControlCandidateJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_render_prompt_cache_control_candidate_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreRenderPromptCacheControlCandidateJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_preview_provider_request_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CorePreviewProviderRequestJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_preview_provider_request_candidate_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CorePreviewProviderRequestCandidateJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_delete_generation_preset_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreDeleteGenerationPresetJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_select_generation_target_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreSelectGenerationTargetJson(
        SafeCoreHandle core,
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 2)]
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

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
