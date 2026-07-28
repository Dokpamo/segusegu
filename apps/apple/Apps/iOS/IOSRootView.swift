import LorepiaKit
import SwiftUI
import Darwin

struct IOSRootView: View {
    private enum Tab: Hashable {
        case home
        case chats
        case create
        case settings
    }

    let environment: AppEnvironment
    @ObservedObject private var settingsViewModel: SettingsViewModel

    @State private var selectedTab: Tab = .home
    @State private var chatNavigationPath: [ConversationListItem] = []
    @State private var showsCoreStatus = false

    init(environment: AppEnvironment) {
        self.environment = environment
        settingsViewModel = environment.settingsViewModel
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                IOSHomeView {
                    selectedTab = .create
                }
                .navigationTitle("홈")
            }
            .tabItem {
                Label("홈", image: "TabHome")
            }
            .tag(Tab.home)

            NavigationStack(path: $chatNavigationPath) {
                ConversationListView(
                    viewModel: environment.conversationListViewModel,
                    onOpenConversation: { item in
                        guard chatNavigationPath.isEmpty else {
                            return
                        }
                        chatNavigationPath.append(item)
                    },
                    onRequestCharacter: {
                        selectedTab = .create
                    }
                )
                .navigationTitle("채팅")
                .navigationDestination(for: ConversationListItem.self) { item in
                    ChatView(
                        viewModel: environment.chatViewModel,
                        onOpenProviderSettings: {
                            selectedTab = .settings
                            Task {
                                await settingsViewModel.refresh()
                            }
                        }
                    )
                        .navigationBarTitleDisplayMode(.inline)
                        .task(id: item.id) {
                            await environment.selectConversation(item)
                        }
                }
            }
            .tabItem {
                Label("채팅", image: "TabChats")
            }
            .tag(Tab.chats)

            NavigationStack {
                IOSCreateView()
                    .navigationTitle("생성")
            }
            .tabItem {
                Label("생성", image: "TabCreate")
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
                                    Label {
                                        Text("코어 상태")
                                    } icon: {
                                        LorepiaGlyphView(
                                            .waveform,
                                            size: 18
                                        )
                                    }
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
                Label("설정", image: "TabSettings")
            }
            .tag(Tab.settings)
        }
        .lorepiaTabBarBehavior()
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
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
#else
        self
#endif
    }
}

private struct IOSHomeView: View {
    let onAdd: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(.systemBackground)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                Button(action: onAdd) {
                    Text("추가하기")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(minHeight: 44)
                .position(
                    x: geometry.size.width / 2,
                    y: geometry.size.height * 0.68
                )
                .accessibilityIdentifier("home-add-button")
            }
        }
    }
}

private struct IOSCreateView: View {
    var body: some View {
        Color(.systemBackground)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
