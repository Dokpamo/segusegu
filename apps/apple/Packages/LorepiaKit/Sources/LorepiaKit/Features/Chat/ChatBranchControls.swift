import SwiftUI

/// Display-ready branch metadata used by the native chat branch controls.
///
/// The Rust domain remains the source of truth for branch ancestry. Callers
/// adapt domain branch records into this small UI value so the controls don't
/// duplicate branch traversal or storage logic.
public struct ChatBranchOption: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }
}

/// UI-facing name for the conversation mode selected above the composer.
///
/// This remains a type alias so the segmented control binds directly to the
/// domain-backed `ConversationMode` without maintaining duplicate state.
public typealias ChatComposerMode = ConversationMode

extension ConversationMode: Identifiable {
    public var id: Self {
        self
    }

    public var accessibilityHint: String {
        switch self {
        case .chat:
            "캐릭터와 짧게 대화를 주고받습니다"
        case .story:
            "장면과 서술 중심으로 이야기를 이어갑니다"
        }
    }
}

public enum ChatRoomSettingsTriggerStyle: Equatable, Sendable {
    case toolbar
    case modeChip
}

public struct ChatRoomSettingsTrigger: View {
    private let mode: ConversationMode
    private let style: ChatRoomSettingsTriggerStyle
    private let isEnabled: Bool
    private let action: () -> Void

    public init(
        mode: ConversationMode,
        style: ChatRoomSettingsTriggerStyle,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.mode = mode
        self.style = style
        self.isEnabled = isEnabled
        self.action = action
    }

    @ViewBuilder
    public var body: some View {
        switch style {
        case .toolbar:
            Button(
                "대화 설정",
                systemImage: "ellipsis",
                action: action
            )
            .disabled(!isEnabled)
            .chatRoomSettingsAccessibility(
                mode: mode,
                style: style
            )
        case .modeChip:
            Button(action: action) {
                Label(mode.title, systemImage: mode.systemImage)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 11)
                    .frame(minHeight: 44)
                    .chatCompactControlSurface(isInteractive: isEnabled)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .chatRoomSettingsAccessibility(
                mode: mode,
                style: style
            )
        }
    }
}

private extension View {
    func chatRoomSettingsAccessibility(
        mode: ConversationMode,
        style: ChatRoomSettingsTriggerStyle
    ) -> some View {
        self
            .accessibilityLabel(
                style == .toolbar ? "대화 설정" : "\(mode.title) 모드"
            )
            .accessibilityValue(mode.title)
            .accessibilityHint("응답 모드와 대화 분기를 설정합니다")
            .accessibilityIdentifier(
                style == .toolbar
                    ? "chat-room-settings-trigger-toolbar"
                    : "chat-room-settings-trigger-mode"
            )
    }
}

public struct ChatRoomSettingsSheet: View {
    private let mode: ConversationMode
    private let branches: [ChatBranchOption]
    private let selectedBranchID: String?
    private let isEnabled: Bool
    private let errorMessage: String?
    private let onModeChange: (ConversationMode) -> Void
    private let onSelectBranch: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedMode: ConversationMode

    public init(
        mode: ConversationMode,
        branches: [ChatBranchOption],
        selectedBranchID: String?,
        isEnabled: Bool = true,
        errorMessage: String? = nil,
        onModeChange: @escaping (ConversationMode) -> Void,
        onSelectBranch: @escaping (String) -> Void
    ) {
        self.mode = mode
        self.branches = branches
        self.selectedBranchID = selectedBranchID
        self.isEnabled = isEnabled
        self.errorMessage = errorMessage
        self.onModeChange = onModeChange
        self.onSelectBranch = onSelectBranch
        _selectedMode = State(initialValue: mode)
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker(
                        "응답 모드",
                        selection: $selectedMode
                    ) {
                        ForEach(ConversationMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.systemImage)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!isEnabled)

                    Text(selectedMode.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("응답 방식")
                }

                Section("대화 흐름") {
                    if branches.isEmpty {
                        LorepiaGlyphLabel(
                            "아직 분기가 없습니다",
                            glyph: .branch
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(branches) { branch in
                            branchRow(branch)
                        }
                    }
                }

                if let errorMessage, !errorMessage.isEmpty {
                    Section {
                        Label(
                            errorMessage,
                            systemImage: "exclamationmark.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier(
                            "chat-room-settings-error"
                        )
                    }
                }
            }
            .chatBranchListStyle()
            .navigationTitle("대화 설정")
            .chatBranchNavigationTitleDisplayMode()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") {
                        dismiss()
                    }
                }
            }
        }
        .chatBranchSheetPresentation()
        .onChange(of: mode) { _, newMode in
            selectedMode = newMode
        }
        .onChange(of: selectedMode) { previousMode, newMode in
            if previousMode != newMode {
                onModeChange(newMode)
            }
        }
        .accessibilityIdentifier("chat-room-settings-sheet")
    }

    private func branchRow(_ branch: ChatBranchOption) -> some View {
        let isCurrent = branch.id == selectedBranchID
        return Button {
            guard !isCurrent else {
                return
            }
            onSelectBranch(branch.id)
        } label: {
            HStack(spacing: LorepiaSpacing.standard) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(branch.title)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let subtitle = branch.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: LorepiaSpacing.compact)

                if isCurrent {
                    LorepiaGlyphView(.check, size: 18)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(branch.title)
        .accessibilityValue(isCurrent ? "현재 흐름" : "")
        .accessibilityHint(
            isCurrent
                ? "현재 선택된 대화 흐름입니다"
                : "이 대화 흐름으로 전환합니다"
        )
    }
}

/// A toolbar button that presents the system branch-selection sheet.
///
/// Place this control in a native `ToolbarItem`. Selection is reported through
/// `onSelect`; the caller remains responsible for changing the active branch.
public struct ChatBranchToolbarControl: View {
    private let branches: [ChatBranchOption]
    private let selectedBranchID: String?
    private let isEnabled: Bool
    private let onSelect: (String) -> Void

    @State private var isPresented = false

    public init(
        branches: [ChatBranchOption],
        selectedBranchID: String?,
        isEnabled: Bool = true,
        onSelect: @escaping (String) -> Void
    ) {
        self.branches = branches
        self.selectedBranchID = selectedBranchID
        self.isEnabled = isEnabled
        self.onSelect = onSelect
    }

    public var body: some View {
        Button {
            isPresented = true
        } label: {
            LorepiaGlyphLabel("대화 분기", glyph: .branch)
        }
        .disabled(!isEnabled || branches.isEmpty)
        .accessibilityValue(
            ChatBranchPresentation.toolbarAccessibilityValue(
                branches: branches,
                selectedBranchID: selectedBranchID
            )
        )
        .accessibilityHint("이 대화의 다른 흐름을 선택합니다")
        .sheet(isPresented: $isPresented) {
            ChatBranchSheet(
                branches: branches,
                selectedBranchID: selectedBranchID,
                isEnabled: isEnabled,
                onSelect: onSelect
            )
            .chatBranchSheetPresentation()
        }
    }
}

/// A native sheet that separates the active branch from alternative branches.
public struct ChatBranchSheet: View {
    private let branches: [ChatBranchOption]
    private let selectedBranchID: String?
    private let isEnabled: Bool
    private let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    public init(
        branches: [ChatBranchOption],
        selectedBranchID: String?,
        isEnabled: Bool = true,
        onSelect: @escaping (String) -> Void
    ) {
        self.branches = branches
        self.selectedBranchID = selectedBranchID
        self.isEnabled = isEnabled
        self.onSelect = onSelect
    }

    public var body: some View {
        NavigationStack {
            Group {
                if branches.isEmpty {
                    ContentUnavailableView {
                        LorepiaGlyphLabel(
                            "분기가 없습니다",
                            glyph: .branch,
                            size: 24
                        )
                    } description: {
                        Text("메시지를 길게 눌러 원하는 지점에서 이야기를 나눌 수 있습니다.")
                    }
                } else {
                    branchList
                }
            }
            .navigationTitle("대화 분기")
            .chatBranchNavigationTitleDisplayMode()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var branchList: some View {
        List {
            if let currentBranch = ChatBranchPresentation.currentBranch(
                in: branches,
                selectedBranchID: selectedBranchID
            ) {
                Section("현재 흐름") {
                    branchRow(currentBranch, isCurrent: true)
                }
            }

            let alternatives = ChatBranchPresentation.alternativeBranches(
                in: branches,
                selectedBranchID: selectedBranchID
            )
            if !alternatives.isEmpty {
                Section("다른 흐름") {
                    ForEach(alternatives) { branch in
                        branchRow(branch, isCurrent: false)
                    }
                }
            }
        }
        .chatBranchListStyle()
    }

    private func branchRow(
        _ branch: ChatBranchOption,
        isCurrent: Bool
    ) -> some View {
        Button {
            if !isCurrent {
                onSelect(branch.id)
            }
            dismiss()
        } label: {
            HStack(spacing: LorepiaSpacing.standard) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(branch.title)
                        .font(.body.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let subtitle = branch.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: LorepiaSpacing.compact)

                if isCurrent {
                    LorepiaGlyphView(.check, size: 18)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(branch.title)
        .accessibilityValue(isCurrent ? "현재 흐름" : "")
        .accessibilityHint(
            isCurrent
                ? "현재 선택된 대화 흐름입니다"
                : "이 대화 흐름으로 전환합니다"
        )
    }
}

/// A compact system segmented control intended to sit directly above the
/// message composer.
public struct ChatComposerModeControl: View {
    @Binding private var selection: ChatComposerMode
    private let isEnabled: Bool

    public init(
        selection: Binding<ChatComposerMode>,
        isEnabled: Bool = true
    ) {
        _selection = selection
        self.isEnabled = isEnabled
    }

    public var body: some View {
        Picker("작성 모드", selection: $selection) {
            ForEach(ChatComposerMode.allCases) { mode in
                Text(mode.title)
                    .tag(mode)
                    .accessibilityHint(mode.accessibilityHint)
            }
        }
        .pickerStyle(.segmented)
        .disabled(!isEnabled)
        .accessibilityValue(selection.title)
        .padding(.horizontal, LorepiaSpacing.standard)
        .padding(.top, LorepiaSpacing.compact)
        .padding(.bottom, 4)
    }
}

public extension View {
    /// Adds the native message action used to fork a conversation at a
    /// particular message. Disabled messages don't expose an inert menu.
    @ViewBuilder
    func chatBranchContextMenu(
        messageID: String,
        isEnabled: Bool = true,
        onBranch: @escaping (String) -> Void
    ) -> some View {
        if isEnabled {
            contextMenu {
                Button {
                    onBranch(messageID)
                } label: {
                    Label(
                        "여기서 분기",
                        systemImage: "arrow.triangle.branch"
                    )
                }
            }
        } else {
            self
        }
    }
}

enum ChatBranchPresentation {
    static func currentBranch(
        in branches: [ChatBranchOption],
        selectedBranchID: String?
    ) -> ChatBranchOption? {
        guard let selectedBranchID else {
            return nil
        }
        return branches.first { $0.id == selectedBranchID }
    }

    static func alternativeBranches(
        in branches: [ChatBranchOption],
        selectedBranchID: String?
    ) -> [ChatBranchOption] {
        branches.filter { $0.id != selectedBranchID }
    }

    static func toolbarAccessibilityValue(
        branches: [ChatBranchOption],
        selectedBranchID: String?
    ) -> String {
        let countDescription = "분기 \(branches.count)개"
        guard let current = currentBranch(
            in: branches,
            selectedBranchID: selectedBranchID
        ) else {
            return countDescription
        }
        return "현재 \(current.title), \(countDescription)"
    }
}

private extension View {
    @ViewBuilder
    func chatBranchNavigationTitleDisplayMode() -> some View {
#if os(iOS)
        navigationBarTitleDisplayMode(.inline)
#else
        self
#endif
    }

    @ViewBuilder
    func chatBranchListStyle() -> some View {
#if os(iOS)
        listStyle(.insetGrouped)
#else
        self
#endif
    }

    @ViewBuilder
    func chatBranchSheetPresentation() -> some View {
#if os(iOS)
        presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
#else
        self
#endif
    }

    @ViewBuilder
    func chatCompactControlSurface(isInteractive: Bool) -> some View {
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
}
