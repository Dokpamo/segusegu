import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

public struct ChatView: View {
    @ObservedObject private var viewModel: ChatViewModel
    private let onOpenProviderSettings: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.calendar) private var calendar
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    @ScaledMetric(relativeTo: .body) private var scaledListInset = 16

    @State private var followsLatest = true
    @State private var isNearBottom = true
    @State private var lastBottomObservation: ChatBottomObservation?
    @State private var isRoomSettingsPresented = false
    @State private var editingMessage: ChatMessage?
    @State private var deletingMessage: ChatMessage?
    @State private var copiedMessageID: String?
    @State private var copyFeedback = 0
    @State private var composerEditorHeight: CGFloat = 0
    /// Restored history is not newly arrived mail. Until the first transcript
    /// of a conversation has landed, messages appear in place instead of
    /// animating in, so opening a room never looks like it is rearranging.
    @State private var hasSettledInitialLoad = false
    @State private var initialLoadSettleGeneration: UInt = 0
    @FocusState private var isComposerFocused: Bool

    public init(
        viewModel: ChatViewModel,
        onOpenProviderSettings: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.onOpenProviderSettings = onOpenProviderSettings
    }

    public var body: some View {
        GeometryReader { geometry in
            Group {
                if viewModel.character != nil {
                    messageList
                } else if viewModel.isLoading {
                    ProgressView("대화를 준비하는 중")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label(
                            "대화를 선택하세요",
                            systemImage: "bubble.left.and.bubble.right"
                        )
                    } description: {
                        Text("채팅에서 캐릭터를 선택하면 저장된 대화를 이어갈 수 있습니다.")
                    }
                }
            }
            .background {
                ChatSurface.background.ignoresSafeArea()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if viewModel.character != nil {
                    composer(
                        restingSafeAreaInset:
                            geometry.safeAreaInsets.bottom
                    )
                }
            }
            .toolbar {
                if let character = viewModel.character {
                    ToolbarItem(placement: .principal) {
                        ChatToolbarIdentity(
                            character: character,
                            branch: branchSummary,
                            isEnabled: viewModel.conversation != nil
                        ) {
                            isRoomSettingsPresented = true
                        }
                    }
                }

#if os(macOS)
                if viewModel.conversation != nil {
                    ToolbarItem(placement: .primaryAction) {
                        ChatRoomSettingsTrigger(
                            mode: viewModel.mode,
                            style: .toolbar,
                            isEnabled: viewModel.conversation != nil
                        ) {
                            isRoomSettingsPresented = true
                        }
                    }
                }
#endif
            }
            .sheet(isPresented: $isRoomSettingsPresented) {
                ChatRoomSettingsSheet(
                    mode: viewModel.mode,
                    branches: viewModel.branchOptions,
                    selectedBranchID: viewModel.activeBranchID,
                    isEnabled: viewModel.canManageBranches,
                    errorMessage: viewModel.errorMessage
                ) { mode in
                    Task {
                        await viewModel.setMode(mode)
                    }
                } onSelectBranch: { branchID in
                    Task {
                        await viewModel.selectBranch(id: branchID)
                    }
                }
            }
            .sheet(item: $editingMessage) { message in
                ChatMessageEditSheet(
                    messageID: message.id,
                    text: message.text,
                    isEnabled: viewModel.canMutateMessage(message)
                ) { messageID, text in
                    await viewModel.editUserMessage(
                        messageID: messageID,
                        replacementText: text
                    )
                }
            }
            .confirmationDialog(
                "이 메시지부터 삭제할까요?",
                isPresented: Binding(
                    get: { deletingMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            deletingMessage = nil
                        }
                    }
                ),
                presenting: deletingMessage
            ) { message in
                Button("현재 흐름에서 삭제", role: .destructive) {
                    Task {
                        await viewModel.removeMessage(messageID: message.id)
                    }
                    deletingMessage = nil
                }
                Button("취소", role: .cancel) {
                    deletingMessage = nil
                }
            } message: { _ in
                Text("이 메시지와 이후 대화를 현재 흐름에서 제거합니다. 다른 분기에는 영향이 없습니다.")
            }
            .chatDetailPlatformChrome()
            .chatCopyFeedback(trigger: copyFeedback)
            .task {
                await viewModel.resumeEventPolling()
                await viewModel.refreshProviderSelection()
            }
            .onDisappear {
                initialLoadSettleGeneration &+= 1
                isComposerFocused = false
                viewModel.pauseEventPolling()
            }
        }
    }

    private var messageList: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack {
                        Color.clear
                            .frame(
                                maxWidth: .infinity,
                                minHeight: geometry.size.height
                            )
                            .accessibilityHidden(true)

                        LazyVStack(alignment: .leading, spacing: 0) {
                        conversationState

                        ForEach(
                            Array(viewModel.messages.enumerated()),
                            id: \.element.id
                        ) { index, message in
                            let previous = messageBefore(index)
                            let separatorKind = ChatTimeline.separatorKind(
                                before: message,
                                after: previous,
                                calendar: timelineCalendar
                            )
                            let joinsPrevious = ChatTimeline.canGroup(
                                previous: previous,
                                current: message,
                                calendar: timelineCalendar
                            )

                            if
                                let separatorKind,
                                let separatorText = ChatTimeline.separatorText(
                                    for: message,
                                    kind: separatorKind,
                                    calendar: timelineCalendar,
                                    locale: locale
                                ),
                                let accessibilityText =
                                    ChatTimeline.accessibilityText(
                                        for: message,
                                        calendar: timelineCalendar,
                                        locale: locale
                                    )
                            {
                                ChatTimeSeparator(
                                    text: separatorText,
                                    accessibilityText: accessibilityText
                                )
                                .padding(.top, index == 0 ? 2 : 16)
                                .padding(.bottom, 4)
                                .transition(.opacity)
                            }

                            VStack(spacing: 0) {
                                ChatBubble(
                                    message: message,
                                    maximumWidth: maximumBubbleWidth(
                                        in: geometry.size.width
                                    ),
                                    storyMaximumWidth: maximumStoryWidth(
                                        in: geometry.size.width
                                    ),
                                    mode: viewModel.mode
                                )
                                .contentShape(Rectangle())
                                .chatMessageContextMenu(
                                    message: message,
                                    isMutationEnabled:
                                        viewModel.canMutateMessage(message)
                                ) { action in
                                    handleMessageAction(
                                        action,
                                        for: message
                                    )
                                }

                                if !ChatMessageActionPresentation.actions(
                                    for: message.role
                                ).isEmpty {
                                    ChatMessageActionRow(
                                        message: message,
                                        isMutationEnabled:
                                            viewModel.canMutateMessage(message),
                                        isCopied:
                                            copiedMessageID == message.id
                                    ) { action in
                                        handleMessageAction(
                                            action,
                                            for: message
                                        )
                                    }
                                    .frame(
                                        maxWidth: messageActionMaximumWidth(
                                            for: message,
                                            in: geometry.size.width
                                        ),
                                        alignment: messageActionRowAlignment(
                                            for: message
                                        )
                                    )
                                    .frame(
                                        maxWidth: .infinity,
                                        alignment:
                                            messageActionContainerAlignment(
                                                for: message
                                            )
                                    )
                                }
                            }
                            .padding(
                                .top,
                                separatorKind != nil
                                    ? 0
                                    : (joinsPrevious ? 2 : 10)
                            )
                            .transition(messageTransition(for: message))
                            .id(message.id)

                            if let forkCount = forkCounts[message.id] {
                                ChatForkMarker(
                                    count: forkCount,
                                    gutter: railGutter
                                ) {
                                    isRoomSettingsPresented = true
                                }
                                .padding(.top, LorepiaSpacing.compact)
                                .transition(.opacity)
                            }
                        }

                        if let usageDescription = viewModel.usageDescription {
                            Text(usageDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.top, LorepiaSpacing.compact)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(ChatScrollAnchor.bottom)
                    }
                    .padding(.leading, railGutter)
                    .background(alignment: .leading) {
                        threadRail
                    }
                    .padding(.horizontal, listInset)
                    .padding(.top, LorepiaSpacing.compact)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: geometry.size.height,
                        alignment: timelineAlignment
                    )
                    .background {
                        GeometryReader { contentGeometry in
                            Color.clear.preference(
                                key: ChatLayoutPreferenceKey.self,
                                value: ChatLayoutMetrics(
                                    bottomY: contentGeometry.frame(
                                        in: .named(ChatCoordinateSpace.name)
                                    ).maxY,
                                    contentSize: contentGeometry.size
                                )
                            )
                        }
                    }
                        .animation(
                            reduceMotion || !hasSettledInitialLoad
                                ? nil
                                : .spring(duration: 0.42, bounce: 0.16),
                            value: viewModel.messages.count
                        )
                    }
                }
                .chatDefaultBottomAnchor()
                .coordinateSpace(name: ChatCoordinateSpace.name)
                .chatInteractiveKeyboardDismissal()
                .onPreferenceChange(ChatLayoutPreferenceKey.self) { metrics in
                    let observation = ChatBottomObservation(
                        scrollState: scrollState,
                        viewportSize: geometry.size,
                        contentSize: metrics.contentSize
                    )
                    let contentOrViewportChanged =
                        lastBottomObservation == nil
                            || lastBottomObservation != observation
                    lastBottomObservation = observation

                    let nearBottom =
                        metrics.bottomY
                            <= geometry.size.height
                                + followThreshold(
                                    for: geometry.size.height
                                )
                    let wasNearBottom = isNearBottom
                    isNearBottom = nearBottom
                    if nearBottom {
                        followsLatest = true
                    } else if
                        wasNearBottom,
                        !contentOrViewportChanged
                    {
                        // A position-only change means the person scrolled,
                        // regardless of whether it came from touch, a wheel,
                        // a scroll bar, or an accessibility action.
                        followsLatest = false
                    }
                }
                .onChange(of: scrollState) { previous, current in
                    let shouldFollow =
                        followsLatest
                            || isNearBottom
                            || current.lastRole == .user
                    guard shouldFollow else {
                        return
                    }
                    followsLatest = true

                    if current.count > previous.count
                        || current.lastID != previous.lastID
                    {
                        scrollToBottom(
                            proxy,
                            animated: !reduceMotion
                        )
                    } else if current.lastTextLength
                        != previous.lastTextLength
                    {
                        // Streaming deltas keep the latest line visible without
                        // starting a new animation for every token.
                        scrollToBottom(proxy, animated: false)
                    }
                }
                .onChange(of: geometry.size) { _, _ in
                    guard followsLatest else {
                        return
                    }
#if os(iOS)
                    // iOS 18+ keeps the bottom edge stable as the composer
                    // changes the viewport. A second imperative scroll after
                    // layout would visibly correct the transcript one frame
                    // later.
                    if #available(iOS 18.0, *) {
                        return
                    }
#endif
                    // Preserve the draft binding's resize transaction so the
                    // transcript and the bottom-anchored composer move as one
                    // layout instead of snapping in separate passes.
                    proxy.scrollTo(
                        ChatScrollAnchor.bottom,
                        anchor: .bottom
                    )
                }
                .onChange(
                    of: viewModel.conversation?.id,
                    initial: true
                ) { _, _ in
                    followsLatest = true
                    isNearBottom = true
                    lastBottomObservation = nil
                    hasSettledInitialLoad = false
                    scrollToBottom(proxy, animated: false)
                    initialLoadSettleGeneration &+= 1
                    let settleGeneration = initialLoadSettleGeneration
                    guard let conversationID = viewModel.conversation?.id else {
                        return
                    }
                    // Restoring reads from local storage, so the transcript
                    // lands well inside this window. Anything arriving after
                    // it is a real arrival and animates.
                    Task { @MainActor in
                        do {
                            try await Task.sleep(for: .milliseconds(150))
                        } catch {
                            return
                        }
                        guard settleGeneration == initialLoadSettleGeneration,
                              viewModel.conversation?.id == conversationID
                        else {
                            return
                        }
                        hasSettledInitialLoad = true
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                dismissComposerKeyboard()
            }
        )
    }

    /// The rail the timeline hangs from. It marks where the thread can fork, so
    /// it only appears where forking is legible: the bubble timeline.
    @ViewBuilder
    private var threadRail: some View {
        if showsThreadRail {
            Capsule()
                .fill(LorepiaColor.threadRail)
                .frame(width: ChatThreadRail.width)
                .padding(.leading, (railGutter - ChatThreadRail.width) / 2)
                .padding(.vertical, LorepiaSpacing.tight)
                .accessibilityHidden(true)
        }
    }

    private var showsThreadRail: Bool {
        viewModel.mode == .chat && !forkCounts.isEmpty
    }

    private var railGutter: CGFloat {
        showsThreadRail ? ChatThreadRail.gutter : 0
    }

    @ViewBuilder
    private var conversationState: some View {
        if viewModel.isLoading {
            ProgressView("대화를 복원하는 중")
                .frame(maxWidth: .infinity)
                .padding(.vertical, LorepiaSpacing.roomy)
                .transition(.opacity)
        } else if viewModel.messages.isEmpty {
            ContentUnavailableView {
                Label("첫 메시지를 보내보세요", systemImage: "sparkles")
            } description: {
                if viewModel.requiresProviderConfiguration {
                    Text(viewModel.providerConfigurationMessage)
                } else {
                    Text("이 대화는 이 기기에만 저장됩니다.")
                }
            } actions: {
                if viewModel.requiresProviderConfiguration {
                    Button(
                        "프로바이더 설정",
                        action: openProviderSettings
                    )
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(
                        "chat-empty-provider-settings"
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, LorepiaSpacing.roomy)
            .transition(.opacity)
        }

        if let errorMessage = viewModel.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lorepiaCard()
                .padding(.bottom, LorepiaSpacing.compact)
                .transition(.opacity)
        }
    }

    private func composer(
        restingSafeAreaInset: CGFloat
    ) -> some View {
        ChatComposer(
            draft: $viewModel.draft,
            measuredEditorHeight: $composerEditorHeight,
            focus: $isComposerFocused,
            placeholder: composerPlaceholder,
            isEnabled: viewModel.canEditDraft,
            canUseTools: viewModel.canManageBranches,
            canChangeMode: viewModel.canManageBranches,
            canChangeProviderProfile:
                viewModel.canChangeProviderProfile,
            canSubmit: viewModel.canSubmit,
            isGenerating: viewModel.isGenerating,
            mode: viewModel.mode,
            providerProfiles: viewModel.providerProfiles,
            selectedProviderProfileID:
                viewModel.selectedProviderProfileID,
            restingSafeAreaInset: restingSafeAreaInset,
            onSubmit: {
                Task {
                    await viewModel.submitMessage()
                }
            },
            onCancel: {
                Task {
                    await viewModel.cancelGeneration()
                }
            },
            onModeChange: { mode in
                Task {
                    await viewModel.setMode(mode)
                }
            },
            onProviderProfileChange: { profileID in
                Task {
                    await viewModel.selectProviderProfile(id: profileID)
                }
            },
            onOpenConversationSettings: {
                isRoomSettingsPresented = true
            },
            onOpenProviderSettings: {
                openProviderSettings()
            }
        )
    }

    private func openProviderSettings() {
        dismissComposerKeyboard()
        onOpenProviderSettings()
    }

    private func dismissComposerKeyboard() {
        isComposerFocused = false
#if os(iOS)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
#endif
    }

    /// The branch shown beneath the character name, when more than one exists.
    ///
    /// The toolbar only has room for the position, so the branch name travels
    /// in the accessibility description and in the conversation settings sheet.
    private var branchSummary: ChatBranchSummary? {
        guard viewModel.branchOptions.count > 1,
              let activeBranchID = viewModel.activeBranchID,
              let index = viewModel.branchOptions.firstIndex(
                  where: { $0.id == activeBranchID }
              )
        else {
            return nil
        }
        let position = "\(index + 1)/\(viewModel.branchOptions.count)"
        return ChatBranchSummary(
            label: position,
            description:
                "\(viewModel.branchOptions[index].title), 분기 \(position)"
        )
    }

    /// Messages the conversation forks at, with how many branches leave them.
    private var forkCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for branch in viewModel.branches {
            guard let forkMessageID = branch.forkMessageID else {
                continue
            }
            counts[forkMessageID, default: 0] += 1
        }
        return counts
    }

    private func handleMessageAction(
        _ action: ChatMessageAction,
        for message: ChatMessage
    ) {
        switch action {
        case .edit:
            guard message.role == .user,
                  viewModel.canMutateMessage(message)
            else {
                return
            }
            editingMessage = message
        case .copy:
            copyToClipboard(
                message.text,
                messageID: message.id
            )
        case .regenerate:
            guard message.role == .assistant,
                  viewModel.canMutateMessage(message)
            else {
                return
            }
            Task {
                await viewModel.regenerateAssistantMessage(
                    messageID: message.id
                )
            }
        case .branch:
            guard viewModel.canMutateMessage(message) else {
                return
            }
            Task {
                await viewModel.createBranch(afterMessageID: message.id)
            }
        case .delete:
            guard viewModel.canMutateMessage(message) else {
                return
            }
            deletingMessage = message
        }
    }

    private func copyToClipboard(
        _ text: String,
        messageID: String
    ) {
#if os(iOS)
        UIPasteboard.general.string = text
        UIAccessibility.post(
            notification: .announcement,
            argument: "메시지를 복사했습니다"
        )
#elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
#endif
        copyFeedback &+= 1
        let feedbackToken = copyFeedback
        withAnimation(
            reduceMotion ? nil : .smooth(duration: 0.2)
        ) {
            copiedMessageID = messageID
        }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard copyFeedback == feedbackToken else {
                return
            }
            withAnimation(
                reduceMotion ? nil : .smooth(duration: 0.2)
            ) {
                copiedMessageID = nil
            }
        }
    }

    private func messageActionMaximumWidth(
        for message: ChatMessage,
        in containerWidth: CGFloat
    ) -> CGFloat {
        if viewModel.mode == .story, message.role != .notice {
            return maximumStoryWidth(in: containerWidth)
        }
        return maximumBubbleWidth(in: containerWidth)
    }

    private func messageActionRowAlignment(
        for message: ChatMessage
    ) -> Alignment {
        if viewModel.mode == .story {
            return .leading
        }
        return message.role == .user ? .trailing : .leading
    }

    private func messageActionContainerAlignment(
        for message: ChatMessage
    ) -> Alignment {
        if viewModel.mode == .story, message.role != .notice {
            return .center
        }
        if message.role == .user {
            return .trailing
        }
        return .leading
    }

    private var composerPlaceholder: String {
        if viewModel.conversation == nil {
            return "대화를 준비하는 중입니다"
        }
        if viewModel.isGenerating {
            return "응답을 기다리는 중입니다"
        }
        return "메시지"
    }

    private var listInset: CGFloat {
        min(max(scaledListInset, 12), 28)
    }

    private func followThreshold(for viewportHeight: CGFloat) -> CGFloat {
        min(max(viewportHeight * 0.14, 72), 160)
    }

    private func maximumBubbleWidth(in containerWidth: CGFloat) -> CGFloat {
        let availableWidth = max(
            containerWidth - (listInset * 2) - railGutter,
            0
        )
        let ratio: CGFloat

        if dynamicTypeSize.isAccessibilitySize {
            ratio = 0.92
        } else if horizontalSizeClass == .compact {
            ratio = 0.82
        } else {
            ratio = 0.68
        }

        let readableMaximum: CGFloat =
            horizontalSizeClass == .compact ? 520 : 680
        return min(availableWidth * ratio, readableMaximum)
    }

    private func maximumStoryWidth(in containerWidth: CGFloat) -> CGFloat {
        let availableWidth = max(
            containerWidth - (listInset * 2) - railGutter,
            0
        )

        if dynamicTypeSize.isAccessibilitySize
            || horizontalSizeClass == .compact
        {
            return availableWidth
        }

        return availableWidth * 0.72
    }

    private var scrollState: ChatScrollState {
        let lastMessage = viewModel.messages.last
        return ChatScrollState(
            count: viewModel.messages.count,
            lastID: lastMessage?.id,
            lastTextLength: lastMessage?.text.count ?? 0,
            lastRole: lastMessage?.role
        )
    }

    private var timelineAlignment: Alignment {
        viewModel.messages.isEmpty ? .center : .bottom
    }

    private var timelineCalendar: Calendar {
        var localCalendar = calendar
        localCalendar.timeZone = timeZone
        return localCalendar
    }

    private func messageTransition(
        for message: ChatMessage
    ) -> AnyTransition {
        guard hasSettledInitialLoad else {
            // Restoring a conversation is not an arrival. Place the transcript
            // rather than flying every bubble in at once.
            return .identity
        }
        if reduceMotion {
            return .opacity
        }

        let insertion = AnyTransition.modifier(
            active: ChatMessageInsertionModifier(
                role: message.role,
                isActive: true
            ),
            identity: ChatMessageInsertionModifier(
                role: message.role,
                isActive: false
            )
        )
        return .asymmetric(insertion: insertion, removal: .opacity)
    }

    private func messageBefore(_ index: Int) -> ChatMessage? {
        guard index > viewModel.messages.startIndex else {
            return nil
        }
        return viewModel.messages[index - 1]
    }

    private func scrollToBottom(
        _ proxy: ScrollViewProxy,
        animated: Bool
    ) {
        if animated {
            withAnimation(.spring(duration: 0.38, bounce: 0.08)) {
                proxy.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom)
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom)
            }
        }
    }
}

/// Marks the message a conversation forks at.
///
/// The count comes from the branches the core reports for this conversation, so
/// the timeline shows where the thread splits instead of hiding it in a menu.
private struct ChatForkMarker: View {
    let count: Int
    let gutter: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                node
                Text("여기서 \(count + 1)개로 갈라짐")
                    .font(.caption)
                    .foregroundStyle(LorepiaColor.thread)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .padding(.leading, -gutter)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("분기 \(count + 1)개로 갈라지는 지점")
        .accessibilityHint("대화 설정을 열어 분기를 전환합니다")
        .accessibilityIdentifier("chat-fork-marker")
    }

    private var node: some View {
        LorepiaGlyphView(.branch, size: 15)
            .foregroundStyle(LorepiaColor.thread)
            .frame(
                width: ChatThreadRail.nodeSize,
                height: ChatThreadRail.nodeSize
            )
            .background(LorepiaColor.threadSoft, in: Circle())
            .overlay {
                Circle().strokeBorder(ChatSurface.background, lineWidth: 2)
            }
            .frame(width: max(gutter, ChatThreadRail.nodeSize))
            .accessibilityHidden(true)
    }
}

/// Shared sizing for the composer.
///
/// The 44 pt touch target is the base unit. The editor band and control rail
/// are always present; only the measured editor height changes as text wraps.
/// Glyphs and emphasized circles stay fixed while the shared Liquid Glass
/// surface reflows around them.
enum ChatComposerMetrics {
#if os(iOS)
    /// Visible primary-action circle inside its larger touch target.
    static let control: CGFloat = 32
#else
    static let control: CGFloat = 28
#endif

    /// Visible clearance between a control and the surface rim.
    static let inset: CGFloat = 8

    /// Space between a control and the editable text.
    static let gap: CGFloat = 10

    /// Touch target the controls are centered in.
    static let target: CGFloat = 44

#if os(iOS)
    /// iOS glass uses its measured layout bounds without a vertical inset.
    static let glassVerticalInset: CGFloat = 0
#else
    static let glassVerticalInset: CGFloat = 2
#endif

    /// The open surface keeps one horizontal placement.
    static let horizontalEdgeInset: CGFloat = 12

    /// Vertical placement follows the native keyboard.
    static let restingBottomInset: CGFloat = 34
    static let keyboardBottomInset: CGFloat = 12

    /// Extra layout owned by the container, outside the measured glass shape.
    /// Liquid Glass renders past its nominal bounds while settling, so the
    /// surrounding safe-area inset must not end exactly at the visible rim.
    static let glassRenderHeadroom: CGFloat = 4

    /// The surface keeps a stable corner radius while its editor grows.
    static let cornerRadius: CGFloat = 24

    /// Leading and trailing rail padding that lands the circles on `inset`.
    static var railHorizontalPadding: CGFloat {
        max(inset - (target - control) / 2, 0)
    }

    /// Bottom rail padding that lands the circles on `inset` from the rim.
    static var railBottomPadding: CGFloat {
        max(inset + glassVerticalInset - (target - control) / 2, 0)
    }

    /// The always-open surface contains one editor band and one control rail.
    static var minimumSurfaceHeight: CGFloat {
        control + (inset + glassVerticalInset) * 2 + target
    }

    /// Glass edge to text; the editor owns a row above the controls.
    static var fieldHorizontalInset: CGFloat {
        inset + gap
    }

    /// The caret begins slightly above the editor's horizontal inset.
    static let fieldTopInset: CGFloat = 16

    /// Keeps the one-line editor and its 44pt control rail within 92pt.
    static let fieldRailSpacing: CGFloat = 8
}

enum ChatThreadRail {
    static let width: CGFloat = 2
    static let gutter: CGFloat = 24
    static let nodeSize: CGFloat = 24
}

struct ChatBranchSummary: Equatable {
    let label: String
    let description: String
}

private struct ChatToolbarIdentity: View {
    let character: LibraryCharacter
    let branch: ChatBranchSummary?
    let isEnabled: Bool
    let action: () -> Void

    @ScaledMetric(relativeTo: .caption) private var scaledAvatarSize = 28
    @ScaledMetric(relativeTo: .caption) private var scaledSymbolSize = 15

    var body: some View {
#if os(iOS)
        Button(action: action) {
            VStack(spacing: -5) {
                avatar(size: 60)

                HStack(spacing: 5) {
                    Text(character.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)

                    if let branch {
                        Text(branch.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .font(.headline)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .chatContactHeaderSurface(isInteractive: isEnabled)
            }
            .fixedSize(horizontal: false, vertical: true)
            // Navigation chrome keeps a stable Messages-like silhouette while
            // the full, untruncated identity remains available to VoiceOver.
            .dynamicTypeSize(.xSmall ... .xxxLarge)
        }
        .buttonStyle(.plain)
        .offset(y: 21)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(branch?.description ?? "")
        .accessibilityHint("응답 모드와 대화 분기를 설정합니다")
        .accessibilityIdentifier("chat-room-settings-trigger-toolbar")
#else
        ViewThatFits(in: .vertical) {
            VStack(spacing: 1) {
                compactSymbol
                Text(character.name)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                compactSymbol
                Text(character.name)
                    .font(.headline)
                    .lineLimit(1)
            }

            Text(character.name)
                .font(.headline)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(character.name)
#endif
    }

    private func avatar(size: CGFloat) -> some View {
        LorepiaAvatar(
            symbolName: character.symbolName,
            seed: character.id,
            size: size
        )
    }

    private var compactSymbol: some View {
        Image(systemName: character.symbolName)
            .font(
                .system(
                    size: min(max(scaledSymbolSize, 13), 20),
                    weight: .semibold
                )
            )
            .foregroundStyle(.tint)
            .frame(
                width: min(max(scaledAvatarSize, 26), 36),
                height: min(max(scaledAvatarSize, 26), 36)
            )
            .background(
                Color.accentColor.opacity(0.12),
                in: Circle()
            )
    }

    private var accessibilityLabel: String {
        "\(character.name), 대화 설정"
    }
}

private struct ChatComposer: View {
    @Binding var draft: String
    @Binding var measuredEditorHeight: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var sendFeedback = 0
    @State private var isSoftwareKeyboardVisible = false

    let focus: FocusState<Bool>.Binding
    let placeholder: String
    let isEnabled: Bool
    let canUseTools: Bool
    let canChangeMode: Bool
    let canChangeProviderProfile: Bool
    let canSubmit: Bool
    let isGenerating: Bool
    let mode: ConversationMode
    let providerProfiles: [ProviderProfile]
    let selectedProviderProfileID: String?
    let restingSafeAreaInset: CGFloat
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onModeChange: (ConversationMode) -> Void
    let onProviderProfileChange: (String) -> Void
    let onOpenConversationSettings: () -> Void
    let onOpenProviderSettings: () -> Void

    @ScaledMetric(relativeTo: .body) private var scaledVerticalInset = 6
    @ScaledMetric(relativeTo: .body) private var scaledFieldPadding = 16
    @ScaledMetric(relativeTo: .body) private var scaledSendSymbol = 18
    @ScaledMetric(relativeTo: .body) private var scaledMinimumFieldHeight = 22

    @ViewBuilder
    var body: some View {
#if os(iOS)
        composerLayout
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillChangeFrameNotification
                )
            ) { notification in
                updateKeyboardVisibility(from: notification)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillHideNotification
                )
            ) { _ in
                setSoftwareKeyboardVisible(false)
            }
#else
        composerLayout
#endif
    }

    private var composerLayout: some View {
        composerRow
            // Preserve the measured surface geometry while giving its animated
            // Liquid Glass pixels room on the leading, trailing, and lower
            // edges. The compensating width and lower padding keep every
            // control and visual inset at the same coordinate.
            .padding(.horizontal, ChatComposerMetrics.glassRenderHeadroom)
            .padding(.bottom, ChatComposerMetrics.glassRenderHeadroom)
            .containerRelativeFrame(.horizontal, alignment: .center) {
                availableWidth,
                _ in
                constrainedWidth(for: availableWidth)
                    + ChatComposerMetrics.glassRenderHeadroom * 2
            }
            // Liquid Glass draws slightly beyond its layout bounds while it
            // morphs. Leave rendering headroom so the upper rim is never cut.
            .padding(.top, 16)
            .padding(
                .bottom,
                bottomInset
                    - restingSafeAreaOffset
                    - ChatComposerMetrics.glassRenderHeadroom
            )
#if !os(iOS)
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.24),
                value: isFocused
            )
#endif
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.26),
                value: isSoftwareKeyboardVisible
            )
    }

    @ViewBuilder
    private var composerRow: some View {
#if os(iOS)
        inputSurface
            .frame(maxWidth: .infinity)
#else
        HStack(alignment: .bottom, spacing: 8) {
            toolsMenu
            inputSurface
        }
        .frame(maxWidth: .infinity)
#endif
    }

    @ViewBuilder
    private var inputSurface: some View {
#if os(iOS)
        iosInputSurface
#else
        HStack(alignment: .bottom, spacing: 0) {
            messageField
                .padding(.leading, fieldPadding)
                .padding(.trailing, 2)
                .padding(.vertical, verticalInset)

            sendControl
        }
        .padding(.trailing, 2)
        .frame(minHeight: 44)
        .chatComposerSurface(isInteractive: isEnabled || canUseTools)
        .chatComposerBorder(
            isEmphasized: isFocused && isEnabled,
            isEnabled: isEnabled || canUseTools,
            contrast: colorSchemeContrast
        )
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.2),
            value: isFocused
        )
        .chatSendFeedback(trigger: sendFeedback)
#endif
    }

#if os(iOS)
    private var iosInputSurface: some View {
        // The editor and accessory rail are always open. Focus only presents
        // the native keyboard; it never changes the composer's own structure.
        ZStack(alignment: .bottom) {
            messageField
                .padding(
                    .leading,
                    fieldHorizontalInset
                )
                .padding(
                    .trailing,
                    fieldHorizontalInset
                )
                .padding(
                    .top,
                    fieldTopInset
                )
                .padding(
                    .bottom,
                    ChatComposerMetrics.target
                        + ChatComposerMetrics.railBottomPadding
                        + fieldRailSpacing
                )
                .layoutPriority(1)

            composerControlRail
        }
        .frame(minHeight: ChatComposerMetrics.minimumSurfaceHeight)
        // This is a composite control surface, not one giant button. Let its
        // child controls own press feedback so a control tap never scales the
        // entire composer.
        .chatComposerSurface(isInteractive: false)
        .chatComposerBorder(
            isEmphasized: isFocused && isEnabled,
            isEnabled: isEnabled || canUseTools,
            contrast: colorSchemeContrast
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("메시지 입력 영역")
        .accessibilityValue("입력 준비")
        .accessibilityIdentifier("chat-composer-surface")
        .chatSendFeedback(trigger: sendFeedback)
    }

    private var composerControlRail: some View {
        HStack(spacing: 0) {
            toolsMenu
            modelMenuControl
            modeMenuControl

            Spacer(minLength: 4)

            sendControl
        }
        .padding(.horizontal, controlRailHorizontalInset)
        .frame(height: ChatComposerMetrics.target)
        .padding(
            .bottom,
            ChatComposerMetrics.railBottomPadding
        )
    }
#endif

    @ViewBuilder
    private var messageField: some View {
#if os(iOS)
        ChatComposerEditor(
            text: $draft,
            measuredHeight: $measuredEditorHeight,
            focus: focus,
            placeholder: placeholder,
            isEnabled: isEnabled,
            maximumLines: maximumEditorLines,
            animatesHeightChanges: !reduceMotion,
            onSubmit: submit,
            onEndEditing: {
                setSoftwareKeyboardVisible(false)
            }
        )
        .frame(
            height: max(
                measuredEditorHeight,
                minimumEditorHeight
            ),
            alignment: .bottom
        )
#else
        TextField(
            placeholder,
            text: $draft,
            axis: .vertical
        )
        .lineLimit(1 ... 5)
        .submitLabel(.send)
        .focused(focus)
        .accessibilityIdentifier("chat-composer-field")
        .accessibilityLabel(placeholder)
        .disabled(!isEnabled)
        .onSubmit(submit)
#endif
    }

    @ViewBuilder
    private var sendControl: some View {
        if isGenerating {
            Button(action: onCancel) {
                cancelLabel
            }
            .buttonStyle(ChatComposerSendButtonStyle())
            .accessibilityLabel("생성 중지")
            .accessibilityHint("현재 모델 응답 생성을 중단합니다")
            .accessibilityIdentifier("chat-composer-cancel")
        } else {
            Button(action: submit) {
                sendLabel
            }
            .buttonStyle(ChatComposerSendButtonStyle())
            .disabled(!canSubmit)
            .accessibilityLabel("메시지 보내기")
        }
    }

    @ViewBuilder
    private var toolsMenu: some View {
#if os(iOS)
        toolsMenuControl
#else
        toolsMenuControl
            .chatComposerAccessorySurface(isInteractive: canUseTools)
            .chatComposerAccessoryBorder(
                isEnabled: canUseTools,
                contrast: colorSchemeContrast
            )
#endif
    }

    @ViewBuilder
    private var toolsMenuControl: some View {
        Menu {
            Button(action: onOpenConversationSettings) {
                Label(
                    "대화 설정",
                    systemImage: "slider.horizontal.3"
                )
            }
            .accessibilityIdentifier("chat-composer-tools-settings")

            Button(action: onOpenProviderSettings) {
                Label(
                    "프로바이더 설정",
                    systemImage: "gearshape"
                )
            }
            .accessibilityIdentifier(
                "chat-composer-tools-provider-settings"
            )
        } label: {
            toolsControlLabel
        }
        .buttonStyle(.plain)
        .disabled(!canUseTools)
        .accessibilityLabel("추가")
        .accessibilityHint("대화 또는 프로바이더 설정 메뉴를 엽니다")
        .accessibilityIdentifier("chat-composer-tools")
    }

    private var toolsControlLabel: some View {
        LorepiaGlyphView(.plus, size: 18)
            .frame(
                width: ChatComposerMetrics.control,
                height: ChatComposerMetrics.control
            )
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

#if os(iOS)
    private var modelMenuControl: some View {
        Menu {
            if providerProfiles.isEmpty {
                Button("설정된 프로바이더 없음", systemImage: "cpu") {}
                    .disabled(true)
            } else {
                Picker(
                    "앱 전체 기본 모델",
                    selection: providerProfileSelection
                ) {
                    ForEach(providerProfiles) { profile in
                        Label(
                            providerTitle(profile),
                            systemImage: "cpu"
                        )
                            .tag(Optional(profile.id))
                            .accessibilityIdentifier(
                                "chat-composer-model-option-\(profile.id)"
                            )
                    }
                }
                .pickerStyle(.inline)
                .disabled(!canChangeProviderProfile)
            }

            Divider()

            Button(action: onOpenProviderSettings) {
                Label("프로바이더 설정", systemImage: "gearshape")
            }
            .accessibilityIdentifier("chat-composer-provider-settings")
        } label: {
            HStack(spacing: 4) {
                Text(
                    selectedProviderProfile.map(providerTitle)
                        ?? "프로바이더 설정"
                )
                    .lineLimit(1)
                    .truncationMode(.middle)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(maxWidth: 148)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("앱 전체 기본 모델")
        .accessibilityValue(
            selectedProviderProfile.map(providerTitle)
                ?? "선택 안 됨"
        )
        .accessibilityHint("기본 모델을 선택하거나 프로바이더 설정을 엽니다")
        .accessibilityIdentifier("chat-composer-model")
    }

    private var modeMenuControl: some View {
        Menu {
            Picker("응답 방식", selection: modeSelection) {
                ForEach(ConversationMode.allCases) { option in
                    Label(option.title, systemImage: option.systemImage)
                        .tag(option)
                        .accessibilityIdentifier(
                            "chat-composer-mode-option-\(option.rawValue)"
                        )
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: mode.systemImage)
                Text(mode.title)
                    .lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canChangeMode)
        .accessibilityLabel("응답 방식")
        .accessibilityValue("\(mode.title) 모드")
        .accessibilityHint("채팅과 스토리 응답 방식을 선택합니다")
        .accessibilityIdentifier("chat-composer-mode")
    }

    private var providerProfileSelection: Binding<String?> {
        Binding(
            get: {
                selectedProviderProfileID
            },
            set: { profileID in
                guard
                    let profileID,
                    profileID != selectedProviderProfileID
                else {
                    return
                }
                onProviderProfileChange(profileID)
            }
        )
    }

    private var modeSelection: Binding<ConversationMode> {
        Binding(
            get: {
                mode
            },
            set: { option in
                guard option != mode else {
                    return
                }
                onModeChange(option)
            }
        )
    }
#endif

    private var selectedProviderProfile: ProviderProfile? {
        guard let selectedProviderProfileID else {
            return nil
        }
        return providerProfiles.first {
            $0.id == selectedProviderProfileID
        }
    }

    private func providerTitle(_ profile: ProviderProfile) -> String {
        "\(profile.displayName) · \(profile.model)"
    }

    private var isFocused: Bool {
        focus.wrappedValue
    }

#if os(iOS)
    private var maximumEditorLines: Int {
        if verticalSizeClass == .compact {
            return 4
        }
        if dynamicTypeSize.isAccessibilitySize {
            return 6
        }
        return 10
    }

#endif

    private func constrainedWidth(for availableWidth: CGFloat) -> CGFloat {
        let insetWidth = max(
            availableWidth - (horizontalInset(for: availableWidth) * 2),
            0
        )
#if os(iOS)
        // Phone widths remain fluid while the open surface keeps one inset.
        return insetWidth
#else
        return min(insetWidth, 720)
#endif
    }

    private func horizontalInset(for availableWidth: CGFloat) -> CGFloat {
#if os(iOS)
        ChatComposerMetrics.horizontalEdgeInset
#else
        min(max(availableWidth * 0.07, 20), 32)
#endif
    }

    private var controlRailHorizontalInset: CGFloat {
        ChatComposerMetrics.railHorizontalPadding
    }

    private var fieldHorizontalInset: CGFloat {
        ChatComposerMetrics.fieldHorizontalInset
    }

    private var fieldTopInset: CGFloat {
        ChatComposerMetrics.fieldTopInset
    }

    private var fieldRailSpacing: CGFloat {
        ChatComposerMetrics.fieldRailSpacing
    }

    private var bottomInset: CGFloat {
#if os(iOS)
        // The surface structure stays open. Only its platform-owned clearance
        // changes when the native software keyboard actually covers the bottom.
        let visualInset = isSoftwareKeyboardVisible
            ? ChatComposerMetrics.keyboardBottomInset
            : ChatComposerMetrics.restingBottomInset
        return max(
            visualInset - ChatComposerMetrics.glassVerticalInset,
            0
        )
#else
        12
#endif
    }

    private var restingSafeAreaOffset: CGFloat {
#if os(iOS)
        isSoftwareKeyboardVisible ? 0 : max(restingSafeAreaInset, 0)
#else
        0
#endif
    }

    private var verticalInset: CGFloat {
        min(max(scaledVerticalInset, 4), 10)
    }

    private var minimumEditorHeight: CGFloat {
        max(scaledMinimumFieldHeight, 20)
    }

    private var fieldPadding: CGFloat {
        min(max(scaledFieldPadding, 12), 18)
    }

    private var sendLabel: some View {
        ZStack {
            Circle()
                .fill(sendBackgroundStyle)
                .frame(
                    width: ChatComposerMetrics.control * 22 / 24,
                    height: ChatComposerMetrics.control * 22 / 24
                )

            LorepiaGlyphView(
                .send,
                size: ChatComposerMetrics.control
            )
            .foregroundStyle(sendForegroundStyle)
        }
            .frame(
                width: ChatComposerMetrics.control,
                height: ChatComposerMetrics.control
            )
            .chatSendGlyphEffect(
                trigger: sendFeedback,
                reduceMotion: reduceMotion
            )
            .animation(
                reduceMotion
                    ? nil
                    : .snappy(duration: 0.2, extraBounce: 0.04),
                value: canSubmit
            )
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }

    private var cancelLabel: some View {
        Image(systemName: "stop.fill")
            .font(
                .system(
                    size: min(max(scaledSendSymbol, 15), 18),
                    weight: .semibold
                )
            )
            .foregroundStyle(Color.white)
            .frame(
                width: ChatComposerMetrics.control,
                height: ChatComposerMetrics.control
            )
            .background(LorepiaColor.ember, in: Circle())
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }

    private var sendForegroundStyle: Color {
        guard canSubmit else {
            return Color.primary.opacity(
                colorSchemeContrast == .increased ? 0.62 : 0.34
            )
        }
        return .white
    }

    private var sendBackgroundStyle: AnyShapeStyle {
        if canSubmit {
            return AnyShapeStyle(Color.black)
        }
        return AnyShapeStyle(
            Color.primary.opacity(
                colorSchemeContrast == .increased ? 0.14 : 0.07
            )
        )
    }

#if os(iOS)
    @MainActor
    private func updateKeyboardVisibility(from notification: Notification) {
        guard
            let frame = notification.userInfo?[
                UIResponder.keyboardFrameEndUserInfoKey
            ] as? CGRect,
            let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)
        else {
            return
        }

        let frameInWindow = window.convert(
            frame,
            from: window.screen.coordinateSpace
        )
        let overlap = window.bounds.intersection(frameInWindow)
        let coversWindowBottom =
            abs(frameInWindow.maxY - window.bounds.maxY) <= 2
        setSoftwareKeyboardVisible(
            !overlap.isNull
                && overlap.height > 0
                && coversWindowBottom
        )
    }

    @MainActor
    private func setSoftwareKeyboardVisible(_ visible: Bool) {
        // A hide transition from a previous dismissal can finish after the
        // field has already been focused again. Let the current focus request
        // win so that stale keyboard notifications cannot drop the composer.
        if !visible && isFocused {
            return
        }
        isSoftwareKeyboardVisible = visible
    }
#endif

    private func submit() {
        guard canSubmit else {
            return
        }
        sendFeedback &+= 1
        onSubmit()
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    let maximumWidth: CGFloat
    let storyMaximumWidth: CGFloat
    let mode: ConversationMode

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @ScaledMetric(relativeTo: .body) private var scaledHorizontalPadding = 14
    @ScaledMetric(relativeTo: .body) private var scaledVerticalPadding = 7
    @ScaledMetric(relativeTo: .body) private var scaledStoryLineSpacing = 5
    @ScaledMetric(relativeTo: .body) private var scaledStoryVerticalPadding = 7

    var body: some View {
        Group {
            if message.role == .system || message.role == .notice {
                notice
            } else if isStoryProse {
                storyProse
            } else if isStoryUserLine {
                storyUserLine
            } else {
                bubble
            }
        }
    }

    private var isStoryProse: Bool {
        mode == .story && message.role == .assistant
    }

    private var isStoryUserLine: Bool {
        mode == .story && message.role == .user
    }

    private var bubble: some View {
        HStack(spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(message.text.isEmpty ? "…" : message.text)
                    .font(.body)
                    .textSelection(.enabled)
                if message.status != .complete {
                    Text(statusText)
                        .font(.caption2)
                        .opacity(0.75)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .foregroundStyle(foregroundStyle)
            .background(backgroundStyle, in: bubbleShape)
            .frame(maxWidth: maximumWidth, alignment: alignment)

            if message.role != .user {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var storyProse: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.text.isEmpty ? "…" : message.text)
                .font(.system(.body, design: .serif))
                .lineSpacing(scaledStoryLineSpacing)
                .textSelection(.enabled)

            if message.status != .complete {
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .padding(.vertical, scaledStoryVerticalPadding)
        .frame(width: storyMaximumWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// The reader's own line in story mode: prose, marked rather than boxed.
    private var storyUserLine: some View {
        HStack(alignment: .top, spacing: LorepiaSpacing.snug) {
            Capsule()
                .fill(LorepiaColor.loreFill)
                .frame(width: 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(message.text.isEmpty ? "…" : message.text)
                    .font(.system(.body, design: .serif))
                    .lineSpacing(scaledStoryLineSpacing)
                    .foregroundStyle(LorepiaColor.loreAccent)
                    .textSelection(.enabled)

                if message.status != .complete {
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, scaledStoryVerticalPadding)
        .frame(width: storyMaximumWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var notice: some View {
        Text(message.text.isEmpty ? statusText : message.text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding / 2)
            .background(
                ChatSurface.incomingMessage,
                in: Capsule()
            )
            .frame(maxWidth: maximumWidth)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(accessibilityText)
    }

    private var alignment: Alignment {
        message.role == .user ? .trailing : .leading
    }

    private var bubbleShape: ChatBubbleShape {
        ChatBubbleShape(
            isOutgoing: message.role == .user
        )
    }

    private var horizontalPadding: CGFloat {
        min(max(scaledHorizontalPadding, 12), 20)
    }

    private var verticalPadding: CGFloat {
        min(max(scaledVerticalPadding, 7), 16)
    }

    private var foregroundStyle: Color {
        message.role == .user ? .white : .primary
    }

    private var backgroundStyle: Color {
        message.role == .user
            ? LorepiaColor.loreFill
            : ChatSurface.incomingMessage
    }

    private var statusText: String {
        switch message.status {
        case .pending:
            "생성 중"
        case .cancelled:
            "취소됨"
        case .failed:
            "실패"
        case .complete:
            "완료"
        case .notice:
            "안내"
        }
    }

    private var accessibilityText: String {
        let speaker = switch message.role {
        case .user:
            "나"
        case .assistant:
            "캐릭터"
        case .system:
            "시스템"
        case .notice:
            "안내"
        }
        let status = message.status == .complete ? "" : ", \(statusText)"
        return "\(speaker): \(message.text)\(status)"
    }

}

private struct ChatTimeSeparator: View {
    let text: String
    let accessibilityText: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(accessibilityText)
    }
}

struct ChatBubbleShape: Shape {
    struct CornerRadii: Equatable {
        let topLeading: CGFloat
        let bottomLeading: CGFloat
        let bottomTrailing: CGFloat
        let topTrailing: CGFloat
    }

    let isOutgoing: Bool

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else {
            return Path()
        }

        let radii = resolvedRadii(in: rect)
        return UnevenRoundedRectangle(
            topLeadingRadius: radii.topLeading,
            bottomLeadingRadius: radii.bottomLeading,
            bottomTrailingRadius: radii.bottomTrailing,
            topTrailingRadius: radii.topTrailing,
            style: .continuous
        )
        .path(in: rect)
    }

    func resolvedRadii(in rect: CGRect) -> CornerRadii {
        let largeRadius = min(18, rect.width / 2, rect.height / 2)
        let tightRadius = min(4, largeRadius)

        if isOutgoing {
            return CornerRadii(
                topLeading: largeRadius,
                bottomLeading: largeRadius,
                bottomTrailing: tightRadius,
                topTrailing: largeRadius
            )
        }

        return CornerRadii(
            topLeading: tightRadius,
            bottomLeading: largeRadius,
            bottomTrailing: largeRadius,
            topTrailing: largeRadius
        )
    }
}

private struct ChatMessageInsertionModifier: ViewModifier {
    let role: ChatMessage.Role
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isActive ? 0 : 1)
            .blur(radius: isActive ? 2.5 : 0)
            .scaleEffect(
                isActive ? scale : 1,
                anchor: anchor
            )
            .offset(
                x: isActive ? horizontalOffset : 0,
                y: isActive ? verticalOffset : 0
            )
    }

    private var anchor: UnitPoint {
        role == .user ? .bottomTrailing : .bottomLeading
    }

    private var scale: CGFloat {
        switch role {
        case .user:
            0.82
        case .assistant:
            0.92
        case .system, .notice:
            0.98
        }
    }

    private var horizontalOffset: CGFloat {
        switch role {
        case .user:
            14
        case .assistant:
            -8
        case .system, .notice:
            0
        }
    }

    private var verticalOffset: CGFloat {
        switch role {
        case .user:
            24
        case .assistant:
            14
        case .system, .notice:
            6
        }
    }
}

private struct ChatComposerSendButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(
                reduceMotion
                    ? 1
                    : (configuration.isPressed ? 0.86 : 1)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(
                reduceMotion
                    ? nil
                    : .spring(duration: 0.18, bounce: 0.24),
                value: configuration.isPressed
            )
    }
}

private struct ChatScrollState: Equatable {
    let count: Int
    let lastID: String?
    let lastTextLength: Int
    let lastRole: ChatMessage.Role?
}

private struct ChatBottomObservation: Equatable {
    let scrollState: ChatScrollState
    let viewportSize: CGSize
    let contentSize: CGSize
}

private enum ChatScrollAnchor {
    static let bottom = "chat-bottom-anchor"
}

private enum ChatCoordinateSpace {
    static let name = "chat-scroll-coordinate-space"
}

private enum ChatSurface {
    static var background: Color {
#if os(iOS)
        Color(uiColor: .systemBackground)
#else
        LorepiaColor.paper
#endif
    }

    static var incomingMessage: Color {
#if os(iOS)
        Color(uiColor: .systemGray5)
#else
        LorepiaColor.incomingFill
#endif
    }
}

private struct ChatLayoutMetrics: Equatable {
    let bottomY: CGFloat
    let contentSize: CGSize
}

private struct ChatLayoutPreferenceKey: PreferenceKey {
    static let defaultValue = ChatLayoutMetrics(
        bottomY: .greatestFiniteMagnitude,
        contentSize: .zero
    )

    static func reduce(
        value: inout ChatLayoutMetrics,
        nextValue: () -> ChatLayoutMetrics
    ) {
        value = nextValue()
    }
}

/// Keeps the measured Liquid Glass surface around its 44 pt hit targets.
private struct ChatComposerFieldGlassShape: Shape {
    func path(in rect: CGRect) -> Path {
        let visualRect = rect.insetBy(
            dx: 0,
            dy: ChatComposerMetrics.glassVerticalInset
        )
        return RoundedRectangle(
            cornerRadius: min(
                ChatComposerMetrics.cornerRadius,
                visualRect.height / 2
            ),
            style: .continuous
        )
        .path(in: visualRect)
    }
}

/// Messages left-aligns a 40 pt glass circle inside its 44 pt tool target.
private struct ChatComposerAccessoryGlassShape: Shape {
    func path(in rect: CGRect) -> Path {
        let diameter = max(min(rect.width, rect.height) - 4, 0)
        let visualRect = CGRect(
            x: rect.minX,
            y: rect.midY - (diameter / 2),
            width: diameter,
            height: diameter
        )
        return Circle().path(in: visualRect)
    }
}

private extension View {
    @ViewBuilder
    func chatDefaultBottomAnchor() -> some View {
#if os(iOS)
        if #available(iOS 18.0, *) {
            defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .defaultScrollAnchor(.bottom, for: .alignment)
        } else {
            self
        }
#else
        self
#endif
    }

    @ViewBuilder
    func chatDetailPlatformChrome() -> some View {
#if os(iOS)
        toolbar(.hidden, for: .tabBar)
#else
        self
#endif
    }

    @ViewBuilder
    func chatInteractiveKeyboardDismissal() -> some View {
#if os(iOS)
        scrollDismissesKeyboard(.interactively)
#else
        self
#endif
    }

    @ViewBuilder
    func chatComposerSurface(isInteractive: Bool) -> some View {
#if os(iOS)
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glassEffect(
                .regular.interactive(isInteractive),
                in: ChatComposerFieldGlassShape()
            )
        } else {
            background(
                .regularMaterial,
                in: ChatComposerFieldGlassShape()
            )
        }
#else
        background(
            .regularMaterial,
            in: ChatComposerFieldGlassShape()
        )
#endif
#else
        background(
            .regularMaterial,
            in: ChatComposerFieldGlassShape()
        )
#endif
    }

    @ViewBuilder
    func chatComposerAccessorySurface(isInteractive: Bool) -> some View {
#if os(iOS)
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glassEffect(
                .regular.interactive(isInteractive),
                in: ChatComposerAccessoryGlassShape()
            )
        } else {
            background(
                .regularMaterial,
                in: ChatComposerAccessoryGlassShape()
            )
        }
#else
        background(.regularMaterial, in: ChatComposerAccessoryGlassShape())
#endif
#else
        background(.regularMaterial, in: ChatComposerAccessoryGlassShape())
#endif
    }

    @ViewBuilder
    func chatContactHeaderSurface(isInteractive: Bool) -> some View {
#if os(iOS)
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glassEffect(
                .regular.interactive(isInteractive),
                in: Capsule()
            )
        } else {
            background(.regularMaterial, in: Capsule())
        }
#else
        background(.regularMaterial, in: Capsule())
#endif
#else
        background(.regularMaterial, in: Capsule())
#endif
    }

    @ViewBuilder
    func chatComposerAccessoryBorder(
        isEnabled: Bool,
        contrast: ColorSchemeContrast
    ) -> some View {
#if os(iOS) && compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self
        } else {
            overlay {
                ChatComposerAccessoryGlassShape()
                    .stroke(
                        Color.primary.opacity(
                            contrast == .increased
                                ? 0.2
                                : (isEnabled ? 0.08 : 0.04)
                        ),
                        lineWidth: contrast == .increased ? 1 : 0.5
                    )
            }
        }
#else
        overlay {
            ChatComposerAccessoryGlassShape()
                .stroke(
                    Color.primary.opacity(
                        contrast == .increased
                            ? 0.2
                            : (isEnabled ? 0.08 : 0.04)
                    ),
                    lineWidth: contrast == .increased ? 1 : 0.5
                )
        }
#endif
    }

    /// Draws a hairline around the composer only where the platform needs one.
    ///
    /// Liquid Glass already reads as a container, and the guidance is to avoid
    /// custom borders on it, so the stroke is limited to older releases.
    @ViewBuilder
    func chatComposerBorder(
        isEmphasized: Bool,
        isEnabled: Bool,
        contrast: ColorSchemeContrast
    ) -> some View {
#if os(iOS) && compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self
        } else {
            chatComposerStroke(
                isEmphasized: isEmphasized,
                isEnabled: isEnabled,
                contrast: contrast
            )
        }
#else
        chatComposerStroke(
            isEmphasized: isEmphasized,
            isEnabled: isEnabled,
            contrast: contrast
        )
#endif
    }

    func chatComposerStroke(
        isEmphasized: Bool,
        isEnabled: Bool,
        contrast: ColorSchemeContrast
    ) -> some View {
        let opacity: Double = if contrast == .increased {
            0.24
        } else if isEmphasized {
            0.16
        } else {
            isEnabled ? 0.08 : 0.04
        }
        return overlay {
            ChatComposerFieldGlassShape()
            .stroke(
                Color.primary.opacity(opacity),
                lineWidth: contrast == .increased ? 1 : 0.5
            )
        }
    }

    @ViewBuilder
    func chatSendGlyphEffect(
        trigger: Int,
        reduceMotion: Bool
    ) -> some View {
        if reduceMotion {
            self
        } else {
            phaseAnimator(
                [false, true, false],
                trigger: trigger
            ) { content, isLifted in
                content
                    .scaleEffect(isLifted ? 0.84 : 1)
                    .offset(y: isLifted ? -1.5 : 0)
            } animation: { isLifted in
                isLifted
                    ? .easeOut(duration: 0.08)
                    : .snappy(
                        duration: 0.2,
                        extraBounce: 0.08
                    )
            }
        }
    }

    @ViewBuilder
    func chatSendFeedback(trigger: Int) -> some View {
#if os(iOS)
        sensoryFeedback(
            .impact(weight: .light, intensity: 0.65),
            trigger: trigger
        )
#else
        self
#endif
    }

    @ViewBuilder
    func chatCopyFeedback(trigger: Int) -> some View {
#if os(iOS)
        sensoryFeedback(.success, trigger: trigger)
#else
        self
#endif
    }
}
