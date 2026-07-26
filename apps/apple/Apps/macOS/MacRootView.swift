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

struct MacRootView: View {
    private enum Destination: String, CaseIterable, Identifiable {
        case library
        case chat
        case importReview
        case settings

        var id: Self {
            self
        }

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

    let environment: AppEnvironment

    @ObservedObject private var settingsViewModel: SettingsViewModel
    @State private var destination: Destination? = .library
    @State private var showsFileImporter = false

    init(environment: AppEnvironment) {
        self.environment = environment
        settingsViewModel = environment.settingsViewModel
    }

    var body: some View {
        NavigationSplitView {
            List(Destination.allCases, selection: $destination) { item in
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
            .navigationTitle(destination?.title ?? "LorePia")
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
        switch destination ?? .library {
        case .library:
            LibraryView(
                viewModel: environment.libraryViewModel,
                onImport: {
                    showsFileImporter = true
                },
                onOpenChat: { character in
                    environment.selectCharacter(character)
                    destination = .chat
                }
            )
        case .chat:
            ChatView(viewModel: environment.chatViewModel)
        case .importReview:
            ImportReviewView(
                viewModel: environment.importReviewViewModel,
                onPickFile: {
                    showsFileImporter = true
                }
            )
        case .settings:
            SettingsView(viewModel: settingsViewModel)
        }
    }

    private func prepareImport(_ url: URL) {
        environment.prepareImport(from: url)
        destination = .importReview
    }
}
