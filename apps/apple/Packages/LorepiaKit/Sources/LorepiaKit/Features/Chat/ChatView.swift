import SwiftUI

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
                    ChatToolbarIdentity(character: character)
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

                            ChatBubble(
                                message: message,
                                maximumWidth: maximumBubbleWidth(
                                    in: geometry.size.width
                                ),
                                joinsPrevious: joinsPrevious,
                                joinsNext: joinsNext
                            )
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
                            : .snappy(duration: 0.26, extraBounce: 0.02),
                        value: viewModel.messages.count
                    )
                }
                .chatDefaultBottomAnchor()
                .coordinateSpace(name: ChatCoordinateSpace.name)
                .chatInteractiveKeyboardDismissal()
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            if value.translation.height > 8 {
                                followsLatest = false
                            }
                        }
                )
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

        let insertion: AnyTransition = switch message.role {
        case .user:
            .scale(scale: 0.92, anchor: .bottomTrailing)
                .combined(with: .opacity)
        case .assistant:
            .scale(scale: 0.97, anchor: .bottomLeading)
                .combined(with: .opacity)
        case .system, .notice:
            .opacity
        }
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
            withAnimation(.snappy(duration: 0.26, extraBounce: 0.02)) {
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
        .overlay {
            Capsule()
                .strokeBorder(
                    Color.primary.opacity(
                        colorSchemeContrast == .increased
                            ? 0.24
                            : (isEnabled ? 0.09 : 0.05)
                    ),
                    lineWidth: colorSchemeContrast == .increased ? 1 : 0.5
                )
        }
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
}

private struct ChatBubble: View {
    let message: ChatMessage
    let maximumWidth: CGFloat
    let joinsPrevious: Bool
    let joinsNext: Bool

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

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

        let showsTail = !joinsNext
        let tailWidth = showsTail
            ? min(max(rect.width * 0.035, 4), 7)
            : 0
        let bodyRect = CGRect(
            x: isOutgoing ? rect.minX : rect.minX + tailWidth,
            y: rect.minY,
            width: max(rect.width - tailWidth, 0),
            height: rect.height
        )
        let largeRadius = min(max(bodyRect.height * 0.38, 14), 20)
        let joinedRadius = min(max(largeRadius * 0.34, 5), 7)
        let tailRadius = min(max(largeRadius * 0.25, 4), 6)

        let shape: UnevenRoundedRectangle
        if isOutgoing {
            shape = UnevenRoundedRectangle(
                topLeadingRadius: largeRadius,
                bottomLeadingRadius: largeRadius,
                bottomTrailingRadius: showsTail
                    ? tailRadius
                    : (joinsNext ? joinedRadius : largeRadius),
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
                bottomLeadingRadius: showsTail
                    ? tailRadius
                    : (joinsNext ? joinedRadius : largeRadius),
                bottomTrailingRadius: largeRadius,
                topTrailingRadius: largeRadius,
                style: .continuous
            )
        }

        var path = shape.path(in: bodyRect)
        guard showsTail else {
            return path
        }

        var tail = Path()
        if isOutgoing {
            tail.move(
                to: CGPoint(
                    x: bodyRect.maxX - tailWidth * 0.55,
                    y: bodyRect.maxY - largeRadius * 0.72
                )
            )
            tail.addCurve(
                to: CGPoint(x: rect.maxX, y: rect.maxY - 1),
                control1: CGPoint(
                    x: bodyRect.maxX + tailWidth * 0.2,
                    y: bodyRect.maxY - largeRadius * 0.42
                ),
                control2: CGPoint(
                    x: rect.maxX - tailWidth * 0.15,
                    y: rect.maxY - 2
                )
            )
            tail.addCurve(
                to: CGPoint(
                    x: bodyRect.maxX - tailWidth * 1.25,
                    y: bodyRect.maxY - 1
                ),
                control1: CGPoint(
                    x: rect.maxX - tailWidth * 0.45,
                    y: rect.maxY
                ),
                control2: CGPoint(
                    x: bodyRect.maxX - tailWidth * 0.5,
                    y: bodyRect.maxY
                )
            )
        } else {
            tail.move(
                to: CGPoint(
                    x: bodyRect.minX + tailWidth * 1.25,
                    y: bodyRect.maxY - 1
                )
            )
            tail.addCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - 1),
                control1: CGPoint(
                    x: bodyRect.minX + tailWidth * 0.5,
                    y: bodyRect.maxY
                ),
                control2: CGPoint(
                    x: rect.minX + tailWidth * 0.45,
                    y: rect.maxY
                )
            )
            tail.addCurve(
                to: CGPoint(
                    x: bodyRect.minX + tailWidth * 0.55,
                    y: bodyRect.maxY - largeRadius * 0.72
                ),
                control1: CGPoint(
                    x: rect.minX + tailWidth * 0.15,
                    y: rect.maxY - 2
                ),
                control2: CGPoint(
                    x: bodyRect.minX - tailWidth * 0.2,
                    y: bodyRect.maxY - largeRadius * 0.42
                )
            )
        }
        tail.closeSubpath()
        path.addPath(tail)
        return path
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
