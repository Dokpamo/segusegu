import Foundation
import XCTest
@testable import LorepiaKit

@MainActor
final class FeatureViewModelTests: XCTestCase {
    func testLibraryFilteringMatchesSummary() {
        let viewModel = LibraryViewModel(
            characters: LibraryCharacter.previewCharacters
        )

        viewModel.query = "합성 자료"

        XCTAssertEqual(
            viewModel.filteredCharacters.map(\.id),
            ["preview-cartographer"]
        )
    }

    func testImportInspectionCommitRefreshesLibrary() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.json")
        try Data(#"{"synthetic":true}"#.utf8).write(to: source)

        let client = FakeCoreClient(characters: [])
        let library = LibraryViewModel(client: client)
        let viewModel = ImportReviewViewModel(
            client: client,
            stager: ImportFileStager(
                directory: root.appendingPathComponent("native-staging")
            ),
            libraryViewModel: library
        )

        await viewModel.inspect(sourceURL: source)
        guard case let .review(inspection) = viewModel.state else {
            return XCTFail("Expected a review state")
        }
        XCTAssertTrue(inspection.isAllowed)
        XCTAssertNil(inspection.representativeImage)
        XCTAssertTrue(inspection.unsupportedOptionalFields.isEmpty)

        await viewModel.commit()

        guard case let .completed(character) = viewModel.state else {
            return XCTFail("Expected a completed import")
        }
        XCTAssertFalse(character.name.isEmpty)
        XCTAssertEqual(library.characters.map(\.id), [character.id])
    }

    func testImportCommitFailureRetainsInspectionForRetry() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("retry.json")
        try Data(#"{"synthetic":true}"#.utf8).write(to: source)

        let client = FakeCoreClient(
            characters: [],
            commitFailuresBeforeSuccess: 1
        )
        let library = LibraryViewModel(client: client)
        let viewModel = ImportReviewViewModel(
            client: client,
            stager: ImportFileStager(
                directory: root.appendingPathComponent("native-staging")
            ),
            libraryViewModel: library
        )

        await viewModel.inspect(sourceURL: source)
        guard case let .review(initialInspection) = viewModel.state else {
            return XCTFail("Expected a review state")
        }

        await viewModel.commit()

        guard case let .commitFailed(retainedInspection, message) = viewModel.state else {
            return XCTFail("Expected a retriable commit failure")
        }
        XCTAssertEqual(retainedInspection, initialInspection)
        XCTAssertFalse(message.isEmpty)
        let failedStats = try await client.databaseStats()
        XCTAssertEqual(failedStats.pendingImports, 1)

        await viewModel.commit()

        guard case .completed = viewModel.state else {
            return XCTFail("Expected retry to commit the retained inspection")
        }
        let completedStats = try await client.databaseStats()
        XCTAssertEqual(completedStats.pendingImports, 0)
        XCTAssertEqual(library.characters.count, 1)
    }

    func testImportCommitFailureCanDiscardRetainedInspection() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("discard.json")
        try Data(#"{"synthetic":true}"#.utf8).write(to: source)

        let client = FakeCoreClient(
            characters: [],
            commitFailuresBeforeSuccess: 1
        )
        let viewModel = ImportReviewViewModel(
            client: client,
            stager: ImportFileStager(
                directory: root.appendingPathComponent("native-staging")
            ),
            libraryViewModel: LibraryViewModel(client: client)
        )

        await viewModel.inspect(sourceURL: source)
        await viewModel.commit()
        guard case .commitFailed = viewModel.state else {
            return XCTFail("Expected a retriable commit failure")
        }

        await viewModel.discardPending()

        XCTAssertEqual(viewModel.state, .empty)
        let discardedStats = try await client.databaseStats()
        XCTAssertEqual(discardedStats.pendingImports, 0)
    }

    func testStagerRejectsOversizeAndCleansPartialFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("native-staging")
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )
        let abandoned = staging.appendingPathComponent("old.partial")
        try Data("old".utf8).write(to: abandoned)
        let source = root.appendingPathComponent("oversize.charx")
        try Data(repeating: 1, count: 9).write(to: source)

        let stager = ImportFileStager(directory: staging, maximumBytes: 8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))

        do {
            _ = try await stager.stage(source)
            XCTFail("Expected the bounded stager to reject the file")
        } catch let error as ImportStagingError {
            XCTAssertEqual(error, .sourceTooLarge(maxBytes: 8))
        }
        let remaining = try FileManager.default.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(remaining.isEmpty)
    }

    func testStagerRejectsSymbolicLinks() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.json")
        let link = root.appendingPathComponent("linked.json")
        try Data("{}".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: source
        )
        let stager = ImportFileStager(
            directory: root.appendingPathComponent("native-staging")
        )

        do {
            _ = try await stager.stage(link)
            XCTFail("Expected a symlink to be rejected")
        } catch let error as ImportStagingError {
            XCTAssertEqual(error, .sourceIsNotRegularFile)
        }
    }

    func testStagerCancellationRemovesPartialFile() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("cancelled.charx")
        let staging = root.appendingPathComponent("native-staging")
        try Data(repeating: 7, count: 8 * 1024 * 1024).write(to: source)
        let stager = ImportFileStager(
            directory: staging,
            maximumBytes: 16 * 1024 * 1024,
            readChunkSize: 1_024
        )
        let copyTask = Task {
            try await stager.stage(source)
        }

        var observedPartial = false
        for _ in 0 ..< 2_000 {
            let contents = (
                try? FileManager.default.contentsOfDirectory(
                    at: staging,
                    includingPropertiesForKeys: nil
                )
            ) ?? []
            if contents.contains(where: { $0.pathExtension == "partial" }) {
                observedPartial = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(observedPartial, "Expected the streaming copy to begin")

        copyTask.cancel()
        do {
            _ = try await copyTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let remaining = try FileManager.default.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(remaining.isEmpty)
    }

    func testChatRestoresConversationMessagesAfterViewModelRestart() async {
        let client = FakeCoreClient()
        let credentials = InMemoryCredentialStore(
            values: ["preview-provider": "synthetic-test-secret"]
        )
        let character = LibraryCharacter.previewCharacters[0]
        let first = ChatViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )

        await first.setCharacter(character)
        first.draft = "안녕"
        XCTAssertTrue(first.canSubmit)
        await first.submitMessage()
        await first.pollOnce()

        XCTAssertEqual(first.messages.map(\.role), [.user, .assistant])
        XCTAssertFalse(first.isGenerating)

        let restored = ChatViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )
        await restored.setCharacter(character)

        XCTAssertEqual(restored.conversation?.id, first.conversation?.id)
        XCTAssertEqual(restored.messages, first.messages)
    }

    func testChatFiltersWrongGenerationDuplicateSequenceAndUnknownEventVersion() async {
        let client = FakeCoreClient()
        let viewModel = ChatViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )
        await viewModel.setCharacter(LibraryCharacter.previewCharacters[0])
        guard let conversationID = viewModel.conversation?.id else {
            return XCTFail("Expected a conversation")
        }
        let generationID = "synthetic-generation"
        let assistantID = "synthetic-assistant"
        await client.replaceMessagesForTesting(
            conversationID: conversationID,
            messages: [
                ChatMessage(
                    id: assistantID,
                    conversationID: conversationID,
                    role: .assistant,
                    text: "AC",
                    status: .pending,
                    generationID: generationID
                ),
            ]
        )
        await client.enqueueEventBatch(
            [
                ChatEvent(
                    eventVersion: 2,
                    generationID: generationID,
                    conversationID: conversationID,
                    sequence: 1,
                    kind: "text_delta",
                    text: "UNSUPPORTED"
                ),
                ChatEvent(
                    generationID: generationID,
                    conversationID: conversationID,
                    sequence: 1,
                    kind: "generation_started"
                ),
                ChatEvent(
                    generationID: generationID,
                    conversationID: conversationID,
                    sequence: 2,
                    kind: "text_delta",
                    text: "A"
                ),
                ChatEvent(
                    generationID: generationID,
                    conversationID: conversationID,
                    sequence: 2,
                    kind: "text_delta",
                    text: "DUPLICATE"
                ),
                ChatEvent(
                    generationID: "wrong-generation",
                    conversationID: conversationID,
                    sequence: 3,
                    kind: "text_delta",
                    text: "WRONG"
                ),
                ChatEvent(
                    generationID: generationID,
                    conversationID: conversationID,
                    sequence: 3,
                    kind: "text_delta",
                    text: "C"
                ),
            ],
            droppedEventCount: 4
        )

        await viewModel.pollOnce()

        XCTAssertEqual(viewModel.messages.last?.text, "AC")
        XCTAssertFalse(
            viewModel.messages.contains {
                $0.text.contains("UNSUPPORTED")
                    || $0.text.contains("DUPLICATE")
                    || $0.text.contains("WRONG")
            }
        )
    }

    func testChatDroppedInterleavedEventsReconcileToPersistedTerminalState() async throws {
        let client = FakeCoreClient()
        let character = LibraryCharacter.previewCharacters[0]
        let conversation = try await client.openConversation(
            characterID: character.id
        )
        let generationID = "active-generation"
        let assistantID = "active-assistant"
        let pending = ChatMessage(
            id: assistantID,
            conversationID: conversation.id,
            role: .assistant,
            text: "",
            status: .pending,
            generationID: generationID
        )
        await client.replaceMessagesForTesting(
            conversationID: conversation.id,
            messages: [pending]
        )
        let viewModel = ChatViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )
        await viewModel.setCharacter(character)
        XCTAssertTrue(viewModel.isGenerating)

        var committed = pending
        committed.text = "persisted final"
        committed.status = .complete
        await client.replaceMessagesForTesting(
            conversationID: conversation.id,
            messages: [committed]
        )
        await client.enqueueEventBatch(
            [
                ChatEvent(
                    generationID: "other-generation",
                    conversationID: conversation.id,
                    sequence: 1,
                    kind: "text_delta",
                    text: "wrong"
                ),
                ChatEvent(
                    generationID: generationID,
                    conversationID: conversation.id,
                    sequence: 2,
                    kind: "text_delta",
                    text: "transient"
                ),
            ],
            droppedEventCount: 3
        )

        await viewModel.pollOnce()

        XCTAssertEqual(viewModel.messages, [committed])
        XCTAssertFalse(viewModel.isGenerating)
        XCTAssertFalse(viewModel.messages[0].text.contains("transient"))
        XCTAssertFalse(viewModel.messages[0].text.contains("wrong"))
    }

    func testChatEmptyPollsTerminateStalePersistedGeneration() async throws {
        let client = FakeCoreClient()
        let character = LibraryCharacter.previewCharacters[0]
        let conversation = try await client.openConversation(
            characterID: character.id
        )
        let generationID = "stale-generation"
        var assistant = ChatMessage(
            id: "stale-assistant",
            conversationID: conversation.id,
            role: .assistant,
            text: "partial",
            status: .pending,
            generationID: generationID
        )
        await client.replaceMessagesForTesting(
            conversationID: conversation.id,
            messages: [assistant]
        )
        let viewModel = ChatViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )
        await viewModel.setCharacter(character)
        XCTAssertTrue(viewModel.isGenerating)

        assistant.text = "recovered terminal"
        assistant.status = .failed
        await client.replaceMessagesForTesting(
            conversationID: conversation.id,
            messages: [assistant]
        )
        for _ in 0 ..< 10 {
            await viewModel.pollOnce()
        }

        XCTAssertEqual(viewModel.messages, [assistant])
        XCTAssertFalse(viewModel.isGenerating)
    }

    func testChatResumeImmediatelyReconcilesPersistedStatus() async throws {
        let client = FakeCoreClient()
        let character = LibraryCharacter.previewCharacters[0]
        let conversation = try await client.openConversation(
            characterID: character.id
        )
        var assistant = ChatMessage(
            id: "resume-assistant",
            conversationID: conversation.id,
            role: .assistant,
            text: "",
            status: .pending,
            generationID: "resume-generation"
        )
        await client.replaceMessagesForTesting(
            conversationID: conversation.id,
            messages: [assistant]
        )
        let viewModel = ChatViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )
        await viewModel.setCharacter(character)
        XCTAssertTrue(viewModel.isGenerating)

        assistant.text = "completed while paused"
        assistant.status = .complete
        await client.replaceMessagesForTesting(
            conversationID: conversation.id,
            messages: [assistant]
        )

        await viewModel.resumeEventPolling()

        XCTAssertEqual(viewModel.messages, [assistant])
        XCTAssertFalse(viewModel.isGenerating)
    }

    func testSettingsStoresCredentialOutsideProviderProfile() async throws {
        let client = FakeCoreClient(profiles: [])
        let credentials = InMemoryCredentialStore()
        let viewModel = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview
        )
        viewModel.beginNewProfile()
        viewModel.profileName = "Local Test"
        viewModel.baseURL = "https://example.invalid/v1"
        viewModel.model = "synthetic"
        viewModel.timeoutSeconds = "15"
        viewModel.credentialDraft = "secret-value"

        await viewModel.saveProfile()

        guard let profile = viewModel.profiles.first else {
            return XCTFail("Expected a saved profile")
        }
        let storedCredential = try await credentials.credential(for: profile.id)
        XCTAssertEqual(storedCredential, "secret-value")
        XCTAssertFalse(String(describing: profile).contains("secret-value"))
    }

    func testEnvironmentCoordinatesSelectedCharacter() async {
        let client = FakeCoreClient()
        let environment = AppEnvironment(
            coreClient: client,
            runtimeMode: .preview,
            credentialStore: InMemoryCredentialStore(),
            characters: LibraryCharacter.previewCharacters
        )
        let character = LibraryCharacter.previewCharacters[1]

        await environment.selectCharacter(character)

        XCTAssertEqual(environment.sharedState.selectedCharacter, character)
        XCTAssertEqual(environment.chatViewModel.character, character)
        XCTAssertNotNil(environment.chatViewModel.conversation)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}
