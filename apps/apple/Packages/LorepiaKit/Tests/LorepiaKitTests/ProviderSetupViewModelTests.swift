import XCTest
@testable import LorepiaKit

@MainActor
final class ProviderSetupViewModelTests: XCTestCase {
    func testProviderSetupLoadsTemplateConnectionRouteAndPresetHierarchy()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertTrue(
            viewModel.templates.contains { $0.id == "openrouter-v1" }
        )
        XCTAssertEqual(
            viewModel.connections.map(\.id),
            ["preview-provider"],
            "The migrated connection must preserve the legacy profile ID."
        )
        XCTAssertEqual(
            viewModel.selectedConnectionID,
            "preview-provider"
        )
        XCTAssertEqual(
            viewModel.modelRoutes.map(\.modelID),
            ["preview-model"]
        )
        XCTAssertEqual(viewModel.modelRoutes.map(\.id), ["preview-provider"])
        XCTAssertEqual(viewModel.presets.map(\.displayName), ["기본"])
        XCTAssertEqual(viewModel.presets.map(\.id), ["preview-provider"])
        XCTAssertEqual(
            Set(viewModel.capabilities.map(\.selected.key)),
            ["streaming", "reasoning"]
        )
        XCTAssertEqual(
            viewModel.assistantModelRoutes.map(\.id),
            ["preview-provider"]
        )
        XCTAssertEqual(
            viewModel.selectedAssistantModelRouteID,
            "preview-provider"
        )
        XCTAssertEqual(
            viewModel.assistantRouteIdentity(
                routeID: "preview-provider"
            )?.provider,
            "Preview Provider"
        )
        XCTAssertTrue(viewModel.assistantRouteSelectionIsRunnable)
        XCTAssertNotNil(viewModel.requestPreview)
    }

    func testWebsiteDiscoveryWithoutExistingAssistantRouteStartsDeterministically()
        async throws
    {
        let client = FakeCoreClient(profiles: [])
        let credentials = InMemoryCredentialStore()
        let viewModel = makeViewModel(
            client: client,
            credentials: credentials
        )
        await viewModel.refresh()

        XCTAssertTrue(viewModel.assistantModelRoutes.isEmpty)
        XCTAssertNil(viewModel.selectedAssistantModelRouteID)
        viewModel.prepareDiscovery(method: .website)
        viewModel.discoveryDisplayName = "첫 웹사이트 연결"
        viewModel.discoveryURL =
            "https://docs.first-provider.invalid/api"
        viewModel.credentialDraft = "synthetic-first-provider-key"

        XCTAssertTrue(
            viewModel.canStartDiscovery,
            "Deterministic discovery must not require an existing assistant route."
        )
        await viewModel.startDiscovery()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(
            viewModel.discovery?.state,
            .awaitingMoreEvidence
        )
        XCTAssertEqual(
            viewModel.discovery?.actionRequired,
            .supplyMoreEvidence
        )
        XCTAssertFalse(viewModel.canRequestDiscoveryAssistant)
        XCTAssertTrue(
            viewModel.assistantRouteSelectionMessage?
                .contains("결정론적 문서 탐색") == true
        )
    }

    func testNonDefaultAssistantRouteFallsBackToDeterministicDiscovery()
        async throws
    {
        let profileA = ProviderProfile(
            id: "active-assistant-route",
            displayName: "Active Assistant",
            baseURL: "https://active-assistant.invalid/v1",
            model: "active-model",
            timeoutSeconds: 30
        )
        let profileB = ProviderProfile(
            id: "inactive-assistant-route",
            displayName: "Inactive Assistant",
            baseURL: "https://inactive-assistant.invalid/v1",
            model: "inactive-model",
            timeoutSeconds: 30
        )
        let targetA = ProviderGenerationTarget(
            modelRouteID: profileA.id,
            generationPresetID: profileA.id
        )
        let client = try FakeCoreClient(
            profiles: [profileA, profileB],
            initialSettings: CoreAppSettings(
                preservePartialGenerations: true,
                selectedProviderProfileID: nil,
                selectedModelRouteID: targetA.modelRouteID,
                selectedGenerationPresetID:
                    targetA.generationPresetID
            )
        )
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        viewModel.prepareDiscovery(method: .website)
        viewModel.selectAssistantModelRoute(id: profileB.id)
        viewModel.discoveryDisplayName = "비기본 route"
        viewModel.discoveryURL =
            "https://docs.nondefault-route.invalid/api"
        viewModel.credentialDraft = "synthetic-nondefault-key"

        XCTAssertFalse(viewModel.assistantRouteSelectionIsRunnable)
        XCTAssertTrue(viewModel.canStartDiscovery)
        await viewModel.startDiscovery()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(
            viewModel.discovery?.state,
            .awaitingMoreEvidence
        )
        XCTAssertFalse(viewModel.canRequestDiscoveryAssistant)
    }

    func testFreshSessionCanRequestItsFrozenRunnableAssistantRoute()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        viewModel.prepareDiscovery(method: .website)
        viewModel.discoveryDisplayName = "도우미 재요청"
        viewModel.discoveryURL =
            "https://docs.request-assistant.invalid/api"
        viewModel.credentialDraft = "synthetic-request-assistant-key"
        await viewModel.startDiscovery()
        guard case let .assistantConsent(initialConsent) =
            viewModel.discovery?.actionRequired
        else {
            return XCTFail("Expected initial assistant consent")
        }
        await viewModel.continueDiscovery(.declineAssistant)

        XCTAssertEqual(
            viewModel.discovery?.state,
            .awaitingMoreEvidence
        )
        XCTAssertTrue(viewModel.canRequestDiscoveryAssistant)
        await viewModel.requestDiscoveryAssistant()

        guard case let .assistantConsent(requestedConsent) =
            viewModel.discovery?.actionRequired
        else {
            return XCTFail("Expected requested assistant consent")
        }
        XCTAssertEqual(
            requestedConsent.assistantModelRouteID,
            initialConsent.assistantModelRouteID
        )
        XCTAssertTrue(
            viewModel.canApproveDiscoveryAssistant(
                requestedConsent
            )
        )
    }

    func testOlderRefreshCannotOverwriteNewerActiveGenerationSelection()
        async throws
    {
        let oldProfile = ProviderProfile(
            id: "old-refresh-connection",
            displayName: "Old Refresh Provider",
            baseURL: "https://old-refresh.example.invalid/v1",
            model: "old-refresh-model",
            timeoutSeconds: 30
        )
        let newProfile = ProviderProfile(
            id: "new-refresh-connection",
            displayName: "New Refresh Provider",
            baseURL: "https://new-refresh.example.invalid/v1",
            model: "new-refresh-model",
            timeoutSeconds: 30
        )
        let oldTarget = ProviderGenerationTarget(
            modelRouteID: oldProfile.id,
            generationPresetID: oldProfile.id
        )
        let newTarget = ProviderGenerationTarget(
            modelRouteID: newProfile.id,
            generationPresetID: newProfile.id
        )
        let client = try FakeCoreClient(
            profiles: [oldProfile, newProfile],
            initialSettings: CoreAppSettings(
                preservePartialGenerations: true,
                selectedProviderProfileID: nil,
                selectedModelRouteID: oldTarget.modelRouteID,
                selectedGenerationPresetID:
                    oldTarget.generationPresetID
            )
        )
        let store = ProviderConfigurationStore()
        let viewModel = ProviderSetupViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        let commitGate = ProviderSetupRefreshCommitGate()
        viewModel.setActiveGenerationSelectionCommitHookForTesting {
            await commitGate.arrive()
        }

        let staleRefresh = Task {
            await viewModel.refresh()
        }
        await commitGate.waitForArrival(1)

        let updatedSettings =
            try await client.selectProviderGenerationTarget(newTarget)
        XCTAssertEqual(
            updatedSettings.selectedGenerationTarget,
            newTarget
        )

        let newerRefresh = Task {
            await viewModel.refresh()
        }
        await commitGate.waitForArrival(2)
        await newerRefresh.value

        XCTAssertEqual(viewModel.activeGenerationTarget, newTarget)
        XCTAssertEqual(
            viewModel.selectedAssistantModelRouteID,
            newTarget.modelRouteID
        )
        XCTAssertEqual(store.selectedConnectionID, newProfile.id)
        XCTAssertEqual(store.selectedGenerationTarget, newTarget)

        await commitGate.releaseFirstArrival()
        await staleRefresh.value

        XCTAssertEqual(
            viewModel.activeGenerationTarget,
            newTarget,
            "A stale refresh must not commit its already-resolved target."
        )
        XCTAssertEqual(
            viewModel.selectedAssistantModelRouteID,
            newTarget.modelRouteID,
            "A stale refresh must not restore its older assistant route."
        )
        XCTAssertEqual(store.selectedConnectionID, newProfile.id)
        XCTAssertEqual(store.selectedGenerationTarget, newTarget)
        XCTAssertEqual(viewModel.loadState, .loaded)
        viewModel.setActiveGenerationSelectionCommitHookForTesting(nil)
    }

    func testOlderPostCommitRefreshCannotEnterNewerHydration()
        async throws
    {
        let oldProfile = ProviderProfile(
            id: "old-post-commit-connection",
            displayName: "Old Post Commit Provider",
            baseURL:
                "https://old-post-commit.example.invalid/v1",
            model: "old-post-commit-model",
            timeoutSeconds: 30
        )
        let newProfile = ProviderProfile(
            id: "new-post-commit-connection",
            displayName: "New Post Commit Provider",
            baseURL:
                "https://new-post-commit.example.invalid/v1",
            model: "new-post-commit-model",
            timeoutSeconds: 30
        )
        let oldTarget = ProviderGenerationTarget(
            modelRouteID: oldProfile.id,
            generationPresetID: oldProfile.id
        )
        let newTarget = ProviderGenerationTarget(
            modelRouteID: newProfile.id,
            generationPresetID: newProfile.id
        )
        let client = try FakeCoreClient(
            profiles: [oldProfile, newProfile],
            initialSettings: CoreAppSettings(
                preservePartialGenerations: true,
                selectedProviderProfileID: nil,
                selectedModelRouteID: oldTarget.modelRouteID,
                selectedGenerationPresetID:
                    oldTarget.generationPresetID
            )
        )
        let store = ProviderConfigurationStore()
        let viewModel = ProviderSetupViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        let postCommitGate = ProviderSetupRefreshCommitGate()
        let hydrationRecorder =
            ProviderSetupRefreshHydrationRecorder()
        viewModel.setRefreshPostCommitHookForTesting {
            await postCommitGate.arrive()
        }
        viewModel.setRefreshHydrationHookForTesting {
            await hydrationRecorder.record()
        }

        let staleRefresh = Task {
            await viewModel.refresh()
        }
        await postCommitGate.waitForArrival(1)
        _ = try await client.selectProviderGenerationTarget(
            newTarget
        )

        let newerRefresh = Task {
            await viewModel.refresh()
        }
        await postCommitGate.waitForArrival(2)
        await newerRefresh.value

        XCTAssertEqual(viewModel.activeGenerationTarget, newTarget)
        XCTAssertEqual(store.selectedConnectionID, newProfile.id)
        let hydrationCountAfterNewerRefresh =
            await hydrationRecorder.recordedCount()
        XCTAssertEqual(hydrationCountAfterNewerRefresh, 1)

        await postCommitGate.releaseFirstArrival()
        await staleRefresh.value

        XCTAssertEqual(viewModel.activeGenerationTarget, newTarget)
        XCTAssertEqual(store.selectedConnectionID, newProfile.id)
        XCTAssertEqual(store.selectedGenerationTarget, newTarget)
        let finalHydrationCount =
            await hydrationRecorder.recordedCount()
        XCTAssertEqual(
            finalHydrationCount,
            1,
            "A superseded post-commit refresh must not start hydration."
        )
        viewModel.setRefreshPostCommitHookForTesting(nil)
        viewModel.setRefreshHydrationHookForTesting(nil)
    }

    func testOlderModelSyncSnapshotCannotOverwriteSameJobCompletion()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        let job = try await client.startProviderModelSync(
            connectionID: "preview-provider",
            credential: nil
        )
        let snapshotGate = ProviderSetupRefreshCommitGate()
        viewModel.setModelSyncEventSnapshotCommitHookForTesting {
            await snapshotGate.arrive()
        }

        let staleRefresh = Task {
            await viewModel.refresh()
        }
        await snapshotGate.waitForArrival(1)
        XCTAssertEqual(viewModel.modelSyncJob?.id, job.id)

        await viewModel.approveModelSync()
        XCTAssertEqual(viewModel.modelSyncJob?.id, job.id)
        XCTAssertEqual(viewModel.modelSyncJob?.state, .completed)
        XCTAssertNil(viewModel.modelSyncEventMessageKey)

        let newerRefreshGate = ProviderSetupRefreshCommitGate()
        viewModel.setRefreshPostCommitHookForTesting {
            await newerRefreshGate.arrive()
        }
        let newerRefresh = Task {
            await viewModel.refresh()
        }
        await newerRefreshGate.waitForArrival(1)

        await snapshotGate.releaseFirstArrival()
        await staleRefresh.value

        XCTAssertEqual(viewModel.modelSyncJob?.id, job.id)
        XCTAssertEqual(
            viewModel.modelSyncJob?.state,
            .completed,
            "A stale same-job snapshot must not restore awaiting-review state."
        )
        XCTAssertNil(
            viewModel.modelSyncEventMessageKey,
            "A stale consumer must not publish its older event message."
        )

        await newerRefreshGate.releaseFirstArrival()
        await newerRefresh.value
        viewModel.setModelSyncEventSnapshotCommitHookForTesting(nil)
        viewModel.setRefreshPostCommitHookForTesting(nil)
    }

    func testOlderModelSyncPollFailureCannotOverwriteNewerRefresh()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        let job = try await client.startProviderModelSync(
            connectionID: "preview-provider",
            credential: nil
        )
        let pollFailureGate = ProviderSetupRefreshCommitGate()
        viewModel.setModelSyncEventPollHookForTesting {
            await pollFailureGate.arrive()
            throw CoreClientFailure.startupFailed(
                "synthetic stale model-sync poll failure"
            )
        }

        let staleRefresh = Task {
            await viewModel.refresh()
        }
        await pollFailureGate.waitForArrival(1)
        XCTAssertEqual(viewModel.modelSyncJob?.id, job.id)

        let newerRefreshGate = ProviderSetupRefreshCommitGate()
        viewModel.setRefreshPostCommitHookForTesting {
            await newerRefreshGate.arrive()
        }
        let newerRefresh = Task {
            await viewModel.refresh()
        }
        await newerRefreshGate.waitForArrival(1)

        await pollFailureGate.releaseFirstArrival()
        await staleRefresh.value

        XCTAssertEqual(viewModel.modelSyncJob?.id, job.id)
        XCTAssertEqual(viewModel.modelSyncJob?.state, .awaitingReview)
        XCTAssertNil(
            viewModel.errorMessage,
            "A stale same-job poll failure must not overwrite newer UI state."
        )

        viewModel.setModelSyncEventPollHookForTesting(nil)
        await newerRefreshGate.releaseFirstArrival()
        await newerRefresh.value
        viewModel.setRefreshPostCommitHookForTesting(nil)
    }

    func testOlderModelSyncSnapshotCannotRollbackCancellation()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        let job = try await client.startProviderModelSync(
            connectionID: "preview-provider",
            credential: nil
        )
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setModelSyncEventSnapshotCommitHookForTesting {
            await gate.arrive()
        }

        let staleRefresh = Task {
            await viewModel.refresh()
        }
        await gate.waitForArrival(1)
        XCTAssertEqual(viewModel.modelSyncJob?.id, job.id)

        await viewModel.cancelModelSync()
        let cancelledRevision = try XCTUnwrap(
            viewModel.modelSyncJob?.revision
        )
        XCTAssertEqual(viewModel.modelSyncJob?.state, .cancelled)

        await gate.releaseFirstArrival()
        await staleRefresh.value

        XCTAssertEqual(viewModel.modelSyncJob?.id, job.id)
        XCTAssertEqual(viewModel.modelSyncJob?.state, .cancelled)
        XCTAssertEqual(
            viewModel.modelSyncJob?.revision,
            cancelledRevision
        )
        viewModel.setModelSyncEventSnapshotCommitHookForTesting(nil)
    }

    func testStaleModelSyncStartCannotPublishAfterRefreshSelectsNewConnection()
        async throws
    {
        let firstProfile = ProviderProfile(
            id: "preview-provider",
            displayName: "Preview Provider",
            baseURL: "https://example.invalid/v1",
            model: "preview-model",
            timeoutSeconds: 30
        )
        let secondProfile = ProviderProfile(
            id: "sync-selection-provider",
            displayName: "Sync Selection Provider",
            baseURL: "https://sync-selection.example.invalid/v1",
            model: "sync-selection-model",
            timeoutSeconds: 30
        )
        let client = FakeCoreClient(
            profiles: [
                firstProfile,
                secondProfile,
            ]
        )
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setModelSyncOperationCommitHookForTesting {
            await gate.arrive()
        }

        let staleStart = Task {
            await viewModel.startModelSync()
        }
        await gate.waitForArrival(1)

        try await client.deleteProviderConnection(id: firstProfile.id)
        await viewModel.refresh()
        XCTAssertEqual(viewModel.selectedConnectionID, secondProfile.id)
        XCTAssertNil(viewModel.modelSyncJob)

        await gate.releaseFirstArrival()
        await staleStart.value

        XCTAssertEqual(viewModel.selectedConnectionID, secondProfile.id)
        XCTAssertNil(viewModel.modelSyncJob)
        XCTAssertNil(viewModel.errorMessage)
        viewModel.setModelSyncOperationCommitHookForTesting(nil)
    }

    func testModelSyncMutationRejectsMismatchedJobResponse()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        await viewModel.startModelSync()
        let original = try XCTUnwrap(viewModel.modelSyncJob)
        viewModel.setModelSyncResponseTransformForTesting { response in
            ProviderModelSyncJob(
                id: "mismatched-\(response.id)",
                connectionID: response.connectionID,
                state: response.state,
                revision: response.revision,
                completedSteps: response.completedSteps,
                totalSteps: response.totalSteps,
                reviewSHA256: response.reviewSHA256,
                diff: response.diff,
                failureMessageKey: response.failureMessageKey,
                updatedAt: response.updatedAt
            )
        }

        await viewModel.cancelModelSync()

        let durable = try await client.getProviderModelSync(
            jobID: original.id
        )
        XCTAssertEqual(viewModel.modelSyncJob, durable)
        XCTAssertEqual(viewModel.modelSyncJob?.state, .cancelled)
        XCTAssertTrue(
            viewModel.statusMessage?.contains("다시 확인") == true
        )
        XCTAssertNotNil(viewModel.errorMessage)
        viewModel.setModelSyncResponseTransformForTesting(nil)
    }

    func testOlderPreviewFailureCannotClearNewerSamePresetPreview()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        let gate = ProviderSetupOrdinalCommitGate()
        viewModel.setRequestPreviewCommitHookForTesting {
            let ordinal = await gate.arrive()
            if ordinal == 1 {
                throw CoreClientFailure.startupFailed(
                    "synthetic stale preview failure"
                )
            }
        }

        let stalePreview = Task {
            await viewModel.loadRequestPreview()
        }
        await gate.waitForArrival(1)

        let latestPreview = Task {
            await viewModel.loadRequestPreview()
        }
        await gate.waitForArrival(2)
        await latestPreview.value

        let expectedPreview = try XCTUnwrap(
            viewModel.currentRequestPreview
        )
        let expectedReasoning = try XCTUnwrap(
            viewModel.currentReasoningControl
        )
        let expectedCache = try XCTUnwrap(
            viewModel.currentPromptCacheControl
        )
        XCTAssertNil(viewModel.errorMessage)

        await gate.releaseFirstArrival()
        await stalePreview.value

        XCTAssertEqual(viewModel.currentRequestPreview, expectedPreview)
        XCTAssertEqual(viewModel.currentReasoningControl, expectedReasoning)
        XCTAssertEqual(viewModel.currentPromptCacheControl, expectedCache)
        XCTAssertNil(viewModel.errorMessage)
        viewModel.setRequestPreviewCommitHookForTesting(nil)
    }

    func testConnectionHydrationImmediatelyInvalidatesOldDescendants()
        async throws
    {
        let firstProfile = ProviderProfile(
            id: "preview-provider",
            displayName: "Preview Provider",
            baseURL: "https://example.invalid/v1",
            model: "preview-model",
            timeoutSeconds: 30
        )
        let secondProfile = ProviderProfile(
            id: "second-provider",
            displayName: "Second Provider",
            baseURL: "https://second.example.invalid/v1",
            model: "second-model",
            timeoutSeconds: 30
        )
        let client = FakeCoreClient(
            profiles: [
                firstProfile,
                secondProfile,
            ]
        )
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        let originalTarget =
            try await client.getSettings().selectedGenerationTarget
        let originalPresetCount =
            try await client.listProviderGenerationPresets(
                modelRouteID: "preview-provider"
            ).count
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setConnectionHydrationCommitHookForTesting {
            await gate.arrive()
        }

        let selection = Task {
            await viewModel.selectConnection(id: secondProfile.id)
        }
        await gate.waitForArrival(1)

        XCTAssertTrue(viewModel.isSelectionLoading)
        XCTAssertEqual(viewModel.selectedConnectionID, secondProfile.id)
        XCTAssertTrue(viewModel.modelRoutes.isEmpty)
        XCTAssertNil(viewModel.selectedModelRouteID)
        XCTAssertTrue(viewModel.presets.isEmpty)
        XCTAssertNil(viewModel.selectedPresetID)
        XCTAssertNil(viewModel.currentRequestPreview)

        await viewModel.useSelectedPresetAsAppDefault()
        await viewModel.savePreset()
        await viewModel.deleteSelectedPreset()

        let unchangedTarget =
            try await client.getSettings().selectedGenerationTarget
        let unchangedPresetCount =
            try await client.listProviderGenerationPresets(
                modelRouteID: "preview-provider"
            ).count
        XCTAssertEqual(unchangedTarget, originalTarget)
        XCTAssertEqual(unchangedPresetCount, originalPresetCount)

        await gate.releaseFirstArrival()
        await selection.value

        XCTAssertFalse(viewModel.isSelectionLoading)
        XCTAssertEqual(viewModel.selectedConnectionID, secondProfile.id)
        XCTAssertTrue(
            viewModel.modelRoutes.allSatisfy {
                $0.connectionID == secondProfile.id
            }
        )
        XCTAssertTrue(
            viewModel.presets.allSatisfy {
                $0.modelRouteID == viewModel.selectedModelRouteID
            }
        )
        viewModel.setConnectionHydrationCommitHookForTesting(nil)
    }

    func testOlderRouteHydrationCannotCommitAfterParentSelection()
        async throws
    {
        let firstProfile = ProviderProfile(
            id: "preview-provider",
            displayName: "Preview Provider",
            baseURL: "https://example.invalid/v1",
            model: "preview-model",
            timeoutSeconds: 30
        )
        let secondProfile = ProviderProfile(
            id: "route-race-provider",
            displayName: "Route Race Provider",
            baseURL: "https://route-race.example.invalid/v1",
            model: "route-race-model",
            timeoutSeconds: 30
        )
        let client = FakeCoreClient(
            profiles: [
                firstProfile,
                secondProfile,
            ]
        )
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        let oldRouteID = try XCTUnwrap(
            viewModel.selectedModelRouteID
        )
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setModelRouteHydrationCommitHookForTesting {
            await gate.arrive()
        }

        let staleRouteSelection = Task {
            await viewModel.selectModelRoute(id: oldRouteID)
        }
        await gate.waitForArrival(1)

        await viewModel.selectConnection(id: secondProfile.id)
        XCTAssertEqual(viewModel.selectedConnectionID, secondProfile.id)
        XCTAssertTrue(
            viewModel.modelRoutes.allSatisfy {
                $0.connectionID == secondProfile.id
            }
        )

        await gate.releaseFirstArrival()
        await staleRouteSelection.value

        XCTAssertEqual(viewModel.selectedConnectionID, secondProfile.id)
        XCTAssertTrue(
            viewModel.modelRoutes.allSatisfy {
                $0.connectionID == secondProfile.id
            }
        )
        XCTAssertTrue(
            viewModel.presets.allSatisfy {
                $0.modelRouteID == viewModel.selectedModelRouteID
            }
        )
        viewModel.setModelRouteHydrationCommitHookForTesting(nil)
    }

    func testRefreshCannotOverwriteNewerUserConnectionSelection()
        async throws
    {
        let firstProfile = ProviderProfile(
            id: "refresh-owner-a",
            displayName: "A Provider",
            baseURL: "https://a.example.invalid/v1",
            model: "a-model",
            timeoutSeconds: 30
        )
        let secondProfile = ProviderProfile(
            id: "refresh-owner-b",
            displayName: "B Provider",
            baseURL: "https://b.example.invalid/v1",
            model: "b-model",
            timeoutSeconds: 30
        )
        let client = FakeCoreClient(
            profiles: [firstProfile, secondProfile]
        )
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        await viewModel.selectConnection(id: firstProfile.id)
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setActiveGenerationSelectionCommitHookForTesting {
            await gate.arrive()
        }

        let staleRefresh = Task {
            await viewModel.refresh()
        }
        await gate.waitForArrival(1)
        await viewModel.selectConnection(id: secondProfile.id)
        let selectedRoutes = viewModel.modelRoutes
        let selectedPresets = viewModel.presets
        let selectedPreview = viewModel.currentRequestPreview
        let selectedEditorName = viewModel.presetName
        let selectedStatus = viewModel.statusMessage
        let selectedError = viewModel.errorMessage

        await gate.releaseFirstArrival()
        await staleRefresh.value

        XCTAssertEqual(viewModel.selectedConnectionID, secondProfile.id)
        XCTAssertEqual(viewModel.modelRoutes, selectedRoutes)
        XCTAssertEqual(viewModel.presets, selectedPresets)
        XCTAssertEqual(viewModel.currentRequestPreview, selectedPreview)
        XCTAssertEqual(viewModel.presetName, selectedEditorName)
        XCTAssertEqual(viewModel.statusMessage, selectedStatus)
        XCTAssertEqual(viewModel.errorMessage, selectedError)
        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertFalse(viewModel.isSelectionLoading)
        viewModel.setActiveGenerationSelectionCommitHookForTesting(nil)
    }

    func testStalePresetDeletionCannotMutateNewConnectionHierarchy()
        async throws
    {
        let firstProfile = ProviderProfile(
            id: "preset-delete-a",
            displayName: "A Provider",
            baseURL: "https://a.example.invalid/v1",
            model: "a-model",
            timeoutSeconds: 30
        )
        let secondProfile = ProviderProfile(
            id: "preset-delete-b",
            displayName: "B Provider",
            baseURL: "https://b.example.invalid/v1",
            model: "b-model",
            timeoutSeconds: 30
        )
        let client = FakeCoreClient(
            profiles: [firstProfile, secondProfile]
        )
        let store = ProviderConfigurationStore()
        let viewModel = ProviderSetupViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        await viewModel.refresh()
        await viewModel.selectConnection(id: firstProfile.id)
        viewModel.beginNewPreset()
        viewModel.presetName = "Delete Me"
        await viewModel.savePreset()
        let deletedPresetID = try XCTUnwrap(
            viewModel.selectedPresetID
        )
        await viewModel.useSelectedPresetAsAppDefault()
        XCTAssertEqual(
            store.selectedGenerationTarget?.generationPresetID,
            deletedPresetID
        )
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setPresetDeletionCommitHookForTesting {
            await gate.arrive()
        }

        let staleDeletion = Task {
            await viewModel.deleteSelectedPreset()
        }
        await gate.waitForArrival(1)
        await viewModel.selectConnection(id: secondProfile.id)
        let selectedRoutes = viewModel.modelRoutes
        let selectedPresets = viewModel.presets
        let selectedPresetID = viewModel.selectedPresetID
        let selectedPreview = viewModel.currentRequestPreview
        let selectedEditorName = viewModel.presetName
        let selectedStatus = viewModel.statusMessage
        let selectedError = viewModel.errorMessage

        await gate.releaseFirstArrival()
        await staleDeletion.value

        XCTAssertEqual(viewModel.selectedConnectionID, secondProfile.id)
        XCTAssertEqual(viewModel.modelRoutes, selectedRoutes)
        XCTAssertEqual(viewModel.presets, selectedPresets)
        XCTAssertEqual(viewModel.selectedPresetID, selectedPresetID)
        XCTAssertEqual(viewModel.currentRequestPreview, selectedPreview)
        XCTAssertEqual(viewModel.presetName, selectedEditorName)
        XCTAssertEqual(viewModel.statusMessage, selectedStatus)
        XCTAssertEqual(viewModel.errorMessage, selectedError)
        XCTAssertNil(viewModel.activeGenerationTarget)
        XCTAssertNil(store.selectedGenerationTarget)
        XCTAssertNil(store.selectedConnectionID)
        let remaining = try await client
            .listProviderGenerationPresets(
                modelRouteID: firstProfile.id
            )
        XCTAssertFalse(remaining.contains { $0.id == deletedPresetID })
        viewModel.setPresetDeletionCommitHookForTesting(nil)
    }

    func testStaleConnectionDeletionPreservesNewSelection()
        async throws
    {
        let firstProfile = ProviderProfile(
            id: "connection-delete-a",
            displayName: "A Provider",
            baseURL: "https://a.example.invalid/v1",
            model: "a-model",
            timeoutSeconds: 30
        )
        let secondProfile = ProviderProfile(
            id: "connection-delete-b",
            displayName: "B Provider",
            baseURL: "https://b.example.invalid/v1",
            model: "b-model",
            timeoutSeconds: 30
        )
        let client = FakeCoreClient(
            profiles: [firstProfile, secondProfile]
        )
        let credentials = InMemoryCredentialStore(
            values: [firstProfile.id: "synthetic-delete-key"]
        )
        let store = ProviderConfigurationStore()
        let viewModel = ProviderSetupViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        await viewModel.refresh()
        await viewModel.selectConnection(id: firstProfile.id)
        await viewModel.useSelectedPresetAsAppDefault()
        XCTAssertEqual(store.selectedConnectionID, firstProfile.id)
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setConnectionDeletionCommitHookForTesting {
            await gate.arrive()
        }

        let staleDeletion = Task {
            await viewModel.deleteSelectedConnection()
        }
        await gate.waitForArrival(1)
        await viewModel.selectConnection(id: secondProfile.id)
        let selectedRoutes = viewModel.modelRoutes
        let selectedPresets = viewModel.presets
        let selectedPreview = viewModel.currentRequestPreview
        let selectedEditorName = viewModel.presetName
        let selectedStatus = viewModel.statusMessage
        let selectedError = viewModel.errorMessage

        await gate.releaseFirstArrival()
        await staleDeletion.value

        XCTAssertEqual(viewModel.selectedConnectionID, secondProfile.id)
        XCTAssertEqual(viewModel.modelRoutes, selectedRoutes)
        XCTAssertEqual(viewModel.presets, selectedPresets)
        XCTAssertEqual(viewModel.currentRequestPreview, selectedPreview)
        XCTAssertEqual(viewModel.presetName, selectedEditorName)
        XCTAssertEqual(viewModel.statusMessage, selectedStatus)
        XCTAssertEqual(viewModel.errorMessage, selectedError)
        XCTAssertFalse(
            viewModel.connections.contains {
                $0.id == firstProfile.id
            }
        )
        let deletedCredential = try await credentials.credential(
            for: firstProfile.id
        )
        XCTAssertNil(deletedCredential)
        XCTAssertNil(viewModel.activeGenerationTarget)
        XCTAssertNil(store.selectedConnectionID)
        XCTAssertNil(store.selectedGenerationTarget)
        viewModel.setConnectionDeletionCommitHookForTesting(nil)
    }

    func testConnectionDeleteVerificationFailureRestoresCredential()
        async throws
    {
        let profile = ProviderProfile(
            id: "credential-delete-restore",
            displayName: "Credential Restore",
            baseURL: "https://restore.example.invalid/v1",
            model: "restore-model",
            timeoutSeconds: 30
        )
        let client = FakeCoreClient(profiles: [profile])
        let credentials = ProviderSetupScriptedCredentialStore(
            values: [profile.id: "synthetic-original-key"],
            readFailureInvocations: [2]
        )
        let viewModel = makeViewModel(
            client: client,
            credentials: credentials
        )
        await viewModel.refresh()

        await viewModel.deleteSelectedConnection()

        let restoredCredential = try await credentials.credential(
            for: profile.id
        )
        XCTAssertEqual(restoredCredential, "synthetic-original-key")
        XCTAssertTrue(
            viewModel.connections.contains { $0.id == profile.id }
        )
        XCTAssertTrue(
            viewModel.errorMessage?.contains("복구") == true
        )
    }

    func testConnectionDeleteRestoreFailureQuarantinesConnection()
        async throws
    {
        let profile = ProviderProfile(
            id: "credential-delete-quarantine",
            displayName: "Credential Quarantine",
            baseURL: "https://quarantine.example.invalid/v1",
            model: "quarantine-model",
            timeoutSeconds: 30
        )
        let client = FakeCoreClient(profiles: [profile])
        let credentials = ProviderSetupScriptedCredentialStore(
            values: [profile.id: "synthetic-original-key"],
            readFailureInvocations: [2],
            setFailureInvocations: [1]
        )
        let viewModel = makeViewModel(
            client: client,
            credentials: credentials
        )
        await viewModel.refresh()

        await viewModel.deleteSelectedConnection()

        let missingCredential = try await credentials.credential(
            for: profile.id
        )
        XCTAssertNil(missingCredential)
        XCTAssertTrue(
            viewModel.connections.contains { $0.id == profile.id }
        )
        XCTAssertTrue(
            viewModel.errorMessage?.contains("격리") == true
        )
    }

    func testSelectingDefaultWritesTypedTargetAndClearsLegacySelection()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        viewModel.beginNewPreset()
        viewModel.presetName = "앱 기본"
        await viewModel.savePreset()

        await viewModel.useSelectedPresetAsAppDefault()

        let target = try XCTUnwrap(viewModel.activeGenerationTarget)
        let settings = try await client.getSettings()
        XCTAssertEqual(settings.selectedGenerationTarget, target)
        XCTAssertNil(settings.selectedProviderProfileID)
        XCTAssertTrue(viewModel.selectedPresetIsAppDefault)
    }

    func testChatUsesConnectionIDForKeychainAndSendsTypedTarget()
        async throws
    {
        let profile = ProviderProfile(
            id: "stable-connection-id",
            displayName: "Stable",
            baseURL: "https://example.invalid/v1",
            model: "stable-model",
            timeoutSeconds: 30
        )
        let client = FakeCoreClient(profiles: [profile])
        let credentials = InMemoryCredentialStore(
            values: [profile.id: "synthetic-stable-key"]
        )
        let chat = ChatViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            automaticallyPollEvents: false
        )
        await chat.setCharacter(LibraryCharacter.previewCharacters[0])
        await chat.refreshProviderSelection()
        chat.draft = "typed target"

        await chat.submitMessage()

        let requests = await client.providerSendRequestsForTesting()
        let request = try XCTUnwrap(requests.last)
        XCTAssertEqual(request.providerProfileID, profile.id)
        XCTAssertEqual(request.modelRouteID, profile.id)
        XCTAssertEqual(request.generationPresetID, profile.id)
        XCTAssertTrue(request.hasCredential)
    }

    func testWebsiteDiscoveryUsesOneImmutableConnectionCredentialSlot()
        async throws
    {
        let client = FakeCoreClient()
        let credentials = InMemoryCredentialStore()
        let viewModel = makeViewModel(
            client: client,
            credentials: credentials
        )
        let secret = "synthetic-provider-secret-canary"
        await viewModel.refresh()
        viewModel.prepareDiscovery(method: .website)
        viewModel.discoveryDisplayName = "개인 Example"
        viewModel.discoveryURL =
            "https://console.example.invalid/api-keys?token=\(secret)#private"
        viewModel.credentialDraft = secret
        XCTAssertEqual(
            viewModel.selectedAssistantModelRouteID,
            "preview-provider"
        )
        XCTAssertTrue(viewModel.assistantRouteSelectionIsRunnable)
        let draftConnectionID =
            viewModel.draftDiscoveryConnectionID

        await viewModel.startDiscovery()

        XCTAssertEqual(
            viewModel.discovery?.state,
            .awaitingAssistantConsent
        )
        XCTAssertTrue(viewModel.credentialDraft.isEmpty)
        let stagedCredential = try await credentials.credential(
            for: draftConnectionID
        )
        XCTAssertEqual(
            stagedCredential,
            secret
        )
        XCTAssertTrue(
            viewModel.hasPendingDiscoveryCredentialCleanup
        )
        assertDoesNotExpose(secret, viewModel: viewModel)

        guard case let .assistantConsent(consent) =
            viewModel.discovery?.actionRequired
        else {
            return XCTFail("Expected assistant consent proposal")
        }
        XCTAssertEqual(
            consent.assistantModelRouteID,
            "preview-provider",
            "The fresh wizard must carry its exact selected route into Core."
        )
        XCTAssertEqual(
            viewModel.assistantRouteIdentity(
                routeID: consent.assistantModelRouteID
            )?.model,
            "preview-model"
        )
        XCTAssertTrue(
            viewModel.canApproveDiscoveryAssistant(consent)
        )
        await viewModel.continueDiscovery(
            .approveAssistant(
                approvalID: consent.approvalID,
                grantSHA256: consent.grantSHA256
            )
        )
        guard case .reviewDraft = viewModel.assistantHostAction else {
            return XCTFail("Expected typed assistant draft review")
        }
        await viewModel.acceptDiscoveryAssistantDraft()
        guard case let .credentialOrigin(approval) =
            viewModel.discovery?.actionRequired
        else {
            return XCTFail("Expected exact credential-origin approval")
        }
        XCTAssertEqual(
            approval.origin,
            "https://console.example.invalid"
        )
        XCTAssertFalse(approval.origin.contains(secret))

        await viewModel.continueDiscovery(
            .approveCredentialOrigin(
                approvalID: approval.approvalID
            )
        )
        XCTAssertEqual(viewModel.discovery?.state, .awaitingProbeConsent)

        await viewModel.continueDiscovery(.skipProbes)
        XCTAssertEqual(viewModel.discovery?.state, .awaitingReview)
        XCTAssertEqual(viewModel.discovery?.review?.warningCount, 1)

        await viewModel.commitDiscovery()

        XCTAssertEqual(viewModel.discovery?.state, .ready)
        let committed = try XCTUnwrap(
            viewModel.connections.first {
                $0.displayName == "개인 Example"
            }
        )
        XCTAssertEqual(committed.id, draftConnectionID)
        XCTAssertTrue(committed.hasCredential)
        let storedCredential = try await credentials.credential(
            for: committed.id
        )
        XCTAssertEqual(storedCredential, secret)
        XCTAssertFalse(
            viewModel.hasPendingDiscoveryCredentialCleanup
        )
        assertDoesNotExpose(secret, viewModel: viewModel)

        await viewModel.selectConnection(id: committed.id)
        viewModel.preservesOpaqueReasoningState = true
        await viewModel.previewEditedPreset()
        XCTAssertFalse(
            viewModel.preservesOpaqueReasoningState,
            "Preview must normalize credential-bearing continuity before Core."
        )
        XCTAssertFalse(
            viewModel.currentRequestPreview?
                .includesOpaqueReasoningState
                ?? true
        )

        viewModel.preservesOpaqueReasoningState = true
        await viewModel.savePreset()
        XCTAssertFalse(
            viewModel.selectedPreset?.preservesOpaqueReasoningState
                ?? true,
            "A credential-bearing preset must persist continuity as false."
        )
        XCTAssertFalse(viewModel.canEditOpaqueReasoningContinuity)
    }

    func testOlderDiscoverySnapshotCannotRollbackNewerCancellation()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        let gate = ProviderSetupRefreshCommitGate()
        let consumerCompleted = expectation(
            description: "stale discovery consumer completed"
        )
        consumerCompleted.assertForOverFulfill = false
        viewModel.setDiscoveryEventSnapshotCommitHookForTesting {
            await gate.arrive()
        }
        viewModel.prepareDiscovery(method: .localServer)
        viewModel.discoveryDisplayName = "Revision Race Local"
        viewModel.discoveryURL = "http://127.0.0.1:11434/v1"

        await viewModel.startDiscovery()
        await gate.waitForArrival(1)
        let sessionID = try XCTUnwrap(viewModel.discovery?.id)
        viewModel.setDiscoveryEventConsumerCompletionHookForTesting {
            completedSessionID in
            if completedSessionID == sessionID {
                consumerCompleted.fulfill()
            }
        }
        let initialEvents =
            try await client.pollProviderDiscoveryEvents(limit: 64)
        let staleEvent = try XCTUnwrap(
            initialEvents.first {
                $0.event.sessionID == sessionID
            }
        )
        let initialRevision = try XCTUnwrap(
            viewModel.discovery?.revision
        )

        await viewModel.cancelDiscovery()
        let cancelledRevision = try XCTUnwrap(
            viewModel.discovery?.revision
        )
        XCTAssertGreaterThan(cancelledRevision, initialRevision)
        XCTAssertEqual(viewModel.discovery?.state, .cancelled)
        let cancelledStatus = viewModel.statusMessage
        let cancelledError = viewModel.errorMessage
        let cancelledHostAction = viewModel.assistantHostAction
        let cancelledCompensationSteps =
            viewModel.compensationSteps
        let cancelledCredentialCleanup =
            viewModel.hasPendingDiscoveryCredentialCleanup

        await gate.releaseFirstArrival()
        await fulfillment(of: [consumerCompleted], timeout: 1)

        XCTAssertEqual(viewModel.discovery?.revision, cancelledRevision)
        XCTAssertEqual(viewModel.discovery?.state, .cancelled)
        XCTAssertEqual(viewModel.statusMessage, cancelledStatus)
        XCTAssertEqual(viewModel.errorMessage, cancelledError)
        XCTAssertEqual(
            viewModel.assistantHostAction,
            cancelledHostAction
        )
        XCTAssertEqual(
            viewModel.compensationSteps,
            cancelledCompensationSteps
        )
        XCTAssertEqual(
            viewModel.hasPendingDiscoveryCredentialCleanup,
            cancelledCredentialCleanup
        )
        let remainingEvents =
            try await client.pollProviderDiscoveryEvents(limit: 64)
        XCTAssertTrue(
            remainingEvents.contains {
                $0.event.id == staleEvent.event.id
            },
            "A rejected stale snapshot must not acknowledge its event."
        )
        viewModel.setDiscoveryEventSnapshotCommitHookForTesting(nil)
        viewModel.setDiscoveryEventConsumerCompletionHookForTesting(nil)
    }

    func testOlderDiscoverySessionCannotOverwriteNewSession()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        let gate = ProviderSetupRefreshCommitGate()
        let firstConsumerCompleted = expectation(
            description: "old discovery consumer completed"
        )
        firstConsumerCompleted.assertForOverFulfill = false
        viewModel.setDiscoveryEventSnapshotCommitHookForTesting {
            await gate.arrive()
        }

        viewModel.prepareDiscovery(method: .localServer)
        viewModel.discoveryDisplayName = "First Session"
        viewModel.discoveryURL = "http://127.0.0.1:11434/v1"
        await viewModel.startDiscovery()
        await gate.waitForArrival(1)
        let oldSessionID = try XCTUnwrap(viewModel.discovery?.id)
        viewModel.setDiscoveryEventConsumerCompletionHookForTesting {
            completedSessionID in
            if completedSessionID == oldSessionID {
                firstConsumerCompleted.fulfill()
            }
        }
        let initialEvents =
            try await client.pollProviderDiscoveryEvents(limit: 64)
        let staleEvent = try XCTUnwrap(
            initialEvents.first {
                $0.event.sessionID == oldSessionID
            }
        )

        await viewModel.cancelDiscovery()
        XCTAssertEqual(viewModel.discovery?.state, .cancelled)

        viewModel.prepareDiscovery(method: .localServer)
        viewModel.discoveryDisplayName = "Second Session"
        viewModel.discoveryURL = "http://127.0.0.1:11434/v1"
        await viewModel.startDiscovery()
        let newSession = try XCTUnwrap(viewModel.discovery)
        XCTAssertNotEqual(newSession.id, oldSessionID)
        let newStatus = viewModel.statusMessage
        let newError = viewModel.errorMessage
        let newHostAction = viewModel.assistantHostAction
        let newCompensationSteps = viewModel.compensationSteps
        let newCredentialCleanup =
            viewModel.hasPendingDiscoveryCredentialCleanup

        await gate.releaseFirstArrival()
        await fulfillment(
            of: [firstConsumerCompleted],
            timeout: 1
        )

        XCTAssertEqual(viewModel.discovery, newSession)
        XCTAssertEqual(viewModel.statusMessage, newStatus)
        XCTAssertEqual(viewModel.errorMessage, newError)
        XCTAssertEqual(viewModel.assistantHostAction, newHostAction)
        XCTAssertEqual(
            viewModel.compensationSteps,
            newCompensationSteps
        )
        XCTAssertEqual(
            viewModel.hasPendingDiscoveryCredentialCleanup,
            newCredentialCleanup
        )
        let remainingEvents =
            try await client.pollProviderDiscoveryEvents(limit: 64)
        XCTAssertTrue(
            remainingEvents.contains {
                $0.event.id == staleEvent.event.id
            },
            "An event for an obsolete session must remain unacknowledged."
        )

        viewModel.setDiscoveryEventSnapshotCommitHookForTesting(nil)
        viewModel.setDiscoveryEventConsumerCompletionHookForTesting(nil)
        await viewModel.cancelDiscovery()
    }

    func testDiscoveryRejectsDifferentSessionForRequestedAction()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        let gate = ProviderSetupRefreshCommitGate()
        let consumerCompleted = expectation(
            description: "wrong-session consumer completed"
        )
        consumerCompleted.assertForOverFulfill = false
        viewModel.setDiscoveryEventSnapshotCommitHookForTesting {
            await gate.arrive()
        }
        viewModel.prepareDiscovery(method: .localServer)
        viewModel.discoveryDisplayName = "Session Identity Local"
        viewModel.discoveryURL = "http://127.0.0.1:11434/v1"
        await viewModel.startDiscovery()
        await gate.waitForArrival(1)
        let original = try XCTUnwrap(viewModel.discovery)
        viewModel.setDiscoveryEventConsumerCompletionHookForTesting {
            completedSessionID in
            if completedSessionID == original.id {
                consumerCompleted.fulfill()
            }
        }
        viewModel.setDiscoverySnapshotTransformForTesting {
            discoverySnapshot(
                $0,
                replacingID: "different-session-id"
            )
        }

        await viewModel.cancelDiscovery()

        let durable = try await client.getProviderDiscovery(
            sessionID: original.id
        )
        XCTAssertEqual(viewModel.discovery, durable)
        XCTAssertEqual(viewModel.discovery?.state, .cancelled)
        XCTAssertTrue(
            viewModel.statusMessage?.contains("다시 확인") == true
        )
        XCTAssertNotNil(viewModel.errorMessage)

        viewModel.setDiscoverySnapshotTransformForTesting(nil)
        await gate.releaseFirstArrival()
        await fulfillment(of: [consumerCompleted], timeout: 1)
        viewModel.setDiscoveryEventSnapshotCommitHookForTesting(nil)
        viewModel.setDiscoveryEventConsumerCompletionHookForTesting(nil)
    }

    func testCancelledCredentialStagingCleansExactDraftSlot()
        async throws
    {
        let client = FakeCoreClient()
        let credentials = InMemoryCredentialStore()
        let viewModel = makeViewModel(
            client: client,
            credentials: credentials
        )
        await viewModel.refresh()
        viewModel.prepareDiscovery(method: .website)
        viewModel.discoveryDisplayName = "Cancelled Stage"
        viewModel.discoveryURL = "https://stage.example.invalid"
        viewModel.credentialDraft = "synthetic-stage-key"
        let connectionID = viewModel.draftDiscoveryConnectionID
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setDiscoveryCredentialStageCommitHookForTesting {
            await gate.arrive()
        }

        let start = Task {
            await viewModel.startDiscovery()
        }
        await gate.waitForArrival(1)
        start.cancel()
        await gate.releaseFirstArrival()
        await start.value

        let stagedCredential =
            try await credentials.credentialData(for: connectionID)
        XCTAssertNil(stagedCredential)
        XCTAssertFalse(
            viewModel.hasPendingDiscoveryCredentialCleanup
        )
        XCTAssertNil(viewModel.discovery)
        viewModel.setDiscoveryCredentialStageCommitHookForTesting(nil)
    }

    func testCancelledDiscoveryBeginCancelsSessionAndCleansCredential()
        async throws
    {
        let client = FakeCoreClient()
        let credentials = InMemoryCredentialStore()
        let viewModel = makeViewModel(
            client: client,
            credentials: credentials
        )
        await viewModel.refresh()
        viewModel.prepareDiscovery(method: .website)
        viewModel.discoveryDisplayName = "Cancelled Begin"
        viewModel.discoveryURL = "https://begin.example.invalid"
        viewModel.credentialDraft = "synthetic-begin-key"
        let connectionID = viewModel.draftDiscoveryConnectionID
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setDiscoveryBeginCommitHookForTesting {
            await gate.arrive()
        }

        let start = Task {
            await viewModel.startDiscovery()
        }
        await gate.waitForArrival(1)
        start.cancel()
        await gate.releaseFirstArrival()
        await start.value

        let stagedCredential =
            try await credentials.credentialData(for: connectionID)
        XCTAssertNil(stagedCredential)
        XCTAssertFalse(
            viewModel.hasPendingDiscoveryCredentialCleanup
        )
        XCTAssertNil(viewModel.discovery)
        let events =
            try await client.pollProviderDiscoveryEvents(limit: 64)
        XCTAssertTrue(
            events.contains { $0.event.state == .cancelled }
        )
        viewModel.setDiscoveryBeginCommitHookForTesting(nil)
    }

    func testCancelledTerminalDiscoveryResponseStillCleansCredential()
        async throws
    {
        let client = FakeCoreClient()
        let credentials = InMemoryCredentialStore()
        let viewModel = makeViewModel(
            client: client,
            credentials: credentials
        )
        await viewModel.refresh()
        viewModel.prepareDiscovery(method: .website)
        viewModel.discoveryDisplayName = "Cancelled Terminal"
        viewModel.discoveryURL = "https://cancel.example.invalid"
        viewModel.credentialDraft = "synthetic-cancel-key"
        await viewModel.startDiscovery()
        let snapshot = try XCTUnwrap(viewModel.discovery)
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setDiscoveryCancellationCommitHookForTesting {
            await gate.arrive()
        }

        let cancellation = Task {
            await viewModel.cancelDiscovery()
        }
        await gate.waitForArrival(1)
        cancellation.cancel()
        await gate.releaseFirstArrival()
        await cancellation.value

        let durable = try await client.getProviderDiscovery(
            sessionID: snapshot.id
        )
        XCTAssertEqual(durable.state, .cancelled)
        let stagedCredential =
            try await credentials.credentialData(
                for: snapshot.pendingConnectionID
            )
        XCTAssertNil(
            stagedCredential
        )
        XCTAssertFalse(
            viewModel.hasPendingDiscoveryCredentialCleanup
        )
        viewModel.setDiscoveryCancellationCommitHookForTesting(nil)
    }

    func testApprovedLANCurlUsesExactGrantAndOneShotCredentialSlot()
        async throws
    {
        let client = FakeCoreClient()
        let credentials = InMemoryCredentialStore()
        let viewModel = makeViewModel(
            client: client,
            credentials: credentials
        )
        let secret = "synthetic-lan-curl-secret"
        await viewModel.refresh()
        viewModel.prepareDiscovery(method: .curl)
        viewModel.discoveryDisplayName = "LAN 모델 서버"
        viewModel.discoveryNetworkMode = .approvedLocalNetwork
        viewModel.approvedLANOrigin = "http://models.lan:11434"
        viewModel.approvedLANAddresses = "192.168.10.24, fd00::24"
        viewModel.curlExample =
            "curl http://models.lan:11434/v1/models "
                + "-H 'Authorization: Bearer \(secret)'"
        let connectionID = viewModel.draftDiscoveryConnectionID

        XCTAssertTrue(viewModel.canStartDiscovery)
        await viewModel.startDiscovery()

        guard case let .credentialOrigin(approval) =
            viewModel.discovery?.actionRequired
        else {
            return XCTFail("Expected exact LAN credential-origin approval")
        }
        XCTAssertEqual(approval.origin, "http://models.lan:11434")
        let storedCredential = try await credentials.credential(
            for: connectionID
        )
        XCTAssertEqual(
            storedCredential,
            secret
        )
        XCTAssertTrue(viewModel.curlExample.isEmpty)
        assertDoesNotExpose(secret, viewModel: viewModel)
    }

    func testCredentialOriginRejectionCancelsWithoutCreatingConnection()
        async
    {
        let client = FakeCoreClient()
        let credentials = InMemoryCredentialStore()
        let viewModel = makeViewModel(
            client: client,
            credentials: credentials
        )
        await viewModel.refresh()
        let initialIDs = viewModel.connections.map(\.id)
        viewModel.prepareDiscovery(method: .knownProvider)
        viewModel.discoveryDisplayName = "거부할 연결"
        viewModel.selectedTemplateID = "openai-v1"
        viewModel.credentialDraft = "synthetic-rejected-secret"
        let draftConnectionID =
            viewModel.draftDiscoveryConnectionID

        await viewModel.startDiscovery()
        await viewModel.cancelDiscovery()

        XCTAssertEqual(viewModel.discovery?.state, .cancelled)
        XCTAssertEqual(viewModel.connections.map(\.id), initialIDs)
        XCTAssertFalse(viewModel.hasActiveDiscovery)
        let remainingStagedCredential =
            try? await credentials.credential(
                for: draftConnectionID
            )
        XCTAssertNil(
            remainingStagedCredential
        )
        XCTAssertFalse(
            viewModel.hasPendingDiscoveryCredentialCleanup
        )
    }

    func testCommitFailureCompensatesExactCredentialSlot()
        async throws
    {
        let client = FakeCoreClient()
        let credentials = InMemoryCredentialStore()
        let viewModel = makeViewModel(
            client: client,
            credentials: credentials
        )
        await viewModel.refresh()
        viewModel.prepareDiscovery(method: .knownProvider)
        viewModel.discoveryDisplayName = "보상할 연결"
        viewModel.selectDiscoveryTemplate(id: "openai-v1")
        viewModel.credentialDraft = "synthetic-compensation-secret"
        await viewModel.startDiscovery()
        guard case let .credentialOrigin(approval) =
            viewModel.discovery?.actionRequired
        else {
            return XCTFail("Expected credential origin approval")
        }
        await viewModel.continueDiscovery(
            .approveCredentialOrigin(
                approvalID: approval.approvalID
            )
        )
        await viewModel.continueDiscovery(.skipProbes)
        let connectionID = try XCTUnwrap(
            viewModel.discovery?.pendingConnectionID
        )
        try await credentials.deleteCredential(for: connectionID)

        await viewModel.commitDiscovery()

        XCTAssertEqual(viewModel.discovery?.state, .failed)
        XCTAssertTrue(
            viewModel.compensationSteps.allSatisfy {
                $0.status == .completed
            }
        )
        let credential =
            try await credentials.credentialData(
                for: connectionID
            )
        XCTAssertNil(credential)
        XCTAssertFalse(
            viewModel.connections.contains {
                $0.id == connectionID
            }
        )
    }

    func testPresetDefaultsRemainOmittedUntilUserSetsAValue() async throws {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        viewModel.beginNewPreset()

        XCTAssertTrue(
            viewModel.parameterValues.values.allSatisfy {
                if case .providerDefault = $0 {
                    return true
                }
                return false
            }
        )

        viewModel.presetName = "강한 추론"
        viewModel.setParameterUsesProviderDefault(
            id: "reasoning_effort",
            usesDefault: false
        )
        viewModel.setParameterLiteral(
            id: "reasoning_effort",
            literal: .enumeration("high")
        )
        await viewModel.savePreset()

        let saved = try XCTUnwrap(viewModel.selectedPreset)
        XCTAssertEqual(saved.displayName, "강한 추론")
        XCTAssertEqual(
            saved.values.first {
                $0.parameterID == "temperature"
            }?.state,
            .providerDefault
        )
        XCTAssertEqual(
            saved.values.first {
                $0.parameterID == "reasoning_effort"
            }?.state,
            .explicit(.enumeration("high"))
        )
    }

    func testUnsavedPresetUsesCandidateValidationAndScalarFreePreview()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        let savedPresetCount = viewModel.presets.count
        viewModel.beginNewPreset()
        viewModel.presetName = "미리보기 전용"
        viewModel.setParameterLiteral(
            id: "temperature",
            literal: .number(0.7)
        )

        await viewModel.previewEditedPreset()

        let preview = try XCTUnwrap(viewModel.currentRequestPreview)
        XCTAssertEqual(viewModel.presets.count, savedPresetCount)
        XCTAssertEqual(preview.redactionVersion, 1)
        XCTAssertEqual(preview.method, "POST")
        XCTAssertEqual(preview.origin, "https://example.invalid")
        XCTAssertEqual(preview.path, "/v1/chat/completions")
        XCTAssertTrue(preview.isScalarFree)
        XCTAssertFalse(preview.bodyTruncated)
        XCTAssertNotNil(preview.bodyShapeJSON)

        viewModel.setParameterLiteral(
            id: "temperature",
            literal: .number(0.8)
        )
        XCTAssertNotNil(viewModel.requestPreview)
        XCTAssertNil(
            viewModel.currentRequestPreview,
            "A preview for older editor values must be hidden."
        )
    }

    func testReasoningAndCacheEditorsUseCoreRenderedControls()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()

        let initialReasoning = try XCTUnwrap(
            viewModel.currentReasoningControl
        )
        XCTAssertEqual(initialReasoning.state, .ready)
        XCTAssertEqual(
            initialReasoning.allowedModes,
            [
                "provider_default",
                "disabled",
                "automatic",
                "enabled",
            ]
        )
        XCTAssertEqual(initialReasoning.effortField, .hidden)

        viewModel.setReasoningMode("automatic")
        viewModel.promptCacheMode = "explicit_context"
        viewModel.promptCacheContextReference = ""
        await viewModel.refreshPresetControls()

        XCTAssertEqual(
            viewModel.currentReasoningControl?.effortField,
            .enabled
        )
        let cache = try XCTUnwrap(
            viewModel.currentPromptCacheControl
        )
        XCTAssertEqual(cache.contextReferenceField, .required)
        XCTAssertEqual(cache.state, .invalid)
        XCTAssertTrue(cache.supportsCustomTTL)
        XCTAssertFalse(
            cache.allowedTTLs.contains("custom_seconds"),
            "Custom TTL support is a dedicated Core flag, not a fake allowed value."
        )
    }

    func testOpenRouterExactDefaultEffortIsAdoptedBeforePreviewAndSave()
        async throws
    {
        let client = FakeCoreClient(
            testingOptions: FakeCoreClientTestingOptions(
                reasoningMetadataFixture:
                    .openRouterExact(defaultEffort: "medium")
            )
        )
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        viewModel.beginNewPreset()
        viewModel.presetName = "OpenRouter 기본 추론"
        viewModel.setReasoningMode("enabled")

        await viewModel.refreshPresetControls()
        await viewModel.refreshPresetControls()

        XCTAssertEqual(viewModel.reasoningEffort, "medium")
        let control = try XCTUnwrap(
            viewModel.currentReasoningControl
        )
        XCTAssertEqual(control.state, .ready)
        XCTAssertEqual(control.effort, "medium")
        XCTAssertEqual(control.effortField, .enabled)

        await viewModel.previewEditedPreset()

        XCTAssertNotNil(viewModel.currentRequestPreview)
        let previewCandidates =
            await client.providerPreviewCandidatesForTesting()
        XCTAssertEqual(
            previewCandidates.last?.reasoningEffort,
            "medium"
        )

        await viewModel.savePreset()

        XCTAssertEqual(
            viewModel.selectedPreset?.reasoningEffort,
            "medium"
        )

        viewModel.reasoningEffort = "high"
        await viewModel.refreshPresetControls()
        XCTAssertEqual(
            viewModel.reasoningEffort,
            "high",
            "A canonical default must never overwrite an explicit user effort."
        )
    }

    func testOpenRouterDefaultEffortClosesImmediatePreviewAndSaveRace()
        async throws
    {
        let previewClient = FakeCoreClient(
            testingOptions: FakeCoreClientTestingOptions(
                reasoningMetadataFixture:
                    .openRouterExact(defaultEffort: "medium")
            )
        )
        let previewViewModel = makeViewModel(client: previewClient)
        await previewViewModel.refresh()
        previewViewModel.beginNewPreset()
        previewViewModel.presetName = "즉시 미리보기"
        previewViewModel.setReasoningMode("enabled")

        await previewViewModel.previewEditedPreset()

        XCTAssertEqual(previewViewModel.reasoningEffort, "medium")
        XCTAssertNotNil(previewViewModel.currentRequestPreview)
        let previewCandidates =
            await previewClient.providerPreviewCandidatesForTesting()
        XCTAssertEqual(
            previewCandidates.last?.reasoningEffort,
            "medium"
        )

        let saveClient = FakeCoreClient(
            testingOptions: FakeCoreClientTestingOptions(
                reasoningMetadataFixture:
                    .openRouterExact(defaultEffort: "high")
            )
        )
        let saveViewModel = makeViewModel(client: saveClient)
        await saveViewModel.refresh()
        saveViewModel.beginNewPreset()
        saveViewModel.presetName = "즉시 저장"
        saveViewModel.setReasoningMode("enabled")

        await saveViewModel.savePreset()

        XCTAssertEqual(saveViewModel.reasoningEffort, "high")
        XCTAssertEqual(
            saveViewModel.selectedPreset?.reasoningEffort,
            "high"
        )
        let savedPreviewCandidates =
            await saveClient.providerPreviewCandidatesForTesting()
        XCTAssertEqual(
            savedPreviewCandidates.last?.reasoningEffort,
            "high"
        )
    }

    func testPresetNormalizationCannotCrossSameIDRefreshEpoch()
        async throws
    {
        let client = FakeCoreClient(
            testingOptions: FakeCoreClientTestingOptions(
                reasoningMetadataFixture:
                    .openRouterExact(defaultEffort: "medium")
            )
        )
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        viewModel.beginNewPreset()
        viewModel.presetName = "Old Draft"
        viewModel.setReasoningMode("enabled")
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setPresetNormalizationCommitHookForTesting {
            await gate.arrive()
        }

        let stalePreview = Task {
            await viewModel.previewEditedPreset()
        }
        await gate.waitForArrival(1)
        await viewModel.refresh()
        let refreshedPresetName = viewModel.presetName
        let refreshedEffort = viewModel.reasoningEffort
        let refreshedControl = viewModel.currentReasoningControl
        let refreshedPreview = viewModel.currentRequestPreview
        let refreshedStatus = viewModel.statusMessage
        let refreshedError = viewModel.errorMessage

        await gate.releaseFirstArrival()
        await stalePreview.value

        XCTAssertEqual(viewModel.presetName, refreshedPresetName)
        XCTAssertEqual(viewModel.reasoningEffort, refreshedEffort)
        XCTAssertEqual(
            viewModel.currentReasoningControl,
            refreshedControl
        )
        XCTAssertEqual(
            viewModel.currentRequestPreview,
            refreshedPreview
        )
        XCTAssertEqual(viewModel.statusMessage, refreshedStatus)
        XCTAssertEqual(viewModel.errorMessage, refreshedError)
        viewModel.setPresetNormalizationCommitHookForTesting(nil)
    }

    func testFailureAfterReasoningNormalizationRemainsVisible()
        async throws
    {
        let client = FakeCoreClient(
            testingOptions: FakeCoreClientTestingOptions(
                reasoningMetadataFixture:
                    .openRouterExact(defaultEffort: "medium")
            )
        )
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        viewModel.beginNewPreset()
        viewModel.presetName = "Normalization Failure"
        viewModel.setReasoningMode("enabled")
        viewModel.setRequestPreviewCommitHookForTesting {
            throw CoreClientFailure.startupFailed(
                "synthetic post-normalization failure"
            )
        }

        await viewModel.previewEditedPreset()

        XCTAssertEqual(viewModel.reasoningEffort, "medium")
        XCTAssertNil(viewModel.currentRequestPreview)
        XCTAssertNotNil(viewModel.errorMessage)
        viewModel.setRequestPreviewCommitHookForTesting(nil)
    }

    func testStalePreviewFailureCannotClearNewerEditorControls()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setRequestPreviewCommitHookForTesting {
            await gate.arrive()
            throw CoreClientFailure.startupFailed(
                "synthetic stale editor failure"
            )
        }

        let stalePreview = Task {
            await viewModel.loadRequestPreview()
        }
        await gate.waitForArrival(1)
        viewModel.presetName = "Newer Editor Value"
        await viewModel.refreshPresetControls()
        let newerReasoning = viewModel.currentReasoningControl
        let newerCache = viewModel.currentPromptCacheControl
        let newerStatus = viewModel.statusMessage
        let newerError = viewModel.errorMessage

        await gate.releaseFirstArrival()
        await stalePreview.value

        XCTAssertEqual(viewModel.presetName, "Newer Editor Value")
        XCTAssertEqual(
            viewModel.currentReasoningControl,
            newerReasoning
        )
        XCTAssertEqual(
            viewModel.currentPromptCacheControl,
            newerCache
        )
        XCTAssertEqual(viewModel.statusMessage, newerStatus)
        XCTAssertEqual(viewModel.errorMessage, newerError)
        viewModel.setRequestPreviewCommitHookForTesting(nil)
    }

    func testProviderDefaultTransitionAtomicallyClearsReasoningOverrides()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        viewModel.beginNewPreset()
        viewModel.presetName = "프로바이더 기본 추론"
        viewModel.setReasoningMode("enabled")
        viewModel.reasoningEffort = "high"
        viewModel.reasoningBudgetTokens = "4096"
        viewModel.reasoningSummary = "detailed"

        viewModel.setReasoningMode("provider_default")

        XCTAssertEqual(viewModel.reasoningEffort, "")
        XCTAssertEqual(viewModel.reasoningBudgetTokens, "")
        XCTAssertEqual(viewModel.reasoningSummary, "provider_default")

        await viewModel.previewEditedPreset()

        let previewCandidates =
            await client.providerPreviewCandidatesForTesting()
        let previewed = try XCTUnwrap(previewCandidates.last)
        XCTAssertEqual(previewed.reasoningMode, "provider_default")
        XCTAssertNil(previewed.reasoningEffort)
        XCTAssertNil(previewed.reasoningBudgetTokens)
        XCTAssertEqual(
            previewed.reasoningSummary,
            "provider_default"
        )

        await viewModel.savePreset()

        let saved = try XCTUnwrap(viewModel.selectedPreset)
        XCTAssertEqual(saved.reasoningMode, "provider_default")
        XCTAssertNil(saved.reasoningEffort)
        XCTAssertNil(saved.reasoningBudgetTokens)
        XCTAssertEqual(saved.reasoningSummary, "provider_default")
    }

    func testStaleProviderDefaultOverrideIsRejectedUntilModeTransition()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        viewModel.reasoningEffort = "high"

        await viewModel.refreshPresetControls()

        XCTAssertEqual(viewModel.reasoningEffort, "high")
        XCTAssertEqual(
            viewModel.currentReasoningControl?.state,
            .invalid,
            "A legacy stale override must be shown as invalid, not silently cleared."
        )

        await viewModel.previewEditedPreset()
        XCTAssertNil(viewModel.currentRequestPreview)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(
            viewModel.currentReasoningControl?.state,
            .invalid
        )

        viewModel.setReasoningMode("enabled")
        viewModel.setReasoningMode("provider_default")
        await viewModel.previewEditedPreset()

        XCTAssertEqual(viewModel.reasoningEffort, "")
        XCTAssertNotNil(viewModel.currentRequestPreview)
    }

    func testOpenRouterExactEffortsWithoutDefaultRejectEnabledNil()
        async throws
    {
        let client = FakeCoreClient(
            testingOptions: FakeCoreClientTestingOptions(
                reasoningMetadataFixture:
                    .openRouterExact(defaultEffort: nil)
            )
        )
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        let originalPresets = viewModel.presets
        let originalPreviewCount =
            await client.providerPreviewCandidatesForTesting().count
        viewModel.beginNewPreset()
        viewModel.presetName = "강도 필수"
        viewModel.setReasoningMode("enabled")

        await viewModel.refreshPresetControls()

        XCTAssertEqual(viewModel.reasoningEffort, "")
        XCTAssertEqual(
            viewModel.currentReasoningControl?.state,
            .invalid
        )
        XCTAssertEqual(
            viewModel.currentReasoningControl?.effortField,
            .required
        )

        await viewModel.previewEditedPreset()
        XCTAssertNil(viewModel.currentRequestPreview)
        let previewCount =
            await client.providerPreviewCandidatesForTesting().count
        XCTAssertEqual(
            previewCount,
            originalPreviewCount
        )

        await viewModel.savePreset()
        XCTAssertEqual(viewModel.presets, originalPresets)
        XCTAssertNil(viewModel.selectedPresetID)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testOpenRouterHiddenEffortMetadataKeepsEnabledNil()
        async throws
    {
        let fixtures: [FakeReasoningMetadataFixture] = [
            .openRouterNotExposed,
            .openRouterExactEmpty,
        ]
        for fixture in fixtures {
            let client = FakeCoreClient(
                testingOptions: FakeCoreClientTestingOptions(
                    reasoningMetadataFixture: fixture
                )
            )
            let viewModel = makeViewModel(client: client)
            await viewModel.refresh()
            viewModel.beginNewPreset()
            viewModel.presetName = "숨김 강도"
            viewModel.setReasoningMode("enabled")

            await viewModel.refreshPresetControls()

            let control = try XCTUnwrap(
                viewModel.currentReasoningControl
            )
            XCTAssertEqual(control.state, .ready)
            XCTAssertEqual(control.effortField, .hidden)
            XCTAssertTrue(control.allowedEfforts.isEmpty)
            XCTAssertEqual(viewModel.reasoningEffort, "")

            await viewModel.previewEditedPreset()

            XCTAssertNotNil(viewModel.currentRequestPreview)
            let previewCandidates =
                await client.providerPreviewCandidatesForTesting()
            XCTAssertNil(
                previewCandidates.last?.reasoningEffort
            )

            await viewModel.savePreset()
            XCTAssertNil(
                viewModel.selectedPreset?.reasoningEffort
            )
        }
    }

    func testOpenRouterExactNoneDoesNotOfferEnabledMode()
        async throws
    {
        let client = FakeCoreClient(
            testingOptions: FakeCoreClientTestingOptions(
                reasoningMetadataFixture:
                    .openRouterExactNoneOnly
            )
        )
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()

        let control = try XCTUnwrap(
            viewModel.currentReasoningControl
        )
        XCTAssertEqual(
            control.allowedModes,
            ["provider_default", "disabled"]
        )
        XCTAssertFalse(control.allowedModes.contains("enabled"))
        XCTAssertEqual(control.effortField, .hidden)
    }

    func testCoreCanNormalizeUnsupportedOpaqueReasoningReplayOff()
        async
    {
        let client = FakeCoreClient(
            testingOptions: FakeCoreClientTestingOptions(
                forcesOpaqueReasoningStateOff: true
            )
        )
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        viewModel.preservesOpaqueReasoningState = true

        await viewModel.refreshPresetControls()

        XCTAssertFalse(
            viewModel.preservesOpaqueReasoningState,
            "Native must adopt Core's fail-closed replay capability."
        )
        XCTAssertFalse(
            viewModel.canEditOpaqueReasoningContinuity,
            "An unavailable Core control must not leave an editable native toggle."
        )

        viewModel.preservesOpaqueReasoningState = true
        await viewModel.savePreset()

        XCTAssertFalse(
            viewModel.selectedPreset?.preservesOpaqueReasoningState
                ?? true,
            "A stale native true value must be clamped before persistence."
        )
        XCTAssertFalse(viewModel.preservesOpaqueReasoningState)
    }

    func testInvalidPresetCandidateNeverPersists() async {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        let originalPresetIDs = viewModel.presets.map(\.id)
        viewModel.beginNewPreset()
        viewModel.presetName = "범위를 벗어난 프리셋"
        viewModel.setParameterLiteral(
            id: "temperature",
            literal: .number(99)
        )

        await viewModel.savePreset()

        let persisted = try? await client
            .listProviderGenerationPresets(
                modelRouteID: "preview-provider"
            )
        XCTAssertEqual(persisted?.map(\.id), originalPresetIDs)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.currentRequestPreview)
    }

    func testDeletingSelectedPresetClearsDurableTypedTarget() async throws {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        viewModel.beginNewPreset()
        viewModel.presetName = "삭제할 기본값"
        await viewModel.savePreset()
        let presetID = try XCTUnwrap(viewModel.selectedPresetID)
        XCTAssertNotEqual(presetID, "preview-provider")
        await viewModel.useSelectedPresetAsAppDefault()

        await viewModel.deleteSelectedPreset()

        let settings = try await client.getSettings()
        XCTAssertNil(settings.selectedGenerationTarget)
        XCTAssertNil(viewModel.activeGenerationTarget)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testCurlDiscoveryCanStartFromCurlAlone() async {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        viewModel.prepareDiscovery(method: .curl)
        viewModel.discoveryDisplayName = "cURL 전용"
        viewModel.curlExample =
            "curl https://api.example.invalid/v1/models"

        XCTAssertTrue(viewModel.canStartDiscovery)
        await viewModel.startDiscovery()

        XCTAssertNotNil(viewModel.discovery)
        XCTAssertTrue(viewModel.curlExample.isEmpty)
    }

    func testCurlCredentialUsesOneShotByteHandoffAndExactKeychainSlot()
        async throws
    {
        let client = FakeCoreClient()
        let credentials = InMemoryCredentialStore()
        let viewModel = makeViewModel(
            client: client,
            credentials: credentials
        )
        let secret = "synthetic-curl-handoff-canary"
        await viewModel.refresh()
        viewModel.prepareDiscovery(method: .curl)
        viewModel.discoveryDisplayName = "cURL 보안 이관"
        viewModel.curlExample =
            "curl https://api.example.invalid/v1/models -H 'Authorization: Bearer \(secret)'"
        let draftConnectionID =
            viewModel.draftDiscoveryConnectionID

        await viewModel.startDiscovery()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.curlExample.isEmpty)
        XCTAssertTrue(viewModel.credentialDraft.isEmpty)
        let storedCurlCredential =
            try await credentials.credentialData(
                for: draftConnectionID
            )
        XCTAssertEqual(storedCurlCredential, Data(secret.utf8))
        XCTAssertEqual(
            viewModel.discovery?.credentialSlotID,
            draftConnectionID
        )
        assertDoesNotExpose(secret, viewModel: viewModel)

        let inspection = try await client.inspectProviderCurl(
            "curl https://api.example.invalid -H 'Authorization: Bearer second-canary'",
            networkPolicy: ProviderNetworkPolicy(mode: .publicInternet)
        )
        let handoffID = try XCTUnwrap(
            inspection.credentialHandoffID
        )
        let firstTake = try await client.takeProviderCurlCredential(
            handoffID: handoffID
        )
        XCTAssertEqual(firstTake, Data("second-canary".utf8))
        let secondTake = try await client.takeProviderCurlCredential(
            handoffID: handoffID
        )
        XCTAssertNil(secondTake)
    }

    func testApprovedLANRequiresExactOriginAndPrivateAddresses()
        async
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        viewModel.prepareDiscovery(method: .localServer)
        viewModel.discoveryDisplayName = "LAN 모델 서버"
        viewModel.discoveryNetworkMode = .approvedLocalNetwork
        viewModel.discoveryURL = "http://models.lan:11434/v1"
        viewModel.approvedLANOrigin = "http://models.lan:11434"
        viewModel.approvedLANAddresses =
            "192.168.10.24, fd12:3456::24"

        XCTAssertTrue(viewModel.canStartDiscovery)

        viewModel.approvedLANOrigin = "http://other.lan:11434"
        XCTAssertFalse(viewModel.canStartDiscovery)

        viewModel.approvedLANOrigin = "http://models.lan:11434"
        viewModel.approvedLANAddresses = "8.8.8.8"
        XCTAssertFalse(viewModel.canStartDiscovery)

        viewModel.approvedLANAddresses = "192.168.10.24"
        await viewModel.startDiscovery()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(
            viewModel.discovery?.pendingConnectionID,
            viewModel.draftDiscoveryConnectionID
        )
    }

    func testDiscoveryRestoresWithItsExactConnectionCredentialSlot()
        async throws
    {
        let client = FakeCoreClient()
        let credentials = InMemoryCredentialStore()
        let first = makeViewModel(
            client: client,
            credentials: credentials
        )
        await first.refresh()
        first.prepareDiscovery(method: .knownProvider)
        first.discoveryDisplayName = "복원할 연결"
        first.selectDiscoveryTemplate(id: "openai-v1")
        first.credentialDraft = "synthetic-restart-secret"
        await first.startDiscovery()
        let sessionID = try XCTUnwrap(first.discovery?.id)
        let connectionID = try XCTUnwrap(
            first.discovery?.pendingConnectionID
        )

        let restored = makeViewModel(
            client: client,
            credentials: credentials
        )
        await restored.refresh()

        XCTAssertEqual(restored.discovery?.id, sessionID)
        XCTAssertEqual(
            restored.draftDiscoveryConnectionID,
            connectionID
        )
        XCTAssertTrue(
            restored.hasPendingDiscoveryCredentialCleanup
        )
        let restoredCredential = try await credentials.credential(
            for: connectionID
        )
        XCTAssertEqual(
            restoredCredential,
            "synthetic-restart-secret"
        )
    }

    func testPreGrantRestoreNeverGuessesChangedDefaultAssistantRoute()
        async throws
    {
        let profileA = ProviderProfile(
            id: "assistant-route-a",
            displayName: "Assistant A",
            baseURL: "https://assistant-a.invalid/v1",
            model: "model-a",
            timeoutSeconds: 30
        )
        let profileB = ProviderProfile(
            id: "assistant-route-b",
            displayName: "Assistant B",
            baseURL: "https://assistant-b.invalid/v1",
            model: "model-b",
            timeoutSeconds: 30
        )
        let targetA = ProviderGenerationTarget(
            modelRouteID: profileA.id,
            generationPresetID: profileA.id
        )
        let targetB = ProviderGenerationTarget(
            modelRouteID: profileB.id,
            generationPresetID: profileB.id
        )
        let client = try FakeCoreClient(
            profiles: [profileA, profileB],
            initialSettings: CoreAppSettings(
                preservePartialGenerations: true,
                selectedProviderProfileID: nil,
                selectedModelRouteID: targetA.modelRouteID,
                selectedGenerationPresetID:
                    targetA.generationPresetID
            )
        )
        let credentials = InMemoryCredentialStore()
        let first = makeViewModel(
            client: client,
            credentials: credentials
        )
        await first.refresh()
        first.prepareDiscovery(method: .website)
        first.discoveryDisplayName = "복원 route 고정"
        first.discoveryURL =
            "https://docs.restore-route.invalid/api"
        first.credentialDraft = "synthetic-restore-route-key"
        await first.startDiscovery()
        guard case let .assistantConsent(consent) =
            first.discovery?.actionRequired
        else {
            return XCTFail("Expected assistant consent")
        }
        XCTAssertEqual(
            consent.assistantModelRouteID,
            targetA.modelRouteID
        )
        await first.continueDiscovery(.declineAssistant)
        XCTAssertEqual(
            first.discovery?.state,
            .awaitingMoreEvidence
        )

        _ = try await client.selectProviderGenerationTarget(
            targetB
        )
        let restored = makeViewModel(
            client: client,
            credentials: credentials
        )
        await restored.refresh()

        XCTAssertEqual(restored.activeGenerationTarget, targetB)
        XCTAssertEqual(
            Set(restored.assistantModelRoutes.map(\.id)),
            [targetA.modelRouteID, targetB.modelRouteID]
        )
        XCTAssertNil(
            restored.selectedAssistantModelRouteID,
            "A pre-grant public snapshot does not expose its frozen route, so current default B must not be guessed."
        )
        XCTAssertFalse(restored.canRequestDiscoveryAssistant)
        XCTAssertTrue(
            restored.assistantRouteSelectionMessage?
                .contains("원래 선택한") == true
        )
        let revision = restored.discovery?.revision
        await restored.requestDiscoveryAssistant()
        XCTAssertEqual(restored.discovery?.revision, revision)
        XCTAssertEqual(
            restored.discovery?.state,
            .awaitingMoreEvidence
        )
    }

    func testAssistantDraftReviewRestoresFromDurableBoundary()
        async throws
    {
        let client = FakeCoreClient()
        let credentials = InMemoryCredentialStore()
        let first = makeViewModel(
            client: client,
            credentials: credentials
        )
        await first.refresh()
        first.prepareDiscovery(method: .website)
        first.discoveryDisplayName = "도우미 초안 복원"
        first.discoveryURL =
            "https://docs.example.invalid/provider"
        first.credentialDraft = "synthetic-assistant-secret"
        await first.startDiscovery()
        guard case let .assistantConsent(consent) =
            first.discovery?.actionRequired
        else {
            return XCTFail("Expected assistant consent")
        }
        await first.continueDiscovery(
            .approveAssistant(
                approvalID: consent.approvalID,
                grantSHA256: consent.grantSHA256
            )
        )
        guard case let .reviewDraft(firstReview) =
            first.assistantHostAction
        else {
            return XCTFail("Expected typed draft review")
        }

        let restored = makeViewModel(
            client: client,
            credentials: credentials
        )
        await restored.refresh()

        XCTAssertEqual(
            restored.discovery?.assistantResumeBoundary?.action,
            .reviewDraft
        )
        XCTAssertEqual(
            restored.discovery?.assistantApprovalBinding?
                .assistantModelRouteID,
            consent.assistantModelRouteID
        )
        XCTAssertEqual(
            restored.selectedAssistantModelRouteID,
            consent.assistantModelRouteID
        )
        XCTAssertTrue(restored.assistantRouteSelectionIsRunnable)
        guard case let .reviewDraft(restoredReview) =
            restored.assistantHostAction
        else {
            return XCTFail("Expected restored typed draft review")
        }
        XCTAssertEqual(restoredReview, firstReview)
    }

    func testAssistantRevisionWaitsForExplicitRetryApprovalAfterRestart()
        async throws
    {
        let client = FakeCoreClient()
        let credentials = InMemoryCredentialStore()
        let first = makeViewModel(
            client: client,
            credentials: credentials
        )
        await first.refresh()
        first.prepareDiscovery(method: .website)
        first.discoveryDisplayName = "도우미 재시도 복원"
        first.discoveryURL =
            "https://docs.example.invalid/provider"
        first.credentialDraft = "synthetic-assistant-retry-secret"
        await first.startDiscovery()
        guard case let .assistantConsent(consent) =
            first.discovery?.actionRequired
        else {
            return XCTFail("Expected assistant consent")
        }
        await first.continueDiscovery(
            .approveAssistant(
                approvalID: consent.approvalID,
                grantSHA256: consent.grantSHA256
            )
        )
        await first.requestDiscoveryAssistantRevision()
        let revisionBeforeRestart = try XCTUnwrap(
            first.discovery?.revision
        )
        XCTAssertEqual(
            first.discovery?.assistantResumeBoundary?.action,
            .approveRetry
        )
        XCTAssertNil(first.assistantHostAction)

        let restored = makeViewModel(
            client: client,
            credentials: credentials
        )
        await restored.refresh()

        XCTAssertEqual(restored.discovery?.revision, revisionBeforeRestart)
        XCTAssertEqual(
            restored.discovery?.assistantResumeBoundary?.action,
            .approveRetry
        )
        XCTAssertNil(
            restored.assistantHostAction,
            "Refreshing must not replay a provider call."
        )

        await restored.approveDiscoveryAssistantRetry()

        XCTAssertNil(restored.errorMessage)
        XCTAssertGreaterThan(
            restored.discovery?.revision ?? 0,
            revisionBeforeRestart
        )
        guard case .reviewDraft = restored.assistantHostAction else {
            return XCTFail(
                "Explicit retry approval should produce a new review."
            )
        }
    }

    func testCancelledAssistantTurnReconcilesDurableDraft()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        viewModel.prepareDiscovery(method: .website)
        viewModel.discoveryDisplayName = "도우미 취소 복구"
        viewModel.discoveryURL =
            "https://docs.example.invalid/provider"
        viewModel.credentialDraft = "synthetic-assistant-cancel"
        await viewModel.startDiscovery()
        guard case let .assistantConsent(consent) =
            viewModel.discovery?.actionRequired
        else {
            return XCTFail("Expected assistant consent")
        }
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setDiscoveryAssistantTurnCommitHookForTesting {
            await gate.arrive()
        }

        let assistant = Task {
            await viewModel.continueDiscovery(
                .approveAssistant(
                    approvalID: consent.approvalID,
                    grantSHA256: consent.grantSHA256
                )
            )
        }
        await gate.waitForArrival(1)
        assistant.cancel()
        await gate.releaseFirstArrival()
        await assistant.value

        let sessionID = try XCTUnwrap(viewModel.discovery?.id)
        let durable = try await client.getProviderDiscovery(
            sessionID: sessionID
        )
        XCTAssertEqual(viewModel.discovery, durable)
        XCTAssertEqual(
            viewModel.discovery?.assistantResumeBoundary?.action,
            .reviewDraft
        )
        guard case .reviewDraft = viewModel.assistantHostAction else {
            return XCTFail("Expected reconciled draft review")
        }
        XCTAssertTrue(
            viewModel.statusMessage?.contains("다시 확인") == true
        )
        viewModel.setDiscoveryAssistantTurnCommitHookForTesting(nil)
    }

    func testCancelledDirectAssistantRunReconcilesDurableDraft()
        async throws
    {
        let client = FakeCoreClient()
        let credentials = InMemoryCredentialStore()
        let setup = makeViewModel(
            client: client,
            credentials: credentials
        )
        await setup.refresh()
        setup.prepareDiscovery(method: .website)
        setup.discoveryDisplayName = "직접 도우미 취소 복구"
        setup.discoveryURL =
            "https://docs.example.invalid/provider"
        setup.credentialDraft = "synthetic-direct-assistant-cancel"
        await setup.startDiscovery()
        guard case let .assistantConsent(consent) =
            setup.discovery?.actionRequired
        else {
            return XCTFail("Expected assistant consent")
        }
        await setup.continueDiscovery(
            .approveAssistant(
                approvalID: consent.approvalID,
                grantSHA256: consent.grantSHA256
            )
        )
        await setup.requestDiscoveryAssistantRevision()
        let sessionID = try XCTUnwrap(setup.discovery?.id)
        let runBoundary =
            try await client
                .approveProviderDiscoveryAssistantRetry(
                    sessionID: sessionID
                )
        XCTAssertEqual(
            runBoundary.assistantResumeBoundary?.action,
            .runAssistant
        )

        let restored = makeViewModel(
            client: client,
            credentials: credentials
        )
        await restored.refresh()
        let revisionBeforeRun = try XCTUnwrap(
            restored.discovery?.revision
        )
        XCTAssertEqual(
            restored.discovery?.assistantResumeBoundary?.action,
            .runAssistant
        )
        XCTAssertNil(restored.assistantHostAction)
        let gate = ProviderSetupRefreshCommitGate()
        restored.setDiscoveryAssistantTurnCommitHookForTesting {
            await gate.arrive()
        }

        let assistant = Task {
            await restored.runDiscoveryAssistant()
        }
        await gate.waitForArrival(1)
        let committedBeforeReconciliation =
            try await client.getProviderDiscovery(
                sessionID: sessionID
            )
        XCTAssertGreaterThan(
            committedBeforeReconciliation.revision,
            revisionBeforeRun
        )
        XCTAssertEqual(
            restored.discovery?.revision,
            revisionBeforeRun,
            "The gate must pause after the durable turn and before UI reconciliation."
        )
        assistant.cancel()
        await gate.releaseFirstArrival()
        await assistant.value

        let durable = try await client.getProviderDiscovery(
            sessionID: sessionID
        )
        XCTAssertEqual(restored.discovery, durable)
        XCTAssertEqual(
            restored.discovery?.assistantResumeBoundary?.action,
            .reviewDraft
        )
        guard case .reviewDraft = restored.assistantHostAction else {
            return XCTFail("Expected reconciled direct draft review")
        }
        XCTAssertTrue(
            restored.statusMessage?.contains("다시 확인") == true
        )
        restored.setDiscoveryAssistantTurnCommitHookForTesting(nil)
    }

    func testCancelledAssistantRetryReconcilesWithoutRunningModel()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        viewModel.prepareDiscovery(method: .website)
        viewModel.discoveryDisplayName = "도우미 재시도 취소"
        viewModel.discoveryURL =
            "https://docs.example.invalid/provider"
        viewModel.credentialDraft = "synthetic-retry-cancel"
        await viewModel.startDiscovery()
        guard case let .assistantConsent(consent) =
            viewModel.discovery?.actionRequired
        else {
            return XCTFail("Expected assistant consent")
        }
        await viewModel.continueDiscovery(
            .approveAssistant(
                approvalID: consent.approvalID,
                grantSHA256: consent.grantSHA256
            )
        )
        await viewModel.requestDiscoveryAssistantRevision()
        let revisionBeforeApproval = try XCTUnwrap(
            viewModel.discovery?.revision
        )
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setDiscoveryAssistantRetryCommitHookForTesting {
            await gate.arrive()
        }

        let retry = Task {
            await viewModel.approveDiscoveryAssistantRetry()
        }
        await gate.waitForArrival(1)
        retry.cancel()
        await gate.releaseFirstArrival()
        await retry.value

        let sessionID = try XCTUnwrap(viewModel.discovery?.id)
        let durable = try await client.getProviderDiscovery(
            sessionID: sessionID
        )
        XCTAssertEqual(viewModel.discovery, durable)
        XCTAssertEqual(
            viewModel.discovery?.revision,
            revisionBeforeApproval + 1
        )
        XCTAssertEqual(
            viewModel.discovery?.assistantResumeBoundary?.action,
            .runAssistant
        )
        XCTAssertNil(
            viewModel.assistantHostAction,
            "Cancellation must not replay the assistant turn."
        )
        XCTAssertTrue(
            viewModel.statusMessage?.contains("취소") == true
        )
        viewModel.setDiscoveryAssistantRetryCommitHookForTesting(nil)
    }

    func testCancelledAssistantCoreHostResumeReconcilesDurableBoundary()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        viewModel.prepareDiscovery(method: .website)
        viewModel.discoveryDisplayName = "도우미 도구 재개 취소"
        viewModel.discoveryURL =
            "https://docs.example.invalid/provider"
        viewModel.credentialDraft = "synthetic-resume-cancel"
        await viewModel.startDiscovery()
        guard case let .assistantConsent(consent) =
            viewModel.discovery?.actionRequired
        else {
            return XCTFail("Expected assistant consent")
        }
        await viewModel.continueDiscovery(
            .approveAssistant(
                approvalID: consent.approvalID,
                grantSHA256: consent.grantSHA256
            )
        )
        await viewModel.requestDiscoveryAssistantRevision()
        let retryBoundary = try XCTUnwrap(viewModel.discovery)
        viewModel.replaceDiscoverySnapshotForTesting(
            discoverySnapshot(
                retryBoundary,
                replacingID: retryBoundary.id,
                assistantResumeBoundary:
                    ProviderDiscoveryAssistantResumeBoundary(
                        checkpoint: .awaitingToolResult,
                        action: .resumeCoreHostAction
                    )
            )
        )
        viewModel
            .setDiscoveryAssistantCoreHostResumeInvocationForTesting {
                sessionID in
                try await client
                    .approveProviderDiscoveryAssistantRetry(
                        sessionID: sessionID
                    )
            }
        let gate = ProviderSetupRefreshCommitGate()
        viewModel
            .setDiscoveryAssistantCoreHostResumeCommitHookForTesting {
                await gate.arrive()
            }

        let resume = Task {
            await viewModel
                .resumeDiscoveryAssistantCoreHostAction()
        }
        await gate.waitForArrival(1)
        resume.cancel()
        await gate.releaseFirstArrival()
        await resume.value

        let durable = try await client.getProviderDiscovery(
            sessionID: retryBoundary.id
        )
        XCTAssertEqual(viewModel.discovery, durable)
        XCTAssertEqual(
            viewModel.discovery?.revision,
            retryBoundary.revision + 1
        )
        XCTAssertEqual(
            viewModel.discovery?.assistantResumeBoundary?.action,
            .runAssistant
        )
        XCTAssertNil(viewModel.assistantHostAction)
        XCTAssertTrue(
            viewModel.statusMessage?.contains("재개됐지만") == true
        )
        viewModel
            .setDiscoveryAssistantCoreHostResumeCommitHookForTesting(nil)
        viewModel
            .setDiscoveryAssistantCoreHostResumeInvocationForTesting(nil)
    }

    func testKnownOllamaUsesCoreTemplateLoopbackMode() async {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        viewModel.prepareDiscovery(method: .knownProvider)
        viewModel.discoveryDisplayName = "로컬 Ollama"

        viewModel.selectDiscoveryTemplate(id: "ollama-v1")

        XCTAssertEqual(
            viewModel.selectedDiscoveryTemplate?
                .defaultNetworkMode,
            .localLoopback
        )
        XCTAssertEqual(
            viewModel.discoveryNetworkMode,
            .localLoopback
        )
        XCTAssertTrue(viewModel.canStartDiscovery)
    }

    func testKnownHostedProvidersNeedOnlyTemplateAndAPIKey() async {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()

        for templateID in [
            "openai-v1",
            "anthropic-v1",
            "gemini-v1",
            "openrouter-v1",
        ] {
            viewModel.prepareDiscovery(method: .knownProvider)
            viewModel.selectDiscoveryTemplate(id: templateID)
            let template = viewModel.selectedDiscoveryTemplate
            XCTAssertEqual(
                viewModel.discoveryDisplayName,
                template?.displayName
            )

            viewModel.credentialDraft = "synthetic-\(templateID)-key"

            XCTAssertTrue(
                viewModel.canStartDiscovery,
                "\(templateID) should need no manual connection name."
            )
        }
    }

    func testUnknownWebsiteSeedsSafeConnectionName() async {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()

        viewModel.prepareDiscovery(method: .website)
        viewModel.discoveryURL = "https://example.invalid/api"
        viewModel.credentialDraft = "synthetic-website-key"

        XCTAssertEqual(
            viewModel.discoveryDisplayName,
            "새 웹사이트 AI"
        )
        XCTAssertTrue(
            viewModel.canStartDiscovery,
            "Website discovery should not require a manual display name."
        )
    }

    func testKnownProviderRequiresAndPersistsManifestConnectionFields()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        viewModel.prepareDiscovery(method: .knownProvider)
        viewModel.discoveryDisplayName = "Manifest 사용자 연결"
        viewModel.selectDiscoveryTemplate(
            id: "synthetic-manifest-fields-v1"
        )
        viewModel.credentialDraft = "synthetic-manifest-secret"

        XCTAssertFalse(
            viewModel.canStartDiscovery,
            "Required manifest fields must gate discovery."
        )
        viewModel.connectionFieldTextValues["project_id"] =
            "synthetic-project"
        viewModel.connectionFieldTextValues["api_version"] =
            "20260801"
        viewModel.connectionFieldBooleanValues["use_vertex"] = true
        XCTAssertTrue(viewModel.canStartDiscovery)

        await viewModel.startDiscovery()

        let values = try XCTUnwrap(
            viewModel.discovery?.connectionOptions.values
        )
        XCTAssertEqual(
            values.first { $0.key == "project_id" }?.value,
            .text("synthetic-project")
        )
        XCTAssertEqual(
            values.first { $0.key == "api_version" }?.value,
            .integer(20_260_801)
        )
        XCTAssertEqual(
            values.first { $0.key == "use_vertex" }?.value,
            .boolean(true)
        )
        XCTAssertFalse(
            values.contains { $0.key == "api_key" },
            "Credential fields must never enter Core config values."
        )
    }

    func testCatalogImportPrepareIsReviewOnlyUntilExactActivation()
        async throws
    {
        let client = FakeCoreClient()
        let envelope = Data(
            #"{"synthetic":"signed-catalog"}"#.utf8
        )
        let before = try await client.getProviderCatalogStatus()

        let plan =
            try await client.prepareSignedProviderCatalogImport(
                envelopeJSON: envelope
            )
        let afterPrepare =
            try await client.getProviderCatalogStatus()

        XCTAssertEqual(
            afterPrepare.currentRevision,
            before.currentRevision,
            "Preparing a review must not change the active catalog."
        )
        XCTAssertEqual(
            plan.review.diff.fromRevision,
            before.currentRevision
        )
        XCTAssertFalse(plan.review.diff.manifestChanges.isEmpty)
        XCTAssertFalse(plan.review.diff.modelChanges.isEmpty)

        do {
            _ = try await client.activateSignedProviderCatalogImport(
                plan: plan,
                envelopeJSON: Data("changed".utf8)
            )
            XCTFail("Activation must be bound to the exact reviewed bytes.")
        } catch {}

        let activated =
            try await client.activateSignedProviderCatalogImport(
                plan: plan,
                envelopeJSON: envelope
            )
        XCTAssertEqual(
            activated.activatedRevision,
            plan.review.candidateRevision
        )
        XCTAssertEqual(
            activated.status.currentRevision,
            plan.review.candidateRevision
        )
    }

    func testCatalogRollbackIsReviewOnlyUntilExactActivation()
        async throws
    {
        let client = FakeCoreClient()
        let envelope = Data(
            #"{"synthetic":"rollback-source"}"#.utf8
        )
        let importPlan =
            try await client.prepareSignedProviderCatalogImport(
                envelopeJSON: envelope
            )
        _ = try await client.activateSignedProviderCatalogImport(
            plan: importPlan,
            envelopeJSON: envelope
        )
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        XCTAssertEqual(viewModel.catalogStatus?.currentRevision, 2)

        await viewModel.prepareCatalogRollback(to: 1)

        XCTAssertEqual(
            viewModel.catalogStatus?.currentRevision,
            2,
            "Preparing rollback review must not mutate active catalog."
        )
        let rollback = try XCTUnwrap(
            viewModel.pendingCatalogRollback
        )
        XCTAssertEqual(rollback.fromRevision, 2)
        XCTAssertEqual(rollback.toRevision, 1)

        await viewModel.activatePreparedCatalogRollback()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.pendingCatalogRollback)
        XCTAssertEqual(viewModel.catalogStatus?.currentRevision, 1)
    }

    func testCatalogRollbackRejectsStaleCASPlan() async throws {
        let client = FakeCoreClient()
        let firstEnvelope = Data(
            #"{"synthetic":"first"}"#.utf8
        )
        let firstImport =
            try await client.prepareSignedProviderCatalogImport(
                envelopeJSON: firstEnvelope
            )
        _ = try await client.activateSignedProviderCatalogImport(
            plan: firstImport,
            envelopeJSON: firstEnvelope
        )
        let staleRollback =
            try await client.prepareProviderCatalogRollback(
                targetRevision: 1
            )
        let secondEnvelope = Data(
            #"{"synthetic":"second"}"#.utf8
        )
        let secondImport =
            try await client.prepareSignedProviderCatalogImport(
                envelopeJSON: secondEnvelope
            )
        _ = try await client.activateSignedProviderCatalogImport(
            plan: secondImport,
            envelopeJSON: secondEnvelope
        )

        do {
            _ = try await client.activateProviderCatalogRollback(
                plan: staleRollback
            )
            XCTFail("A stale state-bound rollback plan must fail.")
        } catch {}
        let status = try await client.getProviderCatalogStatus()
        XCTAssertEqual(status.currentRevision, 3)
    }

    func testCancelledCatalogRollbackReviewCannotReappear()
        async throws
    {
        let client = FakeCoreClient()
        let envelope = Data(#"{"synthetic":"rollback-cancel"}"#.utf8)
        let importPlan =
            try await client.prepareSignedProviderCatalogImport(
                envelopeJSON: envelope
            )
        _ = try await client.activateSignedProviderCatalogImport(
            plan: importPlan,
            envelopeJSON: envelope
        )
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setCatalogReviewCommitHookForTesting {
            await gate.arrive()
        }

        let stalePrepare = Task {
            await viewModel.prepareCatalogRollback(to: 1)
        }
        await gate.waitForArrival(1)
        viewModel.cancelPreparedCatalogRollback()
        let cancelledStatus = viewModel.statusMessage
        await gate.releaseFirstArrival()
        await stalePrepare.value

        XCTAssertNil(viewModel.pendingCatalogRollback)
        XCTAssertEqual(viewModel.statusMessage, cancelledStatus)
        XCTAssertNil(viewModel.errorMessage)
        viewModel.setCatalogReviewCommitHookForTesting(nil)
    }

    func testCancelledCatalogImportReviewCannotReappear()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        let envelope = Data(#"{"synthetic":"import-cancel"}"#.utf8)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "lorepia-import-cancel-\(UUID().uuidString).json"
            )
        try envelope.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setCatalogReviewCommitHookForTesting {
            await gate.arrive()
        }

        let stalePrepare = Task {
            await viewModel.prepareSignedCatalogImport(
                from: fileURL
            )
        }
        await gate.waitForArrival(1)
        viewModel.cancelPreparedCatalogImport()
        let cancelledStatus = viewModel.statusMessage
        await gate.releaseFirstArrival()
        await stalePrepare.value

        XCTAssertNil(viewModel.pendingCatalogImport)
        XCTAssertNil(viewModel.pendingCatalogImportFilename)
        XCTAssertEqual(viewModel.statusMessage, cancelledStatus)
        XCTAssertNil(viewModel.errorMessage)
        viewModel.setCatalogReviewCommitHookForTesting(nil)
    }

    func testCatalogRollbackActivationPreservesRefreshFailure()
        async throws
    {
        let client = FakeCoreClient()
        let envelope = Data(#"{"synthetic":"rollback-partial"}"#.utf8)
        let importPlan =
            try await client.prepareSignedProviderCatalogImport(
                envelopeJSON: envelope
            )
        _ = try await client.activateSignedProviderCatalogImport(
            plan: importPlan,
            envelopeJSON: envelope
        )
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        await viewModel.prepareCatalogRollback(to: 1)
        viewModel.setCatalogPostActivationRefreshHookForTesting {
            throw CoreClientFailure.startupFailed(
                "synthetic catalog refresh failure"
            )
        }

        await viewModel.activatePreparedCatalogRollback()

        XCTAssertEqual(viewModel.catalogStatus?.currentRevision, 1)
        XCTAssertNil(viewModel.pendingCatalogRollback)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(
            viewModel.statusMessage?.contains("적용됐지만") == true
        )
        viewModel.setCatalogPostActivationRefreshHookForTesting(nil)
    }

    func testCatalogImportActivationPreservesRefreshFailure()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        let envelope = Data(#"{"synthetic":"import-partial"}"#.utf8)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "lorepia-import-partial-\(UUID().uuidString).json"
            )
        try envelope.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        await viewModel.prepareSignedCatalogImport(from: fileURL)
        viewModel.setCatalogPostActivationRefreshHookForTesting {
            throw CoreClientFailure.startupFailed(
                "synthetic catalog refresh failure"
            )
        }

        await viewModel.activatePreparedCatalogImport()

        XCTAssertEqual(viewModel.catalogStatus?.currentRevision, 2)
        XCTAssertNil(viewModel.pendingCatalogImport)
        XCTAssertNil(viewModel.pendingCatalogImportFilename)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(
            viewModel.statusMessage?.contains("적용됐지만") == true
        )
        viewModel.setCatalogPostActivationRefreshHookForTesting(nil)
    }

    func testModelSyncStagesReviewBeforeApplyingNewRoute() async {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        XCTAssertEqual(viewModel.modelRoutes.count, 1)

        await viewModel.startModelSync()

        XCTAssertEqual(viewModel.modelSyncJob?.state, .awaitingReview)
        XCTAssertEqual(
            viewModel.modelSyncJob?.diff?.newRoutes.map(\.modelID),
            ["example-pro-2"]
        )
        XCTAssertEqual(viewModel.modelRoutes.count, 1)

        await viewModel.approveModelSync()

        XCTAssertEqual(viewModel.modelSyncJob?.state, .completed)
        XCTAssertEqual(
            Set(viewModel.modelRoutes.map(\.modelID)),
            ["preview-model", "example-pro-2"]
        )
        let discovered = viewModel.modelRoutes.first {
            $0.modelID == "example-pro-2"
        }
        XCTAssertEqual(discovered?.metadataSource, "provider_api")
        XCTAssertNotNil(discovered?.metadataObservedAt)
    }

    func testModelSyncEventsAreJobScopedAndAckedExactly()
        async throws
    {
        let client = FakeCoreClient()
        let first = try await client.startProviderModelSync(
            connectionID: "preview-provider",
            credential: nil
        )
        let second = try await client.startProviderModelSync(
            connectionID: "preview-provider",
            credential: nil
        )

        let firstEvents =
            try await client.pollProviderModelSyncEvents(
                jobID: first.id,
                limit: 16
            )
        let secondEvents =
            try await client.pollProviderModelSyncEvents(
                jobID: second.id,
                limit: 16
            )

        XCTAssertFalse(firstEvents.isEmpty)
        XCTAssertFalse(secondEvents.isEmpty)
        XCTAssertTrue(firstEvents.allSatisfy {
            $0.jobID == first.id
        })
        XCTAssertTrue(secondEvents.allSatisfy {
            $0.jobID == second.id
        })

        let firstSequence = try XCTUnwrap(
            firstEvents.first?.sequence
        )
        let firstAcked =
            try await client.ackProviderModelSyncEvent(
                jobID: first.id,
                sequence: firstSequence
            )
        XCTAssertTrue(firstAcked)
        let remainingFirstEvents =
            try await client.pollProviderModelSyncEvents(
                jobID: first.id,
                limit: 16
            )
        XCTAssertTrue(
            remainingFirstEvents.isEmpty
        )
        let remainingSecondEvents =
            try await client.pollProviderModelSyncEvents(
                jobID: second.id,
                limit: 16
            )
        XCTAssertEqual(
            remainingSecondEvents,
            secondEvents,
            "Acknowledging one job must not drain another job's event."
        )
    }

    func testModelSyncRestoresAcrossViewModelRestart() async throws {
        let client = FakeCoreClient()
        let firstViewModel = makeViewModel(client: client)
        await firstViewModel.refresh()
        await firstViewModel.startModelSync()
        let jobID = try XCTUnwrap(firstViewModel.modelSyncJob?.id)

        let restoredViewModel = makeViewModel(client: client)
        await restoredViewModel.refresh()

        XCTAssertEqual(restoredViewModel.modelSyncJob?.id, jobID)
        XCTAssertEqual(
            restoredViewModel.modelSyncJob?.state,
            .awaitingReview
        )
    }

    func testDefaultSelectionSuccessReconcilesAfterCancellationAndMove()
        async throws
    {
        let first = ProviderProfile(
            id: "default-race-a",
            displayName: "A",
            baseURL: "https://a.example.invalid/v1",
            model: "a-model",
            timeoutSeconds: 30
        )
        let second = ProviderProfile(
            id: "default-race-b",
            displayName: "B",
            baseURL: "https://b.example.invalid/v1",
            model: "b-model",
            timeoutSeconds: 30
        )
        let client = FakeCoreClient(profiles: [first, second])
        let store = ProviderConfigurationStore()
        let viewModel = ProviderSetupViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        await viewModel.refresh()
        await viewModel.selectConnection(id: first.id)
        let target = ProviderGenerationTarget(
            modelRouteID: try XCTUnwrap(
                viewModel.selectedModelRouteID
            ),
            generationPresetID: try XCTUnwrap(
                viewModel.selectedPresetID
            )
        )
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setDefaultSelectionCommitHookForTesting {
            await gate.arrive()
        }

        let selection = Task {
            await viewModel.useSelectedPresetAsAppDefault()
        }
        await gate.waitForArrival(1)
        selection.cancel()
        await viewModel.selectConnection(id: second.id)
        let secondRoutes = viewModel.modelRoutes
        await gate.releaseFirstArrival()
        await selection.value

        XCTAssertEqual(viewModel.selectedConnectionID, second.id)
        XCTAssertEqual(viewModel.modelRoutes, secondRoutes)
        XCTAssertEqual(viewModel.activeGenerationTarget, target)
        XCTAssertEqual(store.selectedConnectionID, first.id)
        XCTAssertEqual(store.selectedGenerationTarget, target)
        viewModel.setDefaultSelectionCommitHookForTesting(nil)
    }

    func testCancelledPostUpsertStillPublishesSavedPreset()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        viewModel.beginNewPreset()
        viewModel.presetName = "Durable Cancelled Save"
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setPresetSaveCommitHookForTesting {
            await gate.arrive()
        }

        let save = Task {
            await viewModel.savePreset()
        }
        await gate.waitForArrival(1)
        let savedID = try XCTUnwrap(viewModel.selectedPresetID)
        save.cancel()
        await gate.releaseFirstArrival()
        await save.value

        XCTAssertEqual(viewModel.selectedPresetID, savedID)
        XCTAssertTrue(
            viewModel.presets.contains { $0.id == savedID }
        )
        let durable = try await client
            .listProviderGenerationPresets(
                modelRouteID: try XCTUnwrap(
                    viewModel.selectedModelRouteID
                )
            )
        XCTAssertTrue(durable.contains { $0.id == savedID })
        XCTAssertTrue(
            viewModel.statusMessage?.contains("저장") == true
        )
        viewModel.setPresetSaveCommitHookForTesting(nil)
    }

    func testPostUpsertFailureReportsPartialSuccess()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        viewModel.beginNewPreset()
        viewModel.presetName = "Durable Failed Postflight"
        viewModel.setPresetSaveCommitHookForTesting {
            throw ProviderSetupCredentialFailure.injected
        }

        await viewModel.savePreset()

        let savedID = try XCTUnwrap(viewModel.selectedPresetID)
        XCTAssertTrue(
            viewModel.presets.contains { $0.id == savedID }
        )
        XCTAssertTrue(
            viewModel.statusMessage?.contains("저장됐지만") == true
        )
        XCTAssertNotNil(viewModel.errorMessage)
        viewModel.setPresetSaveCommitHookForTesting(nil)
    }

    func testPostUpsertPublishPreservesNewerSameRouteEditorDraft()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        viewModel.beginNewPreset()
        viewModel.presetName = "Committed Before ABA"
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setPresetSavePrePublishHookForTesting {
            await gate.arrive()
        }

        let save = Task {
            await viewModel.savePreset()
        }
        await gate.waitForArrival(1)
        viewModel.presetName = "Newer Unsaved Draft"
        let newerStatus = viewModel.statusMessage
        let newerError = viewModel.errorMessage
        await gate.releaseFirstArrival()
        await save.value

        let routeID = try XCTUnwrap(
            viewModel.selectedModelRouteID
        )
        let durable = try await client
            .listProviderGenerationPresets(
                modelRouteID: routeID
            )
        let committed = try XCTUnwrap(
            durable.first {
                $0.displayName == "Committed Before ABA"
            }
        )
        XCTAssertTrue(
            viewModel.presets.contains { $0.id == committed.id },
            "The durable collection must still publish the committed record."
        )
        XCTAssertEqual(viewModel.presetName, "Newer Unsaved Draft")
        XCTAssertNotEqual(viewModel.selectedPresetID, committed.id)
        XCTAssertEqual(viewModel.statusMessage, newerStatus)
        XCTAssertEqual(viewModel.errorMessage, newerError)
        viewModel.setPresetSavePrePublishHookForTesting(nil)
    }

    func testMismatchedPresetSaveResponseReconcilesDurableCollection()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        viewModel.beginNewPreset()
        viewModel.presetName = "Durable Mismatched Save"
        viewModel.setPresetSaveResultTransformForTesting {
            presetRecord(
                $0,
                replacingID: "mismatched-\($0.id)"
            )
        }

        await viewModel.savePreset()

        let routeID = try XCTUnwrap(
            viewModel.selectedModelRouteID
        )
        let durable = try await client
            .listProviderGenerationPresets(
                modelRouteID: routeID
            )
        let committed = try XCTUnwrap(
            durable.first {
                $0.displayName == "Durable Mismatched Save"
            }
        )
        XCTAssertTrue(
            viewModel.presets.contains { $0.id == committed.id }
        )
        XCTAssertFalse(
            viewModel.presets.contains {
                $0.id == "mismatched-\(committed.id)"
            }
        )
        XCTAssertTrue(
            viewModel.statusMessage?.contains("다시 확인") == true
        )
        XCTAssertNotNil(viewModel.errorMessage)
        viewModel.setPresetSaveResultTransformForTesting(nil)
    }

    func testMismatchedPresetSavePreservesNewerSameRouteEditorStatus()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        viewModel.beginNewPreset()
        viewModel.presetName = "Committed Mismatch ABA"
        viewModel.setPresetSaveResultTransformForTesting {
            presetRecord(
                $0,
                replacingID: "mismatched-\($0.id)"
            )
        }
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setPresetSavePrePublishHookForTesting {
            await gate.arrive()
        }

        let save = Task {
            await viewModel.savePreset()
        }
        await gate.waitForArrival(1)
        viewModel.presetName = "Newer Mismatch Draft"
        let newerStatus = viewModel.statusMessage
        let newerError = viewModel.errorMessage
        await gate.releaseFirstArrival()
        await save.value

        let durable = try await client
            .listProviderGenerationPresets(
                modelRouteID: try XCTUnwrap(
                    viewModel.selectedModelRouteID
                )
            )
        let committed = try XCTUnwrap(
            durable.first {
                $0.displayName == "Committed Mismatch ABA"
            }
        )
        XCTAssertTrue(
            viewModel.presets.contains { $0.id == committed.id }
        )
        XCTAssertEqual(viewModel.presetName, "Newer Mismatch Draft")
        XCTAssertEqual(viewModel.statusMessage, newerStatus)
        XCTAssertEqual(viewModel.errorMessage, newerError)
        viewModel.setPresetSavePrePublishHookForTesting(nil)
        viewModel.setPresetSaveResultTransformForTesting(nil)
    }

    func testPostUpsertResponseFailureReconcilesDurableCollection()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        viewModel.beginNewPreset()
        viewModel.presetName = "Durable Response Failure"
        viewModel.setPresetSaveResponseFailureHookForTesting {
            throw ProviderSetupCredentialFailure.injected
        }

        await viewModel.savePreset()

        let routeID = try XCTUnwrap(
            viewModel.selectedModelRouteID
        )
        let durable = try await client
            .listProviderGenerationPresets(
                modelRouteID: routeID
            )
        let committed = try XCTUnwrap(
            durable.first {
                $0.displayName == "Durable Response Failure"
            }
        )
        XCTAssertTrue(
            viewModel.presets.contains { $0.id == committed.id }
        )
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(
            viewModel.statusMessage?.contains("저장됐지만") == true
        )
        viewModel.setPresetSaveResponseFailureHookForTesting(nil)
    }

    func testPresetDeleteHookFailureStillPublishesDurableDeletion()
        async throws
    {
        let client = FakeCoreClient()
        let store = ProviderConfigurationStore()
        let viewModel = ProviderSetupViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        await viewModel.refresh()
        viewModel.beginNewPreset()
        viewModel.presetName = "Delete Despite Hook Failure"
        await viewModel.savePreset()
        let deletedID = try XCTUnwrap(viewModel.selectedPresetID)
        await viewModel.useSelectedPresetAsAppDefault()
        viewModel.setPresetDeletionCommitHookForTesting {
            throw ProviderSetupCredentialFailure.injected
        }

        await viewModel.deleteSelectedPreset()

        let routeID = try XCTUnwrap(
            viewModel.selectedModelRouteID
        )
        let durable = try await client
            .listProviderGenerationPresets(
                modelRouteID: routeID
            )
        let settings = try await client.getSettings()
        XCTAssertFalse(durable.contains { $0.id == deletedID })
        XCTAssertFalse(
            viewModel.presets.contains { $0.id == deletedID }
        )
        XCTAssertNil(settings.selectedGenerationTarget)
        XCTAssertNil(viewModel.activeGenerationTarget)
        XCTAssertNil(store.selectedGenerationTarget)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(
            viewModel.statusMessage?.contains("삭제됐지만") == true
        )
        viewModel.setPresetDeletionCommitHookForTesting(nil)
    }

    func testCancelledPresetDeleteStillPublishesDurableDeletion()
        async throws
    {
        let client = FakeCoreClient()
        let store = ProviderConfigurationStore()
        let viewModel = ProviderSetupViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        await viewModel.refresh()
        viewModel.beginNewPreset()
        viewModel.presetName = "Delete Despite Cancellation"
        await viewModel.savePreset()
        let deletedID = try XCTUnwrap(viewModel.selectedPresetID)
        await viewModel.useSelectedPresetAsAppDefault()
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setPresetDeletionCommitHookForTesting {
            await gate.arrive()
        }

        let deletion = Task {
            await viewModel.deleteSelectedPreset()
        }
        await gate.waitForArrival(1)
        deletion.cancel()
        await gate.releaseFirstArrival()
        await deletion.value

        let routeID = try XCTUnwrap(
            viewModel.selectedModelRouteID
        )
        let durable = try await client
            .listProviderGenerationPresets(
                modelRouteID: routeID
            )
        let settings = try await client.getSettings()
        XCTAssertFalse(durable.contains { $0.id == deletedID })
        XCTAssertFalse(
            viewModel.presets.contains { $0.id == deletedID }
        )
        XCTAssertNil(settings.selectedGenerationTarget)
        XCTAssertNil(viewModel.activeGenerationTarget)
        XCTAssertNil(store.selectedGenerationTarget)
        XCTAssertTrue(
            viewModel.statusMessage?.contains("삭제") == true
        )
        viewModel.setPresetDeletionCommitHookForTesting(nil)
    }

    func testPresetDeletePreservesNewerSameRouteSiblingSelection()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        viewModel.beginNewPreset()
        viewModel.presetName = "Sibling One"
        await viewModel.savePreset()
        let siblingID = try XCTUnwrap(viewModel.selectedPresetID)
        viewModel.beginNewPreset()
        viewModel.presetName = "Sibling Two"
        await viewModel.savePreset()
        let deletedID = try XCTUnwrap(viewModel.selectedPresetID)
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setPresetDeletionCommitHookForTesting {
            await gate.arrive()
        }

        let deletion = Task {
            await viewModel.deleteSelectedPreset()
        }
        await gate.waitForArrival(1)
        await viewModel.selectPreset(id: siblingID)
        let siblingName = viewModel.presetName
        let siblingPreview = viewModel.currentRequestPreview
        let siblingStatus = viewModel.statusMessage
        let siblingError = viewModel.errorMessage
        await gate.releaseFirstArrival()
        await deletion.value

        XCTAssertEqual(viewModel.selectedPresetID, siblingID)
        XCTAssertEqual(viewModel.presetName, siblingName)
        XCTAssertEqual(
            viewModel.currentRequestPreview,
            siblingPreview
        )
        XCTAssertEqual(viewModel.statusMessage, siblingStatus)
        XCTAssertEqual(viewModel.errorMessage, siblingError)
        XCTAssertFalse(
            viewModel.presets.contains { $0.id == deletedID }
        )
        let durable = try await client
            .listProviderGenerationPresets(
                modelRouteID: try XCTUnwrap(
                    viewModel.selectedModelRouteID
                )
            )
        XCTAssertFalse(durable.contains { $0.id == deletedID })
        viewModel.setPresetDeletionCommitHookForTesting(nil)
    }

    func testMismatchedDefaultResponseReconcilesDurableTarget()
        async throws
    {
        let client = FakeCoreClient()
        let store = ProviderConfigurationStore()
        let viewModel = ProviderSetupViewModel(
            client: client,
            credentialStore: InMemoryCredentialStore(),
            runtimeMode: .preview,
            providerConfigurationStore: store
        )
        await viewModel.refresh()
        viewModel.beginNewPreset()
        viewModel.presetName = "Durable Default"
        await viewModel.savePreset()
        let target = ProviderGenerationTarget(
            modelRouteID: try XCTUnwrap(
                viewModel.selectedModelRouteID
            ),
            generationPresetID: try XCTUnwrap(
                viewModel.selectedPresetID
            )
        )
        viewModel.setDefaultSelectionResultTransformForTesting {
            CoreAppSettings(
                preservePartialGenerations:
                    $0.preservePartialGenerations,
                selectedProviderProfileID:
                    $0.selectedProviderProfileID,
                selectedModelRouteID: nil,
                selectedGenerationPresetID: nil
            )
        }

        await viewModel.useSelectedPresetAsAppDefault()

        let settings = try await client.getSettings()
        XCTAssertEqual(
            settings.selectedGenerationTarget,
            target
        )
        XCTAssertEqual(viewModel.activeGenerationTarget, target)
        XCTAssertEqual(store.selectedGenerationTarget, target)
        XCTAssertTrue(
            viewModel.statusMessage?.contains("다시 확인") == true
        )
        XCTAssertNotNil(viewModel.errorMessage)
        viewModel.setDefaultSelectionResultTransformForTesting(nil)
    }

    func testConnectionDeleteAfterSameIDRefreshRepairsHierarchy()
        async throws
    {
        let first = ProviderProfile(
            id: "delete-refresh-a",
            displayName: "A",
            baseURL: "https://a.example.invalid/v1",
            model: "a-model",
            timeoutSeconds: 30
        )
        let second = ProviderProfile(
            id: "delete-refresh-b",
            displayName: "B",
            baseURL: "https://b.example.invalid/v1",
            model: "b-model",
            timeoutSeconds: 30
        )
        let client = FakeCoreClient(profiles: [first, second])
        let credentials = InMemoryCredentialStore(
            values: [first.id: "synthetic-delete-key"]
        )
        let viewModel = makeViewModel(
            client: client,
            credentials: credentials
        )
        await viewModel.refresh()
        await viewModel.selectConnection(id: first.id)
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setConnectionDeletionPreCommitHookForTesting {
            await gate.arrive()
        }

        let deletion = Task {
            await viewModel.deleteSelectedConnection()
        }
        await gate.waitForArrival(1)
        await viewModel.refresh()
        XCTAssertEqual(viewModel.selectedConnectionID, first.id)
        await gate.releaseFirstArrival()
        await deletion.value

        XCTAssertEqual(viewModel.selectedConnectionID, second.id)
        XCTAssertFalse(
            viewModel.connections.contains { $0.id == first.id }
        )
        XCTAssertTrue(
            viewModel.modelRoutes.allSatisfy {
                $0.connectionID == second.id
            }
        )
        XCTAssertFalse(viewModel.isSelectionLoading)
        viewModel.setConnectionDeletionPreCommitHookForTesting(nil)
    }

    func testConnectionDeleteReconciliationPreservesLaterSelection()
        async throws
    {
        let first = ProviderProfile(
            id: "delete-reconcile-a",
            displayName: "A",
            baseURL: "https://a.example.invalid/v1",
            model: "a-model",
            timeoutSeconds: 30
        )
        let second = ProviderProfile(
            id: "delete-reconcile-b",
            displayName: "B",
            baseURL: "https://b.example.invalid/v1",
            model: "b-model",
            timeoutSeconds: 30
        )
        let third = ProviderProfile(
            id: "delete-reconcile-c",
            displayName: "C",
            baseURL: "https://c.example.invalid/v1",
            model: "c-model",
            timeoutSeconds: 30
        )
        let client = FakeCoreClient(profiles: [first, second, third])
        let credentials = InMemoryCredentialStore(
            values: [first.id: "synthetic-delete-key"]
        )
        let viewModel = makeViewModel(
            client: client,
            credentials: credentials
        )
        await viewModel.refresh()
        await viewModel.selectConnection(id: first.id)
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setActiveGenerationReconciliationCommitHookForTesting {
            await gate.arrive()
        }

        let deletion = Task {
            await viewModel.deleteSelectedConnection()
        }
        await gate.waitForArrival(1)
        await viewModel.selectConnection(id: third.id)
        let selectedRoutes = viewModel.modelRoutes
        let selectedPresets = viewModel.presets
        let selectedPreview = viewModel.currentRequestPreview
        let selectedStatus = viewModel.statusMessage
        let selectedError = viewModel.errorMessage

        await gate.releaseFirstArrival()
        await deletion.value

        XCTAssertEqual(viewModel.selectedConnectionID, third.id)
        XCTAssertEqual(viewModel.modelRoutes, selectedRoutes)
        XCTAssertEqual(viewModel.presets, selectedPresets)
        XCTAssertEqual(
            viewModel.currentRequestPreview,
            selectedPreview
        )
        XCTAssertEqual(viewModel.statusMessage, selectedStatus)
        XCTAssertEqual(viewModel.errorMessage, selectedError)
        XCTAssertFalse(
            viewModel.connections.contains { $0.id == first.id }
        )
        XCTAssertTrue(
            viewModel.modelRoutes.allSatisfy {
                $0.connectionID == third.id
            }
        )
        XCTAssertFalse(viewModel.isSelectionLoading)
        viewModel.setActiveGenerationReconciliationCommitHookForTesting(nil)
    }

    func testConnectionDeleteReplacementHandoffPreservesNewerSelection()
        async throws
    {
        let first = ProviderProfile(
            id: "delete-handoff-a",
            displayName: "A",
            baseURL: "https://a.example.invalid/v1",
            model: "a-model",
            timeoutSeconds: 30
        )
        let second = ProviderProfile(
            id: "delete-handoff-b",
            displayName: "B",
            baseURL: "https://b.example.invalid/v1",
            model: "b-model",
            timeoutSeconds: 30
        )
        let third = ProviderProfile(
            id: "delete-handoff-c",
            displayName: "C",
            baseURL: "https://c.example.invalid/v1",
            model: "c-model",
            timeoutSeconds: 30
        )
        let client = FakeCoreClient(
            profiles: [first, second, third]
        )
        let credentials = InMemoryCredentialStore(
            values: [first.id: "synthetic-delete-key"]
        )
        let viewModel = makeViewModel(
            client: client,
            credentials: credentials
        )
        await viewModel.refresh()
        await viewModel.selectConnection(id: first.id)
        let gate = ProviderSetupRefreshCommitGate()
        viewModel
            .setCancellationIndependentSelectionStartHookForTesting {
                await gate.arrive()
            }

        let deletion = Task {
            await viewModel.deleteSelectedConnection()
        }
        await gate.waitForArrival(1)
        await viewModel.selectConnection(id: third.id)
        let selectedRoutes = viewModel.modelRoutes
        let selectedPresets = viewModel.presets
        let selectedPresetID = viewModel.selectedPresetID
        let selectedName = viewModel.presetName
        let selectedStatus = viewModel.statusMessage
        let selectedError = viewModel.errorMessage
        await gate.releaseFirstArrival()
        await deletion.value

        XCTAssertEqual(viewModel.selectedConnectionID, third.id)
        XCTAssertEqual(viewModel.modelRoutes, selectedRoutes)
        XCTAssertEqual(viewModel.presets, selectedPresets)
        XCTAssertEqual(viewModel.selectedPresetID, selectedPresetID)
        XCTAssertEqual(viewModel.presetName, selectedName)
        XCTAssertEqual(viewModel.statusMessage, selectedStatus)
        XCTAssertEqual(viewModel.errorMessage, selectedError)
        XCTAssertFalse(
            viewModel.connections.contains { $0.id == first.id }
        )
        viewModel
            .setCancellationIndependentSelectionStartHookForTesting(nil)
    }

    func testConnectionDeletePostHydrationHandoffPreservesNewerSelection()
        async throws
    {
        let first = ProviderProfile(
            id: "delete-completion-a",
            displayName: "A",
            baseURL: "https://a.example.invalid/v1",
            model: "a-model",
            timeoutSeconds: 30
        )
        let second = ProviderProfile(
            id: "delete-completion-b",
            displayName: "B",
            baseURL: "https://b.example.invalid/v1",
            model: "b-model",
            timeoutSeconds: 30
        )
        let third = ProviderProfile(
            id: "delete-completion-c",
            displayName: "C",
            baseURL: "https://c.example.invalid/v1",
            model: "c-model",
            timeoutSeconds: 30
        )
        let client = FakeCoreClient(
            profiles: [first, second, third]
        )
        let credentials = InMemoryCredentialStore(
            values: [first.id: "synthetic-delete-key"]
        )
        let viewModel = makeViewModel(
            client: client,
            credentials: credentials
        )
        await viewModel.refresh()
        await viewModel.selectConnection(id: first.id)
        let gate = ProviderSetupRefreshCommitGate()
        viewModel
            .setCancellationIndependentSelectionCompletionHookForTesting {
                await gate.arrive()
            }

        let deletion = Task {
            await viewModel.deleteSelectedConnection()
        }
        await gate.waitForArrival(1)
        XCTAssertEqual(
            viewModel.selectedConnectionID,
            second.id,
            "The child hydration must finish before the handoff gate."
        )
        await viewModel.selectConnection(id: third.id)
        let selectedRoutes = viewModel.modelRoutes
        let selectedPresets = viewModel.presets
        let selectedPresetID = viewModel.selectedPresetID
        let selectedName = viewModel.presetName
        let selectedStatus = viewModel.statusMessage
        let selectedError = viewModel.errorMessage
        await gate.releaseFirstArrival()
        await deletion.value

        XCTAssertEqual(viewModel.selectedConnectionID, third.id)
        XCTAssertEqual(viewModel.modelRoutes, selectedRoutes)
        XCTAssertEqual(viewModel.presets, selectedPresets)
        XCTAssertEqual(viewModel.selectedPresetID, selectedPresetID)
        XCTAssertEqual(viewModel.presetName, selectedName)
        XCTAssertEqual(viewModel.statusMessage, selectedStatus)
        XCTAssertEqual(viewModel.errorMessage, selectedError)
        XCTAssertFalse(
            viewModel.connections.contains { $0.id == first.id }
        )
        viewModel
            .setCancellationIndependentSelectionCompletionHookForTesting(
                nil
            )
    }

    func testRollbackActivationIgnoresInFlightCancelAndTaskCancellation()
        async throws
    {
        let client = FakeCoreClient()
        let envelope = Data(#"{"synthetic":"rollback-race"}"#.utf8)
        let imported =
            try await client.prepareSignedProviderCatalogImport(
                envelopeJSON: envelope
            )
        _ = try await client.activateSignedProviderCatalogImport(
            plan: imported,
            envelopeJSON: envelope
        )
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        await viewModel.prepareCatalogRollback(to: 1)
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setCatalogActivationCommitHookForTesting {
            await gate.arrive()
        }

        let activation = Task {
            await viewModel.activatePreparedCatalogRollback()
        }
        await gate.waitForArrival(1)
        viewModel.cancelPreparedCatalogRollback()
        activation.cancel()
        await gate.releaseFirstArrival()
        await activation.value

        XCTAssertEqual(viewModel.catalogStatus?.currentRevision, 1)
        XCTAssertNil(viewModel.pendingCatalogRollback)
        let durable = try await client.getProviderCatalogStatus()
        XCTAssertEqual(durable.currentRevision, 1)
        XCTAssertTrue(
            viewModel.statusMessage?.contains("활성화") == true
        )
        XCTAssertFalse(
            viewModel.statusMessage?.contains("아직 바뀌지 않았") == true
        )
        viewModel.setCatalogActivationCommitHookForTesting(nil)
    }

    func testImportActivationIgnoresInFlightCancelAndTaskCancellation()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        let envelope = Data(#"{"synthetic":"import-race"}"#.utf8)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "lorepia-import-race-\(UUID().uuidString).json"
            )
        try envelope.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        await viewModel.prepareSignedCatalogImport(from: fileURL)
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setCatalogActivationCommitHookForTesting {
            await gate.arrive()
        }

        let activation = Task {
            await viewModel.activatePreparedCatalogImport()
        }
        await gate.waitForArrival(1)
        viewModel.cancelPreparedCatalogImport()
        activation.cancel()
        await gate.releaseFirstArrival()
        await activation.value

        XCTAssertEqual(viewModel.catalogStatus?.currentRevision, 2)
        XCTAssertNil(viewModel.pendingCatalogImport)
        let durable = try await client.getProviderCatalogStatus()
        XCTAssertEqual(durable.currentRevision, 2)
        XCTAssertTrue(
            viewModel.statusMessage?.contains("활성화") == true
        )
        XCTAssertFalse(
            viewModel.statusMessage?.contains("아직 바뀌지 않았") == true
        )
        viewModel.setCatalogActivationCommitHookForTesting(nil)
    }

    func testImportRejectsContradictoryStatusAndReconcilesDurableRevision()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        let envelope = Data(#"{"synthetic":"bad-status"}"#.utf8)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "lorepia-import-status-\(UUID().uuidString).json"
            )
        try envelope.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        await viewModel.prepareSignedCatalogImport(from: fileURL)
        viewModel.setCatalogImportResultTransformForTesting { result in
            ProviderCatalogImportResult(
                signedCatalogRevision: result.signedCatalogRevision,
                activatedRevision: result.activatedRevision,
                diff: result.diff,
                status: ProviderCatalogStatus(
                    schemaVersion: result.status.schemaVersion,
                    currentRevision: 1,
                    currentSource: result.status.currentSource,
                    verifiedSigner: result.status.verifiedSigner,
                    updatedAt: result.status.updatedAt,
                    history: result.status.history
                )
            )
        }

        await viewModel.activatePreparedCatalogImport()

        XCTAssertEqual(viewModel.catalogStatus?.currentRevision, 2)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.pendingCatalogImport)
        viewModel.setCatalogImportResultTransformForTesting(nil)
    }

    func testModelSyncStartReconcilesAfterSameConnectionRefreshAndCancel()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        let connectionID = try XCTUnwrap(
            viewModel.selectedConnectionID
        )
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setModelSyncOperationCommitHookForTesting {
            await gate.arrive()
        }

        let start = Task {
            await viewModel.startModelSync()
        }
        await gate.waitForArrival(1)
        await viewModel.refresh()
        start.cancel()
        await gate.releaseFirstArrival()
        await start.value

        let durable = try await client.listProviderModelSyncs(
            connectionID: connectionID,
            limit: 20
        )
        let job = try XCTUnwrap(durable.first)
        XCTAssertEqual(viewModel.selectedConnectionID, connectionID)
        XCTAssertEqual(viewModel.modelSyncJob?.id, job.id)
        XCTAssertGreaterThanOrEqual(
            viewModel.modelSyncJob?.revision ?? 0,
            job.revision
        )
        XCTAssertTrue(
            viewModel.statusMessage?.contains("시작") == true
                || viewModel.statusMessage?.contains("검토") == true
        )
        viewModel.setModelSyncOperationCommitHookForTesting(nil)
    }

    func testModelSyncApproveReconcilesCompletionAfterCancellation()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        await viewModel.startModelSync()
        XCTAssertEqual(viewModel.modelSyncJob?.state, .awaitingReview)
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setModelSyncOperationCommitHookForTesting {
            await gate.arrive()
        }

        let approval = Task {
            await viewModel.approveModelSync()
        }
        await gate.waitForArrival(1)
        approval.cancel()
        await gate.releaseFirstArrival()
        await approval.value

        XCTAssertEqual(viewModel.modelSyncJob?.state, .completed)
        XCTAssertTrue(
            viewModel.modelRoutes.contains {
                $0.modelID == "example-pro-2"
            }
        )
        XCTAssertTrue(
            viewModel.statusMessage?.contains("적용") == true
        )
        viewModel.setModelSyncOperationCommitHookForTesting(nil)
    }

    func testModelSyncCancelReconcilesTerminalJobAfterCancellation()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        await viewModel.startModelSync()
        let jobID = try XCTUnwrap(viewModel.modelSyncJob?.id)
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setModelSyncOperationCommitHookForTesting {
            await gate.arrive()
        }

        let cancellation = Task {
            await viewModel.cancelModelSync()
        }
        await gate.waitForArrival(1)
        cancellation.cancel()
        await gate.releaseFirstArrival()
        await cancellation.value

        XCTAssertEqual(viewModel.modelSyncJob?.id, jobID)
        XCTAssertEqual(viewModel.modelSyncJob?.state, .cancelled)
        let durable = try await client.getProviderModelSync(
            jobID: jobID
        )
        XCTAssertEqual(durable.state, .cancelled)
        XCTAssertTrue(
            viewModel.statusMessage?.contains("취소") == true
        )
        viewModel.setModelSyncOperationCommitHookForTesting(nil)
    }

    func testModelSyncStartEventFailureRemainsVisible()
        async
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        viewModel.setModelSyncEventPollHookForTesting {
            throw ProviderSetupCredentialFailure.injected
        }

        await viewModel.startModelSync()

        XCTAssertNotNil(viewModel.modelSyncJob)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(
            viewModel.statusMessage?.contains("시작됐지만") == true
        )
        viewModel.setModelSyncEventPollHookForTesting(nil)
    }

    func testModelSyncStartRecoversJobWhenBridgeThrowsAfterCommit()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        let connectionID = try XCTUnwrap(
            viewModel.selectedConnectionID
        )
        viewModel.setModelSyncStartInvocationForTesting {
            requestedConnectionID,
            credential in
            _ = try await client.startProviderModelSync(
                connectionID: requestedConnectionID,
                credential: credential
            )
            throw ProviderSetupCredentialFailure.injected
        }

        await viewModel.startModelSync()

        let durable = try await client.listProviderModelSyncs(
            connectionID: connectionID,
            limit: 64
        )
        let job = try XCTUnwrap(durable.first)
        XCTAssertEqual(durable.count, 1)
        XCTAssertEqual(viewModel.modelSyncJob?.id, job.id)
        XCTAssertEqual(
            viewModel.modelSyncJob?.state,
            .awaitingReview
        )
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(
            viewModel.statusMessage?.contains("시작됐지만") == true
        )
        XCTAssertTrue(
            viewModel.statusMessage?.contains("검토") == true
        )
        viewModel.setModelSyncStartInvocationForTesting(nil)
    }

    func testModelSyncApproveHydrationFailureReportsPartialSuccess()
        async
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        await viewModel.startModelSync()
        viewModel.setConnectionHydrationFailureHookForTesting {
            throw ProviderSetupCredentialFailure.injected
        }

        await viewModel.approveModelSync()

        XCTAssertEqual(viewModel.modelSyncJob?.state, .completed)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(
            viewModel.statusMessage?.contains("적용됐지만") == true
        )
        viewModel.setConnectionHydrationFailureHookForTesting(nil)
    }

    func testModelSyncApproveHandoffPreservesNewerRouteSelection()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        await viewModel.startModelSync()
        let connectionID = try XCTUnwrap(
            viewModel.selectedConnectionID
        )
        let gate = ProviderSetupRefreshCommitGate()
        viewModel
            .setCancellationIndependentSelectionStartHookForTesting {
                await gate.arrive()
            }

        let approval = Task {
            await viewModel.approveModelSync()
        }
        await gate.waitForArrival(1)
        await viewModel.selectConnection(id: connectionID)
        let newerRoute = try XCTUnwrap(
            viewModel.modelRoutes.first {
                $0.modelID == "example-pro-2"
            }
        )
        await viewModel.selectModelRoute(id: newerRoute.id)
        let selectedPresets = viewModel.presets
        let selectedPresetID = viewModel.selectedPresetID
        let selectedName = viewModel.presetName
        let selectedStatus = viewModel.statusMessage
        let selectedError = viewModel.errorMessage
        await gate.releaseFirstArrival()
        await approval.value

        XCTAssertEqual(viewModel.selectedConnectionID, connectionID)
        XCTAssertEqual(viewModel.selectedModelRouteID, newerRoute.id)
        XCTAssertEqual(viewModel.presets, selectedPresets)
        XCTAssertEqual(viewModel.selectedPresetID, selectedPresetID)
        XCTAssertEqual(viewModel.presetName, selectedName)
        XCTAssertEqual(viewModel.statusMessage, selectedStatus)
        XCTAssertEqual(viewModel.errorMessage, selectedError)
        viewModel
            .setCancellationIndependentSelectionStartHookForTesting(nil)
    }

    func testModelSyncApprovePostHydrationHandoffPreservesNewerRoute()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        await viewModel.startModelSync()
        let connectionID = try XCTUnwrap(
            viewModel.selectedConnectionID
        )
        let gate = ProviderSetupRefreshCommitGate()
        viewModel
            .setCancellationIndependentSelectionCompletionHookForTesting {
                await gate.arrive()
            }

        let approval = Task {
            await viewModel.approveModelSync()
        }
        await gate.waitForArrival(1)
        let newerRoute = try XCTUnwrap(
            viewModel.modelRoutes.first {
                $0.modelID == "example-pro-2"
            }
        )
        await viewModel.selectModelRoute(id: newerRoute.id)
        let selectedPresets = viewModel.presets
        let selectedPresetID = viewModel.selectedPresetID
        let selectedName = viewModel.presetName
        let selectedStatus = viewModel.statusMessage
        let selectedError = viewModel.errorMessage
        await gate.releaseFirstArrival()
        await approval.value

        XCTAssertEqual(viewModel.selectedConnectionID, connectionID)
        XCTAssertEqual(viewModel.selectedModelRouteID, newerRoute.id)
        XCTAssertEqual(viewModel.presets, selectedPresets)
        XCTAssertEqual(viewModel.selectedPresetID, selectedPresetID)
        XCTAssertEqual(viewModel.presetName, selectedName)
        XCTAssertEqual(viewModel.statusMessage, selectedStatus)
        XCTAssertEqual(viewModel.errorMessage, selectedError)
        viewModel
            .setCancellationIndependentSelectionCompletionHookForTesting(
                nil
            )
    }

    func testModelSyncApproveLateRestoreFailureRemainsVisible()
        async
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        await viewModel.startModelSync()
        viewModel.setModelSyncRestoreFailureHookForTesting {
            throw ProviderSetupCredentialFailure.injected
        }

        await viewModel.approveModelSync()

        XCTAssertEqual(viewModel.modelSyncJob?.state, .completed)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(
            viewModel.statusMessage?.contains("적용됐지만") == true
        )
        viewModel.setModelSyncRestoreFailureHookForTesting(nil)
    }

    func testDiscoveryCommitCancellationStillAdoptsReadyConnection()
        async throws
    {
        let client = FakeCoreClient()
        let credentials = InMemoryCredentialStore()
        let viewModel = makeViewModel(
            client: client,
            credentials: credentials
        )
        await viewModel.refresh()
        let connectionID = try await prepareKnownDiscoveryForCommit(
            viewModel
        )
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setDiscoveryPostCommitSnapshotHookForTesting {
            await gate.arrive()
        }

        let commit = Task {
            await viewModel.commitDiscovery()
        }
        await gate.waitForArrival(1)
        commit.cancel()
        await gate.releaseFirstArrival()
        await commit.value

        XCTAssertTrue(
            viewModel.connections.contains {
                $0.id == connectionID
            }
        )
        XCTAssertFalse(
            viewModel.hasPendingDiscoveryCredentialCleanup
        )
        let committedCredential =
            try await credentials.credential(
                for: connectionID
            )
        XCTAssertNotNil(
            committedCredential
        )
        XCTAssertEqual(viewModel.discovery?.state, .ready)
        XCTAssertTrue(
            viewModel.statusMessage?.contains("저장") == true
        )
        XCTAssertFalse(
            viewModel.statusMessage?.contains("검토 상태") == true
        )
        viewModel.setDiscoveryPostCommitSnapshotHookForTesting(nil)
    }

    func testDiscoveryPostCommitErrorReconcilesReadyConnection()
        async throws
    {
        let client = FakeCoreClient()
        let credentials = InMemoryCredentialStore()
        let viewModel = makeViewModel(
            client: client,
            credentials: credentials
        )
        await viewModel.refresh()
        let connectionID = try await prepareKnownDiscoveryForCommit(
            viewModel
        )
        viewModel.setDiscoveryPostCommitSnapshotHookForTesting {
            throw ProviderSetupCredentialFailure.injected
        }

        await viewModel.commitDiscovery()

        XCTAssertTrue(
            viewModel.connections.contains {
                $0.id == connectionID
            }
        )
        XCTAssertFalse(
            viewModel.hasPendingDiscoveryCredentialCleanup
        )
        XCTAssertTrue(
            viewModel.errorMessage?.contains("저장됐지만") == true
        )
        XCTAssertTrue(
            viewModel.statusMessage?.contains("저장됐지만") == true
        )
        XCTAssertFalse(
            viewModel.statusMessage?.contains("검토하세요") == true
        )
        viewModel.setDiscoveryPostCommitSnapshotHookForTesting(nil)
    }

    func testDiscoveryMismatchedResponseAndRefreshFailureStayTruthful()
        async throws
    {
        let existing = ProviderProfile(
            id: "existing-refresh-failure",
            displayName: "Existing Refresh Failure",
            baseURL:
                "https://existing-refresh-failure.example.invalid/v1",
            model: "existing-model",
            timeoutSeconds: 30
        )
        let client = FakeCoreClient(profiles: [existing])
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        let existingConnection = try XCTUnwrap(
            viewModel.connections.first {
                $0.id == existing.id
            }
        )
        _ = try await prepareKnownDiscoveryForCommit(viewModel)
        viewModel.setDiscoveryConnectionTransformForTesting { _ in
            existingConnection
        }
        viewModel.setProviderMutationRefreshCommitHookForTesting {
            throw ProviderSetupCredentialFailure.injected
        }

        await viewModel.commitDiscovery()

        XCTAssertEqual(viewModel.discovery?.state, .ready)
        XCTAssertFalse(
            viewModel.hasPendingDiscoveryCredentialCleanup
        )
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(
            viewModel.statusMessage?.contains("저장됐지만") == true
        )
        XCTAssertTrue(
            viewModel.statusMessage?.contains("새로고침") == true
        )
        XCTAssertFalse(
            viewModel.statusMessage?.contains("다시 확인했습니다")
                == true
        )
        viewModel.setDiscoveryConnectionTransformForTesting(nil)
        viewModel.setProviderMutationRefreshCommitHookForTesting(nil)
    }

    func testDiscoveryMismatchedReturnedIDNeverDeletesExistingConnection()
        async throws
    {
        let existing = ProviderProfile(
            id: "existing-safe-b",
            displayName: "Existing B",
            baseURL: "https://b.example.invalid/v1",
            model: "b-model",
            timeoutSeconds: 30
        )
        let client = FakeCoreClient(profiles: [existing])
        let credentials = InMemoryCredentialStore()
        let viewModel = makeViewModel(
            client: client,
            credentials: credentials
        )
        await viewModel.refresh()
        let existingConnection = try XCTUnwrap(
            viewModel.connections.first {
                $0.id == existing.id
            }
        )
        let committedID = try await prepareKnownDiscoveryForCommit(
            viewModel
        )
        viewModel.setDiscoveryConnectionTransformForTesting { _ in
            existingConnection
        }

        await viewModel.commitDiscovery()

        let durableConnections =
            try await client.listProviderConnections()
        XCTAssertTrue(
            durableConnections.contains { $0.id == existing.id }
        )
        XCTAssertTrue(
            durableConnections.contains { $0.id == committedID }
        )
        XCTAssertTrue(
            viewModel.connections.contains { $0.id == existing.id }
        )
        XCTAssertTrue(
            viewModel.connections.contains { $0.id == committedID }
        )
        XCTAssertNotNil(viewModel.errorMessage)
        viewModel.setDiscoveryConnectionTransformForTesting(nil)
    }

    func testDiscoveryCommitRefreshFailureReportsPartialSuccess()
        async throws
    {
        let client = FakeCoreClient()
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        let connectionID = try await prepareKnownDiscoveryForCommit(
            viewModel
        )
        viewModel.setProviderMutationRefreshCommitHookForTesting {
            throw ProviderSetupCredentialFailure.injected
        }

        await viewModel.commitDiscovery()

        let durableConnections =
            try await client.listProviderConnections()
        XCTAssertTrue(
            durableConnections.contains { $0.id == connectionID }
        )
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(
            viewModel.statusMessage?.contains("저장했지만") == true
        )
        XCTAssertFalse(
            viewModel.hasPendingDiscoveryCredentialCleanup
        )
        viewModel.setProviderMutationRefreshCommitHookForTesting(nil)
    }

    func testDiscoveryMutationRefreshPreservesNewerConnectionSelection()
        async throws
    {
        let first = ProviderProfile(
            id: "mutation-owner-b",
            displayName: "B",
            baseURL: "https://b.example.invalid/v1",
            model: "b-model",
            timeoutSeconds: 30
        )
        let second = ProviderProfile(
            id: "mutation-owner-c",
            displayName: "C",
            baseURL: "https://c.example.invalid/v1",
            model: "c-model",
            timeoutSeconds: 30
        )
        let client = FakeCoreClient(profiles: [first, second])
        let viewModel = makeViewModel(client: client)
        await viewModel.refresh()
        await viewModel.selectConnection(id: first.id)
        let committedID = try await prepareKnownDiscoveryForCommit(
            viewModel
        )
        let gate = ProviderSetupRefreshCommitGate()
        viewModel.setProviderMutationRefreshCommitHookForTesting {
            await gate.arrive()
        }

        let commit = Task {
            await viewModel.commitDiscovery()
        }
        await gate.waitForArrival(1)
        await viewModel.selectConnection(id: second.id)
        let selectedRoutes = viewModel.modelRoutes
        let selectedPresets = viewModel.presets
        await gate.releaseFirstArrival()
        await commit.value

        XCTAssertEqual(viewModel.selectedConnectionID, second.id)
        XCTAssertEqual(viewModel.modelRoutes, selectedRoutes)
        XCTAssertEqual(viewModel.presets, selectedPresets)
        XCTAssertTrue(
            viewModel.connections.contains { $0.id == committedID }
        )
        viewModel.setProviderMutationRefreshCommitHookForTesting(nil)
    }

    func testRestoredInProgressCompensationNeverRepeatsVaultDelete()
        async throws
    {
        let client = FakeCoreClient()
        let credentials = ProviderSetupScriptedCredentialStore(
            values: [:]
        )
        let firstViewModel = makeViewModel(
            client: client,
            credentials: credentials
        )
        await firstViewModel.refresh()
        let connectionID = try await prepareKnownDiscoveryForCommit(
            firstViewModel
        )
        try await credentials.setCredential(nil, for: connectionID)
        let gate = ProviderSetupRefreshCommitGate()
        firstViewModel
            .setDiscoveryCompensationClaimCommitHookForTesting {
                await gate.arrive()
            }

        let firstCommit = Task {
            await firstViewModel.commitDiscovery()
        }
        await gate.waitForArrival(1)
        let initialDeleteCount =
            await credentials.deleteInvocationCount()
        XCTAssertEqual(initialDeleteCount, 0)

        let restoredViewModel = makeViewModel(
            client: client,
            credentials: credentials
        )
        await restoredViewModel.refresh()
        let restoredDeleteCount =
            await credentials.deleteInvocationCount()
        XCTAssertEqual(restoredDeleteCount, 0)
        XCTAssertTrue(
            restoredViewModel.compensationSteps.contains {
                $0.status == .outcomeUnknown
            }
        )

        await gate.releaseFirstArrival()
        await firstCommit.value
        let finalDeleteCount =
            await credentials.deleteInvocationCount()
        XCTAssertEqual(finalDeleteCount, 0)
        firstViewModel
            .setDiscoveryCompensationClaimCommitHookForTesting(nil)
    }

    func testCancelledCompensationResumeReconcilesWithoutVaultReplay()
        async throws
    {
        let client = FakeCoreClient()
        let credentials = ProviderSetupScriptedCredentialStore(
            values: [:]
        )
        let firstViewModel = makeViewModel(
            client: client,
            credentials: credentials
        )
        await firstViewModel.refresh()
        let connectionID = try await prepareKnownDiscoveryForCommit(
            firstViewModel
        )
        let sessionID = try XCTUnwrap(
            firstViewModel.discovery?.id
        )
        try await credentials.setCredential(nil, for: connectionID)
        let claimGate = ProviderSetupRefreshCommitGate()
        firstViewModel
            .setDiscoveryCompensationClaimCommitHookForTesting {
                await claimGate.arrive()
            }
        let firstCommit = Task {
            await firstViewModel.commitDiscovery()
        }
        await claimGate.waitForArrival(1)

        let restored = makeViewModel(
            client: client,
            credentials: credentials
        )
        await restored.refresh()
        XCTAssertEqual(restored.discovery?.state, .compensating)
        let deleteCountBeforeResume =
            await credentials.deleteInvocationCount()
        let resumeGate = ProviderSetupRefreshCommitGate()
        restored.setDiscoveryCompensationResumeCommitHookForTesting {
            await resumeGate.arrive()
        }

        let resume = Task {
            await restored.resumeDiscoveryCompensation()
        }
        await resumeGate.waitForArrival(1)
        resume.cancel()
        await resumeGate.releaseFirstArrival()
        await resume.value

        let durable = try await client.getProviderDiscovery(
            sessionID: sessionID
        )
        let deleteCountAfterResume =
            await credentials.deleteInvocationCount()
        XCTAssertEqual(restored.discovery, durable)
        XCTAssertEqual(
            deleteCountAfterResume,
            deleteCountBeforeResume
        )
        XCTAssertTrue(
            restored.statusMessage?.contains("취소") == true
        )

        await claimGate.releaseFirstArrival()
        await firstCommit.value
        firstViewModel
            .setDiscoveryCompensationClaimCommitHookForTesting(nil)
        restored.setDiscoveryCompensationResumeCommitHookForTesting(nil)
    }

    func testCancellationAfterVaultDeleteStillAcknowledgesWithoutReplay()
        async throws
    {
        let client = FakeCoreClient()
        let credentials = ProviderSetupScriptedCredentialStore(
            values: [:]
        )
        let viewModel = makeViewModel(
            client: client,
            credentials: credentials
        )
        await viewModel.refresh()
        let connectionID = try await prepareKnownDiscoveryForCommit(
            viewModel
        )
        try await credentials.setCredential(nil, for: connectionID)
        let gate = ProviderSetupRefreshCommitGate()
        viewModel
            .setDiscoveryCompensationCredentialDeletionCommitHookForTesting {
                await gate.arrive()
            }

        let commit = Task {
            await viewModel.commitDiscovery()
        }
        await gate.waitForArrival(1)
        let committedDeleteCount =
            await credentials.deleteInvocationCount()
        XCTAssertEqual(committedDeleteCount, 1)
        commit.cancel()
        await gate.releaseFirstArrival()
        await commit.value

        XCTAssertTrue(
            viewModel.discovery?.state.isTerminal == true
        )
        XCTAssertFalse(
            viewModel.compensationSteps.contains {
                $0.status == .inProgress
            }
        )
        let restoredViewModel = makeViewModel(
            client: client,
            credentials: credentials
        )
        await restoredViewModel.refresh()
        let restoredDeleteCount =
            await credentials.deleteInvocationCount()
        XCTAssertEqual(restoredDeleteCount, 1)
        XCTAssertFalse(
            restoredViewModel.compensationSteps.contains {
                $0.status == .inProgress
            }
        )
        viewModel
            .setDiscoveryCompensationCredentialDeletionCommitHookForTesting(
                nil
            )
    }

    private func prepareKnownDiscoveryForCommit(
        _ viewModel: ProviderSetupViewModel
    ) async throws -> String {
        viewModel.prepareDiscovery(method: .knownProvider)
        viewModel.discoveryDisplayName = "Synthetic Commit"
        viewModel.selectDiscoveryTemplate(id: "openai-v1")
        viewModel.credentialDraft = "synthetic-commit-secret"
        await viewModel.startDiscovery()
        guard case let .credentialOrigin(approval) =
            viewModel.discovery?.actionRequired
        else {
            throw ProviderSetupCredentialFailure.injected
        }
        await viewModel.continueDiscovery(
            .approveCredentialOrigin(
                approvalID: approval.approvalID
            )
        )
        await viewModel.continueDiscovery(.skipProbes)
        guard viewModel.discovery?.state == .awaitingReview else {
            throw ProviderSetupCredentialFailure.injected
        }
        return try XCTUnwrap(
            viewModel.discovery?.pendingConnectionID
        )
    }

    private func makeViewModel(
        client: FakeCoreClient,
        credentials: any CredentialStore = InMemoryCredentialStore()
    ) -> ProviderSetupViewModel {
        ProviderSetupViewModel(
            client: client,
            credentialStore: credentials,
            runtimeMode: .preview,
            providerConfigurationStore: ProviderConfigurationStore()
        )
    }

    private func assertDoesNotExpose(
        _ secret: String,
        viewModel: ProviderSetupViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            String(reflecting: viewModel.discovery).contains(secret),
            file: file,
            line: line
        )
        XCTAssertFalse(
            (viewModel.errorMessage ?? "").contains(secret),
            file: file,
            line: line
        )
        XCTAssertFalse(
            (viewModel.statusMessage ?? "").contains(secret),
            file: file,
            line: line
        )
    }
}

private func presetRecord(
    _ preset: ProviderGenerationPreset,
    replacingID id: String
) -> ProviderGenerationPreset {
    ProviderGenerationPreset(
        id: id,
        modelRouteID: preset.modelRouteID,
        displayName: preset.displayName,
        values: preset.values,
        reasoningMode: preset.reasoningMode,
        reasoningEffort: preset.reasoningEffort,
        reasoningBudgetTokens: preset.reasoningBudgetTokens,
        reasoningSummary: preset.reasoningSummary,
        preservesOpaqueReasoningState:
            preset.preservesOpaqueReasoningState,
        promptCacheMode: preset.promptCacheMode,
        promptCacheTTL: preset.promptCacheTTL,
        promptCacheCustomTTLSeconds:
            preset.promptCacheCustomTTLSeconds,
        promptCacheContextReference:
            preset.promptCacheContextReference,
        createdAt: preset.createdAt,
        updatedAt: preset.updatedAt
    )
}

private func discoverySnapshot(
    _ snapshot: ProviderDiscoverySnapshot,
    replacingID id: String,
    assistantResumeBoundary:
        ProviderDiscoveryAssistantResumeBoundary? = nil
) -> ProviderDiscoverySnapshot {
    ProviderDiscoverySnapshot(
        schemaVersion: snapshot.schemaVersion,
        id: id,
        pendingConnectionID: snapshot.pendingConnectionID,
        pendingDisplayName: snapshot.pendingDisplayName,
        connectionOptions: snapshot.connectionOptions,
        credentialSlotID: snapshot.credentialSlotID,
        credentialSlotExpected: snapshot.credentialSlotExpected,
        revision: snapshot.revision,
        nextEventSequence: snapshot.nextEventSequence,
        state: snapshot.state,
        steps: snapshot.steps,
        actionRequired: snapshot.actionRequired,
        activeOperationID: snapshot.activeOperationID,
        recoveryOperation: snapshot.recoveryOperation,
        unknownOperation: snapshot.unknownOperation,
        manifestSHA256: snapshot.manifestSHA256,
        commitPlanSHA256: snapshot.commitPlanSHA256,
        commitAttemptID: snapshot.commitAttemptID,
        committedConnectionID: snapshot.committedConnectionID,
        cancellationPending: snapshot.cancellationPending,
        candidates: snapshot.candidates,
        evidence: snapshot.evidence,
        review: snapshot.review,
        reviewProposal: snapshot.reviewProposal,
        assistantApprovalBinding:
            snapshot.assistantApprovalBinding,
        assistantResumeBoundary:
            assistantResumeBoundary
                ?? snapshot.assistantResumeBoundary,
        unknownOutcomeProposal:
            snapshot.unknownOutcomeProposal,
        warnings: snapshot.warnings,
        failureMessageKey: snapshot.failureMessageKey,
        createdAt: snapshot.createdAt,
        updatedAt: snapshot.updatedAt
    )
}

private actor ProviderSetupRefreshCommitGate {
    private struct ArrivalWaiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var arrivalCount = 0
    private var arrivalWaiters: [ArrivalWaiter] = []
    private var firstArrivalContinuation:
        CheckedContinuation<Void, Never>?

    func arrive() async {
        arrivalCount += 1
        let readyWaiters = arrivalWaiters.filter {
            arrivalCount >= $0.expectedCount
        }
        arrivalWaiters.removeAll {
            arrivalCount >= $0.expectedCount
        }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }

        guard arrivalCount == 1 else {
            return
        }
        await withCheckedContinuation { continuation in
            firstArrivalContinuation = continuation
        }
    }

    func waitForArrival(_ expectedCount: Int) async {
        guard arrivalCount < expectedCount else {
            return
        }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(
                ArrivalWaiter(
                    expectedCount: expectedCount,
                    continuation: continuation
                )
            )
        }
    }

    func releaseFirstArrival() {
        firstArrivalContinuation?.resume()
        firstArrivalContinuation = nil
    }
}

private actor ProviderSetupOrdinalCommitGate {
    private struct ArrivalWaiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var arrivalCount = 0
    private var arrivalWaiters: [ArrivalWaiter] = []
    private var firstArrivalContinuation:
        CheckedContinuation<Void, Never>?

    func arrive() async -> Int {
        arrivalCount += 1
        let ordinal = arrivalCount
        let readyWaiters = arrivalWaiters.filter {
            arrivalCount >= $0.expectedCount
        }
        arrivalWaiters.removeAll {
            arrivalCount >= $0.expectedCount
        }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
        if ordinal == 1 {
            await withCheckedContinuation { continuation in
                firstArrivalContinuation = continuation
            }
        }
        return ordinal
    }

    func waitForArrival(_ expectedCount: Int) async {
        guard arrivalCount < expectedCount else {
            return
        }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(
                ArrivalWaiter(
                    expectedCount: expectedCount,
                    continuation: continuation
                )
            )
        }
    }

    func releaseFirstArrival() {
        firstArrivalContinuation?.resume()
        firstArrivalContinuation = nil
    }
}

private actor ProviderSetupRefreshHydrationRecorder {
    private var count = 0

    func record() {
        count += 1
    }

    func recordedCount() -> Int {
        count
    }
}

private enum ProviderSetupCredentialFailure: Error {
    case injected
}

private actor ProviderSetupScriptedCredentialStore:
    CredentialStore
{
    private var values: [String: Data]
    private let readFailureInvocations: Set<Int>
    private let setFailureInvocations: Set<Int>
    private var readCount = 0
    private var setCount = 0
    private var deleteCount = 0

    init(
        values: [String: String],
        readFailureInvocations: Set<Int> = [],
        setFailureInvocations: Set<Int> = []
    ) {
        self.values = values.mapValues { Data($0.utf8) }
        self.readFailureInvocations = readFailureInvocations
        self.setFailureInvocations = setFailureInvocations
    }

    func credential(for profileID: String) async throws -> String? {
        guard let data = try await credentialData(
            for: profileID
        ) else {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.invalidEncoding
        }
        return value
    }

    func setCredential(
        _ credential: String?,
        for profileID: String
    ) async throws {
        try await setCredentialData(
            credential.map { Data($0.utf8) },
            for: profileID
        )
    }

    func credentialData(
        for profileID: String
    ) async throws -> Data? {
        readCount += 1
        if readFailureInvocations.contains(readCount) {
            throw ProviderSetupCredentialFailure.injected
        }
        return values[profileID]
    }

    func setCredentialData(
        _ credential: Data?,
        for profileID: String
    ) async throws {
        setCount += 1
        if setFailureInvocations.contains(setCount) {
            throw ProviderSetupCredentialFailure.injected
        }
        if let credential, !credential.isEmpty {
            values[profileID] = credential
        } else {
            values.removeValue(forKey: profileID)
        }
    }

    func deleteCredential(for profileID: String) async throws {
        deleteCount += 1
        values.removeValue(forKey: profileID)
    }

    func deleteInvocationCount() -> Int {
        deleteCount
    }
}
