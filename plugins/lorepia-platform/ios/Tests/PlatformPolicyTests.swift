import XCTest
@testable import LorepiaPlatformPlugin

final class PlatformPolicyTests: XCTestCase {
    func testStagingWorkCannotBlockCredentialWork() {
        let queues = PlatformWorkQueues()
        let stagingStarted = expectation(description: "staging started")
        let stagingFinished = expectation(description: "staging finished")
        let credentialFinished = expectation(description: "credential finished")
        let releaseStaging = DispatchSemaphore(value: 0)

        queues.scheduleStaging {
            stagingStarted.fulfill()
            XCTAssertEqual(
                releaseStaging.wait(timeout: .now() + 2),
                .success
            )
            stagingFinished.fulfill()
        }
        wait(for: [stagingStarted], timeout: 1)

        queues.scheduleCredential {
            credentialFinished.fulfill()
        }
        wait(for: [credentialFinished], timeout: 1)

        releaseStaging.signal()
        wait(for: [stagingFinished], timeout: 1)
    }

    func testWorkQueuesPreserveOrderingWithinEachDomain() {
        let queues = PlatformWorkQueues()
        let credentialFinished = expectation(
            description: "credential work finished"
        )
        credentialFinished.expectedFulfillmentCount = 2
        let stagingFinished = expectation(description: "staging work finished")
        stagingFinished.expectedFulfillmentCount = 2
        let lock = NSLock()
        var credentialOrder: [Int] = []
        var stagingOrder: [Int] = []

        for value in 1 ... 2 {
            queues.scheduleCredential {
                lock.lock()
                credentialOrder.append(value)
                lock.unlock()
                credentialFinished.fulfill()
            }
            queues.scheduleStaging {
                lock.lock()
                stagingOrder.append(value)
                lock.unlock()
                stagingFinished.fulfill()
            }
        }

        wait(
            for: [credentialFinished, stagingFinished],
            timeout: 1
        )
        XCTAssertEqual(credentialOrder, [1, 2])
        XCTAssertEqual(stagingOrder, [1, 2])
    }

    func testReferenceLimitUsesUTF8Bytes() throws {
        try PlatformPolicy.validateReference(
            String(repeating: "a", count: 256)
        )
        XCTAssertThrowsError(
            try PlatformPolicy.validateReference(
                String(repeating: "가", count: 86)
            )
        )
    }

    func testCredentialIsTrimmedAndBounded() throws {
        XCTAssertEqual(
            try PlatformPolicy.normalizeCredential("  secret\n"),
            "secret"
        )
        XCTAssertThrowsError(
            try PlatformPolicy.normalizeCredential(
                String(repeating: "a", count: 16 * 1_024 + 1)
            )
        )
    }

    func testStagingSuffixIsAllowlisted() {
        XCTAssertEqual(
            PlatformPolicy.stagingSuffix(for: "character.CHARX"),
            ".charx"
        )
        XCTAssertEqual(
            PlatformPolicy.stagingSuffix(for: "archive.tar.gz"),
            ".pending"
        )
    }

    func testDisplayNameReplacesControls() {
        XCTAssertEqual(
            PlatformPolicy.sanitizeDisplayName("bad\u{0000}name.json"),
            "bad\u{FFFD}name.json"
        )
    }

    func testAbandonedStagingCleanupRequiresOwnedOldRegularFile() {
        let now = Date(timeIntervalSince1970: 200_000)
        let old = now.addingTimeInterval(-PlatformPolicy.abandonedStagingAge)
        XCTAssertTrue(
            PlatformPolicy.shouldRemoveAbandonedStagingFile(
                name: PlatformPolicy.ownedStagingPrefix + "synthetic.json",
                isRegularFile: true,
                modifiedAt: old,
                now: now
            )
        )
        XCTAssertFalse(
            PlatformPolicy.shouldRemoveAbandonedStagingFile(
                name: "unrelated.json",
                isRegularFile: true,
                modifiedAt: old,
                now: now
            )
        )
        XCTAssertFalse(
            PlatformPolicy.shouldRemoveAbandonedStagingFile(
                name: PlatformPolicy.ownedStagingPrefix + "fresh.json",
                isRegularFile: true,
                modifiedAt: old.addingTimeInterval(1),
                now: now
            )
        )
        XCTAssertFalse(
            PlatformPolicy.shouldRemoveAbandonedStagingFile(
                name: PlatformPolicy.ownedStagingPrefix + "directory",
                isRegularFile: false,
                modifiedAt: old,
                now: now
            )
        )
    }

    func testStagedImportDescriptionRedactsPathAndDisplayName() {
        let path = "/synthetic/private/card.json"
        let displayName = "private-card.json"
        let staged = NativeStagedImport(
            path: path,
            displayName: displayName,
            sizeBytes: 42
        )

        XCTAssertFalse(String(describing: staged).contains(path))
        XCTAssertFalse(String(describing: staged).contains(displayName))
        XCTAssertFalse(String(reflecting: staged).contains(path))
        XCTAssertFalse(String(reflecting: staged).contains(displayName))
        XCTAssertTrue(String(describing: staged).contains("[REDACTED]"))
    }
}
