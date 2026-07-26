import Combine
import Foundation

@MainActor
public final class ChatViewModel: ObservableObject {
    @Published public private(set) var character: LibraryCharacter?
    @Published public private(set) var conversation: CoreConversation?
    @Published public private(set) var branches: [CoreConversationBranch] = []
    @Published public private(set) var activeBranchID: String?
    @Published public private(set) var mode: ConversationMode = .chat
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public var draft = ""
    @Published public private(set) var isLoading = false
    @Published public private(set) var isGenerating = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var usageDescription: String?

    public let runtimeMode: CoreRuntimeMode

    private let client: any CoreClient
    private let credentialStore: any CredentialStore
    private let automaticallyPollEvents: Bool
    private var activeGenerationID: String?
    private var latestSequenceByGeneration: [String: UInt64] = [:]
    private var pollingTask: Task<Void, Never>?
    private var selectionEpoch: UInt64 = 0
    private var idlePollsSinceReconciliation = 0

    private static let idlePollsBeforeReconciliation = 10

    public init(
        client: any CoreClient,
        credentialStore: any CredentialStore,
        runtimeMode: CoreRuntimeMode,
        automaticallyPollEvents: Bool = true
    ) {
        self.client = client
        self.credentialStore = credentialStore
        self.runtimeMode = runtimeMode
        self.automaticallyPollEvents = automaticallyPollEvents
    }

    public var canSubmit: Bool {
        conversation != nil
            && activeBranchID != nil
            && !isLoading
            && !isGenerating
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && coreIsAvailable
    }

    public var canManageBranches: Bool {
        conversation != nil
            && !isLoading
            && !isGenerating
            && coreIsAvailable
    }

    public var branchOptions: [ChatBranchOption] {
        branches.enumerated().map { index, branch in
            let title: String
            if let branchTitle = branch.title?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !branchTitle.isEmpty {
                title = branchTitle
            } else if branch.forkMessageID == nil {
                title = "기본 흐름"
            } else {
                title = "분기 \(index + 1)"
            }

            let subtitle = branch.forkMessageID.flatMap { messageID in
                messages.first(where: { $0.id == messageID })?.text
            }
            return ChatBranchOption(
                id: branch.id,
                title: title,
                subtitle: subtitle
            )
        }
    }

    public func setCharacter(_ character: LibraryCharacter) async {
        if self.character?.id == character.id, conversation != nil {
            return
        }
        pollingTask?.cancel()
        pollingTask = nil
        let generationToCancel = activeGenerationID
        selectionEpoch &+= 1
        let epoch = selectionEpoch
        self.character = character
        conversation = nil
        branches = []
        activeBranchID = nil
        mode = .chat
        messages = []
        draft = ""
        errorMessage = nil
        activeGenerationID = nil
        latestSequenceByGeneration = [:]
        idlePollsSinceReconciliation = 0
        isGenerating = false
        isLoading = true
        defer {
            if selectionEpoch == epoch {
                isLoading = false
            }
        }

        do {
            if let generationToCancel {
                try? await client.cancelGeneration(generationID: generationToCancel)
            }
            let conversations = try await client.listConversations()
            guard selectionEpoch == epoch, self.character?.id == character.id else {
                return
            }
            let existing = conversations
                .filter { $0.characterID == character.id }
                .max { $0.updatedAt < $1.updatedAt }
            let opened = if let existing {
                existing
            } else {
                try await client.openConversation(characterID: character.id)
            }
            guard selectionEpoch == epoch, self.character?.id == character.id else {
                return
            }
            try await restoreConversation(
                opened,
                characterID: character.id,
                epoch: epoch
            )
            startPolling()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func setConversation(
        _ conversation: CoreConversation,
        character: LibraryCharacter
    ) async {
        if self.conversation?.id == conversation.id {
            return
        }

        pollingTask?.cancel()
        pollingTask = nil
        let generationToCancel = activeGenerationID
        selectionEpoch &+= 1
        let epoch = selectionEpoch
        self.character = character
        self.conversation = nil
        branches = []
        activeBranchID = nil
        mode = .chat
        messages = []
        draft = ""
        errorMessage = nil
        activeGenerationID = nil
        latestSequenceByGeneration = [:]
        idlePollsSinceReconciliation = 0
        isGenerating = false
        isLoading = true
        defer {
            if selectionEpoch == epoch {
                isLoading = false
            }
        }

        do {
            if let generationToCancel {
                try? await client.cancelGeneration(generationID: generationToCancel)
            }
            try await restoreConversation(
                conversation,
                characterID: character.id,
                epoch: epoch
            )
            startPolling()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restoreConversation(
        _ conversation: CoreConversation,
        characterID: String,
        epoch: UInt64
    ) async throws {
        async let stateTask = client.getConversationState(
            conversationID: conversation.id
        )
        async let branchesTask = client.listConversationBranches(
            conversationID: conversation.id
        )
        let (state, loadedBranches) = try await (
            stateTask,
            branchesTask
        )
        let restoredMessages = try await client.listBranchMessages(
            branchID: state.activeBranchID
        )
        guard selectionEpoch == epoch,
              character?.id == characterID
        else {
            return
        }
        self.conversation = conversation
        branches = loadedBranches
        activeBranchID = state.activeBranchID
        mode = state.selectedMode
        messages = restoredMessages
        isGenerating = messages.contains { $0.status == .pending }
        activeGenerationID = messages.last(where: {
            $0.status == .pending && $0.generationID != nil
        })?.generationID
    }

    public func selectBranch(id branchID: String) async {
        guard let conversation,
              branchID != activeBranchID,
              canManageBranches
        else {
            return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            let state = try await client.selectConversationBranch(
                conversationID: conversation.id,
                branchID: branchID
            )
            let restoredMessages = try await client.listBranchMessages(
                branchID: state.activeBranchID
            )
            guard self.conversation?.id == conversation.id else {
                return
            }
            activeBranchID = state.activeBranchID
            mode = state.selectedMode
            messages = restoredMessages
            reconcileGenerationState(from: restoredMessages)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func createBranch(afterMessageID messageID: String) async {
        guard let conversation,
              canManageBranches,
              messages.contains(where: {
                  $0.id == messageID && $0.status != .pending
              })
        else {
            return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            let branchNumber = branches.count + 1
            let branch = try await client.createConversationBranch(
                conversationID: conversation.id,
                fromMessageID: messageID,
                title: "분기 \(branchNumber)"
            )
            let state = try await client.selectConversationBranch(
                conversationID: conversation.id,
                branchID: branch.id
            )
            async let branchListTask = client.listConversationBranches(
                conversationID: conversation.id
            )
            async let messagesTask = client.listBranchMessages(
                branchID: state.activeBranchID
            )
            let (loadedBranches, restoredMessages) = try await (
                branchListTask,
                messagesTask
            )
            guard self.conversation?.id == conversation.id else {
                return
            }
            branches = loadedBranches
            activeBranchID = state.activeBranchID
            mode = state.selectedMode
            messages = restoredMessages
            reconcileGenerationState(from: restoredMessages)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func setMode(_ newMode: ConversationMode) async {
        guard let conversation,
              newMode != mode,
              canManageBranches
        else {
            return
        }

        let previousMode = mode
        mode = newMode
        do {
            let state = try await client.setConversationMode(
                conversationID: conversation.id,
                mode: newMode
            )
            guard self.conversation?.id == conversation.id else {
                return
            }
            mode = state.selectedMode
            errorMessage = nil
        } catch {
            if self.conversation?.id == conversation.id {
                mode = previousMode
                errorMessage = error.localizedDescription
            }
        }
    }

    public func canMutateMessage(_ message: ChatMessage) -> Bool {
        canManageBranches
            && message.status != .pending
            && (message.role == .user || message.role == .assistant)
            && messages.contains(where: { $0.id == message.id })
    }

    @discardableResult
    public func editUserMessage(
        messageID: String,
        replacementText: String
    ) async -> Bool {
        let text = replacementText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !text.isEmpty,
              let conversation,
              let activeBranch,
              let message = messages.first(where: {
                  $0.id == messageID && $0.role == .user
              }),
              canMutateMessage(message)
        else {
            return false
        }

        isLoading = true
        defer { isLoading = false }
        do {
            let provider = try await selectedProviderAccess()
            guard self.conversation?.id == conversation.id,
                  self.activeBranchID == activeBranch.id
            else {
                return false
            }
            let result = try await client.editUserMessage(
                conversationID: conversation.id,
                branchID: activeBranch.id,
                expectedHeadMessageID: activeBranch.headMessageID,
                messageID: messageID,
                replacementText: text,
                providerProfileID: provider.profileID,
                credential: provider.credential
            )
            try await restoreAfterMessageAction(
                conversationID: conversation.id,
                branchID: result.branch.id,
                generationID: result.generationID
            )
            errorMessage = nil
            startPolling()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func regenerateAssistantMessage(messageID: String) async {
        guard let conversation,
              let activeBranch,
              let message = messages.first(where: {
                  $0.id == messageID && $0.role == .assistant
              }),
              canMutateMessage(message)
        else {
            return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            let provider = try await selectedProviderAccess()
            guard self.conversation?.id == conversation.id,
                  self.activeBranchID == activeBranch.id
            else {
                return
            }
            let result = try await client.regenerateAssistantMessage(
                conversationID: conversation.id,
                branchID: activeBranch.id,
                expectedHeadMessageID: activeBranch.headMessageID,
                messageID: messageID,
                providerProfileID: provider.profileID,
                credential: provider.credential
            )
            try await restoreAfterMessageAction(
                conversationID: conversation.id,
                branchID: result.branch.id,
                generationID: result.generationID
            )
            errorMessage = nil
            startPolling()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func removeMessage(messageID: String) async {
        guard let conversation,
              let activeBranch,
              let message = messages.first(where: { $0.id == messageID }),
              canMutateMessage(message)
        else {
            return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            let branch = try await client.removeMessageFromBranch(
                conversationID: conversation.id,
                branchID: activeBranch.id,
                expectedHeadMessageID: activeBranch.headMessageID,
                messageID: messageID
            )
            try await restoreAfterMessageAction(
                conversationID: conversation.id,
                branchID: branch.id,
                generationID: nil
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func submitMessage() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let conversation,
              let activeBranchID,
              let activeBranch = branches.first(
                  where: { $0.id == activeBranchID }
              )
        else {
            return
        }
        do {
            let settings = try await client.getSettings()
            guard self.conversation?.id == conversation.id else {
                return
            }
            guard let profileID = settings.selectedProviderProfileID else {
                errorMessage = "설정에서 사용할 프로바이더 프로필을 선택하세요."
                return
            }
            let credential = try await credentialStore.credential(for: profileID)
            guard self.conversation?.id == conversation.id else {
                return
            }
            draft = ""
            errorMessage = nil
            isGenerating = true
            let generationID = try await client.sendMessageToBranch(
                conversationID: conversation.id,
                branchID: activeBranchID,
                expectedHeadMessageID: activeBranch.headMessageID,
                mode: mode,
                text: text,
                providerProfileID: profileID,
                credential: credential
            )
            guard self.conversation?.id == conversation.id else {
                return
            }
            activeGenerationID = generationID
            latestSequenceByGeneration[generationID] = 0
            idlePollsSinceReconciliation = 0
            await refreshMessages()
            await refreshBranchMetadata(conversationID: conversation.id)
            startPolling()
        } catch {
            isGenerating = false
            errorMessage = error.localizedDescription
            if draft.isEmpty, self.conversation?.id == conversation.id {
                draft = text
            }
        }
    }

    public func cancelGeneration() async {
        guard let generationID = activeGenerationID else {
            return
        }
        do {
            try await client.cancelGeneration(generationID: generationID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func refreshMessages() async {
        guard let conversation else {
            return
        }
        await reconcilePersistedMessages(conversationID: conversation.id)
    }

    private func reconcilePersistedMessages(conversationID: String) async {
        guard let branchID = activeBranchID else {
            return
        }
        do {
            let persisted = try await client.listBranchMessages(
                branchID: branchID
            )
            guard conversation?.id == conversationID,
                  activeBranchID == branchID
            else {
                return
            }
            messages = mergePersistedMessages(persisted)
            reconcileGenerationState(from: persisted)
            idlePollsSinceReconciliation = 0
            await refreshBranchMetadata(conversationID: conversationID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshBranchMetadata(conversationID: String) async {
        do {
            async let stateTask = client.getConversationState(
                conversationID: conversationID
            )
            async let branchesTask = client.listConversationBranches(
                conversationID: conversationID
            )
            let (state, loadedBranches) = try await (
                stateTask,
                branchesTask
            )
            guard conversation?.id == conversationID else {
                return
            }
            branches = loadedBranches
            activeBranchID = state.activeBranchID
            mode = state.selectedMode
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func pollOnce() async {
        guard let conversation else {
            return
        }
        do {
            let batch = try await client.pollEvents(maxEvents: 128)
            guard self.conversation?.id == conversation.id else {
                return
            }
            var shouldReconcile = batch.droppedEventCount > 0
            var appliedEvent = false
            for event in batch.events
            where event.conversationID == conversation.id {
                guard event.eventVersion == 2 else {
                    shouldReconcile = true
                    continue
                }
                guard event.branchID == activeBranchID else {
                    if event.branchID == nil {
                        shouldReconcile = true
                    }
                    continue
                }
                switch apply(event) {
                case .ignored:
                    continue
                case .applied:
                    appliedEvent = true
                case .reconcile:
                    appliedEvent = true
                    shouldReconcile = true
                }
            }

            if appliedEvent {
                idlePollsSinceReconciliation = 0
            } else {
                idlePollsSinceReconciliation += 1
                if idlePollsSinceReconciliation
                    >= Self.idlePollsBeforeReconciliation
                {
                    shouldReconcile = true
                }
            }

            if shouldReconcile {
                await reconcilePersistedMessages(conversationID: conversation.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private enum EventApplication {
        case ignored
        case applied
        case reconcile
    }

    private func apply(_ event: ChatEvent) -> EventApplication {
        if let activeGenerationID, event.generationID != activeGenerationID {
            return .ignored
        }
        let latestSequence = latestSequenceByGeneration[event.generationID] ?? 0
        guard event.sequence > latestSequence else {
            return .ignored
        }
        latestSequenceByGeneration[event.generationID] = event.sequence

        switch event.kind {
        case "generation_started":
            if messages.contains(where: {
                $0.generationID == event.generationID && $0.status != .pending
            }) {
                return .ignored
            }
            activeGenerationID = event.generationID
            isGenerating = true
            return .applied
        case "text_delta":
            guard let delta = event.text else {
                return .ignored
            }
            if messages.contains(where: {
                $0.generationID == event.generationID && $0.status != .pending
            }) {
                return .ignored
            }
            if let index = messages.lastIndex(where: {
                $0.generationID == event.generationID && $0.status == .pending
            }) {
                messages[index].text += delta
            } else {
                messages.append(
                    ChatMessage(
                        id: event.assistantMessageID ?? UUID().uuidString,
                        conversationID: event.conversationID,
                        role: .assistant,
                        text: delta,
                        status: .pending,
                        generationID: event.generationID,
                        createdAt: event.emittedAt
                    )
                )
            }
            return .applied
        case "usage_updated":
            let input = event.usageInputTokens.map(String.init) ?? "?"
            let output = event.usageOutputTokens.map(String.init) ?? "?"
            usageDescription = "입력 \(input) · 출력 \(output) 토큰"
            return .applied
        case "message_committed":
            return .reconcile
        case "generation_finished":
            finishGeneration()
            return .reconcile
        case "generation_cancelled":
            errorMessage = "응답 생성을 취소했습니다."
            finishGeneration()
            return .reconcile
        case "generation_failed":
            errorMessage = event.errorMessage ?? "응답 생성에 실패했습니다."
            finishGeneration()
            return .reconcile
        default:
            return .ignored
        }
    }

    private func finishGeneration() {
        isGenerating = false
        activeGenerationID = nil
    }

    private func mergePersistedMessages(
        _ persisted: [ChatMessage]
    ) -> [ChatMessage] {
        let currentByID = Dictionary(
            messages.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        return persisted.map { persistedMessage in
            guard
                persistedMessage.status == .pending,
                let current = currentByID[persistedMessage.id],
                current.status == .pending,
                current.generationID == persistedMessage.generationID,
                current.text.count > persistedMessage.text.count,
                current.text.hasPrefix(persistedMessage.text)
            else {
                return persistedMessage
            }
            var merged = persistedMessage
            merged.text = current.text
            return merged
        }
    }

    private func reconcileGenerationState(from persisted: [ChatMessage]) {
        let latestPendingGeneration = persisted.last(where: {
            $0.status == .pending && $0.generationID != nil
        })?.generationID

        if let activeGenerationID {
            let activeIsPersisted = persisted.contains {
                $0.status == .pending
                    && $0.generationID == activeGenerationID
            }
            if activeIsPersisted {
                isGenerating = true
                return
            }
            latestSequenceByGeneration.removeValue(forKey: activeGenerationID)
        }
        activeGenerationID = latestPendingGeneration
        isGenerating = latestPendingGeneration != nil
    }

    private func startPolling() {
        guard automaticallyPollEvents else {
            return
        }
        guard pollingTask == nil || pollingTask?.isCancelled == true else {
            return
        }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                await self.pollOnce()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    public func resumeEventPolling() async {
        if let conversation {
            await reconcilePersistedMessages(conversationID: conversation.id)
        }
        startPolling()
    }

    public func pauseEventPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private var activeBranch: CoreConversationBranch? {
        guard let activeBranchID else {
            return nil
        }
        return branches.first { $0.id == activeBranchID }
    }

    private func selectedProviderAccess() async throws -> (
        profileID: String,
        credential: String?
    ) {
        let settings = try await client.getSettings()
        guard let profileID = settings.selectedProviderProfileID else {
            throw CoreClientFailure.configurationRequired(
                "설정에서 사용할 프로바이더 프로필을 선택하세요."
            )
        }
        let credential = try await credentialStore.credential(for: profileID)
        return (profileID, credential)
    }

    private func restoreAfterMessageAction(
        conversationID: String,
        branchID: String,
        generationID: String?
    ) async throws {
        async let stateTask = client.getConversationState(
            conversationID: conversationID
        )
        async let branchesTask = client.listConversationBranches(
            conversationID: conversationID
        )
        async let messagesTask = client.listBranchMessages(branchID: branchID)
        let (state, loadedBranches, restoredMessages) = try await (
            stateTask,
            branchesTask,
            messagesTask
        )
        guard conversation?.id == conversationID else {
            return
        }
        branches = loadedBranches
        activeBranchID = state.activeBranchID
        mode = state.selectedMode
        messages = restoredMessages
        activeGenerationID = generationID
        if let generationID {
            latestSequenceByGeneration[generationID] = 0
        }
        reconcileGenerationState(from: restoredMessages)
        idlePollsSinceReconciliation = 0
    }

    private var coreIsAvailable: Bool {
        if case .unavailable = runtimeMode {
            return false
        }
        return true
    }
}
