import Combine

public enum CoreStatusState: Equatable, Sendable {
    case idle
    case loading
    case ready(version: String, health: HealthStatus)
    case failed(String)
}

@MainActor
public final class CoreStatusViewModel: ObservableObject {
    @Published public private(set) var state: CoreStatusState = .idle

    public let runtimeMode: CoreRuntimeMode
    private let client: any CoreClient

    public init(client: any CoreClient, runtimeMode: CoreRuntimeMode) {
        self.client = client
        self.runtimeMode = runtimeMode
    }

    public func refresh() async {
        state = .loading
        do {
            let version = try await client.version()
            let health = try await client.health()
            state = .ready(version: version, health: health)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
