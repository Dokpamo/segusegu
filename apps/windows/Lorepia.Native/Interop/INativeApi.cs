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

    void CancelGeneration(SafeCoreHandle core, byte[] generationId);

    NativeBuffer PollEventsJson(SafeCoreHandle core, uint maxEvents);

    NativeBuffer GetSettingsJson(SafeCoreHandle core);

    void UpdateSettingsJson(SafeCoreHandle core, byte[] settingsJson);

    NativeBuffer GetProviderProfilesJson(SafeCoreHandle core);

    NativeBuffer UpsertProviderProfileJson(
        SafeCoreHandle core,
        byte[] profileJson);

    void DeleteProviderProfile(SafeCoreHandle core, byte[] profileId);
}
