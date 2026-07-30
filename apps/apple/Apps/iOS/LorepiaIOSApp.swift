import Foundation
import LorepiaKit
import SwiftUI

@main
@MainActor
struct LorepiaIOSApp: App {
    private let environment: AppEnvironment

    init() {
#if DEBUG
        switch IOSLaunchRoute.resolve(
            arguments: ProcessInfo.processInfo.arguments
        ) {
        case .live:
            environment = AppEnvironment.makeDefault(
                dataRoot: IOSAppDirectories.dataRoot()
            )

        case .uiTest:
            environment = AppEnvironment(
                coreClient: FakeCoreClient(characters: []),
                runtimeMode: .preview,
                credentialStore: InMemoryCredentialStore(),
                characters: []
            )

        case .nativeNavigationUITest:
            environment = AppEnvironment(
                coreClient: FakeCoreClient(),
                runtimeMode: .preview,
                credentialStore: InMemoryCredentialStore(),
                characters: LibraryCharacter.previewCharacters
            )

        case .chatHistoryShowcase:
            environment = AppEnvironment(
                coreClient: FakeCoreClient(
                    initialConversationMessages:
                        ChatHistoryShowcase.messages,
                    initialConversationFixtures:
                        ChatHistoryShowcase.conversationFixtures
                ),
                runtimeMode: .preview,
                credentialStore: InMemoryCredentialStore(),
                characters: LibraryCharacter.previewCharacters
            )

        case .chatBubbleShowcase:
            environment = AppEnvironment(
                coreClient: FakeCoreClient(
                    initialConversationMessages:
                        ChatBubbleShowcase.messages,
                    initialConversationFixtures:
                        ChatBubbleShowcase.conversationFixtures
                ),
                runtimeMode: .preview,
                credentialStore: InMemoryCredentialStore(),
                characters: LibraryCharacter.previewCharacters
            )

        case .comprehensiveFixtures:
            environment = DevelopmentFixtures.makeEnvironment(
                for: .comprehensive
            )

        case .emptyFixtures:
            environment = DevelopmentFixtures.makeEnvironment(
                for: .empty
            )

        case .providerMissingFixtures:
            environment = DevelopmentFixtures.makeEnvironment(
                for: .providerMissing
            )

        case .credentialMissingFixtures:
            environment = DevelopmentFixtures.makeEnvironment(
                for: .credentialMissing
            )

        case .providerUnselectedFixtures:
            environment = DevelopmentFixtures.makeEnvironment(
                for: .providerUnselected
            )

        case .healthWarningFixtures:
            environment = DevelopmentFixtures.makeEnvironment(
                for: .healthWarning
            )

        case .coreUnavailableFixtures:
            environment = DevelopmentFixtures.makeEnvironment(
                for: .coreUnavailable
            )

        case .loadFixtures:
            environment = DevelopmentFixtures.makeEnvironment(
                for: .load
            )
        }
#else
        environment = AppEnvironment.makeDefault(
            dataRoot: IOSAppDirectories.dataRoot()
        )
#endif
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView(environment: environment)
        }
    }
}

#if DEBUG
/// The explicitly supported launch routes for the native iOS application.
///
/// Unknown arguments deliberately resolve to `live`. This prevents a typo in
/// a development-fixture flag from silently replacing the local Rust core
/// with synthetic data.
private enum IOSLaunchRoute: Equatable, Sendable {
    case live
    case uiTest
    case nativeNavigationUITest
    case chatHistoryShowcase
    case chatBubbleShowcase
    case comprehensiveFixtures
    case emptyFixtures
    case providerMissingFixtures
    case credentialMissingFixtures
    case providerUnselectedFixtures
    case healthWarningFixtures
    case coreUnavailableFixtures
    case loadFixtures

    /// Resolves a process argument list with the application's fixed
    /// precedence. Only a recognized, explicit fixture argument can select a
    /// synthetic environment.
    static func resolve(arguments: [String]) -> IOSLaunchRoute {
        let arguments = Set(arguments)

        if arguments.contains("--lorepia-ui-test") {
            return .uiTest
        }
        if arguments.contains("--lorepia-native-navigation-ui-test") {
            return .nativeNavigationUITest
        }
        if arguments.contains("--lorepia-ci-smoke")
            || arguments.contains("--lorepia-live-core")
        {
            return .live
        }
        if arguments.contains("--lorepia-chat-history-showcase") {
            return .chatHistoryShowcase
        }
        if arguments.contains("--lorepia-chat-bubble-showcase") {
            return .chatBubbleShowcase
        }
        if arguments.contains("--lorepia-dev-fixtures") {
            return .comprehensiveFixtures
        }
        if arguments.contains("--lorepia-dev-empty") {
            return .emptyFixtures
        }
        if arguments.contains("--lorepia-dev-provider-missing") {
            return .providerMissingFixtures
        }
        if arguments.contains("--lorepia-dev-credential-missing") {
            return .credentialMissingFixtures
        }
        if arguments.contains("--lorepia-dev-provider-unselected") {
            return .providerUnselectedFixtures
        }
        if arguments.contains("--lorepia-dev-health-warning") {
            return .healthWarningFixtures
        }
        if arguments.contains("--lorepia-dev-core-unavailable") {
            return .coreUnavailableFixtures
        }
        if arguments.contains("--lorepia-dev-load") {
            return .loadFixtures
        }
        return .live
    }
}
#endif
