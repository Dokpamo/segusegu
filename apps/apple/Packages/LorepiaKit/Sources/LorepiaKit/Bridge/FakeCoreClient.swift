import Foundation

/// A deterministic in-memory implementation for unit tests and SwiftUI previews.
///
/// Production app construction never selects this client automatically.
public actor FakeCoreClient: CoreClient {
    private let reportedVersion: String
    private let reportedHealth: HealthStatus
    private var characters: [CoreCharacter]
    private var inspections: [String: ImportInspection] = [:]
    private var conversations: [CoreConversation] = []
    private var messagesByConversation: [String: [ChatMessage]] = [:]
    private var profiles: [ProviderProfile]
    private var settings: CoreAppSettings
    private var events: [ChatEvent] = []
    private var droppedEventCount: UInt64 = 0
    private var commitFailuresRemaining: UInt

    public init(
        version: String = "lorepia-core-preview/0.1.0",
        health: HealthStatus? = nil,
        characters: [CoreCharacter]? = nil,
        profiles: [ProviderProfile]? = nil,
        commitFailuresBeforeSuccess: UInt = 0
    ) {
        reportedVersion = version
        reportedHealth = health ?? HealthStatus(
            coreVersion: version,
            databaseOpen: true,
            schemaVersion: 1,
            dataRootWritable: true,
            stagingWritable: true,
            recoveryPending: false,
            activeJobs: 0
        )
        self.characters = characters ?? LibraryCharacter.previewCharacters.map {
            CoreCharacter(
                id: $0.id,
                name: $0.name,
                description: $0.summary,
                sourceHash: "synthetic-\($0.id)",
                avatarAssetHash: nil,
                createdAt: "2026-01-01T00:00:00Z"
            )
        }
        let defaultProfile = ProviderProfile(
            id: "preview-provider",
            displayName: "Preview Provider",
            baseURL: "https://example.invalid/v1",
            model: "preview-model",
            timeoutSeconds: 30
        )
        self.profiles = profiles ?? [defaultProfile]
        settings = CoreAppSettings(
            preservePartialGenerations: true,
            selectedProviderProfileID: (profiles ?? [defaultProfile]).first?.id
        )
        commitFailuresRemaining = commitFailuresBeforeSuccess
    }

    public func version() async throws -> String {
        reportedVersion
    }

    public func apiVersions() async throws -> CoreVersionInfo {
        CoreVersionInfo(
            coreVersion: reportedVersion,
            coreAPIVersion: 1,
            bindingAPIVersion: 2,
            chatEventVersion: 1
        )
    }

    public func health() async throws -> HealthStatus {
        reportedHealth
    }

    public func listCharacters() async throws -> [CoreCharacter] {
        characters
    }

    public func getCharacter(id: String) async throws -> CoreCharacter {
        guard let character = characters.first(where: { $0.id == id }) else {
            throw CoreClientFailure.invalidResponse("캐릭터가 없습니다.")
        }
        return character
    }

    public func inspectImport(stagedURL: URL) async throws -> ImportInspection {
        let id = UUID().uuidString
        let inspection = ImportInspection(
            id: id,
            contentKind: "character_card_v3",
            displayName: stagedURL.deletingPathExtension().lastPathComponent,
            description: "합성 가져오기 검사 결과",
            sourceSHA256: String(repeating: "a", count: 64),
            sourceSize: 128,
            estimatedStoredSize: 128,
            assetCount: 0,
            warnings: [],
            blockedReasons: [],
            isAllowed: true
        )
        inspections[id] = inspection
        return inspection
    }

    public func discardImport(inspectionID: String) async throws {
        inspections.removeValue(forKey: inspectionID)
    }

    public func commitImport(inspectionID: String) async throws -> CoreCharacter {
        guard let inspection = inspections[inspectionID] else {
            throw CoreClientFailure.invalidResponse("가져오기 검사가 없습니다.")
        }
        if commitFailuresRemaining > 0 {
            commitFailuresRemaining -= 1
            throw CoreClientFailure.invalidResponse("합성 커밋 실패")
        }
        inspections.removeValue(forKey: inspectionID)
        let character = CoreCharacter(
            id: UUID().uuidString,
            name: inspection.displayName,
            description: inspection.description,
            sourceHash: inspection.sourceSHA256,
            avatarAssetHash: nil,
            createdAt: "2026-01-01T00:00:00Z"
        )
        characters.append(character)
        return character
    }

    public func listConversations() async throws -> [CoreConversation] {
        conversations
    }

    public func openConversation(characterID: String) async throws -> CoreConversation {
        guard characters.contains(where: { $0.id == characterID }) else {
            throw CoreClientFailure.invalidResponse("캐릭터가 없습니다.")
        }
        let conversation = CoreConversation(
            id: UUID().uuidString,
            characterID: characterID,
            title: characters.first(where: { $0.id == characterID })?.name ?? "대화",
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z"
        )
        conversations.append(conversation)
        messagesByConversation[conversation.id] = []
        return conversation
    }

    public func listMessages(conversationID: String) async throws -> [ChatMessage] {
        messagesByConversation[conversationID] ?? []
    }

    public func sendMessage(
        conversationID: String,
        text: String,
        providerProfileID: String,
        credential _: String?
    ) async throws -> String {
        guard profiles.contains(where: { $0.id == providerProfileID }) else {
            throw CoreClientFailure.invalidResponse("프로바이더 프로필이 없습니다.")
        }
        let generationID = UUID().uuidString
        let userMessage = ChatMessage(
            conversationID: conversationID,
            role: .user,
            text: text
        )
        let assistantID = UUID().uuidString
        let assistantMessage = ChatMessage(
            id: assistantID,
            conversationID: conversationID,
            parentID: userMessage.id,
            role: .assistant,
            text: "이 응답은 테스트용 합성 메시지입니다.",
            generationID: generationID
        )
        messagesByConversation[conversationID, default: []].append(userMessage)
        messagesByConversation[conversationID, default: []].append(assistantMessage)
        events.append(contentsOf: [
            ChatEvent(
                generationID: generationID,
                conversationID: conversationID,
                sequence: 1,
                kind: "generation_started"
            ),
            ChatEvent(
                generationID: generationID,
                conversationID: conversationID,
                sequence: 2,
                kind: "text_delta",
                text: assistantMessage.text
            ),
            ChatEvent(
                generationID: generationID,
                conversationID: conversationID,
                sequence: 3,
                kind: "message_committed",
                messageID: assistantID,
                messageStatus: "complete"
            ),
            ChatEvent(
                generationID: generationID,
                conversationID: conversationID,
                sequence: 4,
                kind: "generation_finished"
            ),
        ])
        return generationID
    }

    public func cancelGeneration(generationID: String) async throws {
        guard let conversation = messagesByConversation.first(where: { entry in
            entry.value.contains(where: { $0.generationID == generationID })
        }) else {
            throw CoreClientFailure.invalidResponse("생성 작업이 없습니다.")
        }
        events.append(
            ChatEvent(
                generationID: generationID,
                conversationID: conversation.key,
                sequence: 5,
                kind: "generation_cancelled"
            )
        )
    }

    public func pollEvents(maxEvents: UInt32) async throws -> ChatEventBatch {
        let count = min(Int(maxEvents), events.count)
        let batch = Array(events.prefix(count))
        events.removeFirst(count)
        let dropped = droppedEventCount
        droppedEventCount = 0
        return ChatEventBatch(events: batch, droppedEventCount: dropped)
    }

    public func enqueueEventBatch(
        _ events: [ChatEvent],
        droppedEventCount: UInt64 = 0
    ) {
        self.events.append(contentsOf: events)
        self.droppedEventCount = self.droppedEventCount
            .saturatingAdd(droppedEventCount)
    }

    public func replaceMessagesForTesting(
        conversationID: String,
        messages: [ChatMessage]
    ) {
        messagesByConversation[conversationID] = messages
    }

    public func listProviderProfiles() async throws -> [ProviderProfile] {
        profiles
    }

    public func upsertProviderProfile(
        _ profile: ProviderProfile
    ) async throws -> ProviderProfile {
        profiles.removeAll { $0.id == profile.id }
        profiles.append(profile)
        return profile
    }

    public func deleteProviderProfile(id: String) async throws {
        profiles.removeAll { $0.id == id }
        if settings.selectedProviderProfileID == id {
            settings.selectedProviderProfileID = nil
        }
    }

    public func getSettings() async throws -> CoreAppSettings {
        settings
    }

    public func updateSettings(
        _ settings: CoreAppSettings
    ) async throws -> CoreAppSettings {
        self.settings = settings
        return settings
    }

    public func databaseStats() async throws -> DatabaseStats {
        DatabaseStats(
            characters: UInt64(characters.count),
            conversations: UInt64(conversations.count),
            messages: UInt64(messagesByConversation.values.flatMap { $0 }.count),
            pendingImports: UInt64(inspections.count)
        )
    }
}

private extension UInt64 {
    func saturatingAdd(_ other: UInt64) -> UInt64 {
        let result = addingReportingOverflow(other)
        return result.overflow ? .max : result.partialValue
    }
}

public actor UnavailableCoreClient: CoreClient {
    private let failure: CoreClientFailure

    public init(message: String) {
        failure = .startupFailed(message)
    }

    public func version() async throws -> String { try unavailable() }
    public func apiVersions() async throws -> CoreVersionInfo { try unavailable() }
    public func health() async throws -> HealthStatus { try unavailable() }
    public func listCharacters() async throws -> [CoreCharacter] { try unavailable() }
    public func getCharacter(id _: String) async throws -> CoreCharacter { try unavailable() }
    public func inspectImport(stagedURL _: URL) async throws -> ImportInspection {
        try unavailable()
    }
    public func discardImport(inspectionID _: String) async throws { throw failure }
    public func commitImport(inspectionID _: String) async throws -> CoreCharacter {
        try unavailable()
    }
    public func listConversations() async throws -> [CoreConversation] { try unavailable() }
    public func openConversation(characterID _: String) async throws -> CoreConversation {
        try unavailable()
    }
    public func listMessages(conversationID _: String) async throws -> [ChatMessage] {
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
    public func cancelGeneration(generationID _: String) async throws { throw failure }
    public func pollEvents(maxEvents _: UInt32) async throws -> ChatEventBatch {
        try unavailable()
    }
    public func listProviderProfiles() async throws -> [ProviderProfile] { try unavailable() }
    public func upsertProviderProfile(
        _ profile: ProviderProfile
    ) async throws -> ProviderProfile {
        try unavailable()
    }
    public func deleteProviderProfile(id _: String) async throws { throw failure }
    public func getSettings() async throws -> CoreAppSettings { try unavailable() }
    public func updateSettings(
        _ settings: CoreAppSettings
    ) async throws -> CoreAppSettings {
        try unavailable()
    }
    public func databaseStats() async throws -> DatabaseStats { try unavailable() }

    private func unavailable<T>() throws -> T {
        throw failure
    }
}
