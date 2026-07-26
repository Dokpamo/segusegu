import Foundation
import XCTest
@testable import LorepiaKit

#if canImport(Darwin)
import Darwin
#endif

@MainActor
final class CoreClientTests: XCTestCase {
    func testFakeClientReportsVersionHealthAndV4Defaults() async throws {
        let client = FakeCoreClient(version: "test-core/1")

        let version = try await client.version()
        let versions = try await client.apiVersions()
        let health = try await client.health()
        let characters = try await client.listCharacters()
        let character = try await client.getCharacter(id: characters[0].id)
        let profiles = try await client.listProviderProfiles()
        let settings = try await client.getSettings()

        XCTAssertEqual(version, "test-core/1")
        XCTAssertEqual(versions.coreAPIVersion, 4)
        XCTAssertEqual(versions.bindingAPIVersion, 4)
        XCTAssertEqual(versions.chatEventVersion, 2)
        XCTAssertEqual(character.id, characters[0].id)
        XCTAssertEqual(health.coreVersion, "test-core/1")
        XCTAssertTrue(health.isHealthy)
        XCTAssertEqual(health.activeJobs, 0)
        XCTAssertFalse(characters.isEmpty)
        XCTAssertEqual(settings.selectedProviderProfileID, profiles.first?.id)
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

    func testLaunchSmokeRejectsNonLiveRuntime() async {
        let environment = AppEnvironment(
            coreClient: FakeCoreClient(),
            runtimeMode: .preview,
            credentialStore: InMemoryCredentialStore()
        )

        do {
            try await environment.validateForLaunchSmoke()
            XCTFail("Preview core unexpectedly passed the executable smoke")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    #if !LOREPIA_UNIFFI_GENERATED
    func testProductionFactoryDoesNotFallBackToFakeCore() async {
        let selection = CoreClientFactory.make(
            dataRoot: FileManager.default.temporaryDirectory
        )
        guard case .unavailable = selection.mode else {
            return XCTFail("A production frame build must report unavailable bindings")
        }
        do {
            _ = try await selection.client.listCharacters()
            XCTFail("Unavailable core unexpectedly returned characters")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }
    #endif

    #if LOREPIA_UNIFFI_GENERATED
    func testGeneratedBindingsOpenTheRealCoreAndExposeV4Surface() async throws {
        let dataRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        let selection = CoreClientFactory.make(dataRoot: dataRoot)
        XCTAssertEqual(selection.mode, .live)

        let version = try await selection.client.version()
        let versions = try await selection.client.apiVersions()
        let health = try await selection.client.health()
        let characters = try await selection.client.listCharacters()
        let conversations = try await selection.client.listConversations()
        let profiles = try await selection.client.listProviderProfiles()
        let settings = try await selection.client.getSettings()
        let events = try await selection.client.pollEvents(maxEvents: 8)
        let stats = try await selection.client.databaseStats()

        XCTAssertFalse(version.isEmpty)
        XCTAssertEqual(versions.coreAPIVersion, 4)
        XCTAssertEqual(versions.bindingAPIVersion, 4)
        XCTAssertEqual(versions.chatEventVersion, 2)
        XCTAssertEqual(health.coreVersion, version)
        XCTAssertTrue(health.databaseOpen)
        XCTAssertTrue(health.dataRootWritable)
        XCTAssertTrue(health.stagingWritable)
        XCTAssertTrue(characters.isEmpty)
        XCTAssertTrue(conversations.isEmpty)
        XCTAssertTrue(profiles.isEmpty)
        XCTAssertNil(settings.selectedProviderProfileID)
        XCTAssertTrue(events.events.isEmpty)
        XCTAssertEqual(events.droppedEventCount, 0)
        XCTAssertEqual(stats.characters, 0)

        let environment = AppEnvironment(
            coreClient: selection.client,
            runtimeMode: selection.mode,
            credentialStore: InMemoryCredentialStore()
        )
        try await environment.validateForLaunchSmoke()
    }

    func testGeneratedCoreRestoresImportedLibraryConversationAndSettings() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dataRoot = base.appendingPathComponent("data", isDirectory: true)
        let source = base.appendingPathComponent("synthetic.json")
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
        try Data(
            #"{"spec":"chara_card_v3","data":{"name":"Apple Restart","description":"Synthetic"}}"#
                .utf8
        ).write(to: source)
        defer { try? FileManager.default.removeItem(at: base) }

        let characterID: String
        let conversationID: String
        let profile = ProviderProfile(
            id: "apple-restart-profile",
            displayName: "Apple Restart",
            baseURL: "https://example.invalid/v1",
            model: "synthetic",
            timeoutSeconds: 15
        )
        do {
            let first = CoreClientFactory.make(dataRoot: dataRoot)
            let inspection = try await first.client.inspectImport(stagedURL: source)
            let character = try await first.client.commitImport(
                inspectionID: inspection.id
            )
            let conversation = try await first.client.openConversation(
                characterID: character.id
            )
            _ = try await first.client.upsertProviderProfile(profile)
            _ = try await first.client.updateSettings(
                CoreAppSettings(
                    preservePartialGenerations: true,
                    selectedProviderProfileID: profile.id
                )
            )
            characterID = character.id
            conversationID = conversation.id
        }

        let reopened = CoreClientFactory.make(dataRoot: dataRoot)
        let characters = try await reopened.client.listCharacters()
        let conversations = try await reopened.client.listConversations()
        let profiles = try await reopened.client.listProviderProfiles()
        let settings = try await reopened.client.getSettings()

        XCTAssertEqual(characters.map(\.id), [characterID])
        XCTAssertEqual(conversations.map(\.id), [conversationID])
        XCTAssertEqual(profiles, [profile])
        XCTAssertEqual(settings.selectedProviderProfileID, profile.id)
        XCTAssertTrue(settings.preservePartialGenerations)
    }

    func testGeneratedImportReviewMapsTheCommittedAvatarCandidate() async throws {
        let dataRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 {
            repositoryRoot.deleteLastPathComponent()
        }
        let package = repositoryRoot
            .appendingPathComponent("testdata/packages/with-avatar.charx")
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))

        let selection = CoreClientFactory.make(dataRoot: dataRoot)
        let inspection = try await selection.client.inspectImport(stagedURL: package)
        let image = try XCTUnwrap(inspection.representativeImage)
        XCTAssertEqual(image.logicalAssetID, "assets/avatar.png")
        XCTAssertEqual(image.mediaType, "image/png")
        XCTAssertEqual(image.sizeBytes, 70)
        XCTAssertTrue(inspection.unsupportedOptionalFields.isEmpty)

        let character = try await selection.client.commitImport(
            inspectionID: inspection.id
        )
        XCTAssertNotNil(character.avatarAssetHash)
    }

    func testGeneratedBindingContractRoundTripsLargeUnicodeNullEnumsEmptyListsAndErrors()
        async throws
    {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dataRoot = base.appendingPathComponent("data", isDirectory: true)
        let source = base.appendingPathComponent("바인딩-계약.json")
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
        let name = "세구 😀 e\u{301}"
        let description = String(repeating: "큰문자열😀", count: 8_192)
        let card: [String: Any] = [
            "spec": "chara_card_v3",
            "data": [
                "name": name,
                "description": description,
                "personality": "Unused fallback",
                "creator": "Synthetic",
            ],
        ]
        try JSONSerialization.data(withJSONObject: card).write(to: source)
        defer { try? FileManager.default.removeItem(at: base) }

        let selection = CoreClientFactory.make(dataRoot: dataRoot)
        XCTAssertEqual(selection.mode, .live)
        let versions = try await selection.client.apiVersions()
        let version = try await selection.client.version()
        let characters = try await selection.client.listCharacters()
        let conversations = try await selection.client.listConversations()
        let profiles = try await selection.client.listProviderProfiles()
        let settings = try await selection.client.getSettings()
        let events = try await selection.client.pollEvents(maxEvents: 8)
        XCTAssertEqual(version, versions.coreVersion)
        XCTAssertEqual(versions.coreAPIVersion, 4)
        XCTAssertEqual(versions.bindingAPIVersion, 4)
        XCTAssertEqual(versions.chatEventVersion, 2)
        XCTAssertTrue(characters.isEmpty)
        XCTAssertTrue(conversations.isEmpty)
        XCTAssertTrue(profiles.isEmpty)
        XCTAssertNil(settings.selectedProviderProfileID)
        XCTAssertTrue(events.events.isEmpty)

        let inspection = try await selection.client.inspectImport(stagedURL: source)
        XCTAssertEqual(inspection.contentKind, "character_card_v3")
        XCTAssertEqual(inspection.displayName, name)
        XCTAssertEqual(inspection.description, description)
        XCTAssertTrue(inspection.warnings.isEmpty)
        XCTAssertTrue(inspection.blockedReasons.isEmpty)
        XCTAssertNil(inspection.representativeImage)
        XCTAssertEqual(
            inspection.unsupportedOptionalFields,
            ["creator", "personality"]
        )
        let character = try await selection.client.commitImport(
            inspectionID: inspection.id
        )
        XCTAssertEqual(character.name, name)
        XCTAssertEqual(character.description, description)
        XCTAssertNil(character.avatarAssetHash)
        let conversation = try await selection.client.openConversation(
            characterID: character.id
        )
        XCTAssertEqual(conversation.title, name)
        let messages = try await selection.client.listMessages(
            conversationID: conversation.id
        )
        XCTAssertTrue(messages.isEmpty)

        do {
            _ = try await selection.client.getCharacter(id: "없는-캐릭터")
            XCTFail("Missing character unexpectedly resolved")
        } catch let FfiError.Core(code, _, recoverable, operationID) {
            XCTAssertEqual(code, "not_found")
            XCTAssertFalse(recoverable)
            XCTAssertFalse(operationID.isEmpty)
        }

        do {
            try await selection.client.cancelGeneration(generationID: "없는-생성")
            XCTFail("Missing generation unexpectedly cancelled")
        } catch let FfiError.Core(code, _, _, operationID) {
            XCTAssertEqual(code, "not_found")
            XCTAssertFalse(operationID.isEmpty)
        }
    }

    func testGeneratedLiveEventsRemainOrderedAndCancellationIsTerminal() async throws {
        let server = try StallingSSEServer()
        defer { server.stop() }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dataRoot = base.appendingPathComponent("data", isDirectory: true)
        let source = base.appendingPathComponent("event-contract.json")
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
        try Data(
            #"{"spec":"chara_card_v3","data":{"name":"Event test","description":"Synthetic"}}"#
                .utf8
        ).write(to: source)
        defer { try? FileManager.default.removeItem(at: base) }

        let selection = CoreClientFactory.make(dataRoot: dataRoot)
        XCTAssertEqual(selection.mode, .live)
        let inspection = try await selection.client.inspectImport(stagedURL: source)
        let character = try await selection.client.commitImport(
            inspectionID: inspection.id
        )
        let conversation = try await selection.client.openConversation(
            characterID: character.id
        )
        let profile = try await selection.client.upsertProviderProfile(
            ProviderProfile(
                id: "swift-cancellation",
                displayName: "Swift cancellation",
                baseURL: server.baseURL,
                model: "synthetic",
                timeoutSeconds: 5
            )
        )
        let generationID = try await selection.client.sendMessage(
            conversationID: conversation.id,
            text: "중지해",
            providerProfileID: profile.id,
            credential: nil
        )
        XCTAssertTrue(server.waitUntilStreaming())

        let deadline = Date().addingTimeInterval(5)
        var events: [ChatEvent] = []
        while !events.contains(where: { $0.kind == "text_delta" }) {
            events += try await selection.client.pollEvents(maxEvents: 64).events
                .filter { $0.generationID == generationID }
            if Date() >= deadline {
                XCTFail("text delta did not arrive")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        try await selection.client.cancelGeneration(generationID: generationID)
        while !events.contains(where: { $0.kind == "generation_cancelled" }) {
            events += try await selection.client.pollEvents(maxEvents: 64).events
                .filter { $0.generationID == generationID }
            if Date() >= deadline {
                XCTFail("cancellation did not arrive")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(events.first?.kind, "generation_started")
        XCTAssertEqual(
            events.first(where: { $0.kind == "text_delta" })?.text,
            "부분😀"
        )
        XCTAssertEqual(events.last?.kind, "generation_cancelled")
        XCTAssertTrue(
            zip(events, events.dropFirst()).allSatisfy { pair in
                pair.0.sequence < pair.1.sequence
            }
        )
        let messages = try await selection.client.listMessages(
            conversationID: conversation.id
        )
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].parentID, nil)
        XCTAssertEqual(messages[0].generationID, nil)
        XCTAssertEqual(messages[1].role, .assistant)
        XCTAssertEqual(messages[1].text, "부분😀")
        XCTAssertEqual(messages[1].status, .cancelled)
    }
    #endif
}

#if LOREPIA_UNIFFI_GENERATED && canImport(Darwin)
private enum SSEServerFailure: Error {
    case operation(String)
}

private final class StallingSSEServer: @unchecked Sendable {
    private let listener: Int32
    private let streaming = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let group = DispatchGroup()
    private let stopLock = NSLock()
    private var isStopped = false

    let baseURL: String

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw SSEServerFailure.operation("socket")
        }

        var reuse: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            Darwin.close(descriptor)
            throw SSEServerFailure.operation("setsockopt")
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw SSEServerFailure.operation("bind/listen")
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let addressResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &boundLength)
            }
        }
        guard addressResult == 0 else {
            Darwin.close(descriptor)
            throw SSEServerFailure.operation("getsockname")
        }

        listener = descriptor
        baseURL = "http://127.0.0.1:\(UInt16(bigEndian: boundAddress.sin_port))/v1"
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { group.leave() }
            serve()
        }
    }

    func waitUntilStreaming() -> Bool {
        streaming.wait(timeout: .now() + 5) == .success
    }

    func stop() {
        stopLock.lock()
        if isStopped {
            stopLock.unlock()
            return
        }
        isStopped = true
        stopLock.unlock()

        release.signal()
        _ = Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        _ = group.wait(timeout: .now() + 5)
    }

    private func serve() {
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else {
            streaming.signal()
            return
        }
        defer { Darwin.close(client) }
        readRequest(from: client)

        let event = "data: {\"choices\":[{\"delta\":{\"content\":\"부분😀\"}}]}\n\n"
        let eventBytes = Array(event.utf8)
        let headers = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/event-stream\r\n"
            + "Transfer-Encoding: chunked\r\n"
            + "Connection: close\r\n\r\n"
            + "\(String(eventBytes.count, radix: 16))\r\n"
        writeAll(Array(headers.utf8), to: client)
        writeAll(eventBytes, to: client)
        writeAll(Array("\r\n".utf8), to: client)
        streaming.signal()
        _ = release.wait(timeout: .now() + 5)
        writeAll(Array("0\r\n\r\n".utf8), to: client)
    }

    private func readRequest(from descriptor: Int32) {
        var request: [UInt8] = []
        var expectedSize: Int?
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while expectedSize == nil || request.count < (expectedSize ?? 0) {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count > 0 else {
                return
            }
            request.append(contentsOf: buffer.prefix(count))
            guard expectedSize == nil else {
                continue
            }
            let text = String(decoding: request, as: UTF8.self)
            guard let headerRange = text.range(of: "\r\n\r\n") else {
                continue
            }
            let headers = text[..<headerRange.lowerBound]
            let contentLength = String(headers)
                .components(separatedBy: "\r\n")
                .first {
                    $0.lowercased().hasPrefix("content-length:")
                }
                .flatMap {
                    Int($0.split(separator: ":", maxSplits: 1)[1]
                        .trimmingCharacters(in: .whitespaces))
                } ?? 0
            expectedSize = headers.utf8.count + 4 + contentLength
        }
    }

    private func writeAll(_ bytes: [UInt8], to descriptor: Int32) {
        bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                guard count > 0 else {
                    return
                }
                written += count
            }
        }
    }
}
#endif
