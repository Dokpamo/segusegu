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

    public NativeBuffer SendMessageWithTargetJson(
        SafeCoreHandle core,
        byte[] requestJson,
        byte[]? credential)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CoreSendMessageWithTargetJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length),
            credential,
            checked((nuint)(credential?.Length ?? 0)),
            credential is null ? (byte)0 : (byte)1,
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_send_message_with_target_json",
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

    public NativeBuffer GetProviderTemplatesJson(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);

        var status = NativeMethods.CoreListProviderTemplatesJson(
            core,
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_list_provider_templates_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer CreateProviderConnectionJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CoreCreateProviderConnectionJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_create_provider_connection_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer GetProviderConnectionsJson(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);

        var status = NativeMethods.CoreListProviderConnectionsJson(
            core,
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_list_provider_connections_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer UpsertProviderConnectionJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CoreUpsertProviderConnectionJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_upsert_provider_connection_json",
            status,
            buffer,
            core);
    }

    public void DeleteProviderConnectionJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CoreDeleteProviderConnectionJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length));
        ThrowIfFailed(
            "lorepia_core_delete_provider_connection_json",
            status,
            core);
    }

    public NativeBuffer GetModelRoutesJson(
        SafeCoreHandle core,
        byte[] connectionId)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(connectionId);

        var status = NativeMethods.CoreListModelRoutesJson(
            core,
            connectionId,
            checked((nuint)connectionId.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_list_model_routes_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer UpsertModelRouteJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CoreUpsertModelRouteJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_upsert_model_route_json",
            status,
            buffer,
            core);
    }

    public void DeleteModelRouteJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CoreDeleteModelRouteJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length));
        ThrowIfFailed(
            "lorepia_core_delete_model_route_json",
            status,
            core);
    }

    public NativeBuffer GetCapabilityObservationsJson(
        SafeCoreHandle core,
        byte[] modelRouteId)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(modelRouteId);

        var status = NativeMethods.CoreListCapabilityObservationsJson(
            core,
            modelRouteId,
            checked((nuint)modelRouteId.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_list_capability_observations_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer GetEffectiveCapabilityJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CoreGetEffectiveCapabilityJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_get_effective_capability_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer GetEffectiveParameterSpecsJson(
        SafeCoreHandle core,
        byte[] modelRouteId)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(modelRouteId);

        var status = NativeMethods.CoreEffectiveParameterSpecsJson(
            core,
            modelRouteId,
            checked((nuint)modelRouteId.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_effective_parameter_specs_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer UpsertUserCapabilityOverrideJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CoreUpsertUserCapabilityOverrideJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_upsert_user_capability_override_json",
            status,
            buffer,
            core);
    }

    public void DeleteUserCapabilityOverrideJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CoreDeleteUserCapabilityOverrideJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length));
        ThrowIfFailed(
            "lorepia_core_delete_user_capability_override_json",
            status,
            core);
    }

    public NativeBuffer RefreshProviderModelsJson(
        SafeCoreHandle core,
        byte[] requestJson,
        byte[]? credential)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CoreRefreshProviderModelsJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length),
            credential,
            checked((nuint)(credential?.Length ?? 0)),
            credential is null ? (byte)0 : (byte)1,
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_refresh_provider_models_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer StartProviderModelSyncJson(
        SafeCoreHandle core,
        byte[] requestJson,
        byte[]? credential)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CoreStartProviderModelSyncJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length),
            credential,
            checked((nuint)(credential?.Length ?? 0)),
            credential is null ? (byte)0 : (byte)1,
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_start_provider_model_sync_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer GetProviderModelSyncJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CoreGetProviderModelSyncJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_get_provider_model_sync_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer ListProviderModelSyncsJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CoreListProviderModelSyncsJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_list_provider_model_syncs_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer ApproveProviderModelSyncJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CoreApproveProviderModelSyncJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_approve_provider_model_sync_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer CancelProviderModelSyncJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CoreCancelProviderModelSyncJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_cancel_provider_model_sync_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer PollProviderModelSyncJobEventsJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status =
            NativeMethods.CorePollProviderModelSyncJobEventsJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_poll_provider_model_sync_job_events_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer AckProviderModelSyncEventJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CoreAckProviderModelSyncEventJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_ack_provider_model_sync_event_json",
            status,
            buffer,
            core);
    }

    public (NativeBuffer Metadata, NativeBuffer Credential)
        InspectProviderCurlJson(
            SafeCoreHandle core,
            byte[] requestJson,
            byte[] rawCurl)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);
        ArgumentNullException.ThrowIfNull(rawCurl);
        NativeBufferValue metadata = default;
        NativeBufferValue credential = default;
        var status = NativeMethods.CoreInspectProviderCurlJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length),
            rawCurl,
            checked((nuint)rawCurl.Length),
            out metadata,
            out credential);
        if (status != NativeStatus.Success)
        {
            if (metadata.Pointer != IntPtr.Zero
                || metadata.Length != 0)
            {
                NativeMethods.BufferFree(metadata);
            }
            if (credential.Pointer != IntPtr.Zero
                || credential.Length != 0)
            {
                NativeMethods.BufferFree(credential);
            }
            throw CreateFailure(
                "lorepia_core_inspect_provider_curl_json",
                status,
                core);
        }
        return (
            new NativeBuffer(metadata, NativeMethods.BufferFree),
            new NativeBuffer(credential, NativeMethods.BufferFree));
    }

    public NativeBuffer BeginProviderDiscoveryJson(
        SafeCoreHandle core,
        byte[] requestJson,
        byte[]? rawCurl) =>
        InvokeOptionalBytesJson(
            "lorepia_core_begin_provider_discovery_json",
            core,
            requestJson,
            rawCurl,
            NativeMethods.CoreBeginProviderDiscoveryJson);

    public NativeBuffer PrepareProviderDiscoveryActionJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        InvokeRequestJson(
            "lorepia_core_prepare_provider_discovery_action_json",
            core,
            requestJson,
            NativeMethods.CorePrepareProviderDiscoveryActionJson);

    public NativeBuffer GetProviderDiscoveryJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        InvokeRequestJson(
            "lorepia_core_get_provider_discovery_json",
            core,
            requestJson,
            NativeMethods.CoreGetProviderDiscoveryJson);

    public NativeBuffer ListProviderDiscoveriesJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        InvokeRequestJson(
            "lorepia_core_list_provider_discoveries_json",
            core,
            requestJson,
            NativeMethods.CoreListProviderDiscoveriesJson);

    public NativeBuffer ListProviderDiscoveryCandidatesJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        InvokeRequestJson(
            "lorepia_core_list_provider_discovery_candidates_json",
            core,
            requestJson,
            NativeMethods.CoreListProviderDiscoveryCandidatesJson);

    public NativeBuffer ListProviderDiscoveryEvidenceJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        InvokeRequestJson(
            "lorepia_core_list_provider_discovery_evidence_json",
            core,
            requestJson,
            NativeMethods.CoreListProviderDiscoveryEvidenceJson);

    public NativeBuffer ListProviderDiscoveryApprovalsJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        InvokeRequestJson(
            "lorepia_core_list_provider_discovery_approvals_json",
            core,
            requestJson,
            NativeMethods.CoreListProviderDiscoveryApprovalsJson);

    public NativeBuffer GetProviderDiscoveryReviewJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        InvokeRequestJson(
            "lorepia_core_get_provider_discovery_review_json",
            core,
            requestJson,
            NativeMethods.CoreGetProviderDiscoveryReviewJson);

    public NativeBuffer GetProviderDiscoveryApprovalProposalJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        InvokeRequestJson(
            "lorepia_core_get_provider_discovery_approval_proposal_json",
            core,
            requestJson,
            NativeMethods.CoreGetProviderDiscoveryApprovalProposalJson);

    public NativeBuffer GetProviderDiscoveryReviewProposalJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        InvokeRequestJson(
            "lorepia_core_get_provider_discovery_review_proposal_json",
            core,
            requestJson,
            NativeMethods.CoreGetProviderDiscoveryReviewProposalJson);

    public NativeBuffer ContinueProviderDiscoveryJson(
        SafeCoreHandle core,
        byte[] requestJson,
        byte[]? credential) =>
        InvokeOptionalBytesJson(
            "lorepia_core_continue_provider_discovery_json",
            core,
            requestJson,
            credential,
            NativeMethods.CoreContinueProviderDiscoveryJson);

    public NativeBuffer SupplyProviderDiscoveryEvidenceJson(
        SafeCoreHandle core,
        byte[] requestJson,
        byte[]? rawCurl) =>
        InvokeOptionalBytesJson(
            "lorepia_core_supply_provider_discovery_evidence_json",
            core,
            requestJson,
            rawCurl,
            NativeMethods.CoreSupplyProviderDiscoveryEvidenceJson);

    public NativeBuffer CancelProviderDiscoveryJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        InvokeRequestJson(
            "lorepia_core_cancel_provider_discovery_json",
            core,
            requestJson,
            NativeMethods.CoreCancelProviderDiscoveryJson);

    public NativeBuffer CommitProviderDiscoveryJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        InvokeRequestJson(
            "lorepia_core_commit_provider_discovery_json",
            core,
            requestJson,
            NativeMethods.CoreCommitProviderDiscoveryJson);

    public NativeBuffer RecoverProviderDiscoveriesJson(
        SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);
        var status =
            NativeMethods.CoreRecoverProviderDiscoveriesJson(
                core,
                out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_recover_provider_discoveries_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer PollProviderDiscoveryEventsJson(
        SafeCoreHandle core,
        uint maxEvents)
    {
        ArgumentNullException.ThrowIfNull(core);
        var status =
            NativeMethods.CorePollProviderDiscoveryEventsJson(
                core,
                maxEvents,
                out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_poll_provider_discovery_events_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer AckProviderDiscoveryEventJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        InvokeRequestJson(
            "lorepia_core_ack_provider_discovery_event_json",
            core,
            requestJson,
            NativeMethods.CoreAckProviderDiscoveryEventJson);

    public NativeBuffer ListProviderDiscoveryCompensationStepsJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        InvokeRequestJson(
            "lorepia_core_list_provider_discovery_compensation_steps_json",
            core,
            requestJson,
            NativeMethods.CoreListProviderDiscoveryCompensationStepsJson);

    public NativeBuffer StartProviderDiscoveryCredentialCompensationJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        InvokeRequestJson(
            "lorepia_core_start_provider_discovery_credential_compensation_json",
            core,
            requestJson,
            NativeMethods.CoreStartProviderDiscoveryCredentialCompensationJson);

    public NativeBuffer CompleteProviderDiscoveryCredentialCompensationJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        InvokeRequestJson(
            "lorepia_core_complete_provider_discovery_credential_compensation_json",
            core,
            requestJson,
            NativeMethods.CoreCompleteProviderDiscoveryCredentialCompensationJson);

    public NativeBuffer FailProviderDiscoveryCredentialCompensationJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        InvokeRequestJson(
            "lorepia_core_fail_provider_discovery_credential_compensation_json",
            core,
            requestJson,
            NativeMethods.CoreFailProviderDiscoveryCredentialCompensationJson);

    public NativeBuffer MarkProviderDiscoveryCredentialCompensationUnknownJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        InvokeRequestJson(
            "lorepia_core_mark_provider_discovery_credential_compensation_unknown_json",
            core,
            requestJson,
            NativeMethods.CoreMarkProviderDiscoveryCredentialCompensationUnknownJson);

    public NativeBuffer RunProviderDiscoveryAssistantTurnJson(
        SafeCoreHandle core,
        byte[] requestJson,
        byte[]? credential) =>
        InvokeOptionalBytesJson(
            "lorepia_core_run_provider_discovery_assistant_turn_json",
            core,
            requestJson,
            credential,
            NativeMethods.CoreRunProviderDiscoveryAssistantTurnJson);

    public NativeBuffer ResumeProviderDiscoveryAssistantCoreHostActionJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        InvokeRequestJson(
            "lorepia_core_resume_provider_discovery_assistant_core_host_action_json",
            core,
            requestJson,
            NativeMethods.CoreResumeProviderDiscoveryAssistantCoreHostActionJson);

    public NativeBuffer ApproveProviderDiscoveryAssistantRetryJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        InvokeRequestJson(
            "lorepia_core_approve_provider_discovery_assistant_retry_json",
            core,
            requestJson,
            NativeMethods.CoreApproveProviderDiscoveryAssistantRetryJson);

    public NativeBuffer RequestProviderDiscoveryAssistantRevisionJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        InvokeRequestJson(
            "lorepia_core_request_provider_discovery_assistant_revision_json",
            core,
            requestJson,
            NativeMethods.CoreRequestProviderDiscoveryAssistantRevisionJson);

    public NativeBuffer AcceptProviderDiscoveryAssistantDraftJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        InvokeRequestJson(
            "lorepia_core_accept_provider_discovery_assistant_draft_json",
            core,
            requestJson,
            NativeMethods.CoreAcceptProviderDiscoveryAssistantDraftJson);

    public NativeBuffer RecordProviderDiscoveryAssistantFailureJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        InvokeRequestJson(
            "lorepia_core_record_provider_discovery_assistant_failure_json",
            core,
            requestJson,
            NativeMethods.CoreRecordProviderDiscoveryAssistantFailureJson);

    public NativeBuffer GetProviderCatalogStatusJson(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);

        var status = NativeMethods.CoreProviderCatalogStatusJson(
            core,
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_provider_catalog_status_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer GetProviderCatalogHistoryJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CoreProviderCatalogHistoryJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_provider_catalog_history_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer PrepareSignedProviderCatalogImportJson(
        SafeCoreHandle core,
        byte[] envelopeJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(envelopeJson);

        var status =
            NativeMethods.CorePrepareSignedProviderCatalogImportJson(
                core,
                envelopeJson,
                checked((nuint)envelopeJson.Length),
                out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_prepare_signed_provider_catalog_import_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer ActivateSignedProviderCatalogImportJson(
        SafeCoreHandle core,
        byte[] requestJson,
        byte[] envelopeJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);
        ArgumentNullException.ThrowIfNull(envelopeJson);

        var status =
            NativeMethods.CoreActivateSignedProviderCatalogImportJson(
                core,
                requestJson,
                checked((nuint)requestJson.Length),
                envelopeJson,
                checked((nuint)envelopeJson.Length),
                out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_activate_signed_provider_catalog_import_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer DiffProviderCatalogRevisionsJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CoreDiffProviderCatalogRevisionsJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_diff_provider_catalog_revisions_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer PrepareProviderCatalogRollbackJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CorePrepareProviderCatalogRollbackJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_prepare_provider_catalog_rollback_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer ActivateProviderCatalogRollbackJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CoreActivateProviderCatalogRollbackJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_activate_provider_catalog_rollback_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer GetGenerationPresetsJson(
        SafeCoreHandle core,
        byte[] modelRouteId)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(modelRouteId);

        var status = NativeMethods.CoreListGenerationPresetsJson(
            core,
            modelRouteId,
            checked((nuint)modelRouteId.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_list_generation_presets_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer UpsertGenerationPresetJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CoreUpsertGenerationPresetJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_upsert_generation_preset_json",
            status,
            buffer,
            core);
    }

    public void ValidateGenerationPresetJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CoreValidateGenerationPresetJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length));
        ThrowIfFailed(
            "lorepia_core_validate_generation_preset_json",
            status,
            core);
    }

    public void ValidateGenerationPresetCandidateJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CoreValidateGenerationPresetCandidateJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length));
        ThrowIfFailed(
            "lorepia_core_validate_generation_preset_candidate_json",
            status,
            core);
    }

    public NativeBuffer RenderReasoningControlCandidateJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status =
            NativeMethods.CoreRenderReasoningControlCandidateJson(
                core,
                requestJson,
                checked((nuint)requestJson.Length),
                out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_render_reasoning_control_candidate_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer RenderPromptCacheControlCandidateJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status =
            NativeMethods.CoreRenderPromptCacheControlCandidateJson(
                core,
                requestJson,
                checked((nuint)requestJson.Length),
                out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_render_prompt_cache_control_candidate_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer PreviewProviderRequestJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CorePreviewProviderRequestJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_preview_provider_request_json",
            status,
            buffer,
            core);
    }

    public NativeBuffer PreviewProviderRequestCandidateJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CorePreviewProviderRequestCandidateJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_preview_provider_request_candidate_json",
            status,
            buffer,
            core);
    }

    public void DeleteGenerationPresetJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CoreDeleteGenerationPresetJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length));
        ThrowIfFailed(
            "lorepia_core_delete_generation_preset_json",
            status,
            core);
    }

    public NativeBuffer SelectGenerationTargetJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);

        var status = NativeMethods.CoreSelectGenerationTargetJson(
            core,
            requestJson,
            checked((nuint)requestJson.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_select_generation_target_json",
            status,
            buffer,
            core);
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

    private delegate int RequestJsonCall(
        SafeCoreHandle core,
        byte[] requestJson,
        nuint requestJsonLength,
        out NativeBufferValue buffer);

    private delegate int OptionalBytesJsonCall(
        SafeCoreHandle core,
        byte[] requestJson,
        nuint requestJsonLength,
        byte[]? value,
        nuint valueLength,
        byte valuePresent,
        out NativeBufferValue buffer);

    private static NativeBuffer InvokeRequestJson(
        string operation,
        SafeCoreHandle core,
        byte[] requestJson,
        RequestJsonCall call)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);
        var status = call(
            core,
            requestJson,
            checked((nuint)requestJson.Length),
            out var buffer);
        return OwnSuccessfulBuffer(
            operation,
            status,
            buffer,
            core);
    }

    private static NativeBuffer InvokeOptionalBytesJson(
        string operation,
        SafeCoreHandle core,
        byte[] requestJson,
        byte[]? value,
        OptionalBytesJsonCall call)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(requestJson);
        var status = call(
            core,
            requestJson,
            checked((nuint)requestJson.Length),
            value,
            checked((nuint)(value?.Length ?? 0)),
            value is null ? (byte)0 : (byte)1,
            out var buffer);
        return OwnSuccessfulBuffer(
            operation,
            status,
            buffer,
            core);
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
