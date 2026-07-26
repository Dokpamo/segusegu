import XCTest
@testable import LorepiaKit

@MainActor
final class CoreClientTests: XCTestCase {
    func testFakeClientReportsVersionAndHealth() async throws {
        let client = FakeCoreClient(version: "test-core/1")

        let version = try await client.version()
        let health = try await client.health()

        XCTAssertEqual(version, "test-core/1")
        XCTAssertEqual(health.coreVersion, "test-core/1")
        XCTAssertTrue(health.isHealthy)
        XCTAssertEqual(health.activeJobs, 0)
    }

    func testHealthRequiresWritableStoresAndNoPendingRecovery() {
        let health = HealthStatus(
            coreVersion: "test-core/1",
            databaseOpen: true,
            schemaVersion: 1,
            dataRootWritable: true,
            stagingWritable: false,
            recoveryPending: false,
            activeJobs: 0
        )

        XCTAssertFalse(health.isHealthy)
    }

    func testStatusViewModelMapsClientReport() async {
        let client = FakeCoreClient(version: "test-core/2")
        let viewModel = CoreStatusViewModel(
            client: client,
            runtimeMode: .preview
        )

        await viewModel.refresh()

        guard case let .ready(version, health) = viewModel.state else {
            return XCTFail("Expected a ready state")
        }
        XCTAssertEqual(version, "test-core/2")
        XCTAssertEqual(health.schemaVersion, 1)
    }

    #if LOREPIA_UNIFFI_GENERATED
    func testGeneratedBindingsOpenTheRealCore() async throws {
        let dataRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        let selection = CoreClientFactory.make(dataRoot: dataRoot)
        XCTAssertEqual(selection.mode, .live)

        let version = try await selection.client.version()
        let health = try await selection.client.health()

        XCTAssertFalse(version.isEmpty)
        XCTAssertEqual(health.coreVersion, version)
        XCTAssertTrue(health.databaseOpen)
        XCTAssertTrue(health.dataRootWritable)
        XCTAssertTrue(health.stagingWritable)
    }
    #endif
}
