package dev.lorepia.app.feature.settings

import dev.lorepia.app.FakeCoreClient
import dev.lorepia.app.FakeCredentialStore
import dev.lorepia.app.MainDispatcherRule
import dev.lorepia.app.bridge.AppSettings
import dev.lorepia.app.bridge.AuthBinding
import dev.lorepia.app.bridge.CapabilityObservation
import dev.lorepia.app.bridge.CapabilityValue
import dev.lorepia.app.bridge.ConnectionFieldSpec
import dev.lorepia.app.bridge.ConnectionFieldType
import dev.lorepia.app.bridge.CredentialRedirectPolicy
import dev.lorepia.app.bridge.CredentialScope
import dev.lorepia.app.bridge.EffectiveCapability
import dev.lorepia.app.bridge.DiscoveryApproval
import dev.lorepia.app.bridge.DiscoveryApprovalGrant
import dev.lorepia.app.bridge.DiscoveryAssistantCheckpoint
import dev.lorepia.app.bridge.DiscoveryAssistantDraftPersistence
import dev.lorepia.app.bridge.DiscoveryAssistantDraftReview
import dev.lorepia.app.bridge.DiscoveryAssistantDraftReviewCheck
import dev.lorepia.app.bridge.DiscoveryAssistantEndpoint
import dev.lorepia.app.bridge.DiscoveryAssistantManifest
import dev.lorepia.app.bridge.DiscoveryAssistantManifestDraft
import dev.lorepia.app.bridge.DiscoveryAssistantOutcome
import dev.lorepia.app.bridge.DiscoveryAssistantQuestion
import dev.lorepia.app.bridge.DiscoveryAssistantResumeAction
import dev.lorepia.app.bridge.DiscoveryAssistantResumeBoundary
import dev.lorepia.app.bridge.GenerationPreset
import dev.lorepia.app.bridge.ModelRoute
import dev.lorepia.app.bridge.ModelRouteConfig
import dev.lorepia.app.bridge.ModelSyncJob
import dev.lorepia.app.bridge.ModelSyncEvent
import dev.lorepia.app.bridge.ModelSyncProvenance
import dev.lorepia.app.bridge.ModelSyncReview
import dev.lorepia.app.bridge.ParameterDefaultMode
import dev.lorepia.app.bridge.ParameterSpec
import dev.lorepia.app.bridge.ParameterType
import dev.lorepia.app.bridge.ProviderConnection
import dev.lorepia.app.bridge.ProviderCatalogDiff
import dev.lorepia.app.bridge.ProviderCatalogImportPlan
import dev.lorepia.app.bridge.ProviderCatalogImportReview
import dev.lorepia.app.bridge.ProviderCatalogRollbackPlan
import dev.lorepia.app.bridge.ProviderParameterMapping
import dev.lorepia.app.bridge.ProviderParameterTarget
import dev.lorepia.app.bridge.ProviderNetworkMode
import dev.lorepia.app.bridge.ProviderLocalNetworkApproval
import dev.lorepia.app.bridge.ProviderDiscoveryConnectionOptions
import dev.lorepia.app.bridge.ProviderDiscoveryInput
import dev.lorepia.app.bridge.ProviderDiscoverySource
import dev.lorepia.app.bridge.ProviderTemplate
import dev.lorepia.app.bridge.UiParameterLevel
import dev.lorepia.app.healthyCoreStatus
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SettingsViewModelTest {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    @Test
    fun `refresh hydrates template connection route preset and capability provenance`() = runTest {
        val fixture = providerFixture()
        val core = fixture.core()

        val viewModel = SettingsViewModel(core, FakeCredentialStore())
        advanceUntilIdle()

        val state = viewModel.uiState.value as SettingsUiState.Ready
        assertEquals(listOf(fixture.template), state.templates)
        val details = state.connections.single()
        assertEquals(fixture.connection, details.connection)
        assertEquals(fixture.route, details.routes.single().route)
        assertEquals(fixture.preset, details.routes.single().presets.single())
        val capability = details.routes.single().capabilities.single()
        assertEquals("streaming", capability.key)
        assertEquals("capability_probe", capability.effective?.selected?.source)
        assertFalse(capability.effective?.selectedIsStale ?: true)
    }

    @Test
    fun `fresh discovery freezes the executable selected route as setup assistant`() = runTest {
        val fixture = providerFixture()
        val core = fixture.core(settings = fixture.settings())
        val credentials = FakeCredentialStore().apply {
            values[fixture.connection.id] = "assistant-provider-secret"
        }
        val viewModel = SettingsViewModel(core, credentials)
        advanceUntilIdle()

        viewModel.beginAddConnection()
        viewModel.chooseSetupKind(ProviderSetupKind.UnknownSite)
        viewModel.updateSetup(
            ready(viewModel).setup!!.copy(
                displayName = "Unknown provider",
                siteUrl = "https://provider.example.invalid",
            ),
        )

        assertEquals(
            fixture.route.id,
            ready(viewModel).setup?.preferredAssistantModelRouteId,
        )

        viewModel.submitSetupDetails("", "")
        advanceUntilIdle()
        assertEquals(
            fixture.route.id,
            core.lastProviderDiscoveryInput?.preferredAssistantModelRouteId,
        )

        viewModel.continueDiscoveryWithoutTemplate()
        advanceUntilIdle()
        viewModel.requestDiscoveryAssistant()
        advanceUntilIdle()

        val grant = ready(viewModel).setup
            ?.discovery
            ?.approvalProposal
            ?.grant as DiscoveryApprovalGrant.AssistantConsent
        assertEquals(fixture.route.id, grant.assistantModelRouteId)
    }

    @Test
    fun `discovery without an executable selected target blocks assistant request locally`() =
        runTest {
            val core = FakeCoreClient()
            val viewModel = SettingsViewModel(core, FakeCredentialStore())
            advanceUntilIdle()

            viewModel.beginAddConnection()
            viewModel.chooseSetupKind(ProviderSetupKind.UnknownSite)
            viewModel.updateSetup(
                ready(viewModel).setup!!.copy(
                    displayName = "Unknown provider",
                    siteUrl = "https://provider.example.invalid",
                ),
            )
            viewModel.submitSetupDetails("", "")
            advanceUntilIdle()
            viewModel.continueDiscoveryWithoutTemplate()
            advanceUntilIdle()
            val before = ready(viewModel).setup!!.discovery!!

            viewModel.requestDiscoveryAssistant()
            advanceUntilIdle()

            val after = ready(viewModel).setup!!.discovery!!
            assertEquals(before.revision, after.revision)
            assertEquals(before.state, after.state)
            assertTrue(ready(viewModel).error!!.contains("모델과 preset"))
        }

    @Test
    fun `changing selected target after discovery start cannot retarget its assistant`() =
        runTest {
            val first = providerFixture(suffix = "assistant-a")
            val second = providerFixture(suffix = "assistant-b")
            val core = coreForFixtures(
                listOf(first, second),
                settings = first.settings(),
            )
            val credentials = FakeCredentialStore().apply {
                values[first.connection.id] = "first-secret"
                values[second.connection.id] = "second-secret"
            }
            val viewModel = SettingsViewModel(core, credentials)
            advanceUntilIdle()

            viewModel.beginAddConnection()
            viewModel.chooseSetupKind(ProviderSetupKind.UnknownSite)
            viewModel.updateSetup(
                ready(viewModel).setup!!.copy(
                    displayName = "Unknown provider",
                    siteUrl = "https://provider.example.invalid",
                ),
            )
            viewModel.submitSetupDetails("", "")
            advanceUntilIdle()
            viewModel.continueDiscoveryWithoutTemplate()
            advanceUntilIdle()
            assertEquals(
                first.route.id,
                ready(viewModel).setup?.preferredAssistantModelRouteId,
            )

            viewModel.selectGenerationPreset(second.route.id, second.preset.id)
            advanceUntilIdle()
            assertEquals(
                first.route.id,
                ready(viewModel).setup?.preferredAssistantModelRouteId,
            )
            val before = ready(viewModel).setup!!.discovery!!

            viewModel.requestDiscoveryAssistant()
            advanceUntilIdle()

            val after = ready(viewModel).setup!!.discovery!!
            assertEquals(before.revision, after.revision)
            assertTrue(ready(viewModel).error!!.contains("일치하지 않거나"))
        }

    @Test
    fun `restart never guesses a different assistant route before durable consent`() = runTest {
        val first = providerFixture(suffix = "restart-a")
        val second = providerFixture(suffix = "restart-b")
        val core = coreForFixtures(
            listOf(first, second),
            settings = first.settings(),
        )
        val begun = core.beginProviderDiscovery(
            input = assistantDiscoveryInput("assistant-route-restart").copy(
                preferredAssistantModelRouteId = first.route.id,
            ),
            source = ProviderDiscoverySource.Site,
            rawCurl = null,
        )
        val awaitingEvidence = begun.copy(
            state = "awaiting_more_evidence",
            actionRequired =
                dev.lorepia.app.bridge.DiscoveryActionRequired.SupplyMoreEvidence,
        )
        core.providerDiscoveries[begun.sessionId] = awaitingEvidence
        core.settings = second.settings()
        val credentials = FakeCredentialStore().apply {
            values[first.connection.id] = "first-secret"
            values[second.connection.id] = "second-secret"
        }

        val reopened = SettingsViewModel(core, credentials)
        advanceUntilIdle()

        assertNull(ready(reopened).setup?.preferredAssistantModelRouteId)
        val before = ready(reopened).setup!!.discovery!!
        reopened.requestDiscoveryAssistant()
        advanceUntilIdle()
        val after = ready(reopened).setup!!.discovery!!

        assertEquals(before.revision, after.revision)
        assertTrue(ready(reopened).error!!.contains("탐색 시작 시"))
    }

    @Test
    fun `durable assistant grant cannot approve or run through a different current route`() =
        runTest {
            val first = providerFixture(suffix = "grant-a")
            val second = providerFixture(suffix = "grant-b")
            val core = coreForFixtures(
                listOf(first, second),
                settings = first.settings(),
            )
            val begun = core.beginProviderDiscovery(
                input = assistantDiscoveryInput("assistant-grant-restart").copy(
                    preferredAssistantModelRouteId = first.route.id,
                ),
                source = ProviderDiscoverySource.Site,
                rawCurl = null,
            )
            val grant = assistantConsentGrant(first.route.id)
            val proposal = dev.lorepia.app.bridge.DiscoveryApprovalProposal(
                approvalId = "assistant-consent",
                grant = grant,
                grantSha256 = "9".repeat(64),
            )
            val awaitingConsent = begun.copy(
                state = "awaiting_assistant_consent",
                actionRequired = dev.lorepia.app.bridge.DiscoveryActionRequired.ApproveAssistant,
                approvalProposal = proposal,
                assistantResumeBoundary = DiscoveryAssistantResumeBoundary(
                    checkpoint = null,
                    action = DiscoveryAssistantResumeAction.ApproveConsent,
                    questions = emptyList(),
                    draftReview = null,
                ),
            )
            core.providerDiscoveries[begun.sessionId] = awaitingConsent
            core.settings = second.settings()
            val credentials = FakeCredentialStore().apply {
                values[first.connection.id] = "first-secret"
                values[second.connection.id] = "second-secret"
            }

            val approvalViewModel = SettingsViewModel(core, credentials)
            advanceUntilIdle()
            approvalViewModel.approveDiscoveryAssistant()
            advanceUntilIdle()

            assertEquals(
                awaitingConsent.revision,
                ready(approvalViewModel).setup?.discovery?.revision,
            )
            assertEquals(0, core.runProviderDiscoveryAssistantTurnCalls)

            core.providerDiscoveries[begun.sessionId] = awaitingConsent.copy(
                state = "building_assistant_manifest_draft",
                actionRequired = null,
                approvalProposal = null,
                approvals = listOf(
                    DiscoveryApproval(
                        id = "assistant-consent",
                        sessionRevision = awaitingConsent.revision,
                        decision = "approved",
                        grant = grant,
                        createdAt = "2026-01-02T00:00:00Z",
                    ),
                ),
                assistantResumeBoundary = DiscoveryAssistantResumeBoundary(
                    checkpoint = DiscoveryAssistantCheckpoint.Ready,
                    action = DiscoveryAssistantResumeAction.RunAssistant,
                    questions = emptyList(),
                    draftReview = null,
                ),
            )
            val runViewModel = SettingsViewModel(core, credentials)
            advanceUntilIdle()
            runViewModel.runDiscoveryAssistant()
            advanceUntilIdle()

            assertEquals(0, core.runProviderDiscoveryAssistantTurnCalls)
            assertTrue(ready(runViewModel).error!!.contains("일치하지 않거나"))
        }

    @Test
    fun `known provider requires exact origin approval then writes Keystore before core`() = runTest {
        val trace = mutableListOf<String>()
        val template = syntheticTemplate()
        val core = FakeCoreClient(
            providerTemplates = mutableListOf(template),
            operationTrace = trace,
        )
        val credentials = FakeCredentialStore(trace)
        val viewModel = SettingsViewModel(core, credentials)
        advanceUntilIdle()

        viewModel.beginAddConnection()
        viewModel.chooseSetupKind(ProviderSetupKind.KnownProvider)
        viewModel.chooseKnownTemplate(template.id)
        val setup = ready(viewModel).setup!!
        viewModel.updateSetup(
            setup.copy(
                displayName = "내 OpenAI",
                connectionValues = mapOf("organization" to "org-test"),
            ),
        )
        viewModel.submitSetupDetails("synthetic-secret", "")
        advanceUntilIdle()

        assertEquals(
            ProviderSetupStep.ApproveCredentialOrigin,
            ready(viewModel).setup?.step,
        )
        viewModel.approveCredentialOrigin()
        advanceUntilIdle()
        assertEquals(ProviderSetupStep.Review, ready(viewModel).setup?.step)
        assertEquals(
            "https://api.example.invalid",
            (
                ready(viewModel).setup?.discovery?.reviewProposal
                    ?.requestPreview
            )?.origin,
        )

        val connectionId = ready(viewModel).setup!!.connectionId
        viewModel.commitSetup()
        advanceUntilIdle()

        assertEquals(
            listOf(
                "credential:write:$connectionId",
                "credential:read:$connectionId",
                "core:create:$connectionId",
            ),
            trace,
        )
        assertEquals("synthetic-secret", credentials.values[connectionId])
        assertTrue(core.providerConnections.single().credentialSlotReady)
        assertNull((viewModel.uiState.value as SettingsUiState.Ready).setup)
    }

    @Test
    fun `restart restores typed assistant run boundary and waits for explicit action`() = runTest {
        val fixture = providerFixture()
        val grant = assistantConsentGrant(fixture.route.id)
        val core = fixture.core(
            settings = fixture.settings(),
        )
        val snapshot = core.beginProviderDiscovery(
            input = assistantDiscoveryInput("assistant-restart"),
            source = ProviderDiscoverySource.Site,
            rawCurl = null,
        ).copy(
            state = "building_assistant_manifest_draft",
            actionRequired = null,
            approvals = listOf(
                DiscoveryApproval(
                    id = "assistant-consent",
                    sessionRevision = 2uL,
                    decision = "approved",
                    grant = grant,
                    createdAt = "2026-01-02T00:00:00Z",
                ),
            ),
            assistantResumeBoundary = DiscoveryAssistantResumeBoundary(
                checkpoint = DiscoveryAssistantCheckpoint.Ready,
                action = DiscoveryAssistantResumeAction.RunAssistant,
                questions = emptyList(),
                draftReview = null,
            ),
        )
        core.providerDiscoveries[snapshot.sessionId] = snapshot
        core.discoveryAssistantOutcome = DiscoveryAssistantOutcome.MoreEvidenceRequired(
            sessionId = snapshot.sessionId,
            questions = listOf(
                DiscoveryAssistantQuestion(
                    id = "question-models",
                    field = null,
                    question = "공식 model 목록 근거가 어디에 있나요?",
                    requiredEvidence = "official models documentation",
                ),
            ),
        )
        val credentials = FakeCredentialStore().apply {
            values[fixture.connection.id] = "assistant-provider-secret"
        }

        val reopened = SettingsViewModel(core, credentials)
        advanceUntilIdle()

        assertEquals(0, core.runProviderDiscoveryAssistantTurnCalls)
        assertEquals(
            DiscoveryAssistantResumeAction.RunAssistant,
            ready(reopened).setup?.discovery?.assistantResumeBoundary?.action,
        )

        reopened.runDiscoveryAssistant()
        advanceUntilIdle()

        assertEquals(1, core.runProviderDiscoveryAssistantTurnCalls)
        val outcome = ready(reopened).setup?.assistantOutcome
            as DiscoveryAssistantOutcome.MoreEvidenceRequired
        assertEquals("question-models", outcome.questions.single().id)
        assertEquals(
            DiscoveryAssistantResumeAction.SupplyMoreEvidence,
            ready(reopened).setup?.discovery?.assistantResumeBoundary?.action,
        )
    }

    @Test
    fun `restart requires explicit Core-host assistant action resume`() = runTest {
        val fixture = providerFixture()
        val core = fixture.core()
        val initial = core.beginProviderDiscovery(
            input = assistantDiscoveryInput("assistant-core-host-restart"),
            source = ProviderDiscoverySource.Site,
            rawCurl = null,
        )
        val awaitingResume = initial.copy(
            state = "building_assistant_manifest_draft",
            actionRequired = null,
            assistantResumeBoundary = DiscoveryAssistantResumeBoundary(
                checkpoint = DiscoveryAssistantCheckpoint.AwaitingToolResult,
                action = DiscoveryAssistantResumeAction.ResumeCoreHostAction,
                questions = emptyList(),
                draftReview = null,
            ),
        )
        core.providerDiscoveries[initial.sessionId] = awaitingResume

        val reopened = SettingsViewModel(core, FakeCredentialStore())
        advanceUntilIdle()

        assertEquals(0, core.resumeProviderDiscoveryAssistantCoreHostActionCalls)
        assertEquals(
            DiscoveryAssistantResumeAction.ResumeCoreHostAction,
            ready(reopened).setup?.discovery?.assistantResumeBoundary?.action,
        )

        reopened.resumeDiscoveryAssistantCoreHostAction()
        advanceUntilIdle()

        assertEquals(1, core.resumeProviderDiscoveryAssistantCoreHostActionCalls)
        assertEquals(
            DiscoveryAssistantResumeAction.RunAssistant,
            ready(reopened).setup?.discovery?.assistantResumeBoundary?.action,
        )
    }

    @Test
    fun `restart restores assistant draft and retry boundaries without inference`() = runTest {
        val fixture = providerFixture()
        val core = fixture.core()
        val initial = core.beginProviderDiscovery(
            input = assistantDiscoveryInput("assistant-review-restart"),
            source = ProviderDiscoverySource.Site,
            rawCurl = null,
        )
        val review = assistantDraftReview()
        val draftReady = initial.copy(
            state = "building_assistant_manifest_draft",
            actionRequired = null,
            assistantResumeBoundary = DiscoveryAssistantResumeBoundary(
                checkpoint = DiscoveryAssistantCheckpoint.DraftReady,
                action = DiscoveryAssistantResumeAction.ReviewDraft,
                questions = emptyList(),
                draftReview = review,
            ),
        )
        core.providerDiscoveries[initial.sessionId] = draftReady
        val reopened = SettingsViewModel(core, FakeCredentialStore())
        advanceUntilIdle()

        val restored = ready(reopened).setup?.assistantOutcome
            as DiscoveryAssistantOutcome.DraftReadyForReview
        assertEquals(review, restored.review)

        core.providerDiscoveries[initial.sessionId] = draftReady.copy(
            revision = draftReady.revision + 1uL,
            assistantResumeBoundary = DiscoveryAssistantResumeBoundary(
                checkpoint = DiscoveryAssistantCheckpoint.AwaitingRetryConsent,
                action = DiscoveryAssistantResumeAction.ApproveRetry,
                questions = emptyList(),
                draftReview = null,
            ),
        )
        reopened.refresh()
        advanceUntilIdle()

        assertNull(ready(reopened).setup?.assistantOutcome)
        reopened.approveDiscoveryAssistantRetry()
        advanceUntilIdle()

        assertEquals(
            DiscoveryAssistantResumeAction.RunAssistant,
            ready(reopened).setup?.discovery?.assistantResumeBoundary?.action,
        )
    }

    @Test
    fun `restart uses durable exact LAN policy for supplemental curl inspection`() = runTest {
        val approval = ProviderLocalNetworkApproval(
            origin = "http://192.168.50.4:11434",
            addresses = listOf("192.168.50.4"),
        )
        val input = assistantDiscoveryInput("lan-restart").copy(
            siteUrl = null,
            connectionOptions = ProviderDiscoveryConnectionOptions(
                values = emptyList(),
                apiBasePath = "/v1",
                timeoutSeconds = 45u,
                networkMode = ProviderNetworkMode.ApprovedLocalNetwork,
                localNetworkApproval = approval,
            ),
        )
        val core = FakeCoreClient()
        val initial = core.beginProviderDiscovery(
            input = input,
            source = ProviderDiscoverySource.Curl,
            rawCurl = "curl http://192.168.50.4:11434/v1/models",
        )
        val awaiting = initial.copy(
            state = "awaiting_more_evidence",
            actionRequired = dev.lorepia.app.bridge.DiscoveryActionRequired.SupplyMoreEvidence,
        )
        core.providerDiscoveries[initial.sessionId] = awaiting
        val reopened = SettingsViewModel(core, FakeCredentialStore())
        advanceUntilIdle()

        assertEquals(
            ProviderNetworkMode.ApprovedLocalNetwork,
            ready(reopened).setup?.networkMode,
        )
        assertEquals(approval.origin, ready(reopened).setup?.localNetworkOrigin)

        reopened.supplyDiscoveryCurlEvidence(
            "curl http://192.168.50.4:11434/v1/chat/completions",
        )
        advanceUntilIdle()

        assertEquals(
            dev.lorepia.app.bridge.ProviderNetworkPolicy(
                networkMode = ProviderNetworkMode.ApprovedLocalNetwork,
                localNetworkApproval = approval,
            ),
            core.lastCurlNetworkPolicy,
        )
    }

    @Test
    fun `failed connection create removes newly written credential`() = runTest {
        val trace = mutableListOf<String>()
        val template = syntheticTemplate()
        val core = FakeCoreClient(
            providerTemplates = mutableListOf(template),
            createConnectionError = IllegalStateException("database rejected connection"),
            operationTrace = trace,
        )
        val credentials = FakeCredentialStore(trace)
        val viewModel = SettingsViewModel(core, credentials)
        advanceUntilIdle()

        viewModel.beginAddConnection()
        viewModel.chooseSetupKind(ProviderSetupKind.KnownProvider)
        viewModel.chooseKnownTemplate(template.id)
        viewModel.submitSetupDetails("synthetic-secret", "")
        advanceUntilIdle()
        viewModel.approveCredentialOrigin()
        advanceUntilIdle()
        val connectionId = ready(viewModel).setup!!.connectionId
        viewModel.commitSetup()
        advanceUntilIdle()

        assertFalse(credentials.values.containsKey(connectionId))
        assertEquals(
            listOf(
                "credential:write:$connectionId",
                "credential:read:$connectionId",
                "core:create:$connectionId",
                "credential:delete:$connectionId",
            ),
            trace,
        )
        assertEquals(ProviderSetupStep.Failed, ready(viewModel).setup?.step)
    }

    @Test
    fun `failed core delete restores credential before exposing error`() = runTest {
        val trace = mutableListOf<String>()
        val fixture = providerFixture()
        val core = fixture.core(
            deleteConnectionError = IllegalStateException("route is in use"),
            trace = trace,
        )
        val credentials = FakeCredentialStore(trace).apply {
            values[fixture.connection.id] = "existing-secret"
        }
        val viewModel = SettingsViewModel(core, credentials)
        advanceUntilIdle()

        viewModel.deleteConnection(fixture.connection.id)
        advanceUntilIdle()

        assertEquals("existing-secret", credentials.values[fixture.connection.id])
        assertEquals(
            listOf(
                "credential:read:${fixture.connection.id}",
                "credential:delete:${fixture.connection.id}",
                "core:delete:${fixture.connection.id}",
                "credential:write:${fixture.connection.id}",
            ),
            trace,
        )
        assertTrue(ready(viewModel).error!!.contains("route is in use"))
    }

    @Test
    fun `existing connection credential replacement requires a new connection`() = runTest {
        val fixture = providerFixture()
        val core = fixture.core()
        val credentials = FakeCredentialStore().apply {
            values[fixture.connection.id] = "approved-existing-secret"
        }
        val viewModel = SettingsViewModel(core, credentials)
        advanceUntilIdle()

        viewModel.beginEditConnection(fixture.connection.id)
        viewModel.saveConnectionEditor("different-account-secret")

        assertTrue(ready(viewModel).error!!.contains("새 AI 연결"))
        assertEquals("approved-existing-secret", credentials.values[fixture.connection.id])
        assertTrue(credentials.operations.isEmpty())
        assertTrue(core.providerMutationOrder.isEmpty())
    }

    @Test
    fun `existing connection endpoint configuration edit requires a new connection`() = runTest {
        val fixture = providerFixture()
        val core = fixture.core()
        val viewModel = SettingsViewModel(core, FakeCredentialStore())
        advanceUntilIdle()

        viewModel.beginEditConnection(fixture.connection.id)
        val editor = ready(viewModel).connectionEditor!!
        viewModel.updateConnectionEditor(editor.copy(timeoutSeconds = "61"))
        viewModel.saveConnectionEditor("")

        assertTrue(ready(viewModel).error!!.contains("새 AI 연결"))
        assertTrue(core.providerMutationOrder.isEmpty())
    }

    @Test
    fun `blank key retains credential while display name changes`() = runTest {
        val fixture = providerFixture()
        val core = fixture.core()
        val credentials = FakeCredentialStore().apply {
            values[fixture.connection.id] = "approved-existing-secret"
        }
        val viewModel = SettingsViewModel(core, credentials)
        advanceUntilIdle()

        viewModel.beginEditConnection(fixture.connection.id)
        val editor = ready(viewModel).connectionEditor!!
        viewModel.updateConnectionEditor(editor.copy(displayName = "이름만 변경"))
        viewModel.saveConnectionEditor("")
        advanceUntilIdle()

        assertEquals(
            "이름만 변경",
            core.providerConnections.single { it.id == fixture.connection.id }.displayName,
        )
        assertEquals("approved-existing-secret", credentials.values[fixture.connection.id])
        assertTrue(credentials.operations.isEmpty())
        assertEquals(
            listOf("core:update:${fixture.connection.id}"),
            core.providerMutationOrder,
        )
    }

    @Test
    fun `selecting preset persists paired route and preset ids`() = runTest {
        val fixture = providerFixture()
        val core = fixture.core(
            settings = AppSettings(
                preservePartialGenerations = false,
                selectedProviderProfileId = fixture.connection.id,
            ),
        )
        val viewModel = SettingsViewModel(core, FakeCredentialStore())
        advanceUntilIdle()

        viewModel.selectGenerationPreset(fixture.route.id, fixture.preset.id)
        advanceUntilIdle()

        assertEquals(fixture.route.id, core.settings.selectedModelRouteId)
        assertEquals(fixture.preset.id, core.settings.selectedGenerationPresetId)
        assertNull(core.settings.selectedProviderProfileId)
        assertEquals(core.settings, ready(viewModel).settings)
    }

    @Test
    fun `stale settings instance patches preserve flag without clearing latest target`() =
        runTest {
            val fixture = providerFixture()
            val core = fixture.core()
            val staleViewModel = SettingsViewModel(core, FakeCredentialStore())
            val selectingViewModel = SettingsViewModel(core, FakeCredentialStore())
            advanceUntilIdle()

            selectingViewModel.selectGenerationPreset(fixture.route.id, fixture.preset.id)
            advanceUntilIdle()
            staleViewModel.setPreservePartialGenerations(true)
            advanceUntilIdle()

            assertTrue(core.settings.preservePartialGenerations)
            assertEquals(fixture.route.id, core.settings.selectedModelRouteId)
            assertEquals(fixture.preset.id, core.settings.selectedGenerationPresetId)
            assertEquals(core.settings, ready(staleViewModel).settings)
        }

    @Test
    fun `preset save does not auto-select over a newer target from another settings instance`() =
        runTest {
            val fixture = providerFixture()
            val core = fixture.core()
            val savingViewModel = SettingsViewModel(core, FakeCredentialStore())
            val selectingViewModel = SettingsViewModel(core, FakeCredentialStore())
            advanceUntilIdle()

            savingViewModel.beginAddPreset(fixture.route.id)
            advanceUntilIdle()
            val draft = ready(savingViewModel).presetEditor!!
            savingViewModel.updatePresetEditor(draft.copy(displayName = "새 설정"))
            advanceUntilIdle()
            savingViewModel.savePreset()
            advanceUntilIdle()
            assertTrue(ready(savingViewModel).presetReview != null)

            selectingViewModel.selectGenerationPreset(fixture.route.id, fixture.preset.id)
            advanceUntilIdle()
            savingViewModel.savePreset()
            advanceUntilIdle()

            assertEquals(fixture.route.id, core.settings.selectedModelRouteId)
            assertEquals(fixture.preset.id, core.settings.selectedGenerationPresetId)
            assertEquals(core.settings, ready(savingViewModel).settings)
        }

    @Test
    fun `new preset omits provider-default parameter values`() = runTest {
        val fixture = providerFixture(presets = emptyList())
        val core = fixture.core()
        val viewModel = SettingsViewModel(core, FakeCredentialStore())
        advanceUntilIdle()

        viewModel.beginAddPreset(fixture.route.id)
        val editor = ready(viewModel).presetEditor!!
        assertTrue(editor.explicitValues.isEmpty())
        assertEquals(fixture.template.parameters, editor.parameterSpecs)
        viewModel.updatePresetEditor(editor.copy(displayName = "Provider 기본값"))
        advanceUntilIdle()
        viewModel.savePreset()
        advanceUntilIdle()

        assertTrue(core.generationPresets.getValue(fixture.route.id).isEmpty())
        assertTrue(ready(viewModel).presetReview != null)
        viewModel.savePreset()
        advanceUntilIdle()

        val saved = core.generationPresets.getValue(fixture.route.id).single()
        assertTrue(saved.values.isEmpty())
        assertEquals(saved.id, core.settings.selectedGenerationPresetId)
    }

    @Test
    fun `Core exact enabled default effort is visible previewed and saved`() = runTest {
        val fixture = providerFixture(presets = emptyList())
        val core = fixture.core().apply {
            reasoningEffortOverride = "medium"
        }
        val viewModel = SettingsViewModel(core, FakeCredentialStore())
        advanceUntilIdle()

        viewModel.beginAddPreset(fixture.route.id)
        advanceUntilIdle()
        val providerDefaultEditor = ready(viewModel).presetEditor!!
        assertNull(providerDefaultEditor.reasoningEffort)

        viewModel.updatePresetEditor(
            providerDefaultEditor.copy(
                reasoningMode = "enabled",
                reasoningEffort = null,
            ),
        )
        assertNull(ready(viewModel).presetControls)
        viewModel.savePreset()
        assertEquals(0, core.previewPresetCandidateCalls)
        advanceUntilIdle()

        assertEquals("medium", ready(viewModel).presetEditor!!.reasoningEffort)
        viewModel.savePreset()
        advanceUntilIdle()

        assertEquals("medium", core.lastValidatedPresetCandidate!!.reasoningEffort)
        assertEquals("medium", core.lastPreviewPresetCandidate!!.reasoningEffort)
        assertEquals("medium", ready(viewModel).presetReview!!.candidate.reasoningEffort)

        viewModel.savePreset()
        advanceUntilIdle()

        val saved = core.generationPresets.getValue(fixture.route.id).single()
        assertEquals("medium", saved.reasoningEffort)
    }

    @Test
    fun `Core default effort never overwrites an explicit user effort`() = runTest {
        val fixture = providerFixture(presets = emptyList())
        val core = fixture.core().apply {
            reasoningEffortOverride = "medium"
        }
        val viewModel = SettingsViewModel(core, FakeCredentialStore())
        advanceUntilIdle()

        viewModel.beginAddPreset(fixture.route.id)
        advanceUntilIdle()
        viewModel.updatePresetEditor(
            ready(viewModel).presetEditor!!.copy(
                reasoningMode = "enabled",
                reasoningEffort = "high",
            ),
        )
        advanceUntilIdle()

        assertEquals("high", ready(viewModel).presetEditor!!.reasoningEffort)
        viewModel.savePreset()
        advanceUntilIdle()

        assertEquals("high", core.lastValidatedPresetCandidate!!.reasoningEffort)
        assertEquals("high", core.lastPreviewPresetCandidate!!.reasoningEffort)
        assertEquals("high", ready(viewModel).presetReview!!.candidate.reasoningEffort)
    }

    @Test
    fun `hidden Core effort remains omitted for enabled reasoning`() = runTest {
        val fixture = providerFixture(presets = emptyList())
        val core = fixture.core().apply {
            reasoningEffortFieldOverride = "hidden"
        }
        val viewModel = SettingsViewModel(core, FakeCredentialStore())
        advanceUntilIdle()

        viewModel.beginAddPreset(fixture.route.id)
        advanceUntilIdle()
        viewModel.updatePresetEditor(
            ready(viewModel).presetEditor!!.copy(
                reasoningMode = "enabled",
                reasoningEffort = null,
            ),
        )
        advanceUntilIdle()

        assertNull(ready(viewModel).presetEditor!!.reasoningEffort)
        viewModel.savePreset()
        advanceUntilIdle()

        assertNull(core.lastValidatedPresetCandidate!!.reasoningEffort)
        assertNull(core.lastPreviewPresetCandidate!!.reasoningEffort)
        assertNull(ready(viewModel).presetReview!!.candidate.reasoningEffort)
    }

    @Test
    fun `ProviderDefault reasoning keeps effort omitted through preview and save`() = runTest {
        val fixture = providerFixture(presets = emptyList())
        val core = fixture.core()
        val viewModel = SettingsViewModel(core, FakeCredentialStore())
        advanceUntilIdle()

        viewModel.beginAddPreset(fixture.route.id)
        advanceUntilIdle()
        assertEquals("provider_default", ready(viewModel).presetEditor!!.reasoningMode)
        assertNull(ready(viewModel).presetEditor!!.reasoningEffort)
        val editor = ready(viewModel).presetEditor!!
        viewModel.updatePresetEditor(
            editor.copy(
                reasoningMode = "provider_default",
                reasoningEffort = "high",
                reasoningBudgetTokens = "128",
                reasoningSummary = "detailed",
            ),
        )
        assertNull(ready(viewModel).presetEditor!!.reasoningEffort)
        assertTrue(ready(viewModel).presetEditor!!.reasoningBudgetTokens.isEmpty())
        assertEquals("provider_default", ready(viewModel).presetEditor!!.reasoningSummary)
        advanceUntilIdle()

        viewModel.savePreset()
        advanceUntilIdle()

        assertNull(core.lastValidatedPresetCandidate!!.reasoningEffort)
        assertNull(core.lastPreviewPresetCandidate!!.reasoningEffort)
        assertNull(ready(viewModel).presetReview!!.candidate.reasoningEffort)

        viewModel.savePreset()
        advanceUntilIdle()

        val saved = core.generationPresets.getValue(fixture.route.id).single()
        assertEquals("provider_default", saved.reasoningMode)
        assertNull(saved.reasoningEffort)
    }

    @Test
    fun `Core reasoning control error blocks preview and durable save`() = runTest {
        val fixture = providerFixture(presets = emptyList())
        val core = fixture.core()
        val viewModel = SettingsViewModel(core, FakeCredentialStore())
        advanceUntilIdle()

        viewModel.beginAddPreset(fixture.route.id)
        advanceUntilIdle()
        val editor = ready(viewModel).presetEditor!!
        core.renderReasoningControlError =
            IllegalArgumentException("exact OpenRouter default effort is unavailable")

        viewModel.updatePresetEditor(
            editor.copy(
                reasoningMode = "enabled",
                reasoningEffort = null,
            ),
        )
        advanceUntilIdle()

        assertNull(ready(viewModel).presetControls)
        assertTrue(ready(viewModel).error!!.contains("default effort"))
        viewModel.savePreset()
        advanceUntilIdle()

        assertEquals(0, core.previewPresetCandidateCalls)
        assertEquals(0, core.upsertGenerationPresetCalls)
    }

    @Test
    fun `Core control normalizes unsupported legacy opaque reasoning state`() = runTest {
        val fixture = providerFixture()
        val legacyPreset = fixture.preset.copy(
            preserveOpaqueReasoningState = true,
        )
        val core = fixture.core().apply {
            generationPresets[fixture.route.id] = mutableListOf(legacyPreset)
            reasoningPreserveOpaqueOverride = false
        }
        val viewModel = SettingsViewModel(core, FakeCredentialStore())
        advanceUntilIdle()

        viewModel.beginEditPreset(legacyPreset.id)
        advanceUntilIdle()

        val state = ready(viewModel)
        assertFalse(state.presetEditor!!.preserveOpaqueReasoningState)
        assertFalse(state.presetControls!!.reasoning.preserveOpaqueState)
        assertEquals(1, core.renderReasoningControlCalls)
        assertFalse(
            core.lastRenderedReasoningPresetCandidate!!.preserveOpaqueReasoningState,
        )

        viewModel.savePreset()
        advanceUntilIdle()

        assertFalse(ready(viewModel).presetReview!!.candidate.preserveOpaqueReasoningState)
    }

    @Test
    fun `Core false opaque policy blocks injected true before preview and save`() = runTest {
        val fixture = providerFixture(presets = emptyList())
        val core = fixture.core().apply {
            reasoningPreserveOpaqueOverride = false
        }
        val viewModel = SettingsViewModel(core, FakeCredentialStore())
        advanceUntilIdle()

        viewModel.beginAddPreset(fixture.route.id)
        advanceUntilIdle()
        val editor = ready(viewModel).presetEditor!!
        assertFalse(ready(viewModel).presetControls!!.reasoning.preserveOpaqueState)

        viewModel.updatePresetEditor(
            editor.copy(preserveOpaqueReasoningState = true),
        )
        assertFalse(ready(viewModel).presetEditor!!.preserveOpaqueReasoningState)
        advanceUntilIdle()

        viewModel.savePreset()
        advanceUntilIdle()

        assertFalse(core.lastValidatedPresetCandidate!!.preserveOpaqueReasoningState)
        assertFalse(core.lastPreviewPresetCandidate!!.preserveOpaqueReasoningState)
        assertFalse(ready(viewModel).presetReview!!.candidate.preserveOpaqueReasoningState)

        viewModel.savePreset()
        advanceUntilIdle()

        val saved = core.generationPresets.getValue(fixture.route.id).single()
        assertFalse(saved.preserveOpaqueReasoningState)
    }

    @Test
    fun `credential connection blocks opaque true even when Core returns true`() = runTest {
        val fixture = providerFixture()
        val legacyPreset = fixture.preset.copy(
            preserveOpaqueReasoningState = true,
        )
        val core = fixture.core().apply {
            generationPresets[fixture.route.id] = mutableListOf(legacyPreset)
            reasoningPreserveOpaqueOverride = true
        }
        val viewModel = SettingsViewModel(core, FakeCredentialStore())
        advanceUntilIdle()

        viewModel.beginEditPreset(legacyPreset.id)
        advanceUntilIdle()

        var state = ready(viewModel)
        assertTrue(state.isCredentialBearingRoute(fixture.route.id))
        assertTrue(state.presetControls!!.reasoning.preserveOpaqueState)
        assertFalse(state.presetEditor!!.preserveOpaqueReasoningState)
        assertFalse(
            core.lastRenderedReasoningPresetCandidate!!.preserveOpaqueReasoningState,
        )

        viewModel.updatePresetEditor(
            state.presetEditor!!.copy(preserveOpaqueReasoningState = true),
        )
        assertFalse(ready(viewModel).presetEditor!!.preserveOpaqueReasoningState)
        advanceUntilIdle()

        viewModel.savePreset()
        advanceUntilIdle()

        state = ready(viewModel)
        assertFalse(core.lastValidatedPresetCandidate!!.preserveOpaqueReasoningState)
        assertFalse(core.lastPreviewPresetCandidate!!.preserveOpaqueReasoningState)
        assertFalse(state.presetReview!!.candidate.preserveOpaqueReasoningState)

        viewModel.savePreset()
        advanceUntilIdle()

        val saved = core.generationPresets.getValue(fixture.route.id).single()
        assertFalse(saved.preserveOpaqueReasoningState)
    }

    @Test
    fun `invalid preset candidate never reaches durable upsert`() = runTest {
        val fixture = providerFixture(presets = emptyList())
        val core = fixture.core().apply {
            validatePresetCandidateError = IllegalArgumentException("temperature is invalid")
        }
        val viewModel = SettingsViewModel(core, FakeCredentialStore())
        advanceUntilIdle()

        viewModel.beginAddPreset(fixture.route.id)
        val editor = ready(viewModel).presetEditor!!
        viewModel.updatePresetEditor(editor.copy(displayName = "검증 실패"))
        advanceUntilIdle()
        viewModel.savePreset()
        advanceUntilIdle()

        assertEquals(1, core.validatePresetCandidateCalls)
        assertEquals(0, core.previewPresetCandidateCalls)
        assertEquals(0, core.upsertGenerationPresetCalls)
        assertTrue(core.generationPresets.getValue(fixture.route.id).isEmpty())
        assertTrue(ready(viewModel).error!!.contains("temperature is invalid"))
    }

    @Test
    fun `awaiting review model sync is restored without replaying credential request`() = runTest {
        val fixture = providerFixture()
        val review = ModelSyncReview(
            sha256 = "a".repeat(64),
            connectionId = fixture.connection.id,
            expectedConnection = fixture.connection,
            observedAt = "2026-01-02T00:00:00Z",
            expectedModelRoutes = listOf(fixture.route),
            listedRoutes = listOf(fixture.route),
            newlySeenModelRouteIds = emptyList(),
            missingModelRouteIds = emptyList(),
            initialPresets = emptyList(),
            capabilityObservations = listOf(fixture.observation),
            routesRequiringPresetConfiguration = emptyList(),
            provenance = ModelSyncProvenance(
                source = "provider_api",
                apiFamily = fixture.route.apiFamily,
                apiOrigin = fixture.connection.apiOrigin,
                endpointPath = "/v1/models",
                pagesFetched = 1u,
                responseBytes = 256uL,
            ),
        )
        val job = ModelSyncJob(
            id = "sync-1",
            connectionId = fixture.connection.id,
            state = "diff_ready_awaiting_review",
            revision = 3uL,
            review = review,
            failure = null,
            createdAt = "2026-01-02T00:00:00Z",
            updatedAt = "2026-01-02T00:00:01Z",
        )
        val core = fixture.core().apply {
            modelSyncJobs[job.id] = job
            modelSyncJobs["sync-newer-failed"] = job.copy(
                id = "sync-newer-failed",
                state = "failed",
                review = null,
                updatedAt = "2026-01-03T00:00:00Z",
            )
        }
        val credentials = FakeCredentialStore().apply {
            values[fixture.connection.id] = "must-not-be-read"
        }

        val viewModel = SettingsViewModel(core, credentials)
        advanceUntilIdle()

        val restored = ready(viewModel).modelSync as ModelSyncUiState.AwaitingReview
        assertEquals(job.id, restored.jobId)
        assertEquals(review.sha256, restored.reviewHash)
        assertTrue(credentials.operations.isEmpty())
        assertNull(core.lastCredential)
    }

    @Test
    fun `interrupted durable sync is restored blocks another start and can be cancelled`() =
        runTest {
            val first = providerFixture(suffix = "interrupted-a")
            val second = providerFixture(suffix = "interrupted-b")
            val interrupted = activeModelSyncJob(
                id = "sync-interrupted-a",
                fixture = first,
                state = "interrupted",
                updatedAt = "2026-01-02T00:00:01Z",
            )
            val core = coreForFixtures(listOf(first, second)).apply {
                modelSyncJobs[interrupted.id] = interrupted
            }
            val credentials = FakeCredentialStore().apply {
                values[first.connection.id] = "must-not-be-read"
                values[second.connection.id] = "must-not-be-read"
            }
            val viewModel = SettingsViewModel(core, credentials)
            advanceUntilIdle()

            val restored = ready(viewModel).modelSync as ModelSyncUiState.Interrupted
            assertEquals(interrupted.id, restored.jobId)
            assertEquals(first.connection.id, restored.connectionId)
            assertTrue(restored.hasActionableModelSync())
            assertFalse(ready(viewModel).isBusy)
            assertTrue(credentials.operations.isEmpty())

            viewModel.startModelSync(second.connection.id)
            advanceUntilIdle()

            assertEquals(0, core.startProviderModelSyncCalls)
            assertEquals(interrupted.id, (ready(viewModel).modelSync as ModelSyncUiState.Interrupted).jobId)
            assertTrue(ready(viewModel).error!!.contains("중단됨"))

            viewModel.cancelModelSync(interrupted.id)
            advanceUntilIdle()

            assertNull(ready(viewModel).modelSync)
            assertEquals("cancelled", core.modelSyncJobs.getValue(interrupted.id).state)
            assertTrue(ready(viewModel).notice!!.contains("취소"))
        }

    @Test
    fun `interrupted sync in one settings instance blocks stale second instance deletion`() =
        runTest {
            val fixture = providerFixture(suffix = "delete-race")
            val interrupted = activeModelSyncJob(
                id = "sync-delete-race",
                fixture = fixture,
                state = "interrupted",
                updatedAt = "2026-01-02T00:00:01Z",
            )
            val core = fixture.core().apply {
                nextStartedModelSyncJob = interrupted
            }
            val credentials = FakeCredentialStore().apply {
                values[fixture.connection.id] = "synthetic-secret"
            }
            val firstViewModel = SettingsViewModel(core, credentials)
            val staleSecondViewModel = SettingsViewModel(core, credentials)
            advanceUntilIdle()

            firstViewModel.startModelSync(fixture.connection.id)
            advanceUntilIdle()
            assertEquals(
                interrupted.id,
                (ready(firstViewModel).modelSync as ModelSyncUiState.Interrupted).jobId,
            )
            credentials.operations.clear()
            core.providerMutationOrder.clear()

            staleSecondViewModel.deleteConnection(fixture.connection.id)
            advanceUntilIdle()

            assertTrue(core.providerConnections.any { it.id == fixture.connection.id })
            assertEquals("synthetic-secret", credentials.values[fixture.connection.id])
            assertTrue(credentials.operations.isEmpty())
            assertTrue(core.providerMutationOrder.isEmpty())
            val restored =
                ready(staleSecondViewModel).modelSync as ModelSyncUiState.Interrupted
            assertEquals(interrupted.id, restored.jobId)
            assertTrue(ready(staleSecondViewModel).error!!.contains("종료되지 않은"))
        }

    @Test
    fun `stale delete restores running sync monitoring and observes its completion`() =
        runTest {
            val fixture = providerFixture(suffix = "delete-running")
            val running = activeModelSyncJob(
                id = "sync-delete-running",
                fixture = fixture,
                state = "fetching",
                updatedAt = "2026-01-02T00:00:01Z",
            )
            val completed = running.copy(
                state = "completed",
                revision = running.revision + 1uL,
                updatedAt = "2026-01-02T00:00:02Z",
            )
            val core = fixture.core()
            val credentials = FakeCredentialStore().apply {
                values[fixture.connection.id] = "synthetic-secret"
            }
            val staleSecondViewModel = SettingsViewModel(core, credentials)
            advanceUntilIdle()
            core.modelSyncJobs[running.id] = running
            core.queuedModelSyncGetResponses[running.id] = ArrayDeque(listOf(completed))
            credentials.operations.clear()
            core.providerMutationOrder.clear()

            staleSecondViewModel.deleteConnection(fixture.connection.id)
            advanceUntilIdle()

            assertTrue(core.providerConnections.any { it.id == fixture.connection.id })
            assertEquals("synthetic-secret", credentials.values[fixture.connection.id])
            assertTrue(credentials.operations.isEmpty())
            assertTrue(core.providerMutationOrder.isEmpty())
            assertTrue(core.getProviderModelSyncCalls >= 1)
            assertEquals("completed", core.modelSyncJobs.getValue(running.id).state)
            assertNull(ready(staleSecondViewModel).modelSync)
            assertTrue(ready(staleSecondViewModel).notice!!.contains("완료"))
        }

    @Test
    fun `awaiting review prevents a second connection sync from replacing it`() = runTest {
        val first = providerFixture(suffix = "sync-a")
        val second = providerFixture(suffix = "sync-b")
        val review = modelSyncReviewFor(
            fixture = first,
            sha256 = "a".repeat(64),
            observedAt = "2026-01-02T00:00:00Z",
        )
        val active = activeModelSyncJob(
            id = "sync-a",
            fixture = first,
            state = "diff_ready_awaiting_review",
            updatedAt = "2026-01-02T00:00:01Z",
            review = review,
        )
        val core = coreForFixtures(listOf(first, second)).apply {
            modelSyncJobs[active.id] = active
        }
        val viewModel = SettingsViewModel(core, FakeCredentialStore())
        advanceUntilIdle()

        viewModel.startModelSync(second.connection.id)
        advanceUntilIdle()

        assertEquals(0, core.startProviderModelSyncCalls)
        assertEquals(setOf(active.id), core.modelSyncJobs.keys)
        val restored = ready(viewModel).modelSync as ModelSyncUiState.AwaitingReview
        assertEquals(active.id, restored.jobId)
        assertTrue(ready(viewModel).error!!.contains("먼저 완료하거나 취소"))
    }

    @Test
    fun `process wide start preflight restores another settings instance active sync`() =
        runTest {
            val first = providerFixture(suffix = "preflight-a")
            val second = providerFixture(suffix = "preflight-b")
            val review = modelSyncReviewFor(
                fixture = first,
                sha256 = "b".repeat(64),
                observedAt = "2026-01-02T00:00:00Z",
            )
            val active = activeModelSyncJob(
                id = "sync-preflight-a",
                fixture = first,
                state = "diff_ready_awaiting_review",
                updatedAt = "2026-01-02T00:00:01Z",
                review = review,
            )
            val core = coreForFixtures(listOf(first, second)).apply {
                nextStartedModelSyncJob = active
            }
            val credentials = FakeCredentialStore().apply {
                values[first.connection.id] = "first-secret"
                values[second.connection.id] = "second-secret"
            }
            val firstViewModel = SettingsViewModel(core, credentials)
            val secondViewModel = SettingsViewModel(core, credentials)
            advanceUntilIdle()

            firstViewModel.startModelSync(first.connection.id)
            advanceUntilIdle()
            secondViewModel.startModelSync(second.connection.id)
            advanceUntilIdle()

            assertEquals(1, core.startProviderModelSyncCalls)
            assertEquals(setOf(active.id), core.modelSyncJobs.keys)
            val restored = ready(secondViewModel).modelSync as ModelSyncUiState.AwaitingReview
            assertEquals(active.id, restored.jobId)
        }

    @Test
    fun `all restored active model syncs stay visible and individually actionable`() =
        runTest {
            val first = providerFixture(suffix = "restore-a")
            val second = providerFixture(suffix = "restore-b")
            val review = modelSyncReviewFor(
                fixture = first,
                sha256 = "c".repeat(64),
                observedAt = "2026-01-02T00:00:00Z",
            )
            val awaiting = activeModelSyncJob(
                id = "sync-restore-a",
                fixture = first,
                state = "diff_ready_awaiting_review",
                updatedAt = "2026-01-02T00:00:01Z",
                review = review,
            )
            val running = activeModelSyncJob(
                id = "sync-restore-b",
                fixture = second,
                state = "fetching",
                updatedAt = "2026-01-02T00:00:02Z",
            )
            val core = coreForFixtures(listOf(first, second)).apply {
                modelSyncJobs[awaiting.id] = awaiting
                modelSyncJobs[running.id] = running
            }
            val viewModel = SettingsViewModel(core, FakeCredentialStore())
            advanceUntilIdle()

            val multiple = ready(viewModel).modelSync as ModelSyncUiState.MultipleActive
            assertEquals(setOf(awaiting.id, running.id), multiple.jobs.map { it.jobId }.toSet())

            viewModel.cancelModelSync(running.id)
            advanceUntilIdle()
            val remaining = ready(viewModel).modelSync as ModelSyncUiState.AwaitingReview
            assertEquals(awaiting.id, remaining.jobId)

            viewModel.approveModelSync(awaiting.id, review.sha256)
            advanceUntilIdle()
            assertNull(ready(viewModel).modelSync)
        }

    @Test
    fun `interrupted sync participates in multiple active restore and remains actionable`() =
        runTest {
            val first = providerFixture(suffix = "multi-interrupted-a")
            val second = providerFixture(suffix = "multi-interrupted-b")
            val review = modelSyncReviewFor(
                fixture = first,
                sha256 = "d".repeat(64),
                observedAt = "2026-01-02T00:00:00Z",
            )
            val awaiting = activeModelSyncJob(
                id = "sync-multi-awaiting",
                fixture = first,
                state = "diff_ready_awaiting_review",
                updatedAt = "2026-01-02T00:00:01Z",
                review = review,
            )
            val interrupted = activeModelSyncJob(
                id = "sync-multi-interrupted",
                fixture = second,
                state = "interrupted",
                updatedAt = "2026-01-02T00:00:02Z",
            )
            val core = coreForFixtures(listOf(first, second)).apply {
                modelSyncJobs[awaiting.id] = awaiting
                modelSyncJobs[interrupted.id] = interrupted
            }
            val viewModel = SettingsViewModel(core, FakeCredentialStore())
            advanceUntilIdle()

            val multiple = ready(viewModel).modelSync as ModelSyncUiState.MultipleActive
            assertEquals(
                setOf(awaiting.id, interrupted.id),
                multiple.jobs.map { it.jobId }.toSet(),
            )
            val recoveredInterrupted = multiple.jobs
                .filterIsInstance<ModelSyncUiState.Interrupted>()
                .single()
            assertEquals(interrupted.id, recoveredInterrupted.jobId)

            viewModel.cancelModelSync(interrupted.id)
            advanceUntilIdle()

            val remaining = ready(viewModel).modelSync as ModelSyncUiState.AwaitingReview
            assertEquals(awaiting.id, remaining.jobId)
        }

    @Test
    fun `approve error reconciles durable failed job instead of leaving stale review`() =
        runTest {
            val fixture = providerFixture(suffix = "approve-failed")
            val review = modelSyncReviewFor(
                fixture = fixture,
                sha256 = "e".repeat(64),
                observedAt = "2026-01-02T00:00:00Z",
            )
            val awaiting = activeModelSyncJob(
                id = "sync-approve-failed",
                fixture = fixture,
                state = "diff_ready_awaiting_review",
                updatedAt = "2026-01-02T00:00:01Z",
                review = review,
            )
            val core = fixture.core().apply {
                modelSyncJobs[awaiting.id] = awaiting
                approveProviderModelSyncStateOnError = "failed"
                approveProviderModelSyncError =
                    IllegalStateException("commit failed after durable transition")
            }
            val viewModel = SettingsViewModel(core, FakeCredentialStore())
            advanceUntilIdle()

            viewModel.approveModelSync(awaiting.id, review.sha256)
            advanceUntilIdle()

            assertEquals(1, core.approveProviderModelSyncCalls)
            assertEquals("failed", core.modelSyncJobs.getValue(awaiting.id).state)
            val failed = ready(viewModel).modelSync as ModelSyncUiState.Failed
            assertTrue(failed.retryable)
            assertFalse(ready(viewModel).isBusy)
            assertTrue(ready(viewModel).error!!.contains("'failed'"))
        }

    @Test
    fun `cancel error reconciles committing job and resumed monitor observes completion`() =
        runTest {
            val fixture = providerFixture(suffix = "cancel-committing")
            val review = modelSyncReviewFor(
                fixture = fixture,
                sha256 = "f".repeat(64),
                observedAt = "2026-01-02T00:00:00Z",
            )
            val awaiting = activeModelSyncJob(
                id = "sync-cancel-committing",
                fixture = fixture,
                state = "diff_ready_awaiting_review",
                updatedAt = "2026-01-02T00:00:01Z",
                review = review,
            )
            val committing = awaiting.copy(
                state = "committing",
                revision = awaiting.revision + 1uL,
                updatedAt = "2026-01-02T00:00:02Z",
            )
            val completed = committing.copy(
                state = "completed",
                revision = committing.revision + 1uL,
                updatedAt = "2026-01-02T00:00:03Z",
            )
            val core = fixture.core().apply {
                modelSyncJobs[awaiting.id] = awaiting
                cancelProviderModelSyncStateOnError = "committing"
                cancelProviderModelSyncError = IllegalStateException(
                    "model synchronization cannot be cancelled while committing",
                )
                queuedModelSyncGetResponses[awaiting.id] =
                    ArrayDeque(listOf(committing, completed))
            }
            val viewModel = SettingsViewModel(core, FakeCredentialStore())
            advanceUntilIdle()

            viewModel.cancelModelSync(awaiting.id)
            advanceUntilIdle()

            assertEquals(1, core.cancelProviderModelSyncCalls)
            assertTrue(core.getProviderModelSyncCalls >= 2)
            assertEquals("completed", core.modelSyncJobs.getValue(awaiting.id).state)
            assertNull(ready(viewModel).modelSync)
            assertFalse(ready(viewModel).isBusy)
            assertTrue(ready(viewModel).notice!!.contains("완료"))
        }

    @Test
    fun `cancel error with unreadable exact outcome remains fail visible`() = runTest {
        val fixture = providerFixture(suffix = "cancel-unknown")
        val review = modelSyncReviewFor(
            fixture = fixture,
            sha256 = "1".repeat(64),
            observedAt = "2026-01-02T00:00:00Z",
        )
        val awaiting = activeModelSyncJob(
            id = "sync-cancel-unknown",
            fixture = fixture,
            state = "diff_ready_awaiting_review",
            updatedAt = "2026-01-02T00:00:01Z",
            review = review,
        )
        val core = fixture.core().apply {
            modelSyncJobs[awaiting.id] = awaiting
            cancelProviderModelSyncError = IllegalStateException("cancel transport failed")
        }
        val viewModel = SettingsViewModel(core, FakeCredentialStore())
        advanceUntilIdle()
        core.getProviderModelSyncError = IllegalStateException("exact job read failed")

        viewModel.cancelModelSync(awaiting.id)
        advanceUntilIdle()

        assertEquals(1, core.cancelProviderModelSyncCalls)
        val failed = ready(viewModel).modelSync as ModelSyncUiState.Failed
        assertTrue(failed.message.contains("확인할 수 없습니다"))
        assertFalse(ready(viewModel).isBusy)
        assertTrue(ready(viewModel).error!!.contains("상태 새로고침"))
    }

    @Test
    fun `model sync rejects cross-wired credential scope before Keystore read`() = runTest {
        val fixture = providerFixture()
        val core = fixture.core().apply {
            providerConnections[0] = fixture.connection.copy(
                credentialScope = fixture.connection.credentialScope?.copy(
                    allowedOrigins = listOf("https://other.example.invalid"),
                ),
            )
        }
        val credentials = FakeCredentialStore().apply {
            values["another-connection"] = "must-not-be-read"
        }
        val viewModel = SettingsViewModel(core, credentials)
        advanceUntilIdle()

        viewModel.startModelSync(fixture.connection.id)
        advanceUntilIdle()

        assertTrue(credentials.operations.isEmpty())
        assertNull(core.lastCredential)
        assertTrue(ready(viewModel).error!!.contains("scope"))
    }

    @Test
    fun `job scoped model sync never accepts or acknowledges another job event`() = runTest {
        val fixture = providerFixture()
        val activeJob = ModelSyncJob(
            id = "sync-a",
            connectionId = fixture.connection.id,
            state = "fetching",
            revision = 1uL,
            review = null,
            failure = null,
            createdAt = "2026-01-02T00:00:00Z",
            updatedAt = "2026-01-02T00:00:01Z",
        )
        val crossWired = modelSyncEvent(jobId = "sync-b", sequence = 1uL)
        val untouched = modelSyncEvent(jobId = "sync-b", sequence = 2uL)
        val core = fixture.core().apply {
            nextStartedModelSyncJob = activeJob
            modelSyncEvents["sync-a"] = ArrayDeque(listOf(crossWired))
            modelSyncEvents["sync-b"] = ArrayDeque(listOf(untouched))
        }
        val credentials = FakeCredentialStore().apply {
            values[fixture.connection.id] = "synthetic-secret"
        }
        val viewModel = SettingsViewModel(core, credentials)
        advanceUntilIdle()

        viewModel.startModelSync(fixture.connection.id)
        advanceUntilIdle()

        assertTrue(ready(viewModel).error!!.contains("다른 job ID"))
        assertTrue(core.acknowledgedModelSyncEvents.isEmpty())
        assertEquals(listOf(untouched), core.modelSyncEvents.getValue("sync-b").toList())
        val running = ready(viewModel).modelSync as ModelSyncUiState.Running
        assertEquals("sync-a", running.jobId)
    }

    @Test
    fun `catalog import round trips the exact reviewed plan and envelope`() = runTest {
        val plan = catalogImportPlan()
        val core = FakeCoreClient(catalogImportPlan = plan)
        val viewModel = SettingsViewModel(core, FakeCredentialStore())
        advanceUntilIdle()
        val submitted = """{"synthetic":"signed-envelope"}""".toByteArray()
        val expected = submitted.copyOf()

        viewModel.prepareCatalogImport(submitted)
        advanceUntilIdle()

        assertTrue(submitted.all { it == 0.toByte() })
        assertTrue(checkNotNull(core.lastPreparedCatalogBytes).contentEquals(expected))
        val review = (
            ready(viewModel).catalog as ProviderCatalogUiState.Ready
            ).pendingReview as ProviderCatalogPendingReview.Import
        assertEquals(plan.review.actionId, review.actionId)
        assertEquals(plan.planSha256, review.planSha256)

        viewModel.activateCatalogImport()
        advanceUntilIdle()

        assertEquals(plan, core.lastActivatedCatalogPlan)
        assertTrue(checkNotNull(core.lastActivatedCatalogBytes).contentEquals(expected))
        assertEquals(
            plan.review.candidateRevision,
            (ready(viewModel).catalog as ProviderCatalogUiState.Ready).status.activeRevision,
        )
    }

    @Test
    fun `catalog rollback activates only the exact reviewed CAS plan`() = runTest {
        val plan = catalogRollbackPlan()
        val core = FakeCoreClient(catalogRollbackPlan = plan)
        val viewModel = SettingsViewModel(core, FakeCredentialStore())
        advanceUntilIdle()

        viewModel.prepareCatalogRollback(plan.toRevision)
        advanceUntilIdle()

        val review = (
            ready(viewModel).catalog as ProviderCatalogUiState.Ready
            ).pendingReview as ProviderCatalogPendingReview.Rollback
        assertEquals(plan.actionId, review.actionId)
        assertEquals(plan.expectedStateVersion, review.expectedStateVersion)
        assertEquals(plan.planSha256, review.planSha256)

        viewModel.activateCatalogRollback()
        advanceUntilIdle()

        assertEquals(plan, core.lastActivatedRollbackPlan)
        assertEquals(
            plan.toRevision,
            (ready(viewModel).catalog as ProviderCatalogUiState.Ready).status.activeRevision,
        )
    }

    @Test
    fun `health failure is represented without crashing`() = runTest {
        val core = FakeCoreClient(healthError = IllegalStateException("database unavailable"))

        val viewModel = SettingsViewModel(core, FakeCredentialStore())
        advanceUntilIdle()

        assertTrue(viewModel.uiState.value is SettingsUiState.Error)
    }
}

private fun modelSyncEvent(
    jobId: String,
    sequence: ULong,
): ModelSyncEvent = ModelSyncEvent(
    version = 1u,
    jobId = jobId,
    sequence = sequence,
    jobRevision = 1uL,
    redactionVersion = 1u,
    state = "fetching",
    completedSteps = 1u,
    totalSteps = 3u,
    messageKey = "provider.model_sync.fetching",
    reviewSha256 = null,
    failure = null,
    emittedAt = "2026-01-02T00:00:01Z",
)

private fun emptyCatalogDiff(
    fromRevision: ULong,
    toRevision: ULong,
): ProviderCatalogDiff = ProviderCatalogDiff(
    diffSchemaVersion = 1u,
    fromRevision = fromRevision,
    toRevision = toRevision,
    addedProviderTemplates = emptyList(),
    changedProviderTemplates = emptyList(),
    removedProviderTemplates = emptyList(),
    addedModels = emptyList(),
    changedModels = emptyList(),
    removedModels = emptyList(),
)

private fun catalogImportPlan(): ProviderCatalogImportPlan {
    val diff = emptyCatalogDiff(1uL, 2uL)
    return ProviderCatalogImportPlan(
        review = ProviderCatalogImportReview(
            planSchemaVersion = 1u,
            actionId = "catalog-import-action",
            expectedStateVersion = 1uL,
            expectedActiveRevision = 1uL,
            expectedActiveSnapshotSha256 = "a".repeat(64),
            expectedHighestAcceptedRevision = 0uL,
            envelopeByteCount = 31uL,
            envelopeSha256 = "b".repeat(64),
            signingKeyId = "synthetic-key",
            payloadSha256 = "c".repeat(64),
            signedCatalogRevision = 2uL,
            candidateRevision = 2uL,
            candidateSnapshotSha256 = "d".repeat(64),
            preparedAt = "2026-01-02T00:00:00Z",
            expiresAt = "2026-01-02T00:15:00Z",
            diff = diff,
        ),
        planSha256 = "e".repeat(64),
        opaquePlanJson = """{"opaque":"import-plan"}""",
    )
}

private fun catalogRollbackPlan(): ProviderCatalogRollbackPlan =
    ProviderCatalogRollbackPlan(
        planSchemaVersion = 1u,
        actionId = "catalog-rollback-action",
        expectedStateVersion = 1uL,
        planSha256 = "f".repeat(64),
        fromRevision = 1uL,
        toRevision = 0uL,
        createdAt = "2026-01-02T00:00:00Z",
        expiresAt = "2026-01-02T00:15:00Z",
        diff = emptyCatalogDiff(1uL, 0uL),
        opaquePlanJson = """{"opaque":"rollback-plan"}""",
    )

private fun assistantConsentGrant(
    modelRouteId: String,
): DiscoveryApprovalGrant.AssistantConsent =
    DiscoveryApprovalGrant.AssistantConsent(
        assistantModelRouteId = modelRouteId,
        evidenceIds = listOf("evidence-1"),
        allowedDocumentOrigins = listOf("https://docs.example.invalid"),
        maxCalls = 2u,
        maxInputTokens = 1_024u,
        maxOutputTokens = 512u,
        maxToolCalls = 4u,
        maxRetries = 1u,
        maxCostMicroUnits = 10_000uL,
    )

private fun modelSyncReviewFor(
    fixture: ProviderFixture,
    sha256: String,
    observedAt: String,
): ModelSyncReview = ModelSyncReview(
    sha256 = sha256,
    connectionId = fixture.connection.id,
    expectedConnection = fixture.connection,
    observedAt = observedAt,
    expectedModelRoutes = listOf(fixture.route),
    listedRoutes = listOf(fixture.route),
    newlySeenModelRouteIds = emptyList(),
    missingModelRouteIds = emptyList(),
    initialPresets = emptyList(),
    capabilityObservations = listOf(fixture.observation),
    routesRequiringPresetConfiguration = emptyList(),
    provenance = ModelSyncProvenance(
        source = "provider_api",
        apiFamily = fixture.route.apiFamily,
        apiOrigin = fixture.connection.apiOrigin,
        endpointPath = "/v1/models",
        pagesFetched = 1u,
        responseBytes = 256uL,
    ),
)

private fun activeModelSyncJob(
    id: String,
    fixture: ProviderFixture,
    state: String,
    updatedAt: String,
    review: ModelSyncReview? = null,
): ModelSyncJob = ModelSyncJob(
    id = id,
    connectionId = fixture.connection.id,
    state = state,
    revision = 3uL,
    review = review,
    failure = null,
    createdAt = "2026-01-02T00:00:00Z",
    updatedAt = updatedAt,
)

private fun assistantDiscoveryInput(
    connectionId: String,
): ProviderDiscoveryInput = ProviderDiscoveryInput(
    connectionId = connectionId,
    displayName = "Assistant-discovered provider",
    siteUrl = "https://provider.example.invalid",
    docsUrl = null,
    credentialSlotReady = false,
    preferredAssistantModelRouteId = "route-1",
    connectionOptions = ProviderDiscoveryConnectionOptions(
        values = emptyList(),
        apiBasePath = null,
        timeoutSeconds = 30u,
        networkMode = ProviderNetworkMode.Public,
        localNetworkApproval = null,
    ),
)

private fun assistantDraftReview(): DiscoveryAssistantDraftReview =
    DiscoveryAssistantDraftReview(
        draft = DiscoveryAssistantManifestDraft(
            manifest = DiscoveryAssistantManifest(
                schemaVersion = 1u,
                apiFamily = "openai_chat_completions",
                sources = emptyList(),
                defaultApiOrigin = "https://api.example.invalid",
                auth = AuthBinding.BearerHeader,
                modelsEndpoint = DiscoveryAssistantEndpoint("GET", "/v1/models"),
                generateEndpoint = DiscoveryAssistantEndpoint(
                    "POST",
                    "/v1/chat/completions",
                ),
                responseDecoder = "openai_json_v1",
                streamingDecoder = "openai_sse_v1",
                parameters = emptyList(),
            ),
            evidenceMappings = emptyList(),
            conflicts = emptyList(),
            unresolvedQuestions = emptyList(),
            confidence = emptyList(),
            summary = "Synthetic manifest draft",
        ),
        unresolvedConflicts = emptyList(),
        requiredChecks = listOf(
            DiscoveryAssistantDraftReviewCheck.ManifestValidation,
            DiscoveryAssistantDraftReviewCheck.UrlPolicyValidation,
            DiscoveryAssistantDraftReviewCheck.CredentialOriginApproval,
            DiscoveryAssistantDraftReviewCheck.UserReview,
        ),
        persistence = DiscoveryAssistantDraftPersistence.BlockedUntilChecksPass,
    )

private fun ready(viewModel: SettingsViewModel): SettingsUiState.Ready =
    viewModel.uiState.value as SettingsUiState.Ready

private data class ProviderFixture(
    val template: ProviderTemplate,
    val connection: ProviderConnection,
    val route: ModelRoute,
    val preset: GenerationPreset,
    val observation: CapabilityObservation,
    val effective: EffectiveCapability,
    val presets: List<GenerationPreset>,
) {
    fun settings(): AppSettings = AppSettings(
        preservePartialGenerations = false,
        selectedProviderProfileId = null,
        selectedModelRouteId = route.id,
        selectedGenerationPresetId = preset.id,
    )

    fun core(
        settings: AppSettings = AppSettings(false, null),
        deleteConnectionError: Throwable? = null,
        trace: MutableList<String>? = null,
    ): FakeCoreClient = FakeCoreClient(
        health = healthyCoreStatus().copy(schemaVersion = 9),
        providerTemplates = mutableListOf(template),
        providerConnections = mutableListOf(connection),
        modelRoutes = mutableMapOf(connection.id to mutableListOf(route)),
        generationPresets = mutableMapOf(route.id to presets.toMutableList()),
        capabilityObservations = mutableMapOf(
            route.id to mutableListOf(observation),
        ),
        effectiveCapabilities = mutableMapOf(
            (route.id to observation.key) to effective,
        ),
        settings = settings,
        deleteConnectionError = deleteConnectionError,
        operationTrace = trace,
    )
}

private fun coreForFixtures(
    fixtures: List<ProviderFixture>,
    settings: AppSettings = AppSettings(false, null),
): FakeCoreClient = FakeCoreClient(
    health = healthyCoreStatus().copy(schemaVersion = 9),
    providerTemplates = fixtures.map(ProviderFixture::template).distinctBy { it.id }.toMutableList(),
    providerConnections = fixtures.map(ProviderFixture::connection).toMutableList(),
    modelRoutes = fixtures.associate { fixture ->
        fixture.connection.id to mutableListOf(fixture.route)
    }.toMutableMap(),
    generationPresets = fixtures.associate { fixture ->
        fixture.route.id to fixture.presets.toMutableList()
    }.toMutableMap(),
    capabilityObservations = fixtures.associate { fixture ->
        fixture.route.id to mutableListOf(fixture.observation)
    }.toMutableMap(),
    effectiveCapabilities = fixtures.associate { fixture ->
        (fixture.route.id to fixture.observation.key) to fixture.effective
    }.toMutableMap(),
    settings = settings,
)

private fun providerFixture(
    presets: List<GenerationPreset>? = null,
    suffix: String = "1",
): ProviderFixture {
    val template = syntheticTemplate()
    val connection = ProviderConnection(
        id = "connection-$suffix",
        templateId = template.id,
        templateVersion = template.manifestVersion,
        displayName = "내 Example AI",
        apiOrigin = template.defaultApiOrigin!!,
        apiBasePath = null,
        networkMode = ProviderNetworkMode.Public,
        values = emptyList(),
        credentialSlotReady = true,
        credentialScope = CredentialScope(
            allowedOrigins = listOf(template.defaultApiOrigin!!),
            authBinding = template.authBinding,
            redirectPolicy = CredentialRedirectPolicy.Deny,
        ),
        approvedCredentialOrigins = listOf(template.defaultApiOrigin),
        timeoutSeconds = 60u,
        status = "connected",
        createdAt = "2026-01-01T00:00:00Z",
        updatedAt = "2026-01-01T00:00:00Z",
    )
    val route = ModelRoute(
        id = "route-$suffix",
        connectionId = connection.id,
        apiFamily = template.apiFamily,
        modelId = "example-chat-$suffix",
        displayName = "Example Chat",
        routeConfig = ModelRouteConfig(null, null, null, emptyList()),
        availability = "available",
        metadataSource = "provider_api",
        metadataObservedAt = "2026-01-01T00:00:00Z",
        firstSeenAt = "2026-01-01T00:00:00Z",
        lastSeenAt = "2026-01-01T00:00:00Z",
    )
    val preset = GenerationPreset(
        id = "preset-$suffix",
        modelRouteId = route.id,
        displayName = "기본 역할극",
        values = emptyList(),
        reasoningMode = "provider_default",
        reasoningEffort = null,
        reasoningBudgetTokens = null,
        reasoningSummary = "provider_default",
        preserveOpaqueReasoningState = false,
        promptCacheMode = "provider_default",
        promptCacheTtl = "provider_default",
        promptCacheCustomTtlSeconds = null,
        promptCacheContextReference = null,
        createdAt = "2026-01-01T00:00:00Z",
        updatedAt = "2026-01-01T00:00:00Z",
    )
    val observation = CapabilityObservation(
        id = "observation-$suffix",
        modelRouteId = route.id,
        key = "streaming",
        value = CapabilityValue("boolean", true, null, emptyList(), null),
        status = "verified",
        source = "capability_probe",
        confidence = "high",
        observedAt = "2026-01-01T00:00:00Z",
        expiresAt = null,
        evidenceRef = "evidence-$suffix",
    )
    val effective = EffectiveCapability(
        selected = observation,
        alternatives = emptyList(),
        evaluatedAt = "2026-01-01T00:00:00Z",
        selectedIsStale = false,
        hasConflict = false,
    )
    return ProviderFixture(
        template = template,
        connection = connection,
        route = route,
        preset = preset,
        observation = observation,
        effective = effective,
        presets = presets ?: listOf(preset),
    )
}

private fun syntheticTemplate(): ProviderTemplate = ProviderTemplate(
    id = "example-v1",
    displayName = "Example AI",
    manifestVersion = 1u,
    source = "builtin",
    apiFamily = "openai_chat_completions",
    defaultApiOrigin = "https://api.example.invalid",
    requiresCredential = true,
    supportsModelListing = true,
    authBinding = AuthBinding.BearerHeader,
    connectionFields = listOf(
        ConnectionFieldSpec(
            key = "organization",
            labelKey = "organization",
            descriptionKey = null,
            valueType = ConnectionFieldType.Text,
            required = false,
        ),
    ),
    parameters = listOf(
        ParameterSpec(
            id = "temperature",
            labelKey = "temperature",
            descriptionKey = "sampling temperature",
            valueType = ParameterType.Number,
            allowedValues = emptyList(),
            minimum = 0.0,
            maximum = 2.0,
            step = 0.1,
            defaultMode = ParameterDefaultMode.ProviderDefault,
            visibility = null,
            conflicts = emptyList(),
            providerMapping = ProviderParameterMapping(
                target = ProviderParameterTarget.RequestBody,
                fieldName = "temperature",
            ),
            level = UiParameterLevel.Basic,
        ),
    ),
)
