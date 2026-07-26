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
#endif
        environment = AppEnvironment.makeDefault(
            dataRoot: IOSAppDirectories.dataRoot()
        )
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView(environment: environment)
        }
    }
}
