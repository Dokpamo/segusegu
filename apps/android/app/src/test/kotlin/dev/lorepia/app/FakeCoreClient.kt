package dev.lorepia.app

import dev.lorepia.app.bridge.*
import dev.lorepia.app.platform.credentials.CredentialStore
import dev.lorepia.app.platform.credentials.CredentialRecordStatus

class FakeCoreClient(
    var version: String = "test-core",
    var coreApiVersion: UInt = 8u,
    var bindingApiVersion: UInt = 8u,
    var chatEventVersion: UInt = 4u,
    var health: CoreHealthStatus = healthyCoreStatus(),
    var characters: List<CharacterSummary> = emptyList(),
    var inspection: ImportInspection = syntheticInspection(),
    var conversations: MutableList<ConversationSummary> = mutableListOf(),
    var messages: MutableMap<String, MutableList<ChatMessage>> = mutableMapOf(),
    var profiles: MutableList<ProviderProfile> = mutableListOf(),
    var providerTemplates: MutableList<ProviderTemplate> = mutableListOf(),
    var providerConnections: MutableList<ProviderConnection> = mutableListOf(),
    var modelRoutes: MutableMap<String, MutableList<ModelRoute>> = mutableMapOf(),
    var generationPresets: MutableMap<String, MutableList<GenerationPreset>> = mutableMapOf(),
    var capabilityObservations: MutableMap<String, MutableList<CapabilityObservation>> =
        mutableMapOf(),
    var effectiveCapabilities: MutableMap<Pair<String, String>, EffectiveCapability> =
        mutableMapOf(),
    var modelSyncJobs: MutableMap<String, ModelSyncJob> = mutableMapOf(),
    var modelSyncEvents: MutableMap<String, ArrayDeque<ModelSyncEvent>> = mutableMapOf(),
    var nextStartedModelSyncJob: ModelSyncJob? = null,
    var providerDiscoveries: MutableMap<String, ProviderDiscoverySnapshot> = mutableMapOf(),
    var providerDiscoveryEvents: ArrayDeque<DiscoveryOutboxEvent> = ArrayDeque(),
    var providerDiscoveryCompensationSteps:
        MutableMap<String, MutableList<DiscoveryCompensationStep>> = mutableMapOf(),
    var catalogStatus: ProviderCatalogStatus = syntheticCatalogStatus(),
    var catalogHistory: ProviderCatalogHistory = syntheticCatalogHistory(),
    var catalogImportPlan: ProviderCatalogImportPlan? = null,
    var catalogRollbackPlan: ProviderCatalogRollbackPlan? = null,
    var curlInspectionCredential: ByteArray? = null,
    var discoveryAssistantOutcome: DiscoveryAssistantOutcome? = null,
    var settings: AppSettings = AppSettings(
        preservePartialGenerations = false,
        selectedProviderProfileId = null,
    ),
    var versionError: Throwable? = null,
    var healthError: Throwable? = null,
    var inspectionError: Throwable? = null,
    var commitError: Throwable? = null,
    var createConnectionError: Throwable? = null,
    var updateConnectionError: Throwable? = null,
    var deleteConnectionError: Throwable? = null,
    var validatePresetCandidateError: Throwable? = null,
    var discoveryError: Throwable? = null,
    var catalogError: Throwable? = null,
    private val operationTrace: MutableList<String>? = null,
) : CoreClient {
    val queuedEvents = ArrayDeque<ChatEvent>()
    private val curlCredentialHandoffs = mutableMapOf<String, ByteArray>()
    private val providerDiscoveryInputs = mutableMapOf<String, ProviderDiscoveryInput>()
    var coreVersionCalls = 0
        private set
    var versionInfoCalls = 0
        private set
    var healthCheckCalls = 0
        private set
    var listCharactersCalls = 0
        private set
    var inspectImportCalls = 0
        private set
    var commitImportCalls = 0
        private set
    var discardImportCalls = 0
        private set
    var sendMessageCalls = 0
        private set
    var cancelGenerationCalls = 0
        private set
    var upsertGenerationPresetCalls = 0
        private set
    var validatePresetCandidateCalls = 0
        private set
    var previewPresetCandidateCalls = 0
        private set
    var startProviderModelSyncCalls = 0
        private set
    var getProviderModelSyncCalls = 0
        private set
    var approveProviderModelSyncCalls = 0
        private set
    var cancelProviderModelSyncCalls = 0
        private set
    var getProviderModelSyncError: Throwable? = null
    var approveProviderModelSyncError: Throwable? = null
    var approveProviderModelSyncStateOnError: String? = null
    var cancelProviderModelSyncError: Throwable? = null
    var cancelProviderModelSyncStateOnError: String? = null
    val queuedModelSyncGetResponses =
        mutableMapOf<String, ArrayDeque<ModelSyncJob>>()
    var renderReasoningControlCalls = 0
        private set
    var reasoningPreserveOpaqueOverride: Boolean? = null
    var reasoningEffortOverride: String? = null
    var reasoningEffortFieldOverride: String? = null
    var renderReasoningControlError: Throwable? = null
    var inspectProviderCurlCalls = 0
        private set
    var takeProviderCurlCredentialCalls = 0
        private set
    var runProviderDiscoveryAssistantTurnCalls = 0
        private set
    var resumeProviderDiscoveryAssistantCoreHostActionCalls = 0
        private set
    var lastSuppliedDiscoveryCurl: String? = null
        private set
    var lastCurlNetworkPolicy: ProviderNetworkPolicy? = null
        private set
    var lastProviderDiscoveryInput: ProviderDiscoveryInput? = null
        private set
    var lastCredential: String? = null
        private set
    var lastGenerationTarget: GenerationTarget? = null
        private set
    var lastValidatedPresetCandidate: GenerationPreset? = null
        private set
    var lastPreviewPresetCandidate: GenerationPreset? = null
        private set
    var lastRenderedReasoningPresetCandidate: GenerationPreset? = null
        private set
    var lastPreparedCatalogBytes: ByteArray? = null
        private set
    var lastActivatedCatalogBytes: ByteArray? = null
        private set
    var lastActivatedCatalogPlan: ProviderCatalogImportPlan? = null
        private set
    var lastActivatedRollbackPlan: ProviderCatalogRollbackPlan? = null
        private set
    val providerMutationOrder = mutableListOf<String>()
    val acknowledgedModelSyncEvents = mutableListOf<Pair<String, ULong>>()
    var closed = false
        private set

    override suspend fun coreVersion(): String {
        coreVersionCalls += 1
        versionError?.let { throw it }
        return version
    }

    override suspend fun versionInfo(): CoreVersionInfo {
        versionInfoCalls += 1
        versionError?.let { throw it }
        return CoreVersionInfo(
            coreVersion = version,
            coreApiVersion = coreApiVersion,
            bindingApiVersion = bindingApiVersion,
            chatEventVersion = chatEventVersion,
        )
    }

    override suspend fun healthCheck(): CoreHealthStatus {
        healthCheckCalls += 1
        healthError?.let { throw it }
        return health
    }

    override suspend fun databaseStats(): DatabaseStats = DatabaseStats(
        characters = characters.size.toULong(),
        conversations = conversations.size.toULong(),
        messages = messages.values.sumOf { it.size }.toULong(),
        pendingImports = 0uL,
    )

    override suspend fun listCharacters(): List<CharacterSummary> {
        listCharactersCalls += 1
        return characters
    }

    override suspend fun getCharacter(characterId: String): CharacterSummary =
        characters.first { it.id == characterId }

    override suspend fun inspectImport(stagedPath: String): ImportInspection {
        inspectImportCalls += 1
        inspectionError?.let { throw it }
        return inspection
    }

    override suspend fun commitImport(inspectionId: String): CharacterSummary {
        commitImportCalls += 1
        commitError?.let { throw it }
        return CharacterSummary(
            id = "character-$inspectionId",
            name = inspection.displayName,
            description = inspection.description,
            sourceHash = inspection.sourceSha256,
        ).also { character ->
            characters = characters + character
        }
    }

    override suspend fun discardImport(inspectionId: String) {
        discardImportCalls += 1
    }

    override suspend fun listConversations(): List<ConversationSummary> =
        conversations.toList()

    override suspend fun openConversation(characterId: String): ConversationSummary {
        val character = getCharacter(characterId)
        val next = ConversationSummary(
            id = "conversation-${conversations.size + 1}",
            characterId = characterId,
            title = character.name,
            createdAt = "2026-01-01T00:00:00Z",
            updatedAt = "2026-01-01T00:00:00Z",
        )
        conversations += next
        messages[next.id] = mutableListOf()
        return next
    }

    override suspend fun listMessages(conversationId: String): List<ChatMessage> =
        messages[conversationId]?.toList().orEmpty()

    override suspend fun sendMessage(
        conversationId: String,
        text: String,
        providerProfileId: String,
        credential: String?,
    ): String {
        sendMessageCalls += 1
        lastCredential = credential
        val generationId = "generation-$sendMessageCalls"
        messages.getOrPut(conversationId, ::mutableListOf) += ChatMessage(
            id = "user-$sendMessageCalls",
            conversationId = conversationId,
            parentId = null,
            role = "user",
            content = text,
            status = "complete",
            generationId = null,
            createdAt = "2026-01-01T00:00:00Z",
        )
        messages.getValue(conversationId) += ChatMessage(
            id = "assistant-$sendMessageCalls",
            conversationId = conversationId,
            parentId = "user-$sendMessageCalls",
            role = "assistant",
            content = "",
            status = "pending",
            generationId = generationId,
            createdAt = "2026-01-01T00:00:01Z",
        )
        return generationId
    }

    override suspend fun sendMessageWithTarget(
        conversationId: String,
        text: String,
        target: GenerationTarget,
        credential: String?,
    ): String {
        lastGenerationTarget = target
        return sendMessage(
            conversationId = conversationId,
            text = text,
            providerProfileId = target.modelRouteId,
            credential = credential,
        )
    }

    override suspend fun cancelGeneration(generationId: String) {
        cancelGenerationCalls += 1
    }

    override suspend fun pollEvents(maxEvents: UInt): ChatEventBatch {
        val drained = buildList {
            repeat(minOf(maxEvents.toInt(), queuedEvents.size)) {
                add(queuedEvents.removeFirst())
            }
        }
        return ChatEventBatch(drained, droppedEventCount = 0uL)
    }

    override suspend fun getSettings(): AppSettings = settings

    override suspend fun updateSettings(settings: AppSettings): AppSettings {
        this.settings = settings
        return settings
    }

    override suspend fun listProviderProfiles(): List<ProviderProfile> = profiles.toList()

    override suspend fun upsertProviderProfile(profile: ProviderProfile): ProviderProfile {
        profiles.removeAll { it.id == profile.id }
        profiles += profile
        return profile
    }

    override suspend fun deleteProviderProfile(profileId: String) {
        profiles.removeAll { it.id == profileId }
        if (settings.selectedProviderProfileId == profileId) {
            settings = settings.copy(selectedProviderProfileId = null)
        }
    }

    override suspend fun listProviderTemplates(): List<ProviderTemplate> =
        providerTemplates.toList()

    override suspend fun inspectProviderCurl(
        rawCurl: String,
        networkPolicy: ProviderNetworkPolicy,
    ): ProviderCurlInspection {
        inspectProviderCurlCalls += 1
        lastCurlNetworkPolicy = networkPolicy
        discoveryError?.let { throw it }
        require(rawCurl.isNotBlank())
        val handoffId = curlInspectionCredential?.let {
            "curl-handoff-${curlCredentialHandoffs.size + 1}".also { id ->
                curlCredentialHandoffs[id] = it.copyOf()
            }
        }
        return ProviderCurlInspection(
            inspectionSchemaVersion = 1u,
            sanitizedSiteUrl = "https://api.example.invalid",
            apiOrigin = "https://api.example.invalid",
            method = "POST",
            path = "/v1/chat/completions",
            headerNames = listOf("authorization", "content-type"),
            authBindingHint = if (handoffId == null) null else AuthBinding.BearerHeader,
            apiFamilyHint = "openai_chat_completions",
            modelHint = "synthetic-model",
            streamHint = true,
            redactedCurl = "curl https://api.example.invalid/v1/chat/completions",
            credentialHandoffId = handoffId,
        )
    }

    override suspend fun takeProviderCurlCredential(
        credentialHandoffId: String,
    ): ByteArray? {
        takeProviderCurlCredentialCalls += 1
        return curlCredentialHandoffs.remove(credentialHandoffId)
    }

    override suspend fun beginProviderDiscovery(
        input: ProviderDiscoveryInput,
        source: ProviderDiscoverySource,
        rawCurl: String?,
    ): ProviderDiscoverySnapshot {
        discoveryError?.let { throw it }
        val template = (source as? ProviderDiscoverySource.KnownProvider)?.let { known ->
            providerTemplates.firstOrNull { it.id == known.templateId }
        }
        val snapshot = syntheticDiscoverySnapshot(input, template)
        lastProviderDiscoveryInput = input
        providerDiscoveryInputs[snapshot.sessionId] = input
        providerDiscoveries[snapshot.sessionId] = snapshot
        return snapshot
    }

    override suspend fun prepareProviderDiscoveryAction(
        actionId: String,
        expectedRevision: ULong,
        action: ProviderDiscoveryAction,
    ): ProviderDiscoveryActionEnvelope = ProviderDiscoveryActionEnvelope(
        actionId = actionId,
        expectedRevision = expectedRevision,
        requestSha256 = "request-${actionId.padEnd(64, '0').take(64)}",
        action = action,
    )

    override suspend fun getProviderDiscovery(
        sessionId: String,
    ): ProviderDiscoverySnapshot = providerDiscoveries.getValue(sessionId)

    override suspend fun listProviderDiscoveries(
        limit: UInt,
    ): List<ProviderDiscoverySnapshot> = providerDiscoveries.values.take(limit.toInt())

    override suspend fun continueProviderDiscovery(
        sessionId: String,
        envelope: ProviderDiscoveryActionEnvelope,
        credential: String?,
    ): ProviderDiscoverySnapshot {
        discoveryError?.let { throw it }
        val current = providerDiscoveries.getValue(sessionId)
        require(current.revision == envelope.expectedRevision)
        val preferredAssistantModelRouteId =
            providerDiscoveryInputs[sessionId]?.preferredAssistantModelRouteId
        if (envelope.action is ProviderDiscoveryAction.RequestAssistant) {
            requireNotNull(preferredAssistantModelRouteId) {
                "provider setup assistant route was not selected"
            }
        }
        val updated = current.afterFakeDiscoveryAction(
            envelope.action,
            preferredAssistantModelRouteId,
        )
        providerDiscoveries[sessionId] = updated
        return updated
    }

    override suspend fun supplyProviderDiscoveryDocumentEvidence(
        sessionId: String,
        expectedRevision: ULong,
        documentUrl: String,
    ): ProviderDiscoverySnapshot = providerDiscoveries.getValue(sessionId).let { current ->
        require(current.revision == expectedRevision)
        current.copy(
            revision = current.revision + 1uL,
            state = "awaiting_more_evidence",
            evidence = current.evidence + DiscoveryEvidence(
                id = "evidence-${current.evidence.size + 1}",
                kind = "official_document",
                contentSha256 = "d".repeat(64),
                fetchedAt = "2026-01-01T00:00:00Z",
            ),
        ).also { providerDiscoveries[sessionId] = it }
    }

    override suspend fun supplyProviderDiscoveryCurlEvidence(
        sessionId: String,
        expectedRevision: ULong,
        rawCurl: String,
    ): ProviderDiscoverySnapshot {
        lastSuppliedDiscoveryCurl = rawCurl
        return supplyProviderDiscoveryDocumentEvidence(
            sessionId,
            expectedRevision,
            "curl-evidence",
        )
    }

    override suspend fun cancelProviderDiscovery(
        sessionId: String,
        expectedRevision: ULong,
    ): ProviderDiscoverySnapshot = providerDiscoveries.getValue(sessionId).let { current ->
        require(current.revision == expectedRevision)
        current.copy(
            revision = current.revision + 1uL,
            state = "cancelled",
            actionRequired = null,
        ).also { providerDiscoveries[sessionId] = it }
    }

    override suspend fun commitProviderDiscovery(
        sessionId: String,
        credentialReferenceConfirmed: Boolean,
    ): ProviderConnection {
        discoveryError?.let { throw it }
        val snapshot = providerDiscoveries.getValue(sessionId)
        require(snapshot.state == "committing")
        require(!snapshot.credentialSlotExpected || credentialReferenceConfirmed)
        operationTrace?.add("core:create:${snapshot.pendingConnectionId}")
        createConnectionError?.let { failure ->
            val attemptId = checkNotNull(snapshot.commitAttemptId)
            if (snapshot.credentialSlotExpected) {
                providerDiscoveryCompensationSteps[attemptId] = mutableListOf(
                    syntheticCredentialCompensationStep(snapshot, attemptId),
                )
            }
            providerDiscoveries[sessionId] = snapshot.copy(
                revision = snapshot.revision + 1uL,
                state = "compensating",
                activeOperationId = "compensation-operation",
                recoveryOperation = "compensation",
                actionRequired = null,
                failure = null,
            )
            throw failure
        }
        val connection = ProviderConnection(
            id = snapshot.pendingConnectionId,
            templateId = providerTemplates.firstOrNull()?.id ?: "discovered",
            templateVersion = providerTemplates.firstOrNull()?.manifestVersion ?: 1u,
            displayName = snapshot.pendingDisplayName,
            apiOrigin = "https://api.example.invalid",
            apiBasePath = null,
            networkMode = ProviderNetworkMode.Public,
            values = emptyList(),
            credentialSlotReady = snapshot.credentialSlotExpected,
            credentialScope = snapshot.credentialSlotId?.let {
                CredentialScope(
                    allowedOrigins = listOf("https://api.example.invalid"),
                    authBinding = AuthBinding.BearerHeader,
                    redirectPolicy = CredentialRedirectPolicy.Deny,
                )
            },
            approvedCredentialOrigins = if (snapshot.credentialSlotExpected) {
                listOf("https://api.example.invalid")
            } else {
                emptyList()
            },
            timeoutSeconds = 60u,
            status = "untested",
            createdAt = "2026-01-01T00:00:00Z",
            updatedAt = "2026-01-01T00:00:00Z",
        )
        providerConnections += connection
        providerDiscoveries[sessionId] = snapshot.copy(
            revision = snapshot.revision + 1uL,
            state = "ready",
            actionRequired = null,
            committedConnectionId = connection.id,
        )
        return connection
    }

    override suspend fun listProviderDiscoveryCompensationSteps(
        commitAttemptId: String,
    ): List<DiscoveryCompensationStep> =
        providerDiscoveryCompensationSteps[commitAttemptId].orEmpty()

    override suspend fun continueProviderDiscoveryCompensation(
        sessionId: String,
    ): ProviderDiscoverySnapshot {
        val snapshot = providerDiscoveries.getValue(sessionId)
        val attemptId = checkNotNull(snapshot.commitAttemptId)
        val hasPendingStep = providerDiscoveryCompensationSteps[attemptId]
            .orEmpty()
            .any { it.status != DiscoveryCompensationStatus.Completed }
        if (hasPendingStep) return snapshot
        return snapshot.copy(
            revision = snapshot.revision + 1uL,
            state = "failed",
            activeOperationId = null,
            recoveryOperation = null,
            failure = DiscoveryFailure(
                code = "synthetic_commit_failed",
                messageKey = "provider.discovery.synthetic_commit_failed",
                recoverable = true,
            ),
        ).also { providerDiscoveries[sessionId] = it }
    }

    override suspend fun startProviderDiscoveryCredentialCompensation(
        sessionId: String,
        stepId: String,
    ): DiscoveryCompensationStep {
        val snapshot = providerDiscoveries.getValue(sessionId)
        val attemptId = checkNotNull(snapshot.commitAttemptId)
        val steps = providerDiscoveryCompensationSteps.getValue(attemptId)
        val index = steps.indexOfFirst { it.id == stepId }
        require(index >= 0)
        val updated = steps[index].copy(
            status = DiscoveryCompensationStatus.InProgress,
            attemptCount = steps[index].attemptCount + 1u,
        )
        steps[index] = updated
        return updated
    }

    override suspend fun completeProviderDiscoveryCredentialCompensation(
        sessionId: String,
        stepId: String,
    ): ProviderDiscoverySnapshot {
        val snapshot = providerDiscoveries.getValue(sessionId)
        val attemptId = checkNotNull(snapshot.commitAttemptId)
        val steps = providerDiscoveryCompensationSteps.getValue(attemptId)
        val index = steps.indexOfFirst { it.id == stepId }
        require(index >= 0)
        steps[index] = steps[index].copy(
            status = DiscoveryCompensationStatus.Completed,
            completedAt = "2026-01-01T00:00:01Z",
        )
        return snapshot.copy(
            revision = snapshot.revision + 1uL,
            state = "failed",
            actionRequired = null,
        ).also { providerDiscoveries[sessionId] = it }
    }

    override suspend fun failProviderDiscoveryCredentialCompensation(
        sessionId: String,
        stepId: String,
        failure: DiscoveryFailure,
    ): ProviderDiscoverySnapshot {
        val snapshot = providerDiscoveries.getValue(sessionId)
        val attemptId = checkNotNull(snapshot.commitAttemptId)
        val steps = providerDiscoveryCompensationSteps.getValue(attemptId)
        val index = steps.indexOfFirst { it.id == stepId }
        require(index >= 0)
        steps[index] = steps[index].copy(
            status = DiscoveryCompensationStatus.Failed,
            lastFailure = failure,
        )
        return snapshot.copy(
            revision = snapshot.revision + 1uL,
            failure = failure,
        ).also { providerDiscoveries[sessionId] = it }
    }

    override suspend fun markProviderDiscoveryCredentialCompensationUnknown(
        sessionId: String,
        stepId: String,
    ): ProviderDiscoverySnapshot {
        val snapshot = providerDiscoveries.getValue(sessionId)
        val attemptId = checkNotNull(snapshot.commitAttemptId)
        val steps = providerDiscoveryCompensationSteps.getValue(attemptId)
        val index = steps.indexOfFirst { it.id == stepId }
        require(index >= 0)
        steps[index] = steps[index].copy(
            status = DiscoveryCompensationStatus.OutcomeUnknown,
        )
        return snapshot.copy(
            revision = snapshot.revision + 1uL,
            state = "unknown_outcome",
            unknownOperation = "compensation",
        ).also { providerDiscoveries[sessionId] = it }
    }

    override suspend fun resumeProviderDiscoveryCompensation(
        sessionId: String,
    ): ProviderDiscoverySnapshot = providerDiscoveries.getValue(sessionId).let { snapshot ->
        snapshot.copy(
            revision = snapshot.revision + 1uL,
            failure = null,
        ).also { providerDiscoveries[sessionId] = it }
    }

    override suspend fun recoverProviderDiscoveries(): List<DiscoveryRecoveryResult> =
        emptyList()

    override suspend fun pollProviderDiscoveryEvents(
        limit: UInt,
    ): List<DiscoveryOutboxEvent> = buildList {
        repeat(minOf(limit.toInt(), providerDiscoveryEvents.size)) {
            add(providerDiscoveryEvents.removeFirst())
        }
    }

    override suspend fun ackProviderDiscoveryEvent(eventId: String): Boolean = true

    override suspend fun runProviderDiscoveryAssistantTurn(
        sessionId: String,
        estimate: DiscoveryAssistantCallEstimate,
        assistantCredential: String?,
    ): DiscoveryAssistantOutcome {
        val preferredAssistantModelRouteId = checkNotNull(
            providerDiscoveryInputs[sessionId]?.preferredAssistantModelRouteId,
        )
        require(settings.selectedModelRouteId == preferredAssistantModelRouteId)
        requireNotNull(settings.selectedGenerationPresetId)
        runProviderDiscoveryAssistantTurnCalls += 1
        val outcome = discoveryAssistantOutcome ?: DiscoveryAssistantOutcome.MoreEvidenceRequired(
            sessionId = sessionId,
            questions = emptyList(),
        )
        val current = providerDiscoveries.getValue(sessionId)
        providerDiscoveries[sessionId] = when (outcome) {
            is DiscoveryAssistantOutcome.MoreEvidenceRequired -> current.copy(
                revision = current.revision + 1uL,
                state = "awaiting_more_evidence",
                actionRequired = DiscoveryActionRequired.SupplyMoreEvidence,
                assistantResumeBoundary = DiscoveryAssistantResumeBoundary(
                    checkpoint = DiscoveryAssistantCheckpoint.AwaitingMoreEvidence,
                    action = DiscoveryAssistantResumeAction.SupplyMoreEvidence,
                    questions = outcome.questions,
                    draftReview = null,
                ),
            )
            is DiscoveryAssistantOutcome.DraftReadyForReview -> current.copy(
                revision = current.revision + 1uL,
                state = "building_assistant_manifest_draft",
                actionRequired = null,
                assistantResumeBoundary = DiscoveryAssistantResumeBoundary(
                    checkpoint = DiscoveryAssistantCheckpoint.DraftReady,
                    action = DiscoveryAssistantResumeAction.ReviewDraft,
                    questions = emptyList(),
                    draftReview = outcome.review,
                ),
            )
        }
        return outcome
    }

    override suspend fun approveProviderDiscoveryAssistantRetry(
        sessionId: String,
    ): ProviderDiscoverySnapshot = providerDiscoveries.getValue(sessionId).copy(
        revision = providerDiscoveries.getValue(sessionId).revision + 1uL,
        assistantResumeBoundary = DiscoveryAssistantResumeBoundary(
            checkpoint = DiscoveryAssistantCheckpoint.Ready,
            action = DiscoveryAssistantResumeAction.RunAssistant,
            questions = emptyList(),
            draftReview = null,
        ),
    ).also { providerDiscoveries[sessionId] = it }

    override suspend fun requestProviderDiscoveryAssistantRevision(
        sessionId: String,
    ): ProviderDiscoverySnapshot = providerDiscoveries.getValue(sessionId)

    override suspend fun acceptProviderDiscoveryAssistantDraft(
        sessionId: String,
    ): ProviderDiscoverySnapshot = providerDiscoveries.getValue(sessionId)

    override suspend fun resumeProviderDiscoveryAssistantCoreHostAction(
        sessionId: String,
    ): ProviderDiscoverySnapshot {
        resumeProviderDiscoveryAssistantCoreHostActionCalls += 1
        return providerDiscoveries.getValue(sessionId).copy(
            revision = providerDiscoveries.getValue(sessionId).revision + 1uL,
            assistantResumeBoundary = DiscoveryAssistantResumeBoundary(
                checkpoint = DiscoveryAssistantCheckpoint.Ready,
                action = DiscoveryAssistantResumeAction.RunAssistant,
                questions = emptyList(),
                draftReview = null,
            ),
        ).also { providerDiscoveries[sessionId] = it }
    }

    override suspend fun recordProviderDiscoveryAssistantFailure(
        sessionId: String,
        kind: String,
        retryable: Boolean,
    ): ProviderDiscoverySnapshot = providerDiscoveries.getValue(sessionId)

    override suspend fun createProviderConnection(
        draft: ProviderConnectionDraft,
    ): ProviderConnection {
        providerMutationOrder += "core:create:${draft.id}"
        operationTrace?.add("core:create:${draft.id}")
        createConnectionError?.let { throw it }
        val connection = ProviderConnection(
            id = draft.id,
            templateId = draft.templateId,
            templateVersion = draft.templateVersion,
            displayName = draft.displayName,
            apiOrigin = draft.apiOrigin,
            apiBasePath = draft.apiBasePath,
            networkMode = draft.networkMode,
            values = draft.values,
            credentialSlotReady = draft.approvedCredentialOrigin != null,
            credentialScope = null,
            approvedCredentialOrigins = listOfNotNull(draft.approvedCredentialOrigin),
            timeoutSeconds = draft.timeoutSeconds,
            status = "untested",
            createdAt = "2026-01-01T00:00:00Z",
            updatedAt = "2026-01-01T00:00:00Z",
        )
        providerConnections.removeAll { it.id == connection.id }
        providerConnections += connection
        return connection
    }

    override suspend fun listProviderConnections(): List<ProviderConnection> =
        providerConnections.toList()

    override suspend fun upsertProviderConnection(
        connection: ProviderConnection,
    ): ProviderConnection {
        providerMutationOrder += "core:update:${connection.id}"
        operationTrace?.add("core:update:${connection.id}")
        updateConnectionError?.let { throw it }
        providerConnections.removeAll { it.id == connection.id }
        providerConnections += connection
        return connection
    }

    override suspend fun deleteProviderConnection(connectionId: String) {
        providerMutationOrder += "core:delete:$connectionId"
        operationTrace?.add("core:delete:$connectionId")
        deleteConnectionError?.let { throw it }
        providerConnections.removeAll { it.id == connectionId }
        val removedRouteIds = modelRoutes.remove(connectionId).orEmpty().map(ModelRoute::id)
        removedRouteIds.forEach { routeId ->
            generationPresets.remove(routeId)
            capabilityObservations.remove(routeId)
            effectiveCapabilities.keys.removeAll { it.first == routeId }
        }
        if (settings.selectedModelRouteId in removedRouteIds) {
            settings = settings.copy(
                selectedModelRouteId = null,
                selectedGenerationPresetId = null,
            )
        }
    }

    override suspend fun listModelRoutes(connectionId: String): List<ModelRoute> =
        modelRoutes[connectionId]?.toList().orEmpty()

    override suspend fun startProviderModelSync(
        connectionId: String,
        credential: String?,
    ): String {
        startProviderModelSyncCalls += 1
        lastCredential = credential
        val configured = nextStartedModelSyncJob
        val id = configured?.id ?: "model-sync-${modelSyncJobs.size + 1}"
        modelSyncJobs[id] = configured ?: ModelSyncJob(
                id = id,
                connectionId = connectionId,
                state = "created",
                revision = 0uL,
                review = null,
                failure = null,
                createdAt = "2026-01-01T00:00:00Z",
                updatedAt = "2026-01-01T00:00:00Z",
            )
        return id
    }

    override suspend fun getProviderModelSync(jobId: String): ModelSyncJob {
        getProviderModelSyncCalls += 1
        getProviderModelSyncError?.let { throw it }
        val queued = queuedModelSyncGetResponses[jobId]
        if (queued != null && queued.isNotEmpty()) {
            return queued.removeFirst().also { modelSyncJobs[jobId] = it }
        }
        return modelSyncJobs.getValue(jobId)
    }

    override suspend fun listProviderModelSyncs(
        connectionId: String,
        limit: UInt,
    ): List<ModelSyncJob> = modelSyncJobs.values
        .filter { it.connectionId == connectionId }
        .take(limit.toInt())

    override suspend fun approveProviderModelSync(
        jobId: String,
        reviewSha256: String,
    ): ModelSyncJob {
        approveProviderModelSyncCalls += 1
        val current = modelSyncJobs.getValue(jobId)
        require(current.review?.sha256 == reviewSha256)
        approveProviderModelSyncError?.let { error ->
            approveProviderModelSyncStateOnError?.let { state ->
                modelSyncJobs[jobId] = current.copy(
                    state = state,
                    revision = current.revision + 1uL,
                    failure = state.modelSyncFailureOrNull(),
                )
            }
            throw error
        }
        return current.copy(
            state = "completed",
            revision = current.revision + 1uL,
        ).also { modelSyncJobs[jobId] = it }
    }

    override suspend fun cancelProviderModelSync(jobId: String): ModelSyncJob {
        cancelProviderModelSyncCalls += 1
        val current = modelSyncJobs.getValue(jobId)
        cancelProviderModelSyncError?.let { error ->
            cancelProviderModelSyncStateOnError?.let { state ->
                modelSyncJobs[jobId] = current.copy(
                    state = state,
                    revision = current.revision + 1uL,
                    failure = state.modelSyncFailureOrNull(),
                )
            }
            throw error
        }
        return current.copy(
            state = "cancelled",
            revision = current.revision + 1uL,
        ).also { modelSyncJobs[jobId] = it }
    }

    override suspend fun pollProviderModelSyncJobEvents(
        jobId: String,
        limit: UInt,
    ): List<ModelSyncEvent> = buildList {
        val events = modelSyncEvents.getOrPut(jobId, ::ArrayDeque)
        repeat(minOf(limit.toInt(), events.size)) {
            add(events.removeFirst())
        }
    }

    override suspend fun ackProviderModelSyncEvent(jobId: String, sequence: ULong): Boolean {
        acknowledgedModelSyncEvents += jobId to sequence
        return true
    }

    override suspend fun providerCatalogStatus(): ProviderCatalogStatus {
        catalogError?.let { throw it }
        return catalogStatus
    }

    override suspend fun providerCatalogHistory(
        limit: UInt,
        beforeRevision: ULong?,
        beforeStateVersion: ULong?,
    ): ProviderCatalogHistory {
        catalogError?.let { throw it }
        return catalogHistory.copy(
            revisions = catalogHistory.revisions.take(limit.toInt()),
            activations = catalogHistory.activations.take(limit.toInt()),
        )
    }

    override suspend fun prepareSignedProviderCatalogImport(
        envelopeJson: ByteArray,
    ): ProviderCatalogImportPlan {
        catalogError?.let { throw it }
        lastPreparedCatalogBytes = envelopeJson.copyOf()
        return checkNotNull(catalogImportPlan) {
            "No synthetic catalog import plan was configured."
        }
    }

    override suspend fun activateSignedProviderCatalogImport(
        plan: ProviderCatalogImportPlan,
        envelopeJson: ByteArray,
    ): ProviderCatalogImportResult {
        catalogError?.let { throw it }
        check(plan == catalogImportPlan) { "Catalog plan changed after review." }
        check(envelopeJson.contentEquals(checkNotNull(lastPreparedCatalogBytes))) {
            "Catalog envelope changed after review."
        }
        lastActivatedCatalogPlan = plan
        lastActivatedCatalogBytes = envelopeJson.copyOf()
        catalogStatus = catalogStatus.copy(
            stateVersion = catalogStatus.stateVersion + 1uL,
            activeRevision = plan.review.candidateRevision,
            activeSnapshotSha256 = plan.review.candidateSnapshotSha256,
        )
        return ProviderCatalogImportResult(
            signedCatalogRevision = plan.review.signedCatalogRevision,
            activatedRevision = plan.review.candidateRevision,
            diff = plan.review.diff,
            status = catalogStatus,
        )
    }

    override suspend fun diffProviderCatalogRevisions(
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

    override suspend fun prepareProviderCatalogRollback(
        targetRevision: ULong,
    ): ProviderCatalogRollbackPlan {
        catalogError?.let { throw it }
        return checkNotNull(catalogRollbackPlan) {
            "No synthetic catalog rollback plan was configured."
        }.also { check(it.toRevision == targetRevision) }
    }

    override suspend fun activateProviderCatalogRollback(
        plan: ProviderCatalogRollbackPlan,
    ): ProviderCatalogRollbackResult {
        catalogError?.let { throw it }
        check(plan == catalogRollbackPlan) { "Catalog rollback plan changed after review." }
        lastActivatedRollbackPlan = plan
        catalogStatus = catalogStatus.copy(
            stateVersion = catalogStatus.stateVersion + 1uL,
            activeRevision = plan.toRevision,
        )
        return ProviderCatalogRollbackResult(
            fromRevision = plan.fromRevision,
            activatedRevision = plan.toRevision,
            status = catalogStatus,
        )
    }

    override suspend fun listGenerationPresets(modelRouteId: String): List<GenerationPreset> =
        generationPresets[modelRouteId]?.toList().orEmpty()

    override suspend fun upsertGenerationPreset(preset: GenerationPreset): GenerationPreset {
        upsertGenerationPresetCalls += 1
        val values = generationPresets.getOrPut(preset.modelRouteId, ::mutableListOf)
        values.removeAll { it.id == preset.id }
        values += preset
        return preset
    }

    override suspend fun validateGenerationPresetCandidate(preset: GenerationPreset) {
        validatePresetCandidateCalls += 1
        lastValidatedPresetCandidate = preset
        validatePresetCandidateError?.let { throw it }
        require(modelRoutes.values.flatten().any { it.id == preset.modelRouteId })
    }

    override suspend fun renderReasoningControlForPreset(
        preset: GenerationPreset,
    ): ReasoningControl {
        renderReasoningControlCalls += 1
        lastRenderedReasoningPresetCandidate = preset
        renderReasoningControlError?.let { throw it }
        return ReasoningControl(
            state = "ready",
            mode = preset.reasoningMode,
            effort = reasoningEffortOverride ?: preset.reasoningEffort,
            budgetTokens = preset.reasoningBudgetTokens,
            summary = preset.reasoningSummary,
            preserveOpaqueState =
                reasoningPreserveOpaqueOverride ?: preset.preserveOpaqueReasoningState,
            allowedModes = listOf("provider_default", "disabled", "automatic", "enabled"),
            allowedEfforts = listOf(
                "minimal",
                "low",
                "medium",
                "high",
                "extra_high",
                "maximum",
            ),
            allowedSummaries = listOf(
                "provider_default",
                "disabled",
                "automatic",
                "concise",
                "detailed",
            ),
            minimumBudgetTokens = 1u,
            maximumBudgetTokens = 32_768u,
            effortField = reasoningEffortFieldOverride ?: "enabled",
            budgetField = "enabled",
            summaryField = "enabled",
            issues = emptyList(),
        )
    }

    override suspend fun renderPromptCacheControlForPreset(
        preset: GenerationPreset,
    ): PromptCacheControl = PromptCacheControl(
        state = "ready",
        mode = preset.promptCacheMode,
        ttl = preset.promptCacheTtl,
        customTtlSeconds = preset.promptCacheCustomTtlSeconds,
        contextReference = preset.promptCacheContextReference,
        allowedModes = listOf(
            "provider_default",
            "automatic",
            "explicit_breakpoints",
            "explicit_context",
            "disabled_if_supported",
        ),
        allowedTtls = listOf("provider_default", "short", "long"),
        supportsCustomTtl = true,
        minimumCustomTtlSeconds = 1u,
        maximumCustomTtlSeconds = 86_400u,
        ttlField = "enabled",
        contextReferenceField = if (preset.promptCacheMode == "explicit_context") {
            "required"
        } else {
            "hidden"
        },
        issues = emptyList(),
    )

    override suspend fun previewProviderRequestCandidate(
        preset: GenerationPreset,
    ): RequestPreview {
        previewPresetCandidateCalls += 1
        lastPreviewPresetCandidate = preset
        validateGenerationPresetCandidate(preset)
        return requestPreview(preset.modelRouteId)
    }

    override suspend fun validateGenerationPreset(
        modelRouteId: String,
        generationPresetId: String,
    ) {
        require(generationPresets[modelRouteId]?.any { it.id == generationPresetId } == true)
    }

    override suspend fun previewProviderRequest(
        modelRouteId: String,
        generationPresetId: String,
    ): RequestPreview {
        validateGenerationPreset(modelRouteId, generationPresetId)
        return requestPreview(modelRouteId)
    }

    private fun requestPreview(modelRouteId: String): RequestPreview {
        val route = modelRoutes.values.flatten().first { it.id == modelRouteId }
        val connection = providerConnections.first { it.id == route.connectionId }
        return RequestPreview(
            redactionVersion = 1u,
            method = "POST",
            origin = connection.apiOrigin,
            path = route.routeConfig.endpointPath ?: "/v1/chat/completions",
            headerNames = listOf("authorization", "content-type"),
            queryParameterNames = emptyList(),
            bodyShape = RequestBodyShape.Object(
                fields = listOf(
                    RequestBodyField("model", RequestBodyShape.StringValue),
                    RequestBodyField(
                        "messages",
                        RequestBodyShape.Array(
                            items = listOf(RequestBodyShape.Object(emptyList(), false)),
                            truncated = false,
                        ),
                    ),
                ),
                truncated = false,
            ),
            bodyTruncated = false,
            includesPrivateMessage = false,
            includesCredentialValue = false,
            includesOpaqueReasoningState = false,
        )
    }

    override suspend fun deleteGenerationPreset(generationPresetId: String) {
        generationPresets.values.forEach { presets ->
            presets.removeAll { it.id == generationPresetId }
        }
        if (settings.selectedGenerationPresetId == generationPresetId) {
            settings = settings.copy(
                selectedModelRouteId = null,
                selectedGenerationPresetId = null,
            )
        }
    }

    override suspend fun listCapabilityObservations(
        modelRouteId: String,
    ): List<CapabilityObservation> =
        capabilityObservations[modelRouteId]?.toList().orEmpty()

    override suspend fun effectiveCapability(
        modelRouteId: String,
        key: String,
    ): EffectiveCapability? = effectiveCapabilities[modelRouteId to key]

    override suspend fun effectiveParameterSpecs(modelRouteId: String): List<ParameterSpec> {
        val route = modelRoutes.values.flatten().firstOrNull { it.id == modelRouteId }
            ?: return emptyList()
        val connection = providerConnections.firstOrNull { it.id == route.connectionId }
            ?: return emptyList()
        return providerTemplates.firstOrNull {
            it.id == connection.templateId && it.manifestVersion == connection.templateVersion
        }?.parameters.orEmpty()
    }

    override suspend fun selectGenerationTarget(target: GenerationTarget?): AppSettings {
        settings = settings.copy(
            selectedProviderProfileId = null,
            selectedModelRouteId = target?.modelRouteId,
            selectedGenerationPresetId = target?.generationPresetId,
        )
        return settings
    }

    override fun close() {
        closed = true
    }
}

private fun syntheticDiscoverySnapshot(
    input: ProviderDiscoveryInput,
    template: ProviderTemplate?,
): ProviderDiscoverySnapshot {
    val manifestSha256 = "b".repeat(64)
    val review = syntheticDiscoveryReview()
    val reviewProposal = syntheticDiscoveryReviewProposal(review)
    val credentialProposal = template
        ?.takeIf { it.requiresCredential && input.credentialSlotReady }
        ?.let {
            DiscoveryApprovalProposal(
                approvalId = "approval-credential-${input.connectionId}",
                grant = DiscoveryApprovalGrant.CredentialOrigin(
                    origin = checkNotNull(it.defaultApiOrigin),
                    authBinding = it.authBinding,
                    manifestSha256 = manifestSha256,
                ),
                grantSha256 = "c".repeat(64),
            )
        }
    val state = when {
        credentialProposal != null -> "awaiting_credential_origin_approval"
        template != null -> "awaiting_review"
        else -> "awaiting_template_selection"
    }
    return ProviderDiscoverySnapshot(
        snapshotSchemaVersion = 3u,
        sessionId = "discovery-${input.connectionId}",
        pendingConnectionId = input.connectionId,
        pendingDisplayName = input.displayName,
        connectionOptions = input.connectionOptions,
        credentialSlotId = input.connectionId.takeIf { input.credentialSlotReady },
        credentialSlotExpected = input.credentialSlotReady,
        revision = 1uL,
        state = state,
        nextEventSequence = 1uL,
        steps = listOf(
            DiscoveryStep("input", "provider.discovery.input", "completed"),
            DiscoveryStep(
                "review",
                "provider.discovery.review",
                if (state == "awaiting_review") "current" else "pending",
            ),
        ),
        actionRequired = when (state) {
            "awaiting_credential_origin_approval" ->
                DiscoveryActionRequired.ApproveCredentialOrigin
            "awaiting_review" -> DiscoveryActionRequired.Review
            else -> DiscoveryActionRequired.SelectTemplate
        },
        activeOperationId = null,
        recoveryOperation = null,
        unknownOperation = null,
        manifestSha256 = manifestSha256,
        commitPlanSha256 = reviewProposal.commitPlanSha256,
        commitAttemptId = reviewProposal.commitAttemptId,
        committedConnectionId = null,
        cancellationPending = false,
        failure = null,
        candidates = template?.let {
            listOf(
                DiscoveryCandidate(
                    id = "candidate-${it.id}",
                    proposedRevision = 1uL,
                    summary = DiscoveryCandidateSummary.ProviderTemplate(
                        it.id,
                        it.manifestVersion,
                    ),
                    evidenceIds = emptyList(),
                    createdAt = "2026-01-01T00:00:00Z",
                ),
            )
        }.orEmpty(),
        evidence = emptyList(),
        approvals = emptyList(),
        approvalProposal = credentialProposal,
        review = review.takeIf { state == "awaiting_review" },
        reviewProposal = reviewProposal.takeIf { state == "awaiting_review" },
        createdAt = "2026-01-01T00:00:00Z",
        updatedAt = "2026-01-01T00:00:00Z",
    )
}

private fun syntheticDiscoveryReview(): DiscoveryReview = DiscoveryReview(
    sha256 = "d".repeat(64),
    graphSha256 = "e".repeat(64),
    changes = listOf(
        DiscoveryReviewChange(
            kind = "add",
            targetKind = "provider_connection",
            targetId = "pending",
            summaryKey = "provider.discovery.review.add_connection",
            evidenceIds = emptyList(),
        ),
    ),
    unresolvedQuestionCount = 0u,
    warningCount = 0u,
)

private fun syntheticDiscoveryReviewProposal(
    review: DiscoveryReview,
): DiscoveryReviewProposal = DiscoveryReviewProposal(
    review = review,
    approval = DiscoveryApprovalProposal(
        approvalId = "approval-review",
        grant = DiscoveryApprovalGrant.Review(
            reviewSha256 = review.sha256,
            graphSha256 = review.graphSha256,
        ),
        grantSha256 = "f".repeat(64),
    ),
    commitAttemptId = "00000000-0000-4000-8000-000000000001",
    commitPlanSha256 = "1".repeat(64),
    requestPreview = RequestPreview(
        redactionVersion = 1u,
        method = "POST",
        origin = "https://api.example.invalid",
        path = "/v1/chat/completions",
        headerNames = listOf("authorization", "content-type"),
        queryParameterNames = emptyList(),
        bodyShape = RequestBodyShape.Object(emptyList(), false),
        bodyTruncated = false,
        includesPrivateMessage = false,
        includesCredentialValue = false,
        includesOpaqueReasoningState = false,
    ),
)

private fun syntheticCredentialCompensationStep(
    snapshot: ProviderDiscoverySnapshot,
    attemptId: String,
): DiscoveryCompensationStep = DiscoveryCompensationStep(
    id = "credential-compensation-${snapshot.pendingConnectionId}",
    commitAttemptId = attemptId,
    ordinal = 2u,
    actionId = "credential-compensation-action",
    kind = DiscoveryCompensationKind.RemoveCredentialSlot,
    target = DiscoveryCompensationTarget.RemoveCredentialSlot(
        connectionId = snapshot.pendingConnectionId,
        credentialRef = snapshot.pendingConnectionId,
    ),
    status = DiscoveryCompensationStatus.Pending,
    attemptCount = 0u,
    lastFailure = null,
    createdAt = "2026-01-01T00:00:00Z",
    updatedAt = "2026-01-01T00:00:00Z",
    completedAt = null,
)

private fun ProviderDiscoverySnapshot.afterFakeDiscoveryAction(
    action: ProviderDiscoveryAction,
    preferredAssistantModelRouteId: String?,
): ProviderDiscoverySnapshot {
    val nextRevision = revision + 1uL
    return when (action) {
        is ProviderDiscoveryAction.ApproveCredentialOrigin -> {
            val review = syntheticDiscoveryReview()
            copy(
                revision = nextRevision,
                state = "awaiting_review",
                actionRequired = DiscoveryActionRequired.Review,
                approvalProposal = null,
                review = review,
                reviewProposal = syntheticDiscoveryReviewProposal(review),
            )
        }
        is ProviderDiscoveryAction.ApproveReview -> copy(
            revision = nextRevision,
            state = "committing",
            actionRequired = null,
            approvalProposal = null,
        )
        is ProviderDiscoveryAction.SelectTemplate,
        ProviderDiscoveryAction.ContinueWithoutTemplate,
        -> copy(
            revision = nextRevision,
            state = "awaiting_more_evidence",
            actionRequired = DiscoveryActionRequired.SupplyMoreEvidence,
        )
        ProviderDiscoveryAction.RequestAssistant -> copy(
            revision = nextRevision,
            state = "awaiting_assistant_consent",
            actionRequired = DiscoveryActionRequired.ApproveAssistant,
            approvalProposal = DiscoveryApprovalProposal(
                approvalId = "assistant-approval",
                grant = DiscoveryApprovalGrant.AssistantConsent(
                    assistantModelRouteId = checkNotNull(preferredAssistantModelRouteId),
                    evidenceIds = evidence.map(DiscoveryEvidence::id),
                    allowedDocumentOrigins = listOf("https://docs.example.invalid"),
                    maxCalls = 2u,
                    maxInputTokens = 1_024u,
                    maxOutputTokens = 512u,
                    maxToolCalls = 4u,
                    maxRetries = 1u,
                    maxCostMicroUnits = 10_000uL,
                ),
                grantSha256 = "9".repeat(64),
            ),
            assistantResumeBoundary = DiscoveryAssistantResumeBoundary(
                checkpoint = null,
                action = DiscoveryAssistantResumeAction.ApproveConsent,
                questions = emptyList(),
                draftReview = null,
            ),
        )
        ProviderDiscoveryAction.DeclineAssistant,
        ProviderDiscoveryAction.SkipProbes,
        -> copy(
            revision = nextRevision,
            state = "awaiting_more_evidence",
            actionRequired = DiscoveryActionRequired.SupplyMoreEvidence,
        )
        ProviderDiscoveryAction.Cancel -> copy(
            revision = nextRevision,
            state = "cancelled",
            actionRequired = null,
        )
        ProviderDiscoveryAction.ResumeCompensation -> copy(
            revision = nextRevision,
            failure = null,
        )
        ProviderDiscoveryAction.RestartInterrupted -> copy(
            revision = nextRevision,
            state = "awaiting_more_evidence",
            actionRequired = DiscoveryActionRequired.SupplyMoreEvidence,
        )
        is ProviderDiscoveryAction.ApproveAssistant -> {
            val proposal = checkNotNull(approvalProposal)
            copy(
                revision = nextRevision,
                state = "building_assistant_manifest_draft",
                actionRequired = null,
                approvals = approvals + DiscoveryApproval(
                    id = proposal.approvalId,
                    sessionRevision = nextRevision,
                    decision = "approved",
                    grant = proposal.grant,
                    createdAt = "2026-01-01T00:00:00Z",
                ),
                approvalProposal = null,
                assistantResumeBoundary = DiscoveryAssistantResumeBoundary(
                    checkpoint = DiscoveryAssistantCheckpoint.Ready,
                    action = DiscoveryAssistantResumeAction.RunAssistant,
                    questions = emptyList(),
                    draftReview = null,
                ),
            )
        }
        is ProviderDiscoveryAction.ApproveProbes,
        is ProviderDiscoveryAction.ResolveUnknownOutcome,
        is ProviderDiscoveryAction.SupplyMoreEvidence,
        -> copy(revision = nextRevision)
    }
}

private fun String.modelSyncFailureOrNull(): ModelSyncFailure? =
    if (this == "failed") {
        ModelSyncFailure(
            code = "internal",
            messageKey = "model_sync.failed",
            recoverable = true,
        )
    } else {
        null
    }

class FakeCredentialStore(
    private val operationTrace: MutableList<String>? = null,
) : CredentialStore {
    val values = mutableMapOf<String, String>()
    val operations = mutableListOf<String>()
    var readError: Throwable? = null
    var inspectError: Throwable? = null
    var writeError: Throwable? = null
    var deleteError: Throwable? = null

    override suspend fun read(credentialRef: String): String? {
        operations += "credential:read:$credentialRef"
        operationTrace?.add("credential:read:$credentialRef")
        readError?.let { throw it }
        return values[credentialRef]
    }

    override suspend fun inspect(credentialRef: String): CredentialRecordStatus {
        inspectError?.let { throw it }
        return if (values.containsKey(credentialRef)) {
            CredentialRecordStatus.Available
        } else {
            CredentialRecordStatus.Missing
        }
    }

    override suspend fun write(credentialRef: String, credential: String) {
        operations += "credential:write:$credentialRef"
        operationTrace?.add("credential:write:$credentialRef")
        writeError?.let { throw it }
        values[credentialRef] = credential
    }

    override suspend fun writeBytes(credentialRef: String, credential: ByteArray) {
        write(credentialRef, credential.toString(Charsets.UTF_8))
    }

    override suspend fun delete(credentialRef: String) {
        operations += "credential:delete:$credentialRef"
        operationTrace?.add("credential:delete:$credentialRef")
        deleteError?.let { throw it }
        values.remove(credentialRef)
    }
}

fun healthyCoreStatus(): CoreHealthStatus = CoreHealthStatus(
    coreVersion = "test-core",
    databaseOpen = true,
    schemaVersion = 1,
    dataRootWritable = true,
    stagingWritable = true,
    recoveryPending = false,
    activeJobs = 0,
)

fun syntheticCharacter(id: String = "character-1"): CharacterSummary = CharacterSummary(
    id = id,
    name = "합성 캐릭터",
    description = "테스트 전용 합성 설명",
    sourceHash = "a".repeat(64),
)

fun syntheticInspection(): ImportInspection = ImportInspection(
    id = "inspection-1",
    contentKind = "charx",
    displayName = "합성 캐릭터",
    description = "테스트 전용 합성 설명",
    sourceSha256 = "a".repeat(64),
    sourceSize = 128u,
    estimatedStoredSize = 256u,
    assetCount = 1u,
    warnings = emptyList(),
    blockedReasons = emptyList(),
    isAllowed = true,
    representativeImage = ImportImagePreview(
        logicalAssetId = "assets/avatar.png",
        mediaType = "image/png",
        sizeBytes = 70u,
    ),
    unsupportedOptionalFields = listOf("alternate_greetings", "creator"),
)

fun syntheticCatalogStatus(): ProviderCatalogStatus = ProviderCatalogStatus(
    statusSchemaVersion = 1u,
    stateVersion = 1uL,
    activeRevision = 1uL,
    activeSnapshotSha256 = "a".repeat(64),
    bundledBaselineSha256 = "a".repeat(64),
    snapshotCount = 1u,
    signedUpdateCount = 0u,
    highestAcceptedRevision = 0uL,
    latestIssuedAt = null,
    activeSignedRevisions = emptyList(),
)

fun syntheticCatalogHistory(): ProviderCatalogHistory = ProviderCatalogHistory(
    historySchemaVersion = 1u,
    activeRevision = 1uL,
    revisions = emptyList(),
    activations = emptyList(),
    nextBeforeRevision = null,
    nextBeforeStateVersion = null,
)
