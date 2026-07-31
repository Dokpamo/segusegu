import AppKit
import Darwin
import LorepiaKit
import SwiftUI

@main
@MainActor
struct LorepiaMacApp: App {
    private let environment: AppEnvironment
    private let navigationModel: MacRootNavigationModel
    private let isLaunchSmoke: Bool

    init() {
        isLaunchSmoke = ProcessInfo.processInfo.arguments
            .contains("--lorepia-ci-smoke")
        if isLaunchSmoke {
            Self.traceLaunchSmoke("app init started")
        }
        environment = AppEnvironment.makeDefault(
            dataRoot: MacAppDirectories.dataRoot()
        )
        if isLaunchSmoke {
            Self.traceLaunchSmoke("environment initialized")
        }
        navigationModel = MacRootNavigationModel()
        if isLaunchSmoke {
            Self.traceLaunchSmoke("navigation initialized")
        }
    }

    var body: some Scene {
        WindowGroup {
            MacRootView(
                environment: environment,
                navigationModel: navigationModel
            )
                .frame(minWidth: 880, minHeight: 560)
                .task {
                    if isLaunchSmoke {
                        Self.traceLaunchSmoke("root task started")
                    }
                    await environment.start()
                    if isLaunchSmoke {
                        Self.traceLaunchSmoke("environment started")
                    }
                    if isLaunchSmoke {
                        do {
                            Self.traceLaunchSmoke("navigation smoke started")
                            let routes = try await navigationModel
                                .runLaunchSmoke(
                                    settleDelay: .milliseconds(200)
                                ) { destination in
                                    Self.traceLaunchSmoke(
                                        "rendered \(destination.rawValue)"
                                    )
                                }
                            Self.traceLaunchSmoke("navigation smoke completed")
                            try await environment.validateForLaunchSmoke()
                            Self.traceLaunchSmoke("core validation completed")
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

    private static func traceLaunchSmoke(_ message: String) {
        fputs("LorePia macOS smoke: \(message)\n", stderr)
        fflush(stderr)
    }
}
