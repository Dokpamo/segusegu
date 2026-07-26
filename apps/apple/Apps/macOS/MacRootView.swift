import Combine
import LorepiaKit
import SwiftUI
import UniformTypeIdentifiers

private extension Notification.Name {
    static let lorepiaImportRequested = Notification.Name(
        "dev.lorepia.mac.import-requested"
    )
}

struct LorepiaMacCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("콘텐츠 가져오기…") {
                NotificationCenter.default.post(
                    name: .lorepiaImportRequested,
                    object: nil
                )
            }
            .keyboardShortcut("o")
        }
    }
}

private extension MacRootNavigationModel.Destination {
    var title: String {
        switch self {
        case .library:
            "서재"
        case .chat:
            "채팅"
        case .importReview:
            "가져오기 검토"
        case .settings:
            "설정"
        }
    }

    var symbol: String {
        switch self {
        case .library:
            "books.vertical"
        case .chat:
            "bubble.left.and.bubble.right"
        case .importReview:
            "doc.badge.plus"
        case .settings:
            "gearshape"
        }
    }
}

struct MacRootView: View {
    let environment: AppEnvironment

    @ObservedObject private var navigationModel: MacRootNavigationModel
    @ObservedObject private var settingsViewModel: SettingsViewModel
    @State private var showsFileImporter = false

    init(
        environment: AppEnvironment,
        navigationModel: MacRootNavigationModel
    ) {
        self.environment = environment
        self.navigationModel = navigationModel
        settingsViewModel = environment.settingsViewModel
    }

    var body: some View {
        NavigationSplitView {
            List(
                MacRootNavigationModel.Destination.allCases,
                selection: Binding<MacRootNavigationModel.Destination?>(
                    get: { navigationModel.destination },
                    set: { destination in
                        if let destination {
                            navigationModel.navigate(to: destination)
                        }
                    }
                )
            ) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationTitle("LorePia")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            HSplitView {
                detail
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)

                if settingsViewModel.showTechnicalDetails {
                    ScrollView {
                        CoreStatusPanel(
                            viewModel: environment.coreStatusViewModel
                        )
                        .padding(LorepiaSpacing.standard)
                    }
                    .frame(minWidth: 250, idealWidth: 280, maxWidth: 320)
                }
            }
            .navigationTitle(navigationModel.destination.title)
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else {
                return
            }
            prepareImport(url)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else {
                return false
            }
            prepareImport(url)
            return true
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .lorepiaImportRequested)
        ) { _ in
            showsFileImporter = true
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch navigationModel.destination {
        case .library:
            LibraryView(
                viewModel: environment.libraryViewModel,
                onImport: {
                    showsFileImporter = true
                },
                onOpenChat: { character in
                    navigationModel.navigate(to: .chat)
                    Task {
                        await environment.selectCharacter(character)
                    }
                }
            )
            .onAppear {
                navigationModel.acknowledgeRendered(.library)
            }
        case .chat:
            ChatView(viewModel: environment.chatViewModel)
                .onAppear {
                    navigationModel.acknowledgeRendered(.chat)
                }
        case .importReview:
            ImportReviewView(
                viewModel: environment.importReviewViewModel,
                onPickFile: {
                    showsFileImporter = true
                },
                onFinished: {
                    navigationModel.navigate(to: .library)
                }
            )
            .onAppear {
                navigationModel.acknowledgeRendered(.importReview)
            }
        case .settings:
            SettingsView(viewModel: settingsViewModel)
                .onAppear {
                    navigationModel.acknowledgeRendered(.settings)
                }
        }
    }

    private func prepareImport(_ url: URL) {
        navigationModel.navigate(to: .importReview)
        Task {
            await environment.prepareImport(from: url)
        }
    }
}
