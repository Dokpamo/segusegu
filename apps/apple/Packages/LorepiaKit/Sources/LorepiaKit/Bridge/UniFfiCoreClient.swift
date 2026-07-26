import Foundation

#if LOREPIA_UNIFFI_GENERATED
public actor UniFfiCoreClient: CoreClient {
    private let core: LorepiaCore

    public init(dataRoot: URL) throws {
        let config = FfiCoreConfig(
            dataRoot: dataRoot.path(percentEncoded: false)
        )
        core = try LorepiaCore.open(config: config)
    }

    public func version() async throws -> String {
        coreVersion()
    }

    public func health() async throws -> HealthStatus {
        let report = try core.healthCheck()
        return HealthStatus(
            coreVersion: report.coreVersion,
            databaseOpen: report.databaseOpen,
            schemaVersion: report.schemaVersion,
            dataRootWritable: report.dataRootWritable,
            stagingWritable: report.stagingWritable,
            recoveryPending: report.recoveryPending,
            activeJobs: report.activeJobs
        )
    }
}
#else
public actor UniFfiCoreClient: CoreClient {
    public init(dataRoot _: URL) throws {
        throw CoreClientFailure.bindingsUnavailable
    }

    public func version() async throws -> String {
        throw CoreClientFailure.bindingsUnavailable
    }

    public func health() async throws -> HealthStatus {
        throw CoreClientFailure.bindingsUnavailable
    }
}
#endif

public enum CoreClientFactory {
    public static func make(dataRoot: URL) -> CoreClientSelection {
        #if LOREPIA_UNIFFI_GENERATED
        do {
            return CoreClientSelection(
                client: try UniFfiCoreClient(dataRoot: dataRoot),
                mode: .live
            )
        } catch {
            let message = String(describing: error)
            return CoreClientSelection(
                client: UnavailableCoreClient(message: message),
                mode: .unavailable(message)
            )
        }
        #else
        return CoreClientSelection(
            client: FakeCoreClient(),
            mode: .preview
        )
        #endif
    }
}
