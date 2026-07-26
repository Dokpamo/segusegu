#if os(macOS)
import Combine

@MainActor
public final class MacRootNavigationModel: ObservableObject {
    public enum Destination: String, CaseIterable, Identifiable, Sendable {
        case library
        case chat
        case importReview
        case settings

        public var id: Self {
            self
        }
    }

    @Published public private(set) var destination: Destination
    private var renderAcknowledgementCounts: [Destination: Int] = [:]

    public init(destination: Destination = .library) {
        self.destination = destination
    }

    public func navigate(to destination: Destination) {
        self.destination = destination
    }

    /// Records that the real SwiftUI detail for `destination` appeared.
    public func acknowledgeRendered(_ destination: Destination) {
        guard self.destination == destination else {
            return
        }
        renderAcknowledgementCounts[destination, default: 0] += 1
    }

    /// Navigates through every macOS root route and waits for the real SwiftUI
    /// detail to acknowledge rendering before advancing.
    @discardableResult
    public func runLaunchSmoke(
        renderTimeout: Duration = .seconds(5)
    ) async throws -> [Destination] {
        guard destination == .library else {
            throw MacRootNavigationSmokeError.unexpectedInitialDestination(
                destination
            )
        }

        let expected: [Destination] = [
            .library,
            .chat,
            .settings,
            .importReview,
            .library,
        ]
        var visited: [Destination] = []
        for (index, next) in expected.enumerated() {
            let previousAcknowledgements =
                renderAcknowledgementCounts[next, default: 0]
            let requiredAcknowledgements = index == 0
                ? 1
                : previousAcknowledgements + 1
            if index > 0 {
                navigate(to: next)
            }
            try await waitUntilRendered(
                next,
                minimumAcknowledgements: requiredAcknowledgements,
                timeout: renderTimeout
            )
            visited.append(next)
        }

        guard visited == expected,
              Set(visited) == Set(Destination.allCases)
        else {
            throw MacRootNavigationSmokeError.unexpectedRouteSequence(
                expected: expected,
                actual: visited
            )
        }
        return visited
    }

    private func waitUntilRendered(
        _ destination: Destination,
        minimumAcknowledgements: Int,
        timeout: Duration
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while renderAcknowledgementCounts[destination, default: 0]
            < minimumAcknowledgements
        {
            guard clock.now < deadline else {
                throw MacRootNavigationSmokeError.renderTimedOut(destination)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

public enum MacRootNavigationSmokeError: Error, Equatable, Sendable {
    case unexpectedInitialDestination(MacRootNavigationModel.Destination)
    case renderTimedOut(MacRootNavigationModel.Destination)
    case unexpectedRouteSequence(
        expected: [MacRootNavigationModel.Destination],
        actual: [MacRootNavigationModel.Destination]
    )
}
#endif
