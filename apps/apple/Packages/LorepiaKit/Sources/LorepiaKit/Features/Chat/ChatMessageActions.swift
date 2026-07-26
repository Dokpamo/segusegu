import SwiftUI

public enum ChatMessageAction: String, CaseIterable, Identifiable, Sendable {
    case edit
    case copy
    case regenerate
    case branch
    case delete

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
        case .edit:
            "편집"
        case .copy:
            "복사"
        case .regenerate:
            "재생성"
        case .branch:
            "여기서 분기"
        case .delete:
            "삭제"
        }
    }

    public var systemImage: String {
        switch self {
        case .edit:
            "pencil.line"
        case .copy:
            "square.on.square"
        case .regenerate:
            "arrow.2.circlepath"
        case .branch:
            "arrow.branch"
        case .delete:
            "trash"
        }
    }
}

enum ChatMessageActionGlyph: String, CaseIterable, Sendable {
    case edit
    case copy
    case regenerate
    case branch
    case delete
    case check
}

extension ChatMessageAction {
    var glyph: ChatMessageActionGlyph {
        switch self {
        case .edit:
            .edit
        case .copy:
            .copy
        case .regenerate:
            .regenerate
        case .branch:
            .branch
        case .delete:
            .delete
        }
    }
}

enum ChatMessageActionPresentation {
    static func actions(
        for role: ChatMessage.Role
    ) -> [ChatMessageAction] {
        switch role {
        case .user:
            [.edit, .copy, .branch, .delete]
        case .assistant:
            [.copy, .regenerate, .branch, .delete]
        case .system, .notice:
            []
        }
    }
}

public struct ChatMessageActionRow: View {
    private let message: ChatMessage
    private let isMutationEnabled: Bool
    private let isCopied: Bool
    private let onAction: (ChatMessageAction) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @ScaledMetric(relativeTo: .body) private var scaledGlyphSize = 20

    public init(
        message: ChatMessage,
        isMutationEnabled: Bool,
        isCopied: Bool = false,
        onAction: @escaping (ChatMessageAction) -> Void
    ) {
        self.message = message
        self.isMutationEnabled = isMutationEnabled
        self.isCopied = isCopied
        self.onAction = onAction
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(
                ChatMessageActionPresentation.actions(for: message.role)
            ) { action in
                Button(role: action == .delete ? .destructive : nil) {
                    onAction(action)
                } label: {
                    ZStack {
                        let glyph =
                            action == .copy && isCopied
                                ? ChatMessageActionGlyph.check
                                : action.glyph
                        ChatMessageActionGlyphView(glyph: glyph)
                            .id(glyph)
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .scale(scale: 0.72)
                                        .combined(with: .opacity)
                            )
                    }
                    .frame(width: glyphSize, height: glyphSize)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ChatMessageActionButtonStyle())
                .foregroundStyle(
                    action == .copy && isCopied
                        ? Color.accentColor
                        : Color.primary.opacity(
                            colorSchemeContrast == .increased ? 0.78 : 0.58
                        )
                )
                .animation(
                    reduceMotion ? nil : .smooth(duration: 0.18),
                    value: isCopied
                )
                .disabled(!isEnabled(action))
                .accessibilityLabel(accessibilityLabel(for: action))
                .accessibilityHint(accessibilityHint(for: action))
                .accessibilityIdentifier(
                    "chat-message-action-\(action.rawValue)-\(message.role.rawValue)-\(message.id)"
                )
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "chat-message-action-row-\(message.role.rawValue)-\(message.id)"
        )
    }

    private var glyphSize: CGFloat {
        min(max(scaledGlyphSize, 19), 22)
    }

    private func isEnabled(_ action: ChatMessageAction) -> Bool {
        if action == .copy {
            return !message.text.isEmpty
        }
        return isMutationEnabled
    }

    private func accessibilityHint(
        for action: ChatMessageAction
    ) -> String {
        switch action {
        case .edit:
            "이 메시지를 수정하고 새 흐름에서 응답을 다시 생성합니다"
        case .copy:
            "메시지 내용을 클립보드에 복사합니다"
        case .regenerate:
            "새 흐름에서 이 응답을 다시 생성합니다"
        case .branch:
            "이 메시지까지 포함한 새 대화 흐름을 만듭니다"
        case .delete:
            "확인 후 이 메시지와 이후 대화를 현재 흐름에서 제거합니다"
        }
    }

    private func accessibilityLabel(
        for action: ChatMessageAction
    ) -> String {
        if action == .copy, isCopied {
            return "복사됨"
        }
        return switch (message.role, action) {
        case (.user, .edit):
            "메시지 편집"
        case (.user, .copy):
            "메시지 복사"
        case (.assistant, .copy):
            "응답 복사"
        case (.assistant, .regenerate):
            "응답 재생성"
        case (_, .branch):
            "여기서 분기"
        case (.user, .delete):
            "메시지 삭제"
        case (.assistant, .delete):
            "응답 삭제"
        default:
            action.title
        }
    }
}

private struct ChatMessageActionGlyphView: View {
    let glyph: ChatMessageActionGlyph

    var body: some View {
        ZStack {
            ChatMessageActionGlyphShape(glyph: glyph)
                .fill(.foreground)

            if glyph == .branch {
                ChatMessageBranchNodeShape()
                    .fill(.foreground)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ChatMessageActionGlyphShape: Shape {
    let glyph: ChatMessageActionGlyph

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 20
        let origin = CGPoint(
            x: rect.midX - (10 * scale),
            y: rect.midY - (10 * scale)
        )
        let strokeStyle = StrokeStyle(
            lineWidth: 1.65 * scale,
            lineCap: .round,
            lineJoin: .round
        )

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: origin.x + (x * scale),
                y: origin.y + (y * scale)
            )
        }

        func canvasRect(
            x: CGFloat,
            y: CGFloat,
            width: CGFloat,
            height: CGFloat
        ) -> CGRect {
            CGRect(
                x: origin.x + (x * scale),
                y: origin.y + (y * scale),
                width: width * scale,
                height: height * scale
            )
        }

        func stroked(_ centerline: Path) -> Path {
            centerline.strokedPath(strokeStyle)
        }

        var result = Path()

        switch glyph {
        case .edit:
            var page = Path()
            page.move(to: point(8.1, 4.2))
            page.addLine(to: point(6.4, 4.2))
            page.addQuadCurve(
                to: point(4.3, 6.3),
                control: point(4.3, 4.2)
            )
            page.addLine(to: point(4.3, 13.7))
            page.addQuadCurve(
                to: point(6.4, 15.8),
                control: point(4.3, 15.8)
            )
            page.addLine(to: point(10.2, 15.8))
            result.addPath(stroked(page))

            var pen = Path()
            pen.move(to: point(7.6, 12.8))
            pen.addLine(to: point(8.3, 10.1))
            pen.addLine(to: point(13.5, 4.9))
            pen.addQuadCurve(
                to: point(15.2, 6.6),
                control: point(15.2, 5.0)
            )
            pen.addLine(to: point(10.0, 11.8))
            pen.closeSubpath()
            result.addPath(pen)

        case .copy:
            var back = Path()
            back.move(to: point(12.4, 3.8))
            back.addLine(to: point(6.1, 3.8))
            back.addQuadCurve(
                to: point(4.2, 5.7),
                control: point(4.2, 3.8)
            )
            back.addLine(to: point(4.2, 11.4))
            back.addQuadCurve(
                to: point(5.9, 13.2),
                control: point(4.2, 13.2)
            )
            result.addPath(stroked(back))

            var front = Path()
            front.addRoundedRect(
                in: canvasRect(
                    x: 6.4,
                    y: 6.2,
                    width: 9.4,
                    height: 10
                ),
                cornerSize: CGSize(
                    width: 2.1 * scale,
                    height: 2.1 * scale
                )
            )
            result.addPath(stroked(front))

        case .regenerate:
            var arrow = Path()
            arrow.move(to: point(14.8, 6.2))
            arrow.addCurve(
                to: point(15.1, 13.5),
                control1: point(16.6, 8.0),
                control2: point(16.5, 11.2)
            )
            arrow.addCurve(
                to: point(6.2, 14.3),
                control1: point(12.9, 16.3),
                control2: point(8.8, 16.7)
            )
            arrow.addCurve(
                to: point(6.3, 5.5),
                control1: point(3.5, 11.9),
                control2: point(3.8, 7.9)
            )
            arrow.addCurve(
                to: point(13.1, 4.5),
                control1: point(8.1, 3.8),
                control2: point(11.0, 3.5)
            )
            result.addPath(stroked(arrow))

            var arrowhead = Path()
            arrowhead.move(to: point(12.1, 6.3))
            arrowhead.addLine(to: point(14.8, 6.2))
            arrowhead.addLine(to: point(14.8, 3.5))
            result.addPath(stroked(arrowhead))

        case .branch:
            var branches = Path()
            branches.move(to: point(10, 16.2))
            branches.addLine(to: point(10, 10.5))
            branches.move(to: point(10, 10.5))
            branches.addCurve(
                to: point(5.2, 5.4),
                control1: point(10, 7.4),
                control2: point(7.8, 5.4)
            )
            branches.move(to: point(10, 10.5))
            branches.addCurve(
                to: point(14.8, 5.4),
                control1: point(10, 7.4),
                control2: point(12.2, 5.4)
            )
            result.addPath(stroked(branches))

        case .delete:
            var bin = Path()
            bin.move(to: point(5.2, 7.7))
            bin.addLine(to: point(5.9, 14.5))
            bin.addQuadCurve(
                to: point(8.0, 16.3),
                control: point(6.1, 16.3)
            )
            bin.addLine(to: point(12.0, 16.3))
            bin.addQuadCurve(
                to: point(14.1, 14.5),
                control: point(13.9, 16.3)
            )
            bin.addLine(to: point(14.8, 7.7))
            result.addPath(stroked(bin))

            var lid = Path()
            lid.move(to: point(4.3, 6.2))
            lid.addLine(to: point(15.7, 6.2))
            lid.move(to: point(8.0, 4.0))
            lid.addLine(to: point(12.0, 4.0))
            lid.move(to: point(8.2, 9.4))
            lid.addLine(to: point(8.5, 13.8))
            lid.move(to: point(11.8, 9.4))
            lid.addLine(to: point(11.5, 13.8))
            result.addPath(stroked(lid))

        case .check:
            var check = Path()
            check.move(to: point(4.4, 10.4))
            check.addLine(to: point(8.2, 14.1))
            check.addLine(to: point(15.8, 6.3))
            result.addPath(stroked(check))
        }

        return result
    }
}

private struct ChatMessageBranchNodeShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 20
        let origin = CGPoint(
            x: rect.midX - (10 * scale),
            y: rect.midY - (10 * scale)
        )

        func nodeRect(centerX: CGFloat) -> CGRect {
            CGRect(
                x: origin.x + ((centerX - 1.25) * scale),
                y: origin.y + (4.15 * scale),
                width: 2.5 * scale,
                height: 2.5 * scale
            )
        }

        var result = Path()
        result.addEllipse(in: nodeRect(centerX: 5.2))
        result.addEllipse(in: nodeRect(centerX: 14.8))
        return result
    }
}

private struct ChatMessageActionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Color.clear
                    .frame(width: 32, height: 32)
                    .chatMessageActionPressedSurface(
                        isInteractive: isEnabled
                    )
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: 8,
                            style: .continuous
                        )
                        .strokeBorder(
                            Color.primary.opacity(
                                colorSchemeContrast == .increased
                                    ? 0.22
                                    : 0.08
                            ),
                            lineWidth: 0.5
                        )
                    }
                    .opacity(configuration.isPressed ? 1 : 0)
                    .scaleEffect(
                        reduceMotion
                            ? 1
                            : (configuration.isPressed ? 1 : 0.86)
                    )
            }
            .scaleEffect(
                reduceMotion
                    ? 1
                    : (configuration.isPressed ? 0.94 : 1)
            )
            .opacity(isEnabled ? 1 : 0.36)
            .animation(
                reduceMotion
                    ? nil
                    : .snappy(duration: 0.18, extraBounce: 0.02),
                value: configuration.isPressed
            )
    }
}

public struct ChatMessageEditSheet: View {
    private let messageID: String
    private let isEnabled: Bool
    private let onSave: (String, String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var isSaving = false
    @State private var saveFailed = false

    public init(
        messageID: String,
        text: String,
        isEnabled: Bool = true,
        onSave: @escaping (String, String) async -> Bool
    ) {
        self.messageID = messageID
        self.isEnabled = isEnabled
        self.onSave = onSave
        _draft = State(initialValue: text)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $draft)
                        .frame(minHeight: 120)
                        .disabled(!isEnabled)
                        .accessibilityLabel("메시지 내용")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("편집하면 원래 대화는 유지되고 새 흐름에서 응답을 생성합니다.")
                        if saveFailed {
                            Label(
                                "저장하지 못했습니다. 설정과 연결 상태를 확인한 뒤 다시 시도하세요.",
                                systemImage: "exclamationmark.circle"
                            )
                            .foregroundStyle(.red)
                            .accessibilityIdentifier(
                                "chat-message-edit-failure"
                            )
                        }
                    }
                }
            }
            .navigationTitle("메시지 편집")
            .chatMessageActionNavigationTitleDisplayMode()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        let text = draft.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                        isSaving = true
                        saveFailed = false
                        Task {
                            if await onSave(messageID, text) {
                                dismiss()
                            } else {
                                isSaving = false
                                saveFailed = true
                            }
                        }
                    }
                    .disabled(
                        !isEnabled
                            || isSaving
                            || draft.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                    )
                }
            }
            .disabled(isSaving)
            .overlay {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("메시지 저장 중")
                }
            }
        }
        .chatMessageActionSheetPresentation()
        .accessibilityIdentifier("chat-message-edit-sheet")
    }
}

public extension View {
    @ViewBuilder
    func chatMessageContextMenu(
        message: ChatMessage,
        isMutationEnabled: Bool,
        onAction: @escaping (ChatMessageAction) -> Void
    ) -> some View {
        let actions = ChatMessageActionPresentation.actions(
            for: message.role
        )
        if actions.isEmpty {
            self
        } else {
            contextMenu {
                ForEach(actions) { action in
                    Button(
                        role: action == .delete ? .destructive : nil
                    ) {
                        onAction(action)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                    .disabled(
                        action == .copy
                            ? message.text.isEmpty
                            : !isMutationEnabled
                    )
                }
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func chatMessageActionPressedSurface(
        isInteractive: Bool
    ) -> some View {
#if os(iOS)
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glassEffect(
                .regular.interactive(isInteractive),
                in: RoundedRectangle(
                    cornerRadius: 8,
                    style: .continuous
                )
            )
        } else {
            background(
                .thinMaterial,
                in: RoundedRectangle(
                    cornerRadius: 8,
                    style: .continuous
                )
            )
        }
#else
        background(
            .thinMaterial,
            in: RoundedRectangle(
                cornerRadius: 8,
                style: .continuous
            )
        )
#endif
#else
        background(
            .thinMaterial,
            in: RoundedRectangle(
                cornerRadius: 8,
                style: .continuous
            )
        )
#endif
    }

    @ViewBuilder
    func chatMessageActionNavigationTitleDisplayMode() -> some View {
#if os(iOS)
        navigationBarTitleDisplayMode(.inline)
#else
        self
#endif
    }

    @ViewBuilder
    func chatMessageActionSheetPresentation() -> some View {
#if os(iOS)
        presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
#else
        self
#endif
    }
}
