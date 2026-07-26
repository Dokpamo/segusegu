import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

public struct ChatView: View {
    @ObservedObject private var viewModel: ChatViewModel

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

    public init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if viewModel.character != nil {
                composerArea
            }
        }
        .toolbar {
            if let character = viewModel.character {
                ToolbarItem(placement: .principal) {
                    ChatToolbarIdentity(character: character)
                }
            }

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

            if viewModel.isGenerating {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        Task {
                            await viewModel.cancelGeneration()
                        }
                    } label: {
                        Image(systemName: "stop.fill")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("생성 취소")
                    .accessibilityHint("현재 모델 응답 생성을 중단합니다")
                }
            }
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
        }
        .onDisappear {
            viewModel.pauseEventPolling()
        }
    }

    private var messageList: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        conversationState

                        ForEach(
                            Array(viewModel.messages.enumerated()),
                            id: \.element.id
                        ) { index, message in
                            let previous = messageBefore(index)
                            let next = messageAfter(index)
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
                            let joinsNext = ChatTimeline.canGroup(
                                previous: message,
                                current: next,
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
                                    mode: viewModel.mode,
                                    joinsPrevious: joinsPrevious,
                                    joinsNext: joinsNext
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
                                        alignment:
                                            message.role == .user
                                                ? .trailing
                                                : .leading
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
                    .padding(.horizontal, listInset)
                    .padding(.vertical, LorepiaSpacing.compact)
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
                        reduceMotion
                            ? nil
                            : .spring(duration: 0.42, bounce: 0.16),
                        value: viewModel.messages.count
                    )
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
                    scrollToBottom(proxy, animated: false)
                }
                .onChange(
                    of: viewModel.conversation?.id,
                    initial: true
                ) { _, _ in
                    followsLatest = true
                    isNearBottom = true
                    lastBottomObservation = nil
                    scrollToBottom(proxy, animated: false)
                }
            }
        }
    }

    @ViewBuilder
    private var conversationState: some View {
        if viewModel.isLoading {
            ProgressView("대화를 복원하는 중")
                .frame(maxWidth: .infinity)
                .padding(.vertical, LorepiaSpacing.roomy)
                .transition(.opacity)
        } else if viewModel.messages.isEmpty, viewModel.errorMessage == nil {
            ContentUnavailableView {
                Label("첫 메시지를 보내보세요", systemImage: "sparkles")
            } description: {
                Text("이 대화는 이 기기에만 저장됩니다.")
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

    private var composer: some View {
        ChatComposer(
            draft: $viewModel.draft,
            placeholder: composerPlaceholder,
            isEnabled: viewModel.conversation != nil
                && !viewModel.isGenerating,
            canSubmit: viewModel.canSubmit
        ) {
            Task {
                await viewModel.submitMessage()
            }
        }
    }

    private var composerArea: some View {
        VStack(spacing: 0) {
            HStack {
                ChatRoomSettingsTrigger(
                    mode: viewModel.mode,
                    style: .modeChip,
                    isEnabled: viewModel.conversation != nil
                ) {
                    isRoomSettingsPresented = true
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, listInset)
            .padding(.top, 4)

            composer
        }
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
        if viewModel.mode == .story, message.role == .assistant {
            return maximumStoryWidth(in: containerWidth)
        }
        return maximumBubbleWidth(in: containerWidth)
    }

    private func messageActionContainerAlignment(
        for message: ChatMessage
    ) -> Alignment {
        if message.role == .user {
            return .trailing
        }
        if viewModel.mode == .story, message.role == .assistant {
            return .center
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
        let availableWidth = max(containerWidth - (listInset * 2), 0)
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
        let availableWidth = max(containerWidth - (listInset * 2), 0)

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

    private func messageAfter(_ index: Int) -> ChatMessage? {
        let nextIndex = index + 1
        guard nextIndex < viewModel.messages.endIndex else {
            return nil
        }
        return viewModel.messages[nextIndex]
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

private func chatOutgoingColor(
    for contrast: ColorSchemeContrast
) -> Color {
    contrast == .increased
        ? Color(red: 0, green: 0.30, blue: 0.72)
        : .accentColor
}

private func chatIncomingColor(
    for contrast: ColorSchemeContrast
) -> Color {
#if os(iOS)
    Color(
        uiColor:
            contrast == .increased
                ? .systemGray3
                : .systemGray5
    )
#elseif os(macOS)
    contrast == .increased
        ? Color(nsColor: .separatorColor)
        : Color(nsColor: .controlBackgroundColor)
#else
    Color.secondary.opacity(contrast == .increased ? 0.22 : 0.12)
#endif
}

private struct ChatToolbarIdentity: View {
    let character: LibraryCharacter

    @ScaledMetric(relativeTo: .caption) private var scaledAvatarSize = 28
    @ScaledMetric(relativeTo: .caption) private var scaledSymbolSize = 15

    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 1) {
                symbol
                Text(character.name)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                symbol
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
    }

    private var symbol: some View {
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
}

private struct ChatComposer: View {
    @Binding var draft: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @FocusState private var isFocused: Bool
    @State private var sendFeedback = 0

    let placeholder: String
    let isEnabled: Bool
    let canSubmit: Bool
    let onSubmit: () -> Void

    @ScaledMetric(relativeTo: .body) private var scaledHorizontalInset = 12
    @ScaledMetric(relativeTo: .body) private var scaledVerticalInset = 8
    @ScaledMetric(relativeTo: .body) private var scaledFieldPadding = 10
    @ScaledMetric(relativeTo: .title2) private var scaledSendSymbol = 28

    var body: some View {
        HStack(alignment: .bottom, spacing: LorepiaSpacing.compact) {
            TextField(
                placeholder,
                text: $draft,
                axis: .vertical
            )
            .lineLimit(1 ... 5)
            .submitLabel(.send)
            .focused($isFocused)
            .padding(.leading, fieldPadding)
            .padding(.vertical, verticalInset)
            .disabled(!isEnabled)
            .onSubmit(submit)

            Button(action: submit) {
                sendLabel
            }
            .buttonStyle(ChatComposerSendButtonStyle())
            .disabled(!canSubmit)
            .accessibilityLabel("메시지 보내기")
        }
        .padding(.trailing, 4)
        .chatComposerSurface(isInteractive: isEnabled)
        .overlay {
            Capsule()
                .strokeBorder(
                    Color.primary.opacity(
                        colorSchemeContrast == .increased
                            ? 0.24
                            : (
                                isFocused && isEnabled
                                    ? 0.16
                                    : (isEnabled ? 0.08 : 0.04)
                            )
                    ),
                    lineWidth: colorSchemeContrast == .increased ? 1 : 0.5
                )
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.2),
            value: isFocused
        )
        .chatSendFeedback(trigger: sendFeedback)
        .padding(.horizontal, horizontalInset)
        .padding(.vertical, verticalInset)
    }

    private var horizontalInset: CGFloat {
        min(max(scaledHorizontalInset, 10), 20)
    }

    private var verticalInset: CGFloat {
        min(max(scaledVerticalInset, 7), 14)
    }

    private var fieldPadding: CGFloat {
        min(max(scaledFieldPadding, 9), 15)
    }

    private var sendLabel: some View {
        Image(systemName: "arrow.up")
            .font(
                .system(
                    size: min(max(scaledSendSymbol, 20), 26),
                    weight: .bold
                )
            )
            .foregroundStyle(
                canSubmit
                    ? Color.white
                    : Color.primary.opacity(
                        colorSchemeContrast == .increased ? 0.64 : 0.38
                    )
            )
            .chatSendSymbolEffect(
                trigger: sendFeedback,
                reduceMotion: reduceMotion
            )
            .frame(width: 36, height: 36)
            .background(
                canSubmit
                    ? outgoingColor
                    : Color.primary.opacity(
                        colorSchemeContrast == .increased ? 0.16 : 0.08
                    ),
                in: Circle()
            )
            .scaleEffect(canSubmit ? 1 : 0.9)
            .animation(
                reduceMotion
                    ? nil
                    : .snappy(duration: 0.2, extraBounce: 0.04),
                value: canSubmit
            )
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }

    private var outgoingColor: Color {
        chatOutgoingColor(for: colorSchemeContrast)
    }

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
    let joinsPrevious: Bool
    let joinsNext: Bool

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @ScaledMetric(relativeTo: .body) private var scaledHorizontalPadding = 13
    @ScaledMetric(relativeTo: .body) private var scaledVerticalPadding = 8
    @ScaledMetric(relativeTo: .body) private var scaledStoryLineSpacing = 5
    @ScaledMetric(relativeTo: .body) private var scaledStoryVerticalPadding = 7

    var body: some View {
        Group {
            if message.role == .system || message.role == .notice {
                notice
            } else if isStoryProse {
                storyProse
            } else {
                bubble
            }
        }
    }

    private var isStoryProse: Bool {
        mode == .story && message.role == .assistant
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
                .font(.body)
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

    private var notice: some View {
        Text(message.text.isEmpty ? statusText : message.text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding / 2)
            .background(
                Color.secondary.opacity(0.1),
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
            isOutgoing: message.role == .user,
            joinsPrevious: joinsPrevious,
            joinsNext: joinsNext
        )
    }

    private var horizontalPadding: CGFloat {
        min(max(scaledHorizontalPadding, 12), 20)
    }

    private var verticalPadding: CGFloat {
        min(max(scaledVerticalPadding, 8), 16)
    }

    private var foregroundStyle: Color {
        message.role == .user ? .white : .primary
    }

    private var backgroundStyle: Color {
        message.role == .user
            ? chatOutgoingColor(for: colorSchemeContrast)
            : chatIncomingColor(for: colorSchemeContrast)
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
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(accessibilityText)
    }
}

private struct ChatBubbleShape: Shape {
    let isOutgoing: Bool
    let joinsPrevious: Bool
    let joinsNext: Bool

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else {
            return Path()
        }

        let largeRadius = min(max(rect.height * 0.46, 15), 20)
        let joinedRadius = min(max(largeRadius * 0.34, 5), 7)
        let terminalRadius = min(max(largeRadius * 0.46, 7), 9)

        let shape: UnevenRoundedRectangle
        if isOutgoing {
            shape = UnevenRoundedRectangle(
                topLeadingRadius: largeRadius,
                bottomLeadingRadius: largeRadius,
                bottomTrailingRadius: joinsNext
                    ? joinedRadius
                    : terminalRadius,
                topTrailingRadius: joinsPrevious
                    ? joinedRadius
                    : largeRadius,
                style: .continuous
            )
        } else {
            shape = UnevenRoundedRectangle(
                topLeadingRadius: joinsPrevious
                    ? joinedRadius
                    : largeRadius,
                bottomLeadingRadius: joinsNext
                    ? joinedRadius
                    : terminalRadius,
                bottomTrailingRadius: largeRadius,
                topTrailingRadius: largeRadius,
                style: .continuous
            )
        }

        return shape.path(in: rect)
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

private extension View {
    @ViewBuilder
    func chatDefaultBottomAnchor() -> some View {
#if os(iOS)
        if #available(iOS 18.0, *) {
            defaultScrollAnchor(.bottom, for: .initialOffset)
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
    func chatSendSymbolEffect(
        trigger: Int,
        reduceMotion: Bool
    ) -> some View {
#if compiler(>=5.9)
        if reduceMotion {
            self
        } else {
            symbolEffect(
                .bounce,
                options: .nonRepeating,
                value: trigger
            )
        }
#else
        self
#endif
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
