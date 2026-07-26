import AppKit
import Darwin
import LorepiaKit
import SwiftUI

@main
@MainActor
struct LorepiaMacApp: App {
    private let environment: AppEnvironment
    private let navigationModel: MacRootNavigationModel

    init() {
        environment = AppEnvironment.makeDefault(
            dataRoot: MacAppDirectories.dataRoot()
        )
        navigationModel = MacRootNavigationModel()
    }

    var body: some Scene {
        WindowGroup {
            MacRootView(
                environment: environment,
                navigationModel: navigationModel
            )
                .frame(minWidth: 880, minHeight: 560)
                .task {
                    await environment.start()
                    let isLaunchSmoke = ProcessInfo.processInfo.arguments
                        .contains("--lorepia-ci-smoke")
                    if isLaunchSmoke {
                        do {
                            let routes = try await navigationModel
                                .runLaunchSmoke()
                            try await environment.validateForLaunchSmoke()
                            let routeLog = routes
                                .map(\.rawValue)
                                .joined(separator: " -> ")
                            fputs(
                                "LorePia macOS navigation smoke: \(routeLog)\n",
                                stderr
                            )
                            exit(EXIT_SUCCESS)
                        } catch {
                            fputs(
                                "LorePia macOS launch smoke failed: \(error)\n",
                                stderr
                            )
                            exit(EXIT_FAILURE)
                        }
                    }
                }
                .accessibilityIdentifier("lorepia-root")
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            LorepiaMacCommands()
        }
    }
}
