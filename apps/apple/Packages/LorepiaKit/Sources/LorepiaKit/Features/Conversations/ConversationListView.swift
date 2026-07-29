import SwiftUI

public struct ConversationListView: View {
    @ObservedObject private var viewModel: ConversationListViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showsNewConversation = false

    private let onOpenConversation: (ConversationListItem) -> Void
    private let onRequestCharacter: (() -> Void)?

    public init(
        viewModel: ConversationListViewModel,
        onOpenConversation: @escaping (ConversationListItem) -> Void,
        onRequestCharacter: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onOpenConversation = onOpenConversation
        self.onRequestCharacter = onRequestCharacter
    }

    public var body: some View {
        Group {
            switch contentState {
            case .loading:
                ProgressView("대화를 불러오는 중")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error:
                errorView
            case .empty:
                emptyView
            case .noResults:
                ContentUnavailableView.search(text: viewModel.query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .results:
                conversationList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The list sits on the same page the rooms do, so the tab does not
        // switch from paper to white on the way in.
        .background(LorepiaColor.paper.ignoresSafeArea())
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: contentState
        )
        .searchable(
            text: $viewModel.query,
            placement: conversationSearchPlacement,
            prompt: Text("캐릭터, 대화 제목 또는 메시지 검색")
        )
        .sheet(isPresented: $showsNewConversation) {
            NewConversationSheet(
                viewModel: viewModel,
                onCreated: onOpenConversation,
                onRequestCharacter: onRequestCharacter
            )
        }
        .task {
            await viewModel.refresh()
        }
        .accessibilityIdentifier("conversation-list-screen")
    }

    private var conversationSearchPlacement: SearchFieldPlacement {
#if os(iOS)
        .navigationBarDrawer(displayMode: .automatic)
#else
        .automatic
#endif
    }

    private var contentState: ConversationListContentState {
        if !viewModel.hasLoaded {
            return .loading
        }
        if viewModel.items.isEmpty, viewModel.errorMessage != nil {
            return .error
        }
        if viewModel.items.isEmpty {
            return .empty
        }
        if viewModel.filteredItems.isEmpty {
            return .noResults
        }
        return .results
    }

    private var conversationList: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                Section {
                    refreshErrorRow(message: errorMessage)
                }
            }

            ForEach(viewModel.filteredItems) { item in
                Button {
                    onOpenConversation(item)
                } label: {
                    ConversationListRow(item: item)
                        .padding(
                            EdgeInsets(
                                top: ConversationRowGeometry.verticalInset,
                                leading: ConversationRowGeometry.leadingInset,
                                bottom: ConversationRowGeometry.verticalInset,
                                trailing: ConversationRowGeometry.trailingInset
                            )
                        )
                        .contentShape(.interaction, Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .accessibilityHint("대화를 엽니다")
                .accessibilityIdentifier(
                    "conversation-row-\(item.id)"
                )
            }
        }
        .listStyle(.plain)
        .lorepiaCanvas()
        .refreshable {
            await viewModel.refresh()
        }
    }

    private func refreshErrorRow(message: String) -> some View {
        VStack(alignment: .leading, spacing: LorepiaSpacing.compact) {
            Label(
                "최신 대화를 불러오지 못했습니다",
                systemImage: "exclamationmark.triangle"
            )
            .font(.callout.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("다시 시도") {
                Task {
                    await viewModel.refresh()
                }
            }
        }
        .padding(.vertical, LorepiaSpacing.compact / 2)
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label("아직 대화가 없습니다", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("캐릭터를 선택하고 첫 대화 방식을 정해 보세요.")
        } actions: {
            Button("새 대화 시작") {
                viewModel.clearCreationError()
                showsNewConversation = true
            }
            .buttonStyle(.borderedProminent)

            if let onRequestCharacter, viewModel.characters.isEmpty {
                Button("캐릭터 만들기", action: onRequestCharacter)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorView: some View {
        ContentUnavailableView {
            Label(
                "대화를 불러오지 못했습니다",
                systemImage: "exclamationmark.triangle"
            )
        } description: {
            Text(viewModel.errorMessage ?? "알 수 없는 오류가 발생했습니다.")
        } actions: {
            Button("다시 불러오기") {
                Task {
                    await viewModel.refresh()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum ConversationListContentState: Hashable {
    case loading
    case error
    case empty
    case noResults
    case results
}

private enum ConversationRowGeometry {
    static let avatarSize: CGFloat = 52
    static let verticalGap: CGFloat = 18
    static let verticalInset = verticalGap / 2
    static let leadingInset: CGFloat = 11
    static let trailingInset: CGFloat = 13
    static let avatarTextSpacing: CGFloat = 13
    static let titleAccessorySpacing: CGFloat = 8
    static let timestampOpticalAdjustment: CGFloat = 0.5
    static let textLineSpacing: CGFloat = 6
    static let minimumHitTarget: CGFloat = 44
}

private struct ConversationListRow: View {
    let item: ConversationListItem

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body)
    private var avatarSize: CGFloat = ConversationRowGeometry.avatarSize
    @ScaledMetric(relativeTo: .headline)
    private var titleFontSize: CGFloat = 16
    @ScaledMetric(relativeTo: .subheadline)
    private var previewFontSize: CGFloat = 15
    @ScaledMetric(relativeTo: .caption2)
    private var timestampFontSize: CGFloat = 11

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                accessibilityLayout
            } else {
                standardLayout
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: max(
                ConversationRowGeometry.minimumHitTarget,
                resolvedAvatarSize
            ),
            alignment: .leading
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var standardLayout: some View {
        HStack(
            alignment: .center,
            spacing: ConversationRowGeometry.avatarTextSpacing
        ) {
            avatar
            standardTextContent
                .layoutPriority(1)
        }
    }

    private var accessibilityLayout: some View {
        VStack(
            alignment: .leading,
            spacing: ConversationRowGeometry.textLineSpacing
        ) {
            HStack(
                alignment: .center,
                spacing: ConversationRowGeometry.avatarTextSpacing
            ) {
                avatar
                textContent
            }
            trailingAccessory
                .padding(
                    .leading,
                    resolvedAvatarSize
                        + ConversationRowGeometry.avatarTextSpacing
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var avatar: some View {
        LorepiaAvatar(
            symbolName: item.character?.symbolName ?? "person.crop.circle",
            seed: item.character?.id ?? item.id,
            size: resolvedAvatarSize
        )
    }

    private var resolvedAvatarSize: CGFloat {
        max(
            ConversationRowGeometry.minimumHitTarget,
            min(avatarSize, 72)
        )
    }

    private var standardTextContent: some View {
        VStack(
            alignment: .leading,
            spacing: ConversationRowGeometry.textLineSpacing
        ) {
            HStack(
                alignment: .center,
                spacing: ConversationRowGeometry.titleAccessorySpacing
            ) {
                title
                trailingAccessory
                    .alignmentGuide(VerticalAlignment.center) { dimensions in
                        dimensions[VerticalAlignment.center]
                            + ConversationRowGeometry.timestampOpticalAdjustment
                    }
            }
            preview
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var textContent: some View {
        VStack(
            alignment: .leading,
            spacing: ConversationRowGeometry.textLineSpacing
        ) {
            title
            preview
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var preview: some View {
        Text(item.previewText)
            .font(.system(size: previewFontSize))
            .foregroundStyle(.secondary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .fixedSize(
                horizontal: false,
                vertical: dynamicTypeSize.isAccessibilitySize
            )
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trailingAccessory: some View {
        timestamp
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var title: some View {
        Text(item.displayTitle)
            .font(.system(size: titleFontSize, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .fixedSize(
                horizontal: false,
                vertical: dynamicTypeSize.isAccessibilitySize
            )
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var timestamp: some View {
        if let date = item.updatedDate {
            Text(ConversationListTimestamp.shortLabel(for: date))
                .font(.system(size: timestampFontSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var accessibilityLabel: String {
        var components = [item.displayTitle]
        if let characterName = item.character?.name,
           characterName != item.displayTitle
        {
            components.append(characterName)
        }
        components.append(item.previewText)
        if let mode = item.mode {
            components.append("\(mode.title) 모드")
        }
        if let date = item.updatedDate {
            components.append(
                ConversationListTimestamp.accessibilityLabel(for: date)
            )
        }
        return components.joined(separator: ", ")
    }
}

private struct NewConversationSheet: View {
    @ObservedObject var viewModel: ConversationListViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedCharacterID: String?
    @State private var selectedMode: ConversationMode = .chat

    let onCreated: (ConversationListItem) -> Void
    let onRequestCharacter: (() -> Void)?

    init(
        viewModel: ConversationListViewModel,
        onCreated: @escaping (ConversationListItem) -> Void,
        onRequestCharacter: (() -> Void)?
    ) {
        self.viewModel = viewModel
        self.onCreated = onCreated
        self.onRequestCharacter = onRequestCharacter
        _selectedCharacterID = State(
            initialValue: viewModel.characters.first?.id
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.characters.isEmpty {
                    noCharactersView
                } else {
                    selectionForm
                }
            }
            .navigationTitle("새 대화")
            .conversationSheetTitleDisplayMode()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") {
                        dismiss()
                    }
                    .disabled(viewModel.isCreatingConversation)
                }
                if !viewModel.characters.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("만들기") {
                            createConversation()
                        }
                        .disabled(
                            selectedCharacter == nil
                                || viewModel.isCreatingConversation
                        )
                    }
                }
            }
        }
        .interactiveDismissDisabled(viewModel.isCreatingConversation)
        .onChange(of: viewModel.characters.map(\.id)) { _, identifiers in
            if let selectedCharacterID,
               identifiers.contains(selectedCharacterID)
            {
                return
            }
            selectedCharacterID = identifiers.first
        }
    }

    private var selectionForm: some View {
        Form {
            Section("캐릭터") {
                ForEach(viewModel.characters) { character in
                    Button {
                        selectedCharacterID = character.id
                    } label: {
                        HStack(spacing: LorepiaSpacing.compact) {
                            Image(systemName: character.symbolName)
                                .frame(width: 28, height: 28)
                                .background(
                                    .tint.opacity(0.12),
                                    in: Circle()
                                )
                                .accessibilityHidden(true)
                            Text(character.name)
                                .foregroundStyle(.primary)
                            Spacer(minLength: LorepiaSpacing.compact)
                            if selectedCharacterID == character.id {
                                LorepiaGlyphView(.check, size: 18)
                                    .foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(character.name)
                    .accessibilityValue(
                        selectedCharacterID == character.id
                            ? "선택됨"
                            : "선택되지 않음"
                    )
                }
            }

            Section("대화 방식") {
                Picker("대화 방식", selection: $selectedMode) {
                    ForEach(ConversationMode.allCases, id: \.self) { mode in
                        Text(mode.title)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityHint("채팅 또는 스토리 방식을 선택합니다")

                Label(
                    selectedMode.detail,
                    systemImage: selectedMode.systemImage
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if let errorMessage = viewModel.creationErrorMessage {
                Section {
                    Label(
                        errorMessage,
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.red)
                    .accessibilityLabel(
                        "대화를 만들지 못했습니다. \(errorMessage)"
                    )
                }
            }

            if viewModel.isCreatingConversation {
                Section {
                    HStack {
                        ProgressView()
                        Text("새 대화를 만드는 중")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityIdentifier("new-conversation-sheet")
    }

    private var noCharactersView: some View {
        ContentUnavailableView {
            Label("선택할 캐릭터가 없습니다", systemImage: "person.crop.circle.badge.plus")
        } description: {
            Text("먼저 캐릭터를 만들거나 파일에서 가져오세요.")
        } actions: {
            if let onRequestCharacter {
                Button("캐릭터 만들기") {
                    dismiss()
                    onRequestCharacter()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectedCharacter: LibraryCharacter? {
        guard let selectedCharacterID else {
            return nil
        }
        return viewModel.characters.first {
            $0.id == selectedCharacterID
        }
    }

    private func createConversation() {
        guard let selectedCharacter else {
            return
        }
        Task {
            guard let item = await viewModel.createConversation(
                character: selectedCharacter,
                mode: selectedMode
            ) else {
                return
            }
            dismiss()
            onCreated(item)
        }
    }
}

private extension View {
    @ViewBuilder
    func conversationSheetTitleDisplayMode() -> some View {
#if os(iOS)
        navigationBarTitleDisplayMode(.inline)
#else
        self
#endif
    }
}
