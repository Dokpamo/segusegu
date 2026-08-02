package dev.lorepia.app.feature.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import dev.lorepia.app.bridge.ConnectionConfigEntry
import dev.lorepia.app.bridge.ConnectionConfigValue
import dev.lorepia.app.bridge.ConnectionFieldType
import dev.lorepia.app.bridge.CoreClient
import dev.lorepia.app.bridge.DiscoveryActionRequired
import dev.lorepia.app.bridge.DiscoveryApprovalGrant
import dev.lorepia.app.bridge.DiscoveryAssistantCallEstimate
import dev.lorepia.app.bridge.DiscoveryAssistantOutcome
import dev.lorepia.app.bridge.DiscoveryAssistantResumeAction
import dev.lorepia.app.bridge.DiscoveryCandidateSummary
import dev.lorepia.app.bridge.DiscoveryUnknownOutcomeResolution
import dev.lorepia.app.bridge.GenerationPreset
import dev.lorepia.app.bridge.GenerationTarget
import dev.lorepia.app.bridge.ParameterValue
import dev.lorepia.app.bridge.ParameterValueState
import dev.lorepia.app.bridge.ProviderConnection
import dev.lorepia.app.bridge.ProviderConnectionDraft
import dev.lorepia.app.bridge.ProviderCatalogImportPlan
import dev.lorepia.app.bridge.ProviderCatalogRollbackPlan
import dev.lorepia.app.bridge.ProviderDiscoveryAction
import dev.lorepia.app.bridge.ProviderDiscoveryConnectionOptions
import dev.lorepia.app.bridge.ProviderDiscoveryInput
import dev.lorepia.app.bridge.ProviderDiscoverySnapshot
import dev.lorepia.app.bridge.ProviderDiscoverySource
import dev.lorepia.app.bridge.ProviderNetworkMode
import dev.lorepia.app.bridge.ProviderNetworkPolicy
import dev.lorepia.app.bridge.ProviderTemplate
import dev.lorepia.app.bridge.ReasoningControl
import dev.lorepia.app.platform.credentials.CredentialStore
import dev.lorepia.app.platform.credentials.CredentialRecordStatus
import dev.lorepia.app.platform.credentials.validatedCredentialRefForRead
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit

class SettingsViewModel(
    private val coreClient: CoreClient,
    private val credentialStore: CredentialStore,
) : ViewModel() {
    private val credentialCoordinator = ProviderCredentialCoordinator(
        coreClient = coreClient,
        credentialStore = credentialStore,
    )
    private val _uiState = MutableStateFlow<SettingsUiState>(SettingsUiState.Loading)
    val uiState: StateFlow<SettingsUiState> = _uiState.asStateFlow()
    private var refreshJob: Job? = null
    private var modelSyncJob: Job? = null
    private var discoveryMonitorJob: Job? = null
    private var presetControlJob: Job? = null
    private var presetControlRevision = 0L
    private var stateRevision = 0L
    private var catalogRevision = 0L
    private var pendingCredentialConnectionId: String? = null
    private var pendingCredential: CharArray? = null
    private var pendingCatalogImportBytes: ByteArray? = null
    private var pendingCatalogImportPlan: ProviderCatalogImportPlan? = null
    private var pendingCatalogRollbackPlan: ProviderCatalogRollbackPlan? = null
    private val snapshotReadSemaphore = Semaphore(MAX_CONCURRENT_SNAPSHOT_READS)

    init {
        refresh()
    }

    fun refresh() {
        clearPendingCredential()
        clearPendingCatalogMutation()
        catalogRevision += 1
        refreshJob?.cancel()
        val revision = ++stateRevision
        _uiState.value = SettingsUiState.Loading
        refreshJob = viewModelScope.launch {
            try {
                val loaded = loadSnapshot()
                if (revision == stateRevision) {
                    _uiState.value = loaded
                    resumeModelSyncMonitoring(loaded, revision)
                    loaded.setup?.discovery?.let { discovery ->
                        if (
                            !discovery.state.requiresExplicitRecoveryAction() &&
                            !discovery.requiresExplicitAssistantResumeAction()
                        ) {
                            startDiscoveryMonitoring(revision, discovery.sessionId)
                        }
                    }
                }
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                if (revision == stateRevision) {
                    _uiState.value = SettingsUiState.Error(error)
                }
            }
        }
    }

    fun beginAddConnection() {
        clearPendingCredential()
        updateReady { state ->
            state.copy(
                setup = ProviderSetupState(
                    connectionId = UUID.randomUUID().toString(),
                    preferredAssistantModelRouteId =
                        state.activeSetupAssistantTarget()?.modelRouteId,
                ),
                connectionEditor = null,
                presetEditor = null,
                notice = null,
                error = null,
            )
        }
    }

    fun chooseSetupKind(kind: ProviderSetupKind) {
        updateReady { state ->
            val setup = state.setup ?: return@updateReady state
            setup.takeIf { it.step == ProviderSetupStep.ChooseMethod } ?: return@updateReady state
            state.copy(
                setup = setup.copy(
                    kind = kind,
                    step = ProviderSetupStep.EnterDetails,
                    templateId = null,
                    displayName = when (kind) {
                        ProviderSetupKind.UnknownSite -> "새 Provider"
                        ProviderSetupKind.LocalServer -> "로컬 Provider"
                        ProviderSetupKind.CurlExample -> "cURL Provider"
                        ProviderSetupKind.KnownProvider -> setup.displayName
                    },
                    siteUrl = "",
                    apiOrigin = "",
                    networkMode = when (kind) {
                        ProviderSetupKind.LocalServer -> ProviderNetworkMode.LocalLoopback
                        else -> ProviderNetworkMode.Public
                    },
                    localNetworkOrigin = "",
                    localNetworkAddresses = "",
                    error = null,
                ),
            )
        }
    }

    fun chooseKnownTemplate(templateId: String) {
        updateReady { state ->
            val setup = state.setup ?: return@updateReady state
            val template = state.templates.firstOrNull { it.id == templateId }
                ?: return@updateReady state.copy(error = "선택한 provider를 찾을 수 없습니다.")
            state.copy(
                setup = setup.copy(
                    kind = ProviderSetupKind.KnownProvider,
                    step = ProviderSetupStep.EnterDetails,
                    templateId = template.id,
                    displayName = setup.displayName.ifBlank { template.displayName },
                    apiOrigin = template.defaultApiOrigin.orEmpty(),
                    networkMode = template.defaultNetworkMode,
                    connectionValues = template.connectionFields
                        .filter {
                            it.required && it.valueType == ConnectionFieldType.Boolean
                        }
                        .associate { it.key to "false" },
                    approvedCredentialOrigin = null,
                    error = null,
                ),
                error = null,
            )
        }
    }

    fun updateSetup(setup: ProviderSetupState) {
        updateReady { state ->
            if (state.setup?.connectionId != setup.connectionId) {
                state
            } else {
                state.copy(
                    setup = setup.copy(
                        preferredAssistantModelRouteId =
                            state.setup.preferredAssistantModelRouteId,
                        hasPendingCredential = state.setup.hasPendingCredential,
                        error = null,
                    ),
                    error = null,
                )
            }
        }
    }

    fun submitSetupDetails(
        credential: String,
        rawCurl: String,
    ) {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        val initialSetup = (state.setup ?: return).copy(
            preferredAssistantModelRouteId =
                state.activeSetupAssistantTarget()?.modelRouteId,
        )
        if (state.isBusy || initialSetup.step != ProviderSetupStep.EnterDetails) return
        val template = state.templates.firstOrNull { it.id == initialSetup.templateId }
        val validationError = validateDiscoverySetup(
            setup = initialSetup,
            template = template,
            credentialSupplied = credential.isNotBlank(),
            rawCurlSupplied = rawCurl.isNotBlank(),
        )
        if (validationError != null) {
            _uiState.value = state.copy(
                setup = initialSetup.copy(error = validationError),
                error = validationError,
            )
            return
        }
        replacePendingCredential(
            connectionId = initialSetup.connectionId,
            credential = credential.takeIf(String::isNotBlank)
                .takeUnless { initialSetup.kind == ProviderSetupKind.CurlExample },
        )
        val setup = initialSetup.copy(
            hasPendingCredential = pendingCredential != null,
            step = ProviderSetupStep.Discovering,
            error = null,
        )
        val operationRevision = ++stateRevision
        _uiState.value = state.copy(
            setup = setup,
            busyOperation = BusyOperation.RunningDiscoveryAction,
            notice = null,
            error = null,
        )
        viewModelScope.launch {
            var handedOffCredential: ByteArray? = null
            try {
                val input = setup.toDiscoveryInput(template)
                val snapshot = if (setup.kind == ProviderSetupKind.CurlExample) {
                    val inspection = coreClient.inspectProviderCurl(
                        rawCurl = rawCurl,
                        networkPolicy = ProviderNetworkPolicy(
                            networkMode = setup.networkMode,
                            localNetworkApproval = setup.localNetworkApproval,
                        ),
                    )
                    handedOffCredential = inspection.credentialHandoffId?.let { handoffId ->
                        checkNotNull(coreClient.takeProviderCurlCredential(handoffId)) {
                            "cURL 자격증명 handoff가 만료되었거나 이미 사용되었습니다."
                        }
                    }
                    credentialCoordinator.beginCurlDiscovery(
                        input = input,
                        redactedCurl = inspection.redactedCurl,
                        credential = handedOffCredential,
                    )
                } else {
                    val source = when (setup.kind) {
                        ProviderSetupKind.KnownProvider -> ProviderDiscoverySource.KnownProvider(
                            checkNotNull(setup.templateId),
                        )
                        ProviderSetupKind.UnknownSite,
                        ProviderSetupKind.LocalServer,
                        -> ProviderDiscoverySource.Site
                        ProviderSetupKind.CurlExample,
                        null,
                        -> error("Provider discovery method is missing.")
                    }
                    credentialCoordinator.beginDiscovery(
                        input = input,
                        source = source,
                        rawCurl = null,
                        credential = pendingCredentialString(setup.connectionId),
                    )
                }
                if (operationRevision == stateRevision) {
                    publishDiscoverySnapshot(operationRevision, snapshot)
                    startDiscoveryMonitoring(operationRevision, snapshot.sessionId)
                }
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                publishDiscoveryFailure(operationRevision, error)
            } finally {
                handedOffCredential?.fill(0)
                clearPendingCredential(setup.connectionId)
            }
        }
    }

    fun selectDiscoveryCandidate(candidateId: String) {
        performDiscoveryAction(
            ProviderDiscoveryAction.SelectTemplate(candidateId),
            credentialRequired = false,
        )
    }

    fun handleDiscoveryUiAction(action: ProviderDiscoveryUiAction) {
        when (action) {
            is ProviderDiscoveryUiAction.SelectCandidate ->
                selectDiscoveryCandidate(action.candidateId)
            ProviderDiscoveryUiAction.ContinueWithoutTemplate ->
                continueDiscoveryWithoutTemplate()
            ProviderDiscoveryUiAction.RequestAssistant -> requestDiscoveryAssistant()
            ProviderDiscoveryUiAction.ApproveAssistant -> approveDiscoveryAssistant()
            ProviderDiscoveryUiAction.DeclineAssistant -> declineDiscoveryAssistant()
            ProviderDiscoveryUiAction.RunAssistant -> runDiscoveryAssistant()
            ProviderDiscoveryUiAction.ApproveAssistantRetry ->
                approveDiscoveryAssistantRetry()
            ProviderDiscoveryUiAction.ResumeAssistantCoreHostAction ->
                resumeDiscoveryAssistantCoreHostAction()
            ProviderDiscoveryUiAction.ApproveProbes -> approveDiscoveryProbes()
            ProviderDiscoveryUiAction.SkipProbes -> skipDiscoveryProbes()
            ProviderDiscoveryUiAction.AcceptAssistantDraft ->
                acceptDiscoveryAssistantDraft()
            is ProviderDiscoveryUiAction.SupplyDocument ->
                supplyDiscoveryDocumentEvidence(action.url)
            is ProviderDiscoveryUiAction.SupplyCurl ->
                supplyDiscoveryCurlEvidence(action.rawCurl)
            ProviderDiscoveryUiAction.RestartInterrupted ->
                restartInterruptedDiscovery()
            ProviderDiscoveryUiAction.ResumeCompensation ->
                resumeDiscoveryCompensation()
            is ProviderDiscoveryUiAction.ResolveUnknownOutcome ->
                resolveDiscoveryUnknownOutcome(action.resolution)
        }
    }

    fun continueDiscoveryWithoutTemplate() {
        performDiscoveryAction(
            ProviderDiscoveryAction.ContinueWithoutTemplate,
            credentialRequired = false,
        )
    }

    fun approveCredentialOrigin() {
        val snapshot = currentDiscoverySnapshot() ?: return
        val proposal = snapshot.approvalProposal ?: return
        if (
            snapshot.actionRequired !is DiscoveryActionRequired.ApproveCredentialOrigin ||
            proposal.grant !is DiscoveryApprovalGrant.CredentialOrigin
        ) {
            return
        }
        performDiscoveryAction(
            ProviderDiscoveryAction.ApproveCredentialOrigin(proposal.approvalId),
            credentialRequired = true,
        )
    }

    fun requestDiscoveryAssistant() {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        val setup = state.setup ?: return
        if (!ensureCurrentSetupAssistantTarget(state, setup.preferredAssistantModelRouteId)) {
            return
        }
        performDiscoveryAction(
            ProviderDiscoveryAction.RequestAssistant,
            credentialRequired = false,
        )
    }

    fun approveDiscoveryAssistant() {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        val setup = state.setup ?: return
        val snapshot = setup.discovery ?: return
        val proposal = snapshot.approvalProposal ?: return
        val grant = proposal.grant as? DiscoveryApprovalGrant.AssistantConsent ?: return
        if (
            setup.preferredAssistantModelRouteId != grant.assistantModelRouteId ||
            !ensureCurrentSetupAssistantTarget(state, grant.assistantModelRouteId)
        ) {
            return
        }
        performDiscoveryAction(
            action = ProviderDiscoveryAction.ApproveAssistant(
                approvalId = proposal.approvalId,
                approvalGrantSha256 = proposal.grantSha256,
            ),
            credentialRequired = false,
            afterContinue = { continued ->
                runApprovedAssistantTurn(state, continued, grant)
            },
        )
    }

    fun declineDiscoveryAssistant() {
        performDiscoveryAction(
            ProviderDiscoveryAction.DeclineAssistant,
            credentialRequired = false,
        )
    }

    fun runDiscoveryAssistant() {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        val setup = state.setup ?: return
        val snapshot = setup.discovery ?: return
        if (
            snapshot.assistantResumeBoundary?.action !=
            DiscoveryAssistantResumeAction.RunAssistant
        ) {
            return
        }
        val grant = snapshot.approvals
            .asReversed()
            .firstNotNullOfOrNull { approval ->
                approval.grant as? DiscoveryApprovalGrant.AssistantConsent
            } ?: return
        if (
            setup.preferredAssistantModelRouteId != grant.assistantModelRouteId ||
            !ensureCurrentSetupAssistantTarget(state, grant.assistantModelRouteId)
        ) {
            return
        }
        performDirectDiscoveryMutation { current ->
            check(
                current.assistantResumeBoundary?.action ==
                    DiscoveryAssistantResumeAction.RunAssistant,
            ) {
                "Setup assistant resume boundary changed before the approved call."
            }
            runApprovedAssistantTurn(state, current, grant)
        }
    }

    fun approveDiscoveryAssistantRetry() {
        val snapshot = currentDiscoverySnapshot() ?: return
        if (
            snapshot.assistantResumeBoundary?.action !=
            DiscoveryAssistantResumeAction.ApproveRetry
        ) {
            return
        }
        performDirectDiscoveryMutation { current ->
            coreClient.approveProviderDiscoveryAssistantRetry(current.sessionId)
        }
    }

    fun resumeDiscoveryAssistantCoreHostAction() {
        val snapshot = currentDiscoverySnapshot() ?: return
        if (
            snapshot.assistantResumeBoundary?.action !=
            DiscoveryAssistantResumeAction.ResumeCoreHostAction
        ) {
            return
        }
        performDirectDiscoveryMutation { current ->
            check(
                current.assistantResumeBoundary?.action ==
                    DiscoveryAssistantResumeAction.ResumeCoreHostAction,
            ) {
                "Setup assistant Core-host action boundary changed before resume."
            }
            coreClient.resumeProviderDiscoveryAssistantCoreHostAction(current.sessionId)
        }
    }

    fun approveDiscoveryProbes() {
        val snapshot = currentDiscoverySnapshot() ?: return
        val proposal = snapshot.approvalProposal ?: return
        if (proposal.grant !is DiscoveryApprovalGrant.CapabilityProbe) return
        performDiscoveryAction(
            ProviderDiscoveryAction.ApproveProbes(
                approvalId = proposal.approvalId,
                approvalGrantSha256 = proposal.grantSha256,
            ),
            credentialRequired = snapshot.credentialSlotExpected,
        )
    }

    fun skipDiscoveryProbes() {
        performDiscoveryAction(
            ProviderDiscoveryAction.SkipProbes,
            credentialRequired = false,
        )
    }

    fun acceptDiscoveryAssistantDraft() {
        performDirectDiscoveryMutation { snapshot ->
            coreClient.acceptProviderDiscoveryAssistantDraft(snapshot.sessionId)
        }
    }

    fun supplyDiscoveryDocumentEvidence(documentUrl: String) {
        if (documentUrl.isBlank()) return
        performDirectDiscoveryMutation { snapshot ->
            coreClient.supplyProviderDiscoveryDocumentEvidence(
                sessionId = snapshot.sessionId,
                expectedRevision = snapshot.revision,
                documentUrl = documentUrl.trim(),
            )
        }
    }

    fun supplyDiscoveryCurlEvidence(rawCurl: String) {
        if (rawCurl.isBlank()) return
        performDirectDiscoveryMutation { snapshot ->
            credentialCoordinator.supplyCurlEvidence(
                snapshot = snapshot,
                rawCurl = rawCurl,
                networkPolicy = ProviderNetworkPolicy(
                    networkMode = snapshot.connectionOptions.networkMode,
                    localNetworkApproval = snapshot.connectionOptions.localNetworkApproval,
                ),
            )
        }
    }

    fun restartInterruptedDiscovery() {
        performDiscoveryAction(
            ProviderDiscoveryAction.RestartInterrupted,
            credentialRequired = currentDiscoverySnapshot()?.credentialSlotExpected == true,
        )
    }

    fun resumeDiscoveryCompensation() {
        performDirectDiscoveryMutation { snapshot ->
            credentialCoordinator.resumeDiscoveryCompensation(snapshot)
        }
    }

    fun resolveDiscoveryUnknownOutcome(
        resolution: DiscoveryUnknownOutcomeResolution,
    ) {
        val snapshot = currentDiscoverySnapshot() ?: return
        val proposal = snapshot.approvalProposal ?: return
        if (proposal.grant !is DiscoveryApprovalGrant.UnknownOutcomeResolution) return
        performDiscoveryAction(
            ProviderDiscoveryAction.ResolveUnknownOutcome(
                approvalId = proposal.approvalId,
                resolution = resolution,
            ),
            credentialRequired = false,
        )
    }

    fun commitSetup() {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        val setup = state.setup ?: return
        val snapshot = setup.discovery ?: return
        val proposal = snapshot.reviewProposal ?: return
        if (
            state.isBusy ||
            snapshot.actionRequired !is DiscoveryActionRequired.Review ||
            !proposal.requestPreview.isSafeDiscoveryPreview()
        ) {
            if (!proposal.requestPreview.isSafeDiscoveryPreview()) {
                _uiState.value = state.copy(
                    error = "Core가 안전하게 redaction한 요청 미리보기를 제공하지 않았습니다.",
                )
            }
            return
        }
        val operationRevision = ++stateRevision
        _uiState.value = state.copy(
            setup = setup.copy(step = ProviderSetupStep.Committing),
            busyOperation = BusyOperation.SavingConnection,
            notice = null,
            error = null,
        )
        viewModelScope.launch {
            var mutationCompleted = false
            try {
                val action = ProviderDiscoveryAction.ApproveReview(
                    approvalId = proposal.approval.approvalId,
                    commitAttemptId = proposal.commitAttemptId,
                    commitPlanSha256 = proposal.commitPlanSha256,
                    graphSha256 = proposal.review.graphSha256,
                )
                val envelope = coreClient.prepareProviderDiscoveryAction(
                    actionId = UUID.randomUUID().toString(),
                    expectedRevision = snapshot.revision,
                    action = action,
                )
                val committing = credentialCoordinator.continueDiscovery(
                    snapshot = snapshot,
                    envelope = envelope,
                    credentialRequired = false,
                )
                check(committing.state == "committing") {
                    "Core did not enter the reviewed provider commit state."
                }
                val saved = credentialCoordinator.commitDiscovery(committing)
                mutationCompleted = true
                val loaded = loadSnapshot(
                    notice = "${saved.displayName} 연결을 저장했습니다. 모델 동기화를 실행해 주세요.",
                )
                if (operationRevision == stateRevision) {
                    _uiState.value = loaded
                }
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                val durable = runCatching {
                    coreClient.getProviderDiscovery(snapshot.sessionId)
                }.getOrNull()
                val reconciled = durable?.let {
                    runCatching { reconcileDiscoverySnapshot(it) }.getOrDefault(it)
                }
                if (mutationCompleted) {
                    publishPostMutationReloadFailure(
                        operationRevision,
                        "Provider discovery commit",
                        error,
                    )
                } else if (reconciled != null) {
                    publishDiscoverySnapshot(
                        operationRevision,
                        reconciled,
                        error.userFacingMessage(),
                    )
                } else {
                    publishDiscoveryFailure(operationRevision, error)
                }
            }
        }
    }

    fun cancelSetup() {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        val setup = state.setup ?: return
        val snapshot = setup.discovery
        clearPendingCredential()
        if (snapshot == null) {
            _uiState.value = state.copy(setup = null, notice = null, error = null)
            return
        }
        if (state.isBusy) return
        val operationRevision = ++stateRevision
        _uiState.value = state.copy(
            busyOperation = BusyOperation.CancellingDiscovery,
            notice = null,
            error = null,
        )
        viewModelScope.launch {
            try {
                val cancelled = credentialCoordinator.cancelDiscovery(snapshot)
                publishDiscoverySnapshot(operationRevision, cancelled)
                startDiscoveryMonitoring(operationRevision, cancelled.sessionId)
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                publishDiscoveryFailure(operationRevision, error)
            }
        }
    }

    fun retrySetup() {
        clearPendingCredential()
        updateReady { state ->
            val setup = state.setup ?: return@updateReady state
            state.copy(
                setup = setup.copy(
                    connectionId = UUID.randomUUID().toString(),
                    preferredAssistantModelRouteId =
                        state.activeSetupAssistantTarget()?.modelRouteId,
                    step = ProviderSetupStep.EnterDetails,
                    progress = null,
                    review = null,
                    discovery = null,
                    approvedCredentialOrigin = null,
                    hasPendingCredential = false,
                    error = null,
                ),
                error = null,
            )
        }
    }

    private fun performDiscoveryAction(
        action: ProviderDiscoveryAction,
        credentialRequired: Boolean,
        afterContinue: suspend (ProviderDiscoverySnapshot) -> ProviderDiscoverySnapshot = {
            it
        },
    ) {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        val setup = state.setup ?: return
        val snapshot = setup.discovery ?: return
        if (state.isBusy || snapshot.state.isDiscoveryTerminal()) return
        discoveryMonitorJob?.cancel()
        val operationRevision = ++stateRevision
        _uiState.value = state.copy(
            busyOperation = BusyOperation.RunningDiscoveryAction,
            notice = null,
            error = null,
        )
        viewModelScope.launch {
            try {
                val envelope = coreClient.prepareProviderDiscoveryAction(
                    actionId = UUID.randomUUID().toString(),
                    expectedRevision = snapshot.revision,
                    action = action,
                )
                val continued = credentialCoordinator.continueDiscovery(
                    snapshot = snapshot,
                    envelope = envelope,
                    credentialRequired = credentialRequired,
                )
                val result = reconcileDiscoverySnapshot(afterContinue(continued))
                publishDiscoverySnapshot(operationRevision, result)
                startDiscoveryMonitoring(operationRevision, result.sessionId)
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                reconcileDiscoveryOperationFailure(
                    operationRevision,
                    snapshot.sessionId,
                    error,
                )
            }
        }
    }

    private fun performDirectDiscoveryMutation(
        mutation: suspend (ProviderDiscoverySnapshot) -> ProviderDiscoverySnapshot,
    ) {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        val snapshot = state.setup?.discovery ?: return
        if (state.isBusy || snapshot.state.isDiscoveryTerminal()) return
        discoveryMonitorJob?.cancel()
        val operationRevision = ++stateRevision
        _uiState.value = state.copy(
            busyOperation = BusyOperation.RunningDiscoveryAction,
            notice = null,
            error = null,
        )
        viewModelScope.launch {
            try {
                val result = reconcileDiscoverySnapshot(mutation(snapshot))
                publishDiscoverySnapshot(operationRevision, result)
                startDiscoveryMonitoring(operationRevision, result.sessionId)
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                reconcileDiscoveryOperationFailure(
                    operationRevision,
                    snapshot.sessionId,
                    error,
                )
            }
        }
    }

    private suspend fun reconcileDiscoveryOperationFailure(
        expectedRevision: Long,
        sessionId: String,
        error: Throwable,
    ) {
        val durable = runCatching { coreClient.getProviderDiscovery(sessionId) }.getOrNull()
        if (durable == null) {
            publishDiscoveryFailure(expectedRevision, error)
            return
        }
        val reconciled = runCatching {
            reconcileDiscoverySnapshot(durable)
        }.getOrDefault(durable)
        publishDiscoverySnapshot(expectedRevision, reconciled, error.userFacingMessage())
        startDiscoveryMonitoring(expectedRevision, reconciled.sessionId)
    }

    private fun publishDiscoverySnapshot(
        expectedRevision: Long,
        snapshot: ProviderDiscoverySnapshot,
        transientError: String? = null,
    ) {
        if (expectedRevision != stateRevision) return
        val latest = _uiState.value as? SettingsUiState.Ready ?: return
        val current = latest.setup
        if (
            current != null &&
            current.discovery != null &&
            current.discovery.sessionId != snapshot.sessionId
        ) {
            return
        }
        val setup = current?.takeIf {
            it.connectionId == snapshot.pendingConnectionId
        } ?: ProviderSetupState(
            connectionId = snapshot.pendingConnectionId,
            displayName = snapshot.pendingDisplayName,
        )
        val errorMessage = transientError ?: snapshot.failure?.messageKey
        _uiState.value = latest.copy(
            setup = setup.copy(
                connectionId = snapshot.pendingConnectionId,
                displayName = snapshot.pendingDisplayName,
                preferredAssistantModelRouteId =
                    snapshot.durableAssistantModelRouteId()
                        ?: setup.preferredAssistantModelRouteId,
                apiBasePath = snapshot.connectionOptions.apiBasePath.orEmpty(),
                networkMode = snapshot.connectionOptions.networkMode,
                localNetworkOrigin = snapshot.connectionOptions.localNetworkApproval
                    ?.origin
                    .orEmpty(),
                localNetworkAddresses = snapshot.connectionOptions.localNetworkApproval
                    ?.addresses
                    .orEmpty()
                    .joinToString("\n"),
                timeoutSeconds = snapshot.connectionOptions.timeoutSeconds.toString(),
                step = snapshot.toSetupStep(),
                progress = snapshot.toUiProgress(),
                discovery = snapshot,
                assistantOutcome = snapshot.toAssistantOutcome(),
                hasPendingCredential = false,
                error = errorMessage,
            ),
            busyOperation = null,
            notice = null,
            error = errorMessage,
        )
    }

    private fun publishDiscoveryFailure(
        expectedRevision: Long,
        error: Throwable,
    ) {
        if (expectedRevision != stateRevision) return
        val latest = _uiState.value as? SettingsUiState.Ready ?: return
        val message = error.userFacingMessage()
        _uiState.value = latest.copy(
            setup = latest.setup?.copy(
                step = ProviderSetupStep.Failed,
                hasPendingCredential = false,
                error = message,
            ),
            busyOperation = null,
            notice = null,
            error = message,
        )
    }

    private fun startDiscoveryMonitoring(
        expectedRevision: Long,
        sessionId: String,
    ) {
        val snapshot = currentDiscoverySnapshot()
        if (
            snapshot?.sessionId != sessionId ||
            snapshot.state.isDiscoveryTerminal() ||
            snapshot.state.requiresExplicitRecoveryAction() ||
            snapshot.requiresExplicitAssistantResumeAction() ||
            snapshot.actionRequired != null
        ) {
            return
        }
        discoveryMonitorJob?.cancel()
        discoveryMonitorJob = viewModelScope.launch {
            try {
                while (expectedRevision == stateRevision) {
                    val events = coreClient.pollProviderDiscoveryEvents(
                        DISCOVERY_EVENT_BATCH_LIMIT,
                    )
                    if (events.any { it.event.eventVersion != DISCOVERY_EVENT_VERSION }) {
                        throw IllegalStateException(
                            "이 Android 빌드가 지원하지 않는 discovery event 버전입니다.",
                        )
                    }
                    var activeSnapshot: ProviderDiscoverySnapshot? = null
                    for (outbox in events) {
                        val durable = reconcileDiscoverySnapshot(
                            coreClient.getProviderDiscovery(outbox.event.sessionId),
                        )
                        if (durable.sessionId == sessionId) {
                            activeSnapshot = durable
                        }
                        coreClient.ackProviderDiscoveryEvent(outbox.event.eventId)
                    }
                    val durable = activeSnapshot
                        ?: reconcileDiscoverySnapshot(
                            coreClient.getProviderDiscovery(sessionId),
                        )
                    publishDiscoverySnapshot(expectedRevision, durable)
                    if (
                        durable.state.isDiscoveryTerminal() ||
                        durable.actionRequired != null
                    ) {
                        break
                    }
                    delay(DISCOVERY_POLL_INTERVAL_MILLIS)
                }
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                val durable = runCatching {
                    coreClient.getProviderDiscovery(sessionId)
                }.getOrNull()
                if (durable != null) {
                    val reconciled = runCatching {
                        reconcileDiscoverySnapshot(durable)
                    }.getOrDefault(durable)
                    publishDiscoverySnapshot(
                        expectedRevision,
                        reconciled,
                        "자동 탐색 상태 모니터링이 중단되었습니다. 새로고침해 복구할 수 있습니다. " +
                            "(${error.userFacingMessage()})",
                    )
                } else {
                    publishDiscoveryFailure(expectedRevision, error)
                }
            }
        }
    }

    private fun currentDiscoverySnapshot(): ProviderDiscoverySnapshot? =
        (_uiState.value as? SettingsUiState.Ready)?.setup?.discovery

    private suspend fun reconcileDiscoverySnapshot(
        snapshot: ProviderDiscoverySnapshot,
    ): ProviderDiscoverySnapshot {
        if (snapshot.state == "compensating" && snapshot.failure == null) {
            return credentialCoordinator.reconcileDiscoveryCompensation(snapshot)
        }
        credentialCoordinator.reconcileDiscoveryCredential(snapshot)
        return snapshot
    }

    private suspend fun assistantCredentialForRoute(
        state: SettingsUiState.Ready,
        modelRouteId: String,
    ): String? {
        val connection = state.connections.firstNotNullOfOrNull { details ->
            details.takeIf { candidate ->
                candidate.routes.any { it.route.id == modelRouteId }
            }?.connection
        } ?: error("선택한 setup assistant model route를 찾을 수 없습니다.")
        val credentialRef = connection.validatedCredentialRefForRead() ?: return null
        check(credentialStore.inspect(credentialRef) == CredentialRecordStatus.Available) {
            "Setup assistant provider 자격증명이 없거나 복호화할 수 없습니다."
        }
        return checkNotNull(credentialStore.read(credentialRef)) {
            "Setup assistant provider 자격증명이 요청 직전에 사라졌습니다."
        }
    }

    private fun ensureCurrentSetupAssistantTarget(
        state: SettingsUiState.Ready,
        expectedModelRouteId: String?,
    ): Boolean {
        val current = state.activeSetupAssistantTarget()
        if (
            expectedModelRouteId != null &&
            current?.modelRouteId == expectedModelRouteId
        ) {
            return true
        }
        val message = if (expectedModelRouteId == null) {
            "탐색 시작 시 실행 가능한 setup assistant 모델과 preset이 선택되지 않았습니다. " +
                "이 탐색을 취소하고 사용할 모델과 preset을 선택한 뒤 다시 시작해 주세요."
        } else {
            "탐색 시작 때 고정한 setup assistant 모델과 현재 선택한 모델/preset이 " +
                "일치하지 않거나 더 이상 사용할 수 없습니다. 원래 선택을 복구하거나 " +
                "이 탐색을 취소한 뒤 다시 시작해 주세요."
        }
        _uiState.value = state.copy(
            setup = state.setup?.copy(error = message),
            notice = null,
            error = message,
        )
        return false
    }

    private suspend fun runApprovedAssistantTurn(
        state: SettingsUiState.Ready,
        snapshot: ProviderDiscoverySnapshot,
        grant: DiscoveryApprovalGrant.AssistantConsent,
    ): ProviderDiscoverySnapshot {
        val credential = assistantCredentialForRoute(
            state = state,
            modelRouteId = grant.assistantModelRouteId,
        )
        coreClient.runProviderDiscoveryAssistantTurn(
            sessionId = snapshot.sessionId,
            estimate = DiscoveryAssistantCallEstimate(
                inputTokens = grant.maxInputTokens.toULong(),
                maximumOutputTokens = grant.maxOutputTokens.toULong(),
                maximumCostMicroUnits = grant.maxCostMicroUnits,
            ),
            assistantCredential = credential,
        )
        return coreClient.getProviderDiscovery(snapshot.sessionId).also {
            check(it.assistantResumeBoundary != null) {
                "Core omitted the typed setup assistant resume boundary."
            }
        }
    }

    fun prepareCatalogImport(documentBytes: ByteArray) {
        val state = _uiState.value as? SettingsUiState.Ready ?: run {
            documentBytes.fill(0)
            return
        }
        val catalog = state.catalog as? ProviderCatalogUiState.Ready ?: run {
            documentBytes.fill(0)
            return
        }
        if (
            state.isBusy ||
            catalog.isBusy ||
            catalog.pendingReview != null ||
            documentBytes.isEmpty() ||
            documentBytes.size.toLong() > PROVIDER_CATALOG_MAX_DOCUMENT_BYTES
        ) {
            documentBytes.fill(0)
            val message = if (documentBytes.isEmpty()) {
                "빈 catalog 문서는 가져올 수 없습니다."
            } else {
                "Catalog 문서는 최대 2 MiB여야 하며 다른 검토와 동시에 준비할 수 없습니다."
            }
            _uiState.value = state.copy(catalog = catalog.copy(error = message))
            return
        }
        clearPendingCatalogMutation()
        val ownedBytes = documentBytes.copyOf()
        documentBytes.fill(0)
        val revision = ++catalogRevision
        _uiState.value = state.copy(
            catalog = catalog.copy(
                busyOperation = ProviderCatalogBusyOperation.PreparingImport,
                notice = null,
                error = null,
            ),
        )
        viewModelScope.launch {
            try {
                val plan = coreClient.prepareSignedProviderCatalogImport(ownedBytes)
                if (revision != catalogRevision) {
                    ownedBytes.fill(0)
                    return@launch
                }
                pendingCatalogImportBytes = ownedBytes
                pendingCatalogImportPlan = plan
                val latest = _uiState.value as? SettingsUiState.Ready ?: run {
                    clearPendingCatalogMutation()
                    return@launch
                }
                val latestCatalog = latest.catalog as? ProviderCatalogUiState.Ready ?: run {
                    clearPendingCatalogMutation()
                    return@launch
                }
                _uiState.value = latest.copy(
                    catalog = latestCatalog.copy(
                        pendingReview = plan.toUiReview(),
                        busyOperation = null,
                        notice = null,
                        error = null,
                    ),
                )
            } catch (cancellation: CancellationException) {
                ownedBytes.fill(0)
                throw cancellation
            } catch (error: Throwable) {
                ownedBytes.fill(0)
                publishCatalogOperationFailure(revision, error)
            }
        }
    }

    fun activateCatalogImport() {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        val catalog = state.catalog as? ProviderCatalogUiState.Ready ?: return
        val plan = pendingCatalogImportPlan ?: return
        val bytes = pendingCatalogImportBytes ?: return
        val review = catalog.pendingReview as? ProviderCatalogPendingReview.Import ?: return
        if (
            state.isBusy ||
            catalog.isBusy ||
            review.actionId != plan.review.actionId ||
            review.planSha256 != plan.planSha256
        ) {
            return
        }
        val revision = ++catalogRevision
        _uiState.value = state.copy(
            catalog = catalog.copy(
                busyOperation = ProviderCatalogBusyOperation.ActivatingImport,
                notice = null,
                error = null,
            ),
        )
        viewModelScope.launch {
            try {
                val result = coreClient.activateSignedProviderCatalogImport(plan, bytes)
                clearPendingCatalogMutation()
                reloadCatalogState(
                    expectedRevision = revision,
                    notice = "서명 catalog revision ${result.activatedRevision}을 활성화했습니다.",
                )
            } catch (cancellation: CancellationException) {
                clearPendingCatalogMutation()
                throw cancellation
            } catch (error: Throwable) {
                clearPendingCatalogMutation()
                publishCatalogOperationFailure(
                    revision,
                    IllegalStateException(
                        "Catalog 활성화 결과를 자동 재시도하지 않습니다. 새로고침 후 다시 검토해 주세요.",
                        error,
                    ),
                    clearReview = true,
                )
            }
        }
    }

    fun cancelCatalogImport() {
        clearPendingCatalogMutation()
        val revision = ++catalogRevision
        updateCatalogState { catalog ->
            catalog.copy(
                pendingReview = null,
                busyOperation = null,
                notice = "서명 catalog 가져오기 검토를 취소했습니다.",
                error = null,
            )
        }
        check(revision == catalogRevision)
    }

    fun prepareCatalogRollback(targetRevision: ULong) {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        val catalog = state.catalog as? ProviderCatalogUiState.Ready ?: return
        if (state.isBusy || catalog.isBusy || catalog.pendingReview != null) return
        clearPendingCatalogMutation()
        val revision = ++catalogRevision
        _uiState.value = state.copy(
            catalog = catalog.copy(
                busyOperation = ProviderCatalogBusyOperation.PreparingRollback,
                notice = null,
                error = null,
            ),
        )
        viewModelScope.launch {
            try {
                val plan = coreClient.prepareProviderCatalogRollback(targetRevision)
                if (revision != catalogRevision) return@launch
                pendingCatalogRollbackPlan = plan
                updateCatalogState { latest ->
                    latest.copy(
                        pendingReview = plan.toUiReview(),
                        busyOperation = null,
                        notice = null,
                        error = null,
                    )
                }
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                publishCatalogOperationFailure(revision, error)
            }
        }
    }

    fun activateCatalogRollback() {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        val catalog = state.catalog as? ProviderCatalogUiState.Ready ?: return
        val plan = pendingCatalogRollbackPlan ?: return
        val review = catalog.pendingReview as? ProviderCatalogPendingReview.Rollback ?: return
        if (
            state.isBusy ||
            catalog.isBusy ||
            review.actionId != plan.actionId ||
            review.planSha256 != plan.planSha256
        ) {
            return
        }
        val revision = ++catalogRevision
        _uiState.value = state.copy(
            catalog = catalog.copy(
                busyOperation = ProviderCatalogBusyOperation.ActivatingRollback,
                notice = null,
                error = null,
            ),
        )
        viewModelScope.launch {
            try {
                val result = coreClient.activateProviderCatalogRollback(plan)
                clearPendingCatalogMutation()
                reloadCatalogState(
                    expectedRevision = revision,
                    notice = "Provider catalog를 revision ${result.activatedRevision}로 되돌렸습니다.",
                )
            } catch (cancellation: CancellationException) {
                clearPendingCatalogMutation()
                throw cancellation
            } catch (error: Throwable) {
                clearPendingCatalogMutation()
                publishCatalogOperationFailure(
                    revision,
                    IllegalStateException(
                        "Rollback 결과를 자동 재시도하지 않습니다. 새로고침해 현재 revision을 확인하세요.",
                        error,
                    ),
                    clearReview = true,
                )
            }
        }
    }

    fun cancelCatalogRollback() {
        pendingCatalogRollbackPlan = null
        catalogRevision += 1
        updateCatalogState { catalog ->
            catalog.copy(
                pendingReview = null,
                busyOperation = null,
                notice = "Catalog rollback 검토를 취소했습니다.",
                error = null,
            )
        }
    }

    fun refreshCatalog() {
        clearPendingCatalogMutation()
        val revision = ++catalogRevision
        updateCatalogState { catalog ->
            catalog.copy(
                pendingReview = null,
                busyOperation = ProviderCatalogBusyOperation.Refreshing,
                notice = null,
                error = null,
            )
        }
        viewModelScope.launch {
            try {
                reloadCatalogState(revision, notice = null)
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                publishCatalogOperationFailure(revision, error)
            }
        }
    }

    fun reportCatalogDocumentError(message: String) {
        updateCatalogState { catalog ->
            catalog.copy(error = message, notice = null)
        }
    }

    fun beginEditConnection(connectionId: String) {
        updateReady { state ->
            val connection = state.connections.firstOrNull {
                it.connection.id == connectionId
            }?.connection ?: return@updateReady state
            state.copy(
                setup = null,
                presetEditor = null,
                connectionEditor = ConnectionEditor(connection),
                notice = null,
                error = null,
            )
        }
    }

    fun updateConnectionEditor(editor: ConnectionEditor) {
        updateReady { state ->
            if (state.connectionEditor?.original?.id == editor.original.id) {
                state.copy(connectionEditor = editor, notice = null, error = null)
            } else {
                state
            }
        }
    }

    fun cancelConnectionEditor() {
        updateReady { it.copy(connectionEditor = null, notice = null, error = null) }
    }

    fun saveConnectionEditor(replacementCredential: String) {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        val editor = state.connectionEditor ?: return
        if (state.isBusy) return
        val details = state.connections.firstOrNull {
            it.connection.id == editor.original.id
        } ?: return
        if (replacementCredential.isNotBlank()) {
            _uiState.value = state.copy(
                error = EXISTING_CONNECTION_CREDENTIAL_REPLACEMENT_MESSAGE,
            )
            return
        }
        if (editor.hasImmutableConnectionChanges(details.connection)) {
            _uiState.value = state.copy(
                error = EXISTING_CONNECTION_CONFIGURATION_CHANGE_MESSAGE,
            )
            return
        }
        val updated = editor.toConnection(details.connection) ?: run {
            _uiState.value = state.copy(error = "연결 입력값을 확인해 주세요.")
            return
        }
        val operationRevision = ++stateRevision
        _uiState.value = state.copy(
            busyOperation = BusyOperation.SavingConnection,
            notice = null,
            error = null,
        )
        viewModelScope.launch {
            var mutationCompleted = false
            try {
                credentialCoordinator.updateConnection(
                    original = details.connection,
                    updated = updated,
                    replacementCredential = null,
                )
                mutationCompleted = true
                val loaded = loadSnapshot(notice = "연결 설정을 저장했습니다.")
                if (operationRevision == stateRevision) {
                    _uiState.value = loaded
                }
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                if (mutationCompleted) {
                    publishPostMutationReloadFailure(
                        operationRevision,
                        "Provider 연결 변경",
                        error,
                    )
                } else {
                    restoreOperationError(operationRevision, error)
                }
            }
        }
    }

    fun deleteConnection(connectionId: String) {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        if (state.isBusy) return
        state.connections.firstOrNull {
            it.connection.id == connectionId
        } ?: return
        val operationRevision = ++stateRevision
        _uiState.value = state.copy(
            busyOperation = BusyOperation.DeletingConnection,
            notice = null,
            error = null,
        )
        viewModelScope.launch {
            var mutationCompleted = false
            try {
                val outcome = PROCESS_MODEL_SYNC_START_MUTEX.withLock {
                    val latestConnections = boundedSnapshotRead {
                        coreClient.listProviderConnections()
                    }
                    val latestConnection = latestConnections.firstOrNull {
                        it.id == connectionId
                    } ?: error("삭제할 provider 연결이 더 이상 존재하지 않습니다.")
                    val activeJobs = loadActiveModelSyncJobs(latestConnections)
                    if (activeJobs.any { it.connectionId == connectionId }) {
                        ConnectionDeleteOutcome.Blocked(
                            modelSync = activeJobs.toModelSyncUiState(),
                        )
                    } else {
                        credentialCoordinator.deleteConnection(latestConnection)
                        ConnectionDeleteOutcome.Deleted
                    }
                }
                if (outcome is ConnectionDeleteOutcome.Blocked) {
                    if (operationRevision == stateRevision) {
                        val latest = _uiState.value as? SettingsUiState.Ready
                            ?: return@launch
                        val restored = latest.copy(
                            modelSync = outcome.modelSync,
                            busyOperation = if (
                                outcome.modelSync is ModelSyncUiState.Running
                            ) {
                                BusyOperation.SynchronizingModels
                            } else {
                                null
                            },
                            notice = null,
                            error = "이 연결에는 종료되지 않은 모델 동기화가 있습니다. " +
                                "중단 작업을 취소하거나 검토를 완료한 뒤 삭제해 주세요.",
                        )
                        _uiState.value = restored
                        modelSyncJob = null
                        resumeModelSyncMonitoring(restored, operationRevision)
                    }
                    return@launch
                }
                mutationCompleted = outcome is ConnectionDeleteOutcome.Deleted
                val loaded = loadSnapshot(notice = "연결과 Keystore 자격증명을 삭제했습니다.")
                if (operationRevision == stateRevision) {
                    _uiState.value = loaded
                }
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                if (mutationCompleted) {
                    publishPostMutationReloadFailure(
                        operationRevision,
                        "Provider 연결 삭제",
                        error,
                    )
                } else {
                    restoreOperationError(operationRevision, error)
                }
            }
        }
    }

    fun selectGenerationPreset(modelRouteId: String, generationPresetId: String) {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        if (state.isBusy) return
        val route = state.connections
            .asSequence()
            .flatMap { it.routes.asSequence() }
            .firstOrNull { it.route.id == modelRouteId }
            ?: return
        if (route.presets.none { it.id == generationPresetId }) return
        val operationRevision = ++stateRevision
        _uiState.value = state.copy(
            busyOperation = BusyOperation.SelectingModel,
            notice = null,
            error = null,
        )
        viewModelScope.launch {
            try {
                val settings = PROCESS_SETTINGS_SELECTION_MUTEX.withLock {
                    coreClient.selectGenerationTarget(
                        GenerationTarget(modelRouteId, generationPresetId),
                    )
                }
                if (operationRevision == stateRevision) {
                    val latest = _uiState.value as? SettingsUiState.Ready ?: return@launch
                    val stillExists = latest.connections
                        .asSequence()
                        .flatMap { it.routes.asSequence() }
                        .filter { it.route.id == modelRouteId }
                        .flatMap { it.presets.asSequence() }
                        .any { it.id == generationPresetId }
                    _uiState.value = if (stillExists) {
                        val updated = latest.copy(settings = settings)
                        updated.copy(
                            setup = updated.setup?.let { setup ->
                                if (setup.discovery == null) {
                                    setup.copy(
                                        preferredAssistantModelRouteId =
                                            updated.activeSetupAssistantTarget()?.modelRouteId,
                                    )
                                } else {
                                    setup
                                }
                            },
                            busyOperation = null,
                            notice = "사용할 모델과 preset을 선택했습니다.",
                            error = null,
                        )
                    } else {
                        latest.copy(
                            busyOperation = null,
                            error = "선택한 preset이 더 이상 존재하지 않습니다.",
                        )
                    }
                }
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                restoreOperationError(operationRevision, error)
            }
        }
    }

    fun beginAddPreset(modelRouteId: String) {
        updateReady { state ->
            val details = state.connections.firstNotNullOfOrNull { connection ->
                connection.routes.firstOrNull { it.route.id == modelRouteId }
                    ?.let { route -> connection to route }
            } ?: return@updateReady state
            state.copy(
                setup = null,
                connectionEditor = null,
                presetEditor = normalizePresetEditor(
                    PresetEditor(
                        id = UUID.randomUUID().toString(),
                        modelRouteId = modelRouteId,
                        displayName = "기본 설정",
                        parameterSpecs = details.second.parameterSpecs,
                        explicitValues = emptyMap(),
                    ),
                ),
                presetReview = null,
                notice = null,
                error = null,
            )
        }
        refreshPresetControls()
    }

    fun beginEditPreset(generationPresetId: String) {
        updateReady { state ->
            val details = state.connections.firstNotNullOfOrNull { connection ->
                connection.routes.firstNotNullOfOrNull { route ->
                    route.presets.firstOrNull { it.id == generationPresetId }
                        ?.let { preset -> Triple(connection, route, preset) }
                }
            } ?: return@updateReady state
            val preset = details.third
            state.copy(
                setup = null,
                connectionEditor = null,
                presetEditor = normalizePresetEditor(
                    PresetEditor(
                        id = preset.id,
                        modelRouteId = preset.modelRouteId,
                        displayName = preset.displayName,
                        parameterSpecs = details.second.parameterSpecs,
                        explicitValues = preset.values.mapNotNull { value ->
                            (value.state as? ParameterValueState.Explicit)?.value?.let {
                                value.parameterId to it
                            }
                        }.toMap(),
                        reasoningMode = preset.reasoningMode,
                        reasoningEffort = preset.reasoningEffort,
                        reasoningBudgetTokens =
                            preset.reasoningBudgetTokens?.toString().orEmpty(),
                        reasoningSummary = preset.reasoningSummary,
                        preserveOpaqueReasoningState = preset.preserveOpaqueReasoningState,
                        promptCacheMode = preset.promptCacheMode,
                        promptCacheTtl = preset.promptCacheTtl,
                        promptCacheCustomTtlSeconds =
                            preset.promptCacheCustomTtlSeconds?.toString().orEmpty(),
                        promptCacheContextReference =
                            preset.promptCacheContextReference.orEmpty(),
                        createdAt = preset.createdAt,
                        updatedAt = preset.updatedAt,
                        isExisting = true,
                        redactedRequestPreview = details.second
                            .presetPreviews[preset.id]
                            ?.safeDisplayText(),
                    ),
                ),
                presetReview = null,
                notice = null,
                error = null,
            )
        }
        refreshPresetControls()
    }

    fun updatePresetEditor(editor: PresetEditor) {
        updateReady { state ->
            if (state.presetEditor?.id != editor.id) return@updateReady state
            val previous = state.presetEditor
            val modeSafeEditor = editor.normalizedReasoningModeState()
            val policySafeEditor = modeSafeEditor.copy(
                preserveOpaqueReasoningState =
                    modeSafeEditor.preserveOpaqueReasoningState &&
                        state.presetControls?.reasoning?.preserveOpaqueState == true &&
                        !state.isCredentialBearingRoute(modeSafeEditor.modelRouteId),
            )
            val candidateChanged = previous.copy(
                visibleLevel = policySafeEditor.visibleLevel,
                redactedRequestPreview = policySafeEditor.redactedRequestPreview,
                validationMessages = policySafeEditor.validationMessages,
            ) != policySafeEditor.copy(
                redactedRequestPreview = previous.redactedRequestPreview,
                validationMessages = previous.validationMessages,
            )
            val normalized = normalizePresetEditor(
                policySafeEditor.copy(
                    redactedRequestPreview = if (candidateChanged) {
                        null
                    } else {
                        previous.redactedRequestPreview
                    },
                ),
            )
            val validation = validatePresetEditor(normalized)
            state.copy(
                presetEditor = normalized.copy(validationMessages = validation),
                presetReview = null,
                presetControls = null,
                notice = null,
                error = null,
            )
        }
        refreshPresetControls()
    }

    fun cancelPresetEditor() {
        presetControlJob?.cancel()
        updateReady {
            it.copy(
                presetEditor = null,
                presetReview = null,
                presetControls = null,
                notice = null,
                error = null,
            )
        }
    }

    fun savePreset() {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        val currentEditor = state.presetEditor ?: return
        if (state.isBusy) return
        val credentialBearingConnection =
            state.isCredentialBearingRoute(currentEditor.modelRouteId)
        val modeSafeEditor = currentEditor.normalizedReasoningModeState()
        val editor = modeSafeEditor.copy(
            preserveOpaqueReasoningState =
                modeSafeEditor.preserveOpaqueReasoningState &&
                    !credentialBearingConnection,
        )
        val controls = state.presetControls ?: run {
            _uiState.value = state.copy(error = "Route별 추론 및 cache 제어를 확인하는 중입니다.")
            return
        }
        val controlIssues = validatePresetControls(
            editor,
            controls,
            credentialBearingConnection,
        )
        if (controlIssues.isNotEmpty()) {
            _uiState.value = state.copy(
                error = controlIssues.joinToString("\n"),
            )
            return
        }
        val validation = validatePresetEditor(editor)
        if (validation.isNotEmpty()) {
            _uiState.value = state.copy(
                presetEditor = editor.copy(validationMessages = validation),
                error = "Preset 입력값을 확인해 주세요.",
            )
            return
        }
        val preset = editor.toGenerationPreset() ?: run {
            _uiState.value = state.copy(error = "Preset 입력값을 확인해 주세요.")
            return
        }
        val preparedReview = state.presetReview
            ?.takeIf { currentEditor == editor }
        val operationRevision = ++stateRevision
        _uiState.value = state.copy(
            presetEditor = editor,
            presetReview = preparedReview,
            busyOperation = if (preparedReview == null) {
                BusyOperation.ValidatingPreset
            } else {
                BusyOperation.SavingPreset
            },
            notice = null,
            error = null,
        )
        viewModelScope.launch {
            var mutationCompleted = false
            try {
                if (preparedReview == null) {
                    coreClient.validateGenerationPresetCandidate(preset)
                    val preview = coreClient.previewProviderRequestCandidate(preset)
                    check(preview.isSafeToDisplay) {
                        "Core request preview failed its redaction contract."
                    }
                    if (operationRevision == stateRevision) {
                        val latest = _uiState.value as? SettingsUiState.Ready
                            ?: return@launch
                        _uiState.value = latest.copy(
                            presetEditor = editor.copy(
                                redactedRequestPreview = preview.safeDisplayText(),
                            ),
                            presetReview = PresetCandidateReview(preset, preview),
                            busyOperation = null,
                            notice = "요청 미리보기를 확인한 뒤 저장을 확정해 주세요.",
                            error = null,
                        )
                    }
                    return@launch
                }
                check(preparedReview.candidate.matchesEditorCandidate(preset)) {
                    "Preset 입력이 미리보기 이후 변경되었습니다. 다시 검토해 주세요."
                }
                check(preparedReview.preview.isSafeToDisplay) {
                    "Prepared request preview failed its redaction contract."
                }
                val saved = coreClient.upsertGenerationPreset(preparedReview.candidate)
                mutationCompleted = true
                val settings = PROCESS_SETTINGS_SELECTION_MUTEX.withLock {
                    val latestSettings = coreClient.getSettings()
                    if (
                        latestSettings.selectedModelRouteId == null &&
                        latestSettings.selectedGenerationPresetId == null
                    ) {
                        coreClient.selectGenerationTarget(
                            GenerationTarget(saved.modelRouteId, saved.id),
                        )
                    } else {
                        latestSettings
                    }
                }
                val loaded = loadSnapshot(
                    notice = "Preset을 저장했습니다.",
                    settingsOverride = settings,
                )
                if (operationRevision == stateRevision) {
                    _uiState.value = loaded
                }
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                if (mutationCompleted) {
                    publishPostMutationReloadFailure(
                        operationRevision,
                        "Preset 저장",
                        error,
                    )
                } else {
                    restoreOperationError(operationRevision, error)
                }
            }
        }
    }

    fun deletePreset(generationPresetId: String) {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        if (state.isBusy) return
        val exists = state.connections
            .asSequence()
            .flatMap { it.routes.asSequence() }
            .flatMap { it.presets.asSequence() }
            .any { it.id == generationPresetId }
        if (!exists) return
        val operationRevision = ++stateRevision
        _uiState.value = state.copy(
            busyOperation = BusyOperation.DeletingPreset,
            notice = null,
            error = null,
        )
        viewModelScope.launch {
            var mutationCompleted = false
            try {
                coreClient.deleteGenerationPreset(generationPresetId)
                mutationCompleted = true
                val loaded = loadSnapshot(notice = "Preset을 삭제했습니다.")
                if (operationRevision == stateRevision) {
                    _uiState.value = loaded
                }
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                if (mutationCompleted) {
                    publishPostMutationReloadFailure(
                        operationRevision,
                        "Preset 삭제",
                        error,
                    )
                } else {
                    restoreOperationError(operationRevision, error)
                }
            }
        }
    }

    fun setPreservePartialGenerations(enabled: Boolean) {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        if (state.isBusy || state.settings.preservePartialGenerations == enabled) return
        val operationRevision = ++stateRevision
        _uiState.value = state.copy(
            busyOperation = BusyOperation.SavingConnection,
            notice = null,
            error = null,
        )
        viewModelScope.launch {
            try {
                val settings = PROCESS_SETTINGS_SELECTION_MUTEX.withLock {
                    val latestSettings = coreClient.getSettings()
                    if (latestSettings.preservePartialGenerations == enabled) {
                        latestSettings
                    } else {
                        coreClient.updateSettings(
                            latestSettings.copy(preservePartialGenerations = enabled),
                        )
                    }
                }
                if (operationRevision == stateRevision) {
                    val latest = _uiState.value as? SettingsUiState.Ready ?: return@launch
                    _uiState.value = latest.copy(
                        settings = settings,
                        busyOperation = null,
                        error = null,
                    )
                }
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                restoreOperationError(operationRevision, error)
            }
        }
    }

    fun startModelSync(connectionId: String) {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        if (state.isBusy || state.connections.none { it.connection.id == connectionId }) return
        if (state.modelSync.hasActionableModelSync()) {
            _uiState.value = state.copy(
                error = "진행 중, 중단됨 또는 검토 대기 중인 모델 동기화를 " +
                    "먼저 완료하거나 취소해 주세요.",
            )
            return
        }
        val operationRevision = ++stateRevision
        _uiState.value = state.copy(
            modelSync = ModelSyncUiState.Running(
                connectionId = connectionId,
                jobId = "",
                progress = DiscoveryProgress(0, 3, "동기화 준비 중"),
            ),
            busyOperation = BusyOperation.SynchronizingModels,
            notice = null,
            error = null,
        )
        modelSyncJob?.cancel()
        modelSyncJob = viewModelScope.launch {
            val startOutcome = try {
                PROCESS_MODEL_SYNC_START_MUTEX.withLock {
                    val activeJobs = loadActiveModelSyncJobs()
                    if (activeJobs.isNotEmpty()) {
                        ModelSyncStartOutcome.Existing(activeJobs.toModelSyncUiState())
                    } else {
                        val connection = coreClient.listProviderConnections()
                            .firstOrNull { it.id == connectionId }
                            ?: error("선택한 provider 연결이 더 이상 존재하지 않습니다.")
                        val credential = connection.validatedCredentialRefForRead()?.let {
                            check(
                                credentialStore.inspect(it) == CredentialRecordStatus.Available,
                            ) {
                                "저장된 자격증명을 사용할 수 없습니다. 연결 편집에서 다시 입력해 주세요."
                            }
                            checkNotNull(credentialStore.read(it)) {
                                "저장된 자격증명을 사용할 수 없습니다. 연결 편집에서 다시 입력해 주세요."
                            }
                        }
                        ModelSyncStartOutcome.Started(
                            coreClient.startProviderModelSync(connectionId, credential),
                        )
                    }
                }
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                if (operationRevision == stateRevision) {
                    val latest = _uiState.value as? SettingsUiState.Ready ?: return@launch
                    _uiState.value = latest.copy(
                        modelSync = ModelSyncUiState.Failed(
                            connectionId = connectionId,
                            message = error.userFacingMessage(),
                            retryable = true,
                        ),
                        busyOperation = null,
                        error = error.userFacingMessage(),
                    )
                }
                return@launch
            }
            if (startOutcome is ModelSyncStartOutcome.Existing) {
                if (operationRevision == stateRevision) {
                    val latest = _uiState.value as? SettingsUiState.Ready ?: return@launch
                    _uiState.value = latest.copy(
                        modelSync = startOutcome.state,
                        busyOperation = null,
                        error = "이미 진행 중, 중단됨 또는 검토 대기 중인 " +
                            "모델 동기화를 복원했습니다.",
                    )
                    modelSyncJob = null
                    resumeModelSyncMonitoring(
                        _uiState.value as SettingsUiState.Ready,
                        operationRevision,
                    )
                }
                return@launch
            }
            val jobId = (startOutcome as ModelSyncStartOutcome.Started).jobId
            try {
                pollModelSync(operationRevision, jobId)
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                reconcileModelSyncMonitorFailure(operationRevision, jobId, error)
            }
        }
    }

    fun approveModelSync(jobId: String, reviewSha256: String) {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        val review = state.modelSync
            ?.actionableJobs()
            ?.filterIsInstance<ModelSyncUiState.AwaitingReview>()
            ?.firstOrNull { it.jobId == jobId }
            ?: return
        if (state.isBusy || review.jobId != jobId || review.reviewHash != reviewSha256) return
        val operationRevision = ++stateRevision
        _uiState.value = state.copy(
            busyOperation = BusyOperation.SynchronizingModels,
            notice = null,
            error = null,
        )
        modelSyncJob?.cancel()
        modelSyncJob = viewModelScope.launch {
            try {
                val job = coreClient.approveProviderModelSync(jobId, reviewSha256)
                val loaded = loadSnapshot(
                    notice = if (job.state == "completed") {
                        "검토한 모델 변경을 적용했습니다."
                    } else {
                        "검토한 모델 변경을 적용하는 중입니다."
                    },
                )
                if (operationRevision == stateRevision) {
                    _uiState.value = loaded
                    modelSyncJob = null
                    resumeModelSyncMonitoring(loaded, operationRevision)
                }
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                reconcileModelSyncMutationFailure(
                    expectedRevision = operationRevision,
                    jobId = jobId,
                    connectionId = review.connectionId,
                    operationLabel = "모델 동기화 적용",
                    mutationError = error,
                )
            }
        }
    }

    fun cancelModelSync(jobId: String) {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        val current = state.modelSync
            ?.actionableJobs()
            ?.firstOrNull { it.jobId == jobId }
            ?: return
        if (state.isBusy &&
            !(current is ModelSyncUiState.Running &&
                state.busyOperation == BusyOperation.SynchronizingModels)
        ) {
            return
        }
        if (current.jobId.isBlank()) return
        val operationRevision = ++stateRevision
        modelSyncJob?.cancel()
        _uiState.value = state.copy(
            busyOperation = BusyOperation.CancellingDiscovery,
            notice = null,
            error = null,
        )
        modelSyncJob = viewModelScope.launch {
            try {
                coreClient.cancelProviderModelSync(jobId)
                val loaded = loadSnapshot(notice = "모델 동기화를 취소했습니다.")
                if (operationRevision == stateRevision) {
                    _uiState.value = loaded
                    modelSyncJob = null
                    resumeModelSyncMonitoring(loaded, operationRevision)
                }
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                reconcileModelSyncMutationFailure(
                    expectedRevision = operationRevision,
                    jobId = jobId,
                    connectionId = current.connectionId,
                    operationLabel = "모델 동기화 취소",
                    mutationError = error,
                )
            }
        }
    }

    fun dismissModelSync() {
        updateReady { state ->
            if (state.modelSync is ModelSyncUiState.Failed) {
                state.copy(modelSync = null, error = null)
            } else {
                state
            }
        }
    }

    private suspend fun pollModelSync(expectedRevision: Long, jobId: String) {
        while (expectedRevision == stateRevision) {
            val job = coreClient.getProviderModelSync(jobId)
            val deliveredEvents = coreClient.pollProviderModelSyncJobEvents(jobId, 64u)
            val incompatible = deliveredEvents.firstOrNull {
                it.version != MODEL_SYNC_EVENT_VERSION ||
                    it.redactionVersion != MODEL_SYNC_REDACTION_VERSION
            }
            check(incompatible == null) {
                "이 앱이 지원하지 않는 모델 동기화 event/redaction 버전입니다. " +
                    "앱과 Core binding을 함께 업데이트해 주세요."
            }
            check(deliveredEvents.all { it.jobId == jobId }) {
                "Job-scoped 모델 동기화 event가 다른 job ID를 포함했습니다."
            }
            val acceptedEvents = deliveredEvents
            val event = acceptedEvents.maxByOrNull { it.sequence }
            when (job.state) {
                "diff_ready_awaiting_review" -> {
                    val review = checkNotNull(job.review) {
                        "Model sync review is missing."
                    }
                    val latest = _uiState.value as? SettingsUiState.Ready ?: return
                    _uiState.value = latest.copy(
                        modelSync = review.toUiState(job.id),
                        busyOperation = null,
                        error = null,
                    )
                    ackModelSyncEvents(jobId, acceptedEvents)
                    return
                }

                "completed" -> {
                    val loaded = try {
                        loadSnapshot(notice = "모델 및 capability 동기화를 완료했습니다.")
                    } catch (error: Throwable) {
                        publishPostMutationReloadFailure(
                            expectedRevision,
                            "모델 및 capability 동기화",
                            error,
                        )
                        ackModelSyncEvents(jobId, acceptedEvents)
                        return
                    }
                    if (expectedRevision == stateRevision) {
                        _uiState.value = loaded
                    }
                    ackModelSyncEvents(jobId, acceptedEvents)
                    return
                }

                "interrupted" -> {
                    val latest = _uiState.value as? SettingsUiState.Ready ?: return
                    _uiState.value = latest.copy(
                        modelSync = job.toActionableUiState(),
                        busyOperation = null,
                        error = "앱 재시작으로 provider 요청이 중단되었습니다. " +
                            "중단 작업을 취소한 뒤 직접 다시 실행해 주세요.",
                    )
                    ackModelSyncEvents(jobId, acceptedEvents)
                    return
                }

                "failed" -> {
                    val message = job.failure?.messageKey
                        ?.let(::humanizeModelSyncMessage)
                        ?: "모델 동기화에 실패했습니다."
                    val latest = _uiState.value as? SettingsUiState.Ready ?: return
                    _uiState.value = latest.copy(
                        modelSync = ModelSyncUiState.Failed(
                            connectionId = job.connectionId,
                            message = message,
                            retryable = job.failure?.recoverable ?: true,
                        ),
                        busyOperation = null,
                        error = message,
                    )
                    ackModelSyncEvents(jobId, acceptedEvents)
                    return
                }

                "cancelled" -> {
                    val latest = _uiState.value as? SettingsUiState.Ready ?: return
                    _uiState.value = latest.copy(
                        modelSync = null,
                        busyOperation = null,
                        notice = "모델 동기화를 취소했습니다.",
                    )
                    ackModelSyncEvents(jobId, acceptedEvents)
                    return
                }

                else -> {
                    val latest = _uiState.value as? SettingsUiState.Ready ?: return
                    _uiState.value = latest.copy(
                        modelSync = ModelSyncUiState.Running(
                            connectionId = job.connectionId,
                            jobId = job.id,
                            progress = DiscoveryProgress(
                                completedSteps = event?.completedSteps?.toInt()
                                    ?: if (job.state == "fetching") 1 else 0,
                                totalSteps = event?.totalSteps?.toInt()?.coerceAtLeast(1) ?: 3,
                                currentLabel = event?.messageKey
                                    ?.let(::humanizeModelSyncMessage)
                                    ?: when (job.state) {
                                        "fetching" -> "Provider에서 모델 목록을 가져오는 중"
                                        "committing" -> "승인한 변경을 원자적으로 적용하는 중"
                                        else -> "동기화 준비 중"
                                    },
                            ),
                        ),
                        busyOperation = BusyOperation.SynchronizingModels,
                        error = null,
                    )
                }
            }
            ackModelSyncEvents(jobId, acceptedEvents)
            delay(MODEL_SYNC_POLL_INTERVAL_MILLIS)
        }
    }

    private suspend fun ackModelSyncEvents(
        jobId: String,
        events: List<dev.lorepia.app.bridge.ModelSyncEvent>,
    ) {
        events.sortedBy { it.sequence }.forEach { event ->
            // False means another live Settings destination already delivered
            // the same at-least-once event. The authoritative job snapshot was
            // reconciled before this acknowledgement.
            coreClient.ackProviderModelSyncEvent(jobId, event.sequence)
        }
    }

    private fun prepareKnownProviderReview(
        state: SettingsUiState.Ready,
        setup: ProviderSetupState,
    ) {
        val template = state.templates.firstOrNull { it.id == setup.templateId }
        val validationMessage = validateKnownProviderSetup(setup, template)
        if (validationMessage != null) {
            _uiState.value = state.copy(
                setup = setup.copy(error = validationMessage),
                error = validationMessage,
            )
            return
        }
        checkNotNull(template)
        val nextStep = if (template.requiresCredential) {
            ProviderSetupStep.ApproveCredentialOrigin
        } else {
            ProviderSetupStep.Review
        }
        _uiState.value = state.copy(
            setup = setup.copy(
                step = nextStep,
                approvedCredentialOrigin = null,
                review = if (nextStep == ProviderSetupStep.Review) {
                    buildKnownProviderReview(state, setup, null)
                } else {
                    null
                },
                error = null,
            ),
            error = null,
        )
    }

    private fun refreshPresetControls() {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        val currentEditor = state.presetEditor ?: return
        val modeSafeEditor = currentEditor.normalizedReasoningModeState()
        val editor = modeSafeEditor.copy(
            preserveOpaqueReasoningState =
                modeSafeEditor.preserveOpaqueReasoningState &&
                    !state.isCredentialBearingRoute(currentEditor.modelRouteId),
        )
        val revision = ++presetControlRevision
        presetControlJob?.cancel()
        if (state.presetControls != null || editor != currentEditor) {
            _uiState.value = state.copy(
                presetEditor = editor.copy(
                    validationMessages = validatePresetEditor(editor),
                ),
                presetReview = state.presetReview.takeIf { editor == currentEditor },
                presetControls = null,
            )
        }
        val candidate = editor.toGenerationPreset() ?: return
        presetControlJob = viewModelScope.launch {
            var expectedCandidate = candidate
            try {
                var controls = renderPresetControls(expectedCandidate)
                if (revision != presetControlRevision) return@launch
                var latest = _uiState.value as? SettingsUiState.Ready ?: return@launch
                var latestEditor = latest.presetEditor ?: return@launch
                var latestCandidate = latestEditor.toGenerationPreset()
                    ?: return@launch
                if (!candidate.matchesEditorCandidate(latestCandidate)) return@launch
                var nativeAllowed =
                    !latest.isCredentialBearingRoute(latestEditor.modelRouteId)
                var canonicalOpaqueState =
                    controls.reasoning.preserveOpaqueState && nativeAllowed
                var canonicalReasoningEffort =
                    latestEditor.canonicalReasoningEffort(controls.reasoning)
                if (
                    latestEditor.preserveOpaqueReasoningState !=
                    canonicalOpaqueState ||
                    latestEditor.reasoningEffort != canonicalReasoningEffort
                ) {
                    val normalizedEditor = normalizePresetEditor(
                        latestEditor.copy(
                            reasoningEffort = canonicalReasoningEffort,
                            preserveOpaqueReasoningState =
                                canonicalOpaqueState,
                            redactedRequestPreview = null,
                        ),
                    )
                    val normalizedCandidate = normalizedEditor.toGenerationPreset()
                        ?: return@launch
                    _uiState.value = latest.copy(
                        presetEditor = normalizedEditor.copy(
                            validationMessages = validatePresetEditor(normalizedEditor),
                        ),
                        presetReview = null,
                        presetControls = null,
                        notice = null,
                        error = null,
                    )
                    expectedCandidate = normalizedCandidate
                    controls = renderPresetControls(expectedCandidate)
                    if (revision != presetControlRevision) return@launch
                    latest = _uiState.value as? SettingsUiState.Ready ?: return@launch
                    latestEditor = latest.presetEditor ?: return@launch
                    latestCandidate = latestEditor.toGenerationPreset() ?: return@launch
                    if (!normalizedCandidate.matchesEditorCandidate(latestCandidate)) {
                        return@launch
                    }
                    nativeAllowed =
                        !latest.isCredentialBearingRoute(latestEditor.modelRouteId)
                    canonicalOpaqueState =
                        controls.reasoning.preserveOpaqueState && nativeAllowed
                    canonicalReasoningEffort =
                        latestEditor.canonicalReasoningEffort(controls.reasoning)
                    check(
                        latestEditor.preserveOpaqueReasoningState ==
                            canonicalOpaqueState &&
                            latestEditor.reasoningEffort == canonicalReasoningEffort,
                    ) {
                        "Core returned an unstable reasoning control policy."
                    }
                }
                _uiState.value = latest.copy(
                    presetControls = controls,
                    error = null,
                )
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                if (revision != presetControlRevision) return@launch
                val latest = _uiState.value as? SettingsUiState.Ready ?: return@launch
                val latestCandidate = latest.presetEditor?.toGenerationPreset()
                if (
                    latestCandidate != null &&
                    expectedCandidate.matchesEditorCandidate(latestCandidate)
                ) {
                    _uiState.value = latest.copy(
                        presetControls = null,
                        error = error.userFacingMessage(),
                    )
                }
            }
        }
    }

    private suspend fun renderPresetControls(candidate: GenerationPreset): PresetControls =
        coroutineScope {
            val reasoning = async {
                coreClient.renderReasoningControlForPreset(candidate)
            }
            val cache = async {
                coreClient.renderPromptCacheControlForPreset(candidate)
            }
            PresetControls(reasoning.await(), cache.await())
        }

    private suspend fun loadActiveModelSyncJobs(): List<dev.lorepia.app.bridge.ModelSyncJob> =
        loadActiveModelSyncJobs(
            boundedSnapshotRead { coreClient.listProviderConnections() },
        )

    private suspend fun loadActiveModelSyncJobs(
        connections: List<ProviderConnection>,
    ): List<dev.lorepia.app.bridge.ModelSyncJob> = coroutineScope {
        connections
            .map { connection ->
                async {
                    boundedSnapshotRead {
                        coreClient.listProviderModelSyncs(
                            connection.id,
                            MODEL_SYNC_HISTORY_LIMIT,
                        )
                    }
                }
            }
            .awaitAll()
            .flatten()
            .filter { it.state in ACTIVE_MODEL_SYNC_STATES }
            .distinctBy { it.id }
    }

    private suspend fun loadSnapshot(
        notice: String? = null,
        settingsOverride: dev.lorepia.app.bridge.AppSettings? = null,
    ): SettingsUiState.Ready {
        coreClient.recoverProviderDiscoveries()
        val discoveredSnapshots = boundedSnapshotRead {
            coreClient.listProviderDiscoveries(DISCOVERY_HISTORY_LIMIT)
        }
        val discoveries = discoveredSnapshots.onEach { snapshot ->
            credentialCoordinator.reconcileDiscoveryCredential(snapshot)
        }
        val restoredDiscovery = discoveries
            .filterNot { it.state.isDiscoveryTerminal() }
            .maxWithOrNull(
                compareBy<ProviderDiscoverySnapshot> {
                    when {
                        it.state == "unknown_outcome" -> 5
                        it.state == "interrupted" || it.state == "compensating" -> 4
                        it.actionRequired != null -> 3
                        else -> 2
                    }
                }.thenBy { it.updatedAt },
            )
        return coroutineScope {
        val healthDeferred = async { boundedSnapshotRead { coreClient.healthCheck() } }
        val settingsDeferred = async {
            settingsOverride ?: boundedSnapshotRead { coreClient.getSettings() }
        }
        val templatesDeferred = async {
            boundedSnapshotRead { coreClient.listProviderTemplates() }
        }
        val connectionsDeferred = async {
            boundedSnapshotRead { coreClient.listProviderConnections() }
        }
        val catalogDeferred = async {
            try {
                ProviderCatalogUiState.Ready(
                    status = boundedSnapshotRead {
                        coreClient.providerCatalogStatus()
                    },
                    history = boundedSnapshotRead {
                        coreClient.providerCatalogHistory(CATALOG_HISTORY_LIMIT)
                    },
                )
            } catch (error: Throwable) {
                ProviderCatalogUiState.Error(error.userFacingMessage())
            }
        }

        val templates = templatesDeferred.await()
        val templateByIdentity = templates.associateBy { it.id to it.manifestVersion }
        val details = connectionsDeferred.await().map { connection ->
            async {
                val credentialRecordStatus = if (connection.credentialSlotReady) {
                    runCatching {
                        val reference = checkNotNull(
                            connection.validatedCredentialRefForRead(),
                        )
                        boundedSnapshotRead {
                            credentialStore.inspect(reference)
                        }
                    }.getOrNull()
                } else {
                    null
                }
                val routes = boundedSnapshotRead {
                    coreClient.listModelRoutes(connection.id)
                }.map { route ->
                    async {
                        val presets = boundedSnapshotRead {
                            coreClient.listGenerationPresets(route.id)
                        }
                        val parameterSpecsDeferred = async {
                            boundedSnapshotRead {
                                coreClient.effectiveParameterSpecs(route.id)
                            }
                        }
                        val previews = presets.map { preset ->
                            async {
                                preset.id to runCatching {
                                    boundedSnapshotRead {
                                        coreClient.previewProviderRequest(route.id, preset.id)
                                    }
                                }.getOrNull()?.takeIf { it.isSafeToDisplay }
                            }
                        }.awaitAll().mapNotNull { (id, preview) ->
                            preview?.let { id to it }
                        }.toMap()
                        val observations = boundedSnapshotRead {
                            coreClient.listCapabilityObservations(route.id)
                        }
                        val capabilities = observations
                            .groupBy { it.key }
                            .map { (key, matching) ->
                                async {
                                    CapabilityDetails(
                                        key = key,
                                        effective = boundedSnapshotRead {
                                            coreClient.effectiveCapability(route.id, key)
                                        },
                                        observations = matching.sortedByDescending {
                                            it.observedAt
                                        },
                                    )
                                }
                            }
                            .awaitAll()
                            .sortedBy(CapabilityDetails::key)
                        ModelRouteDetails(
                            route = route,
                            presets = presets,
                            capabilities = capabilities,
                            presetPreviews = previews,
                            parameterSpecs = parameterSpecsDeferred.await(),
                        )
                    }
                }.awaitAll()
                ProviderConnectionDetails(
                    connection = connection,
                    template = templateByIdentity[
                        connection.templateId to connection.templateVersion
                    ],
                    routes = routes.sortedBy { it.route.displayName ?: it.route.modelId },
                    credentialRecordStatus = credentialRecordStatus,
                )
            }
        }.awaitAll()
        val activeModelSyncJobs = details
            .map { it.connection.id }
            .map { connectionId ->
                async {
                    boundedSnapshotRead {
                        coreClient.listProviderModelSyncs(
                            connectionId,
                            MODEL_SYNC_HISTORY_LIMIT,
                        )
                    }
                }
            }
            .awaitAll()
            .flatten()
            .filter { it.state in ACTIVE_MODEL_SYNC_STATES }
            .distinctBy { it.id }
        val restoredModelSync = activeModelSyncJobs
            .takeIf { it.isNotEmpty() }
            ?.toModelSyncUiState()
        val settings = settingsDeferred.await()
        val loaded = SettingsUiState.Ready(
            health = healthDeferred.await(),
            settings = settings,
            templates = templates.sortedBy(ProviderTemplate::displayName),
            connections = details.sortedBy { it.connection.displayName },
            catalog = catalogDeferred.await(),
            setup = restoredDiscovery?.let { snapshot ->
                ProviderSetupState(
                    connectionId = snapshot.pendingConnectionId,
                    displayName = snapshot.pendingDisplayName,
                    apiBasePath = snapshot.connectionOptions.apiBasePath.orEmpty(),
                    networkMode = snapshot.connectionOptions.networkMode,
                    localNetworkOrigin = snapshot.connectionOptions.localNetworkApproval
                        ?.origin
                        .orEmpty(),
                    localNetworkAddresses = snapshot.connectionOptions.localNetworkApproval
                        ?.addresses
                        .orEmpty()
                        .joinToString("\n"),
                    timeoutSeconds = snapshot.connectionOptions.timeoutSeconds.toString(),
                    step = snapshot.toSetupStep(),
                    progress = snapshot.toUiProgress(),
                    discovery = snapshot,
                    assistantOutcome = snapshot.toAssistantOutcome(),
                    error = snapshot.failure?.messageKey,
                )
            },
            modelSync = restoredModelSync,
            busyOperation = if (restoredModelSync is ModelSyncUiState.Running) {
                BusyOperation.SynchronizingModels
            } else {
                null
            },
            notice = notice,
        )
        loaded.copy(
            setup = loaded.setup?.copy(
                preferredAssistantModelRouteId =
                    restoredDiscovery?.durableAssistantModelRouteId(),
            ),
        )
        }
    }

    private fun resumeModelSyncMonitoring(
        state: SettingsUiState.Ready,
        expectedRevision: Long,
    ) {
        val running = state.modelSync as? ModelSyncUiState.Running ?: return
        if (running.jobId.isBlank()) return
        modelSyncJob?.cancel()
        modelSyncJob = viewModelScope.launch {
            try {
                pollModelSync(expectedRevision, running.jobId)
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                reconcileModelSyncMonitorFailure(expectedRevision, running.jobId, error)
            }
        }
    }

    private suspend fun reconcileModelSyncMonitorFailure(
        expectedRevision: Long,
        jobId: String,
        monitorError: Throwable,
    ) {
        if (expectedRevision != stateRevision) return
        val durable = runCatching { coreClient.getProviderModelSync(jobId) }.getOrNull()
        if (durable?.state == "completed") {
            val loaded = runCatching {
                loadSnapshot(notice = "모델 및 capability 동기화를 완료했습니다.")
            }.getOrNull()
            if (loaded != null && expectedRevision == stateRevision) {
                _uiState.value = loaded
                return
            }
        }
        val latest = _uiState.value as? SettingsUiState.Ready ?: return
        val reconciled = when (durable?.state) {
            "cancelled" -> null
            "created", "fetching", "committing", "diff_ready_awaiting_review",
            "failed", "interrupted",
            -> durable.toUiState()
            else -> latest.modelSync
        }
        _uiState.value = latest.copy(
            modelSync = reconciled,
            busyOperation = null,
            notice = null,
            error = "동기화 상태 모니터링이 중단되었습니다. Core 작업 상태는 다시 확인했으며, " +
                "새로고침해 모니터링을 재개할 수 있습니다. (${monitorError.userFacingMessage()})",
        )
    }

    private suspend fun reconcileModelSyncMutationFailure(
        expectedRevision: Long,
        jobId: String,
        connectionId: String,
        operationLabel: String,
        mutationError: Throwable,
    ) {
        if (expectedRevision != stateRevision) return
        val durable = try {
            coreClient.getProviderModelSync(jobId)
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (reconcileError: Throwable) {
            if (expectedRevision != stateRevision) return
            val latest = _uiState.value as? SettingsUiState.Ready ?: return
            val message = "$operationLabel 결과를 Core에서 확인할 수 없습니다. " +
                "상태 새로고침으로 작업 결과를 확인해 주세요. " +
                "(${mutationError.userFacingMessage()}; " +
                "${reconcileError.userFacingMessage()})"
            _uiState.value = latest.copy(
                modelSync = ModelSyncUiState.Failed(
                    connectionId = connectionId,
                    message = message,
                    retryable = true,
                ),
                busyOperation = null,
                notice = null,
                error = message,
            )
            modelSyncJob = null
            return
        }
        if (durable.id != jobId) {
            if (expectedRevision != stateRevision) return
            val latest = _uiState.value as? SettingsUiState.Ready ?: return
            val message = "$operationLabel 결과가 다른 모델 동기화 작업을 가리킵니다. " +
                "상태 새로고침으로 작업 결과를 확인해 주세요."
            _uiState.value = latest.copy(
                modelSync = ModelSyncUiState.Failed(
                    connectionId = connectionId,
                    message = message,
                    retryable = false,
                ),
                busyOperation = null,
                notice = null,
                error = message,
            )
            modelSyncJob = null
            return
        }

        var snapshotError: Throwable? = null
        val loaded = try {
            loadSnapshot()
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (error: Throwable) {
            snapshotError = error
            null
        }
        if (expectedRevision != stateRevision) return
        val latest = _uiState.value as? SettingsUiState.Ready ?: return
        val base = loaded ?: latest
        val activeFallback = durable.takeIf {
            it.state in ACTIVE_MODEL_SYNC_STATES
        }?.toActionableUiState()
        val reconciledModelSync = when (durable.state) {
            "completed", "cancelled" -> loaded?.modelSync ?: ModelSyncUiState.Failed(
                connectionId = durable.connectionId,
                message = "$operationLabel 결과는 '${durable.state}'로 확인했지만 " +
                    "최신 설정을 다시 읽지 못했습니다. 상태 새로고침이 필요합니다.",
                retryable = true,
            )

            "failed" -> loaded?.modelSync?.takeIf { it.hasActionableModelSync() }
                ?: durable.toUiState()

            in ACTIVE_MODEL_SYNC_STATES -> loaded?.modelSync ?: activeFallback

            else -> loaded?.modelSync ?: ModelSyncUiState.Blocked(
                connectionId = durable.connectionId,
                jobId = durable.id,
                message = "지원하지 않는 모델 동기화 상태 '${durable.state}'를 확인했습니다. " +
                    "새 작업을 시작하기 전에 상태를 새로고침하거나 이 작업을 취소해 주세요.",
            )
        }
        val terminalKnown = durable.state == "completed" || durable.state == "cancelled"
        val reconciliationMessage = buildString {
            append(operationLabel)
            append(" 요청은 오류를 반환했지만 Core의 최신 작업 상태 '")
            append(durable.state)
            append("'를 다시 확인했습니다. (")
            append(mutationError.userFacingMessage())
            append(')')
            snapshotError?.let {
                append(" 최신 목록을 다시 읽는 중에도 오류가 발생했습니다. (")
                append(it.userFacingMessage())
                append(')')
            }
        }
        val reconciled = base.copy(
            modelSync = reconciledModelSync,
            busyOperation = if (reconciledModelSync is ModelSyncUiState.Running) {
                BusyOperation.SynchronizingModels
            } else {
                null
            },
            notice = if (terminalKnown && loaded != null) {
                if (durable.state == "completed") {
                    "모델 동기화가 완료된 상태로 확인되었습니다."
                } else {
                    "모델 동기화가 취소된 상태로 확인되었습니다."
                }
            } else {
                null
            },
            error = if (terminalKnown && loaded != null) null else reconciliationMessage,
        )
        _uiState.value = reconciled
        modelSyncJob = null
        resumeModelSyncMonitoring(reconciled, expectedRevision)
    }

    private fun restoreOperationError(expectedRevision: Long, error: Throwable) {
        if (expectedRevision != stateRevision) return
        val latest = _uiState.value as? SettingsUiState.Ready ?: return
        _uiState.value = latest.copy(
            busyOperation = null,
            notice = null,
            error = error.userFacingMessage(),
        )
    }

    private fun publishPostMutationReloadFailure(
        expectedRevision: Long,
        operationName: String,
        error: Throwable,
    ) {
        if (expectedRevision != stateRevision) return
        _uiState.value = SettingsUiState.Error(
            IllegalStateException(
                "$operationName 작업은 완료됐지만 최신 상태를 다시 불러오지 못했습니다. " +
                    "새로고침해 주세요.",
                error,
            ),
        )
    }

    private suspend fun <T> boundedSnapshotRead(block: suspend () -> T): T =
        snapshotReadSemaphore.withPermit { block() }

    private inline fun updateReady(
        transform: (SettingsUiState.Ready) -> SettingsUiState.Ready,
    ) {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        if (!state.isBusy) {
            _uiState.value = transform(state)
        }
    }

    private fun replacePendingCredential(
        connectionId: String,
        credential: String?,
    ) {
        clearPendingCredential()
        if (credential == null) return
        pendingCredentialConnectionId = connectionId
        pendingCredential = credential.toCharArray()
    }

    private fun pendingCredentialString(connectionId: String): String? {
        check(pendingCredentialConnectionId == null ||
            pendingCredentialConnectionId == connectionId
        ) {
            "Pending credential is bound to another provider connection."
        }
        return pendingCredential?.concatToString()
    }

    private fun clearPendingCredential(connectionId: String? = null) {
        if (connectionId != null && pendingCredentialConnectionId != connectionId) return
        pendingCredential?.fill('\u0000')
        pendingCredential = null
        pendingCredentialConnectionId = null
    }

    private fun clearPendingCatalogMutation() {
        pendingCatalogImportBytes?.fill(0)
        pendingCatalogImportBytes = null
        pendingCatalogImportPlan = null
        pendingCatalogRollbackPlan = null
    }

    private inline fun updateCatalogState(
        transform: (ProviderCatalogUiState.Ready) -> ProviderCatalogUiState.Ready,
    ) {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        val catalog = state.catalog as? ProviderCatalogUiState.Ready ?: return
        _uiState.value = state.copy(catalog = transform(catalog))
    }

    private suspend fun reloadCatalogState(
        expectedRevision: Long,
        notice: String?,
    ) = coroutineScope {
        val status = async {
            boundedSnapshotRead { coreClient.providerCatalogStatus() }
        }
        val history = async {
            boundedSnapshotRead {
                coreClient.providerCatalogHistory(CATALOG_HISTORY_LIMIT)
            }
        }
        val loaded = ProviderCatalogUiState.Ready(
            status = status.await(),
            history = history.await(),
            notice = notice,
        )
        if (expectedRevision != catalogRevision) return@coroutineScope
        val latest = _uiState.value as? SettingsUiState.Ready ?: return@coroutineScope
        _uiState.value = latest.copy(catalog = loaded)
    }

    private fun publishCatalogOperationFailure(
        expectedRevision: Long,
        error: Throwable,
        clearReview: Boolean = false,
    ) {
        if (expectedRevision != catalogRevision) return
        updateCatalogState { catalog ->
            catalog.copy(
                pendingReview = if (clearReview) null else catalog.pendingReview,
                busyOperation = null,
                notice = null,
                error = error.userFacingMessage(),
            )
        }
    }

    override fun onCleared() {
        clearPendingCredential()
        clearPendingCatalogMutation()
        super.onCleared()
    }

    companion object {
        private const val DISCOVERY_POLL_INTERVAL_MILLIS = 250L
        private const val DISCOVERY_EVENT_BATCH_LIMIT = 64u
        private const val DISCOVERY_HISTORY_LIMIT = 20u
        private const val DISCOVERY_EVENT_VERSION = 2u
        private const val MODEL_SYNC_POLL_INTERVAL_MILLIS = 200L
        private const val MODEL_SYNC_HISTORY_LIMIT = 20u
        private const val CATALOG_HISTORY_LIMIT = 40u
        private const val MAX_CONCURRENT_SNAPSHOT_READS = 8
        private const val MODEL_SYNC_EVENT_VERSION = 1u
        private const val MODEL_SYNC_REDACTION_VERSION = 1u
        private val ACTIVE_MODEL_SYNC_STATES = setOf(
            "created",
            "fetching",
            "interrupted",
            "committing",
            "diff_ready_awaiting_review",
        )
        private val PROCESS_MODEL_SYNC_START_MUTEX = Mutex()
        private val PROCESS_SETTINGS_SELECTION_MUTEX = Mutex()
        private const val EXISTING_CONNECTION_CREDENTIAL_REPLACEMENT_MESSAGE =
            "기존 연결의 API 자격증명은 같은 연결 ID에서 교체할 수 없습니다. " +
                "provider-native reasoning 상태가 다른 계정으로 이어지지 않도록 " +
                "새 AI 연결을 만들어 주세요."
        private const val EXISTING_CONNECTION_CONFIGURATION_CHANGE_MESSAGE =
            "기존 연결의 API endpoint와 연결 옵션은 변경할 수 없습니다. " +
                "다른 endpoint나 설정을 사용하려면 새 AI 연결을 만들어 주세요."

        fun factory(
            coreClient: CoreClient,
            credentialStore: CredentialStore,
        ): ViewModelProvider.Factory = viewModelFactory {
            initializer {
                SettingsViewModel(coreClient, credentialStore)
            }
        }
    }
}

private fun validateDiscoverySetup(
    setup: ProviderSetupState,
    template: ProviderTemplate?,
    credentialSupplied: Boolean,
    rawCurlSupplied: Boolean,
): String? {
    if (setup.kind == null) return "Provider 추가 방법을 선택해 주세요."
    if (setup.displayName.isBlank()) return "연결 이름을 입력해 주세요."
    val timeout = setup.timeoutSeconds.toUIntOrNull()
    if (timeout == null || timeout !in 1u..600u) {
        return "제한 시간은 1초에서 600초 사이여야 합니다."
    }
    if (
        setup.kind in setOf(ProviderSetupKind.UnknownSite, ProviderSetupKind.LocalServer) &&
        setup.siteUrl.isBlank()
    ) {
        return "탐색을 시작할 사이트 또는 API URL을 입력해 주세요."
    }
    if (setup.kind == ProviderSetupKind.CurlExample && !rawCurlSupplied) {
        return "공식 문서의 cURL 예제를 입력해 주세요."
    }
    if (setup.kind == ProviderSetupKind.KnownProvider) {
        val knownError = validateKnownProviderSetup(
            setup.copy(hasPendingCredential = credentialSupplied),
            template,
        )
        if (knownError != null) return knownError
    }
    if (
        setup.kind == ProviderSetupKind.LocalServer &&
        setup.networkMode == ProviderNetworkMode.Public
    ) {
        return "로컬 서버는 loopback 또는 명시적으로 승인한 로컬 네트워크 모드여야 합니다."
    }
    when (setup.networkMode) {
        ProviderNetworkMode.Public,
        ProviderNetworkMode.LocalLoopback,
        -> Unit
        ProviderNetworkMode.ApprovedLocalNetwork -> {
            val approval = setup.localNetworkApproval
            if (approval == null || approval.origin.isBlank()) {
                return "승인할 로컬 네트워크 origin을 정확히 입력해 주세요."
            }
            if (approval.addresses.isEmpty() || approval.addresses.size > 16) {
                return "승인할 로컬 IP 주소를 1개에서 16개까지 입력해 주세요."
            }
            if (setup.docsUrl.isNotBlank()) {
                return "승인한 LAN에서는 별도 문서 읽기 승인 없이 문서 URL을 가져오지 않습니다."
            }
            if (
                setup.kind == ProviderSetupKind.UnknownSite ||
                setup.kind == ProviderSetupKind.LocalServer
            ) {
                return "승인한 LAN provider는 네트워크 문서 탐색 대신 공식 cURL 예제로 설정해 주세요."
            }
        }
    }
    return null
}

private sealed interface ModelSyncStartOutcome {
    data class Started(val jobId: String) : ModelSyncStartOutcome

    data class Existing(val state: ModelSyncUiState) : ModelSyncStartOutcome
}

private sealed interface ConnectionDeleteOutcome {
    data object Deleted : ConnectionDeleteOutcome

    data class Blocked(
        val modelSync: ModelSyncUiState,
    ) : ConnectionDeleteOutcome
}

private fun ProviderSetupState.toDiscoveryInput(
    template: ProviderTemplate?,
): ProviderDiscoveryInput {
    val timeout = checkNotNull(timeoutSeconds.toUIntOrNull())
    val values = if (kind == ProviderSetupKind.KnownProvider) {
        checkNotNull(connectionValues.toConfigEntries(template))
    } else {
        emptyList()
    }
    return ProviderDiscoveryInput(
        connectionId = connectionId,
        displayName = displayName.trim(),
        siteUrl = when (kind) {
            ProviderSetupKind.UnknownSite,
            ProviderSetupKind.LocalServer,
            -> siteUrl.trim().takeIf(String::isNotEmpty)
            ProviderSetupKind.KnownProvider,
            ProviderSetupKind.CurlExample,
            null,
            -> null
        },
        docsUrl = docsUrl.trim().takeIf(String::isNotEmpty),
        credentialSlotReady = false,
        preferredAssistantModelRouteId = preferredAssistantModelRouteId,
        connectionOptions = ProviderDiscoveryConnectionOptions(
            values = values,
            apiBasePath = apiBasePath.trim().takeIf(String::isNotEmpty),
            timeoutSeconds = timeout,
            networkMode = networkMode,
            localNetworkApproval = localNetworkApproval,
        ),
    )
}

private fun ProviderDiscoverySnapshot.toSetupStep(): ProviderSetupStep = when (state) {
    "awaiting_credential_origin_approval" -> ProviderSetupStep.ApproveCredentialOrigin
    "awaiting_review" -> ProviderSetupStep.Review
    "committing", "compensating", "unknown_outcome" -> ProviderSetupStep.Committing
    "ready" -> ProviderSetupStep.Completed
    "failed" -> ProviderSetupStep.Failed
    "cancelled" -> ProviderSetupStep.Cancelled
    else -> ProviderSetupStep.Discovering
}

private fun ProviderDiscoverySnapshot.toAssistantOutcome(): DiscoveryAssistantOutcome? {
    val boundary = assistantResumeBoundary ?: return null
    return when (boundary.action) {
        DiscoveryAssistantResumeAction.SupplyMoreEvidence ->
            DiscoveryAssistantOutcome.MoreEvidenceRequired(
                sessionId = sessionId,
                questions = boundary.questions,
            )
        DiscoveryAssistantResumeAction.ReviewDraft ->
            boundary.draftReview?.let {
                DiscoveryAssistantOutcome.DraftReadyForReview(it)
            }
        else -> null
    }
}

private fun ProviderDiscoverySnapshot.durableAssistantModelRouteId(): String? =
    (approvalProposal?.grant as? DiscoveryApprovalGrant.AssistantConsent)
        ?.assistantModelRouteId
        ?: approvals.asReversed().firstNotNullOfOrNull { approval ->
            (approval.grant as? DiscoveryApprovalGrant.AssistantConsent)
                ?.assistantModelRouteId
        }

private fun ProviderDiscoverySnapshot.toUiProgress(): DiscoveryProgress {
    val completed = steps.count { it.state == "completed" }
    val active = steps.firstOrNull {
        it.state == "current" || it.state == "active" || it.state == "in_progress"
    }
        ?: steps.firstOrNull { it.state != "completed" }
    return DiscoveryProgress(
        completedSteps = completed,
        totalSteps = steps.size.coerceAtLeast(1),
        currentLabel = active?.titleKey ?: state.replace('_', ' '),
    )
}

private fun String.isDiscoveryTerminal(): Boolean =
    this in setOf("ready", "failed", "cancelled")

private fun String.requiresExplicitRecoveryAction(): Boolean =
    this in setOf("compensating", "interrupted", "unknown_outcome")

private fun ProviderDiscoverySnapshot.requiresExplicitAssistantResumeAction(): Boolean =
    when (assistantResumeBoundary?.action) {
        null,
        DiscoveryAssistantResumeAction.WaitForAssistantOutcome,
        -> false
        else -> true
    }

private fun dev.lorepia.app.bridge.RequestPreview?.isSafeDiscoveryPreview(): Boolean =
    this == null || isSafeToDisplay

private fun validateKnownProviderSetup(
    setup: ProviderSetupState,
    template: ProviderTemplate?,
): String? {
    if (template == null) return "Provider를 선택해 주세요."
    if (setup.displayName.isBlank()) return "연결 이름을 입력해 주세요."
    if (setup.apiOrigin.isBlank()) return "API origin을 확인해 주세요."
    val timeout = setup.timeoutSeconds.toUIntOrNull()
    if (timeout == null || timeout !in 1u..600u) {
        return "제한 시간은 1초에서 600초 사이여야 합니다."
    }
    if (template.requiresCredential && !setup.hasPendingCredential) {
        return "API 자격증명을 입력해 주세요."
    }
    for (field in template.connectionFields) {
        if (field.valueType == ConnectionFieldType.Credential) continue
        val value = setup.connectionValues[field.key]
        if (field.required && value.isNullOrBlank()) {
            return "${field.labelKey} 값을 입력해 주세요."
        }
        if (field.valueType == ConnectionFieldType.Integer &&
            !value.isNullOrBlank() &&
            value.toLongOrNull() == null
        ) {
            return "${field.labelKey} 값은 정수여야 합니다."
        }
        if (field.valueType == ConnectionFieldType.Boolean &&
            !value.isNullOrBlank() &&
            value.lowercase() !in setOf("true", "false")
        ) {
            return "${field.labelKey} 값은 true 또는 false여야 합니다."
        }
    }
    return null
}

private fun ProviderSetupState.toConnectionDraft(
    template: ProviderTemplate,
): ProviderConnectionDraft? {
    val timeout = timeoutSeconds.toUIntOrNull() ?: return null
    return ProviderConnectionDraft(
        id = connectionId,
        templateId = template.id,
        templateVersion = template.manifestVersion,
        displayName = displayName.trim(),
        apiOrigin = apiOrigin.trim(),
        apiBasePath = apiBasePath.trim().takeIf(String::isNotEmpty),
        networkMode = networkMode,
        values = connectionValues.toConfigEntries(template) ?: return null,
        approvedCredentialOrigin = approvedCredentialOrigin,
        timeoutSeconds = timeout,
    )
}

private fun Map<String, String>.toConfigEntries(
    template: ProviderTemplate?,
): List<ConnectionConfigEntry>? {
    if (template == null) return emptyList()
    return template.connectionFields.mapNotNull { field ->
        if (field.valueType == ConnectionFieldType.Credential) return@mapNotNull null
        val raw = get(field.key)?.trim().orEmpty()
        if (raw.isEmpty()) return@mapNotNull null
        val value = when (field.valueType) {
            ConnectionFieldType.Text -> ConnectionConfigValue.Text(raw)
            ConnectionFieldType.Integer -> {
                ConnectionConfigValue.Integer(raw.toLongOrNull() ?: return null)
            }

            ConnectionFieldType.Boolean -> ConnectionConfigValue.Boolean(
                when (raw.lowercase()) {
                    "true" -> true
                    "false" -> false
                    else -> return null
                },
            )

            ConnectionFieldType.Credential -> return@mapNotNull null
        }
        ConnectionConfigEntry(field.key, value)
    }
}

private fun ConnectionEditor.toConnection(
    current: ProviderConnection,
): ProviderConnection? {
    if (displayName.isBlank() || hasImmutableConnectionChanges(current)) return null
    return current.copy(
        displayName = displayName.trim(),
    )
}

private fun ConnectionEditor.hasImmutableConnectionChanges(
    current: ProviderConnection,
): Boolean {
    val currentValues = current.values.associate { entry ->
        entry.key to when (val value = entry.value) {
            is ConnectionConfigValue.Text -> value.value
            is ConnectionConfigValue.Integer -> value.value.toString()
            is ConnectionConfigValue.Boolean -> value.value.toString()
        }
    }
    return original != current ||
        apiBasePath.trim().takeIf(String::isNotEmpty) != current.apiBasePath ||
        timeoutSeconds != current.timeoutSeconds.toString() ||
        values != currentValues
}

private fun buildKnownProviderReview(
    state: SettingsUiState.Ready,
    setup: ProviderSetupState,
    credentialOrigin: String?,
): ProviderSetupReview {
    val template = state.templates.first { it.id == setup.templateId }
    return ProviderSetupReview(
        providerName = setup.displayName.trim(),
        apiOrigin = setup.apiOrigin.trim(),
        credentialOrigin = credentialOrigin,
        apiFamily = template.apiFamily,
        models = emptyList(),
        capabilitySummary = listOf("연결 저장 후 모델별 근거를 동기화합니다."),
        evidenceSummary = listOf(
            "LorePia 내장 template ${template.id} v${template.manifestVersion}",
        ),
        redactedRequestPreview = null,
        reviewHash = "pending-core-review",
    )
}

private fun PresetEditor.toGenerationPreset(): GenerationPreset? {
    val now = Instant.now().toString()
    val budget = reasoningBudgetTokens.takeIf(String::isNotBlank)?.toUIntOrNull()
        ?: if (reasoningBudgetTokens.isBlank()) null else return null
    val customTtl = promptCacheCustomTtlSeconds.takeIf(String::isNotBlank)?.toUIntOrNull()
        ?: if (promptCacheCustomTtlSeconds.isBlank()) null else return null
    return GenerationPreset(
        id = id,
        modelRouteId = modelRouteId,
        displayName = displayName.trim(),
        values = explicitValues.entries
            .sortedBy { it.key }
            .map { (parameterId, literal) ->
                ParameterValue(parameterId, ParameterValueState.Explicit(literal))
            },
        reasoningMode = reasoningMode,
        reasoningEffort = reasoningEffort,
        reasoningBudgetTokens = budget,
        reasoningSummary = reasoningSummary,
        preserveOpaqueReasoningState = preserveOpaqueReasoningState,
        promptCacheMode = promptCacheMode,
        promptCacheTtl = promptCacheTtl,
        promptCacheCustomTtlSeconds = customTtl,
        promptCacheContextReference =
            promptCacheContextReference.trim().takeIf(String::isNotEmpty),
        createdAt = createdAt,
        updatedAt = now,
    )
}

private fun PresetEditor.canonicalReasoningEffort(
    control: ReasoningControl,
): String? = when {
    reasoningMode == "provider_default" -> null
    control.effortField == "hidden" -> null
    reasoningMode == "enabled" &&
        reasoningEffort == null &&
        control.state == "ready" &&
        control.mode == "enabled" &&
        control.effort != null &&
        control.effort in control.allowedEfforts -> control.effort
    else -> reasoningEffort
}

private fun PresetEditor.normalizedReasoningModeState(): PresetEditor = when (reasoningMode) {
    "provider_default" -> copy(
        reasoningEffort = null,
        reasoningBudgetTokens = "",
        reasoningSummary = "provider_default",
    )
    "disabled" -> copy(
        reasoningEffort = null,
        reasoningBudgetTokens = "",
        reasoningSummary = "disabled",
        preserveOpaqueReasoningState = false,
    )
    else -> this
}

private fun GenerationPreset.matchesEditorCandidate(other: GenerationPreset): Boolean =
    copy(updatedAt = other.updatedAt) == other

private fun dev.lorepia.app.bridge.ModelSyncReview.toUiState(
    jobId: String,
): ModelSyncUiState.AwaitingReview {
    val listedById = listedRoutes.associateBy { it.id }
    val expectedById = expectedModelRoutes.associateBy { it.id }
    val added = newlySeenModelRouteIds.map { id ->
        listedById[id]?.displayName ?: listedById[id]?.modelId ?: id
    }
    val missing = missingModelRouteIds.map { id ->
        expectedById[id]?.displayName ?: expectedById[id]?.modelId ?: id
    }
    val changed = listedRoutes.mapNotNull { listed ->
        val expected = expectedById[listed.id]
        if (expected == null || listed.id in newlySeenModelRouteIds) {
            null
        } else {
            routeChangeSummary(expected, listed)
        }
    }
    val capabilityChanges = capabilityObservations.map { observation ->
        buildString {
            append(observation.key)
            append(": ")
            append(capabilityValueSummary(observation.value))
            append(" · ")
            append(observation.status)
            append(" · ")
            append(observation.source)
            append(" · 신뢰도 ")
            append(observation.confidence)
            append(" · 관측 ")
            append(observation.observedAt)
            observation.expiresAt?.let {
                append(" · 만료 ")
                append(it)
            }
            observation.evidenceRef?.let {
                append(" · 근거 ")
                append(it)
            }
        }
    }
    return ModelSyncUiState.AwaitingReview(
        connectionId = connectionId,
        jobId = jobId,
        reviewHash = sha256,
        targetSummary = "${expectedConnection.displayName} · " +
            "${expectedConnection.apiOrigin} · " +
            "${expectedConnection.templateId} v${expectedConnection.templateVersion}",
        addedModels = added,
        changedModels = changed,
        missingModels = missing,
        capabilityChanges = capabilityChanges,
        initialPresets = initialPresets.map { preset ->
            "${preset.displayName} → " +
                (listedById[preset.modelRouteId]?.displayName
                    ?: listedById[preset.modelRouteId]?.modelId
                    ?: preset.modelRouteId)
        },
        routesRequiringPresetConfiguration = routesRequiringPresetConfiguration.map { id ->
            listedById[id]?.displayName ?: listedById[id]?.modelId ?: id
        },
        provenance = listOf(
            "${provenance.source} · ${provenance.apiFamily}",
            "${provenance.apiOrigin}${provenance.endpointPath}",
            "${provenance.pagesFetched} page · ${provenance.responseBytes} bytes",
            "관측 $observedAt",
        ),
    )
}

private fun capabilityValueSummary(
    value: dev.lorepia.app.bridge.CapabilityValue,
): String = when (value.kind) {
    "boolean" -> value.booleanValue?.toString() ?: "boolean 값 없음"
    "integer" -> value.integerValue?.toString() ?: "integer 값 없음"
    "enum_values" -> value.enumValues.joinToString().ifBlank { "enum 값 없음" }
    "structured" -> "구조화된 metadata"
    else -> "알 수 없는 값"
}

private fun routeChangeSummary(
    expected: dev.lorepia.app.bridge.ModelRoute,
    listed: dev.lorepia.app.bridge.ModelRoute,
): String? {
    val fields = buildList {
        if (expected.apiFamily != listed.apiFamily) add("API 형식")
        if (expected.modelId != listed.modelId) add("model ID")
        if (expected.displayName != listed.displayName) add("표시 이름")
        if (expected.routeConfig != listed.routeConfig) add("route 설정")
        if (expected.availability != listed.availability) add("가용성")
        if (expected.rawMetadataJson != listed.rawMetadataJson) add("raw metadata")
        if (expected.metadataSource != listed.metadataSource) add("metadata 출처")
    }
    if (fields.isEmpty()) return null
    return "${listed.displayName ?: listed.modelId} (${fields.joinToString()})"
}

private fun List<dev.lorepia.app.bridge.ModelSyncJob>.toModelSyncUiState(): ModelSyncUiState {
    val actionable = sortedWith(
        compareByDescending<dev.lorepia.app.bridge.ModelSyncJob> {
            if (it.state == "diff_ready_awaiting_review") 1 else 0
        }.thenByDescending { it.updatedAt }
            .thenBy { it.id },
    ).map(dev.lorepia.app.bridge.ModelSyncJob::toActionableUiState)
    return if (actionable.size == 1) {
        actionable.single()
    } else {
        ModelSyncUiState.MultipleActive(actionable)
    }
}

private fun dev.lorepia.app.bridge.ModelSyncJob.toActionableUiState():
    ModelSyncUiState.Actionable = when (state) {
    "diff_ready_awaiting_review" -> review?.toUiState(id) ?: ModelSyncUiState.Blocked(
        connectionId = connectionId,
        jobId = id,
        message = "저장된 모델 동기화 review가 손상되었습니다. 이 작업을 취소해 주세요.",
    )

    "created", "fetching", "committing" -> ModelSyncUiState.Running(
        connectionId = connectionId,
        jobId = id,
        progress = DiscoveryProgress(
            completedSteps = if (state == "created") 0 else 1,
            totalSteps = 3,
            currentLabel = when (state) {
                "fetching" -> "Provider에서 모델 목록을 가져오는 중"
                "committing" -> "승인한 변경을 적용하는 중"
                else -> "동기화 준비 중"
            },
        ),
    )

    "interrupted" -> ModelSyncUiState.Interrupted(
        connectionId = connectionId,
        jobId = id,
    )

    else -> ModelSyncUiState.Blocked(
        connectionId = connectionId,
        jobId = id,
        message = "지원하지 않는 활성 모델 동기화 상태 '$state'입니다. 이 작업을 취소해 주세요.",
    )
}

private fun dev.lorepia.app.bridge.ModelSyncJob.toUiState(): ModelSyncUiState = when (state) {
    "diff_ready_awaiting_review", "created", "fetching", "interrupted", "committing" ->
        toActionableUiState()

    else -> ModelSyncUiState.Failed(
        connectionId = connectionId,
        message = failure?.messageKey?.let(::humanizeModelSyncMessage)
            ?: "모델 동기화에 실패했습니다.",
        retryable = failure?.recoverable ?: true,
    )
}

private fun humanizeModelSyncMessage(messageKey: String): String =
    messageKey.replace('_', ' ').replace('-', ' ')

private fun dev.lorepia.app.bridge.RequestPreview.safeDisplayText(): String? {
    if (!isSafeToDisplay) return null
    return buildString {
        append(method)
        append(' ')
        append(origin)
        append(path)
        if (headerNames.isNotEmpty()) {
            append("\nHeaders: ")
            append(headerNames.joinToString())
        }
        if (queryParameterNames.isNotEmpty()) {
            append("\nQuery names: ")
            append(queryParameterNames.joinToString())
        }
        bodyShape?.let {
            append("\nBody shape: ")
            append(it.displayLabel())
        }
        if (bodyTruncated) {
            append("\nBody shape truncated by bounded preview.")
        }
        append("\nRedaction v")
        append(redactionVersion)
    }
}

private fun Throwable.userFacingMessage(): String =
    message?.takeIf(String::isNotBlank) ?: "설정을 저장하지 못했습니다."
