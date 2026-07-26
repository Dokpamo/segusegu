import SwiftUI

public struct ChatView: View {
    @ObservedObject private var viewModel: ChatViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @ScaledMetric(relativeTo: .body) private var scaledListInset = 16
    @ScaledMetric(relativeTo: .body) private var scaledFollowThreshold = 96

    @State private var isNearBottom = true

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
                    Text("서재에서 캐릭터를 선택하면 저장된 대화를 이어갈 수 있습니다.")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if viewModel.character != nil {
                composer
            }
        }
        .toolbar {
            if let character = viewModel.character {
                ToolbarItem(placement: .principal) {
                    ChatToolbarIdentity(
                        character: character,
                        runtimeName: viewModel.runtimeMode.displayName
                    )
                }
            }

            if viewModel.isGenerating {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        Task {
                            await viewModel.cancelGeneration()
                        }
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("생성 취소")
                    .accessibilityHint("현재 모델 응답 생성을 중단합니다")
                }
            }
        }
        .chatDetailPlatformChrome()
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
                            let joinsPrevious = canGroup(
                                message,
                                with: messageBefore(index)
                            )
                            let joinsNext = canGroup(
                                message,
                                with: messageAfter(index)
                            )

                            ChatBubble(
                                message: message,
                                maximumWidth: maximumBubbleWidth(
                                    in: geometry.size.width
                                ),
                                joinsPrevious: joinsPrevious,
                                joinsNext: joinsNext
                            )
                            .padding(.top, joinsPrevious ? 2 : 10)
                            .transition(messageTransition)
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
                            .background {
                                GeometryReader { bottomGeometry in
                                    Color.clear.preference(
                                        key: ChatBottomPreferenceKey.self,
                                        value: bottomGeometry.frame(
                                            in: .named(ChatCoordinateSpace.name)
                                        ).maxY
                                    )
                                }
                            }
                    }
                    .padding(.horizontal, listInset)
                    .padding(.vertical, LorepiaSpacing.compact)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    .animation(
                        reduceMotion
                            ? .linear(duration: 0.12)
                            : .snappy(duration: 0.24),
                        value: viewModel.messages.count
                    )
                }
                .coordinateSpace(name: ChatCoordinateSpace.name)
                .chatInteractiveKeyboardDismissal()
                .onPreferenceChange(ChatBottomPreferenceKey.self) { bottomY in
                    isNearBottom =
                        bottomY
                            <= geometry.size.height + followThreshold
                }
                .onChange(of: scrollState) { previous, current in
                    guard isNearBottom || current.lastRole == .user else {
                        return
                    }

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
                .onChange(
                    of: viewModel.conversation?.id,
                    initial: true
                ) { _, _ in
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

    private var followThreshold: CGFloat {
        min(max(scaledFollowThreshold, 72), 160)
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

    private var scrollState: ChatScrollState {
        let lastMessage = viewModel.messages.last
        return ChatScrollState(
            count: viewModel.messages.count,
            lastID: lastMessage?.id,
            lastTextLength: lastMessage?.text.count ?? 0,
            lastRole: lastMessage?.role
        )
    }

    private var messageTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        )
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

    private func canGroup(
        _ message: ChatMessage,
        with neighbor: ChatMessage?
    ) -> Bool {
        guard let neighbor, message.role == neighbor.role else {
            return false
        }
        return message.role == .user || message.role == .assistant
    }

    private func scrollToBottom(
        _ proxy: ScrollViewProxy,
        animated: Bool
    ) {
        if animated {
            withAnimation(.snappy(duration: 0.24)) {
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

private struct ChatToolbarIdentity: View {
    let character: LibraryCharacter
    let runtimeName: String

    @ScaledMetric(relativeTo: .headline) private var scaledSymbolSize = 26

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                symbol
                VStack(spacing: 0) {
                    Text(character.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(runtimeName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Text(character.name)
                .font(.headline)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(character.name), \(runtimeName)")
    }

    private var symbol: some View {
        Image(systemName: character.symbolName)
            .font(.system(size: min(max(scaledSymbolSize, 22), 34)))
            .foregroundStyle(.tint)
    }
}

private struct ChatComposer: View {
    @Binding var draft: String

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
            .padding(.leading, fieldPadding)
            .padding(.vertical, verticalInset)
            .disabled(!isEnabled)
            .onSubmit(onSubmit)

            Button(action: onSubmit) {
                sendLabel
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .accessibilityLabel("메시지 보내기")
        }
        .padding(.trailing, 4)
        .chatComposerSurface(isInteractive: isEnabled)
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
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(.tint, in: Circle())
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    let maximumWidth: CGFloat
    let joinsPrevious: Bool
    let joinsNext: Bool

    @ScaledMetric(relativeTo: .body) private var scaledHorizontalPadding = 14
    @ScaledMetric(relativeTo: .body) private var scaledVerticalPadding = 10

    var body: some View {
        if message.role == .system || message.role == .notice {
            notice
        } else {
            bubble
        }
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

    private var bubbleShape: UnevenRoundedRectangle {
        let large: CGFloat = 18
        let joined: CGFloat = 6

        if message.role == .user {
            return UnevenRoundedRectangle(
                topLeadingRadius: large,
                bottomLeadingRadius: large,
                bottomTrailingRadius: joinsNext ? joined : large,
                topTrailingRadius: joinsPrevious ? joined : large,
                style: .continuous
            )
        }

        return UnevenRoundedRectangle(
            topLeadingRadius: joinsPrevious ? joined : large,
            bottomLeadingRadius: joinsNext ? joined : large,
            bottomTrailingRadius: large,
            topTrailingRadius: large,
            style: .continuous
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
            ? .accentColor
            : Color.secondary.opacity(0.14)
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

private struct ChatScrollState: Equatable {
    let count: Int
    let lastID: String?
    let lastTextLength: Int
    let lastRole: ChatMessage.Role?
}

private enum ChatScrollAnchor {
    static let bottom = "chat-bottom-anchor"
}

private enum ChatCoordinateSpace {
    static let name = "chat-scroll-coordinate-space"
}

private struct ChatBottomPreferenceKey: PreferenceKey {
    static let defaultValue = CGFloat.greatestFiniteMagnitude

    static func reduce(
        value: inout CGFloat,
        nextValue: () -> CGFloat
    ) {
        value = nextValue()
    }
}

private extension View {
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
    }
}
