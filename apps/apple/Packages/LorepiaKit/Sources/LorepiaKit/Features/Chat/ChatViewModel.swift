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
    @Published public private(set) var providerProfiles: [ProviderProfile] = []
    @Published public private(set) var selectedProviderProfileID: String?
    @Published public private(set) var hasLoadedProviderConfiguration = false
    @Published public private(set) var hasProviderCredentialAccessFailure = false
    @Published public var draft = ""
    @Published public private(set) var isLoading = false
    @Published public private(set) var isGenerating = false
    @Published public private(set) var isSubmitting = false
    @Published public private(set) var isChangingProviderProfile = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var usageDescription: String?

    public let runtimeMode: CoreRuntimeMode

    private let client: any CoreClient
    private let credentialStore: any CredentialStore
    private let providerConfigurationStore: ProviderConfigurationStore?
    private let automaticallyPollEvents: Bool
    private var providerConfigurationCancellable: AnyCancellable?
    private var activeGenerationID: String?
    private var latestSequenceByGeneration: [String: UInt64] = [:]
    private var pollingTask: Task<Void, Never>?
    private var selectionEpoch: UInt64 = 0
    /// Invalidates branch/mode/message snapshots across MainActor reentrancy.
    private var conversationSelectionRevision: UInt64 = 0
    /// Orders same-selection message and metadata snapshots by start time.
    private var conversationContentRevision: UInt64 = 0
    /// Prevents an older async operation from clearing a newer loading state.
    private var loadingOperationRevision: UInt64 = 0
    private var providerSelectionRevision: UInt64 = 0
    private var providerRefreshRevision: UInt64 = 0
    private var providerRefreshRetryScheduled = false
    private var providerStoreAutoRefreshEnabled = true
    private var credentialAccessRevision: UInt64 = 0
    private var credentialFailureProfileID: String?
    private var providerRefreshErrorMessage: String?
    private var idlePollsSinceReconciliation = 0
    private var draftByConversationID: [String: String] = [:]

    private struct ConversationSelectionToken: Equatable {
        let conversationID: String
        let revision: UInt64
    }

    private struct ConversationContentToken: Equatable {
        let selection: ConversationSelectionToken
        let revision: UInt64
    }

    private struct ConversationContentObservationToken: Equatable {
        let selection: ConversationSelectionToken
        let revision: UInt64
    }

#if DEBUG
    private var branchMetadataCommitHookForTesting:
        (@MainActor () async -> Void)?
    private var messageActionRestoreCommitHookForTesting:
        (@MainActor () async -> Void)?
    private var conversationRestoreCommitHookForTesting:
        (@MainActor () async -> Void)?
    private var conversationSelectionErrorCommitHookForTesting:
        (@MainActor () async -> Void)?
    private var pollBatchCommitHookForTesting:
        (@MainActor () async -> Void)?
    private var submitMessageSuccessCommitHookForTesting:
        (@MainActor () async -> Void)?
    private var submitMessageGenerationCommitHookForTesting:
        (@MainActor (String) -> Void)?
    private var submitMessageErrorCommitHookForTesting:
        (@MainActor () async -> Void)?
    private var cancelGenerationErrorCommitHookForTesting:
        (@MainActor () async -> Void)?
#endif

    private static let idlePollsBeforeReconciliation = 10
    private static let credentialAccessFailureMessage =
        "저장된 자격 증명을 불러오지 못했습니다. 프로바이더 설정에서 다시 저장하세요."
    private static let credentialTooLargeMessage =
        "저장된 자격 증명이 너무 깁니다. 프로바이더 설정에서 다시 저장하세요."
    private static let blockedProviderMessage =
        "이 프로바이더의 자격 증명 상태를 확인할 수 없습니다. 프로바이더 설정에서 API 키를 다시 저장하세요."

    public init(
        client: any CoreClient,
        credentialStore: any CredentialStore,
        runtimeMode: CoreRuntimeMode,
        providerConfigurationStore: ProviderConfigurationStore? = nil,
        automaticallyPollEvents: Bool = true
    ) {
        self.client = client
        self.credentialStore = credentialStore
        self.runtimeMode = runtimeMode
        self.providerConfigurationStore = providerConfigurationStore
        self.automaticallyPollEvents = automaticallyPollEvents
        if let providerConfigurationStore,
           providerConfigurationStore.revision > 0
               || !providerConfigurationStore.profiles.isEmpty
               || providerConfigurationStore.selectedProfileID != nil
        {
            applyProviderConfiguration(
                profiles: providerConfigurationStore.profiles,
                selectedProfileID:
                    providerConfigurationStore.selectedProfileID
            )
        }
        providerConfigurationCancellable = providerConfigurationStore?.$revision
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard
                        let self,
                        let store = self.providerConfigurationStore
                    else {
                        return
                    }
                    self.applyProviderConfiguration(
                        profiles: store.profiles,
                        selectedProfileID: store.selectedProfileID
                    )
                    guard self.providerStoreAutoRefreshEnabled else {
                        return
                    }
                    await self.refreshProviderSelection()
                }
            }
    }

    public var canSubmit: Bool {
        conversation != nil
            && activeBranchID != nil
            && !isLoading
            && !isGenerating
            && !isSubmitting
            && !isChangingProviderProfile
            && !hasProviderCredentialAccessFailure
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (
                !hasLoadedProviderConfiguration
                    || selectedProviderProfile != nil
            )
            && coreIsAvailable
    }

    public var canEditDraft: Bool {
        conversation != nil
            && !isLoading
            && !isGenerating
            && !isSubmitting
            && coreIsAvailable
    }

    public var canManageBranches: Bool {
        conversation != nil
            && !isLoading
            && !isGenerating
            && !isSubmitting
            && coreIsAvailable
    }

    public var selectedProviderProfile: ProviderProfile? {
        guard let selectedProviderProfileID,
              !providerProfileIsBlocked(selectedProviderProfileID)
        else {
            return nil
        }
        return providerProfiles.first { $0.id == selectedProviderProfileID }
    }

    public var requiresProviderConfiguration: Bool {
        selectedProviderProfile == nil
            || hasProviderCredentialAccessFailure
    }

    public var providerConfigurationMessage: String {
        if let selectedProviderProfileID,
           providerProfileIsBlocked(selectedProviderProfileID)
        {
            return Self.blockedProviderMessage
        }
        if hasProviderCredentialAccessFailure {
            return Self.credentialAccessFailureMessage
        }
        if providerProfiles.isEmpty {
            return "메시지를 보내려면 프로바이더 프로필을 추가하세요."
        }
        return "메시지를 보내려면 앱 전체 기본 프로바이더를 선택하세요."
    }

    public var canChangeProviderProfile: Bool {
        conversation != nil
            && !isLoading
            && !isGenerating
            && !isSubmitting
            && !isChangingProviderProfile
            && !providerProfiles.isEmpty
            && providerConfigurationStore?.mutatingProfileIDs.isEmpty != false
            && (
                selectedProviderProfileID.map {
                    !providerProfileIsBlocked($0)
                } ?? true
            )
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
        stashDraftForActiveConversation()
        pollingTask?.cancel()
        pollingTask = nil
        let generationToCancel = activeGenerationID
        selectionEpoch &+= 1
        advanceConversationSelectionRevision()
        let epoch = selectionEpoch
        let loadingRevision = beginLoadingOperation()
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
        defer {
            endLoadingOperation(loadingRevision)
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
#if DEBUG
            await conversationSelectionErrorCommitHookForTesting?()
#endif
            if selectionEpoch == epoch {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func setConversation(
        _ conversation: CoreConversation,
        character: LibraryCharacter
    ) async {
        if self.conversation?.id == conversation.id {
            return
        }

        stashDraftForActiveConversation()
        pollingTask?.cancel()
        pollingTask = nil
        let generationToCancel = activeGenerationID
        selectionEpoch &+= 1
        advanceConversationSelectionRevision()
        let epoch = selectionEpoch
        let loadingRevision = beginLoadingOperation()
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
        defer {
            endLoadingOperation(loadingRevision)
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
#if DEBUG
            await conversationSelectionErrorCommitHookForTesting?()
#endif
            if selectionEpoch == epoch {
                errorMessage = error.localizedDescription
            }
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
#if DEBUG
        await conversationRestoreCommitHookForTesting?()
#endif
        guard selectionEpoch == epoch,
              character?.id == characterID
        else {
            return
        }
        advanceConversationSelectionRevision()
        self.conversation = conversation
        draft = draftByConversationID.removeValue(
            forKey: conversation.id
        ) ?? ""
        branches = loadedBranches
        activeBranchID = state.activeBranchID
        mode = state.selectedMode
        messages = restoredMessages
        isGenerating = messages.contains { $0.status == .pending }
        activeGenerationID = messages.last(where: {
            $0.status == .pending && $0.generationID != nil
        })?.generationID
    }

    private func stashDraftForActiveConversation() {
        guard let conversationID = conversation?.id else {
            return
        }
        if draft.isEmpty {
            draftByConversationID.removeValue(forKey: conversationID)
        } else {
            draftByConversationID[conversationID] = draft
        }
    }

    private func restoreSubmittedDraftAfterFailure(
        _ submittedDraft: String,
        conversationID: String,
        branchID: String,
        selectionToken: ConversationSelectionToken
    ) -> Bool {
        if conversationSelectionIsCurrent(
            selectionToken,
            branchID: branchID
        ) {
            if draft.isEmpty {
                draft = submittedDraft
            }
            return true
        }

        if conversation?.id == conversationID {
            if draft.isEmpty {
                draft = submittedDraft
            }
            return false
        }
        if draftByConversationID[conversationID] == nil {
            draftByConversationID[conversationID] = submittedDraft
        }
        return false
    }

    public func selectBranch(id branchID: String) async {
        guard let conversation,
              branchID != activeBranchID,
              canManageBranches
        else {
            return
        }

        let selectionToken = beginConversationSelectionMutation(
            conversationID: conversation.id
        )
        let loadingRevision = beginLoadingOperation()
        defer { endLoadingOperation(loadingRevision) }
        do {
            let state = try await client.selectConversationBranch(
                conversationID: conversation.id,
                branchID: branchID
            )
            let restoredMessages = try await client.listBranchMessages(
                branchID: state.activeBranchID
            )
            guard conversationSelectionIsCurrent(selectionToken) else {
                return
            }
            advanceConversationSelectionRevision()
            activeBranchID = state.activeBranchID
            mode = state.selectedMode
            messages = restoredMessages
            reconcileGenerationState(from: restoredMessages)
            errorMessage = nil
        } catch {
            if conversationSelectionIsCurrent(selectionToken) {
                errorMessage = error.localizedDescription
            }
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

        let selectionToken = beginConversationSelectionMutation(
            conversationID: conversation.id
        )
        let loadingRevision = beginLoadingOperation()
        defer { endLoadingOperation(loadingRevision) }
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
            guard conversationSelectionIsCurrent(selectionToken) else {
                return
            }
            advanceConversationSelectionRevision()
            branches = loadedBranches
            activeBranchID = state.activeBranchID
            mode = state.selectedMode
            messages = restoredMessages
            reconcileGenerationState(from: restoredMessages)
            errorMessage = nil
        } catch {
            if conversationSelectionIsCurrent(selectionToken) {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func setMode(_ newMode: ConversationMode) async {
        guard let conversation,
              newMode != mode,
              canManageBranches
        else {
            return
        }

        let selectionToken = beginConversationSelectionMutation(
            conversationID: conversation.id
        )
        let previousMode = mode
        mode = newMode
        do {
            let state = try await client.setConversationMode(
                conversationID: conversation.id,
                mode: newMode
            )
            guard conversationSelectionIsCurrent(
                selectionToken,
                branchID: state.activeBranchID
            ) else {
                return
            }
            advanceConversationSelectionRevision()
            mode = state.selectedMode
            errorMessage = nil
        } catch {
            if conversationSelectionIsCurrent(selectionToken) {
                advanceConversationSelectionRevision()
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

        let selectionToken = beginConversationSelectionMutation(
            conversationID: conversation.id
        )
        let loadingRevision = beginLoadingOperation()
        defer { endLoadingOperation(loadingRevision) }
        do {
            let provider = try await selectedProviderAccess()
            guard conversationSelectionIsCurrent(
                selectionToken,
                branchID: activeBranch.id
            )
            else {
                return false
            }
            try validateProviderAccess(provider)
            let result = try await client.editUserMessage(
                conversationID: conversation.id,
                branchID: activeBranch.id,
                expectedHeadMessageID: activeBranch.headMessageID,
                messageID: messageID,
                replacementText: text,
                providerProfileID: provider.profile.id,
                credential: provider.credential
            )
            guard try await restoreAfterMessageAction(
                conversationID: conversation.id,
                branchID: result.branch.id,
                generationID: result.generationID,
                selectionToken: selectionToken
            ) else {
                return false
            }
            errorMessage = nil
            startPolling()
            return true
        } catch {
            if conversationSelectionIsCurrent(selectionToken) {
                errorMessage = userFacingProviderError(
                    error,
                    fallback: "메시지를 수정하지 못했습니다. 잠시 후 다시 시도하세요."
                )
            }
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

        let selectionToken = beginConversationSelectionMutation(
            conversationID: conversation.id
        )
        let loadingRevision = beginLoadingOperation()
        defer { endLoadingOperation(loadingRevision) }
        do {
            let provider = try await selectedProviderAccess()
            guard conversationSelectionIsCurrent(
                selectionToken,
                branchID: activeBranch.id
            )
            else {
                return
            }
            try validateProviderAccess(provider)
            let result = try await client.regenerateAssistantMessage(
                conversationID: conversation.id,
                branchID: activeBranch.id,
                expectedHeadMessageID: activeBranch.headMessageID,
                messageID: messageID,
                providerProfileID: provider.profile.id,
                credential: provider.credential
            )
            guard try await restoreAfterMessageAction(
                conversationID: conversation.id,
                branchID: result.branch.id,
                generationID: result.generationID,
                selectionToken: selectionToken
            ) else {
                return
            }
            errorMessage = nil
            startPolling()
        } catch {
            if conversationSelectionIsCurrent(selectionToken) {
                errorMessage = userFacingProviderError(
                    error,
                    fallback: "응답을 다시 생성하지 못했습니다. 잠시 후 다시 시도하세요."
                )
            }
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

        let selectionToken = beginConversationSelectionMutation(
            conversationID: conversation.id
        )
        let loadingRevision = beginLoadingOperation()
        defer { endLoadingOperation(loadingRevision) }
        do {
            let branch = try await client.removeMessageFromBranch(
                conversationID: conversation.id,
                branchID: activeBranch.id,
                expectedHeadMessageID: activeBranch.headMessageID,
                messageID: messageID
            )
            guard try await restoreAfterMessageAction(
                conversationID: conversation.id,
                branchID: branch.id,
                generationID: nil,
                selectionToken: selectionToken
            ) else {
                return
            }
            errorMessage = nil
        } catch {
            if conversationSelectionIsCurrent(selectionToken) {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func submitMessage() async {
        let submittedDraft = draft
        if let selectedProviderProfileID,
           providerProfileIsBlocked(selectedProviderProfileID)
        {
            errorMessage = Self.blockedProviderMessage
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmit,
              !text.isEmpty,
              let conversation,
              let activeBranchID,
              let activeBranch = branches.first(
                  where: { $0.id == activeBranchID }
              ),
              let selectionToken = conversationSelectionToken(
                  conversationID: conversation.id
              )
        else {
            return
        }
        let submissionMode = mode
        let providerRevision = providerSelectionRevision
        isSubmitting = true
        defer {
            isSubmitting = false
        }
        do {
            let provider = try await selectedProviderAccess()
            guard conversationSelectionIsCurrent(
                selectionToken,
                branchID: activeBranchID
            ),
                  providerSelectionRevision == providerRevision,
                  !isChangingProviderProfile
            else {
                return
            }
            try validateProviderAccess(provider)
            if draft == submittedDraft {
                draft = ""
            }
            errorMessage = nil
            isGenerating = true
            let generationID = try await client.sendMessageToBranch(
                conversationID: conversation.id,
                branchID: activeBranchID,
                expectedHeadMessageID: activeBranch.headMessageID,
                mode: submissionMode,
                text: text,
                providerProfileID: provider.profile.id,
                credential: provider.credential
            )
#if DEBUG
            await submitMessageSuccessCommitHookForTesting?()
#endif
            guard conversationSelectionIsCurrent(
                selectionToken,
                branchID: activeBranchID
            ) else {
                return
            }
            activeGenerationID = generationID
#if DEBUG
            submitMessageGenerationCommitHookForTesting?(generationID)
#endif
            latestSequenceByGeneration[generationID] = 0
            idlePollsSinceReconciliation = 0
            await refreshMessages()
            guard conversationSelectionIsCurrent(
                selectionToken,
                branchID: activeBranchID
            ) else {
                return
            }
            startPolling()
        } catch {
#if DEBUG
            await submitMessageErrorCommitHookForTesting?()
#endif
            guard restoreSubmittedDraftAfterFailure(
                submittedDraft,
                conversationID: conversation.id,
                branchID: activeBranchID,
                selectionToken: selectionToken
            ) else {
                return
            }
            isGenerating = false
            errorMessage = userFacingProviderError(
                error,
                fallback: "메시지를 보내지 못했습니다. 잠시 후 다시 시도하세요."
            )
        }
    }

    public func cancelGeneration() async {
        guard let generationID = activeGenerationID,
              let conversation,
              let activeBranchID,
              let selectionToken = conversationSelectionToken(
                  conversationID: conversation.id
              )
        else {
            return
        }
        do {
            try await client.cancelGeneration(generationID: generationID)
        } catch {
#if DEBUG
            await cancelGenerationErrorCommitHookForTesting?()
#endif
            guard conversationSelectionIsCurrent(
                selectionToken,
                branchID: activeBranchID
            ),
                activeGenerationID == generationID
            else {
                return
            }
            errorMessage = userFacingProviderError(
                error,
                fallback: "응답 생성을 중단하지 못했습니다. 다시 시도하세요."
            )
        }
    }

    public func refreshMessages() async {
        guard !isLoading,
              let conversation,
              let contentToken = beginConversationContentRead(
                  conversationID: conversation.id
              )
        else {
            return
        }
        await reconcilePersistedMessages(
            conversationID: conversation.id,
            contentToken: contentToken
        )
    }

    private func reconcilePersistedMessages(
        conversationID: String,
        contentToken: ConversationContentToken
    ) async {
        guard conversationContentIsCurrent(contentToken),
              let branchID = activeBranchID
        else {
            return
        }
        do {
            let persisted = try await client.listBranchMessages(
                branchID: branchID
            )
            guard conversationContentIsCurrent(
                contentToken,
                branchID: branchID
            )
            else {
                return
            }
            messages = mergePersistedMessages(persisted)
            reconcileGenerationState(from: persisted)
            idlePollsSinceReconciliation = 0
            await refreshBranchMetadata(
                conversationID: conversationID,
                branchID: branchID,
                contentToken: contentToken
            )
        } catch {
            if conversationContentIsCurrent(contentToken) {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshBranchMetadata(
        conversationID: String,
        branchID: String,
        contentToken: ConversationContentToken
    ) async {
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
#if DEBUG
            await branchMetadataCommitHookForTesting?()
#endif
            guard conversationContentIsCurrent(
                contentToken,
                branchID: branchID
            ),
                state.activeBranchID == branchID
            else {
                return
            }
            branches = loadedBranches
            mode = state.selectedMode
        } catch {
            if conversationContentIsCurrent(contentToken) {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func pollOnce() async {
        guard !isLoading,
              let conversation,
              let observationToken = observeConversationContent(
                  conversationID: conversation.id
              )
        else {
            return
        }
        let selectionToken = observationToken.selection
        do {
            let batch = try await client.pollEvents(maxEvents: 128)
#if DEBUG
            await pollBatchCommitHookForTesting?()
#endif
            guard conversationContentObservationIsCurrent(observationToken) else {
                return
            }
            var shouldReconcile = batch.droppedEventCount > 0
            var appliedEvent = false
            var pollContentToken: ConversationContentToken?
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
                guard eventCanMutateCurrentContent(event) else {
                    continue
                }
                if pollContentToken == nil {
                    pollContentToken = claimConversationContentCommit(
                        observationToken
                    )
                }
                guard let pollContentToken,
                      conversationContentIsCurrent(pollContentToken)
                else {
                    return
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
                let contentToken =
                    pollContentToken
                    ?? claimConversationContentCommit(
                        observationToken
                    )
                guard let contentToken else {
                    return
                }
                await reconcilePersistedMessages(
                    conversationID: conversation.id,
                    contentToken: contentToken
                )
            }
        } catch {
            if conversationContentObservationIsCurrent(observationToken) {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func eventCanMutateCurrentContent(_ event: ChatEvent) -> Bool {
        guard event.generationID == activeGenerationID,
              event.sequence
                  > (latestSequenceByGeneration[event.generationID] ?? 0)
        else {
            return false
        }

        switch event.kind {
        case "generation_started":
            return !messages.contains {
                $0.generationID == event.generationID
                    && $0.status != .pending
            }
        case "text_delta":
            return event.text != nil
                && !messages.contains {
                    $0.generationID == event.generationID
                        && $0.status != .pending
                }
        case "usage_updated",
             "message_committed",
             "generation_finished",
             "generation_cancelled",
             "generation_failed":
            return true
        default:
            return false
        }
    }

    private enum EventApplication {
        case ignored
        case applied
        case reconcile
    }

    private func apply(_ event: ChatEvent) -> EventApplication {
        guard let currentActiveGenerationID = activeGenerationID,
              event.generationID == currentActiveGenerationID
        else {
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
            errorMessage = Self.providerErrorMessage(for: event.errorCode)
                ?? "응답 생성에 실패했습니다. 잠시 후 다시 시도하세요."
            finishGeneration()
            return .reconcile
        default:
            return .ignored
        }
    }

    private func finishGeneration() {
        if let activeGenerationID {
            latestSequenceByGeneration.removeValue(
                forKey: activeGenerationID
            )
        }
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
        await refreshMessages()
        startPolling()
    }

    public func pauseEventPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func setProviderStoreAutoRefreshEnabledForTesting(
        _ isEnabled: Bool
    ) {
        providerStoreAutoRefreshEnabled = isEnabled
    }

#if DEBUG
    func setBranchMetadataCommitHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        branchMetadataCommitHookForTesting = hook
    }

    func setMessageActionRestoreCommitHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        messageActionRestoreCommitHookForTesting = hook
    }

    func setConversationRestoreCommitHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        conversationRestoreCommitHookForTesting = hook
    }

    func setConversationSelectionErrorCommitHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        conversationSelectionErrorCommitHookForTesting = hook
    }

    func setPollBatchCommitHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        pollBatchCommitHookForTesting = hook
    }

    func setSubmitMessageSuccessCommitHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        submitMessageSuccessCommitHookForTesting = hook
    }

    func setSubmitMessageGenerationCommitHookForTesting(
        _ hook: (@MainActor (String) -> Void)?
    ) {
        submitMessageGenerationCommitHookForTesting = hook
    }

    func setSubmitMessageErrorCommitHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        submitMessageErrorCommitHookForTesting = hook
    }

    func setCancelGenerationErrorCommitHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        cancelGenerationErrorCommitHookForTesting = hook
    }

    func restoreAfterMessageActionForTesting(
        conversationID: String,
        branchID: String
    ) async throws -> Bool {
        guard let selectionToken = conversationSelectionToken(
            conversationID: conversationID
        ) else {
            return false
        }
        return try await restoreAfterMessageAction(
            conversationID: conversationID,
            branchID: branchID,
            generationID: nil,
            selectionToken: selectionToken
        )
    }
#endif

    public func refreshProviderSelection() async {
        guard !isChangingProviderProfile else {
            return
        }
        guard providerConfigurationStore?.mutatingProfileIDs.isEmpty != false
        else {
            return
        }
        providerRefreshRevision &+= 1
        let refreshRevision = providerRefreshRevision
        let selectionRevision = providerSelectionRevision
        let configurationRevisionBeforeRead =
            providerConfigurationStore?.revision

        do {
            async let profilesTask = client.listProviderProfiles()
            async let settingsTask = client.getSettings()
            let (profiles, settings) = try await (
                profilesTask,
                settingsTask
            )
            guard providerRefreshRevision == refreshRevision,
                  providerSelectionRevision == selectionRevision
            else {
                return
            }
            guard providerConfigurationRevisionIsCurrent(
                configurationRevisionBeforeRead
            ) else {
                scheduleProviderSelectionRefresh()
                return
            }
            if let selectedProfileID =
                settings.selectedProviderProfileID
            {
                guard profiles.contains(where: {
                    $0.id == selectedProfileID
                }) else {
                    applyProviderConfiguration(
                        profiles: profiles,
                        selectedProfileID: nil
                    )
                    errorMessage = userFacingProviderError(
                        ProviderAccessFailure.invalidSelection,
                        fallback: "프로바이더 설정을 확인하세요."
                    )
                    return
                }
                guard !providerProfileIsBlocked(selectedProfileID) else {
                    providerRefreshErrorMessage = nil
                    errorMessage = Self.blockedProviderMessage
                    return
                }
            }
            applyProviderConfiguration(
                profiles: profiles,
                selectedProfileID: settings.selectedProviderProfileID
            )
            let credentialRevision = credentialAccessRevision
            let configurationRevision =
                providerConfigurationStore?.revision
            var credentialFailureMessage: String?
            if let profileID = selectedProviderProfileID {
                guard !providerProfileIsBlocked(profileID) else {
                    providerRefreshErrorMessage = nil
                    errorMessage = Self.blockedProviderMessage
                    return
                }
                do {
                    _ = try await credentialForProvider(
                        profileID: profileID
                    )
                    guard providerRefreshRevision == refreshRevision,
                          providerSelectionRevision == selectionRevision
                    else {
                        return
                    }
                    guard providerConfigurationIsCurrent(
                        profileID: profileID,
                        revision: configurationRevision
                    ) else {
                        scheduleProviderSelectionRefresh()
                        return
                    }
                    if credentialAccessRevision == credentialRevision {
                        credentialAccessRevision &+= 1
                        credentialFailureProfileID = nil
                        hasProviderCredentialAccessFailure = false
                        if errorMessage
                            == Self.credentialAccessFailureMessage
                            || errorMessage
                                == Self.credentialTooLargeMessage
                            || errorMessage
                                == Self.blockedProviderMessage
                        {
                            errorMessage = nil
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard providerRefreshRevision == refreshRevision,
                          providerSelectionRevision == selectionRevision
                    else {
                        return
                    }
                    guard providerConfigurationIsCurrent(
                        profileID: profileID,
                        revision: configurationRevision
                    ) else {
                        scheduleProviderSelectionRefresh()
                        return
                    }
                    guard credentialAccessRevision == credentialRevision else {
                        return
                    }
                    credentialAccessRevision &+= 1
                    credentialFailureProfileID = profileID
                    hasProviderCredentialAccessFailure = true
                    credentialFailureMessage =
                        userFacingCredentialError(error)
                }
            } else if credentialAccessRevision == credentialRevision {
                credentialAccessRevision &+= 1
                credentialFailureProfileID = nil
                hasProviderCredentialAccessFailure = false
                if errorMessage == Self.credentialAccessFailureMessage
                    || errorMessage == Self.credentialTooLargeMessage
                    || errorMessage == Self.blockedProviderMessage
                {
                    errorMessage = nil
                }
            }
            if errorMessage == providerRefreshErrorMessage {
                errorMessage = nil
            }
            providerRefreshErrorMessage = nil
            if let credentialFailureMessage {
                errorMessage = credentialFailureMessage
            }
        } catch is CancellationError {
            return
        } catch {
            // A transient settings failure must not erase the last known,
            // still-usable model choice from the composer.
            guard providerRefreshRevision == refreshRevision,
                  providerSelectionRevision == selectionRevision
            else {
                return
            }
            guard providerConfigurationRevisionIsCurrent(
                configurationRevisionBeforeRead
            ) else {
                scheduleProviderSelectionRefresh()
                return
            }
            guard providerProfiles.isEmpty else {
                return
            }
            let providerError = userFacingProviderError(
                error,
                fallback: "모델 목록을 불러오지 못했습니다. 프로바이더 설정에서 다시 시도하세요."
            )
            providerRefreshErrorMessage = providerError
            errorMessage = providerError
        }
    }

    public func selectProviderProfile(id: String) async {
        guard
            id != selectedProviderProfileID,
            providerProfiles.contains(where: { $0.id == id }),
            !providerProfileIsBlocked(id),
            canChangeProviderProfile
        else {
            return
        }

        providerSelectionRevision &+= 1
        let revision = providerSelectionRevision
        let configurationRevision =
            providerConfigurationStore?.revision
        isChangingProviderProfile = true
        defer {
            if providerSelectionRevision == revision {
                isChangingProviderProfile = false
            }
        }

        do {
            try validateProviderProfileAvailability(
                profileID: id,
                revision: configurationRevision
            )
            let updated = try await client.selectProviderProfile(id: id)
            guard providerSelectionRevision == revision else {
                return
            }
            try validateProviderProfileAvailability(
                profileID: id,
                revision: configurationRevision
            )
            applyProviderConfiguration(
                profiles: providerProfiles,
                selectedProfileID: updated.selectedProviderProfileID
            )
            guard selectedProviderProfileID == id else {
                errorMessage =
                    "기본 프로바이더 변경 결과를 확인할 수 없습니다. 다시 시도하세요."
                return
            }
            let configurationRevision =
                providerConfigurationStore?.revision
            do {
                _ = try await credentialForProvider(profileID: id)
                guard providerSelectionRevision == revision,
                      providerConfigurationIsCurrent(
                          profileID: id,
                          revision: configurationRevision
                      )
                else {
                    return
                }
                credentialAccessRevision &+= 1
                credentialFailureProfileID = nil
                hasProviderCredentialAccessFailure = false
            } catch is CancellationError {
                return
            } catch {
                guard providerSelectionRevision == revision,
                      providerConfigurationIsCurrent(
                          profileID: id,
                          revision: configurationRevision
                      )
                else {
                    return
                }
                credentialAccessRevision &+= 1
                credentialFailureProfileID = id
                hasProviderCredentialAccessFailure = true
                errorMessage = userFacingCredentialError(error)
                return
            }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            if providerSelectionRevision == revision {
                errorMessage = userFacingProviderError(
                    error,
                    fallback: "기본 프로바이더를 변경하지 못했습니다. 다시 시도하세요."
                )
            }
        }
    }

    private var activeBranch: CoreConversationBranch? {
        guard let activeBranchID else {
            return nil
        }
        return branches.first { $0.id == activeBranchID }
    }

    private struct SelectedProviderAccess {
        let profile: ProviderProfile
        let credential: String?
        let configurationRevision: UInt64?
    }

    private enum ProviderAccessFailure: Error {
        case noProfiles
        case selectionRequired
        case invalidSelection
        case credentialUnavailable
        case credentialTooLarge
        case profileBlocked
        case configurationChanged
    }

    private func selectedProviderAccess() async throws -> SelectedProviderAccess {
        guard providerConfigurationStore?.mutatingProfileIDs.isEmpty != false
        else {
            throw ProviderAccessFailure.configurationChanged
        }
        let configurationRevisionBeforeRead =
            providerConfigurationStore?.revision
        async let profilesTask = client.listProviderProfiles()
        async let settingsTask = client.getSettings()
        let (profiles, settings) = try await (profilesTask, settingsTask)

        guard providerConfigurationRevisionIsCurrent(
            configurationRevisionBeforeRead
        ) else {
            scheduleProviderSelectionRefresh()
            throw ProviderAccessFailure.configurationChanged
        }

        guard !profiles.isEmpty else {
            applyProviderConfiguration(
                profiles: [],
                selectedProfileID: nil
            )
            throw ProviderAccessFailure.noProfiles
        }
        guard let profileID = settings.selectedProviderProfileID else {
            applyProviderConfiguration(
                profiles: profiles,
                selectedProfileID: nil
            )
            throw ProviderAccessFailure.selectionRequired
        }
        guard let profile = profiles.first(where: { $0.id == profileID }) else {
            applyProviderConfiguration(
                profiles: profiles,
                selectedProfileID: nil
            )
            throw ProviderAccessFailure.invalidSelection
        }
        guard !providerProfileIsBlocked(profileID) else {
            throw ProviderAccessFailure.profileBlocked
        }
        applyProviderConfiguration(
            profiles: profiles,
            selectedProfileID: profileID
        )
        let configurationRevision = providerConfigurationStore?.revision

        let credential: String?
        do {
            credential = try await credentialForProvider(
                profileID: profileID
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if providerProfileIsBlocked(profileID) {
                throw ProviderAccessFailure.profileBlocked
            }
            guard providerConfigurationIsCurrent(
                profileID: profile.id,
                revision: configurationRevision
            ) else {
                scheduleProviderSelectionRefresh()
                throw ProviderAccessFailure.configurationChanged
            }
            credentialAccessRevision &+= 1
            credentialFailureProfileID = profileID
            hasProviderCredentialAccessFailure = true
            if let credentialError = error as? CredentialStoreError,
               credentialError == .credentialTooLarge
            {
                throw ProviderAccessFailure.credentialTooLarge
            }
            throw ProviderAccessFailure.credentialUnavailable
        }
        guard !providerProfileIsBlocked(profileID) else {
            throw ProviderAccessFailure.profileBlocked
        }
        guard providerConfigurationIsCurrent(
            profileID: profile.id,
            revision: configurationRevision
        )
        else {
            scheduleProviderSelectionRefresh()
            throw ProviderAccessFailure.configurationChanged
        }
        credentialAccessRevision &+= 1
        credentialFailureProfileID = nil
        hasProviderCredentialAccessFailure = false
        return SelectedProviderAccess(
            profile: profile,
            credential: credential,
            configurationRevision: configurationRevision
        )
    }

    private func credentialForProvider(
        profileID: String
    ) async throws -> String? {
        let credential = try await credentialStore.credential(
            for: profileID
        )
        guard
            (credential?.utf8.count ?? 0)
                <= CredentialStorePolicy.maximumCredentialUTF8Bytes
        else {
            throw CredentialStoreError.credentialTooLarge
        }
        return credential
    }

    private func providerAccessIsCurrent(
        _ access: SelectedProviderAccess
    ) -> Bool {
        providerConfigurationIsCurrent(
            profileID: access.profile.id,
            revision: access.configurationRevision
        )
    }

    private func validateProviderAccess(
        _ access: SelectedProviderAccess
    ) throws {
        guard !providerProfileIsBlocked(access.profile.id) else {
            throw ProviderAccessFailure.profileBlocked
        }
        guard providerAccessIsCurrent(access) else {
            scheduleProviderSelectionRefresh()
            throw ProviderAccessFailure.configurationChanged
        }
    }

    private func validateProviderProfileAvailability(
        profileID: String,
        revision: UInt64?
    ) throws {
        guard !providerProfileIsBlocked(profileID) else {
            throw ProviderAccessFailure.profileBlocked
        }
        guard let providerConfigurationStore else {
            return
        }
        guard let revision,
              providerConfigurationStore.revision == revision
        else {
            scheduleProviderSelectionRefresh()
            throw ProviderAccessFailure.configurationChanged
        }
    }

    private func providerProfileIsBlocked(
        _ profileID: String
    ) -> Bool {
        providerConfigurationStore?.isBlocked(
            profileID: profileID
        ) == true
    }

    private func providerConfigurationRevisionIsCurrent(
        _ revision: UInt64?
    ) -> Bool {
        guard let providerConfigurationStore else {
            return revision == nil
        }
        guard let revision else {
            return false
        }
        return providerConfigurationStore.revision == revision
    }

    private func scheduleProviderSelectionRefresh() {
        guard !providerRefreshRetryScheduled else {
            return
        }
        providerRefreshRetryScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else {
                return
            }
            self.providerRefreshRetryScheduled = false
            await self.refreshProviderSelection()
        }
    }

    private func providerConfigurationIsCurrent(
        profileID: String,
        revision: UInt64?
    ) -> Bool {
        guard let providerConfigurationStore else {
            return selectedProviderProfileID == profileID
        }
        guard let revision else {
            return false
        }
        return providerConfigurationStore.revision == revision
            && providerConfigurationStore.selectedProfileID == profileID
            && !providerConfigurationStore.isBlocked(
                profileID: profileID
            )
    }

    private func applyProviderConfiguration(
        profiles: [ProviderProfile],
        selectedProfileID: String?
    ) {
        let sortedProfiles = profiles.sorted {
            if $0.displayName == $1.displayName {
                if $0.model == $1.model {
                    return $0.id.localizedStandardCompare($1.id)
                        == .orderedAscending
                }
                return $0.model.localizedStandardCompare($1.model)
                    == .orderedAscending
            }
            return $0.displayName.localizedStandardCompare($1.displayName)
                == .orderedAscending
        }
        let validSelection = sortedProfiles.contains {
            $0.id == selectedProfileID
        } ? selectedProfileID : nil
        providerProfiles = sortedProfiles
        selectedProviderProfileID = validSelection
        if credentialFailureProfileID != nil,
           credentialFailureProfileID != validSelection
        {
            credentialAccessRevision &+= 1
            credentialFailureProfileID = nil
            hasProviderCredentialAccessFailure = false
            if errorMessage == Self.credentialAccessFailureMessage
                || errorMessage == Self.credentialTooLargeMessage
            {
                errorMessage = nil
            }
        }
        hasLoadedProviderConfiguration = true
        providerConfigurationStore?.replace(
            profiles: sortedProfiles,
            selectedProfileID: validSelection
        )
        if errorMessage == Self.blockedProviderMessage,
           validSelection.map({
               !providerProfileIsBlocked($0)
           }) ?? true
        {
            errorMessage = nil
        }
    }

    private func userFacingProviderError(
        _ error: Error,
        fallback: String
    ) -> String {
        if let accessFailure = error as? ProviderAccessFailure {
            switch accessFailure {
            case .noProfiles:
                return "프로바이더 프로필이 없습니다. 프로바이더 설정에서 추가하세요."
            case .selectionRequired:
                return "기본 프로바이더가 선택되지 않았습니다. 프로바이더 설정에서 선택하세요."
            case .invalidSelection:
                return "선택된 프로바이더를 찾을 수 없습니다. 프로바이더 설정에서 다시 선택하세요."
            case .credentialUnavailable:
                return Self.credentialAccessFailureMessage
            case .credentialTooLarge:
                return Self.credentialTooLargeMessage
            case .profileBlocked:
                return Self.blockedProviderMessage
            case .configurationChanged:
                return "기본 프로바이더가 변경되었습니다. 메시지를 다시 보내세요."
            }
        }

        if error is CredentialStoreError {
            return userFacingCredentialError(error)
        }

        if let urlError = error as? URLError {
            if urlError.code == .timedOut {
                return "프로바이더 응답 시간이 초과되었습니다. 잠시 후 다시 시도하세요."
            }
            return "네트워크에 연결할 수 없습니다. 연결 상태를 확인한 뒤 다시 시도하세요."
        }

#if LOREPIA_UNIFFI_GENERATED
        if let ffiError = error as? FfiError,
           case let .Core(code, _, _, _) = ffiError,
           let message = Self.providerErrorMessage(for: code)
        {
            return message
        }
#endif

        if let coreFailure = error as? CoreClientFailure {
            switch coreFailure {
            case let .configurationRequired(message):
                return message
            case .bindingsUnavailable:
                return coreFailure.localizedDescription
            case .startupFailed, .invalidResponse:
                return fallback
            }
        }

        return fallback
    }

    private func userFacingCredentialError(_ error: Error) -> String {
        if let credentialError = error as? CredentialStoreError,
           credentialError == .credentialTooLarge
        {
            return Self.credentialTooLargeMessage
        }
        return Self.credentialAccessFailureMessage
    }

    private static func providerErrorMessage(for code: String?) -> String? {
        switch code {
        case "provider_auth_failed":
            "인증에 실패했습니다. 프로바이더 설정에서 API 키를 확인하세요."
        case "provider_rate_limited":
            "요청 한도에 도달했습니다. 잠시 후 다시 시도하세요."
        case "network_unavailable":
            "네트워크에 연결할 수 없습니다. 연결 상태를 확인한 뒤 다시 시도하세요."
        case "provider_unavailable":
            "프로바이더가 응답하지 않거나 시간이 초과되었습니다. 잠시 후 다시 시도하세요."
        case "provider_timeout", "timeout":
            "프로바이더 응답 시간이 초과되었습니다. 잠시 후 다시 시도하세요."
        case "cancelled":
            "응답 생성을 취소했습니다."
        default:
            nil
        }
    }

    private func restoreAfterMessageAction(
        conversationID: String,
        branchID: String,
        generationID: String?,
        selectionToken: ConversationSelectionToken
    ) async throws -> Bool {
        guard let contentToken = beginConversationContentRead(
            selectionToken: selectionToken
        ) else {
            return false
        }
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
#if DEBUG
        await messageActionRestoreCommitHookForTesting?()
#endif
        guard conversationContentIsCurrent(contentToken),
              state.activeBranchID == branchID
        else {
            return false
        }
        advanceConversationSelectionRevision()
        branches = loadedBranches
        activeBranchID = state.activeBranchID
        mode = state.selectedMode
        messages = mergePersistedMessages(restoredMessages)
        activeGenerationID = generationID
        if let generationID {
            latestSequenceByGeneration[generationID] = 0
        }
        reconcileGenerationState(from: restoredMessages)
        idlePollsSinceReconciliation = 0
        return true
    }

    private func beginConversationSelectionMutation(
        conversationID: String
    ) -> ConversationSelectionToken {
        advanceConversationSelectionRevision()
        return ConversationSelectionToken(
            conversationID: conversationID,
            revision: conversationSelectionRevision
        )
    }

    private func advanceConversationSelectionRevision() {
        conversationSelectionRevision &+= 1
        conversationContentRevision &+= 1
    }

    private func beginConversationContentRead(
        conversationID: String
    ) -> ConversationContentToken? {
        guard let selectionToken = conversationSelectionToken(
            conversationID: conversationID
        ) else {
            return nil
        }
        return beginConversationContentRead(selectionToken: selectionToken)
    }

    private func beginConversationContentRead(
        selectionToken: ConversationSelectionToken
    ) -> ConversationContentToken? {
        guard conversationSelectionIsCurrent(selectionToken) else {
            return nil
        }
        conversationContentRevision &+= 1
        return ConversationContentToken(
            selection: selectionToken,
            revision: conversationContentRevision
        )
    }

    private func observeConversationContent(
        conversationID: String
    ) -> ConversationContentObservationToken? {
        guard let selectionToken = conversationSelectionToken(
            conversationID: conversationID
        ) else {
            return nil
        }
        return ConversationContentObservationToken(
            selection: selectionToken,
            revision: conversationContentRevision
        )
    }

    private func conversationContentObservationIsCurrent(
        _ token: ConversationContentObservationToken
    ) -> Bool {
        conversationContentRevision == token.revision
            && conversationSelectionIsCurrent(token.selection)
    }

    private func claimConversationContentCommit(
        _ observation: ConversationContentObservationToken
    ) -> ConversationContentToken? {
        guard conversationContentObservationIsCurrent(observation) else {
            return nil
        }
        conversationContentRevision &+= 1
        return ConversationContentToken(
            selection: observation.selection,
            revision: conversationContentRevision
        )
    }

    private func conversationSelectionToken(
        conversationID: String
    ) -> ConversationSelectionToken? {
        guard conversation?.id == conversationID else {
            return nil
        }
        return ConversationSelectionToken(
            conversationID: conversationID,
            revision: conversationSelectionRevision
        )
    }

    private func conversationSelectionIsCurrent(
        _ token: ConversationSelectionToken,
        branchID: String? = nil
    ) -> Bool {
        guard conversation?.id == token.conversationID,
              conversationSelectionRevision == token.revision
        else {
            return false
        }
        if let branchID {
            return activeBranchID == branchID
        }
        return true
    }

    private func conversationContentIsCurrent(
        _ token: ConversationContentToken,
        branchID: String? = nil
    ) -> Bool {
        conversationContentRevision == token.revision
            && conversationSelectionIsCurrent(
                token.selection,
                branchID: branchID
            )
    }

    private func beginLoadingOperation() -> UInt64 {
        loadingOperationRevision &+= 1
        isLoading = true
        return loadingOperationRevision
    }

    private func endLoadingOperation(_ revision: UInt64) {
        guard loadingOperationRevision == revision else {
            return
        }
        isLoading = false
    }

    private var coreIsAvailable: Bool {
        if case .unavailable = runtimeMode {
            return false
        }
        return true
    }
}
