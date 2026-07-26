import Foundation

#if LOREPIA_UNIFFI_GENERATED
public actor UniFfiCoreClient: CoreClient {
    private let core: LorepiaCore

    public init(dataRoot: URL) throws {
        let config = FfiCoreConfig(
            dataRoot: dataRoot.path(percentEncoded: false)
        )
        core = try LorepiaCore.open(config: config)
    }

    public func version() async throws -> String {
        coreVersion()
    }

    public func apiVersions() async throws -> CoreVersionInfo {
        let info = versionInfo()
        return CoreVersionInfo(
            coreVersion: info.coreVersion,
            coreAPIVersion: info.coreApiVersion,
            bindingAPIVersion: info.bindingApiVersion,
            chatEventVersion: info.chatEventVersion
        )
    }

    public func health() async throws -> HealthStatus {
        let report = try core.healthCheck()
        return HealthStatus(
            coreVersion: report.coreVersion,
            databaseOpen: report.databaseOpen,
            schemaVersion: report.schemaVersion,
            dataRootWritable: report.dataRootWritable,
            stagingWritable: report.stagingWritable,
            recoveryPending: report.recoveryPending,
            activeJobs: report.activeJobs
        )
    }

    public func listCharacters() async throws -> [CoreCharacter] {
        try core.listCharacters().map(Self.mapCharacter)
    }

    public func getCharacter(id: String) async throws -> CoreCharacter {
        try Self.mapCharacter(core.getCharacter(characterId: id))
    }

    public func inspectImport(stagedURL: URL) async throws -> ImportInspection {
        let inspection = try core.inspectImport(
            stagedPath: stagedURL.path(percentEncoded: false)
        )
        return ImportInspection(
            id: inspection.id,
            contentKind: inspection.contentKind,
            displayName: inspection.displayName,
            description: inspection.description,
            sourceSHA256: inspection.sourceSha256,
            sourceSize: inspection.sourceSize,
            estimatedStoredSize: inspection.estimatedStoredSize,
            assetCount: inspection.assetCount,
            warnings: inspection.warnings.map {
                ImportWarning(code: $0.code, message: $0.message)
            },
            blockedReasons: inspection.blockedReasons,
            isAllowed: inspection.isAllowed,
            representativeImage: inspection.representativeImage.map {
                ImportImagePreview(
                    logicalAssetID: $0.logicalAssetId,
                    mediaType: $0.mediaType,
                    sizeBytes: $0.sizeBytes
                )
            },
            unsupportedOptionalFields: inspection.unsupportedOptionalFields
        )
    }

    public func discardImport(inspectionID: String) async throws {
        try core.discardImport(inspectionId: inspectionID)
    }

    public func commitImport(inspectionID: String) async throws -> CoreCharacter {
        try Self.mapCharacter(core.commitImport(inspectionId: inspectionID))
    }

    public func listConversations() async throws -> [CoreConversation] {
        try core.listConversations().map(Self.mapConversation)
    }

    public func openConversation(characterID: String) async throws -> CoreConversation {
        try Self.mapConversation(core.openConversation(characterId: characterID))
    }

    public func createConversation(
        characterID: String,
        title: String,
        mode: ConversationMode
    ) async throws -> CoreConversation {
        try Self.mapConversation(
            core.createConversation(
                characterId: characterID,
                title: title,
                mode: mode.rawValue
            )
        )
    }

    public func listConversations(
        characterID: String
    ) async throws -> [CoreConversation] {
        try core.listConversationsForCharacter(
            characterId: characterID
        ).map(Self.mapConversation)
    }

    public func getConversation(id: String) async throws -> CoreConversation {
        try Self.mapConversation(
            core.getConversation(conversationId: id)
        )
    }

    public func getConversationState(
        conversationID: String
    ) async throws -> CoreConversationState {
        try Self.mapConversationState(
            core.getConversationState(conversationId: conversationID)
        )
    }

    public func listConversationBranches(
        conversationID: String
    ) async throws -> [CoreConversationBranch] {
        try core.listConversationBranches(
            conversationId: conversationID
        ).map(Self.mapConversationBranch)
    }

    public func createConversationBranch(
        conversationID: String,
        fromMessageID: String?,
        title: String?
    ) async throws -> CoreConversationBranch {
        try Self.mapConversationBranch(
            core.createConversationBranch(
                conversationId: conversationID,
                fromMessageId: fromMessageID,
                title: title
            )
        )
    }

    public func selectConversationBranch(
        conversationID: String,
        branchID: String
    ) async throws -> CoreConversationState {
        try Self.mapConversationState(
            core.selectConversationBranch(
                conversationId: conversationID,
                branchId: branchID
            )
        )
    }

    public func setConversationMode(
        conversationID: String,
        mode: ConversationMode
    ) async throws -> CoreConversationState {
        try Self.mapConversationState(
            core.setConversationMode(
                conversationId: conversationID,
                mode: mode.rawValue
            )
        )
    }

    public func listMessages(conversationID: String) async throws -> [ChatMessage] {
        try core.listMessages(
            conversationId: conversationID
        ).map(Self.mapMessage)
    }

    public func listBranchMessages(
        branchID: String
    ) async throws -> [ChatMessage] {
        try core.listBranchMessages(
            branchId: branchID
        ).map(Self.mapMessage)
    }

    public func sendMessage(
        conversationID: String,
        text: String,
        providerProfileID: String,
        credential: String?
    ) async throws -> String {
        try core.sendMessage(
            conversationId: conversationID,
            text: text,
            providerProfileId: providerProfileID,
            credential: credential
        )
    }

    public func sendMessageToBranch(
        conversationID: String,
        branchID: String,
        expectedHeadMessageID: String?,
        mode: ConversationMode,
        text: String,
        providerProfileID: String,
        credential: String?
    ) async throws -> String {
        try core.sendMessageToBranch(
            conversationId: conversationID,
            branchId: branchID,
            expectedHead: expectedHeadMessageID,
            mode: mode.rawValue,
            text: text,
            providerProfileId: providerProfileID,
            credential: credential
        )
    }

    public func cancelGeneration(generationID: String) async throws {
        try core.cancelGeneration(generationId: generationID)
    }

    public func pollEvents(maxEvents: UInt32) async throws -> ChatEventBatch {
        let batch = try core.pollEvents(maxEvents: maxEvents)
        return ChatEventBatch(
            events: batch.events.map { event in
                ChatEvent(
                    eventVersion: event.eventVersion,
                    generationID: event.generationId,
                    conversationID: event.conversationId,
                    branchID: event.branchId,
                    assistantMessageID: event.assistantMessageId,
                    sequence: event.sequence,
                    emittedAt: event.emittedAt,
                    kind: event.kind,
                    text: event.text,
                    messageID: event.messageId,
                    messageStatus: event.messageStatus,
                    errorCode: event.errorCode,
                    errorMessage: event.errorMessage,
                    usageInputTokens: event.usageInputTokens,
                    usageOutputTokens: event.usageOutputTokens
                )
            },
            droppedEventCount: batch.droppedEventCount
        )
    }

    public func listProviderProfiles() async throws -> [ProviderProfile] {
        try core.listProviderProfiles().map(Self.mapProviderProfile)
    }

    public func upsertProviderProfile(
        _ profile: ProviderProfile
    ) async throws -> ProviderProfile {
        let saved = try core.upsertProviderProfile(
            profile: FfiProviderProfile(
                id: profile.id,
                displayName: profile.displayName,
                baseUrl: profile.baseURL,
                model: profile.model,
                timeoutSeconds: profile.timeoutSeconds
            )
        )
        return Self.mapProviderProfile(saved)
    }

    public func deleteProviderProfile(id: String) async throws {
        try core.deleteProviderProfile(profileId: id)
    }

    public func getSettings() async throws -> CoreAppSettings {
        let settings = try core.getSettings()
        return CoreAppSettings(
            preservePartialGenerations: settings.preservePartialGenerations,
            selectedProviderProfileID: settings.selectedProviderProfileId
        )
    }

    public func updateSettings(
        _ settings: CoreAppSettings
    ) async throws -> CoreAppSettings {
        let updated = try core.updateSettings(
            settings: FfiAppSettings(
                preservePartialGenerations: settings.preservePartialGenerations,
                selectedProviderProfileId: settings.selectedProviderProfileID
            )
        )
        return CoreAppSettings(
            preservePartialGenerations: updated.preservePartialGenerations,
            selectedProviderProfileID: updated.selectedProviderProfileId
        )
    }

    public func databaseStats() async throws -> DatabaseStats {
        let stats = try core.databaseStats()
        return DatabaseStats(
            characters: stats.characters,
            conversations: stats.conversations,
            messages: stats.messages,
            pendingImports: stats.pendingImports
        )
    }

    private static func mapCharacter(_ character: FfiCharacter) -> CoreCharacter {
        CoreCharacter(
            id: character.id,
            name: character.name,
            description: character.description,
            sourceHash: character.sourceHash,
            avatarAssetHash: character.avatarAssetHash,
            createdAt: character.createdAt
        )
    }

    private static func mapConversation(
        _ conversation: FfiConversation
    ) -> CoreConversation {
        CoreConversation(
            id: conversation.id,
            characterID: conversation.characterId,
            title: conversation.title,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt
        )
    }

    private static func mapConversationBranch(
        _ branch: FfiConversationBranch
    ) -> CoreConversationBranch {
        CoreConversationBranch(
            id: branch.id,
            conversationID: branch.conversationId,
            title: branch.title,
            forkMessageID: branch.forkMessageId,
            headMessageID: branch.headMessageId,
            createdAt: branch.createdAt,
            updatedAt: branch.updatedAt
        )
    }

    private static func mapConversationState(
        _ state: FfiConversationState
    ) throws -> CoreConversationState {
        guard let mode = ConversationMode(rawValue: state.selectedMode) else {
            throw CoreClientFailure.invalidResponse(
                "지원하지 않는 대화 모드입니다: \(state.selectedMode)"
            )
        }
        return CoreConversationState(
            conversationID: state.conversationId,
            activeBranchID: state.activeBranchId,
            selectedMode: mode,
            updatedAt: state.updatedAt
        )
    }

    private static func mapMessage(_ message: FfiMessage) -> ChatMessage {
        ChatMessage(
            id: message.id,
            conversationID: message.conversationId,
            parentID: message.parentId,
            role: ChatMessage.Role(rawValue: message.role) ?? .notice,
            text: message.content,
            status: ChatMessage.Status(rawValue: message.status) ?? .notice,
            generationID: message.generationId,
            createdAt: message.createdAt
        )
    }

    private static func mapProviderProfile(
        _ profile: FfiProviderProfile
    ) -> ProviderProfile {
        ProviderProfile(
            id: profile.id,
            displayName: profile.displayName,
            baseURL: profile.baseUrl,
            model: profile.model,
            timeoutSeconds: profile.timeoutSeconds
        )
    }
}
#else
public actor UniFfiCoreClient: CoreClient {
    public init(dataRoot _: URL) throws {
        throw CoreClientFailure.bindingsUnavailable
    }

    public func version() async throws -> String { try unavailable() }
    public func apiVersions() async throws -> CoreVersionInfo { try unavailable() }
    public func health() async throws -> HealthStatus { try unavailable() }
    public func listCharacters() async throws -> [CoreCharacter] { try unavailable() }
    public func getCharacter(id _: String) async throws -> CoreCharacter { try unavailable() }
    public func inspectImport(stagedURL _: URL) async throws -> ImportInspection {
        try unavailable()
    }
    public func discardImport(inspectionID _: String) async throws {
        throw CoreClientFailure.bindingsUnavailable
    }
    public func commitImport(inspectionID _: String) async throws -> CoreCharacter {
        try unavailable()
    }
    public func listConversations() async throws -> [CoreConversation] { try unavailable() }
    public func openConversation(characterID _: String) async throws -> CoreConversation {
        try unavailable()
    }
    public func createConversation(
        characterID _: String,
        title _: String,
        mode _: ConversationMode
    ) async throws -> CoreConversation {
        try unavailable()
    }
    public func listConversations(
        characterID _: String
    ) async throws -> [CoreConversation] {
        try unavailable()
    }
    public func getConversation(id _: String) async throws -> CoreConversation {
        try unavailable()
    }
    public func getConversationState(
        conversationID _: String
    ) async throws -> CoreConversationState {
        try unavailable()
    }
    public func listConversationBranches(
        conversationID _: String
    ) async throws -> [CoreConversationBranch] {
        try unavailable()
    }
    public func createConversationBranch(
        conversationID _: String,
        fromMessageID _: String?,
        title _: String?
    ) async throws -> CoreConversationBranch {
        try unavailable()
    }
    public func selectConversationBranch(
        conversationID _: String,
        branchID _: String
    ) async throws -> CoreConversationState {
        try unavailable()
    }
    public func setConversationMode(
        conversationID _: String,
        mode _: ConversationMode
    ) async throws -> CoreConversationState {
        try unavailable()
    }
    public func listMessages(conversationID _: String) async throws -> [ChatMessage] {
        try unavailable()
    }
    public func listBranchMessages(
        branchID _: String
    ) async throws -> [ChatMessage] {
        try unavailable()
    }
    public func sendMessage(
        conversationID _: String,
        text _: String,
        providerProfileID _: String,
        credential _: String?
    ) async throws -> String {
        try unavailable()
    }
    public func sendMessageToBranch(
        conversationID _: String,
        branchID _: String,
        expectedHeadMessageID _: String?,
        mode _: ConversationMode,
        text _: String,
        providerProfileID _: String,
        credential _: String?
    ) async throws -> String {
        try unavailable()
    }
    public func cancelGeneration(generationID _: String) async throws {
        throw CoreClientFailure.bindingsUnavailable
    }
    public func pollEvents(maxEvents _: UInt32) async throws -> ChatEventBatch {
        try unavailable()
    }
    public func listProviderProfiles() async throws -> [ProviderProfile] { try unavailable() }
    public func upsertProviderProfile(
        _ profile: ProviderProfile
    ) async throws -> ProviderProfile {
        try unavailable()
    }
    public func deleteProviderProfile(id _: String) async throws {
        throw CoreClientFailure.bindingsUnavailable
    }
    public func getSettings() async throws -> CoreAppSettings { try unavailable() }
    public func updateSettings(
        _ settings: CoreAppSettings
    ) async throws -> CoreAppSettings {
        try unavailable()
    }
    public func databaseStats() async throws -> DatabaseStats { try unavailable() }

    private func unavailable<T>() throws -> T {
        throw CoreClientFailure.bindingsUnavailable
    }
}
#endif

public enum CoreClientFactory {
    public static func make(dataRoot: URL) -> CoreClientSelection {
        #if LOREPIA_UNIFFI_GENERATED
        do {
            return CoreClientSelection(
                client: try UniFfiCoreClient(dataRoot: dataRoot),
                mode: .live
            )
        } catch {
            let message = String(describing: error)
            return CoreClientSelection(
                client: UnavailableCoreClient(message: message),
                mode: .unavailable(message)
            )
        }
        #else
        let message = CoreClientFailure.bindingsUnavailable.localizedDescription
        return CoreClientSelection(
            client: UnavailableCoreClient(message: message),
            mode: .unavailable(message)
        )
        #endif
    }
}
