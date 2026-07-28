import Foundation
@preconcurrency import Security
import XCTest
@testable import LorepiaKit

@MainActor
final class FeatureViewModelTests: XCTestCase {
    private func providerSelectionFixtures() -> [ProviderProfile] {
        [
            ProviderProfile(
                id: "compact",
                displayName: "Compact",
                baseURL: "https://example.invalid/v1",
                model: "lore-compact",
                timeoutSeconds: 30
            ),
            ProviderProfile(
                id: "pro",
                displayName: "Pro",
                baseURL: "https://example.invalid/v1",
                model: "lore-pro",
                timeoutSeconds: 60
            ),
        ]
    }

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

    func testChatModeSelectionPersistsAcrossViewModelRecreation() async throws {
        let client = FakeCoreClient()
        let character = LibraryCharacter.previewCharacters[0]
        let conversation = try await client.createConversation(
            characterID: character.id,
            title: "모드 영속화 방",
            mode: .chat
        )
        let first = ChatViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )

        await first.setConversation(conversation, character: character)
        XCTAssertEqual(first.mode, .chat)

        await first.setMode(.story)

        XCTAssertEqual(first.mode, .story)
        let persisted = try await client.getConversationState(
            conversationID: conversation.id
        )
        XCTAssertEqual(persisted.selectedMode, .story)

        let restored = ChatViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )
        await restored.setConversation(conversation, character: character)

        XCTAssertEqual(restored.mode, .story)
        XCTAssertEqual(restored.activeBranchID, persisted.activeBranchID)
    }

    func testChatRefreshesAndChangesTheSelectedProviderModel() async throws {
        let profiles = [
            ProviderProfile(
                id: "compact",
                displayName: "Compact",
                baseURL: "https://example.invalid/v1",
                model: "lore-compact",
                timeoutSeconds: 30
            ),
            ProviderProfile(
                id: "pro",
                displayName: "Pro",
                baseURL: "https://example.invalid/v1",
                model: "lore-pro",
                timeoutSeconds: 60
            ),
        ]
        let client = FakeCoreClient(profiles: profiles)
        let viewModel = ChatViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )

        await viewModel.setCharacter(
            LibraryCharacter.previewCharacters[0]
        )
        await viewModel.refreshProviderSelection()

        XCTAssertEqual(viewModel.providerProfiles, profiles)
        XCTAssertEqual(viewModel.selectedProviderProfile?.model, "lore-compact")
        XCTAssertTrue(viewModel.canChangeProviderProfile)

        await viewModel.selectProviderProfile(id: "pro")

        XCTAssertEqual(viewModel.selectedProviderProfile?.model, "lore-pro")
        let settings = try await client.getSettings()
        XCTAssertEqual(settings.selectedProviderProfileID, "pro")
        XCTAssertTrue(settings.preservePartialGenerations)
    }

    func testChatDiscardsAStaleProviderRefreshAfterASelection() async throws {
        let profiles = providerSelectionFixtures()
        let client = FakeCoreClient(
            profiles: profiles,
            listProviderProfilesDelay: .milliseconds(80)
        )
        let viewModel = ChatViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )

        await viewModel.setCharacter(
            LibraryCharacter.previewCharacters[0]
        )
        await viewModel.refreshProviderSelection()

        let staleRefresh = Task {
            await viewModel.refreshProviderSelection()
        }
        try await Task.sleep(for: .milliseconds(20))
        await viewModel.selectProviderProfile(id: "pro")
        await staleRefresh.value

        XCTAssertEqual(viewModel.selectedProviderProfileID, "pro")
        let settings = try await client.getSettings()
        XCTAssertEqual(settings.selectedProviderProfileID, "pro")
    }

    func testChatDiscardsCapturedProviderRefreshAfterSettingsDeletesProfile() async throws {
        let profile = providerSelectionFixtures()[0]
        let client = FakeCoreClient(profiles: [profile])
        let credentials = InMemoryCredentialStore(
            values: [profile.id: "synthetic-stale-refresh-key"]
        )
        let store = ProviderConfigurationStore()
        let settings = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        await settings.refresh()

        let chat = ChatViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store,
            automaticallyPollEvents: false
        )
        await chat.setCharacter(LibraryCharacter.previewCharacters[0])
        chat.setProviderStoreAutoRefreshEnabledForTesting(false)
        let exactDraft = "  stale refresh 삭제 경쟁 원문  "
        chat.draft = exactDraft
        XCTAssertEqual(chat.providerProfiles, [profile])
        XCTAssertEqual(chat.selectedProviderProfileID, profile.id)

        await client.gateNextProviderReadSnapshotsForTesting()
        let staleRefresh = Task {
            await chat.refreshProviderSelection()
        }
        await waitUntil {
            await client.providerReadSnapshotCaptureCountForTesting()
                == 2
        }
        let capturedReads =
            await client.providerReadSnapshotCaptureCountForTesting()
        XCTAssertEqual(capturedReads, 2)

        await settings.deleteEditingProfile()
        await waitUntil(timeout: .seconds(3)) {
            store.profiles.isEmpty
                && store.selectedProfileID == nil
                && chat.providerProfiles.isEmpty
                && chat.selectedProviderProfileID == nil
        }
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNil(store.selectedProfileID)
        XCTAssertTrue(chat.providerProfiles.isEmpty)
        XCTAssertNil(chat.selectedProviderProfileID)
        let readsBeforeStaleRelease =
            await client.providerReadInvocationCountsForTesting()

        await client.releaseProviderReadSnapshotsForTesting()
        await staleRefresh.value
        await waitUntil(timeout: .seconds(3)) {
            let reads =
                await client.providerReadInvocationCountsForTesting()
            return reads.profiles > readsBeforeStaleRelease.profiles
                && reads.settings > readsBeforeStaleRelease.settings
                && chat.hasLoadedProviderConfiguration
                && chat.providerProfiles.isEmpty
                && chat.selectedProviderProfileID == nil
        }

        let readsAfterStaleRelease =
            await client.providerReadInvocationCountsForTesting()
        let coreProfiles = try await client.listProviderProfiles()
        let coreSettings = try await client.getSettings()
        let updateCount =
            await client.updateSettingsInvocationCountForTesting()
        let deleteCount =
            await client.providerDeleteInvocationCountForTesting()
        XCTAssertTrue(coreProfiles.isEmpty)
        XCTAssertNil(coreSettings.selectedProviderProfileID)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNil(store.selectedProfileID)
        XCTAssertTrue(chat.providerProfiles.isEmpty)
        XCTAssertNil(chat.selectedProviderProfileID)
        XCTAssertFalse(chat.canSubmit)
        XCTAssertEqual(updateCount, 1)
        XCTAssertEqual(deleteCount, 1)
        XCTAssertGreaterThan(
            readsAfterStaleRelease.profiles,
            readsBeforeStaleRelease.profiles
        )
        XCTAssertGreaterThan(
            readsAfterStaleRelease.settings,
            readsBeforeStaleRelease.settings
        )

        await chat.submitMessage()

        let requests = await client.providerSendRequestsForTesting()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(chat.draft, exactDraft)
    }

    func testSharedProviderStateStaysDeletedAfterQueuedRefreshesSettle() async throws {
        let profile = providerSelectionFixtures()[0]
        let client = FakeCoreClient(profiles: [profile])
        let credentials = InMemoryCredentialStore(
            values: [profile.id: "synthetic-normal-delete-key"]
        )
        let store = ProviderConfigurationStore()
        let settings = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        let chat = ChatViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store,
            automaticallyPollEvents: false
        )
        await chat.setCharacter(LibraryCharacter.previewCharacters[0])

        await settings.refresh()
        await chat.refreshProviderSelection()

        XCTAssertEqual(settings.profiles, [profile])
        XCTAssertEqual(settings.selectedProfileID, profile.id)
        XCTAssertEqual(chat.providerProfiles, [profile])
        XCTAssertEqual(chat.selectedProviderProfileID, profile.id)

        await settings.deleteEditingProfile()

        var lastRevision = store.revision
        var lastReads =
            await client.providerReadInvocationCountsForTesting()
        var stableSamples = 0
        for _ in 0 ..< 400 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
            let nextRevision = store.revision
            let nextReads =
                await client.providerReadInvocationCountsForTesting()
            let isIdle =
                !settings.isLoading
                    && !chat.isLoading
                    && store.mutatingProfileIDs.isEmpty
            if isIdle,
               nextRevision == lastRevision,
               nextReads == lastReads
            {
                stableSamples += 1
                if stableSamples >= 20 {
                    break
                }
            } else {
                stableSamples = 0
            }
            lastRevision = nextRevision
            lastReads = nextReads
        }

        let settledReads =
            await client.providerReadInvocationCountsForTesting()
        let coreProfiles = try await client.listProviderProfiles()
        let coreSettings = try await client.getSettings()
        let finalReads =
            await client.providerReadInvocationCountsForTesting()
        let upsertCount =
            await client.providerUpsertInvocationCountForTesting()
        let deleteCount =
            await client.providerDeleteInvocationCountForTesting()
        let updateCount =
            await client.updateSettingsInvocationCountForTesting()
        let snapshot = """
        core profiles=\(coreProfiles.map(\.id)) selected=\(String(describing: coreSettings.selectedProviderProfileID))
        store profiles=\(store.profiles.map(\.id)) selected=\(String(describing: store.selectedProfileID)) quarantined=\(store.quarantinedProfileIDs.sorted()) mutating=\(store.mutatingProfileIDs.sorted()) revision=\(store.revision)
        settings profiles=\(settings.profiles.map(\.id)) selected=\(String(describing: settings.selectedProfileID)) loading=\(settings.isLoading)
        chat profiles=\(chat.providerProfiles.map(\.id)) selected=\(String(describing: chat.selectedProviderProfileID)) loading=\(chat.isLoading)
        reads settled=\(settledReads) final=\(finalReads) upserts=\(upsertCount) deletes=\(deleteCount) updates=\(updateCount) stableSamples=\(stableSamples)
        """

        XCTAssertGreaterThanOrEqual(stableSamples, 20, snapshot)
        XCTAssertTrue(coreProfiles.isEmpty, snapshot)
        XCTAssertNil(coreSettings.selectedProviderProfileID, snapshot)
        XCTAssertTrue(store.profiles.isEmpty, snapshot)
        XCTAssertNil(store.selectedProfileID, snapshot)
        XCTAssertTrue(store.mutatingProfileIDs.isEmpty, snapshot)
        XCTAssertTrue(settings.profiles.isEmpty, snapshot)
        XCTAssertNil(settings.selectedProfileID, snapshot)
        XCTAssertTrue(chat.providerProfiles.isEmpty, snapshot)
        XCTAssertNil(chat.selectedProviderProfileID, snapshot)
        XCTAssertEqual(upsertCount, 0, snapshot)
        XCTAssertEqual(deleteCount, 1, snapshot)
        XCTAssertEqual(updateCount, 1, snapshot)
    }

    func testSettingsDeletionRemainsEmptyWithLiveChatStoreObservation() async throws {
        let profile = providerSelectionFixtures()[0]
        let client = FakeCoreClient(profiles: [profile])
        let credentials = InMemoryCredentialStore(
            values: [profile.id: "synthetic-live-observer-key"]
        )
        let store = ProviderConfigurationStore()
        let chat = ChatViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store,
            automaticallyPollEvents: false
        )
        let settings = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        await settings.refresh()
        XCTAssertEqual(chat.providerProfiles, [profile])

        await settings.deleteEditingProfile()
        try await Task.sleep(for: .seconds(1))

        let coreProfiles = try await client.listProviderProfiles()
        let coreSettings = try await client.getSettings()
        XCTAssertTrue(coreProfiles.isEmpty)
        XCTAssertNil(coreSettings.selectedProviderProfileID)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNil(store.selectedProfileID)
        XCTAssertTrue(settings.profiles.isEmpty)
        XCTAssertNil(settings.selectedProfileID)
        XCTAssertTrue(chat.providerProfiles.isEmpty)
        XCTAssertNil(chat.selectedProviderProfileID)
    }

    func testEnvironmentDeletionRemainsEmptyAfterStartup() async throws {
        let profile = providerSelectionFixtures()[0]
        let client = FakeCoreClient(profiles: [profile])
        let credentials = InMemoryCredentialStore(
            values: [profile.id: "synthetic-environment-key"]
        )
        let environment = AppEnvironment(
            coreClient: client,
            runtimeMode: .preview,
            credentialStore: credentials,
            characters: LibraryCharacter.previewCharacters
        )
        await environment.start()

        await environment.settingsViewModel.deleteEditingProfile()
        try await Task.sleep(for: .seconds(1))

        let coreProfiles = try await client.listProviderProfiles()
        let coreSettings = try await client.getSettings()
        XCTAssertTrue(coreProfiles.isEmpty)
        XCTAssertNil(coreSettings.selectedProviderProfileID)
        XCTAssertTrue(environment.providerConfigurationStore.profiles.isEmpty)
        XCTAssertNil(
            environment.providerConfigurationStore.selectedProfileID
        )
        XCTAssertTrue(environment.settingsViewModel.profiles.isEmpty)
        XCTAssertNil(environment.settingsViewModel.selectedProfileID)
        XCTAssertTrue(environment.chatViewModel.providerProfiles.isEmpty)
        XCTAssertNil(environment.chatViewModel.selectedProviderProfileID)
    }

    func testChatBlocksSubmitWhileProviderSelectionIsSaving() async throws {
        let client = FakeCoreClient(
            profiles: providerSelectionFixtures(),
            updateSettingsDelay: .milliseconds(80)
        )
        let viewModel = ChatViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )

        await viewModel.setCharacter(
            LibraryCharacter.previewCharacters[0]
        )
        await viewModel.refreshProviderSelection()
        viewModel.draft = "이전 모델로 보내면 안 되는 메시지"

        let selection = Task {
            await viewModel.selectProviderProfile(id: "pro")
        }
        for _ in 0 ..< 20 where !viewModel.isChangingProviderProfile {
            await Task.yield()
        }
        XCTAssertTrue(viewModel.isChangingProviderProfile)
        XCTAssertFalse(viewModel.canSubmit)

        await viewModel.submitMessage()

        XCTAssertEqual(
            viewModel.draft,
            "이전 모델로 보내면 안 되는 메시지"
        )
        XCTAssertFalse(viewModel.isGenerating)
        await selection.value
        XCTAssertEqual(viewModel.selectedProviderProfileID, "pro")
    }

    func testChatReportsAnInitialProviderRefreshFailure() async {
        let viewModel = ChatViewModel(
            client: UnavailableCoreClient(message: "offline"),
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .unavailable("offline"),
            automaticallyPollEvents: false
        )

        await viewModel.refreshProviderSelection()

        XCTAssertTrue(viewModel.providerProfiles.isEmpty)
        XCTAssertTrue(
            viewModel.errorMessage?.contains(
                "모델 목록을 불러오지 못했습니다"
            ) == true
        )
    }

    func testChatClearsItsProviderErrorAfterRefreshRecovers() async {
        let client = FakeCoreClient(
            profiles: providerSelectionFixtures(),
            listProviderFailuresBeforeSuccess: 1
        )
        let viewModel = ChatViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )

        await viewModel.refreshProviderSelection()
        XCTAssertNotNil(viewModel.errorMessage)

        await viewModel.refreshProviderSelection()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.selectedProviderProfileID, "compact")
    }

    func testChatSubmitIsNotCancelledByAReadOnlyProviderRefresh() async throws {
        let client = FakeCoreClient(
            profiles: providerSelectionFixtures(),
            listProviderProfilesDelay: .milliseconds(80)
        )
        let viewModel = ChatViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )

        await viewModel.setCharacter(
            LibraryCharacter.previewCharacters[0]
        )
        await viewModel.refreshProviderSelection()
        viewModel.draft = "조회 중에도 보내야 하는 메시지"

        let refresh = Task {
            await viewModel.refreshProviderSelection()
        }
        try await Task.sleep(for: .milliseconds(20))
        await viewModel.submitMessage()
        await refresh.value

        XCTAssertTrue(viewModel.draft.isEmpty)
        XCTAssertTrue(
            viewModel.messages.contains {
                $0.text == "조회 중에도 보내야 하는 메시지"
            }
        )
    }

    func testChatSerializesDoubleSubmitAndLocksItsModeSnapshot() async {
        let client = FakeCoreClient(
            profiles: providerSelectionFixtures(),
            getSettingsDelay: .milliseconds(80)
        )
        let viewModel = ChatViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )

        await viewModel.setCharacter(
            LibraryCharacter.previewCharacters[0]
        )
        await viewModel.refreshProviderSelection()
        viewModel.draft = "한 번만 보내야 하는 메시지"

        let firstSubmit = Task {
            await viewModel.submitMessage()
        }
        for _ in 0 ..< 20 where !viewModel.isSubmitting {
            await Task.yield()
        }
        XCTAssertTrue(viewModel.isSubmitting)
        XCTAssertFalse(viewModel.canEditDraft)

        async let secondSubmit: Void = viewModel.submitMessage()
        await viewModel.setMode(.story)
        _ = await (firstSubmit.value, secondSubmit)

        XCTAssertEqual(viewModel.mode, .chat)
        XCTAssertEqual(
            viewModel.messages.filter {
                $0.role == .user
                    && $0.text == "한 번만 보내야 하는 메시지"
            }.count,
            1
        )
    }

    func testChatSelectsIndependentRoomsForTheSameCharacter() async throws {
        let client = FakeCoreClient()
        let character = LibraryCharacter.previewCharacters[0]
        let firstRoom = try await client.createConversation(
            characterID: character.id,
            title: "첫 번째 방",
            mode: .chat
        )
        let secondRoom = try await client.createConversation(
            characterID: character.id,
            title: "두 번째 방",
            mode: .story
        )
        let firstMessage = ChatMessage(
            conversationID: firstRoom.id,
            role: .user,
            text: "첫 방의 합성 메시지"
        )
        let secondMessage = ChatMessage(
            conversationID: secondRoom.id,
            role: .user,
            text: "둘째 방의 합성 메시지"
        )
        await client.replaceMessagesForTesting(
            conversationID: firstRoom.id,
            messages: [firstMessage]
        )
        await client.replaceMessagesForTesting(
            conversationID: secondRoom.id,
            messages: [secondMessage]
        )
        let rooms = try await client.listConversations(
            characterID: character.id
        )
        XCTAssertEqual(Set(rooms.map(\.id)), [firstRoom.id, secondRoom.id])

        let viewModel = ChatViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )

        await viewModel.setConversation(firstRoom, character: character)
        XCTAssertEqual(viewModel.conversation?.id, firstRoom.id)
        XCTAssertEqual(viewModel.messages, [firstMessage])
        XCTAssertEqual(viewModel.mode, .chat)

        await viewModel.setConversation(secondRoom, character: character)
        XCTAssertEqual(viewModel.conversation?.id, secondRoom.id)
        XCTAssertEqual(viewModel.messages, [secondMessage])
        XCTAssertEqual(viewModel.mode, .story)
    }

    func testChatBranchMessagesRemainIsolatedAndRestoreWhenSwitching() async throws {
        let client = FakeCoreClient()
        let character = LibraryCharacter.previewCharacters[0]
        let conversation = try await client.createConversation(
            characterID: character.id,
            title: "분기 격리 방",
            mode: .chat
        )
        let viewModel = ChatViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )
        await viewModel.setConversation(conversation, character: character)
        let rootBranchID = try XCTUnwrap(viewModel.activeBranchID)

        viewModel.draft = "공통 시작"
        await viewModel.submitMessage()
        let forkMessageID = try XCTUnwrap(viewModel.messages.last?.id)

        await viewModel.createBranch(afterMessageID: forkMessageID)
        let siblingBranchID = try XCTUnwrap(viewModel.activeBranchID)
        XCTAssertNotEqual(siblingBranchID, rootBranchID)

        viewModel.draft = "분기에만 남는 메시지"
        await viewModel.submitMessage()
        XCTAssertEqual(
            viewModel.messages.filter { $0.role == .user }.map(\.text),
            ["공통 시작", "분기에만 남는 메시지"]
        )

        await viewModel.selectBranch(id: rootBranchID)
        XCTAssertEqual(viewModel.activeBranchID, rootBranchID)
        XCTAssertEqual(
            viewModel.messages.filter { $0.role == .user }.map(\.text),
            ["공통 시작"]
        )

        viewModel.draft = "기본 흐름에만 남는 메시지"
        await viewModel.submitMessage()
        XCTAssertEqual(
            viewModel.messages.filter { $0.role == .user }.map(\.text),
            ["공통 시작", "기본 흐름에만 남는 메시지"]
        )

        await viewModel.selectBranch(id: siblingBranchID)
        XCTAssertEqual(viewModel.activeBranchID, siblingBranchID)
        XCTAssertEqual(
            viewModel.messages.filter { $0.role == .user }.map(\.text),
            ["공통 시작", "분기에만 남는 메시지"]
        )

        await viewModel.selectBranch(id: rootBranchID)
        XCTAssertEqual(
            viewModel.messages.filter { $0.role == .user }.map(\.text),
            ["공통 시작", "기본 흐름에만 남는 메시지"]
        )
    }

    func testChatEditingUserMessageCreatesAndSelectsANewBranch() async throws {
        let client = FakeCoreClient()
        let character = LibraryCharacter.previewCharacters[0]
        let viewModel = ChatViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )
        await viewModel.setCharacter(character)
        viewModel.draft = "원래 질문"
        await viewModel.submitMessage()
        let originalBranchID = try XCTUnwrap(viewModel.activeBranchID)
        let userMessageID = try XCTUnwrap(
            viewModel.messages.first(where: { $0.role == .user })?.id
        )

        let edited = await viewModel.editUserMessage(
            messageID: userMessageID,
            replacementText: "수정한 질문"
        )

        XCTAssertTrue(edited)
        XCTAssertNotEqual(viewModel.activeBranchID, originalBranchID)
        XCTAssertEqual(
            viewModel.messages.map(\.role),
            [.user, .assistant]
        )
        XCTAssertEqual(viewModel.messages.first?.text, "수정한 질문")
        XCTAssertTrue(
            viewModel.messages.last?.text.contains("편집한 메시지") == true
        )
        XCTAssertEqual(viewModel.branches.count, 2)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testChatEditFailureKeepsARecoverableConfigurationMessage() async throws {
        let client = FakeCoreClient(profiles: [])
        let character = LibraryCharacter.previewCharacters[0]
        let viewModel = ChatViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )
        await viewModel.setCharacter(character)
        let conversationID = try XCTUnwrap(viewModel.conversation?.id)
        let user = ChatMessage(
            id: "editable-user",
            conversationID: conversationID,
            role: .user,
            text: "원래 질문",
            status: .complete
        )
        let assistant = ChatMessage(
            id: "editable-assistant",
            conversationID: conversationID,
            role: .assistant,
            text: "원래 응답",
            status: .complete,
            generationID: "editable-generation"
        )
        await client.replaceMessagesForTesting(
            conversationID: conversationID,
            messages: [user, assistant]
        )
        await viewModel.refreshMessages()

        let edited = await viewModel.editUserMessage(
            messageID: user.id,
            replacementText: "잃어버리면 안 되는 수정문"
        )

        XCTAssertFalse(edited)
        XCTAssertEqual(
            viewModel.errorMessage,
            "프로바이더 프로필이 없습니다. 프로바이더 설정에서 추가하세요."
        )
        XCTAssertEqual(viewModel.messages.first?.text, "원래 질문")
    }

    func testChatRegeneratingAssistantCreatesAndSelectsANewBranch() async throws {
        let client = FakeCoreClient()
        let character = LibraryCharacter.previewCharacters[0]
        let viewModel = ChatViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )
        await viewModel.setCharacter(character)
        viewModel.draft = "다시 답해줘"
        await viewModel.submitMessage()
        let originalBranchID = try XCTUnwrap(viewModel.activeBranchID)
        let originalAssistant = try XCTUnwrap(
            viewModel.messages.first(where: { $0.role == .assistant })
        )

        await viewModel.regenerateAssistantMessage(
            messageID: originalAssistant.id
        )

        XCTAssertNotEqual(viewModel.activeBranchID, originalBranchID)
        XCTAssertEqual(
            viewModel.messages.map(\.role),
            [.user, .assistant]
        )
        XCTAssertNotEqual(viewModel.messages.last?.id, originalAssistant.id)
        XCTAssertTrue(
            viewModel.messages.last?.text.contains("다시 생성한") == true
        )
        XCTAssertEqual(viewModel.branches.count, 2)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testChatRemovingMessageRewindsTheCurrentBranch() async throws {
        let client = FakeCoreClient()
        let character = LibraryCharacter.previewCharacters[0]
        let viewModel = ChatViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )
        await viewModel.setCharacter(character)
        viewModel.draft = "삭제 테스트"
        await viewModel.submitMessage()
        let branchID = try XCTUnwrap(viewModel.activeBranchID)
        let assistantID = try XCTUnwrap(
            viewModel.messages.last(where: { $0.role == .assistant })?.id
        )

        await viewModel.removeMessage(messageID: assistantID)

        XCTAssertEqual(viewModel.activeBranchID, branchID)
        XCTAssertEqual(viewModel.messages.map(\.role), [.user])
        XCTAssertEqual(viewModel.branches.count, 1)
        XCTAssertEqual(viewModel.branches.first?.headMessageID, viewModel.messages.last?.id)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testChatIgnoresV2EventsFromInactiveBranch() async throws {
        let client = FakeCoreClient()
        let character = LibraryCharacter.previewCharacters[0]
        let conversation = try await client.createConversation(
            characterID: character.id,
            title: "분기 이벤트 필터 방",
            mode: .chat
        )
        let viewModel = ChatViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )
        await viewModel.setConversation(conversation, character: character)
        let activeBranchID = try XCTUnwrap(viewModel.activeBranchID)
        let inactiveBranch = try await client.createConversationBranch(
            conversationID: conversation.id,
            fromMessageID: nil,
            title: "비활성 분기"
        )
        XCTAssertNotEqual(inactiveBranch.id, activeBranchID)
        await client.enqueueEventBatch([
            ChatEvent(
                eventVersion: 2,
                generationID: "inactive-generation",
                conversationID: conversation.id,
                branchID: inactiveBranch.id,
                assistantMessageID: "inactive-assistant",
                sequence: 1,
                kind: "generation_started"
            ),
            ChatEvent(
                eventVersion: 2,
                generationID: "inactive-generation",
                conversationID: conversation.id,
                branchID: inactiveBranch.id,
                assistantMessageID: "inactive-assistant",
                sequence: 2,
                kind: "text_delta",
                text: "다른 분기에서 온 델타"
            ),
        ])

        await viewModel.pollOnce()

        XCTAssertEqual(viewModel.activeBranchID, activeBranchID)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertFalse(viewModel.isGenerating)
        XCTAssertNil(viewModel.usageDescription)
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
        guard let conversationID = viewModel.conversation?.id,
              let branchID = viewModel.activeBranchID
        else {
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
                    eventVersion: 99,
                    generationID: generationID,
                    conversationID: conversationID,
                    branchID: branchID,
                    assistantMessageID: assistantID,
                    sequence: 1,
                    kind: "text_delta",
                    text: "UNSUPPORTED"
                ),
                ChatEvent(
                    generationID: generationID,
                    conversationID: conversationID,
                    branchID: branchID,
                    assistantMessageID: assistantID,
                    sequence: 1,
                    kind: "generation_started"
                ),
                ChatEvent(
                    generationID: generationID,
                    conversationID: conversationID,
                    branchID: branchID,
                    assistantMessageID: assistantID,
                    sequence: 2,
                    kind: "text_delta",
                    text: "A"
                ),
                ChatEvent(
                    generationID: generationID,
                    conversationID: conversationID,
                    branchID: branchID,
                    assistantMessageID: assistantID,
                    sequence: 2,
                    kind: "text_delta",
                    text: "DUPLICATE"
                ),
                ChatEvent(
                    generationID: "wrong-generation",
                    conversationID: conversationID,
                    branchID: branchID,
                    sequence: 3,
                    kind: "text_delta",
                    text: "WRONG"
                ),
                ChatEvent(
                    generationID: generationID,
                    conversationID: conversationID,
                    branchID: branchID,
                    assistantMessageID: assistantID,
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

    func testCredentialStoreTreatsWhitespaceAsDeletion() async throws {
        let credentials = InMemoryCredentialStore(
            values: ["profile": "synthetic-secret"]
        )

        try await credentials.setCredential(
            " \n\t ",
            for: "profile"
        )

        let storedCredential = try await credentials.credential(for: "profile")
        XCTAssertNil(storedCredential)
    }

    func testKeychainQueryContractUsesDataProtectionAndThisDeviceOnly() {
        let service = "dev.lorepia.tests.provider.query-contract"
        let profileID = "synthetic-profile"
        let data = Data("synthetic-keychain-value".utf8)
        let protectedQuery = KeychainQueryBuilder.dataProtectionQuery(
            service: service,
            profileID: profileID
        )
        let legacyQuery = KeychainQueryBuilder.legacyQuery(
            service: service,
            profileID: profileID
        )
        let updateAttributes = KeychainQueryBuilder.updateAttributes(
            data: data
        )
        let addAttributes = KeychainQueryBuilder.addAttributes(
            query: protectedQuery,
            data: data
        )

#if os(macOS)
        XCTAssertEqual(
            protectedQuery[kSecUseDataProtectionKeychain as String]
                as? Bool,
            true
        )
        XCTAssertEqual(
            legacyQuery[kSecUseDataProtectionKeychain as String]
                as? Bool,
            false
        )
#else
        XCTAssertEqual(
            protectedQuery[kSecUseDataProtectionKeychain as String]
                as? Bool,
            true
        )
#endif
        XCTAssertNil(
            legacyQuery[kSecAttrAccessible as String]
        )
        XCTAssertEqual(
            updateAttributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        XCTAssertEqual(
            addAttributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
    }

    func testDataProtectionCredentialReadHardensAndNormalizesExistingItem() async throws {
        let paddedCredential = " \n synthetic-dp-key \t "
        let normalizedCredential = "synthetic-dp-key"
        let legacyData = Data("synthetic-legacy-key".utf8)
        let securityClient = ScriptedKeychainSecurityClient(
            protectedItem: KeychainTestItem(
                data: Data(paddedCredential.utf8),
                accessibility:
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                        as String
            ),
            legacyItem: KeychainTestItem(
                data: legacyData,
                accessibility: nil
            )
        )
        let store = KeychainCredentialStore(
            service: "dev.lorepia.tests.provider.dp-upgrade",
            securityClient: securityClient
        )

        let firstRead = try await store.credential(
            for: "synthetic-profile"
        )

        XCTAssertEqual(firstRead, normalizedCredential)
        XCTAssertEqual(
            securityClient.protectedItemSnapshot(),
            KeychainTestItem(
                data: Data(normalizedCredential.utf8),
                accessibility:
                    kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
            )
        )
#if os(macOS)
        XCTAssertNil(securityClient.legacyItemSnapshot())
#endif
        XCTAssertEqual(securityClient.protectedUpdateCallCount(), 1)

        let secondRead = try await store.credential(
            for: "synthetic-profile"
        )

        XCTAssertEqual(secondRead, normalizedCredential)
        XCTAssertEqual(securityClient.protectedUpdateCallCount(), 1)
    }

#if os(macOS)
    func testLegacyCredentialReadMigratesNormalizedValueToDataProtectionStore() async throws {
        let paddedCredential = " \n synthetic-legacy-key \t "
        let normalizedCredential = "synthetic-legacy-key"
        let securityClient = ScriptedKeychainSecurityClient(
            legacyItem: KeychainTestItem(
                data: Data(paddedCredential.utf8),
                accessibility: nil
            )
        )
        let store = KeychainCredentialStore(
            service: "dev.lorepia.tests.provider.legacy-migration",
            securityClient: securityClient
        )

        let firstRead = try await store.credential(
            for: "synthetic-profile"
        )

        XCTAssertEqual(firstRead, normalizedCredential)
        XCTAssertEqual(
            securityClient.protectedItemSnapshot(),
            KeychainTestItem(
                data: Data(normalizedCredential.utf8),
                accessibility:
                    kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
            )
        )
        XCTAssertNil(securityClient.legacyItemSnapshot())
        XCTAssertEqual(securityClient.protectedUpdateCallCount(), 1)

        let secondRead = try await store.credential(
            for: "synthetic-profile"
        )

        XCTAssertEqual(secondRead, normalizedCredential)
        XCTAssertEqual(securityClient.protectedUpdateCallCount(), 1)
    }

    func testLegacyMigrationAcceptsOversizedRawPaddingWhenNormalizedCredentialIsWithinLimit() async throws {
        let normalizedCredential = "synthetic-short-key"
        let paddedCredential =
            String(
                repeating: " ",
                count: CredentialStorePolicy.maximumCredentialUTF8Bytes + 1
            )
            + normalizedCredential
            + "\n\t"
        XCTAssertGreaterThan(
            paddedCredential.utf8.count,
            CredentialStorePolicy.maximumCredentialUTF8Bytes
        )
        let securityClient = ScriptedKeychainSecurityClient(
            legacyItem: KeychainTestItem(
                data: Data(paddedCredential.utf8),
                accessibility: nil
            )
        )
        let store = KeychainCredentialStore(
            service: "dev.lorepia.tests.provider.legacy-padding",
            securityClient: securityClient
        )

        let firstRead = try await store.credential(
            for: "synthetic-profile"
        )
        let secondRead = try await store.credential(
            for: "synthetic-profile"
        )

        XCTAssertEqual(firstRead, normalizedCredential)
        XCTAssertEqual(secondRead, normalizedCredential)
        XCTAssertEqual(
            securityClient.protectedItemSnapshot(),
            KeychainTestItem(
                data: Data(normalizedCredential.utf8),
                accessibility:
                    kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
            )
        )
        XCTAssertNil(securityClient.legacyItemSnapshot())
        XCTAssertEqual(securityClient.protectedUpdateCallCount(), 1)
    }

    func testOversizedNormalizedLegacyCredentialFailsBeforeMigrationOrCleanup() async {
        let overlongCredential = String(
            repeating: "x",
            count: CredentialStorePolicy.maximumCredentialUTF8Bytes + 1
        )
        let legacyData = Data(overlongCredential.utf8)
        let securityClient = ScriptedKeychainSecurityClient(
            legacyItem: KeychainTestItem(
                data: legacyData,
                accessibility: nil
            )
        )
        let store = KeychainCredentialStore(
            service: "dev.lorepia.tests.provider.legacy-overlong",
            securityClient: securityClient
        )

        do {
            _ = try await store.credential(for: "synthetic-profile")
            XCTFail("Expected an oversized normalized credential failure")
        } catch {
            XCTAssertEqual(
                error as? CredentialStoreError,
                .credentialTooLarge
            )
        }

        XCTAssertNil(securityClient.protectedItemSnapshot())
        XCTAssertEqual(
            securityClient.legacyItemSnapshot()?.data,
            legacyData
        )
        XCTAssertEqual(securityClient.protectedUpdateCallCount(), 0)
        XCTAssertEqual(securityClient.legacyDeleteCallCount(), 0)
    }

    func testCorruptLegacyCredentialFailsBeforeMigrationOrCleanup() async {
        let legacyData = Data([0xFF, 0xFE])
        let securityClient = ScriptedKeychainSecurityClient(
            legacyItem: KeychainTestItem(
                data: legacyData,
                accessibility: nil
            )
        )
        let store = KeychainCredentialStore(
            service: "dev.lorepia.tests.provider.legacy-corrupt",
            securityClient: securityClient
        )

        do {
            _ = try await store.credential(for: "synthetic-profile")
            XCTFail("Expected invalid UTF-8 to fail closed")
        } catch {
            XCTAssertEqual(
                error as? CredentialStoreError,
                .invalidEncoding
            )
        }

        XCTAssertNil(securityClient.protectedItemSnapshot())
        XCTAssertEqual(
            securityClient.legacyItemSnapshot()?.data,
            legacyData
        )
        XCTAssertEqual(securityClient.protectedUpdateCallCount(), 0)
        XCTAssertEqual(securityClient.legacyDeleteCallCount(), 0)
    }

    func testLegacyMigrationVerificationFailureRollsBackProtectedCopyAndPreservesLegacy() async {
        let credentialCanary =
            "synthetic-secret-canary-legacy-verify-operation-42"
        let legacyData = Data(" \(credentialCanary) ".utf8)
        let securityClient = ScriptedKeychainSecurityClient(
            legacyItem: KeychainTestItem(
                data: legacyData,
                accessibility: nil
            ),
            copyFailureStatuses: [
                3: errSecInteractionNotAllowed,
            ]
        )
        let store = KeychainCredentialStore(
            service: "dev.lorepia.tests.provider.legacy-verify-failure",
            securityClient: securityClient
        )

        do {
            _ = try await store.credential(for: "synthetic-profile")
            XCTFail("Expected migration verification to fail")
        } catch {
            XCTAssertEqual(
                error as? CredentialStoreError,
                .keychainStatus(errSecInteractionNotAllowed)
            )
            XCTAssertFalse(
                String(reflecting: error).contains(credentialCanary)
            )
            XCTAssertFalse(
                error.localizedDescription.contains(credentialCanary)
            )
        }

        XCTAssertNil(securityClient.protectedItemSnapshot())
        XCTAssertEqual(
            securityClient.legacyItemSnapshot()?.data,
            legacyData
        )
        XCTAssertEqual(securityClient.legacyDeleteCallCount(), 0)
    }
#endif

    func testCredentialWriteVerificationFailureRestoresPreviousProtectedData() async {
        let oldCredential = "synthetic-old-protected-key"
        let newCredentialCanary =
            "synthetic-secret-canary-new-key-operation-42"
        let legacyData = Data("synthetic-legacy-key".utf8)
        let securityClient = ScriptedKeychainSecurityClient(
            protectedItem: KeychainTestItem(
                data: Data(oldCredential.utf8),
                accessibility:
                    kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
            ),
            legacyItem: KeychainTestItem(
                data: legacyData,
                accessibility: nil
            ),
            copyFailureStatuses: [
                2: errSecInteractionNotAllowed,
            ]
        )
        let store = KeychainCredentialStore(
            service: "dev.lorepia.tests.provider.write-verify-failure",
            securityClient: securityClient
        )

        do {
            try await store.setCredential(
                newCredentialCanary,
                for: "synthetic-profile"
            )
            XCTFail("Expected write verification to fail")
        } catch {
            XCTAssertEqual(
                error as? CredentialStoreError,
                .keychainStatus(errSecInteractionNotAllowed)
            )
            XCTAssertFalse(
                String(reflecting: error).contains(newCredentialCanary)
            )
            XCTAssertFalse(
                error.localizedDescription.contains(newCredentialCanary)
            )
        }

        XCTAssertEqual(
            securityClient.protectedItemSnapshot(),
            KeychainTestItem(
                data: Data(oldCredential.utf8),
                accessibility:
                    kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
            )
        )
#if os(macOS)
        XCTAssertEqual(
            securityClient.legacyItemSnapshot()?.data,
            legacyData
        )
        XCTAssertEqual(securityClient.legacyDeleteCallCount(), 0)
#endif
    }

    func testDataProtectionHardeningUpdateFailurePreservesLegacyAndHidesCredential() async {
        let credentialCanary =
            "synthetic-secret-canary-dp-update-operation-42"
        let originalData = Data(" \(credentialCanary) ".utf8)
        let legacyData = Data("synthetic-legacy-key".utf8)
        let securityClient = ScriptedKeychainSecurityClient(
            protectedItem: KeychainTestItem(
                data: originalData,
                accessibility:
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                        as String
            ),
            legacyItem: KeychainTestItem(
                data: legacyData,
                accessibility: nil
            ),
            updateStatuses: [errSecInteractionNotAllowed]
        )
        let store = KeychainCredentialStore(
            service: "dev.lorepia.tests.provider.dp-update-failure",
            securityClient: securityClient
        )

        do {
            _ = try await store.credential(for: "synthetic-profile")
            XCTFail("Expected the injected Keychain update failure")
        } catch {
            XCTAssertEqual(
                error as? CredentialStoreError,
                .keychainStatus(errSecInteractionNotAllowed)
            )
            XCTAssertFalse(
                String(reflecting: error).contains(credentialCanary)
            )
            XCTAssertFalse(
                error.localizedDescription.contains(credentialCanary)
            )
        }

        XCTAssertEqual(
            securityClient.protectedItemSnapshot()?.data,
            originalData
        )
        XCTAssertEqual(
            securityClient.legacyItemSnapshot()?.data,
            legacyData
        )
        XCTAssertEqual(securityClient.legacyDeleteCallCount(), 0)
    }

    func testDataProtectionHardeningVerificationFailurePreservesLegacyAndHidesCredential() async {
        let credentialCanary =
            "synthetic-secret-canary-dp-verify-operation-42"
        let originalData = Data(" \(credentialCanary) ".utf8)
        let legacyData = Data("synthetic-legacy-key".utf8)
        let securityClient = ScriptedKeychainSecurityClient(
            protectedItem: KeychainTestItem(
                data: originalData,
                accessibility:
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                        as String
            ),
            legacyItem: KeychainTestItem(
                data: legacyData,
                accessibility: nil
            ),
            copyFailureStatuses: [
                3: errSecInteractionNotAllowed,
            ]
        )
        let store = KeychainCredentialStore(
            service: "dev.lorepia.tests.provider.dp-verify-failure",
            securityClient: securityClient
        )

        do {
            _ = try await store.credential(for: "synthetic-profile")
            XCTFail("Expected the injected Keychain verification failure")
        } catch {
            XCTAssertEqual(
                error as? CredentialStoreError,
                .keychainStatus(errSecInteractionNotAllowed)
            )
            XCTAssertFalse(
                String(reflecting: error).contains(credentialCanary)
            )
            XCTAssertFalse(
                error.localizedDescription.contains(credentialCanary)
            )
        }

        XCTAssertEqual(
            securityClient.protectedItemSnapshot()?.data,
            originalData
        )
        XCTAssertEqual(
            securityClient.legacyItemSnapshot()?.data,
            legacyData
        )
        XCTAssertEqual(securityClient.legacyDeleteCallCount(), 0)
    }

    func testInvalidDataProtectionCredentialFailsBeforeMutationOrLegacyCleanup() async {
        let legacyData = Data("synthetic-legacy-key".utf8)
        let securityClient = ScriptedKeychainSecurityClient(
            protectedItem: KeychainTestItem(
                data: Data([0xFF, 0xFE]),
                accessibility:
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                        as String
            ),
            legacyItem: KeychainTestItem(
                data: legacyData,
                accessibility: nil
            )
        )
        let store = KeychainCredentialStore(
            service: "dev.lorepia.tests.provider.dp-invalid-encoding",
            securityClient: securityClient
        )

        do {
            _ = try await store.credential(for: "synthetic-profile")
            XCTFail("Expected invalid UTF-8 to fail closed")
        } catch {
            XCTAssertEqual(
                error as? CredentialStoreError,
                .invalidEncoding
            )
        }

        XCTAssertEqual(securityClient.protectedUpdateCallCount(), 0)
        XCTAssertEqual(
            securityClient.legacyItemSnapshot()?.data,
            legacyData
        )
        XCTAssertEqual(securityClient.legacyDeleteCallCount(), 0)
    }

    func testLegacyKeychainSecurityOperationsLifecycle() throws {
        let identifier = UUID().uuidString
        let service = "dev.lorepia.tests.provider.\(identifier)"
        let profileID = "synthetic-profile-\(identifier)"
        let query = KeychainQueryBuilder.legacyQuery(
            service: service,
            profileID: profileID
        )
        _ = SecItemDelete(query as CFDictionary)
        defer {
            let cleanupStatus = SecItemDelete(
                query as CFDictionary
            )
            XCTAssertTrue(
                cleanupStatus == errSecSuccess
                    || cleanupStatus == errSecItemNotFound,
                "Synthetic Keychain test item cleanup failed"
            )
        }

        func readData() throws -> Data? {
            var readQuery = query
            readQuery[kSecReturnData as String] = true
            readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(
                readQuery as CFDictionary,
                &result
            )
            if status == errSecItemNotFound {
                return nil
            }
            guard status == errSecSuccess else {
                throw CredentialStoreError.keychainStatus(status)
            }
            return result as? Data
        }

        let firstData = Data("synthetic-keychain-first".utf8)
        var addItem = query
        addItem[kSecValueData as String] = firstData
        let addStatus = SecItemAdd(
            addItem as CFDictionary,
            nil
        )
        XCTAssertEqual(addStatus, errSecSuccess)
        XCTAssertTrue(try readData() == firstData)
        XCTAssertTrue(
            try readData() == firstData,
            "Repeated Keychain read unexpectedly removed the item"
        )

        let replacementData = Data(
            "synthetic-keychain-replacement".utf8
        )
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [
                kSecValueData as String: replacementData,
            ] as CFDictionary
        )
        XCTAssertEqual(updateStatus, errSecSuccess)
        XCTAssertTrue(try readData() == replacementData)

        let deleteStatus = SecItemDelete(query as CFDictionary)
        XCTAssertEqual(deleteStatus, errSecSuccess)
        XCTAssertNil(try readData())
    }

    func testCredentialStoreAcceptsTheExactUTF8ByteLimit() async throws {
        let credentials = InMemoryCredentialStore()
        let exactBoundary = String(
            repeating: "a",
            count: CredentialStorePolicy.maximumCredentialUTF8Bytes
        )

        try await credentials.setCredential(
            exactBoundary,
            for: "exact-boundary"
        )

        let stored = try await credentials.credential(
            for: "exact-boundary"
        )
        XCTAssertEqual(
            stored?.utf8.count,
            CredentialStorePolicy.maximumCredentialUTF8Bytes
        )
    }

    func testSettingsRejectsOverlongCredentialsBeforeCoreOrKeychainMutation() async throws {
        let profile = providerSelectionFixtures()[0]
        let existingCredential = "synthetic-existing-key"
        let overlongCredentials = [
            String(
                repeating: "a",
                count: CredentialStorePolicy.maximumCredentialUTF8Bytes + 1
            ),
            String(
                repeating: "가",
                count:
                    CredentialStorePolicy.maximumCredentialUTF8Bytes / 3 + 1
            ),
        ]

        for overlongCredential in overlongCredentials {
            XCTAssertGreaterThan(
                overlongCredential.utf8.count,
                CredentialStorePolicy.maximumCredentialUTF8Bytes
            )
            let client = FakeCoreClient(profiles: [profile])
            let credentials = ScriptedCredentialStore(
                values: [profile.id: existingCredential]
            )
            let viewModel = SettingsViewModel(
                client: client,
                credentialStore: credentials,
                runtimeMode: .preview
            )
            await viewModel.refresh()
            viewModel.credentialDraft = overlongCredential

            await viewModel.saveProfile()

            let storedCredential = try await credentials.credential(
                for: profile.id
            )
            let upsertCount =
                await client.providerUpsertInvocationCountForTesting()
            let setCount = await credentials.setCallCount()
            XCTAssertTrue(storedCredential == existingCredential)
            XCTAssertEqual(upsertCount, 0)
            XCTAssertEqual(setCount, 0)
            XCTAssertEqual(
                viewModel.errorMessage,
                "API 키가 너무 깁니다. 더 짧은 키인지 확인하세요."
            )
            XCTAssertTrue(viewModel.hasStoredCredential)
            XCTAssertEqual(viewModel.profiles, [profile])
        }
    }

    func testChatRejectsLegacyOverlongCredentialsBeforeCoreSend() async {
        let profile = providerSelectionFixtures()[0]
        let overlongCredentials = [
            String(
                repeating: "a",
                count: CredentialStorePolicy.maximumCredentialUTF8Bytes + 1
            ),
            String(
                repeating: "가",
                count:
                    CredentialStorePolicy.maximumCredentialUTF8Bytes / 3 + 1
            ),
        ]

        for overlongCredential in overlongCredentials {
            let client = FakeCoreClient(profiles: [profile])
            let credentials = ScriptedCredentialStore(
                values: [profile.id: overlongCredential]
            )
            let viewModel = ChatViewModel(
                client: client,
                credentialStore: credentials,
                runtimeMode: .preview,
                automaticallyPollEvents: false
            )
            await viewModel.setCharacter(
                LibraryCharacter.previewCharacters[0]
            )
            let exactDraft = " \n legacy credential 실패 \t "
            viewModel.draft = exactDraft

            await viewModel.submitMessage()

            XCTAssertEqual(viewModel.draft, exactDraft)
            XCTAssertFalse(viewModel.canSubmit)
            XCTAssertEqual(
                viewModel.errorMessage,
                "저장된 자격 증명이 너무 깁니다. 프로바이더 설정에서 다시 저장하세요."
            )
            let requests = await client.providerSendRequestsForTesting()
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func testSettingsWhitespaceCredentialDoesNotReportAStoredKey() async throws {
        let client = FakeCoreClient(profiles: [])
        let credentials = InMemoryCredentialStore()
        let viewModel = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview
        )
        viewModel.beginNewProfile()
        viewModel.profileName = "Whitespace Test"
        viewModel.baseURL = "https://example.invalid/v1"
        viewModel.model = "synthetic"
        viewModel.timeoutSeconds = "15"
        viewModel.credentialDraft = " \n\t "

        await viewModel.saveProfile()

        let profile = try XCTUnwrap(viewModel.profiles.first)
        let storedCredential = try await credentials.credential(for: profile.id)
        XCTAssertNil(storedCredential)
        XCTAssertFalse(viewModel.hasStoredCredential)
        XCTAssertTrue(viewModel.isCredentialStateKnown)
        XCTAssertTrue(viewModel.credentialDraft.isEmpty)
    }

    func testSettingsOverwritesAnUnreadableCredentialAfterDurableDeselect() async throws {
        let profile = providerSelectionFixtures()[0]
        let replacementCredential = "synthetic-readable-replacement"
        let client = FakeCoreClient(profiles: [profile])
        let credentials = ScriptedCredentialStore(
            values: [profile.id: "synthetic-unreadable-existing"],
            readFailureInvocations: [1, 2]
        )
        let viewModel = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview
        )
        await viewModel.refresh()
        XCTAssertFalse(viewModel.isCredentialStateKnown)
        viewModel.credentialDraft = replacementCredential

        await viewModel.saveProfile()

        let stored = try await credentials.credential(for: profile.id)
        let persisted = try await client.getSettings()
        XCTAssertEqual(stored, replacementCredential)
        XCTAssertEqual(persisted.selectedProviderProfileID, profile.id)
        XCTAssertTrue(viewModel.isCredentialStateKnown)
        XCTAssertTrue(viewModel.hasStoredCredential)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testSettingsForceClearsAnUnreadableCredential() async throws {
        let profile = providerSelectionFixtures()[0]
        let client = FakeCoreClient(profiles: [profile])
        let credentials = ScriptedCredentialStore(
            values: [profile.id: "synthetic-unreadable-existing"],
            readFailureInvocations: [1, 2]
        )
        let viewModel = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview
        )
        await viewModel.refresh()
        XCTAssertFalse(viewModel.isCredentialStateKnown)

        await viewModel.clearCredential()

        let stored = try await credentials.credential(for: profile.id)
        let persisted = try await client.getSettings()
        XCTAssertNil(stored)
        XCTAssertEqual(persisted.selectedProviderProfileID, profile.id)
        XCTAssertTrue(viewModel.isCredentialStateKnown)
        XCTAssertFalse(viewModel.hasStoredCredential)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testSettingsDeletesAProfileWithAnUnreadableCredential() async throws {
        let profile = providerSelectionFixtures()[0]
        let client = FakeCoreClient(profiles: [profile])
        let credentials = ScriptedCredentialStore(
            values: [profile.id: "synthetic-unreadable-existing"],
            readFailureInvocations: [1, 2]
        )
        let viewModel = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview
        )
        await viewModel.refresh()
        XCTAssertFalse(viewModel.isCredentialStateKnown)

        await viewModel.deleteEditingProfile()

        let stored = try await credentials.credential(for: profile.id)
        let profiles = try await client.listProviderProfiles()
        let persisted = try await client.getSettings()
        XCTAssertNil(stored)
        XCTAssertTrue(profiles.isEmpty)
        XCTAssertNil(persisted.selectedProviderProfileID)
        XCTAssertTrue(viewModel.profiles.isEmpty)
        XCTAssertTrue(viewModel.isCredentialStateKnown)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testSettingsCredentialWriteFailureCanRecoverWithoutLosingProfile() async throws {
        let secret = "synthetic-retry-secret"
        let client = FakeCoreClient(profiles: [])
        let credentials = ScriptedCredentialStore(
            setFailuresBeforeSuccess: 1
        )
        let viewModel = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview
        )
        viewModel.beginNewProfile()
        viewModel.profileName = "Retry Test"
        viewModel.baseURL = "https://example.invalid/v1"
        viewModel.model = "synthetic"
        viewModel.timeoutSeconds = "15"
        viewModel.credentialDraft = secret

        await viewModel.saveProfile()

        XCTAssertTrue(viewModel.profiles.isEmpty)
        XCTAssertEqual(viewModel.credentialDraft, secret)
        XCTAssertFalse(viewModel.hasStoredCredential)
        XCTAssertTrue(viewModel.isCredentialStateKnown)
        XCTAssertFalse(viewModel.errorMessage?.contains(secret) == true)
        XCTAssertFalse(viewModel.statusMessage?.contains(secret) == true)

        await viewModel.saveProfile()

        let profile = try XCTUnwrap(viewModel.profiles.first)
        let credentialAfterRetry = try await credentials.credential(
            for: profile.id
        )
        XCTAssertEqual(credentialAfterRetry, secret)
        XCTAssertTrue(viewModel.hasStoredCredential)
        XCTAssertTrue(viewModel.credentialDraft.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.profiles.count, 1)
    }

    func testSettingsProfileDeleteFailureRestoresCredential() async throws {
        let profile = providerSelectionFixtures()[0]
        let secret = "synthetic-delete-secret"
        let client = FakeCoreClient(
            profiles: [profile],
            testingOptions: FakeCoreClientTestingOptions(
                deleteProviderFailuresBeforeSuccess: 1
            )
        )
        let credentials = ScriptedCredentialStore(
            values: [profile.id: secret]
        )
        let viewModel = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview
        )
        await viewModel.refresh()

        await viewModel.deleteEditingProfile()

        let retainedProfiles = try await client.listProviderProfiles()
        let restoredCredential = try await credentials.credential(
            for: profile.id
        )
        XCTAssertEqual(retainedProfiles, [profile])
        XCTAssertEqual(restoredCredential, secret)
        XCTAssertEqual(viewModel.profiles, [profile])
        XCTAssertTrue(viewModel.hasStoredCredential)
        XCTAssertTrue(viewModel.isCredentialStateKnown)
        XCTAssertTrue(viewModel.credentialDraft.isEmpty)
        XCTAssertFalse(viewModel.errorMessage?.contains(secret) == true)
        XCTAssertFalse(viewModel.statusMessage?.contains(secret) == true)
    }

    func testSettingsDeleteAndCredentialRestoreFailureNeverPublishesSecret() async throws {
        let profile = providerSelectionFixtures()[0]
        let secret = "synthetic-rollback-canary"
        let store = ProviderConfigurationStore()
        let client = FakeCoreClient(
            profiles: [profile],
            testingOptions: FakeCoreClientTestingOptions(
                deleteProviderFailuresBeforeSuccess: 1
            )
        )
        let credentials = ScriptedCredentialStore(
            values: [profile.id: secret],
            setFailuresBeforeSuccess: 1
        )
        let viewModel = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        let chat = ChatViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store,
            automaticallyPollEvents: false
        )
        await chat.setCharacter(LibraryCharacter.previewCharacters[0])
        await viewModel.refresh()
        await chat.refreshProviderSelection()
        chat.draft = "fail closed"

        await viewModel.deleteEditingProfile()
        await waitUntil {
            chat.hasLoadedProviderConfiguration
                && chat.selectedProviderProfileID == nil
        }

        let retainedProfiles = try await client.listProviderProfiles()
        let restoredCredential = try await credentials.credential(
            for: profile.id
        )
        let coreSettings = try await client.getSettings()
        XCTAssertEqual(retainedProfiles, [profile])
        XCTAssertNil(restoredCredential)
        XCTAssertEqual(viewModel.profiles, [profile])
        XCTAssertNil(coreSettings.selectedProviderProfileID)
        XCTAssertNil(viewModel.selectedProfileID)
        XCTAssertNil(store.selectedProfileID)
        XCTAssertNil(chat.selectedProviderProfileID)
        XCTAssertFalse(chat.canSubmit)
        XCTAssertFalse(viewModel.hasStoredCredential)
        XCTAssertTrue(viewModel.isCredentialStateKnown)
        XCTAssertTrue(viewModel.credentialDraft.isEmpty)
        XCTAssertFalse(viewModel.errorMessage?.contains(secret) == true)
        XCTAssertFalse(viewModel.statusMessage?.contains(secret) == true)
        XCTAssertFalse(viewModel.credentialStatusDescription.contains(secret))

        await chat.submitMessage()
        let sendRequests = await client.providerSendRequestsForTesting()
        XCTAssertTrue(sendRequests.isEmpty)

        let restartedStore = ProviderConfigurationStore()
        let restartedChat = ChatViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: restartedStore,
            automaticallyPollEvents: false
        )
        await restartedChat.setCharacter(
            LibraryCharacter.previewCharacters[0]
        )
        let restartedDraft = "  재시작 후에도 보존할 원문  "
        restartedChat.draft = restartedDraft
        await restartedChat.refreshProviderSelection()

        XCTAssertTrue(restartedStore.quarantinedProfileIDs.isEmpty)
        XCTAssertNil(restartedChat.selectedProviderProfileID)
        XCTAssertFalse(restartedChat.canSubmit)
        await restartedChat.submitMessage()

        let requestsAfterRestart =
            await client.providerSendRequestsForTesting()
        XCTAssertTrue(requestsAfterRestart.isEmpty)
        XCTAssertEqual(restartedChat.draft, restartedDraft)
    }

    func testSettingsPreDeselectFailureLeavesCredentialAndProfileUntouched() async throws {
        let profile = providerSelectionFixtures()[0]
        let storedSecret = "synthetic-quarantine-old-key"
        let rawDetail =
            "synthetic-secret-canary operation_id=deselect-operation-42"
        let store = ProviderConfigurationStore()
        let client = FakeCoreClient(
            profiles: [profile],
            testingOptions: FakeCoreClientTestingOptions(
                updateSettingsFailure: .invalidResponse(rawDetail),
                updateSettingsFailureInvocations: [1]
            )
        )
        let credentials = ScriptedCredentialStore(
            values: [profile.id: storedSecret]
        )
        let settings = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        let chat = ChatViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store,
            automaticallyPollEvents: false
        )
        await chat.setCharacter(LibraryCharacter.previewCharacters[0])
        await settings.refresh()
        await chat.refreshProviderSelection()
        let exactDraft = "  격리 중 보존할 원문  "
        chat.draft = exactDraft

        await settings.deleteEditingProfile()

        let coreSettingsAfterFailure = try await client.getSettings()
        let retainedProfiles = try await client.listProviderProfiles()
        let retainedCredential = try await credentials.credential(
            for: profile.id
        )
        let credentialDeleteCount =
            await credentials.deleteCallCount()
        let providerDeleteCount =
            await client.providerDeleteInvocationCountForTesting()
        XCTAssertEqual(
            coreSettingsAfterFailure.selectedProviderProfileID,
            profile.id
        )
        XCTAssertEqual(retainedProfiles, [profile])
        XCTAssertEqual(retainedCredential, storedSecret)
        XCTAssertEqual(credentialDeleteCount, 0)
        XCTAssertEqual(providerDeleteCount, 0)
        XCTAssertEqual(settings.selectedProfileID, profile.id)
        XCTAssertFalse(store.isQuarantined(profileID: profile.id))
        XCTAssertFalse(
            store.mutatingProfileIDs.contains(profile.id)
        )
        XCTAssertEqual(chat.draft, exactDraft)
        XCTAssertFalse(settings.errorMessage?.contains(rawDetail) == true)
        XCTAssertFalse(settings.statusMessage?.contains(rawDetail) == true)
    }

    func testSettingsPersistsDeselectBeforeDeletingSelectedCredential() async throws {
        let profile = providerSelectionFixtures()[0]
        let storedCredential = "synthetic-delete-order-key"
        let client = FakeCoreClient(profiles: [profile])
        let credentials = ScriptedCredentialStore(
            values: [profile.id: storedCredential],
            deleteDelay: .milliseconds(150)
        )
        let settings = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview
        )
        await settings.refresh()

        let deletion = Task {
            await settings.deleteEditingProfile()
        }
        await waitUntil {
            await credentials.deleteCallCount() == 1
        }

        let settingsDuringCredentialDeletion =
            try await client.getSettings()
        let credentialDuringDeletion =
            try await credentials.credential(for: profile.id)
        XCTAssertNil(
            settingsDuringCredentialDeletion.selectedProviderProfileID
        )
        XCTAssertEqual(
            credentialDuringDeletion,
            storedCredential
        )
        await deletion.value
    }

    func testSettingsRestoresSelectionOnlyAfterCredentialRestoreVerification() async throws {
        let profile = providerSelectionFixtures()[0]
        let storedCredential = "synthetic-verified-restore-key"
        let client = FakeCoreClient(
            profiles: [profile],
            testingOptions: FakeCoreClientTestingOptions(
                deleteProviderFailuresBeforeSuccess: 1
            )
        )
        let credentials = ScriptedCredentialStore(
            values: [profile.id: storedCredential],
            readDelay: .milliseconds(100)
        )
        let settings = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview
        )
        await settings.refresh()

        let deletion = Task {
            await settings.deleteEditingProfile()
        }
        await waitUntil(timeout: .seconds(3)) {
            await credentials.readCallCount() >= 4
        }

        let coreSettingsDuringVerification =
            try await client.getSettings()
        XCTAssertNil(
            coreSettingsDuringVerification.selectedProviderProfileID
        )
        await deletion.value

        let coreSettingsAfterVerification =
            try await client.getSettings()
        let restoredCredential = try await credentials.credential(
            for: profile.id
        )
        XCTAssertEqual(
            coreSettingsAfterVerification.selectedProviderProfileID,
            profile.id
        )
        XCTAssertEqual(restoredCredential, storedCredential)
    }

    func testSettingsSelectionRestoreFailureKeepsDurableDeselectAcrossRestart() async throws {
        let profile = providerSelectionFixtures()[0]
        let storedCredential = "synthetic-selection-restore-key"
        let rawDetail =
            "synthetic-secret-canary operation_id=selection-restore-42"
        let client = FakeCoreClient(
            profiles: [profile],
            testingOptions: FakeCoreClientTestingOptions(
                deleteProviderFailuresBeforeSuccess: 1,
                updateSettingsFailure: .invalidResponse(rawDetail),
                updateSettingsFailureInvocations: [2]
            )
        )
        let credentials = ScriptedCredentialStore(
            values: [profile.id: storedCredential]
        )
        let settings = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview
        )
        await settings.refresh()

        await settings.deleteEditingProfile()

        let coreSettings = try await client.getSettings()
        let retainedProfiles = try await client.listProviderProfiles()
        let restoredCredential = try await credentials.credential(
            for: profile.id
        )
        XCTAssertNil(coreSettings.selectedProviderProfileID)
        XCTAssertEqual(retainedProfiles, [profile])
        XCTAssertEqual(restoredCredential, storedCredential)
        XCTAssertNil(settings.selectedProfileID)
        XCTAssertFalse(settings.errorMessage?.contains(rawDetail) == true)
        XCTAssertFalse(settings.statusMessage?.contains(rawDetail) == true)

        let restartedStore = ProviderConfigurationStore()
        let restartedChat = ChatViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: restartedStore,
            automaticallyPollEvents: false
        )
        await restartedChat.setCharacter(
            LibraryCharacter.previewCharacters[0]
        )
        let exactDraft = "  selection restore 재시작 원문  "
        restartedChat.draft = exactDraft
        await restartedChat.refreshProviderSelection()
        await restartedChat.submitMessage()

        let requests = await client.providerSendRequestsForTesting()
        XCTAssertTrue(restartedStore.quarantinedProfileIDs.isEmpty)
        XCTAssertNil(restartedChat.selectedProviderProfileID)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(restartedChat.draft, exactDraft)
    }

    func testSettingsPreexistingQuarantineNeverRestoresSelectionAfterDeleteFailure() async throws {
        for failsAtCredentialDelete in [true, false] {
            let profile = providerSelectionFixtures()[0]
            let storedCredential =
                "synthetic-prior-quarantine-\(failsAtCredentialDelete)"
            let store = ProviderConfigurationStore(
                quarantinedProfileIDs: [profile.id]
            )
            let client = FakeCoreClient(
                profiles: [profile],
                testingOptions: FakeCoreClientTestingOptions(
                    deleteProviderFailuresBeforeSuccess:
                        failsAtCredentialDelete ? 0 : 1
                )
            )
            let credentials = ScriptedCredentialStore(
                values: [profile.id: storedCredential],
                deleteFailuresBeforeSuccess:
                    failsAtCredentialDelete ? 1 : 0
            )
            let settings = SettingsViewModel(
                client: client,
                credentialStore: credentials,
                runtimeMode: .preview,
                providerConfigurationStore: store
            )
            await settings.refresh()

            await settings.deleteEditingProfile()

            let coreSettings = try await client.getSettings()
            let retainedProfiles = try await client.listProviderProfiles()
            let retainedCredential = try await credentials.credential(
                for: profile.id
            )
            XCTAssertNil(coreSettings.selectedProviderProfileID)
            XCTAssertEqual(retainedProfiles, [profile])
            XCTAssertEqual(retainedCredential, storedCredential)
            XCTAssertTrue(store.isQuarantined(profileID: profile.id))

            let restartedStore = ProviderConfigurationStore()
            let restartedChat = ChatViewModel(
                client: client,
                credentialStore: credentials,
                runtimeMode: .preview,
                providerConfigurationStore: restartedStore,
                automaticallyPollEvents: false
            )
            await restartedChat.setCharacter(
                LibraryCharacter.previewCharacters[0]
            )
            let exactDraft =
                "  prior quarantine \(failsAtCredentialDelete)  "
            restartedChat.draft = exactDraft
            await restartedChat.refreshProviderSelection()
            await restartedChat.submitMessage()

            let requests =
                await client.providerSendRequestsForTesting()
            XCTAssertTrue(restartedStore.quarantinedProfileIDs.isEmpty)
            XCTAssertNil(restartedChat.selectedProviderProfileID)
            XCTAssertTrue(requests.isEmpty)
            XCTAssertEqual(restartedChat.draft, exactDraft)
        }
    }

    func testSettingsBaseURLChangeWithStoredKeyRequiresANewCredential() async throws {
        let profile = providerSelectionFixtures()[0]
        let existingCredential = "synthetic-existing-key"
        let client = FakeCoreClient(profiles: [profile])
        let credentials = ScriptedCredentialStore(
            values: [profile.id: existingCredential]
        )
        let viewModel = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview
        )
        await viewModel.refresh()
        viewModel.baseURL = "https://changed.example.invalid/v1"
        viewModel.credentialDraft = " \n "

        await viewModel.saveProfile()

        let coreProfiles = try await client.listProviderProfiles()
        let coreSettings = try await client.getSettings()
        let storedCredential = try await credentials.credential(
            for: profile.id
        )
        let upsertCount =
            await client.providerUpsertInvocationCountForTesting()
        let setCount = await credentials.setCallCount()
        XCTAssertEqual(coreProfiles, [profile])
        XCTAssertEqual(coreSettings.selectedProviderProfileID, profile.id)
        XCTAssertTrue(storedCredential == existingCredential)
        XCTAssertEqual(upsertCount, 0)
        XCTAssertEqual(setCount, 0)
        XCTAssertEqual(
            viewModel.errorMessage,
            "Base URL을 변경하려면 새 API 키를 함께 입력하거나 저장된 키를 먼저 삭제하세요."
        )
    }

    func testSettingsTemporarilyDeselectsAProfileWhileReplacingItsKey() async throws {
        let profile = providerSelectionFixtures()[0]
        let store = ProviderConfigurationStore()
        let client = FakeCoreClient(profiles: [profile])
        let credentials = ScriptedCredentialStore(
            values: [profile.id: "synthetic-old-key"],
            setDelay: .milliseconds(80)
        )
        let settings = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        let chat = ChatViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store,
            automaticallyPollEvents: false
        )
        await chat.setCharacter(LibraryCharacter.previewCharacters[0])
        await settings.refresh()
        await chat.refreshProviderSelection()
        chat.draft = "교체 중 차단"
        settings.model = "lore-compact-updated"
        settings.credentialDraft = "synthetic-new-key"

        let save = Task {
            await settings.saveProfile()
        }
        await waitUntil {
            settings.isLoading
                && settings.selectedProfileID == nil
                && store.selectedProfileID == nil
        }
        await waitUntil {
            chat.hasLoadedProviderConfiguration
                && chat.selectedProviderProfileID == nil
        }

        XCTAssertFalse(chat.canSubmit)
        await chat.submitMessage()
        let requestsDuringReplacement =
            await client.providerSendRequestsForTesting()
        XCTAssertTrue(requestsDuringReplacement.isEmpty)

        await save.value
        await waitUntil {
            chat.selectedProviderProfileID == profile.id
        }

        let coreSettings = try await client.getSettings()
        let coreProfiles = try await client.listProviderProfiles()
        let storedCredential = try await credentials.credential(
            for: profile.id
        )
        XCTAssertEqual(coreSettings.selectedProviderProfileID, profile.id)
        XCTAssertEqual(coreProfiles.first?.model, "lore-compact-updated")
        XCTAssertTrue(storedCredential == "synthetic-new-key")
        XCTAssertEqual(store.selectedProfileID, profile.id)
        XCTAssertEqual(chat.selectedProviderProfileID, profile.id)
    }

    func testSettingsSelectedProfileCredentialFailureRestoresThePreviousPair() async throws {
        let profile = providerSelectionFixtures()[0]
        let oldCredential = "synthetic-old-key"
        let replacementCredential = "synthetic-new-key"
        let store = ProviderConfigurationStore()
        let client = FakeCoreClient(profiles: [profile])
        let credentials = ScriptedCredentialStore(
            values: [profile.id: oldCredential],
            setFailuresBeforeSuccess: 1
        )
        let viewModel = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        await viewModel.refresh()
        viewModel.baseURL = "https://replacement.example.invalid/v1"
        viewModel.model = "replacement-model"
        viewModel.credentialDraft = replacementCredential

        await viewModel.saveProfile()

        let coreProfiles = try await client.listProviderProfiles()
        let coreSettings = try await client.getSettings()
        let storedCredential = try await credentials.credential(
            for: profile.id
        )
        XCTAssertEqual(coreProfiles, [profile])
        XCTAssertEqual(viewModel.profiles, [profile])
        XCTAssertEqual(coreSettings.selectedProviderProfileID, profile.id)
        XCTAssertEqual(viewModel.selectedProfileID, profile.id)
        XCTAssertEqual(store.selectedProfileID, profile.id)
        XCTAssertTrue(storedCredential == oldCredential)
        XCTAssertEqual(viewModel.credentialDraft, replacementCredential)
        XCTAssertFalse(
            viewModel.errorMessage?.contains(replacementCredential)
                == true
        )
        XCTAssertFalse(
            viewModel.statusMessage?.contains(replacementCredential)
                == true
        )
    }

    func testSettingsChangesEndpointOnlyWhileCredentialIsAbsent() async throws {
        let profile = providerSelectionFixtures()[0]
        let oldCredential = "synthetic-old-endpoint-key"
        let newCredential = "synthetic-new-endpoint-key"
        let newBaseURL = "https://replacement.example.invalid/v1"
        let client = FakeCoreClient(profiles: [profile])
        let credentials = ScriptedCredentialStore(
            values: [profile.id: oldCredential],
            setDelay: .milliseconds(120),
            deleteDelay: .milliseconds(120)
        )
        let viewModel = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview
        )
        await viewModel.refresh()
        viewModel.baseURL = newBaseURL
        viewModel.credentialDraft = newCredential

        let save = Task {
            await viewModel.saveProfile()
        }
        await waitUntil {
            await credentials.deleteCallCount() == 1
        }

        let profileDuringCredentialDeletion =
            try await client.listProviderProfiles().first
        let credentialDuringDeletion =
            try await credentials.credential(for: profile.id)
        XCTAssertEqual(profileDuringCredentialDeletion?.baseURL, profile.baseURL)
        XCTAssertEqual(credentialDuringDeletion, oldCredential)

        await waitUntil {
            let upsertCount =
                await client.providerUpsertInvocationCountForTesting()
            let setCount = await credentials.setCallCount()
            return upsertCount == 1 && setCount == 1
        }
        let profileDuringCredentialWrite =
            try await client.listProviderProfiles().first
        let credentialDuringWrite =
            try await credentials.credential(for: profile.id)
        XCTAssertEqual(profileDuringCredentialWrite?.baseURL, newBaseURL)
        XCTAssertNil(credentialDuringWrite)

        await save.value

        let savedCredential =
            try await credentials.credential(for: profile.id)
        let savedProfile = try await client.listProviderProfiles().first
        XCTAssertEqual(savedCredential, newCredential)
        XCTAssertEqual(savedProfile?.baseURL, newBaseURL)
    }

    func testSettingsPreservesOtherSelectionWhenProfileAndCredentialRollbackFail() async throws {
        let profiles = providerSelectionFixtures()
        let rawDetail =
            "synthetic-secret-canary operation_id=rollback-operation-42"
        let store = ProviderConfigurationStore()
        let client = FakeCoreClient(
            profiles: profiles,
            testingOptions: FakeCoreClientTestingOptions(
                upsertProviderProfileFailure: .invalidResponse(rawDetail),
                upsertProviderFailureInvocations: [2]
            )
        )
        let credentials = ScriptedCredentialStore(
            values: [
                "compact": "synthetic-compact-key",
                "pro": "synthetic-pro-old-key",
            ],
            setFailuresBeforeSuccess: 1
        )
        let viewModel = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        await viewModel.refresh()
        await viewModel.editProfile(id: "pro")
        viewModel.model = "lore-pro-updated"
        viewModel.credentialDraft = "synthetic-pro-new-key"

        await viewModel.saveProfile()

        let coreSettings = try await client.getSettings()
        let coreProfiles = try await client.listProviderProfiles()
        XCTAssertEqual(coreSettings.selectedProviderProfileID, "compact")
        XCTAssertEqual(viewModel.selectedProfileID, "compact")
        XCTAssertEqual(store.selectedProfileID, "compact")
        XCTAssertEqual(
            coreProfiles.first(where: { $0.id == "pro" })?.model,
            "lore-pro-updated"
        )
        XCTAssertFalse(viewModel.errorMessage?.contains("operation_id") == true)
        XCTAssertFalse(viewModel.statusMessage?.contains("operation_id") == true)
        XCTAssertFalse(
            viewModel.errorMessage?.contains("synthetic-secret-canary")
                == true
        )
    }

    func testSettingsSerializesConcurrentProfileSaves() async throws {
        let client = FakeCoreClient(
            profiles: [],
            updateSettingsDelay: .milliseconds(80)
        )
        let credentials = ScriptedCredentialStore(
            setDelay: .milliseconds(80)
        )
        let viewModel = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview
        )
        viewModel.beginNewProfile()
        viewModel.profileName = "First Save"
        viewModel.baseURL = "https://example.invalid/v1"
        viewModel.model = "synthetic-first"
        viewModel.timeoutSeconds = "15"
        viewModel.credentialDraft = "synthetic-first-key"

        let firstSave = Task {
            await viewModel.saveProfile()
        }
        for _ in 0 ..< 100 where !viewModel.isLoading {
            await Task.yield()
        }
        XCTAssertTrue(viewModel.isLoading)

        viewModel.profileName = "Second Save"
        viewModel.model = "synthetic-second"
        viewModel.credentialDraft = "synthetic-second-key"
        await viewModel.saveProfile()
        await firstSave.value

        let profile = try XCTUnwrap(viewModel.profiles.first)
        XCTAssertEqual(viewModel.profiles.count, 1)
        XCTAssertEqual(profile.displayName, "First Save")
        XCTAssertEqual(profile.model, "synthetic-first")
        let setCallCount = await credentials.setCallCount()
        XCTAssertEqual(setCallCount, 1)
    }

    func testSharedProviderConfigurationStaysInSyncBothDirections() async throws {
        let profiles = providerSelectionFixtures()
        let client = FakeCoreClient(profiles: profiles)
        let store = ProviderConfigurationStore()
        let credentials = InMemoryCredentialStore()
        let settings = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        let chat = ChatViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store,
            automaticallyPollEvents: false
        )
        await chat.setCharacter(LibraryCharacter.previewCharacters[0])
        await settings.refresh()
        await chat.refreshProviderSelection()
        let initialRevision = store.revision

        await settings.selectProfile(id: "pro")
        await waitUntil {
            chat.selectedProviderProfileID == "pro"
        }

        XCTAssertEqual(store.selectedProfileID, "pro")
        XCTAssertEqual(chat.selectedProviderProfile?.model, "lore-pro")
        XCTAssertGreaterThan(store.revision, initialRevision)
        let settingsRevision = store.revision

        await chat.selectProviderProfile(id: "compact")
        await waitUntil {
            settings.selectedProfileID == "compact"
                && settings.model == "lore-compact"
        }

        XCTAssertEqual(store.selectedProfileID, "compact")
        XCTAssertEqual(settings.selectedProfileID, "compact")
        XCTAssertEqual(settings.model, "lore-compact")
        XCTAssertGreaterThan(store.revision, settingsRevision)
    }

    func testConcurrentPreserveAndProviderSelectionKeepBothSettingsFields() async throws {
        let profiles = providerSelectionFixtures()
        let client = FakeCoreClient(
            profiles: profiles,
            updateSettingsDelay: .milliseconds(80)
        )
        let store = ProviderConfigurationStore()
        let credentials = InMemoryCredentialStore()
        let settings = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        let chat = ChatViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store,
            automaticallyPollEvents: false
        )
        await chat.setCharacter(LibraryCharacter.previewCharacters[0])
        await settings.refresh()
        await chat.refreshProviderSelection()

        let selection = Task {
            await chat.selectProviderProfile(id: "pro")
        }
        await waitUntil {
            chat.isChangingProviderProfile
        }
        let preserve = Task {
            await settings.setPreservePartialGenerations(false)
        }
        await selection.value
        await preserve.value

        let persisted = try await client.getSettings()
        XCTAssertFalse(persisted.preservePartialGenerations)
        XCTAssertEqual(persisted.selectedProviderProfileID, "pro")
    }

    func testSettingsPreservesDirtyEditorWhenSharedSelectionChanges() async {
        let profiles = providerSelectionFixtures()
        let store = ProviderConfigurationStore()
        let credentials = ScriptedCredentialStore()
        let viewModel = SettingsViewModel(
            client: FakeCoreClient(profiles: profiles),
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        await viewModel.refresh()
        let readsBeforeChange = await credentials.readCallCount()
        viewModel.profileName = "저장하지 않은 이름"
        viewModel.baseURL = "https://draft.example.invalid/v1"
        viewModel.model = "draft-model"
        viewModel.timeoutSeconds = "123"
        viewModel.credentialDraft = "synthetic-unsaved-draft"

        store.replace(
            profiles: profiles,
            selectedProfileID: "pro"
        )
        await waitUntil {
            viewModel.selectedProfileID == "pro"
        }

        XCTAssertEqual(viewModel.profileName, "저장하지 않은 이름")
        XCTAssertEqual(
            viewModel.baseURL,
            "https://draft.example.invalid/v1"
        )
        XCTAssertEqual(viewModel.model, "draft-model")
        XCTAssertEqual(viewModel.timeoutSeconds, "123")
        XCTAssertEqual(
            viewModel.credentialDraft,
            "synthetic-unsaved-draft"
        )
        let readsAfterChange = await credentials.readCallCount()
        XCTAssertEqual(readsAfterChange, readsBeforeChange)
    }

    func testSettingsBlockedProfileActionOpensEditorWithoutSelectingIt() async {
        let profiles = providerSelectionFixtures()
        let store = ProviderConfigurationStore(
            quarantinedProfileIDs: ["pro"]
        )
        let client = FakeCoreClient(profiles: profiles)
        let viewModel = SettingsViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        await viewModel.refresh()

        await viewModel.selectProfile(id: "pro")

        let persisted = try? await client.getSettings()
        XCTAssertEqual(persisted?.selectedProviderProfileID, "compact")
        XCTAssertEqual(viewModel.selectedProfileID, "compact")
        XCTAssertEqual(viewModel.profileName, "Pro")
        XCTAssertEqual(viewModel.model, "lore-pro")
        XCTAssertTrue(viewModel.isEditingStoredProfile)
        XCTAssertTrue(viewModel.requiresCredentialRecovery)
    }

    func testSettingsAdoptsTheLatestSharedStoreRevisionDuringCredentialRead() async {
        let profiles = providerSelectionFixtures()
        let store = ProviderConfigurationStore()
        let credentials = ScriptedCredentialStore(
            values: ["compact": "synthetic-compact-key"],
            readDelay: .milliseconds(80)
        )
        let viewModel = SettingsViewModel(
            client: FakeCoreClient(profiles: profiles),
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        await viewModel.refresh()

        store.replace(
            profiles: profiles,
            selectedProfileID: "pro"
        )
        await waitUntil {
            viewModel.isLoading
                && viewModel.selectedProfileID == "pro"
        }
        store.replace(
            profiles: profiles,
            selectedProfileID: "compact"
        )
        await waitUntil(timeout: .seconds(3)) {
            !viewModel.isLoading
                && viewModel.selectedProfileID == "compact"
                && viewModel.model == "lore-compact"
                && viewModel.isCredentialStateKnown
                && viewModel.hasStoredCredential
        }

        XCTAssertEqual(viewModel.selectedProfileID, "compact")
        XCTAssertEqual(viewModel.model, "lore-compact")
        XCTAssertTrue(viewModel.credentialDraft.isEmpty)
        XCTAssertTrue(viewModel.hasStoredCredential)
    }

    func testSettingsUnknownCredentialStateUsesNeutralStatusCopy() async {
        let profile = providerSelectionFixtures()[0]
        let secret = "synthetic-status-canary"
        let credentials = ScriptedCredentialStore(
            values: [profile.id: secret],
            readFailuresBeforeSuccess: 1
        )
        let viewModel = SettingsViewModel(
            client: FakeCoreClient(profiles: [profile]),
            credentialStore: credentials,
            runtimeMode: .preview
        )

        await viewModel.refresh()
        viewModel.credentialDraft = "replacement"

        XCTAssertFalse(viewModel.isCredentialStateKnown)
        XCTAssertFalse(viewModel.credentialStatusDescription.contains("추가"))
        XCTAssertFalse(viewModel.credentialStatusDescription.contains("교체"))
        XCTAssertFalse(viewModel.credentialStatusDescription.contains(secret))
    }

    func testSettingsCoreProfileRejectionHidesRawDetailAndCredential() async {
        let secret = "synthetic-secret-canary"
        let rawDetail =
            "\(secret) operation_id=settings-operation-42 internal-detail"
        let client = FakeCoreClient(
            profiles: [],
            testingOptions: FakeCoreClientTestingOptions(
                upsertProviderProfileFailure: .invalidResponse(rawDetail)
            )
        )
        let viewModel = SettingsViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview
        )
        viewModel.beginNewProfile()
        viewModel.profileName = String(repeating: "x", count: 257)
        viewModel.baseURL = "https://example.invalid/v1"
        viewModel.model = "synthetic"
        viewModel.timeoutSeconds = "15"
        viewModel.credentialDraft = secret

        await viewModel.saveProfile()

        XCTAssertTrue(viewModel.profiles.isEmpty)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.errorMessage?.contains(secret) == true)
        XCTAssertFalse(viewModel.errorMessage?.contains("operation_id") == true)
        XCTAssertFalse(viewModel.errorMessage?.contains("internal-detail") == true)
        XCTAssertFalse(viewModel.statusMessage?.contains(secret) == true)
    }

    func testChatNoProfilePreflightPreservesDraftAndSkipsCoreSend() async {
        let client = FakeCoreClient(profiles: [])
        let viewModel = ChatViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )
        await viewModel.setCharacter(LibraryCharacter.previewCharacters[0])
        viewModel.draft = "  프로필 없음 원문  "

        await viewModel.submitMessage()

        XCTAssertEqual(viewModel.draft, "  프로필 없음 원문  ")
        XCTAssertEqual(
            viewModel.errorMessage,
            "프로바이더 프로필이 없습니다. 프로바이더 설정에서 추가하세요."
        )
        XCTAssertFalse(viewModel.canSubmit)
        let requests = await client.providerSendRequestsForTesting()
        XCTAssertTrue(requests.isEmpty)
    }

    func testChatMissingSelectionPreflightPreservesDraftAndSkipsCoreSend() async throws {
        let profiles = providerSelectionFixtures()
        let client = FakeCoreClient(profiles: profiles)
        _ = try await client.updateSettings(
            CoreAppSettings(
                preservePartialGenerations: true,
                selectedProviderProfileID: nil
            )
        )
        let viewModel = ChatViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )
        await viewModel.setCharacter(LibraryCharacter.previewCharacters[0])
        viewModel.draft = "  선택 없음 원문  "

        await viewModel.submitMessage()

        XCTAssertEqual(viewModel.draft, "  선택 없음 원문  ")
        XCTAssertEqual(
            viewModel.errorMessage,
            "기본 프로바이더가 선택되지 않았습니다. 프로바이더 설정에서 선택하세요."
        )
        XCTAssertFalse(viewModel.canSubmit)
        let requests = await client.providerSendRequestsForTesting()
        XCTAssertTrue(requests.isEmpty)
    }

    func testChatDanglingSelectionPreflightPreservesDraftAndSkipsCoreSend() async throws {
        let client = FakeCoreClient(profiles: providerSelectionFixtures())
        _ = try await client.updateSettings(
            CoreAppSettings(
                preservePartialGenerations: true,
                selectedProviderProfileID: "missing-profile"
            )
        )
        let viewModel = ChatViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )
        await viewModel.setCharacter(LibraryCharacter.previewCharacters[0])
        viewModel.draft = "  잘못된 선택 원문  "

        await viewModel.submitMessage()

        XCTAssertEqual(viewModel.draft, "  잘못된 선택 원문  ")
        XCTAssertEqual(
            viewModel.errorMessage,
            "선택된 프로바이더를 찾을 수 없습니다. 프로바이더 설정에서 다시 선택하세요."
        )
        XCTAssertFalse(viewModel.canSubmit)
        let requests = await client.providerSendRequestsForTesting()
        XCTAssertTrue(requests.isEmpty)
    }

    func testChatCredentialReadFailurePreservesDraftAndSkipsCoreSend() async {
        let client = FakeCoreClient(profiles: providerSelectionFixtures())
        let credentials = ScriptedCredentialStore(
            readFailuresBeforeSuccess: 1
        )
        let viewModel = ChatViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )
        await viewModel.setCharacter(LibraryCharacter.previewCharacters[0])
        viewModel.draft = "  Keychain 실패 원문  "

        await viewModel.submitMessage()

        XCTAssertEqual(viewModel.draft, "  Keychain 실패 원문  ")
        XCTAssertEqual(
            viewModel.errorMessage,
            "저장된 자격 증명을 불러오지 못했습니다. 프로바이더 설정에서 다시 저장하세요."
        )
        XCTAssertFalse(viewModel.canSubmit)
        let requests = await client.providerSendRequestsForTesting()
        XCTAssertTrue(requests.isEmpty)
    }

    func testChatLockedKeychainPreservesDraftAndHidesOSStatus() async {
        let client = FakeCoreClient(profiles: providerSelectionFixtures())
        let viewModel = ChatViewModel(
            client: client,
            credentialStore: LockedCredentialStore(),
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )
        await viewModel.setCharacter(LibraryCharacter.previewCharacters[0])
        let exactDraft = "  잠긴 Keychain 원문  "
        viewModel.draft = exactDraft

        await viewModel.submitMessage()

        XCTAssertEqual(viewModel.draft, exactDraft)
        XCTAssertEqual(
            viewModel.errorMessage,
            "저장된 자격 증명을 불러오지 못했습니다. 프로바이더 설정에서 다시 저장하세요."
        )
        XCTAssertFalse(
            viewModel.errorMessage?.contains(
                String(errSecInteractionNotAllowed)
            ) == true
        )
        XCTAssertFalse(viewModel.canSubmit)
        let requests = await client.providerSendRequestsForTesting()
        XCTAssertTrue(requests.isEmpty)
    }

    func testChatSelectionChangeDuringCredentialReadSkipsStaleCoreSend() async throws {
        let profiles = providerSelectionFixtures()
        let client = FakeCoreClient(profiles: profiles)
        let store = ProviderConfigurationStore()
        let credentials = ScriptedCredentialStore(
            values: [
                "compact": "synthetic-compact-key",
                "pro": "synthetic-pro-key",
            ],
            readDelay: .milliseconds(80)
        )
        let viewModel = ChatViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store,
            automaticallyPollEvents: false
        )
        await viewModel.setCharacter(LibraryCharacter.previewCharacters[0])
        await viewModel.refreshProviderSelection()
        let exactDraft = "  선택 변경 중 보낼 원문  "
        viewModel.draft = exactDraft
        let readsBeforeSubmission = await credentials.readCallCount()

        let submission = Task {
            await viewModel.submitMessage()
        }
        await waitUntil {
            await credentials.readCallCount() > readsBeforeSubmission
        }
        _ = try await client.updateSettings(
            CoreAppSettings(
                preservePartialGenerations: true,
                selectedProviderProfileID: "pro"
            )
        )
        store.replace(
            profiles: profiles,
            selectedProfileID: "pro"
        )
        await submission.value

        XCTAssertEqual(viewModel.draft, exactDraft)
        XCTAssertEqual(viewModel.selectedProviderProfileID, "pro")
        let requests = await client.providerSendRequestsForTesting()
        XCTAssertTrue(requests.isEmpty)
    }

    func testSettingsClearCredentialDuringChatPreflightInvalidatesSend() async throws {
        let profile = providerSelectionFixtures()[0]
        let store = ProviderConfigurationStore()
        let client = FakeCoreClient(profiles: [profile])
        let credentials = ScriptedCredentialStore(
            values: [profile.id: "synthetic-selected-key"],
            readDelay: .milliseconds(80)
        )
        let settings = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        let chat = ChatViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store,
            automaticallyPollEvents: false
        )
        await chat.setCharacter(LibraryCharacter.previewCharacters[0])
        await settings.refresh()
        await chat.refreshProviderSelection()
        let exactDraft = " \n Keychain 삭제 경쟁 원문 \t "
        chat.draft = exactDraft
        let readsBeforeSubmission = await credentials.readCallCount()

        let submission = Task {
            await chat.submitMessage()
        }
        await waitUntil {
            await credentials.readCallCount() > readsBeforeSubmission
        }
        await settings.clearCredential()
        await submission.value

        let storedCredential = try await credentials.credential(
            for: profile.id
        )
        let requests = await client.providerSendRequestsForTesting()
        XCTAssertNil(storedCredential)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(chat.draft, exactDraft)
        XCTAssertFalse(store.isQuarantined(profileID: profile.id))
    }

    func testChatCannotSelectAProfileWhileSettingsReplacesItsCredential() async throws {
        let profiles = providerSelectionFixtures()
        let store = ProviderConfigurationStore()
        let client = FakeCoreClient(profiles: profiles)
        let credentials = ScriptedCredentialStore(
            values: [
                "compact": "synthetic-compact-key",
                "pro": "synthetic-pro-key",
            ],
            setDelay: .milliseconds(500)
        )
        let settings = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        let chat = ChatViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store,
            automaticallyPollEvents: false
        )
        await chat.setCharacter(LibraryCharacter.previewCharacters[0])
        await settings.refresh()
        await chat.refreshProviderSelection()
        await settings.editProfile(id: "pro")
        settings.credentialDraft = "synthetic-pro-replacement"

        let save = Task {
            await settings.saveProfile()
        }
        await waitUntil(timeout: .seconds(3)) {
            settings.isLoading
                && store.isBlocked(profileID: "pro")
        }
        await chat.selectProviderProfile(id: "pro")

        let settingsWhileBlocked = try await client.getSettings()
        let updateCountWhileBlocked =
            await client.updateSettingsInvocationCountForTesting()
        let requestsWhileBlocked =
            await client.providerSendRequestsForTesting()
        XCTAssertEqual(
            settingsWhileBlocked.selectedProviderProfileID,
            "compact"
        )
        XCTAssertEqual(chat.selectedProviderProfileID, "compact")
        XCTAssertEqual(updateCountWhileBlocked, 0)
        XCTAssertTrue(requestsWhileBlocked.isEmpty)
        XCTAssertTrue(store.isBlocked(profileID: "pro"))

        await save.value
        await waitUntil {
            !store.isBlocked(profileID: "pro")
                && chat.selectedProviderProfileID == "pro"
        }

        XCTAssertFalse(store.isBlocked(profileID: "pro"))
        let settingsAfterSave = try await client.getSettings()
        XCTAssertEqual(settingsAfterSave.selectedProviderProfileID, "pro")
    }

    func testChatIsBlockedWhenProviderMutationStartedBeforeAccess() async throws {
        let profiles = providerSelectionFixtures()
        let store = ProviderConfigurationStore()
        let client = FakeCoreClient(profiles: profiles)
        let chat = ChatViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            providerConfigurationStore: store,
            automaticallyPollEvents: false
        )
        await chat.setCharacter(LibraryCharacter.previewCharacters[0])
        await chat.refreshProviderSelection()
        let exactDraft = "  mutation 이전 시작 원문  "
        chat.draft = exactDraft

        store.beginMutation(profileID: "compact")

        XCTAssertFalse(chat.canSubmit)
        await chat.submitMessage()
        let blockedSubmitRequests =
            await client.providerSendRequestsForTesting()
        XCTAssertTrue(blockedSubmitRequests.isEmpty)
        XCTAssertEqual(chat.draft, exactDraft)

        store.endMutation(profileID: "compact")
        store.beginMutation(profileID: "pro")
        await chat.selectProviderProfile(id: "pro")

        let coreSettings = try await client.getSettings()
        let updateCount =
            await client.updateSettingsInvocationCountForTesting()
        XCTAssertEqual(coreSettings.selectedProviderProfileID, "compact")
        XCTAssertEqual(chat.selectedProviderProfileID, "compact")
        XCTAssertEqual(updateCount, 0)

        store.endMutation(profileID: "pro")
    }

    func testSettingsCredentialReadFailureRecoversByReplacingTheCredential() async throws {
        let profile = providerSelectionFixtures()[0]
        let store = ProviderConfigurationStore()
        let credentials = ScriptedCredentialStore(
            values: [profile.id: "synthetic-existing-key"]
        )
        let client = FakeCoreClient(profiles: [profile])
        let settings = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        await settings.refresh()
        await credentials.failNextReads(1)
        settings.credentialDraft = "synthetic-replacement-key"

        await settings.saveProfile()

        let upsertCount =
            await client.providerUpsertInvocationCountForTesting()
        let updateCount =
            await client.updateSettingsInvocationCountForTesting()
        let setCount = await credentials.setCallCount()
        let deleteCount = await credentials.deleteCallCount()
        let storedCredential = try await credentials.credential(
            for: profile.id
        )
        XCTAssertFalse(store.isBlocked(profileID: profile.id))
        XCTAssertFalse(
            store.mutatingProfileIDs.contains(profile.id)
        )
        XCTAssertFalse(store.isQuarantined(profileID: profile.id))
        XCTAssertEqual(upsertCount, 1)
        XCTAssertEqual(updateCount, 2)
        XCTAssertEqual(setCount, 1)
        XCTAssertEqual(deleteCount, 1)
        XCTAssertEqual(storedCredential, "synthetic-replacement-key")
        XCTAssertFalse(
            settings.errorMessage?.contains("synthetic-secret-canary")
                == true
        )

        let chat = ChatViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store,
            automaticallyPollEvents: false
        )
        await chat.setCharacter(LibraryCharacter.previewCharacters[0])
        chat.draft = "mutation release"
        await chat.refreshProviderSelection()
        XCTAssertTrue(chat.canSubmit)
    }

    func testSettingsProfileDeleteCredentialReadFailureForceDeletesSafely() async throws {
        for wasQuarantined in [false, true] {
            let profile = providerSelectionFixtures()[0]
            let store = ProviderConfigurationStore(
                quarantinedProfileIDs:
                    wasQuarantined ? [profile.id] : []
            )
            let credentials = ScriptedCredentialStore(
                values: [profile.id: "synthetic-existing-key"]
            )
            let client = FakeCoreClient(profiles: [profile])
            let settings = SettingsViewModel(
                client: client,
                credentialStore: credentials,
                runtimeMode: .preview,
                providerConfigurationStore: store
            )
            await settings.refresh()
            await credentials.failNextReads(1)

            await settings.deleteEditingProfile()

            let coreSettings = try await client.getSettings()
            let deleteCount =
                await client.providerDeleteInvocationCountForTesting()
            let updateCount =
                await client.updateSettingsInvocationCountForTesting()
            let credentialDeleteCount =
                await credentials.deleteCallCount()
            XCTAssertNil(coreSettings.selectedProviderProfileID)
            XCTAssertEqual(deleteCount, 1)
            XCTAssertEqual(updateCount, 1)
            XCTAssertEqual(credentialDeleteCount, 1)
            XCTAssertFalse(
                store.mutatingProfileIDs.contains(profile.id)
            )
            XCTAssertFalse(store.isQuarantined(profileID: profile.id))
            XCTAssertTrue(settings.profiles.isEmpty)
        }
    }

    func testSettingsPersistsDeselectBeforeClearingSelectedCredential() async throws {
        let profile = providerSelectionFixtures()[0]
        let storedCredential = "synthetic-clear-order-key"
        let client = FakeCoreClient(profiles: [profile])
        let credentials = ScriptedCredentialStore(
            values: [profile.id: storedCredential],
            deleteDelay: .milliseconds(150)
        )
        let settings = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview
        )
        await settings.refresh()

        let clear = Task {
            await settings.clearCredential()
        }
        await waitUntil {
            await credentials.deleteCallCount() == 1
        }

        let coreSettingsDuringDelete = try await client.getSettings()
        let credentialDuringDelete =
            try await credentials.credential(for: profile.id)
        XCTAssertNil(coreSettingsDuringDelete.selectedProviderProfileID)
        XCTAssertEqual(credentialDuringDelete, storedCredential)
        await clear.value

        let coreSettingsAfterClear = try await client.getSettings()
        let credentialAfterClear =
            try await credentials.credential(for: profile.id)
        XCTAssertEqual(
            coreSettingsAfterClear.selectedProviderProfileID,
            profile.id
        )
        XCTAssertNil(credentialAfterClear)
    }

    func testSettingsClearPreDeselectFailureLeavesCredentialUntouched() async throws {
        let profile = providerSelectionFixtures()[0]
        let storedCredential = "synthetic-clear-deselect-key"
        let rawDetail =
            "synthetic-secret-canary operation_id=clear-deselect-42"
        let client = FakeCoreClient(
            profiles: [profile],
            testingOptions: FakeCoreClientTestingOptions(
                updateSettingsFailure: .invalidResponse(rawDetail),
                updateSettingsFailureInvocations: [1]
            )
        )
        let credentials = ScriptedCredentialStore(
            values: [profile.id: storedCredential]
        )
        let store = ProviderConfigurationStore()
        let settings = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        await settings.refresh()

        await settings.clearCredential()

        let coreSettings = try await client.getSettings()
        let storedAfterFailure = try await credentials.credential(
            for: profile.id
        )
        let deleteCount = await credentials.deleteCallCount()
        XCTAssertEqual(
            coreSettings.selectedProviderProfileID,
            profile.id
        )
        XCTAssertEqual(storedAfterFailure, storedCredential)
        XCTAssertEqual(deleteCount, 0)
        XCTAssertFalse(store.isQuarantined(profileID: profile.id))
        XCTAssertFalse(
            store.mutatingProfileIDs.contains(profile.id)
        )
        XCTAssertFalse(settings.errorMessage?.contains(rawDetail) == true)
        XCTAssertFalse(settings.statusMessage?.contains(rawDetail) == true)
    }

    func testSettingsCredentialDeleteFailureWithKnownStoredKeyDoesNotCreateQuarantine() async throws {
        let profile = providerSelectionFixtures()[0]
        let store = ProviderConfigurationStore()
        let credentials = ScriptedCredentialStore(
            values: [profile.id: "synthetic-existing-key"],
            deleteFailuresBeforeSuccess: 1
        )
        let client = FakeCoreClient(profiles: [profile])
        let settings = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        await settings.refresh()

        await settings.clearCredential()

        XCTAssertFalse(store.isBlocked(profileID: profile.id))
        XCTAssertFalse(store.isQuarantined(profileID: profile.id))
        XCTAssertFalse(
            store.mutatingProfileIDs.contains(profile.id)
        )
        XCTAssertTrue(settings.isCredentialStateKnown)
        XCTAssertTrue(settings.hasStoredCredential)
        let storedCredential = try await credentials.credential(
            for: profile.id
        )
        XCTAssertEqual(
            storedCredential,
            "synthetic-existing-key"
        )
        let coreSettings = try await client.getSettings()
        XCTAssertEqual(
            coreSettings.selectedProviderProfileID,
            profile.id
        )
    }

    func testSettingsCredentialDeleteFailureWithUnknownReadBackQuarantinesProfile() async {
        let profile = providerSelectionFixtures()[0]
        let store = ProviderConfigurationStore()
        let credentials = ScriptedCredentialStore(
            values: [profile.id: "synthetic-existing-key"],
            readFailureInvocations: [3],
            deleteFailuresBeforeSuccess: 1
        )
        let client = FakeCoreClient(profiles: [profile])
        let settings = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        await settings.refresh()

        await settings.clearCredential()

        XCTAssertTrue(store.isQuarantined(profileID: profile.id))
        XCTAssertTrue(store.isBlocked(profileID: profile.id))
        XCTAssertFalse(
            store.mutatingProfileIDs.contains(profile.id)
        )
        XCTAssertFalse(settings.isCredentialStateKnown)

        let coreSettings = try? await client.getSettings()
        XCTAssertNil(coreSettings?.selectedProviderProfileID)
        let restartedStore = ProviderConfigurationStore()
        let restartedChat = ChatViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: restartedStore,
            automaticallyPollEvents: false
        )
        await restartedChat.setCharacter(
            LibraryCharacter.previewCharacters[0]
        )
        let exactDraft = "  clear unknown 재시작 원문  "
        restartedChat.draft = exactDraft
        await restartedChat.refreshProviderSelection()
        await restartedChat.submitMessage()

        let requests = await client.providerSendRequestsForTesting()
        XCTAssertTrue(restartedStore.quarantinedProfileIDs.isEmpty)
        XCTAssertNil(restartedChat.selectedProviderProfileID)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(restartedChat.draft, exactDraft)
    }

    func testSettingsFailedCredentialClearPreservesExistingQuarantineWhenKeyRemains() async {
        let profile = providerSelectionFixtures()[0]
        let store = ProviderConfigurationStore(
            quarantinedProfileIDs: [profile.id]
        )
        let credentials = ScriptedCredentialStore(
            values: [profile.id: "synthetic-existing-key"],
            deleteFailuresBeforeSuccess: 1
        )
        let client = FakeCoreClient(profiles: [profile])
        let settings = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        await settings.refresh()

        await settings.clearCredential()

        XCTAssertTrue(store.isQuarantined(profileID: profile.id))
        XCTAssertTrue(settings.isCredentialStateKnown)
        XCTAssertTrue(settings.hasStoredCredential)

        let coreSettings = try? await client.getSettings()
        XCTAssertNil(coreSettings?.selectedProviderProfileID)
        let restartedStore = ProviderConfigurationStore()
        let restartedChat = ChatViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: restartedStore,
            automaticallyPollEvents: false
        )
        await restartedChat.setCharacter(
            LibraryCharacter.previewCharacters[0]
        )
        restartedChat.draft = "prior quarantine clear restart"
        await restartedChat.refreshProviderSelection()
        await restartedChat.submitMessage()
        let requests = await client.providerSendRequestsForTesting()
        XCTAssertTrue(restartedStore.quarantinedProfileIDs.isEmpty)
        XCTAssertTrue(requests.isEmpty)
    }

    func testSettingsFailedCredentialClearRemovesExistingQuarantineWhenAbsenceIsConfirmed() async throws {
        let profile = providerSelectionFixtures()[0]
        let store = ProviderConfigurationStore(
            quarantinedProfileIDs: [profile.id]
        )
        let credentials = ScriptedCredentialStore(
            values: [profile.id: "synthetic-existing-key"],
            deleteFailuresBeforeSuccess: 1,
            deleteRemovesValueBeforeFailure: true
        )
        let client = FakeCoreClient(profiles: [profile])
        let settings = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        await settings.refresh()

        await settings.clearCredential()

        XCTAssertFalse(store.isQuarantined(profileID: profile.id))
        XCTAssertFalse(store.isBlocked(profileID: profile.id))
        XCTAssertTrue(settings.isCredentialStateKnown)
        XCTAssertFalse(settings.hasStoredCredential)
        let storedCredential = try await credentials.credential(
            for: profile.id
        )
        XCTAssertNil(storedCredential)
        let coreSettings = try await client.getSettings()
        XCTAssertEqual(
            coreSettings.selectedProviderProfileID,
            profile.id
        )
    }

    func testSettingsKeylessRecoveryClearsQuarantineAndAllowsChatSend() async {
        let profile = providerSelectionFixtures()[0]
        let store = ProviderConfigurationStore(
            quarantinedProfileIDs: [profile.id]
        )
        let client = FakeCoreClient(profiles: [profile])
        let credentials = ScriptedCredentialStore()
        let settings = SettingsViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        let chat = ChatViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store,
            automaticallyPollEvents: false
        )
        await settings.refresh()
        await chat.setCharacter(LibraryCharacter.previewCharacters[0])
        await chat.refreshProviderSelection()

        XCTAssertTrue(settings.requiresCredentialRecovery)
        XCTAssertFalse(chat.canSubmit)

        await settings.clearCredential()
        await waitUntil {
            !store.isBlocked(profileID: profile.id)
                && chat.selectedProviderProfileID == profile.id
        }
        chat.draft = "API 키 없는 로컬 프로바이더"

        XCTAssertFalse(settings.requiresCredentialRecovery)
        XCTAssertTrue(chat.canSubmit)
        await chat.submitMessage()

        let requests = await client.providerSendRequestsForTesting()
        let coreSettings = try? await client.getSettings()
        XCTAssertEqual(
            coreSettings?.selectedProviderProfileID,
            profile.id
        )
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.providerProfileID, profile.id)
        XCTAssertEqual(requests.first?.hasCredential, false)
    }

    func testChatImmediateCoreFailureRestoresExactDraftAndHidesRawDetail() async {
        let rawDetail =
            "synthetic-secret-canary operation_id=provider-operation-42"
        let client = FakeCoreClient(
            profiles: providerSelectionFixtures(),
            testingOptions: FakeCoreClientTestingOptions(
                sendMessageToBranchFailure: .invalidResponse(rawDetail)
            )
        )
        let viewModel = ChatViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )
        await viewModel.setCharacter(LibraryCharacter.previewCharacters[0])
        let exactDraft = " \n 전송 실패 원문 \t "
        viewModel.draft = exactDraft

        await viewModel.submitMessage()

        XCTAssertEqual(viewModel.draft, exactDraft)
        XCTAssertEqual(
            viewModel.errorMessage,
            "메시지를 보내지 못했습니다. 잠시 후 다시 시도하세요."
        )
        XCTAssertFalse(viewModel.errorMessage?.contains(rawDetail) == true)
        let requests = await client.providerSendRequestsForTesting()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.entryPoint, .branch)
        XCTAssertEqual(requests.first?.text, exactDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        ))
    }

    func testChatProviderErrorCodesUseSafeKoreanMessages() async throws {
        let cases: [(String, String)] = [
            (
                "provider_auth_failed",
                "인증에 실패했습니다. 프로바이더 설정에서 API 키를 확인하세요."
            ),
            (
                "provider_rate_limited",
                "요청 한도에 도달했습니다. 잠시 후 다시 시도하세요."
            ),
            (
                "network_unavailable",
                "네트워크에 연결할 수 없습니다. 연결 상태를 확인한 뒤 다시 시도하세요."
            ),
            (
                "provider_timeout",
                "프로바이더 응답 시간이 초과되었습니다. 잠시 후 다시 시도하세요."
            ),
            (
                "provider_unavailable",
                "프로바이더가 응답하지 않거나 시간이 초과되었습니다. 잠시 후 다시 시도하세요."
            ),
            (
                "synthetic_unknown",
                "응답 생성에 실패했습니다. 잠시 후 다시 시도하세요."
            ),
        ]
        let rawDetail =
            "synthetic-secret-canary operation_id=provider-event-42"

        for (errorCode, expectedMessage) in cases {
            let client = FakeCoreClient(
                profiles: providerSelectionFixtures()
            )
            let viewModel = ChatViewModel(
                client: client,
                credentialStore: InMemoryCredentialStore(),
                runtimeMode: .preview,
                automaticallyPollEvents: false
            )
            await viewModel.setCharacter(
                LibraryCharacter.previewCharacters[0]
            )
            let conversationID = try XCTUnwrap(
                viewModel.conversation?.id
            )
            let branchID = try XCTUnwrap(viewModel.activeBranchID)
            let generationID = "active-\(errorCode)"
            var assistant = ChatMessage(
                id: "assistant-\(errorCode)",
                conversationID: conversationID,
                role: .assistant,
                text: "부분 응답",
                status: .pending,
                generationID: generationID
            )
            await client.replaceMessagesForTesting(
                conversationID: conversationID,
                messages: [assistant]
            )
            await viewModel.refreshMessages()
            XCTAssertTrue(viewModel.isGenerating)
            assistant.status = .failed
            await client.replaceMessagesForTesting(
                conversationID: conversationID,
                messages: [assistant]
            )
            await client.enqueueEventBatch([
                ChatEvent(
                    generationID: generationID,
                    conversationID: conversationID,
                    branchID: branchID,
                    assistantMessageID: assistant.id,
                    sequence: 1,
                    kind: "generation_failed",
                    errorCode: errorCode,
                    errorMessage: rawDetail
                ),
            ])

            await viewModel.pollOnce()

            XCTAssertEqual(
                viewModel.errorMessage,
                expectedMessage,
                "Unexpected mapping for \(errorCode)"
            )
            XCTAssertFalse(
                viewModel.errorMessage?.contains(rawDetail) == true
            )
            XCTAssertFalse(viewModel.isGenerating)
        }
    }

    func testChatIgnoresLateFailureAfterGenerationFinishes() async throws {
        let client = FakeCoreClient(
            profiles: providerSelectionFixtures()
        )
        let viewModel = ChatViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )
        await viewModel.setCharacter(
            LibraryCharacter.previewCharacters[0]
        )
        let conversationID = try XCTUnwrap(
            viewModel.conversation?.id
        )
        let branchID = try XCTUnwrap(viewModel.activeBranchID)
        let generationID = "terminal-generation"
        var assistant = ChatMessage(
            id: "terminal-assistant",
            conversationID: conversationID,
            role: .assistant,
            text: "완료된 응답",
            status: .pending,
            generationID: generationID
        )
        await client.replaceMessagesForTesting(
            conversationID: conversationID,
            messages: [assistant]
        )
        await viewModel.refreshMessages()
        XCTAssertTrue(viewModel.isGenerating)

        assistant.status = .complete
        await client.replaceMessagesForTesting(
            conversationID: conversationID,
            messages: [assistant]
        )
        await client.enqueueEventBatch([
            ChatEvent(
                generationID: generationID,
                conversationID: conversationID,
                branchID: branchID,
                assistantMessageID: assistant.id,
                sequence: 1,
                kind: "generation_finished"
            ),
            ChatEvent(
                generationID: generationID,
                conversationID: conversationID,
                branchID: branchID,
                assistantMessageID: assistant.id,
                sequence: 2,
                kind: "generation_failed",
                errorCode: "provider_auth_failed",
                errorMessage: "synthetic-secret-canary"
            ),
        ])

        await viewModel.pollOnce()

        XCTAssertFalse(viewModel.isGenerating)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.messages, [assistant])
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

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition did not become true")
    }
}

private struct KeychainTestItem: Equatable {
    var data: Data
    var accessibility: String?
}

private final class ScriptedKeychainSecurityClient:
    KeychainSecurityClient,
    @unchecked Sendable
{
    private enum Namespace {
        case protected
        case legacy
    }

    private let lock = NSLock()
    private var protectedItem: KeychainTestItem?
    private var legacyItem: KeychainTestItem?
    private var updateStatuses: [OSStatus]
    private var copyFailureStatuses: [Int: OSStatus]
    private var copyCalls = 0
    private var protectedUpdateCalls = 0
    private var legacyDeleteCalls = 0

    init(
        protectedItem: KeychainTestItem? = nil,
        legacyItem: KeychainTestItem? = nil,
        updateStatuses: [OSStatus] = [],
        copyFailureStatuses: [Int: OSStatus] = [:]
    ) {
        self.protectedItem = protectedItem
        self.legacyItem = legacyItem
        self.updateStatuses = updateStatuses
        self.copyFailureStatuses = copyFailureStatuses
    }

    func copyMatching(_ query: [String: Any]) -> KeychainCopyResult {
        lock.withLock {
            copyCalls += 1
            if let status = copyFailureStatuses.removeValue(
                forKey: copyCalls
            ) {
                return KeychainCopyResult(status: status, data: nil)
            }

            guard let item = item(for: namespace(for: query)) else {
                return KeychainCopyResult(
                    status: errSecItemNotFound,
                    data: nil
                )
            }
            if let requiredAccessibility =
                query[kSecAttrAccessible as String] as? String,
               item.accessibility != requiredAccessibility
            {
                return KeychainCopyResult(
                    status: errSecItemNotFound,
                    data: nil
                )
            }
            return KeychainCopyResult(
                status: errSecSuccess,
                data: item.data
            )
        }
    }

    func update(
        _ query: [String: Any],
        attributes: [String: Any]
    ) -> OSStatus {
        lock.withLock {
            let namespace = namespace(for: query)
            if namespace == .protected {
                protectedUpdateCalls += 1
            }
            if !updateStatuses.isEmpty {
                let status = updateStatuses.removeFirst()
                if status != errSecSuccess {
                    return status
                }
            }

            guard var item = item(for: namespace) else {
                return errSecItemNotFound
            }
            if let data = attributes[kSecValueData as String] as? Data {
                item.data = data
            }
            if let accessibility =
                attributes[kSecAttrAccessible as String] as? String
            {
                item.accessibility = accessibility
            }
            setItem(item, for: namespace)
            return errSecSuccess
        }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            let namespace = namespace(for: attributes)
            guard item(for: namespace) == nil else {
                return errSecDuplicateItem
            }
            guard
                let data = attributes[kSecValueData as String] as? Data
            else {
                return errSecParam
            }
            let item = KeychainTestItem(
                data: data,
                accessibility:
                    attributes[kSecAttrAccessible as String] as? String
            )
            setItem(item, for: namespace)
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            let namespace = namespace(for: query)
            if namespace == .legacy {
                legacyDeleteCalls += 1
            }
            guard item(for: namespace) != nil else {
                return errSecItemNotFound
            }
            setItem(nil, for: namespace)
            return errSecSuccess
        }
    }

    func protectedItemSnapshot() -> KeychainTestItem? {
        lock.withLock {
            protectedItem
        }
    }

    func legacyItemSnapshot() -> KeychainTestItem? {
        lock.withLock {
            legacyItem
        }
    }

    func protectedUpdateCallCount() -> Int {
        lock.withLock {
            protectedUpdateCalls
        }
    }

    func legacyDeleteCallCount() -> Int {
        lock.withLock {
            legacyDeleteCalls
        }
    }

    private func namespace(
        for query: [String: Any]
    ) -> Namespace {
        query[kSecUseDataProtectionKeychain as String] as? Bool == false
            ? .legacy
            : .protected
    }

    private func item(for namespace: Namespace) -> KeychainTestItem? {
        switch namespace {
        case .protected:
            protectedItem
        case .legacy:
            legacyItem
        }
    }

    private func setItem(
        _ item: KeychainTestItem?,
        for namespace: Namespace
    ) {
        switch namespace {
        case .protected:
            protectedItem = item
        case .legacy:
            legacyItem = item
        }
    }
}

private enum SyntheticCredentialStoreFailure: Error, LocalizedError {
    case injected

    var errorDescription: String? {
        "synthetic-secret-canary operation_id=credential-operation-42"
    }
}

private actor ScriptedCredentialStore: CredentialStore {
    private var values: [String: String]
    private var readFailuresRemaining: UInt
    private var readFailureInvocations: Set<Int>
    private var setFailuresRemaining: UInt
    private var deleteFailuresRemaining: UInt
    private let readDelay: Duration?
    private let setDelay: Duration?
    private let deleteDelay: Duration?
    private let deleteRemovesValueBeforeFailure: Bool
    private var setCalls = 0
    private var readCalls = 0
    private var deleteCalls = 0

    init(
        values: [String: String] = [:],
        readFailuresBeforeSuccess: UInt = 0,
        readFailureInvocations: Set<Int> = [],
        setFailuresBeforeSuccess: UInt = 0,
        deleteFailuresBeforeSuccess: UInt = 0,
        readDelay: Duration? = nil,
        setDelay: Duration? = nil,
        deleteDelay: Duration? = nil,
        deleteRemovesValueBeforeFailure: Bool = false
    ) {
        self.values = values
        readFailuresRemaining = readFailuresBeforeSuccess
        self.readFailureInvocations = readFailureInvocations
        setFailuresRemaining = setFailuresBeforeSuccess
        deleteFailuresRemaining = deleteFailuresBeforeSuccess
        self.readDelay = readDelay
        self.setDelay = setDelay
        self.deleteDelay = deleteDelay
        self.deleteRemovesValueBeforeFailure =
            deleteRemovesValueBeforeFailure
    }

    func credential(for profileID: String) async throws -> String? {
        readCalls += 1
        if let readDelay {
            try await Task.sleep(for: readDelay)
        }
        if readFailureInvocations.contains(readCalls) {
            throw SyntheticCredentialStoreFailure.injected
        }
        if readFailuresRemaining > 0 {
            readFailuresRemaining -= 1
            throw SyntheticCredentialStoreFailure.injected
        }
        return values[profileID]
    }

    func setCredential(
        _ credential: String?,
        for profileID: String
    ) async throws {
        setCalls += 1
        if let setDelay {
            try await Task.sleep(for: setDelay)
        }
        if setFailuresRemaining > 0 {
            setFailuresRemaining -= 1
            throw SyntheticCredentialStoreFailure.injected
        }
        let normalized = credential?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if let normalized, !normalized.isEmpty {
            values[profileID] = normalized
        } else {
            values.removeValue(forKey: profileID)
        }
    }

    func deleteCredential(for profileID: String) async throws {
        deleteCalls += 1
        if let deleteDelay {
            try await Task.sleep(for: deleteDelay)
        }
        if deleteFailuresRemaining > 0 {
            deleteFailuresRemaining -= 1
            if deleteRemovesValueBeforeFailure {
                values.removeValue(forKey: profileID)
            }
            throw SyntheticCredentialStoreFailure.injected
        }
        values.removeValue(forKey: profileID)
    }

    func setCallCount() -> Int {
        setCalls
    }

    func readCallCount() -> Int {
        readCalls
    }

    func deleteCallCount() -> Int {
        deleteCalls
    }

    func failNextReads(_ count: UInt) {
        readFailuresRemaining += count
    }
}

private actor LockedCredentialStore: CredentialStore {
    func credential(for _: String) async throws -> String? {
        throw CredentialStoreError.keychainStatus(
            errSecInteractionNotAllowed
        )
    }

    func setCredential(
        _: String?,
        for _: String
    ) async throws {
        throw CredentialStoreError.keychainStatus(
            errSecInteractionNotAllowed
        )
    }

    func deleteCredential(for _: String) async throws {
        throw CredentialStoreError.keychainStatus(
            errSecInteractionNotAllowed
        )
    }
}
