namespace Lorepia.Native.Interop;

internal interface INativeApi
{
    uint GetAbiVersion();

    SafeCoreHandle CreateCore(byte[] configurationJson);

    NativeBuffer GetCoreVersion(SafeCoreHandle core);

    NativeBuffer GetHealthCheckJson(SafeCoreHandle core);

    NativeBuffer InspectImportJson(SafeCoreHandle core, byte[] stagedPath);

    NativeBuffer CommitImportJson(SafeCoreHandle core, byte[] inspectionId);

    void DiscardImport(SafeCoreHandle core, byte[] inspectionId);

    NativeBuffer GetCharactersJson(SafeCoreHandle core);

    NativeBuffer GetCharacterJson(SafeCoreHandle core, byte[] characterId);

    NativeBuffer OpenConversationJson(SafeCoreHandle core, byte[] characterId);

    NativeBuffer GetConversationsJson(SafeCoreHandle core);

    NativeBuffer GetMessagesJson(SafeCoreHandle core, byte[] conversationId);

    NativeBuffer SendMessageJson(
        SafeCoreHandle core,
        byte[] conversationId,
        byte[] text,
        byte[] providerProfileId,
        byte[]? credential);

    NativeBuffer SendMessageWithTargetJson(
        SafeCoreHandle core,
        byte[] requestJson,
        byte[]? credential);

    void CancelGeneration(SafeCoreHandle core, byte[] generationId);

    NativeBuffer PollEventsJson(SafeCoreHandle core, uint maxEvents);

    NativeBuffer GetSettingsJson(SafeCoreHandle core);

    void UpdateSettingsJson(SafeCoreHandle core, byte[] settingsJson);

    NativeBuffer GetProviderTemplatesJson(SafeCoreHandle core);

    NativeBuffer CreateProviderConnectionJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer GetProviderConnectionsJson(SafeCoreHandle core);

    NativeBuffer UpsertProviderConnectionJson(
        SafeCoreHandle core,
        byte[] requestJson);

    void DeleteProviderConnectionJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer GetModelRoutesJson(
        SafeCoreHandle core,
        byte[] connectionId);

    NativeBuffer UpsertModelRouteJson(
        SafeCoreHandle core,
        byte[] requestJson);

    void DeleteModelRouteJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer GetCapabilityObservationsJson(
        SafeCoreHandle core,
        byte[] modelRouteId);

    NativeBuffer GetEffectiveCapabilityJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer GetEffectiveParameterSpecsJson(
        SafeCoreHandle core,
        byte[] modelRouteId);

    NativeBuffer UpsertUserCapabilityOverrideJson(
        SafeCoreHandle core,
        byte[] requestJson);

    void DeleteUserCapabilityOverrideJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer RefreshProviderModelsJson(
        SafeCoreHandle core,
        byte[] requestJson,
        byte[]? credential);

    NativeBuffer StartProviderModelSyncJson(
        SafeCoreHandle core,
        byte[] requestJson,
        byte[]? credential);

    NativeBuffer GetProviderModelSyncJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer ListProviderModelSyncsJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer ApproveProviderModelSyncJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer CancelProviderModelSyncJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer PollProviderModelSyncJobEventsJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer AckProviderModelSyncEventJson(
        SafeCoreHandle core,
        byte[] requestJson);

    (NativeBuffer Metadata, NativeBuffer Credential)
        InspectProviderCurlJson(
            SafeCoreHandle core,
            byte[] requestJson,
            byte[] rawCurl);

    NativeBuffer BeginProviderDiscoveryJson(
        SafeCoreHandle core,
        byte[] requestJson,
        byte[]? rawCurl);

    NativeBuffer PrepareProviderDiscoveryActionJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer GetProviderDiscoveryJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer ListProviderDiscoveriesJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer ListProviderDiscoveryCandidatesJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer ListProviderDiscoveryEvidenceJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer ListProviderDiscoveryApprovalsJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer GetProviderDiscoveryReviewJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer GetProviderDiscoveryApprovalProposalJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer GetProviderDiscoveryReviewProposalJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer ContinueProviderDiscoveryJson(
        SafeCoreHandle core,
        byte[] requestJson,
        byte[]? credential);

    NativeBuffer SupplyProviderDiscoveryEvidenceJson(
        SafeCoreHandle core,
        byte[] requestJson,
        byte[]? rawCurl);

    NativeBuffer CancelProviderDiscoveryJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer CommitProviderDiscoveryJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer RecoverProviderDiscoveriesJson(SafeCoreHandle core);

    NativeBuffer PollProviderDiscoveryEventsJson(
        SafeCoreHandle core,
        uint maxEvents);

    NativeBuffer AckProviderDiscoveryEventJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer ListProviderDiscoveryCompensationStepsJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer StartProviderDiscoveryCredentialCompensationJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer CompleteProviderDiscoveryCredentialCompensationJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer FailProviderDiscoveryCredentialCompensationJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer MarkProviderDiscoveryCredentialCompensationUnknownJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer RunProviderDiscoveryAssistantTurnJson(
        SafeCoreHandle core,
        byte[] requestJson,
        byte[]? credential);

    NativeBuffer ResumeProviderDiscoveryAssistantCoreHostActionJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer ApproveProviderDiscoveryAssistantRetryJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer RequestProviderDiscoveryAssistantRevisionJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer AcceptProviderDiscoveryAssistantDraftJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer RecordProviderDiscoveryAssistantFailureJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer GetProviderCatalogStatusJson(SafeCoreHandle core);

    NativeBuffer GetProviderCatalogHistoryJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer PrepareSignedProviderCatalogImportJson(
        SafeCoreHandle core,
        byte[] envelopeJson);

    NativeBuffer ActivateSignedProviderCatalogImportJson(
        SafeCoreHandle core,
        byte[] requestJson,
        byte[] envelopeJson);

    NativeBuffer DiffProviderCatalogRevisionsJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer PrepareProviderCatalogRollbackJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer ActivateProviderCatalogRollbackJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer GetGenerationPresetsJson(
        SafeCoreHandle core,
        byte[] modelRouteId);

    NativeBuffer UpsertGenerationPresetJson(
        SafeCoreHandle core,
        byte[] requestJson);

    void ValidateGenerationPresetJson(
        SafeCoreHandle core,
        byte[] requestJson);

    void ValidateGenerationPresetCandidateJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer RenderReasoningControlCandidateJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer RenderPromptCacheControlCandidateJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer PreviewProviderRequestJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer PreviewProviderRequestCandidateJson(
        SafeCoreHandle core,
        byte[] requestJson);

    void DeleteGenerationPresetJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer SelectGenerationTargetJson(
        SafeCoreHandle core,
        byte[] requestJson);

    NativeBuffer GetProviderProfilesJson(SafeCoreHandle core);

    NativeBuffer UpsertProviderProfileJson(
        SafeCoreHandle core,
        byte[] profileJson);

    void DeleteProviderProfile(SafeCoreHandle core, byte[] profileId);
}
