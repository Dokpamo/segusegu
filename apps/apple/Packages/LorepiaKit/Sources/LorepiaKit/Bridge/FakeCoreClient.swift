import Foundation

public struct FakeConversationFixture: Sendable {
    public let conversation: CoreConversation
    public let mode: ConversationMode
    public let messages: [ChatMessage]

    public init(
        conversation: CoreConversation,
        mode: ConversationMode,
        messages: [ChatMessage]
    ) {
        self.conversation = conversation
        self.mode = mode
        self.messages = messages
    }
}

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
    private var branchesByConversation: [String: [CoreConversationBranch]] = [:]
    private var statesByConversation: [String: CoreConversationState] = [:]
    private var messagesByBranch: [String: [ChatMessage]] = [:]
    private var profiles: [ProviderProfile]
    private var settings: CoreAppSettings
    private var events: [ChatEvent] = []
    private var droppedEventCount: UInt64 = 0
    private var commitFailuresRemaining: UInt
    private var listProviderFailuresRemaining: UInt
    private let listProviderProfilesDelay: Duration?
    private let getSettingsDelay: Duration?
    private let updateSettingsDelay: Duration?
    private let initialConversationMessages: [ChatMessage]

    public init(
        version: String = "lorepia-core-preview/0.1.0",
        health: HealthStatus? = nil,
        characters: [CoreCharacter]? = nil,
        profiles: [ProviderProfile]? = nil,
        commitFailuresBeforeSuccess: UInt = 0,
        listProviderFailuresBeforeSuccess: UInt = 0,
        listProviderProfilesDelay: Duration? = nil,
        getSettingsDelay: Duration? = nil,
        updateSettingsDelay: Duration? = nil,
        initialConversationMessages: [ChatMessage] = [],
        initialConversationFixtures: [FakeConversationFixture] = []
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
        listProviderFailuresRemaining = listProviderFailuresBeforeSuccess
        self.listProviderProfilesDelay = listProviderProfilesDelay
        self.getSettingsDelay = getSettingsDelay
        self.updateSettingsDelay = updateSettingsDelay
        self.initialConversationMessages = initialConversationMessages
        settings = CoreAppSettings(
            preservePartialGenerations: true,
            selectedProviderProfileID: (profiles ?? [defaultProfile]).first?.id
        )
        commitFailuresRemaining = commitFailuresBeforeSuccess

        for fixture in initialConversationFixtures {
            let conversation = fixture.conversation
            var parentID: String?
            let seededMessages = fixture.messages.enumerated().map {
                index, template in
                let messageID = "\(conversation.id)-fixture-\(index + 1)"
                let message = ChatMessage(
                    id: messageID,
                    conversationID: conversation.id,
                    parentID: parentID,
                    role: template.role,
                    text: template.text,
                    status: template.status,
                    generationID: template.generationID == nil
                        ? nil
                        : "\(conversation.id)-fixture-generation-\(index + 1)",
                    createdAt: template.createdAt ?? conversation.updatedAt
                )
                parentID = messageID
                return message
            }
            let branch = CoreConversationBranch(
                id: "\(conversation.id)-fixture-main",
                conversationID: conversation.id,
                title: nil,
                forkMessageID: nil,
                headMessageID: seededMessages.last?.id,
                createdAt: conversation.createdAt,
                updatedAt: conversation.updatedAt
            )

            conversations.append(conversation)
            messagesByConversation[conversation.id] = seededMessages
            branchesByConversation[conversation.id] = [branch]
            messagesByBranch[branch.id] = seededMessages
            statesByConversation[conversation.id] = CoreConversationState(
                conversationID: conversation.id,
                activeBranchID: branch.id,
                selectedMode: fixture.mode,
                updatedAt: conversation.updatedAt
            )
        }
    }

    public func version() async throws -> String {
        reportedVersion
    }

    public func apiVersions() async throws -> CoreVersionInfo {
        CoreVersionInfo(
            coreVersion: reportedVersion,
            coreAPIVersion: 4,
            bindingAPIVersion: 4,
            chatEventVersion: 2
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
        guard let character = characters.first(where: { $0.id == characterID }) else {
            throw CoreClientFailure.invalidResponse("캐릭터가 없습니다.")
        }
        return try createConversationRecord(
            characterID: characterID,
            title: character.name,
            mode: .chat
        )
    }

    public func createConversation(
        characterID: String,
        title: String,
        mode: ConversationMode
    ) async throws -> CoreConversation {
        try createConversationRecord(
            characterID: characterID,
            title: title,
            mode: mode
        )
    }

    public func listConversations(
        characterID: String
    ) async throws -> [CoreConversation] {
        guard characters.contains(where: { $0.id == characterID }) else {
            throw CoreClientFailure.invalidResponse("캐릭터가 없습니다.")
        }
        return conversations.filter { $0.characterID == characterID }
    }

    public func getConversation(id: String) async throws -> CoreConversation {
        guard let conversation = conversations.first(where: { $0.id == id }) else {
            throw CoreClientFailure.invalidResponse("대화가 없습니다.")
        }
        return conversation
    }

    public func getConversationState(
        conversationID: String
    ) async throws -> CoreConversationState {
        guard let state = statesByConversation[conversationID] else {
            throw CoreClientFailure.invalidResponse("대화 상태가 없습니다.")
        }
        return state
    }

    public func listConversationBranches(
        conversationID: String
    ) async throws -> [CoreConversationBranch] {
        guard conversations.contains(where: { $0.id == conversationID }) else {
            throw CoreClientFailure.invalidResponse("대화가 없습니다.")
        }
        return branchesByConversation[conversationID] ?? []
    }

    public func createConversationBranch(
        conversationID: String,
        fromMessageID: String?,
        title: String?
    ) async throws -> CoreConversationBranch {
        guard let state = statesByConversation[conversationID],
              let sourceBranch = branchesByConversation[conversationID]?.first(
                  where: { $0.id == state.activeBranchID }
              )
        else {
            throw CoreClientFailure.invalidResponse("대화 상태가 없습니다.")
        }
        let sourceMessages = messagesByBranch[sourceBranch.id] ?? []
        let branchedMessages: [ChatMessage]
        if let fromMessageID {
            guard let index = sourceMessages.firstIndex(
                where: { $0.id == fromMessageID }
            ) else {
                throw CoreClientFailure.invalidResponse(
                    "분기 기준 메시지가 현재 흐름에 없습니다."
                )
            }
            branchedMessages = Array(sourceMessages.prefix(through: index))
        } else {
            branchedMessages = []
        }
        let branchID = UUID().uuidString
        let timestamp = Self.timestamp()
        let branch = CoreConversationBranch(
            id: branchID,
            conversationID: conversationID,
            title: title,
            forkMessageID: fromMessageID,
            headMessageID: branchedMessages.last?.id,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        branchesByConversation[conversationID, default: []].append(branch)
        messagesByBranch[branchID] = branchedMessages
        return branch
    }

    public func selectConversationBranch(
        conversationID: String,
        branchID: String
    ) async throws -> CoreConversationState {
        guard let previousState = statesByConversation[conversationID],
              branchesByConversation[conversationID]?.contains(
                  where: { $0.id == branchID }
              ) == true
        else {
            throw CoreClientFailure.invalidResponse("대화 분기가 없습니다.")
        }
        let state = CoreConversationState(
            conversationID: conversationID,
            activeBranchID: branchID,
            selectedMode: previousState.selectedMode,
            updatedAt: Self.timestamp()
        )
        statesByConversation[conversationID] = state
        messagesByConversation[conversationID] = messagesByBranch[branchID] ?? []
        return state
    }

    public func setConversationMode(
        conversationID: String,
        mode: ConversationMode
    ) async throws -> CoreConversationState {
        guard let previousState = statesByConversation[conversationID] else {
            throw CoreClientFailure.invalidResponse("대화 상태가 없습니다.")
        }
        let state = CoreConversationState(
            conversationID: conversationID,
            activeBranchID: previousState.activeBranchID,
            selectedMode: mode,
            updatedAt: Self.timestamp()
        )
        statesByConversation[conversationID] = state
        return state
    }

    public func listMessages(conversationID: String) async throws -> [ChatMessage] {
        guard let state = statesByConversation[conversationID] else {
            return messagesByConversation[conversationID] ?? []
        }
        return messagesByBranch[state.activeBranchID] ?? []
    }

    public func listBranchMessages(branchID: String) async throws -> [ChatMessage] {
        guard let messages = messagesByBranch[branchID] else {
            throw CoreClientFailure.invalidResponse("대화 분기가 없습니다.")
        }
        return messages
    }

    private func createConversationRecord(
        characterID: String,
        title: String,
        mode: ConversationMode
    ) throws -> CoreConversation {
        guard characters.contains(where: { $0.id == characterID }) else {
            throw CoreClientFailure.invalidResponse("캐릭터가 없습니다.")
        }
        let timestamp = Self.timestamp()
        let conversation = CoreConversation(
            id: UUID().uuidString,
            characterID: characterID,
            title: title,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        var parentID: String?
        let seededMessages = initialConversationMessages.enumerated().map {
            index, template in
            let messageID = "\(conversation.id)-seed-\(index + 1)"
            let message = ChatMessage(
                id: messageID,
                conversationID: conversation.id,
                parentID: parentID,
                role: template.role,
                text: template.text,
                status: template.status,
                generationID: template.generationID == nil
                    ? nil
                    : "\(conversation.id)-seed-generation-\(index + 1)",
                createdAt: template.createdAt ?? timestamp
            )
            parentID = messageID
            return message
        }
        let branch = CoreConversationBranch(
            id: UUID().uuidString,
            conversationID: conversation.id,
            title: nil,
            forkMessageID: nil,
            headMessageID: seededMessages.last?.id,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        conversations.append(conversation)
        messagesByConversation[conversation.id] = seededMessages
        branchesByConversation[conversation.id] = [branch]
        messagesByBranch[branch.id] = seededMessages
        statesByConversation[conversation.id] = CoreConversationState(
            conversationID: conversation.id,
            activeBranchID: branch.id,
            selectedMode: mode,
            updatedAt: timestamp
        )
        return conversation
    }

    public func sendMessage(
        conversationID: String,
        text: String,
        providerProfileID: String,
        credential _: String?
    ) async throws -> String {
        guard let state = statesByConversation[conversationID],
              let branch = branchesByConversation[conversationID]?.first(
                  where: { $0.id == state.activeBranchID }
              )
        else {
            throw CoreClientFailure.invalidResponse("대화 상태가 없습니다.")
        }
        return try sendMessageRecord(
            conversationID: conversationID,
            branchID: branch.id,
            expectedHeadMessageID: branch.headMessageID,
            mode: state.selectedMode,
            text: text,
            providerProfileID: providerProfileID
        )
    }

    public func sendMessageToBranch(
        conversationID: String,
        branchID: String,
        expectedHeadMessageID: String?,
        mode: ConversationMode,
        text: String,
        providerProfileID: String,
        credential _: String?
    ) async throws -> String {
        try sendMessageRecord(
            conversationID: conversationID,
            branchID: branchID,
            expectedHeadMessageID: expectedHeadMessageID,
            mode: mode,
            text: text,
            providerProfileID: providerProfileID
        )
    }

    public func editUserMessage(
        conversationID: String,
        branchID: String,
        expectedHeadMessageID: String?,
        messageID: String,
        replacementText: String,
        providerProfileID: String,
        credential _: String?
    ) async throws -> CoreMessageActionGeneration {
        guard profiles.contains(where: { $0.id == providerProfileID }) else {
            throw CoreClientFailure.invalidResponse("프로바이더 프로필이 없습니다.")
        }
        let context = try messageActionContext(
            conversationID: conversationID,
            branchID: branchID,
            expectedHeadMessageID: expectedHeadMessageID
        )
        guard let messageIndex = context.messages.firstIndex(
            where: {
                $0.id == messageID
                    && $0.role == .user
                    && $0.status == .complete
            }
        ) else {
            throw CoreClientFailure.invalidResponse("편집할 사용자 메시지가 없습니다.")
        }
        let text = replacementText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !text.isEmpty else {
            throw CoreClientFailure.invalidResponse("메시지를 입력하세요.")
        }

        let original = context.messages[messageIndex]
        var branchMessages = Array(context.messages.prefix(upTo: messageIndex))
        let generationID = UUID().uuidString
        let edited = ChatMessage(
            conversationID: conversationID,
            parentID: original.parentID,
            role: .user,
            text: text
        )
        let assistant = ChatMessage(
            conversationID: conversationID,
            parentID: edited.id,
            role: .assistant,
            text: "편집한 메시지에 대한 테스트용 합성 응답입니다.",
            generationID: generationID
        )
        branchMessages.append(contentsOf: [edited, assistant])
        let branch = installActionBranch(
            conversationID: conversationID,
            forkMessageID: original.parentID,
            messages: branchMessages
        )
        enqueueCompletedGeneration(
            generationID: generationID,
            conversationID: conversationID,
            branchID: branch.id,
            assistant: assistant
        )
        return CoreMessageActionGeneration(
            branch: branch,
            generationID: generationID
        )
    }

    public func regenerateAssistantMessage(
        conversationID: String,
        branchID: String,
        expectedHeadMessageID: String?,
        messageID: String,
        providerProfileID: String,
        credential _: String?
    ) async throws -> CoreMessageActionGeneration {
        guard profiles.contains(where: { $0.id == providerProfileID }) else {
            throw CoreClientFailure.invalidResponse("프로바이더 프로필이 없습니다.")
        }
        let context = try messageActionContext(
            conversationID: conversationID,
            branchID: branchID,
            expectedHeadMessageID: expectedHeadMessageID
        )
        guard let messageIndex = context.messages.firstIndex(
            where: {
                $0.id == messageID
                    && $0.role == .assistant
                    && $0.status != .pending
            }
        ) else {
            throw CoreClientFailure.invalidResponse("다시 생성할 응답이 없습니다.")
        }
        let original = context.messages[messageIndex]
        guard let sourceUserID = original.parentID,
              let userIndex = context.messages.firstIndex(
                  where: {
                      $0.id == sourceUserID
                          && $0.role == .user
                          && $0.status == .complete
                  }
              )
        else {
            throw CoreClientFailure.invalidResponse(
                "응답의 사용자 메시지를 찾을 수 없습니다."
            )
        }
        let sourceUser = context.messages[userIndex]

        var branchMessages = Array(context.messages.prefix(upTo: userIndex))
        let generationID = UUID().uuidString
        let copiedUser = ChatMessage(
            conversationID: conversationID,
            parentID: sourceUser.parentID,
            role: .user,
            text: sourceUser.text
        )
        let assistant = ChatMessage(
            conversationID: conversationID,
            parentID: copiedUser.id,
            role: .assistant,
            text: "다시 생성한 테스트용 합성 응답입니다.",
            generationID: generationID
        )
        branchMessages.append(contentsOf: [copiedUser, assistant])
        let branch = installActionBranch(
            conversationID: conversationID,
            forkMessageID: sourceUser.parentID,
            messages: branchMessages
        )
        enqueueCompletedGeneration(
            generationID: generationID,
            conversationID: conversationID,
            branchID: branch.id,
            assistant: assistant
        )
        return CoreMessageActionGeneration(
            branch: branch,
            generationID: generationID
        )
    }

    public func removeMessageFromBranch(
        conversationID: String,
        branchID: String,
        expectedHeadMessageID: String?,
        messageID: String
    ) async throws -> CoreConversationBranch {
        let context = try messageActionContext(
            conversationID: conversationID,
            branchID: branchID,
            expectedHeadMessageID: expectedHeadMessageID
        )
        guard let messageIndex = context.messages.firstIndex(
            where: {
                $0.id == messageID
                    && $0.status != .pending
                    && ($0.role == .user || $0.role == .assistant)
            }
        ) else {
            throw CoreClientFailure.invalidResponse("삭제할 메시지가 없습니다.")
        }

        let remainingMessages = Array(
            context.messages.prefix(upTo: messageIndex)
        )
        let timestamp = Self.timestamp()
        let updatedBranch = CoreConversationBranch(
            id: context.branch.id,
            conversationID: context.branch.conversationID,
            title: context.branch.title,
            forkMessageID: context.branch.forkMessageID,
            headMessageID: remainingMessages.last?.id,
            createdAt: context.branch.createdAt,
            updatedAt: timestamp
        )
        branchesByConversation[conversationID]?[context.branchIndex] =
            updatedBranch
        messagesByBranch[branchID] = remainingMessages
        if let state = statesByConversation[conversationID],
           state.activeBranchID == branchID
        {
            statesByConversation[conversationID] = CoreConversationState(
                conversationID: conversationID,
                activeBranchID: branchID,
                selectedMode: state.selectedMode,
                updatedAt: timestamp
            )
            messagesByConversation[conversationID] = remainingMessages
        }
        touchConversation(conversationID: conversationID, timestamp: timestamp)
        return updatedBranch
    }

    private func messageActionContext(
        conversationID: String,
        branchID: String,
        expectedHeadMessageID: String?
    ) throws -> (
        branchIndex: Int,
        branch: CoreConversationBranch,
        messages: [ChatMessage]
    ) {
        guard let branchIndex = branchesByConversation[conversationID]?.firstIndex(
            where: { $0.id == branchID }
        ), let branch = branchesByConversation[conversationID]?[branchIndex]
        else {
            throw CoreClientFailure.invalidResponse("대화 분기가 없습니다.")
        }
        guard branch.headMessageID == expectedHeadMessageID else {
            throw CoreClientFailure.invalidResponse(
                "다른 기기나 흐름에서 대화가 먼저 변경되었습니다."
            )
        }
        guard statesByConversation[conversationID]?.activeBranchID == branchID else {
            throw CoreClientFailure.invalidResponse(
                "현재 선택된 대화 흐름이 변경되었습니다."
            )
        }
        let messages = messagesByBranch[branchID] ?? []
        if let headMessageID = branch.headMessageID,
           messages.first(where: { $0.id == headMessageID })?.status == .pending
        {
            throw CoreClientFailure.invalidResponse(
                "응답 생성 중에는 메시지를 변경할 수 없습니다."
            )
        }
        return (
            branchIndex,
            branch,
            messages
        )
    }

    private func installActionBranch(
        conversationID: String,
        forkMessageID: String?,
        messages: [ChatMessage]
    ) -> CoreConversationBranch {
        let timestamp = Self.timestamp()
        let branch = CoreConversationBranch(
            id: UUID().uuidString,
            conversationID: conversationID,
            title: nil,
            forkMessageID: forkMessageID,
            headMessageID: messages.last?.id,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        branchesByConversation[conversationID, default: []].append(branch)
        messagesByBranch[branch.id] = messages
        if let state = statesByConversation[conversationID] {
            statesByConversation[conversationID] = CoreConversationState(
                conversationID: conversationID,
                activeBranchID: branch.id,
                selectedMode: state.selectedMode,
                updatedAt: timestamp
            )
        }
        messagesByConversation[conversationID] = messages
        touchConversation(conversationID: conversationID, timestamp: timestamp)
        return branch
    }

    private func enqueueCompletedGeneration(
        generationID: String,
        conversationID: String,
        branchID: String,
        assistant: ChatMessage
    ) {
        events.append(contentsOf: [
            ChatEvent(
                eventVersion: 2,
                generationID: generationID,
                conversationID: conversationID,
                branchID: branchID,
                assistantMessageID: assistant.id,
                sequence: 1,
                kind: "generation_started"
            ),
            ChatEvent(
                eventVersion: 2,
                generationID: generationID,
                conversationID: conversationID,
                branchID: branchID,
                assistantMessageID: assistant.id,
                sequence: 2,
                kind: "text_delta",
                text: assistant.text
            ),
            ChatEvent(
                eventVersion: 2,
                generationID: generationID,
                conversationID: conversationID,
                branchID: branchID,
                assistantMessageID: assistant.id,
                sequence: 3,
                kind: "message_committed",
                messageID: assistant.id,
                messageStatus: "complete"
            ),
            ChatEvent(
                eventVersion: 2,
                generationID: generationID,
                conversationID: conversationID,
                branchID: branchID,
                assistantMessageID: assistant.id,
                sequence: 4,
                kind: "generation_finished"
            ),
        ])
    }

    private func touchConversation(
        conversationID: String,
        timestamp: String
    ) {
        guard let conversationIndex = conversations.firstIndex(
            where: { $0.id == conversationID }
        ) else {
            return
        }
        let conversation = conversations[conversationIndex]
        conversations[conversationIndex] = CoreConversation(
            id: conversation.id,
            characterID: conversation.characterID,
            title: conversation.title,
            createdAt: conversation.createdAt,
            updatedAt: timestamp
        )
    }

    private func sendMessageRecord(
        conversationID: String,
        branchID: String,
        expectedHeadMessageID: String?,
        mode: ConversationMode,
        text: String,
        providerProfileID: String
    ) throws -> String {
        guard profiles.contains(where: { $0.id == providerProfileID }) else {
            throw CoreClientFailure.invalidResponse("프로바이더 프로필이 없습니다.")
        }
        guard let branchIndex = branchesByConversation[conversationID]?.firstIndex(
            where: { $0.id == branchID }
        ), let branch = branchesByConversation[conversationID]?[branchIndex]
        else {
            throw CoreClientFailure.invalidResponse("대화 분기가 없습니다.")
        }
        guard branch.headMessageID == expectedHeadMessageID else {
            throw CoreClientFailure.invalidResponse(
                "다른 기기나 흐름에서 대화가 먼저 변경되었습니다."
            )
        }
        let generationID = UUID().uuidString
        let userMessage = ChatMessage(
            conversationID: conversationID,
            parentID: branch.headMessageID,
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
        messagesByBranch[branchID, default: []].append(userMessage)
        messagesByBranch[branchID, default: []].append(assistantMessage)
        let timestamp = Self.timestamp()
        branchesByConversation[conversationID]?[branchIndex] =
            CoreConversationBranch(
                id: branch.id,
                conversationID: branch.conversationID,
                title: branch.title,
                forkMessageID: branch.forkMessageID,
                headMessageID: assistantID,
                createdAt: branch.createdAt,
                updatedAt: timestamp
            )
        if let state = statesByConversation[conversationID] {
            statesByConversation[conversationID] = CoreConversationState(
                conversationID: conversationID,
                activeBranchID: state.activeBranchID,
                selectedMode: state.selectedMode,
                updatedAt: timestamp
            )
            if state.activeBranchID == branchID {
                messagesByConversation[conversationID] = messagesByBranch[branchID]
            }
        }
        if let conversationIndex = conversations.firstIndex(
            where: { $0.id == conversationID }
        ) {
            let conversation = conversations[conversationIndex]
            conversations[conversationIndex] = CoreConversation(
                id: conversation.id,
                characterID: conversation.characterID,
                title: conversation.title,
                createdAt: conversation.createdAt,
                updatedAt: timestamp
            )
        }
        events.append(contentsOf: [
            ChatEvent(
                eventVersion: 2,
                generationID: generationID,
                conversationID: conversationID,
                branchID: branchID,
                assistantMessageID: assistantID,
                sequence: 1,
                kind: "generation_started"
            ),
            ChatEvent(
                eventVersion: 2,
                generationID: generationID,
                conversationID: conversationID,
                branchID: branchID,
                assistantMessageID: assistantID,
                sequence: 2,
                kind: "text_delta",
                text: assistantMessage.text
            ),
            ChatEvent(
                eventVersion: 2,
                generationID: generationID,
                conversationID: conversationID,
                branchID: branchID,
                assistantMessageID: assistantID,
                sequence: 3,
                kind: "message_committed",
                messageID: assistantID,
                messageStatus: "complete"
            ),
            ChatEvent(
                eventVersion: 2,
                generationID: generationID,
                conversationID: conversationID,
                branchID: branchID,
                assistantMessageID: assistantID,
                sequence: 4,
                kind: "generation_finished"
            ),
        ])
        return generationID
    }

    public func cancelGeneration(generationID: String) async throws {
        guard let branchEntry = messagesByBranch.first(where: { entry in
            entry.value.contains(where: { $0.generationID == generationID })
        }), let conversationID = branchesByConversation.first(where: { entry in
            entry.value.contains(where: { $0.id == branchEntry.key })
        })?.key
        else {
            throw CoreClientFailure.invalidResponse("생성 작업이 없습니다.")
        }
        let assistantMessageID = branchEntry.value.first(where: {
            $0.generationID == generationID && $0.role == .assistant
        })?.id
        events.append(
            ChatEvent(
                eventVersion: 2,
                generationID: generationID,
                conversationID: conversationID,
                branchID: branchEntry.key,
                assistantMessageID: assistantMessageID,
                sequence: 5,
                kind: "generation_cancelled"
            )
        )
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
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
        guard let state = statesByConversation[conversationID] else {
            return
        }
        messagesByBranch[state.activeBranchID] = messages
        guard let branchIndex = branchesByConversation[conversationID]?.firstIndex(
            where: { $0.id == state.activeBranchID }
        ), let branch = branchesByConversation[conversationID]?[branchIndex]
        else {
            return
        }
        branchesByConversation[conversationID]?[branchIndex] =
            CoreConversationBranch(
                id: branch.id,
                conversationID: branch.conversationID,
                title: branch.title,
                forkMessageID: branch.forkMessageID,
                headMessageID: messages.last?.id,
                createdAt: branch.createdAt,
                updatedAt: Self.timestamp()
            )
    }

    public func listProviderProfiles() async throws -> [ProviderProfile] {
        if let listProviderProfilesDelay {
            try await Task.sleep(for: listProviderProfilesDelay)
        }
        if listProviderFailuresRemaining > 0 {
            listProviderFailuresRemaining -= 1
            throw CoreClientFailure.startupFailed(
                "provider profiles unavailable"
            )
        }
        return profiles
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
        if let getSettingsDelay {
            try await Task.sleep(for: getSettingsDelay)
        }
        return settings
    }

    public func updateSettings(
        _ settings: CoreAppSettings
    ) async throws -> CoreAppSettings {
        if let updateSettingsDelay {
            try await Task.sleep(for: updateSettingsDelay)
        }
        self.settings = settings
        return settings
    }

    public func databaseStats() async throws -> DatabaseStats {
        let messageIDs = Set(
            messagesByBranch.values
                .flatMap { $0 }
                .map(\.id)
        )
        return DatabaseStats(
            characters: UInt64(characters.count),
            conversations: UInt64(conversations.count),
            messages: UInt64(messageIDs.count),
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
    public func editUserMessage(
        conversationID _: String,
        branchID _: String,
        expectedHeadMessageID _: String?,
        messageID _: String,
        replacementText _: String,
        providerProfileID _: String,
        credential _: String?
    ) async throws -> CoreMessageActionGeneration {
        try unavailable()
    }
    public func regenerateAssistantMessage(
        conversationID _: String,
        branchID _: String,
        expectedHeadMessageID _: String?,
        messageID _: String,
        providerProfileID _: String,
        credential _: String?
    ) async throws -> CoreMessageActionGeneration {
        try unavailable()
    }
    public func removeMessageFromBranch(
        conversationID _: String,
        branchID _: String,
        expectedHeadMessageID _: String?,
        messageID _: String
    ) async throws -> CoreConversationBranch {
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
