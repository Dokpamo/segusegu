import LorepiaKit
import SwiftUI
import UniformTypeIdentifiers
import Darwin

struct IOSRootView: View {
    private enum Tab: Hashable {
        case home
        case chats
        case create
        case settings
    }

    let environment: AppEnvironment
    @ObservedObject private var importReviewViewModel: ImportReviewViewModel
    @ObservedObject private var settingsViewModel: SettingsViewModel

    @State private var selectedTab: Tab = .home
    @State private var homeChatCharacter: LibraryCharacter?
    @State private var selectedConversation: ConversationListItem?
    @State private var showsFileImporter = false
    @State private var showsImportReview = false
    @State private var showsCoreStatus = false

    init(environment: AppEnvironment) {
        self.environment = environment
        importReviewViewModel = environment.importReviewViewModel
        settingsViewModel = environment.settingsViewModel
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                IOSHomeView(
                    viewModel: environment.libraryViewModel,
                    onOpenChats: {
                        selectedTab = .chats
                    },
                    onCreate: {
                        selectedTab = .create
                    },
                    onOpenChat: { character in
                        homeChatCharacter = character
                    }
                )
                .navigationTitle("홈")
                .navigationDestination(item: $homeChatCharacter) { character in
                    ChatView(viewModel: environment.chatViewModel)
                        .navigationBarTitleDisplayMode(.inline)
                        .task(id: character.id) {
                            await environment.selectCharacter(character)
                        }
                }
            }
            .tabItem {
                Label("홈", systemImage: "house")
            }
            .tag(Tab.home)

            NavigationStack {
                ConversationListView(
                    viewModel: environment.conversationListViewModel,
                    onOpenConversation: { item in
                        selectedConversation = item
                    },
                    onRequestCharacter: {
                        selectedTab = .create
                    }
                )
                .navigationTitle("채팅")
                .navigationDestination(item: $selectedConversation) { item in
                    ChatView(viewModel: environment.chatViewModel)
                        .navigationBarTitleDisplayMode(.inline)
                        .task(id: item.id) {
                            await environment.selectConversation(item)
                        }
                }
            }
            .tabItem {
                Label(
                    "채팅",
                    systemImage: "bubble.left.and.bubble.right"
                )
            }
            .tag(Tab.chats)

            NavigationStack {
                IOSCreateView {
                    showsFileImporter = true
                }
                .navigationTitle("생성")
            }
            .tabItem {
                Label("생성", systemImage: "plus.circle.fill")
            }
            .tag(Tab.create)

            NavigationStack {
                SettingsView(viewModel: settingsViewModel)
                    .toolbar {
                        if settingsViewModel.showTechnicalDetails {
                            ToolbarItem(placement: .primaryAction) {
                                Button {
                                    showsCoreStatus = true
                                } label: {
                                    Label(
                                        "코어 상태",
                                        systemImage: "waveform.path.ecg"
                                    )
                                }
                            }
                        }
                    }
                    .sheet(isPresented: $showsCoreStatus) {
                        NavigationStack {
                            ScrollView {
                                CoreStatusPanel(
                                    viewModel: environment.coreStatusViewModel
                                )
                                .padding(LorepiaSpacing.standard)
                            }
                            .navigationTitle("코어 상태")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("완료") {
                                        showsCoreStatus = false
                                    }
                                }
                            }
                        }
                        .presentationDetents([.medium, .large])
                    }
                .navigationTitle("설정")
            }
            .tabItem {
                Label("설정", systemImage: "gearshape")
            }
            .tag(Tab.settings)
        }
        .lorepiaTabBarBehavior()
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else {
                return
            }
            showsImportReview = true
            Task {
                await environment.prepareImport(from: url)
            }
        }
        .sheet(isPresented: $showsImportReview) {
            NavigationStack {
                ImportReviewView(
                    viewModel: importReviewViewModel,
                    onPickFile: {
                        showsFileImporter = true
                    },
                    finishTitle: "채팅으로 이동",
                    onFinished: {
                        showsImportReview = false
                        selectedTab = .chats
                        Task {
                            await environment.conversationListViewModel.refresh()
                        }
                    }
                )
                .navigationTitle("가져오기 검토")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("완료") {
                            showsImportReview = false
                        }
                        .disabled(importReviewViewModel.isBusy)
                    }
                }
            }
            .interactiveDismissDisabled(
                importReviewViewModel.isBusy
            )
        }
        .task {
            await environment.start()
            if ProcessInfo.processInfo.arguments.contains("--lorepia-ci-smoke") {
                do {
                    try await environment.validateForLaunchSmoke()
                    exit(EXIT_SUCCESS)
                } catch {
                    fputs(
                        "LorePia iOS launch smoke failed: \(error)\n",
                        stderr
                    )
                    exit(EXIT_FAILURE)
                }
            }
        }
        .accessibilityIdentifier("lorepia-root")
    }
}

private extension View {
    @ViewBuilder
    func lorepiaTabBarBehavior() -> some View {
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}

private struct IOSHomeView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onOpenChats: () -> Void
    let onCreate: () -> Void
    let onOpenChat: (LibraryCharacter) -> Void

    var body: some View {
        Group {
            if viewModel.characters.isEmpty {
                ContentUnavailableView {
                    Label("첫 이야기를 시작해 보세요", systemImage: "sparkles")
                } description: {
                    Text("캐릭터를 만들거나 파일에서 가져오면 여기에서 바로 이야기를 이어갈 수 있습니다.")
                } actions: {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Button("캐릭터 생성", action: onCreate)
                                .buttonStyle(.borderedProminent)
                            Button("채팅 보기", action: onOpenChats)
                                .buttonStyle(.bordered)
                        }

                        VStack {
                            Button("캐릭터 생성", action: onCreate)
                                .buttonStyle(.borderedProminent)
                            Button("채팅 보기", action: onOpenChats)
                                .buttonStyle(.bordered)
                        }
                    }
                }
            } else {
                List {
                    Section("이야기 이어가기") {
                        ForEach(viewModel.characters.prefix(5)) { character in
                            Button {
                                onOpenChat(character)
                            } label: {
                                IOSCharacterRow(character: character)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("이 캐릭터와의 채팅을 엽니다")
                        }
                    }

                    Section {
                        Button(action: onCreate) {
                            Label("새 캐릭터 만들기", systemImage: "plus.circle")
                        }
                        Button(action: onOpenChats) {
                            Label(
                                "채팅 전체 보기",
                                systemImage: "bubble.left.and.bubble.right"
                            )
                        }
                    } footer: {
                        Text("\(viewModel.characters.count)명의 캐릭터가 이 기기에 저장되어 있습니다.")
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await viewModel.refresh()
                }
            }
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.24),
            value: viewModel.characters.isEmpty
        )
        .accessibilityIdentifier("home-screen")
    }
}

private struct IOSCharacterRow: View {
    let character: LibraryCharacter

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 44

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: LorepiaSpacing.compact) {
                    HStack(spacing: LorepiaSpacing.compact) {
                        avatar
                        Text(character.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Spacer(minLength: LorepiaSpacing.compact)
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    summary
                }
            } else {
                HStack(spacing: LorepiaSpacing.standard) {
                    avatar
                    VStack(alignment: .leading, spacing: 4) {
                        Text(character.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        summary
                    }
                    Spacer(minLength: LorepiaSpacing.compact)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var avatar: some View {
        Image(systemName: character.symbolName)
            .font(.title2)
            .frame(
                width: max(44, min(avatarSize, 64)),
                height: max(44, min(avatarSize, 64))
            )
            .background(.tint.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }

    private var summary: some View {
        Text(character.summary)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            .multilineTextAlignment(.leading)
    }
}

private struct IOSCreateView: View {
    let onImport: () -> Void

    var body: some View {
        List {
            Section("캐릭터 생성") {
                IOSCreationModeRow(
                    title: "직접 만들기",
                    subtitle: "이름, 소개와 대화 설정을 직접 구성합니다.",
                    systemImage: "slider.horizontal.3",
                    status: "준비 중"
                )
                .accessibilityIdentifier("create-manual-mode")
                IOSCreationModeRow(
                    title: "AI와 함께 만들기",
                    subtitle: "아이디어를 바탕으로 캐릭터 초안을 함께 작성합니다.",
                    systemImage: "wand.and.stars",
                    status: "준비 중"
                )
                .accessibilityIdentifier("create-ai-mode")
            }

            Section("가져오기") {
                Button(action: onImport) {
                    IOSCreationModeRow(
                        title: "파일에서 가져오기",
                        subtitle: "CCv3 JSON 또는 CHARX 파일을 검사한 뒤 이 기기에 저장합니다.",
                        systemImage: "square.and.arrow.down",
                        showsDisclosure: true
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("파일에서 가져오기")
                .accessibilityHint("캐릭터 파일 선택기를 엽니다")
                .accessibilityIdentifier("create-import-button")
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("create-screen")
    }
}

private struct IOSCreationModeRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var status: String?
    var showsDisclosure = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 44

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: LorepiaSpacing.compact) {
                    HStack(alignment: .top, spacing: LorepiaSpacing.compact) {
                        icon
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if showsDisclosure {
                            trailing
                        }
                    }
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if status != nil {
                        trailing
                    }
                }
            } else {
                HStack(alignment: .center, spacing: LorepiaSpacing.standard) {
                    icon
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: LorepiaSpacing.compact)
                    trailing
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var icon: some View {
        Image(systemName: systemImage)
            .font(.title2)
            .frame(
                width: max(44, min(iconSize, 64)),
                height: max(44, min(iconSize, 64))
            )
            .background(.tint.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var trailing: some View {
        if let status {
            Text(status)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        } else if showsDisclosure {
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }
}
