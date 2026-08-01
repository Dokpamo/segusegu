package dev.lorepia.app

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToIndex
import dev.lorepia.app.bridge.*
import dev.lorepia.app.feature.settings.*
import dev.lorepia.app.ui.theme.LorepiaTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class ProviderSettingsScreenTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun credentialOriginApprovalShowsExactOriginWithoutSecret() {
        var approved = false
        val setup = ProviderSetupState(
            connectionId = "connection-1",
            kind = ProviderSetupKind.KnownProvider,
            step = ProviderSetupStep.ApproveCredentialOrigin,
            templateId = "template-1",
            displayName = "Example",
            apiOrigin = "https://api.example.invalid",
            hasPendingCredential = true,
            discovery = credentialOriginApprovalSnapshot(),
        )
        render(readyState(setup = setup), onApproveOrigin = { approved = true })

        scrollToProviderItem()
        composeRule
            .onNodeWithText("https://api.example.invalid")
            .performScrollTo()
            .assertIsDisplayed()
        composeRule.onNodeWithText("must-never-render").assertDoesNotExist()
        composeRule
            .onNodeWithTag("approve-credential-origin")
            .performScrollTo()
            .assertIsDisplayed()
        composeRule.onNodeWithTag("approve-credential-origin").performClick()
        assertTrue(approved)
    }

    @Test
    fun capabilityStalenessConflictAndProvenanceAreVisible() {
        val selected = CapabilityObservation(
            id = "observation-1",
            modelRouteId = "route-1",
            key = "reasoning",
            value = CapabilityValue("boolean", true, null, emptyList(), null),
            status = "documented",
            source = "official_documentation",
            confidence = "medium",
            observedAt = "2026-01-01T00:00:00Z",
            expiresAt = "2026-02-01T00:00:00Z",
            evidenceRef = "evidence-1",
        )
        val routeDetails = ModelRouteDetails(
            route = route(),
            presets = emptyList(),
            capabilities = listOf(
                CapabilityDetails(
                    key = selected.key,
                    effective = EffectiveCapability(
                        selected = selected,
                        alternatives = listOf(
                            selected.copy(
                                id = "observation-2",
                                source = "capability_probe",
                                status = "unsupported",
                            ),
                        ),
                        evaluatedAt = "2026-03-01T00:00:00Z",
                        selectedIsStale = true,
                        hasConflict = true,
                    ),
                    observations = listOf(selected),
                ),
            ),
        )
        render(
            readyState(
                connections = listOf(
                    ProviderConnectionDetails(connection(), template(), listOf(routeDetails)),
                ),
            ),
        )

        scrollToProviderItem()
        composeRule.onNodeWithText("오래된 근거").performScrollTo().assertIsDisplayed()
        composeRule
            .onNodeWithText("근거가 서로 충돌합니다. 대안 1개")
            .performScrollTo()
            .assertIsDisplayed()
        composeRule.onNodeWithText(
            "선택 · true · Documented · 공식 문서 · 신뢰도 Medium",
        ).performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithText(
            "대안 1 · true · Unsupported · 실제 capability 검사 · 신뢰도 Medium",
        ).performScrollTo().assertIsDisplayed()
    }

    @Test
    fun providerDefaultParameterIsMarkedAsRequestOmission() {
        val spec = template().parameters.single()
        val editor = PresetEditor(
            id = "preset-new",
            modelRouteId = "route-1",
            displayName = "기본",
            parameterSpecs = listOf(spec),
            explicitValues = emptyMap(),
        )
        render(readyState(presetEditor = editor))

        composeRule.onNodeWithTag("parameter-inherit-${spec.id}").assertIsOn()
        composeRule
            .onNodeWithText("요청에서 이 필드를 생략합니다.")
            .performScrollTo()
            .assertIsDisplayed()
    }

    @Test
    fun coreHostAssistantResumeRequiresDedicatedExplicitAction() {
        var receivedAction: ProviderDiscoveryUiAction? = null
        val setup = ProviderSetupState(
            connectionId = "connection-1",
            step = ProviderSetupStep.Discovering,
            discovery = assistantCoreHostResumeSnapshot(),
        )
        render(
            state = readyState(setup = setup),
            onDiscoveryAction = { receivedAction = it },
        )

        composeRule
            .onNodeWithTag("resume-discovery-assistant-core-host-action")
            .assertIsDisplayed()
            .performClick()

        assertEquals(
            ProviderDiscoveryUiAction.ResumeAssistantCoreHostAction,
            receivedAction,
        )
    }

    @Test
    fun assistantRequestRequiresTheFrozenExecutableModelAndPreset() {
        val routeDetails = ModelRouteDetails(
            route = route(),
            presets = listOf(generationPreset()),
            capabilities = emptyList(),
        )
        val setup = ProviderSetupState(
            connectionId = "pending-connection",
            step = ProviderSetupStep.Discovering,
            preferredAssistantModelRouteId = "route-1",
            discovery = assistantCoreHostResumeSnapshot().copy(
                pendingConnectionId = "pending-connection",
                state = "awaiting_more_evidence",
                actionRequired = DiscoveryActionRequired.SupplyMoreEvidence,
                assistantResumeBoundary = null,
            ),
        )
        render(
            readyState(
                setup = setup,
                settings = AppSettings(
                    preservePartialGenerations = false,
                    selectedProviderProfileId = null,
                    selectedModelRouteId = "route-1",
                    selectedGenerationPresetId = "preset-1",
                ),
                connections = listOf(
                    ProviderConnectionDetails(
                        connection = connection().copy(credentialSlotReady = false),
                        template = template(),
                        routes = listOf(routeDetails),
                    ),
                ),
            ),
        )

        composeRule
            .onNodeWithTag("request-discovery-assistant")
            .performScrollTo()
            .assertIsDisplayed()
            .assertIsEnabled()
        composeRule
            .onNodeWithTag("discovery-assistant-target")
            .performScrollTo()
            .assertIsDisplayed()
    }

    @Test
    fun assistantRequestIsDisabledWhenNoExecutableTargetWasFrozen() {
        val setup = ProviderSetupState(
            connectionId = "pending-connection",
            step = ProviderSetupStep.Discovering,
            preferredAssistantModelRouteId = null,
            discovery = assistantCoreHostResumeSnapshot().copy(
                pendingConnectionId = "pending-connection",
                state = "awaiting_more_evidence",
                actionRequired = DiscoveryActionRequired.SupplyMoreEvidence,
                assistantResumeBoundary = null,
            ),
        )
        render(readyState(setup = setup))

        composeRule
            .onNodeWithTag("request-discovery-assistant")
            .performScrollTo()
            .assertIsDisplayed()
            .assertIsNotEnabled()
        composeRule
            .onNodeWithTag("discovery-assistant-unavailable")
            .performScrollTo()
            .assertIsDisplayed()
    }

    @Test
    fun existingCredentialReplacementRequiresNewConnection() {
        render(
            readyState(
                connectionEditor = ConnectionEditor(connection()),
            ),
        )

        composeRule
            .onNodeWithTag("credential-replacement-requires-new-connection")
            .assertIsDisplayed()
        composeRule.onNodeWithTag("replacement-credential").assertDoesNotExist()
        composeRule
            .onNodeWithText("API endpoint와 연결 옵션을 바꾸려면 새 AI 연결을 만드세요.")
            .assertIsDisplayed()
    }

    @Test
    fun opaqueReasoningContinuityIsHiddenWhenCoreDisallowsIt() {
        val editor = PresetEditor(
            id = "preset-new",
            modelRouteId = "route-1",
            displayName = "기본",
            parameterSpecs = emptyList(),
            explicitValues = emptyMap(),
            preserveOpaqueReasoningState = true,
        )
        render(
            readyState(
                presetEditor = editor,
                presetControls = opaqueReasoningControls(false),
            ),
        )

        composeRule
            .onNodeWithTag("settings-content")
            .performScrollToIndex(3)
        composeRule.onNodeWithText("추론").performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithTag("opaque-reasoning-state").assertDoesNotExist()
        composeRule
            .onNodeWithText("같은 provider·route·model에서 opaque reasoning state 유지")
            .assertDoesNotExist()
    }

    @Test
    fun credentialConnectionHidesOpaqueContinuityEvenWhenCoreReturnsTrue() {
        val editor = PresetEditor(
            id = "preset-new",
            modelRouteId = "route-1",
            displayName = "기본",
            parameterSpecs = emptyList(),
            explicitValues = emptyMap(),
            preserveOpaqueReasoningState = true,
        )
        val routeDetails = ModelRouteDetails(
            route = route(),
            presets = emptyList(),
            capabilities = emptyList(),
        )
        render(
            readyState(
                connections = listOf(
                    ProviderConnectionDetails(
                        connection = connection(),
                        template = template(),
                        routes = listOf(routeDetails),
                    ),
                ),
                presetEditor = editor,
                presetControls = opaqueReasoningControls(true),
            ),
        )

        composeRule
            .onNodeWithTag("settings-content")
            .performScrollToIndex(3)
        composeRule.onNodeWithText("추론").performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithTag("opaque-reasoning-state").assertDoesNotExist()
        composeRule
            .onNodeWithText("같은 provider·route·model에서 opaque reasoning state 유지")
            .assertDoesNotExist()
    }

    @Test
    fun exactEnabledDefaultEffortIsVisibleAsSelected() {
        val editor = PresetEditor(
            id = "preset-new",
            modelRouteId = "route-1",
            displayName = "기본",
            parameterSpecs = emptyList(),
            explicitValues = emptyMap(),
            reasoningMode = "enabled",
            reasoningEffort = "medium",
        )
        render(
            readyState(
                presetEditor = editor,
                presetControls = opaqueReasoningControls(
                    preserveOpaqueState = false,
                    mode = "enabled",
                    effort = "medium",
                    allowedEfforts = listOf("low", "medium", "high"),
                    effortField = "enabled",
                ),
            ),
        )

        composeRule
            .onNodeWithTag("settings-content")
            .performScrollToIndex(3)
        composeRule
            .onNodeWithTag("reasoning-effort-2")
            .performScrollTo()
            .assertIsDisplayed()
            .assertIsSelected()
        composeRule.onNodeWithText("Medium").assertIsDisplayed()
    }

    @Test
    fun multipleActiveModelSyncJobsStayVisibleAndIndividuallyActionable() {
        var approved: Pair<String, String>? = null
        val cancelled = mutableListOf<String>()
        val awaitingReview = ModelSyncUiState.AwaitingReview(
            connectionId = "connection-a",
            jobId = "sync-a",
            reviewHash = "review-a",
            targetSummary = "Example A",
            addedModels = listOf("model-a"),
            changedModels = emptyList(),
            missingModels = emptyList(),
            capabilityChanges = emptyList(),
            initialPresets = emptyList(),
            routesRequiringPresetConfiguration = emptyList(),
            provenance = listOf("provider list"),
        )
        val interrupted = ModelSyncUiState.Interrupted(
            connectionId = "connection-b",
            jobId = "sync-b",
        )
        render(
            state = readyState(
                modelSync = ModelSyncUiState.MultipleActive(listOf(awaitingReview, interrupted)),
            ),
            onApproveModelSync = { jobId, reviewHash -> approved = jobId to reviewHash },
            onCancelModelSync = cancelled::add,
        )

        composeRule
            .onNodeWithTag("model-sync-state")
            .performScrollTo()
            .assertIsDisplayed()
        composeRule
            .onNodeWithText("복구된 동기화 작업 2개를 모두 정리해야 새 동기화를 시작할 수 있습니다.")
            .assertIsDisplayed()
        composeRule.onNodeWithText("작업 1 · connection-a").assertIsDisplayed()
        composeRule.onNodeWithText("작업 2 · connection-b").performScrollTo().assertIsDisplayed()
        composeRule
            .onNodeWithText("이전 provider 요청이 중단되었습니다.")
            .performScrollTo()
            .assertIsDisplayed()

        composeRule.onNodeWithTag("approve-model-sync").performScrollTo().performClick()
        composeRule
            .onNodeWithTag("cancel-interrupted-model-sync-sync-b")
            .performScrollTo()
            .performClick()

        assertEquals("sync-a" to "review-a", approved)
        assertEquals(listOf("sync-b"), cancelled)
    }

    @Test
    fun interruptedModelSyncExplainsManualRetryAndCanBeCancelled() {
        var cancelledJobId: String? = null
        render(
            state = readyState(
                modelSync = ModelSyncUiState.Interrupted(
                    connectionId = "connection-interrupted",
                    jobId = "sync-interrupted",
                ),
            ),
            onCancelModelSync = { cancelledJobId = it },
        )

        composeRule
            .onNodeWithTag("model-sync-state")
            .performScrollTo()
            .assertIsDisplayed()
        composeRule
            .onNodeWithText("이전 provider 요청이 중단되었습니다.")
            .assertIsDisplayed()
        composeRule
            .onNodeWithText(
                "자격증명이 필요한 네트워크 요청은 자동으로 재개되지 않습니다. " +
                    "중단 작업을 취소한 뒤 모델 새로고침을 직접 다시 시작해 주세요.",
            )
            .performScrollTo()
            .assertIsDisplayed()
        composeRule
            .onNodeWithTag("cancel-interrupted-model-sync-sync-interrupted")
            .performScrollTo()
            .assertIsDisplayed()
            .performClick()

        assertEquals("sync-interrupted", cancelledJobId)
    }

    private fun render(
        state: SettingsUiState.Ready,
        onApproveOrigin: () -> Unit = {},
        onDiscoveryAction: (ProviderDiscoveryUiAction) -> Unit = {},
        onApproveModelSync: (String, String) -> Unit = { _, _ -> },
        onCancelModelSync: (String) -> Unit = {},
    ) {
        composeRule.setContent {
            LorepiaTheme {
                SettingsScreen(
                    uiState = state,
                    onRefresh = {},
                    onBeginAddConnection = {},
                    onChooseSetupKind = {},
                    onChooseKnownTemplate = {},
                    onUpdateSetup = {},
                    onSubmitSetupDetails = { _, _ -> },
                    onDiscoveryAction = onDiscoveryAction,
                    onCatalogAction = {},
                    onApproveCredentialOrigin = onApproveOrigin,
                    onCommitSetup = {},
                    onCancelSetup = {},
                    onRetrySetup = {},
                    onBeginEditConnection = {},
                    onUpdateConnectionEditor = {},
                    onCancelConnectionEditor = {},
                    onSaveConnectionEditor = {},
                    onDeleteConnection = {},
                    onStartModelSync = {},
                    onApproveModelSync = onApproveModelSync,
                    onCancelModelSync = onCancelModelSync,
                    onDismissModelSync = {},
                    onSelectGenerationPreset = { _, _ -> },
                    onBeginAddPreset = {},
                    onBeginEditPreset = {},
                    onUpdatePresetEditor = {},
                    onCancelPresetEditor = {},
                    onSavePreset = {},
                    onDeletePreset = {},
                    onPreservePartialChanged = {},
                    contentPadding = PaddingValues(),
                )
            }
        }
    }

    private fun scrollToProviderItem() {
        composeRule
            .onNodeWithTag("settings-content")
            .performScrollToIndex(2)
    }
}

private fun readyState(
    setup: ProviderSetupState? = null,
    settings: AppSettings = AppSettings(false, null),
    connections: List<ProviderConnectionDetails> = emptyList(),
    connectionEditor: ConnectionEditor? = null,
    presetEditor: PresetEditor? = null,
    presetControls: PresetControls? = null,
    modelSync: ModelSyncUiState? = null,
): SettingsUiState.Ready = SettingsUiState.Ready(
    health = CoreHealthStatus(
        coreVersion = "test",
        databaseOpen = true,
        schemaVersion = 9,
        dataRootWritable = true,
        stagingWritable = true,
        recoveryPending = false,
        activeJobs = 0,
    ),
    settings = settings,
    templates = listOf(template()),
    connections = connections,
    setup = setup,
    connectionEditor = connectionEditor,
    presetEditor = presetEditor,
    presetControls = presetControls,
    modelSync = modelSync,
)

private fun opaqueReasoningControls(
    preserveOpaqueState: Boolean,
    mode: String = "provider_default",
    effort: String? = null,
    allowedEfforts: List<String> = emptyList(),
    effortField: String = "hidden",
): PresetControls = PresetControls(
    reasoning = ReasoningControl(
        state = "ready",
        mode = mode,
        effort = effort,
        budgetTokens = null,
        summary = "provider_default",
        preserveOpaqueState = preserveOpaqueState,
        allowedModes = listOf("provider_default", "disabled"),
        allowedEfforts = allowedEfforts,
        allowedSummaries = listOf("provider_default"),
        minimumBudgetTokens = null,
        maximumBudgetTokens = null,
        effortField = effortField,
        budgetField = "hidden",
        summaryField = "hidden",
        issues = emptyList(),
    ),
    promptCache = PromptCacheControl(
        state = "hidden",
        mode = "provider_default",
        ttl = "provider_default",
        customTtlSeconds = null,
        contextReference = null,
        allowedModes = emptyList(),
        allowedTtls = emptyList(),
        supportsCustomTtl = false,
        minimumCustomTtlSeconds = null,
        maximumCustomTtlSeconds = null,
        ttlField = "hidden",
        contextReferenceField = "hidden",
        issues = emptyList(),
    ),
)

private fun assistantCoreHostResumeSnapshot(): ProviderDiscoverySnapshot =
    ProviderDiscoverySnapshot(
        snapshotSchemaVersion = 3u,
        sessionId = "discovery-1",
        pendingConnectionId = "connection-1",
        pendingDisplayName = "Example",
        connectionOptions = ProviderDiscoveryConnectionOptions(
            values = emptyList(),
            apiBasePath = null,
            timeoutSeconds = 60u,
            networkMode = ProviderNetworkMode.Public,
            localNetworkApproval = null,
        ),
        credentialSlotId = null,
        credentialSlotExpected = false,
        revision = 4uL,
        state = "building_assistant_manifest_draft",
        nextEventSequence = 5uL,
        steps = emptyList(),
        actionRequired = null,
        activeOperationId = null,
        recoveryOperation = null,
        unknownOperation = null,
        manifestSha256 = null,
        commitPlanSha256 = null,
        commitAttemptId = null,
        committedConnectionId = null,
        cancellationPending = false,
        failure = null,
        candidates = emptyList(),
        evidence = emptyList(),
        approvals = emptyList(),
        approvalProposal = null,
        review = null,
        reviewProposal = null,
        createdAt = "2026-01-01T00:00:00Z",
        updatedAt = "2026-01-01T00:00:01Z",
        assistantResumeBoundary = DiscoveryAssistantResumeBoundary(
            checkpoint = DiscoveryAssistantCheckpoint.AwaitingToolResult,
            action = DiscoveryAssistantResumeAction.ResumeCoreHostAction,
            questions = emptyList(),
            draftReview = null,
        ),
    )

private fun credentialOriginApprovalSnapshot(): ProviderDiscoverySnapshot =
    assistantCoreHostResumeSnapshot().copy(
        credentialSlotId = "connection-1",
        credentialSlotExpected = true,
        state = "awaiting_credential_origin_approval",
        actionRequired = DiscoveryActionRequired.ApproveCredentialOrigin,
        manifestSha256 = "a".repeat(64),
        approvalProposal = DiscoveryApprovalProposal(
            approvalId = "approval-credential-1",
            grant = DiscoveryApprovalGrant.CredentialOrigin(
                origin = "https://api.example.invalid",
                authBinding = AuthBinding.BearerHeader,
                manifestSha256 = "a".repeat(64),
            ),
            grantSha256 = "b".repeat(64),
        ),
        assistantResumeBoundary = null,
    )

private fun template(): ProviderTemplate = ProviderTemplate(
    id = "template-1",
    displayName = "Example AI",
    manifestVersion = 1u,
    source = "builtin",
    apiFamily = "openai_chat_completions",
    defaultApiOrigin = "https://api.example.invalid",
    requiresCredential = true,
    supportsModelListing = true,
    authBinding = AuthBinding.BearerHeader,
    connectionFields = emptyList(),
    parameters = listOf(
        ParameterSpec(
            id = "temperature",
            labelKey = "temperature",
            descriptionKey = null,
            valueType = ParameterType.Number,
            allowedValues = emptyList(),
            minimum = 0.0,
            maximum = 2.0,
            step = 0.1,
            defaultMode = ParameterDefaultMode.ProviderDefault,
            visibility = null,
            conflicts = emptyList(),
            providerMapping = ProviderParameterMapping(
                ProviderParameterTarget.RequestBody,
                "temperature",
            ),
            level = UiParameterLevel.Basic,
        ),
    ),
)

private fun connection(): ProviderConnection = ProviderConnection(
    id = "connection-1",
    templateId = "template-1",
    templateVersion = 1u,
    displayName = "Example",
    apiOrigin = "https://api.example.invalid",
    apiBasePath = null,
    networkMode = ProviderNetworkMode.Public,
    values = emptyList(),
    credentialSlotReady = true,
    credentialScope = null,
    approvedCredentialOrigins = listOf("https://api.example.invalid"),
    timeoutSeconds = 60u,
    status = "connected",
    createdAt = "2026-01-01T00:00:00Z",
    updatedAt = "2026-01-01T00:00:00Z",
)

private fun route(): ModelRoute = ModelRoute(
    id = "route-1",
    connectionId = "connection-1",
    apiFamily = "openai_chat_completions",
    modelId = "example-chat",
    displayName = "Example Chat",
    routeConfig = ModelRouteConfig(null, null, null, emptyList()),
    availability = "available",
    firstSeenAt = "2026-01-01T00:00:00Z",
    lastSeenAt = "2026-01-01T00:00:00Z",
)

private fun generationPreset(): GenerationPreset = GenerationPreset(
    id = "preset-1",
    modelRouteId = "route-1",
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
