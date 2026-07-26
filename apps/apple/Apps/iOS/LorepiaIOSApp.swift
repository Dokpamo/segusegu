import LorepiaKit
import SwiftUI

@main
@MainActor
struct LorepiaIOSApp: App {
    private let environment: AppEnvironment

    init() {
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
