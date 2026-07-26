#if os(macOS)
import XCTest
@testable import LorepiaKit

@MainActor
final class MacRootNavigationModelTests: XCTestCase {
    func testLaunchSmokeTraversesEveryRootDestinationAndReturnsToLibrary()
        async throws
    {
        let model = MacRootNavigationModel()
        let renderTask = Task { @MainActor in
            var lastRendered: MacRootNavigationModel.Destination?
            while !Task.isCancelled {
                let destination = model.destination
                if destination != lastRendered {
                    model.acknowledgeRendered(destination)
                    lastRendered = destination
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        defer {
            renderTask.cancel()
        }

        let visited = try await model.runLaunchSmoke(
            renderTimeout: .seconds(1)
        )

        XCTAssertEqual(
            visited,
            [.library, .chat, .settings, .importReview, .library]
        )
        XCTAssertEqual(
            Set(visited),
            Set(MacRootNavigationModel.Destination.allCases)
        )
        XCTAssertEqual(model.destination, .library)
    }

    func testLaunchSmokeFailsClosedWhenDetailDoesNotRender() async {
        let model = MacRootNavigationModel()
        model.acknowledgeRendered(.library)

        do {
            _ = try await model.runLaunchSmoke(
                renderTimeout: .milliseconds(40)
            )
            XCTFail("Expected the missing Chat render to time out.")
        } catch {
            XCTAssertEqual(
                error as? MacRootNavigationSmokeError,
                .renderTimedOut(.chat)
            )
        }
    }

    func testLaunchSmokeFailsClosedWhenItDoesNotStartAtLibrary() async {
        let model = MacRootNavigationModel(destination: .chat)

        do {
            _ = try await model.runLaunchSmoke(
                renderTimeout: .milliseconds(40)
            )
            XCTFail("Expected a non-Library initial route to fail.")
        } catch {
            XCTAssertEqual(
                error as? MacRootNavigationSmokeError,
                .unexpectedInitialDestination(.chat)
            )
        }
    }
}
#endif
