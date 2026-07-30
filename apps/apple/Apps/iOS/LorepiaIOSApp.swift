import Foundation
import LorepiaKit
import SwiftUI

@main
@MainActor
struct LorepiaIOSApp: App {
    private let environment: AppEnvironment

    init() {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--lorepia-ui-test") {
            environment = AppEnvironment(
                coreClient: FakeCoreClient(characters: []),
                runtimeMode: .preview,
                credentialStore: InMemoryCredentialStore(),
                characters: []
            )
            return
        }
        if arguments.contains(
            "--lorepia-native-navigation-ui-test"
        ) {
            environment = AppEnvironment(
                coreClient: FakeCoreClient(),
                runtimeMode: .preview,
                credentialStore: InMemoryCredentialStore(),
                characters: LibraryCharacter.previewCharacters
            )
            return
        }
        if arguments.contains("--lorepia-ci-smoke") {
            environment = AppEnvironment.makeDefault(
                dataRoot: IOSAppDirectories.dataRoot()
            )
            return
        }
        if arguments.contains("--lorepia-live-core") {
            environment = AppEnvironment.makeDefault(
                dataRoot: IOSAppDirectories.dataRoot()
            )
            return
        }
        if arguments.contains("--lorepia-chat-history-showcase") {
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
            return
        }
        if arguments.contains("--lorepia-chat-bubble-showcase") {
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
            return
        }
        if arguments.contains("--lorepia-dev-fixtures") {
            environment = DevelopmentFixtures.makeEnvironment(
                for: .comprehensive
            )
            return
        }
        if arguments.contains("--lorepia-dev-empty") {
            environment = DevelopmentFixtures.makeEnvironment(
                for: .empty
            )
            return
        }
        if arguments.contains("--lorepia-dev-provider-missing") {
            environment = DevelopmentFixtures.makeEnvironment(
                for: .providerMissing
            )
            return
        }
        if arguments.contains("--lorepia-dev-credential-missing") {
            environment = DevelopmentFixtures.makeEnvironment(
                for: .credentialMissing
            )
            return
        }
        if arguments.contains("--lorepia-dev-provider-unselected") {
            environment = DevelopmentFixtures.makeEnvironment(
                for: .providerUnselected
            )
            return
        }
        if arguments.contains("--lorepia-dev-health-warning") {
            environment = DevelopmentFixtures.makeEnvironment(
                for: .healthWarning
            )
            return
        }
        if arguments.contains("--lorepia-dev-core-unavailable") {
            environment = DevelopmentFixtures.makeEnvironment(
                for: .coreUnavailable
            )
            return
        }
        if arguments.contains("--lorepia-dev-load") {
            environment = DevelopmentFixtures.makeEnvironment(
                for: .load
            )
            return
        }
        environment = DevelopmentFixtures.makeEnvironment(
            for: .comprehensive
        )
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
