import Foundation

public actor FakeCoreClient: CoreClient {
    private let reportedVersion: String
    private let reportedHealth: HealthStatus

    public init(
        version: String = "lorepia-core-preview/0.1.0",
        health: HealthStatus? = nil
    ) {
        reportedVersion = version
        reportedHealth = health ?? HealthStatus(
            coreVersion: version,
            databaseOpen: true,
            schemaVersion: 1,
            dataRootWritable: true,
            stagingWritable: true,
            recoveryPending: false,
            activeJobs: 0
        )
    }

    public func version() async throws -> String {
        reportedVersion
    }

    public func health() async throws -> HealthStatus {
        reportedHealth
    }
}

public actor UnavailableCoreClient: CoreClient {
    private let failure: CoreClientFailure

    public init(message: String) {
        failure = .startupFailed(message)
    }

    public func version() async throws -> String {
        throw failure
    }

    public func health() async throws -> HealthStatus {
        throw failure
    }
}
