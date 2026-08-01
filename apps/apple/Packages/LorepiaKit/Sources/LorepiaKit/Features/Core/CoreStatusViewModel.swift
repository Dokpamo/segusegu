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
            async let loadedVersion = client.version()
            async let loadedVersions = client.apiVersions()
            async let loadedHealth = client.health()
            let (version, versions, health) = try await (
                loadedVersion,
                loadedVersions,
                loadedHealth
            )
            try CoreRuntimeContract.validate(versions)
            guard version == versions.coreVersion,
                  version == health.coreVersion
            else {
                throw CoreClientFailure.invalidResponse(
                    "Core version 보고가 서로 일치하지 않습니다."
                )
            }
            state = .ready(version: version, health: health)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
