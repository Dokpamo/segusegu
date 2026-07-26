import LorepiaKit
import SwiftUI

@main
@MainActor
struct LorepiaMacApp: App {
    private let environment: AppEnvironment

    init() {
        environment = AppEnvironment.makeDefault(
            dataRoot: MacAppDirectories.dataRoot()
        )
    }

    var body: some Scene {
        WindowGroup {
            MacRootView(environment: environment)
                .frame(minWidth: 880, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            LorepiaMacCommands()
        }
    }
}
