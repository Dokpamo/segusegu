import Combine
import Foundation

@MainActor
public final class ChatViewModel: ObservableObject {
    @Published public private(set) var character: LibraryCharacter?
    @Published public private(set) var conversation: CoreConversation?
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
            && !isLoading
            && !isGenerating
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && coreIsAvailable
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
            let restoredMessages = try await client.listMessages(
                conversationID: opened.id
            )
            guard selectionEpoch == epoch, self.character?.id == character.id else {
                return
            }
            conversation = opened
            messages = restoredMessages
            isGenerating = messages.contains { $0.status == .pending }
            activeGenerationID = messages.last(where: {
                $0.status == .pending && $0.generationID != nil
            })?.generationID
            startPolling()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func submitMessage() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let conversation else {
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
            let generationID = try await client.sendMessage(
                conversationID: conversation.id,
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
        do {
            let persisted = try await client.listMessages(
                conversationID: conversationID
            )
            guard conversation?.id == conversationID else {
                return
            }
            messages = mergePersistedMessages(persisted)
            reconcileGenerationState(from: persisted)
            idlePollsSinceReconciliation = 0
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
                guard event.eventVersion == 1 else {
                    shouldReconcile = true
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

    private var coreIsAvailable: Bool {
        if case .unavailable = runtimeMode {
            return false
        }
        return true
    }
}
