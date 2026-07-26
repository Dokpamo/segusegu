import Foundation

public struct HealthStatus: Equatable, Sendable {
    public let coreVersion: String
    public let databaseOpen: Bool
    public let schemaVersion: UInt32
    public let dataRootWritable: Bool
    public let stagingWritable: Bool
    public let recoveryPending: Bool
    public let activeJobs: UInt32

    public init(
        coreVersion: String,
        databaseOpen: Bool,
        schemaVersion: UInt32,
        dataRootWritable: Bool,
        stagingWritable: Bool,
        recoveryPending: Bool,
        activeJobs: UInt32
    ) {
        self.coreVersion = coreVersion
        self.databaseOpen = databaseOpen
        self.schemaVersion = schemaVersion
        self.dataRootWritable = dataRootWritable
        self.stagingWritable = stagingWritable
        self.recoveryPending = recoveryPending
        self.activeJobs = activeJobs
    }

    public var isHealthy: Bool {
        databaseOpen
            && dataRootWritable
            && stagingWritable
            && !recoveryPending
    }
}

public enum CoreClientFailure: Error, Equatable, Sendable {
    case bindingsUnavailable
    case startupFailed(String)
}

extension CoreClientFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .bindingsUnavailable:
            "생성된 UniFFI 바인딩을 찾을 수 없습니다."
        case let .startupFailed(message):
            "Rust 코어를 열지 못했습니다: \(message)"
        }
    }
}

public protocol CoreClient: Sendable {
    func version() async throws -> String
    func health() async throws -> HealthStatus
}

public enum CoreRuntimeMode: Equatable, Sendable {
    case live
    case preview
    case unavailable(String)

    public var displayName: String {
        switch self {
        case .live:
            "Rust Core"
        case .preview:
            "Preview Core"
        case .unavailable:
            "Core Unavailable"
        }
    }
}

public struct CoreClientSelection: Sendable {
    public let client: any CoreClient
    public let mode: CoreRuntimeMode

    public init(client: any CoreClient, mode: CoreRuntimeMode) {
        self.client = client
        self.mode = mode
    }
}
