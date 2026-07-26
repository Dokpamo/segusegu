import LorepiaKit
import SwiftUI
import UniformTypeIdentifiers
import Darwin

struct IOSRootView: View {
    private enum Tab: Hashable {
        case library
        case chat
        case settings
    }

    let environment: AppEnvironment
    @ObservedObject private var importReviewViewModel: ImportReviewViewModel

    @State private var selectedTab: Tab = .library
    @State private var showsFileImporter = false
    @State private var showsImportReview = false

    init(environment: AppEnvironment) {
        self.environment = environment
        importReviewViewModel = environment.importReviewViewModel
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                LibraryView(
                    viewModel: environment.libraryViewModel,
                    onImport: {
                        showsFileImporter = true
                    },
                    onOpenChat: { character in
                        selectedTab = .chat
                        Task {
                            await environment.selectCharacter(character)
                        }
                    }
                )
                .navigationTitle("서재")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showsFileImporter = true
                        } label: {
                            Label("가져오기", systemImage: "square.and.arrow.down")
                        }
                    }
                }
            }
            .tabItem {
                Label("서재", systemImage: "books.vertical")
            }
            .tag(Tab.library)

            NavigationStack {
                ChatView(viewModel: environment.chatViewModel)
                    .navigationTitle("채팅")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem {
                Label("채팅", systemImage: "bubble.left.and.bubble.right")
            }
            .tag(Tab.chat)

            NavigationStack {
                VStack(spacing: 0) {
                    SettingsView(viewModel: environment.settingsViewModel)
                    if environment.settingsViewModel.showTechnicalDetails {
                        CoreStatusPanel(
                            viewModel: environment.coreStatusViewModel
                        )
                        .padding(LorepiaSpacing.standard)
                    }
                }
                .navigationTitle("설정")
            }
            .tabItem {
                Label("설정", systemImage: "gearshape")
            }
            .tag(Tab.settings)
        }
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
                    onFinished: {
                        showsImportReview = false
                        selectedTab = .library
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
