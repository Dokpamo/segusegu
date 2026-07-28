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

    /// Used where the platform draws the icon for us, such as context menus.
    public var systemImage: String {
        switch self {
        case .edit:
            "pencil"
        case .copy:
            "doc.on.doc"
        case .regenerate:
            "arrow.clockwise"
        case .branch:
            "arrow.triangle.branch"
        case .delete:
            "trash"
        }
    }

    /// Used in surfaces we draw ourselves, where one icon family matters more
    /// than matching the system symbol set.
    var glyph: LorepiaGlyph {
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

    @ScaledMetric(relativeTo: .body) private var scaledGlyphSize = 16

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
                    LorepiaGlyphView(
                        action == .copy && isCopied ? .check : action.glyph,
                        size: glyphSize
                    )
                    .offset(y: -8)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ChatMessageActionButtonStyle())
                .foregroundStyle(color(for: action))
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

    /// Our glyphs sit on a 24-unit grid, so they need more room than an SF
    /// Symbol at the same point size to read at the same optical weight.
    private var glyphSize: CGFloat {
        min(max(scaledGlyphSize, 15), 18) * 1.25
    }

    /// Branching keeps its own hue everywhere it appears, so the action row
    /// matches the fork marker and the branch controls.
    private func color(for action: ChatMessageAction) -> Color {
        if action == .copy, isCopied {
            return LorepiaColor.loreAccent
        }
        if action == .branch {
            return LorepiaColor.thread
        }
        return Color.secondary
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

private struct ChatMessageActionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Circle()
                    .fill(.thinMaterial)
                    .overlay {
                        Circle()
                            .strokeBorder(
                                Color.primary.opacity(
                                    colorSchemeContrast == .increased
                                        ? 0.22
                                        : 0.08
                                ),
                                lineWidth: 0.5
                            )
                    }
                    .frame(width: 34, height: 34)
                    .offset(y: -8)
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
            .chatMessageActionSymbolPressEffect(
                isActive:
                    isEnabled
                        && configuration.isPressed
                        && !reduceMotion
            )
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
    func chatMessageActionSymbolPressEffect(isActive: Bool) -> some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, macOS 26.0, *) {
            symbolEffect(
                .drawOn.wholeSymbol,
                options: .nonRepeating.speed(1.6),
                isActive: isActive
            )
        } else {
            symbolEffect(
                .pulse,
                options: .nonRepeating.speed(1.6),
                isActive: isActive
            )
        }
#else
        symbolEffect(
            .pulse,
            options: .nonRepeating.speed(1.6),
            isActive: isActive
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
