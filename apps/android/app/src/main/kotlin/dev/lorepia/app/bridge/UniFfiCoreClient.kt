package dev.lorepia.app.bridge

import dev.lorepia.core.*
import dev.lorepia.core.coreVersion as ffiCoreVersion
import dev.lorepia.core.versionInfo as ffiVersionInfo
import java.io.File
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Thin coroutine-friendly adapter around the generated UniFFI API.
 *
 * This class deliberately performs no product logic. The generated source is
 * supplied by `bindings/uniffi` and remains read-only.
 */
class UniFfiCoreClient private constructor(
    private val core: LorepiaCore,
    private val ioDispatcher: CoroutineDispatcher,
) : CoreClient {
    override suspend fun coreVersion(): String = onIo { ffiCoreVersion() }

    override suspend fun versionInfo(): CoreVersionInfo = onIo {
        val info = ffiVersionInfo()
        CoreVersionInfo(
            coreVersion = info.coreVersion,
            coreApiVersion = info.coreApiVersion,
            bindingApiVersion = info.bindingApiVersion,
            chatEventVersion = info.chatEventVersion,
        )
    }

    override suspend fun healthCheck(): CoreHealthStatus = onIo {
        val report = core.healthCheck()
        CoreHealthStatus(
            coreVersion = report.coreVersion,
            databaseOpen = report.databaseOpen,
            schemaVersion = report.schemaVersion.toLong(),
            dataRootWritable = report.dataRootWritable,
            stagingWritable = report.stagingWritable,
            recoveryPending = report.recoveryPending,
            activeJobs = report.activeJobs.toLong(),
        )
    }

    override suspend fun databaseStats(): DatabaseStats = onIo {
        val stats = core.databaseStats()
        DatabaseStats(
            characters = stats.characters,
            conversations = stats.conversations,
            messages = stats.messages,
            pendingImports = stats.pendingImports,
        )
    }

    override suspend fun listCharacters(): List<CharacterSummary> =
        onIo { core.listCharacters().map(FfiCharacter::toAppModel) }

    override suspend fun getCharacter(characterId: String): CharacterSummary = onIo {
        requireNotBlank(characterId, "character ID")
        core.getCharacter(characterId).toAppModel()
    }

    override suspend fun inspectImport(stagedPath: String): ImportInspection = onIo {
        require(File(stagedPath).isAbsolute) { "The staged import path must be absolute." }
        core.inspectImport(stagedPath).toAppModel()
    }

    override suspend fun commitImport(inspectionId: String): CharacterSummary = onIo {
        requireNotBlank(inspectionId, "inspection ID")
        core.commitImport(inspectionId).toAppModel()
    }

    override suspend fun discardImport(inspectionId: String) = onIo {
        requireNotBlank(inspectionId, "inspection ID")
        core.discardImport(inspectionId)
    }

    override suspend fun listConversations(): List<ConversationSummary> =
        onIo { core.listConversations().map(FfiConversation::toAppModel) }

    override suspend fun openConversation(characterId: String): ConversationSummary = onIo {
        requireNotBlank(characterId, "character ID")
        core.openConversation(characterId).toAppModel()
    }

    override suspend fun listMessages(conversationId: String): List<ChatMessage> = onIo {
        requireNotBlank(conversationId, "conversation ID")
        core.listMessages(conversationId).map(FfiMessage::toAppModel)
    }

    override suspend fun sendMessage(
        conversationId: String,
        text: String,
        providerProfileId: String,
        credential: String?,
    ): String = onIo {
        requireNotBlank(conversationId, "conversation ID")
        require(text.isNotBlank()) { "The message must not be blank." }
        requireNotBlank(providerProfileId, "provider profile ID")
        core.sendMessage(
            conversationId = conversationId,
            text = text,
            providerProfileId = providerProfileId,
            credential = credential?.takeIf(String::isNotBlank),
        )
    }

    override suspend fun sendMessageWithTarget(
        conversationId: String,
        text: String,
        target: GenerationTarget,
        credential: String?,
    ): String = onIo {
        requireNotBlank(conversationId, "conversation ID")
        require(text.isNotBlank()) { "The message must not be blank." }
        core.sendMessageWithTarget(
            conversationId = conversationId,
            text = text,
            target = target.toFfiModel(),
            credential = credential?.takeIf(String::isNotBlank),
        )
    }

    override suspend fun cancelGeneration(generationId: String) = onIo {
        requireNotBlank(generationId, "generation ID")
        core.cancelGeneration(generationId)
    }

    override suspend fun pollEvents(maxEvents: UInt): ChatEventBatch = onIo {
        require(maxEvents in 1u..256u) { "Event batch size must be between 1 and 256." }
        val batch = core.pollEvents(maxEvents)
        ChatEventBatch(
            events = batch.events.map(FfiChatEvent::toAppModel),
            droppedEventCount = batch.droppedEventCount,
        )
    }

    override suspend fun getSettings(): AppSettings =
        onIo { core.getSettings().toAppModel() }

    override suspend fun updateSettings(settings: AppSettings): AppSettings = onIo {
        core.updateSettings(settings.toFfiModel()).toAppModel()
    }

    override suspend fun listProviderProfiles(): List<ProviderProfile> =
        onIo { core.listProviderProfiles().map(FfiProviderProfile::toAppModel) }

    override suspend fun upsertProviderProfile(profile: ProviderProfile): ProviderProfile = onIo {
        core.upsertProviderProfile(profile.toFfiModel()).toAppModel()
    }

    override suspend fun deleteProviderProfile(profileId: String) = onIo {
        requireNotBlank(profileId, "provider profile ID")
        core.deleteProviderProfile(profileId)
    }

    override suspend fun listProviderTemplates(): List<ProviderTemplate> =
        onIo { core.listProviderTemplates().map(FfiProviderTemplate::toAppModel) }

    override suspend fun inspectProviderCurl(
        rawCurl: String,
        networkPolicy: ProviderNetworkPolicy,
    ): ProviderCurlInspection = onIo {
        require(rawCurl.isNotBlank()) { "The cURL input must not be blank." }
        core.inspectProviderCurl(rawCurl, networkPolicy.toFfiModel()).toAppModel()
    }

    override suspend fun takeProviderCurlCredential(
        credentialHandoffId: String,
    ): ByteArray? = onIo {
        requireNotBlank(credentialHandoffId, "cURL credential handoff ID")
        core.takeProviderCurlCredential(credentialHandoffId)
    }

    override suspend fun beginProviderDiscovery(
        input: ProviderDiscoveryInput,
        source: ProviderDiscoverySource,
        rawCurl: String?,
    ): ProviderDiscoverySnapshot = onIo {
        core.beginProviderDiscovery(
            input.toFfiModel(),
            source.toFfiModel(),
            rawCurl,
        ).toAppModel()
    }

    override suspend fun prepareProviderDiscoveryAction(
        actionId: String,
        expectedRevision: ULong,
        action: ProviderDiscoveryAction,
    ): ProviderDiscoveryActionEnvelope = onIo {
        requireNotBlank(actionId, "provider discovery action ID")
        core.prepareProviderDiscoveryAction(
            actionId,
            expectedRevision,
            action.toFfiModel(),
        ).toAppModel()
    }

    override suspend fun getProviderDiscovery(
        sessionId: String,
    ): ProviderDiscoverySnapshot = onIo {
        requireNotBlank(sessionId, "provider discovery session ID")
        core.getProviderDiscovery(sessionId).toAppModel()
    }

    override suspend fun listProviderDiscoveries(
        limit: UInt,
    ): List<ProviderDiscoverySnapshot> = onIo {
        require(limit in 1u..100u) {
            "Provider discovery history limit must be between 1 and 100."
        }
        core.listProviderDiscoveries(limit).map(FfiProviderDiscoverySnapshot::toAppModel)
    }

    override suspend fun continueProviderDiscovery(
        sessionId: String,
        envelope: ProviderDiscoveryActionEnvelope,
        credential: String?,
    ): ProviderDiscoverySnapshot = onIo {
        requireNotBlank(sessionId, "provider discovery session ID")
        core.continueProviderDiscovery(
            sessionId,
            envelope.toFfiModel(),
            credential,
        ).toAppModel()
    }

    override suspend fun supplyProviderDiscoveryDocumentEvidence(
        sessionId: String,
        expectedRevision: ULong,
        documentUrl: String,
    ): ProviderDiscoverySnapshot = onIo {
        requireNotBlank(sessionId, "provider discovery session ID")
        require(documentUrl.isNotBlank()) { "The discovery document URL must not be blank." }
        core.supplyProviderDiscoveryDocumentEvidence(
            sessionId,
            expectedRevision,
            documentUrl,
        ).toAppModel()
    }

    override suspend fun supplyProviderDiscoveryCurlEvidence(
        sessionId: String,
        expectedRevision: ULong,
        rawCurl: String,
    ): ProviderDiscoverySnapshot = onIo {
        requireNotBlank(sessionId, "provider discovery session ID")
        require(rawCurl.isNotBlank()) { "The discovery cURL evidence must not be blank." }
        core.supplyProviderDiscoveryCurlEvidence(
            sessionId,
            expectedRevision,
            rawCurl,
        ).toAppModel()
    }

    override suspend fun cancelProviderDiscovery(
        sessionId: String,
        expectedRevision: ULong,
    ): ProviderDiscoverySnapshot = onIo {
        requireNotBlank(sessionId, "provider discovery session ID")
        core.cancelProviderDiscovery(sessionId, expectedRevision).toAppModel()
    }

    override suspend fun commitProviderDiscovery(
        sessionId: String,
        credentialReferenceConfirmed: Boolean,
    ): ProviderConnection = onIo {
        requireNotBlank(sessionId, "provider discovery session ID")
        core.commitProviderDiscovery(sessionId, credentialReferenceConfirmed).toAppModel()
    }

    override suspend fun listProviderDiscoveryCompensationSteps(
        commitAttemptId: String,
    ): List<DiscoveryCompensationStep> = onIo {
        requireNotBlank(commitAttemptId, "provider discovery commit attempt ID")
        core.listProviderDiscoveryCompensationSteps(commitAttemptId)
            .map(FfiDiscoveryCompensationStep::toAppModel)
    }

    override suspend fun continueProviderDiscoveryCompensation(
        sessionId: String,
    ): ProviderDiscoverySnapshot = onIo {
        requireNotBlank(sessionId, "provider discovery session ID")
        core.continueProviderDiscoveryCompensation(sessionId).toAppModel()
    }

    override suspend fun startProviderDiscoveryCredentialCompensation(
        sessionId: String,
        stepId: String,
    ): DiscoveryCompensationStep = onIo {
        requireNotBlank(sessionId, "provider discovery session ID")
        requireNotBlank(stepId, "provider discovery compensation step ID")
        core.startProviderDiscoveryCredentialCompensation(sessionId, stepId).toAppModel()
    }

    override suspend fun completeProviderDiscoveryCredentialCompensation(
        sessionId: String,
        stepId: String,
    ): ProviderDiscoverySnapshot = onIo {
        requireNotBlank(sessionId, "provider discovery session ID")
        requireNotBlank(stepId, "provider discovery compensation step ID")
        core.completeProviderDiscoveryCredentialCompensation(sessionId, stepId).toAppModel()
    }

    override suspend fun failProviderDiscoveryCredentialCompensation(
        sessionId: String,
        stepId: String,
        failure: DiscoveryFailure,
    ): ProviderDiscoverySnapshot = onIo {
        requireNotBlank(sessionId, "provider discovery session ID")
        requireNotBlank(stepId, "provider discovery compensation step ID")
        core.failProviderDiscoveryCredentialCompensation(
            sessionId,
            stepId,
            failure.toFfiModel(),
        ).toAppModel()
    }

    override suspend fun markProviderDiscoveryCredentialCompensationUnknown(
        sessionId: String,
        stepId: String,
    ): ProviderDiscoverySnapshot = onIo {
        requireNotBlank(sessionId, "provider discovery session ID")
        requireNotBlank(stepId, "provider discovery compensation step ID")
        core.markProviderDiscoveryCredentialCompensationUnknown(sessionId, stepId).toAppModel()
    }

    override suspend fun resumeProviderDiscoveryCompensation(
        sessionId: String,
    ): ProviderDiscoverySnapshot = onIo {
        requireNotBlank(sessionId, "provider discovery session ID")
        core.resumeProviderDiscoveryCompensation(sessionId).toAppModel()
    }

    override suspend fun recoverProviderDiscoveries(): List<DiscoveryRecoveryResult> =
        onIo {
            core.recoverProviderDiscoveries().map(FfiDiscoveryRecoveryResult::toAppModel)
        }

    override suspend fun pollProviderDiscoveryEvents(
        limit: UInt,
    ): List<DiscoveryOutboxEvent> = onIo {
        require(limit in 1u..256u) {
            "Provider discovery event batch size must be between 1 and 256."
        }
        core.pollProviderDiscoveryEvents(limit).map(FfiDiscoveryOutboxEvent::toAppModel)
    }

    override suspend fun ackProviderDiscoveryEvent(eventId: String): Boolean = onIo {
        requireNotBlank(eventId, "provider discovery event ID")
        core.ackProviderDiscoveryEvent(eventId)
    }

    override suspend fun runProviderDiscoveryAssistantTurn(
        sessionId: String,
        estimate: DiscoveryAssistantCallEstimate,
        assistantCredential: String?,
    ): DiscoveryAssistantOutcome = onIo {
        requireNotBlank(sessionId, "provider discovery session ID")
        val action = core.runProviderDiscoveryAssistantTurn(
            sessionId = sessionId,
            estimate = FfiDiscoveryAssistantCallEstimate(
                inputTokens = estimate.inputTokens,
                maximumOutputTokens = estimate.maximumOutputTokens,
                maximumCostMicroUnits = estimate.maximumCostMicroUnits,
            ),
            assistantCredential = assistantCredential,
        )
        when (action) {
            is FfiDiscoveryAssistantHostAction.RequestMoreEvidence -> {
                check(action.sessionId == sessionId) {
                    "Provider discovery assistant returned questions for another session."
                }
                DiscoveryAssistantOutcome.MoreEvidenceRequired(
                    sessionId = action.sessionId,
                    questions = action.questions.map(
                        FfiDiscoveryAssistantQuestion::toAppModel,
                    ),
                )
            }
            is FfiDiscoveryAssistantHostAction.ReviewDraft ->
                DiscoveryAssistantOutcome.DraftReadyForReview(
                    review = action.review.toAppModel(),
                )
        }
    }

    override suspend fun approveProviderDiscoveryAssistantRetry(
        sessionId: String,
    ): ProviderDiscoverySnapshot = onIo {
        requireNotBlank(sessionId, "provider discovery session ID")
        core.approveProviderDiscoveryAssistantRetry(sessionId).toAppModel()
    }

    override suspend fun requestProviderDiscoveryAssistantRevision(
        sessionId: String,
    ): ProviderDiscoverySnapshot = onIo {
        requireNotBlank(sessionId, "provider discovery session ID")
        core.requestProviderDiscoveryAssistantRevision(sessionId).toAppModel()
    }

    override suspend fun acceptProviderDiscoveryAssistantDraft(
        sessionId: String,
    ): ProviderDiscoverySnapshot = onIo {
        requireNotBlank(sessionId, "provider discovery session ID")
        core.acceptProviderDiscoveryAssistantDraft(sessionId).toAppModel()
    }

    override suspend fun resumeProviderDiscoveryAssistantCoreHostAction(
        sessionId: String,
    ): ProviderDiscoverySnapshot = onIo {
        requireNotBlank(sessionId, "provider discovery session ID")
        core.resumeProviderDiscoveryAssistantCoreHostAction(sessionId).toAppModel()
    }

    override suspend fun recordProviderDiscoveryAssistantFailure(
        sessionId: String,
        kind: String,
        retryable: Boolean,
    ): ProviderDiscoverySnapshot = onIo {
        requireNotBlank(sessionId, "provider discovery session ID")
        core.recordProviderDiscoveryAssistantFailure(sessionId, kind, retryable).toAppModel()
    }

    override suspend fun createProviderConnection(
        draft: ProviderConnectionDraft,
    ): ProviderConnection = onIo {
        core.createProviderConnection(draft.toFfiModel()).toAppModel()
    }

    override suspend fun listProviderConnections(): List<ProviderConnection> =
        onIo { core.listProviderConnections().map(FfiProviderConnection::toAppModel) }

    override suspend fun upsertProviderConnection(
        connection: ProviderConnection,
    ): ProviderConnection = onIo {
        core.upsertProviderConnection(connection.toFfiModel()).toAppModel()
    }

    override suspend fun deleteProviderConnection(connectionId: String) = onIo {
        requireNotBlank(connectionId, "provider connection ID")
        core.deleteProviderConnection(connectionId)
    }

    override suspend fun listModelRoutes(connectionId: String): List<ModelRoute> = onIo {
        requireNotBlank(connectionId, "provider connection ID")
        core.listModelRoutes(connectionId).map(FfiModelRoute::toAppModel)
    }

    override suspend fun startProviderModelSync(
        connectionId: String,
        credential: String?,
    ): String = onIo {
        requireNotBlank(connectionId, "provider connection ID")
        core.startProviderModelSync(
            connectionId,
            credential?.takeIf(String::isNotBlank),
        )
    }

    override suspend fun getProviderModelSync(jobId: String): ModelSyncJob = onIo {
        requireNotBlank(jobId, "model sync job ID")
        core.getProviderModelSync(jobId).toAppModel()
    }

    override suspend fun listProviderModelSyncs(
        connectionId: String,
        limit: UInt,
    ): List<ModelSyncJob> = onIo {
        requireNotBlank(connectionId, "provider connection ID")
        require(limit in 1u..100u) { "Model sync history limit must be between 1 and 100." }
        core.listProviderModelSyncs(connectionId, limit).map(FfiModelSyncJob::toAppModel)
    }

    override suspend fun approveProviderModelSync(
        jobId: String,
        reviewSha256: String,
    ): ModelSyncJob = onIo {
        requireNotBlank(jobId, "model sync job ID")
        require(reviewSha256.matches(Regex("[0-9a-f]{64}"))) {
            "The model sync review hash must be lowercase SHA-256."
        }
        core.approveProviderModelSync(jobId, reviewSha256).toAppModel()
    }

    override suspend fun cancelProviderModelSync(jobId: String): ModelSyncJob = onIo {
        requireNotBlank(jobId, "model sync job ID")
        core.cancelProviderModelSync(jobId).toAppModel()
    }

    override suspend fun pollProviderModelSyncJobEvents(
        jobId: String,
        limit: UInt,
    ): List<ModelSyncEvent> = onIo {
        requireNotBlank(jobId, "model sync job ID")
        require(limit in 1u..256u) {
            "Model sync event batch size must be between 1 and 256."
        }
        core.pollProviderModelSyncJobEvents(jobId, limit)
            .map(FfiModelSyncEvent::toAppModel)
    }

    override suspend fun ackProviderModelSyncEvent(
        jobId: String,
        sequence: ULong,
    ): Boolean = onIo {
        requireNotBlank(jobId, "model sync job ID")
        core.ackProviderModelSyncEvent(jobId, sequence)
    }

    override suspend fun providerCatalogStatus(): ProviderCatalogStatus =
        onIo { core.providerCatalogStatus().toAppModel() }

    override suspend fun providerCatalogHistory(
        limit: UInt,
        beforeRevision: ULong?,
        beforeStateVersion: ULong?,
    ): ProviderCatalogHistory = onIo {
        require(limit in 1u..100u) {
            "Provider catalog history limit must be between 1 and 100."
        }
        core.providerCatalogHistory(limit, beforeRevision, beforeStateVersion).toAppModel()
    }

    override suspend fun prepareSignedProviderCatalogImport(
        envelopeJson: ByteArray,
    ): ProviderCatalogImportPlan = onIo {
        require(envelopeJson.isNotEmpty()) { "The signed catalog file must not be empty." }
        core.prepareSignedProviderCatalogImport(envelopeJson).toAppModel()
    }

    override suspend fun activateSignedProviderCatalogImport(
        plan: ProviderCatalogImportPlan,
        envelopeJson: ByteArray,
    ): ProviderCatalogImportResult = onIo {
        require(envelopeJson.isNotEmpty()) { "The signed catalog file must not be empty." }
        core.activateSignedProviderCatalogImport(plan.toFfiModel(), envelopeJson).toAppModel()
    }

    override suspend fun prepareProviderCatalogRollback(
        targetRevision: ULong,
    ): ProviderCatalogRollbackPlan =
        onIo { core.prepareProviderCatalogRollback(targetRevision).toAppModel() }

    override suspend fun diffProviderCatalogRevisions(
        fromRevision: ULong,
        toRevision: ULong,
    ): ProviderCatalogDiff =
        onIo { core.diffProviderCatalogRevisions(fromRevision, toRevision).toAppModel() }

    override suspend fun activateProviderCatalogRollback(
        plan: ProviderCatalogRollbackPlan,
    ): ProviderCatalogRollbackResult =
        onIo { core.activateProviderCatalogRollback(plan.toFfiModel()).toAppModel() }

    override suspend fun listGenerationPresets(
        modelRouteId: String,
    ): List<GenerationPreset> = onIo {
        requireNotBlank(modelRouteId, "model route ID")
        core.listGenerationPresets(modelRouteId).map(FfiGenerationPreset::toAppModel)
    }

    override suspend fun upsertGenerationPreset(
        preset: GenerationPreset,
    ): GenerationPreset = onIo {
        core.upsertGenerationPreset(preset.toFfiModel()).toAppModel()
    }

    override suspend fun validateGenerationPresetCandidate(
        preset: GenerationPreset,
    ) = onIo {
        core.validateGenerationPresetCandidate(preset.toFfiModel())
    }

    override suspend fun renderReasoningControlForPreset(
        preset: GenerationPreset,
    ): ReasoningControl = onIo {
        core.renderReasoningControlForPreset(preset.toFfiModel()).toAppModel()
    }

    override suspend fun renderPromptCacheControlForPreset(
        preset: GenerationPreset,
    ): PromptCacheControl = onIo {
        core.renderPromptCacheControlForPreset(preset.toFfiModel()).toAppModel()
    }

    override suspend fun previewProviderRequestCandidate(
        preset: GenerationPreset,
    ): RequestPreview = onIo {
        core.previewProviderRequestCandidate(preset.toFfiModel()).toAppModel()
    }

    override suspend fun validateGenerationPreset(
        modelRouteId: String,
        generationPresetId: String,
    ) = onIo {
        requireNotBlank(modelRouteId, "model route ID")
        requireNotBlank(generationPresetId, "generation preset ID")
        core.validateGenerationPreset(modelRouteId, generationPresetId)
    }

    override suspend fun previewProviderRequest(
        modelRouteId: String,
        generationPresetId: String,
    ): RequestPreview = onIo {
        requireNotBlank(modelRouteId, "model route ID")
        requireNotBlank(generationPresetId, "generation preset ID")
        core.previewProviderRequest(modelRouteId, generationPresetId).toAppModel()
    }

    override suspend fun deleteGenerationPreset(generationPresetId: String) = onIo {
        requireNotBlank(generationPresetId, "generation preset ID")
        core.deleteGenerationPreset(generationPresetId)
    }

    override suspend fun listCapabilityObservations(
        modelRouteId: String,
    ): List<CapabilityObservation> = onIo {
        requireNotBlank(modelRouteId, "model route ID")
        core.listCapabilityObservations(modelRouteId)
            .map(FfiCapabilityObservation::toAppModel)
    }

    override suspend fun effectiveCapability(
        modelRouteId: String,
        key: String,
    ): EffectiveCapability? = onIo {
        requireNotBlank(modelRouteId, "model route ID")
        requireNotBlank(key, "capability key")
        core.effectiveCapability(modelRouteId, key)?.toAppModel()
    }

    override suspend fun effectiveParameterSpecs(modelRouteId: String): List<ParameterSpec> =
        onIo {
            requireNotBlank(modelRouteId, "model route ID")
            core.effectiveParameterSpecs(modelRouteId).map(FfiParameterSpec::toAppModel)
        }

    override suspend fun selectGenerationTarget(target: GenerationTarget?): AppSettings = onIo {
        core.selectGenerationTarget(target?.toFfiModel()).toAppModel()
    }

    override fun close() {
        core.close()
    }

    private suspend fun <T> onIo(block: () -> T): T = try {
        withContext(ioDispatcher) { block() }
    } catch (error: FfiException.Core) {
        throw error.toAppModel()
    }

    companion object {
        fun open(
            dataRoot: File,
            ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
        ): UniFfiCoreClient {
            require(dataRoot.isAbsolute) { "The core data root must be an absolute path." }
            val core = try {
                LorepiaCore.open(FfiCoreConfig(dataRoot = dataRoot.absolutePath))
            } catch (error: FfiException.Core) {
                throw error.toAppModel()
            }
            return UniFfiCoreClient(core, ioDispatcher)
        }
    }
}

private fun requireNotBlank(value: String, fieldName: String) {
    require(value.isNotBlank()) { "The $fieldName must not be blank." }
}

private fun FfiCharacter.toAppModel(): CharacterSummary = CharacterSummary(
    id = id,
    name = name,
    description = description,
    sourceHash = sourceHash,
    avatarAssetHash = avatarAssetHash,
    createdAt = createdAt,
)

private fun FfiImportInspection.toAppModel(): ImportInspection = ImportInspection(
    id = id,
    contentKind = contentKind,
    displayName = displayName,
    description = description,
    sourceSha256 = sourceSha256,
    sourceSize = sourceSize,
    estimatedStoredSize = estimatedStoredSize,
    assetCount = assetCount,
    warnings = warnings.map { ImportWarning(code = it.code, message = it.message) },
    blockedReasons = blockedReasons.toList(),
    isAllowed = isAllowed,
    representativeImage = representativeImage?.let { image ->
        ImportImagePreview(
            logicalAssetId = image.logicalAssetId,
            mediaType = image.mediaType,
            sizeBytes = image.sizeBytes,
        )
    },
    unsupportedOptionalFields = unsupportedOptionalFields.toList(),
)

private fun FfiConversation.toAppModel(): ConversationSummary = ConversationSummary(
    id = id,
    characterId = characterId,
    title = title,
    createdAt = createdAt,
    updatedAt = updatedAt,
)

private fun FfiMessage.toAppModel(): ChatMessage = ChatMessage(
    id = id,
    conversationId = conversationId,
    parentId = parentId,
    role = role,
    content = content,
    status = status,
    generationId = generationId,
    createdAt = createdAt,
)

private fun FfiChatEvent.toAppModel(): ChatEvent = ChatEvent(
    eventVersion = eventVersion,
    generationId = generationId,
    conversationId = conversationId,
    branchId = branchId,
    assistantMessageId = assistantMessageId,
    sequence = sequence,
    emittedAt = emittedAt,
    kind = kind,
    text = text,
    toolCallId = toolCallId,
    toolName = toolName,
    toolArgumentsDelta = toolArgumentsDelta,
    messageId = messageId,
    messageStatus = messageStatus,
    errorCode = errorCode,
    errorMessage = errorMessage,
    usageInputTokens = usageInputTokens,
    usageCachedReadTokens = usageCachedReadTokens,
    usageCachedWriteTokens = usageCachedWriteTokens,
    usageOutputTokens = usageOutputTokens,
    usageReasoningTokens = usageReasoningTokens,
    usageToolTokens = usageToolTokens,
    usageProviderRawSummary = usageProviderRawSummary,
)

private fun FfiAppSettings.toAppModel(): AppSettings = AppSettings(
    preservePartialGenerations = preservePartialGenerations,
    selectedProviderProfileId = selectedProviderProfileId,
    selectedModelRouteId = selectedModelRouteId,
    selectedGenerationPresetId = selectedGenerationPresetId,
)

private fun AppSettings.toFfiModel(): FfiAppSettings = FfiAppSettings(
    preservePartialGenerations = preservePartialGenerations,
    selectedProviderProfileId = selectedProviderProfileId,
    selectedModelRouteId = selectedModelRouteId,
    selectedGenerationPresetId = selectedGenerationPresetId,
)

private fun GenerationTarget.toFfiModel(): FfiGenerationTarget = FfiGenerationTarget(
    modelRouteId = modelRouteId,
    generationPresetId = generationPresetId,
)

private fun FfiRequestPreview.toAppModel(): RequestPreview = RequestPreview(
    redactionVersion = redactionVersion,
    method = method,
    origin = origin,
    path = path,
    headerNames = headerNames,
    queryParameterNames = queryParameterNames,
    bodyShape = bodyShape?.toAppModel(),
    bodyTruncated = bodyTruncated,
    includesPrivateMessage = includesPrivateMessage,
    includesCredentialValue = includesCredentialValue,
    includesOpaqueReasoningState = includesOpaqueReasoningState,
)

private fun FfiRequestBodyField.toAppModel(): RequestBodyField =
    RequestBodyField(name = name, shape = shape.toAppModel())

private fun FfiRequestBodyShape.toAppModel(): RequestBodyShape = when (this) {
    FfiRequestBodyShape.Null -> RequestBodyShape.Null
    FfiRequestBodyShape.Boolean -> RequestBodyShape.Boolean
    FfiRequestBodyShape.Number -> RequestBodyShape.Number
    FfiRequestBodyShape.String -> RequestBodyShape.StringValue
    is FfiRequestBodyShape.Array -> RequestBodyShape.Array(
        items = items.map(FfiRequestBodyShape::toAppModel),
        truncated = truncated,
    )
    is FfiRequestBodyShape.Object -> RequestBodyShape.Object(
        fields = fields.map(FfiRequestBodyField::toAppModel),
        truncated = truncated,
    )
    FfiRequestBodyShape.Redacted -> RequestBodyShape.Redacted
    FfiRequestBodyShape.Truncated -> RequestBodyShape.Truncated
}

private fun FfiProviderProfile.toAppModel(): ProviderProfile = ProviderProfile(
    id = id,
    displayName = displayName,
    baseUrl = baseUrl,
    model = model,
    timeoutSeconds = timeoutSeconds,
)

private fun ProviderProfile.toFfiModel(): FfiProviderProfile = FfiProviderProfile(
    id = id,
    displayName = displayName,
    baseUrl = baseUrl,
    model = model,
    timeoutSeconds = timeoutSeconds,
)

private fun FfiAuthBinding.toAppModel(): AuthBinding = when (this) {
    FfiAuthBinding.BearerHeader -> AuthBinding.BearerHeader
    FfiAuthBinding.None -> AuthBinding.None
    is FfiAuthBinding.HeaderApiKey -> AuthBinding.HeaderApiKey(headerName)
}

private fun AuthBinding.toFfiModel(): FfiAuthBinding = when (this) {
    AuthBinding.BearerHeader -> FfiAuthBinding.BearerHeader
    AuthBinding.None -> FfiAuthBinding.None
    is AuthBinding.HeaderApiKey -> FfiAuthBinding.HeaderApiKey(headerName)
}

private fun FfiConnectionFieldType.toAppModel(): ConnectionFieldType = when (this) {
    FfiConnectionFieldType.BOOLEAN -> ConnectionFieldType.Boolean
    FfiConnectionFieldType.CREDENTIAL -> ConnectionFieldType.Credential
    FfiConnectionFieldType.INTEGER -> ConnectionFieldType.Integer
    FfiConnectionFieldType.TEXT -> ConnectionFieldType.Text
}

private fun FfiConnectionFieldSpec.toAppModel(): ConnectionFieldSpec = ConnectionFieldSpec(
    key = key,
    labelKey = labelKey,
    descriptionKey = descriptionKey,
    valueType = valueType.toAppModel(),
    required = required,
)

private fun FfiConnectionConfigValue.toAppModel(): ConnectionConfigValue = when (this) {
    is FfiConnectionConfigValue.Boolean -> ConnectionConfigValue.Boolean(value)
    is FfiConnectionConfigValue.Integer -> ConnectionConfigValue.Integer(value)
    is FfiConnectionConfigValue.Text -> ConnectionConfigValue.Text(value)
}

private fun ConnectionConfigValue.toFfiModel(): FfiConnectionConfigValue = when (this) {
    is ConnectionConfigValue.Boolean -> FfiConnectionConfigValue.Boolean(value)
    is ConnectionConfigValue.Integer -> FfiConnectionConfigValue.Integer(value)
    is ConnectionConfigValue.Text -> FfiConnectionConfigValue.Text(value)
}

private fun FfiConnectionConfigEntry.toAppModel(): ConnectionConfigEntry =
    ConnectionConfigEntry(key, value.toAppModel())

private fun ConnectionConfigEntry.toFfiModel(): FfiConnectionConfigEntry =
    FfiConnectionConfigEntry(key, value.toFfiModel())

private fun FfiParameterType.toAppModel(): ParameterType = when (this) {
    FfiParameterType.BOOLEAN -> ParameterType.Boolean
    FfiParameterType.ENUM -> ParameterType.Enum
    FfiParameterType.INTEGER -> ParameterType.Integer
    FfiParameterType.JSON_SCHEMA -> ParameterType.JsonSchema
    FfiParameterType.NUMBER -> ParameterType.Number
    FfiParameterType.STOP_SEQUENCE_LIST -> ParameterType.StopSequenceList
    FfiParameterType.STRING -> ParameterType.String
    FfiParameterType.STRING_LIST -> ParameterType.StringList
    FfiParameterType.TOOL_POLICY -> ParameterType.ToolPolicy
}

private fun FfiToolPolicy.toAppModel(): ToolPolicy = when (this) {
    FfiToolPolicy.AUTO -> ToolPolicy.Auto
    FfiToolPolicy.NONE -> ToolPolicy.None
    FfiToolPolicy.REQUIRED -> ToolPolicy.Required
}

private fun ToolPolicy.toFfiModel(): FfiToolPolicy = when (this) {
    ToolPolicy.Auto -> FfiToolPolicy.AUTO
    ToolPolicy.None -> FfiToolPolicy.NONE
    ToolPolicy.Required -> FfiToolPolicy.REQUIRED
}

private fun FfiParameterLiteral.toAppModel(): ParameterLiteral = when (this) {
    is FfiParameterLiteral.Boolean -> ParameterLiteral.Boolean(value)
    is FfiParameterLiteral.Enum -> ParameterLiteral.EnumValue(value)
    is FfiParameterLiteral.Integer -> ParameterLiteral.Integer(value)
    is FfiParameterLiteral.JsonSchema -> ParameterLiteral.JsonSchema(value)
    is FfiParameterLiteral.Number -> ParameterLiteral.Number(value)
    is FfiParameterLiteral.StopSequenceList -> ParameterLiteral.StopSequenceList(values)
    is FfiParameterLiteral.String -> ParameterLiteral.StringValue(value)
    is FfiParameterLiteral.StringList -> ParameterLiteral.StringList(values)
    is FfiParameterLiteral.ToolPolicy -> ParameterLiteral.ToolPolicyValue(value.toAppModel())
}

private fun ParameterLiteral.toFfiModel(): FfiParameterLiteral = when (this) {
    is ParameterLiteral.Boolean -> FfiParameterLiteral.Boolean(value)
    is ParameterLiteral.EnumValue -> FfiParameterLiteral.Enum(value)
    is ParameterLiteral.Integer -> FfiParameterLiteral.Integer(value)
    is ParameterLiteral.JsonSchema -> FfiParameterLiteral.JsonSchema(value)
    is ParameterLiteral.Number -> FfiParameterLiteral.Number(value)
    is ParameterLiteral.StopSequenceList -> FfiParameterLiteral.StopSequenceList(values)
    is ParameterLiteral.StringList -> FfiParameterLiteral.StringList(values)
    is ParameterLiteral.StringValue -> FfiParameterLiteral.String(value)
    is ParameterLiteral.ToolPolicyValue -> FfiParameterLiteral.ToolPolicy(value.toFfiModel())
}

private fun FfiParameterValueState.toAppModel(): ParameterValueState = when (this) {
    FfiParameterValueState.InheritProviderDefault ->
        ParameterValueState.InheritProviderDefault
    is FfiParameterValueState.Explicit ->
        ParameterValueState.Explicit(value.toAppModel())
}

private fun ParameterValueState.toFfiModel(): FfiParameterValueState = when (this) {
    ParameterValueState.InheritProviderDefault ->
        FfiParameterValueState.InheritProviderDefault
    is ParameterValueState.Explicit ->
        FfiParameterValueState.Explicit(value.toFfiModel())
}

private fun FfiParameterValue.toAppModel(): ParameterValue =
    ParameterValue(parameterId, state.toAppModel())

private fun ParameterValue.toFfiModel(): FfiParameterValue =
    FfiParameterValue(parameterId, state.toFfiModel())

private fun FfiParameterChoice.toAppModel(): ParameterChoice =
    ParameterChoice(value.toAppModel(), labelKey)

private fun FfiParameterDefaultMode.toAppModel(): ParameterDefaultMode = when (this) {
    FfiParameterDefaultMode.EXPLICIT_REQUIRED -> ParameterDefaultMode.ExplicitRequired
    FfiParameterDefaultMode.PROVIDER_DEFAULT -> ParameterDefaultMode.ProviderDefault
}

private fun FfiParameterConditionOperator.toAppModel(): ParameterConditionOperator =
    when (this) {
        FfiParameterConditionOperator.EQUALS -> ParameterConditionOperator.Equals
        FfiParameterConditionOperator.NOT_EQUALS -> ParameterConditionOperator.NotEquals
    }

private fun FfiParameterCondition.toAppModel(): ParameterCondition = ParameterCondition(
    parameterId = parameterId,
    operator = operator.toAppModel(),
    value = value.toAppModel(),
)

private fun FfiParameterConflictKind.toAppModel(): ParameterConflictKind = when (this) {
    FfiParameterConflictKind.MUTUALLY_EXCLUSIVE -> ParameterConflictKind.MutuallyExclusive
    FfiParameterConflictKind.REQUIRES -> ParameterConflictKind.Requires
}

private fun FfiParameterConflict.toAppModel(): ParameterConflict = ParameterConflict(
    parameterId = parameterId,
    kind = kind.toAppModel(),
    messageKey = messageKey,
)

private fun FfiProviderParameterTarget.toAppModel(): ProviderParameterTarget = when (this) {
    FfiProviderParameterTarget.REQUEST_BODY -> ProviderParameterTarget.RequestBody
    FfiProviderParameterTarget.REQUEST_HEADER -> ProviderParameterTarget.RequestHeader
}

private fun FfiProviderParameterMapping.toAppModel(): ProviderParameterMapping =
    ProviderParameterMapping(target.toAppModel(), fieldName)

private fun FfiUiParameterLevel.toAppModel(): UiParameterLevel = when (this) {
    FfiUiParameterLevel.ADVANCED -> UiParameterLevel.Advanced
    FfiUiParameterLevel.BASIC -> UiParameterLevel.Basic
    FfiUiParameterLevel.EXPERT -> UiParameterLevel.Expert
    FfiUiParameterLevel.HIDDEN_INTERNAL -> UiParameterLevel.HiddenInternal
}

private fun FfiParameterSpec.toAppModel(): ParameterSpec = ParameterSpec(
    id = id,
    labelKey = labelKey,
    descriptionKey = descriptionKey,
    valueType = valueType.toAppModel(),
    allowedValues = allowedValues.map(FfiParameterChoice::toAppModel),
    minimum = minimum,
    maximum = maximum,
    step = step,
    defaultMode = defaultMode.toAppModel(),
    visibility = visibility?.toAppModel(),
    conflicts = conflicts.map(FfiParameterConflict::toAppModel),
    providerMapping = providerMapping.toAppModel(),
    level = level.toAppModel(),
)

private fun FfiProviderTemplate.toAppModel(): ProviderTemplate = ProviderTemplate(
    id = id,
    displayName = displayName,
    manifestVersion = manifestVersion,
    source = source,
    apiFamily = apiFamily,
    defaultApiOrigin = defaultApiOrigin,
    requiresCredential = requiresCredential,
    supportsModelListing = supportsModelListing,
    authBinding = authBinding.toAppModel(),
    connectionFields = connectionFields.map(FfiConnectionFieldSpec::toAppModel),
    parameters = parameters.map(FfiParameterSpec::toAppModel),
    defaultNetworkMode = defaultNetworkMode.toAppModel(),
)

private fun ProviderConnectionDraft.toFfiModel(): FfiProviderConnectionDraft =
    FfiProviderConnectionDraft(
        id = id,
        templateId = templateId,
        templateVersion = templateVersion,
        displayName = displayName,
        apiOrigin = apiOrigin,
        apiBasePath = apiBasePath,
        networkMode = networkMode.toFfiModel(),
        localNetworkApproval = localNetworkApproval?.toFfiModel(),
        values = values.map(ConnectionConfigEntry::toFfiModel),
        approvedCredentialOrigin = approvedCredentialOrigin,
        timeoutSeconds = timeoutSeconds,
    )

private fun FfiProviderLocalNetworkApproval.toAppModel(): ProviderLocalNetworkApproval =
    ProviderLocalNetworkApproval(origin = origin, addresses = addresses)

private fun ProviderLocalNetworkApproval.toFfiModel(): FfiProviderLocalNetworkApproval =
    FfiProviderLocalNetworkApproval(origin = origin, addresses = addresses)

private fun FfiProviderNetworkMode.toAppModel(): ProviderNetworkMode = when (this) {
    FfiProviderNetworkMode.PUBLIC -> ProviderNetworkMode.Public
    FfiProviderNetworkMode.LOCAL_LOOPBACK -> ProviderNetworkMode.LocalLoopback
    FfiProviderNetworkMode.APPROVED_LOCAL_NETWORK -> ProviderNetworkMode.ApprovedLocalNetwork
}

private fun ProviderNetworkMode.toFfiModel(): FfiProviderNetworkMode = when (this) {
    ProviderNetworkMode.Public -> FfiProviderNetworkMode.PUBLIC
    ProviderNetworkMode.LocalLoopback -> FfiProviderNetworkMode.LOCAL_LOOPBACK
    ProviderNetworkMode.ApprovedLocalNetwork -> FfiProviderNetworkMode.APPROVED_LOCAL_NETWORK
}

private fun ProviderNetworkPolicy.toFfiModel(): FfiProviderNetworkPolicy =
    FfiProviderNetworkPolicy(
        networkMode = networkMode.toFfiModel(),
        localNetworkApproval = localNetworkApproval?.toFfiModel(),
    )

private fun FfiCredentialRedirectPolicy.toAppModel(): CredentialRedirectPolicy = when (this) {
    FfiCredentialRedirectPolicy.DENY -> CredentialRedirectPolicy.Deny
    FfiCredentialRedirectPolicy.FOLLOW_WITHOUT_CREDENTIAL ->
        CredentialRedirectPolicy.FollowWithoutCredential
}

private fun CredentialRedirectPolicy.toFfiModel(): FfiCredentialRedirectPolicy = when (this) {
    CredentialRedirectPolicy.Deny -> FfiCredentialRedirectPolicy.DENY
    CredentialRedirectPolicy.FollowWithoutCredential ->
        FfiCredentialRedirectPolicy.FOLLOW_WITHOUT_CREDENTIAL
}

private fun FfiCredentialScope.toAppModel(): CredentialScope = CredentialScope(
    allowedOrigins = allowedOrigins,
    authBinding = authBinding.toAppModel(),
    redirectPolicy = redirectPolicy.toAppModel(),
)

private fun CredentialScope.toFfiModel(): FfiCredentialScope = FfiCredentialScope(
    allowedOrigins = allowedOrigins,
    authBinding = authBinding.toFfiModel(),
    redirectPolicy = redirectPolicy.toFfiModel(),
)

private fun FfiProviderConnection.toAppModel(): ProviderConnection = ProviderConnection(
    id = id,
    templateId = templateId,
    templateVersion = templateVersion,
    displayName = displayName,
    apiOrigin = apiOrigin,
    apiBasePath = apiBasePath,
    networkMode = networkMode.toAppModel(),
    localNetworkApproval = localNetworkApproval?.toAppModel(),
    values = values.map(FfiConnectionConfigEntry::toAppModel),
    credentialSlotReady = credentialSlotReady,
    credentialScope = credentialScope?.toAppModel(),
    approvedCredentialOrigins = approvedCredentialOrigins,
    timeoutSeconds = timeoutSeconds,
    status = status,
    createdAt = createdAt,
    updatedAt = updatedAt,
)

private fun ProviderConnection.toFfiModel(): FfiProviderConnection = FfiProviderConnection(
    id = id,
    templateId = templateId,
    templateVersion = templateVersion,
    displayName = displayName,
    apiOrigin = apiOrigin,
    apiBasePath = apiBasePath,
    networkMode = networkMode.toFfiModel(),
    localNetworkApproval = localNetworkApproval?.toFfiModel(),
    values = values.map(ConnectionConfigEntry::toFfiModel),
    credentialSlotReady = credentialSlotReady,
    credentialScope = credentialScope?.toFfiModel(),
    approvedCredentialOrigins = approvedCredentialOrigins,
    timeoutSeconds = timeoutSeconds,
    status = status,
    createdAt = createdAt,
    updatedAt = updatedAt,
)

private fun FfiModelRouteConfig.toAppModel(): ModelRouteConfig = ModelRouteConfig(
    deploymentId = deploymentId,
    region = region,
    endpointPath = endpointPath,
    values = values.map(FfiConnectionConfigEntry::toAppModel),
)

private fun FfiModelRoute.toAppModel(): ModelRoute = ModelRoute(
    id = id,
    connectionId = connectionId,
    apiFamily = apiFamily,
    modelId = modelId,
    displayName = displayName,
    routeConfig = routeConfig.toAppModel(),
    availability = availability,
    missCount = missCount,
    rawMetadataJson = rawMetadataJson,
    metadataSource = metadataSource,
    metadataObservedAt = metadataObservedAt,
    lastReconciledSyncJobId = lastReconciledSyncJobId,
    metadataSyncJobId = metadataSyncJobId,
    firstSeenAt = firstSeenAt,
    lastSeenAt = lastSeenAt,
)

private fun FfiGenerationPreset.toAppModel(): GenerationPreset = GenerationPreset(
    id = id,
    modelRouteId = modelRouteId,
    displayName = displayName,
    values = values.map(FfiParameterValue::toAppModel),
    reasoningMode = reasoningMode,
    reasoningEffort = reasoningEffort,
    reasoningBudgetTokens = reasoningBudgetTokens,
    reasoningSummary = reasoningSummary,
    preserveOpaqueReasoningState = preserveOpaqueReasoningState,
    promptCacheMode = promptCacheMode,
    promptCacheTtl = promptCacheTtl,
    promptCacheCustomTtlSeconds = promptCacheCustomTtlSeconds,
    promptCacheContextReference = promptCacheContextReference,
    createdAt = createdAt,
    updatedAt = updatedAt,
)

private fun GenerationPreset.toFfiModel(): FfiGenerationPreset = FfiGenerationPreset(
    id = id,
    modelRouteId = modelRouteId,
    displayName = displayName,
    parameterValueCount = values.size.toUInt(),
    values = values.map(ParameterValue::toFfiModel),
    reasoningMode = reasoningMode,
    reasoningEffort = reasoningEffort,
    reasoningBudgetTokens = reasoningBudgetTokens,
    reasoningSummary = reasoningSummary,
    preserveOpaqueReasoningState = preserveOpaqueReasoningState,
    promptCacheMode = promptCacheMode,
    promptCacheTtl = promptCacheTtl,
    promptCacheCustomTtlSeconds = promptCacheCustomTtlSeconds,
    promptCacheContextReference = promptCacheContextReference,
    createdAt = createdAt,
    updatedAt = updatedAt,
)

private fun FfiParameterIssue.toAppModel(): ParameterIssue = ParameterIssue(
    code = code,
    parameterId = parameterId,
    relatedParameterId = relatedParameterId,
    message = message,
)

private fun FfiReasoningControl.toAppModel(): ReasoningControl = ReasoningControl(
    state = state,
    mode = mode,
    effort = effort,
    budgetTokens = budgetTokens,
    summary = summary,
    preserveOpaqueState = preserveOpaqueState,
    allowedModes = allowedModes,
    allowedEfforts = allowedEfforts,
    allowedSummaries = allowedSummaries,
    minimumBudgetTokens = minimumBudgetTokens,
    maximumBudgetTokens = maximumBudgetTokens,
    effortField = effortField,
    budgetField = budgetField,
    summaryField = summaryField,
    issues = issues.map(FfiParameterIssue::toAppModel),
)

private fun FfiPromptCacheControl.toAppModel(): PromptCacheControl = PromptCacheControl(
    state = state,
    mode = mode,
    ttl = ttl,
    customTtlSeconds = customTtlSeconds,
    contextReference = contextReference,
    allowedModes = allowedModes,
    allowedTtls = allowedTtls,
    supportsCustomTtl = supportsCustomTtl,
    minimumCustomTtlSeconds = minimumCustomTtlSeconds,
    maximumCustomTtlSeconds = maximumCustomTtlSeconds,
    ttlField = ttlField,
    contextReferenceField = contextReferenceField,
    issues = issues.map(FfiParameterIssue::toAppModel),
)

private fun FfiCapabilityValue.toAppModel(): CapabilityValue = CapabilityValue(
    kind = kind,
    booleanValue = booleanValue,
    integerValue = integerValue,
    enumValues = enumValues,
    structuredJson = structuredJson,
)

private fun FfiCapabilityObservation.toAppModel(): CapabilityObservation =
    CapabilityObservation(
        id = id,
        modelRouteId = modelRouteId,
        key = key,
        value = value.toAppModel(),
        status = status,
        source = source,
        confidence = confidence,
        observedAt = observedAt,
        expiresAt = expiresAt,
        evidenceRef = evidenceRef,
    )

private fun FfiEffectiveCapability.toAppModel(): EffectiveCapability = EffectiveCapability(
    selected = selected.toAppModel(),
    alternatives = alternatives.map(FfiCapabilityObservation::toAppModel),
    evaluatedAt = evaluatedAt,
    selectedIsStale = selectedIsStale,
    hasConflict = hasConflict,
)

private fun FfiModelSyncFailure.toAppModel(): ModelSyncFailure = ModelSyncFailure(
    code = code,
    messageKey = messageKey,
    recoverable = recoverable,
)

private fun FfiModelSyncProvenance.toAppModel(): ModelSyncProvenance = ModelSyncProvenance(
    source = source,
    apiFamily = apiFamily,
    apiOrigin = apiOrigin,
    endpointPath = endpointPath,
    pagesFetched = pagesFetched,
    responseBytes = responseBytes,
)

private fun FfiModelSyncReview.toAppModel(): ModelSyncReview = ModelSyncReview(
    sha256 = sha256,
    connectionId = connectionId,
    expectedConnection = expectedConnection.toAppModel(),
    observedAt = observedAt,
    expectedModelRoutes = expectedModelRoutes.map(FfiModelRoute::toAppModel),
    listedRoutes = listedRoutes.map(FfiModelRoute::toAppModel),
    newlySeenModelRouteIds = newlySeenModelRouteIds,
    missingModelRouteIds = missingModelRouteIds,
    initialPresets = initialPresets.map(FfiGenerationPreset::toAppModel),
    capabilityObservations =
        capabilityObservations.map(FfiCapabilityObservation::toAppModel),
    routesRequiringPresetConfiguration = routesRequiringPresetConfiguration,
    provenance = provenance.toAppModel(),
)

private fun FfiModelSyncJob.toAppModel(): ModelSyncJob = ModelSyncJob(
    id = id,
    connectionId = connectionId,
    state = state,
    revision = revision,
    review = review?.toAppModel(),
    failure = failure?.toAppModel(),
    createdAt = createdAt,
    updatedAt = updatedAt,
)

private fun FfiModelSyncEvent.toAppModel(): ModelSyncEvent = ModelSyncEvent(
    version = version,
    jobId = jobId,
    sequence = sequence,
    jobRevision = jobRevision,
    redactionVersion = redactionVersion,
    state = state,
    completedSteps = completedSteps,
    totalSteps = totalSteps,
    messageKey = messageKey,
    reviewSha256 = reviewSha256,
    failure = failure?.toAppModel(),
    emittedAt = emittedAt,
)

private fun FfiException.Core.toAppModel(): CoreFailure = CoreFailure(
    code = code,
    detail = detail,
    recoverable = recoverable,
    operationId = operationId,
)

private fun ProviderDiscoveryInput.toFfiModel(): FfiProviderDiscoveryInput =
    FfiProviderDiscoveryInput(
        connectionId = connectionId,
        displayName = displayName,
        siteUrl = siteUrl,
        docsUrl = docsUrl,
        credentialSlotReady = credentialSlotReady,
        preferredAssistantModelRouteId = preferredAssistantModelRouteId,
        connectionOptions = connectionOptions.toFfiModel(),
        suppliedEvidenceIds = suppliedEvidenceIds,
    )

private fun ProviderDiscoveryConnectionOptions.toFfiModel():
    FfiProviderDiscoveryConnectionOptions = FfiProviderDiscoveryConnectionOptions(
    values = values.map(ConnectionConfigEntry::toFfiModel),
    apiBasePath = apiBasePath,
    timeoutSeconds = timeoutSeconds,
    networkMode = networkMode.toFfiModel(),
    localNetworkApproval = localNetworkApproval?.toFfiModel(),
)

private fun ProviderDiscoverySource.toFfiModel(): FfiProviderDiscoverySource = when (this) {
    is ProviderDiscoverySource.KnownProvider ->
        FfiProviderDiscoverySource.KnownProvider(templateId)
    ProviderDiscoverySource.Site -> FfiProviderDiscoverySource.Site
    ProviderDiscoverySource.Curl -> FfiProviderDiscoverySource.Curl
}

private fun FfiDiscoveryAssistantDraftField.toAppModel(): DiscoveryAssistantDraftField =
    when (this) {
        FfiDiscoveryAssistantDraftField.ApiFamily -> DiscoveryAssistantDraftField.ApiFamily
        FfiDiscoveryAssistantDraftField.DefaultApiOrigin ->
            DiscoveryAssistantDraftField.DefaultApiOrigin
        FfiDiscoveryAssistantDraftField.Auth -> DiscoveryAssistantDraftField.Auth
        FfiDiscoveryAssistantDraftField.GenerateEndpoint ->
            DiscoveryAssistantDraftField.GenerateEndpoint
        FfiDiscoveryAssistantDraftField.ModelsEndpoint ->
            DiscoveryAssistantDraftField.ModelsEndpoint
        FfiDiscoveryAssistantDraftField.ResponseDecoder ->
            DiscoveryAssistantDraftField.ResponseDecoder
        FfiDiscoveryAssistantDraftField.StreamingDecoder ->
            DiscoveryAssistantDraftField.StreamingDecoder
        is FfiDiscoveryAssistantDraftField.Parameter ->
            DiscoveryAssistantDraftField.Parameter(parameterId)
    }

private fun FfiDiscoveryAssistantQuestion.toAppModel(): DiscoveryAssistantQuestion =
    DiscoveryAssistantQuestion(
        id = id,
        field = field?.toAppModel(),
        question = question,
        requiredEvidence = requiredEvidence,
    )

private fun FfiDiscoveryAssistantEvidenceMapping.toAppModel():
    DiscoveryAssistantEvidenceMapping = DiscoveryAssistantEvidenceMapping(
    field = field.toAppModel(),
    evidenceIds = evidenceIds,
    explanation = explanation,
)

private fun FfiDiscoveryAssistantConfidenceLevel.toAppModel():
    DiscoveryAssistantConfidenceLevel = when (this) {
    FfiDiscoveryAssistantConfidenceLevel.UNKNOWN -> DiscoveryAssistantConfidenceLevel.Unknown
    FfiDiscoveryAssistantConfidenceLevel.LOW -> DiscoveryAssistantConfidenceLevel.Low
    FfiDiscoveryAssistantConfidenceLevel.MEDIUM -> DiscoveryAssistantConfidenceLevel.Medium
    FfiDiscoveryAssistantConfidenceLevel.HIGH -> DiscoveryAssistantConfidenceLevel.High
}

private fun FfiDiscoveryAssistantFieldConfidence.toAppModel():
    DiscoveryAssistantFieldConfidence = DiscoveryAssistantFieldConfidence(
    field = field.toAppModel(),
    level = level.toAppModel(),
    rationale = rationale,
)

private fun FfiDiscoveryAssistantConflictDisposition.toAppModel():
    DiscoveryAssistantConflictDisposition = when (this) {
    FfiDiscoveryAssistantConflictDisposition.Unresolved ->
        DiscoveryAssistantConflictDisposition.Unresolved
    is FfiDiscoveryAssistantConflictDisposition.Resolved ->
        DiscoveryAssistantConflictDisposition.Resolved(
            selectedEvidenceId = selectedEvidenceId,
            rationale = rationale,
        )
}

private fun FfiDiscoveryAssistantEvidenceConflict.toAppModel():
    DiscoveryAssistantEvidenceConflict = DiscoveryAssistantEvidenceConflict(
    field = field.toAppModel(),
    evidenceIds = evidenceIds,
    disposition = disposition.toAppModel(),
)

private fun FfiDiscoveryAssistantManifestSource.toAppModel():
    DiscoveryAssistantManifestSource = DiscoveryAssistantManifestSource(
    kind = kind.toWireName(),
    url = url,
    contentSha256 = contentSha256,
)

private fun FfiDiscoveryAssistantEndpoint.toAppModel(): DiscoveryAssistantEndpoint =
    DiscoveryAssistantEndpoint(method = method.toWireName(), path = path)

private fun FfiDiscoveryAssistantManifest.toAppModel(): DiscoveryAssistantManifest =
    DiscoveryAssistantManifest(
        schemaVersion = schemaVersion,
        apiFamily = apiFamily.toWireName(),
        sources = sources.map(FfiDiscoveryAssistantManifestSource::toAppModel),
        defaultApiOrigin = defaultApiOrigin,
        auth = auth.toAppModel(),
        modelsEndpoint = modelsEndpoint?.toAppModel(),
        generateEndpoint = generateEndpoint.toAppModel(),
        responseDecoder = responseDecoder.toWireName(),
        streamingDecoder = streamingDecoder?.toWireName(),
        parameters = parameters.map(FfiParameterSpec::toAppModel),
    )

private fun FfiDiscoveryAssistantManifestDraft.toAppModel():
    DiscoveryAssistantManifestDraft = DiscoveryAssistantManifestDraft(
    manifest = manifest.toAppModel(),
    evidenceMappings = evidenceMappings.map(
        FfiDiscoveryAssistantEvidenceMapping::toAppModel,
    ),
    conflicts = conflicts.map(FfiDiscoveryAssistantEvidenceConflict::toAppModel),
    unresolvedQuestions = unresolvedQuestions.map(
        FfiDiscoveryAssistantQuestion::toAppModel,
    ),
    confidence = confidence.map(FfiDiscoveryAssistantFieldConfidence::toAppModel),
    summary = summary,
)

private fun FfiDiscoveryAssistantDraftReviewCheck.toAppModel():
    DiscoveryAssistantDraftReviewCheck = when (this) {
    FfiDiscoveryAssistantDraftReviewCheck.MANIFEST_VALIDATION ->
        DiscoveryAssistantDraftReviewCheck.ManifestValidation
    FfiDiscoveryAssistantDraftReviewCheck.URL_POLICY_VALIDATION ->
        DiscoveryAssistantDraftReviewCheck.UrlPolicyValidation
    FfiDiscoveryAssistantDraftReviewCheck.CREDENTIAL_ORIGIN_APPROVAL ->
        DiscoveryAssistantDraftReviewCheck.CredentialOriginApproval
    FfiDiscoveryAssistantDraftReviewCheck.USER_REVIEW ->
        DiscoveryAssistantDraftReviewCheck.UserReview
}

private fun FfiDiscoveryAssistantDraftReview.toAppModel(): DiscoveryAssistantDraftReview =
    DiscoveryAssistantDraftReview(
        draft = draft.toAppModel(),
        unresolvedConflicts = unresolvedConflicts.map(
            FfiDiscoveryAssistantDraftField::toAppModel,
        ),
        requiredChecks = requiredChecks.map(
            FfiDiscoveryAssistantDraftReviewCheck::toAppModel,
        ),
        persistence = when (persistence) {
            FfiDiscoveryAssistantDraftPersistence.BLOCKED_UNTIL_CHECKS_PASS ->
                DiscoveryAssistantDraftPersistence.BlockedUntilChecksPass
        },
    )

private fun FfiDiscoveryAssistantManifestSourceKind.toWireName(): String = when (this) {
    FfiDiscoveryAssistantManifestSourceKind.OFFICIAL_SITE -> "official_site"
    FfiDiscoveryAssistantManifestSourceKind.OFFICIAL_DOCUMENTATION ->
        "official_documentation"
    FfiDiscoveryAssistantManifestSourceKind.SIGNED_CATALOG -> "signed_catalog"
    FfiDiscoveryAssistantManifestSourceKind.USER_SUPPLIED -> "user_supplied"
}

private fun FfiDiscoveryAssistantApiFamily.toWireName(): String = when (this) {
    FfiDiscoveryAssistantApiFamily.OPEN_AI_RESPONSES -> "openai_responses"
    FfiDiscoveryAssistantApiFamily.OPEN_AI_CHAT_COMPLETIONS ->
        "openai_chat_completions"
    FfiDiscoveryAssistantApiFamily.ANTHROPIC_MESSAGES -> "anthropic_messages"
    FfiDiscoveryAssistantApiFamily.GEMINI_GENERATE_CONTENT ->
        "gemini_generate_content"
    FfiDiscoveryAssistantApiFamily.OLLAMA_NATIVE -> "ollama_native"
}

private fun FfiDiscoveryAssistantHttpMethod.toWireName(): String = when (this) {
    FfiDiscoveryAssistantHttpMethod.GET -> "GET"
    FfiDiscoveryAssistantHttpMethod.POST -> "POST"
}

private fun FfiDiscoveryAssistantDecoder.toWireName(): String = when (this) {
    FfiDiscoveryAssistantDecoder.OPEN_AI_JSON_V1 -> "openai_json_v1"
    FfiDiscoveryAssistantDecoder.OPEN_AI_SSE_V1 -> "openai_sse_v1"
    FfiDiscoveryAssistantDecoder.ANTHROPIC_JSON_V1 -> "anthropic_json_v1"
    FfiDiscoveryAssistantDecoder.ANTHROPIC_SSE_V1 -> "anthropic_sse_v1"
    FfiDiscoveryAssistantDecoder.GEMINI_JSON_V1 -> "gemini_json_v1"
    FfiDiscoveryAssistantDecoder.GEMINI_SSE_V1 -> "gemini_sse_v1"
    FfiDiscoveryAssistantDecoder.OLLAMA_JSON_V1 -> "ollama_json_v1"
    FfiDiscoveryAssistantDecoder.OLLAMA_JSONL_V1 -> "ollama_jsonl_v1"
}

private fun FfiProviderCurlInspection.toAppModel(): ProviderCurlInspection =
    ProviderCurlInspection(
        inspectionSchemaVersion = inspectionSchemaVersion,
        sanitizedSiteUrl = sanitizedSiteUrl,
        apiOrigin = apiOrigin,
        method = method,
        path = path,
        headerNames = headerNames,
        authBindingHint = authBindingHint?.toAppModel(),
        apiFamilyHint = apiFamilyHint,
        modelHint = modelHint,
        streamHint = streamHint,
        redactedCurl = redactedCurl,
        credentialHandoffId = credentialHandoffId,
    ).also {
        check(it.inspectionSchemaVersion == SUPPORTED_CURL_INSPECTION_SCHEMA_VERSION) {
            "Unsupported provider cURL inspection schema version."
        }
    }

private fun DiscoveryUnknownOutcomeResolution.toFfiModel():
    FfiDiscoveryUnknownOutcomeResolution = when (this) {
        DiscoveryUnknownOutcomeResolution.ConfirmedNoEffect ->
            FfiDiscoveryUnknownOutcomeResolution.ConfirmedNoEffect
        is DiscoveryUnknownOutcomeResolution.ConfirmedCommitCompleted ->
            FfiDiscoveryUnknownOutcomeResolution.ConfirmedCommitCompleted(connectionId)
        DiscoveryUnknownOutcomeResolution.ConfirmedCompensated ->
            FfiDiscoveryUnknownOutcomeResolution.ConfirmedCompensated
        DiscoveryUnknownOutcomeResolution.ManuallyReconciledAsFailed ->
            FfiDiscoveryUnknownOutcomeResolution.ManuallyReconciledAsFailed
    }

private fun FfiDiscoveryUnknownOutcomeResolution.toAppModel():
    DiscoveryUnknownOutcomeResolution = when (this) {
        FfiDiscoveryUnknownOutcomeResolution.ConfirmedNoEffect ->
            DiscoveryUnknownOutcomeResolution.ConfirmedNoEffect
        is FfiDiscoveryUnknownOutcomeResolution.ConfirmedCommitCompleted ->
            DiscoveryUnknownOutcomeResolution.ConfirmedCommitCompleted(connectionId)
        FfiDiscoveryUnknownOutcomeResolution.ConfirmedCompensated ->
            DiscoveryUnknownOutcomeResolution.ConfirmedCompensated
        FfiDiscoveryUnknownOutcomeResolution.ManuallyReconciledAsFailed ->
            DiscoveryUnknownOutcomeResolution.ManuallyReconciledAsFailed
    }

private fun ProviderDiscoveryAction.toFfiModel(): FfiProviderDiscoveryAction = when (this) {
    is ProviderDiscoveryAction.SelectTemplate ->
        FfiProviderDiscoveryAction.SelectTemplate(candidateId)
    ProviderDiscoveryAction.ContinueWithoutTemplate ->
        FfiProviderDiscoveryAction.ContinueWithoutTemplate
    is ProviderDiscoveryAction.SupplyMoreEvidence ->
        FfiProviderDiscoveryAction.SupplyMoreEvidence(evidenceIds)
    ProviderDiscoveryAction.RequestAssistant -> FfiProviderDiscoveryAction.RequestAssistant
    is ProviderDiscoveryAction.ApproveAssistant ->
        FfiProviderDiscoveryAction.ApproveAssistant(approvalId, approvalGrantSha256)
    ProviderDiscoveryAction.DeclineAssistant -> FfiProviderDiscoveryAction.DeclineAssistant
    is ProviderDiscoveryAction.ApproveCredentialOrigin ->
        FfiProviderDiscoveryAction.ApproveCredentialOrigin(approvalId)
    is ProviderDiscoveryAction.ApproveProbes ->
        FfiProviderDiscoveryAction.ApproveProbes(approvalId, approvalGrantSha256)
    ProviderDiscoveryAction.SkipProbes -> FfiProviderDiscoveryAction.SkipProbes
    is ProviderDiscoveryAction.ApproveReview ->
        FfiProviderDiscoveryAction.ApproveReview(
            approvalId,
            commitAttemptId,
            commitPlanSha256,
            graphSha256,
        )
    ProviderDiscoveryAction.ResumeCompensation ->
        FfiProviderDiscoveryAction.ResumeCompensation
    ProviderDiscoveryAction.RestartInterrupted ->
        FfiProviderDiscoveryAction.RestartInterrupted
    is ProviderDiscoveryAction.ResolveUnknownOutcome ->
        FfiProviderDiscoveryAction.ResolveUnknownOutcome(
            approvalId,
            resolution.toFfiModel(),
        )
    ProviderDiscoveryAction.Cancel -> FfiProviderDiscoveryAction.Cancel
}

private fun FfiProviderDiscoveryAction.toAppModel(): ProviderDiscoveryAction = when (this) {
    is FfiProviderDiscoveryAction.SelectTemplate ->
        ProviderDiscoveryAction.SelectTemplate(candidateId)
    FfiProviderDiscoveryAction.ContinueWithoutTemplate ->
        ProviderDiscoveryAction.ContinueWithoutTemplate
    is FfiProviderDiscoveryAction.SupplyMoreEvidence ->
        ProviderDiscoveryAction.SupplyMoreEvidence(evidenceIds)
    FfiProviderDiscoveryAction.RequestAssistant -> ProviderDiscoveryAction.RequestAssistant
    is FfiProviderDiscoveryAction.ApproveAssistant ->
        ProviderDiscoveryAction.ApproveAssistant(approvalId, approvalGrantSha256)
    FfiProviderDiscoveryAction.DeclineAssistant -> ProviderDiscoveryAction.DeclineAssistant
    is FfiProviderDiscoveryAction.ApproveCredentialOrigin ->
        ProviderDiscoveryAction.ApproveCredentialOrigin(approvalId)
    is FfiProviderDiscoveryAction.ApproveProbes ->
        ProviderDiscoveryAction.ApproveProbes(approvalId, approvalGrantSha256)
    FfiProviderDiscoveryAction.SkipProbes -> ProviderDiscoveryAction.SkipProbes
    is FfiProviderDiscoveryAction.ApproveReview ->
        ProviderDiscoveryAction.ApproveReview(
            approvalId,
            commitAttemptId,
            commitPlanSha256,
            graphSha256,
        )
    FfiProviderDiscoveryAction.ResumeCompensation ->
        ProviderDiscoveryAction.ResumeCompensation
    FfiProviderDiscoveryAction.RestartInterrupted ->
        ProviderDiscoveryAction.RestartInterrupted
    is FfiProviderDiscoveryAction.ResolveUnknownOutcome ->
        ProviderDiscoveryAction.ResolveUnknownOutcome(
            approvalId,
            resolution.toAppModel(),
        )
    FfiProviderDiscoveryAction.Cancel -> ProviderDiscoveryAction.Cancel
}

private fun FfiProviderDiscoveryActionEnvelope.toAppModel():
    ProviderDiscoveryActionEnvelope = ProviderDiscoveryActionEnvelope(
    actionId = actionId,
    expectedRevision = expectedRevision,
    requestSha256 = requestSha256,
    action = action.toAppModel(),
)

private fun ProviderDiscoveryActionEnvelope.toFfiModel():
    FfiProviderDiscoveryActionEnvelope = FfiProviderDiscoveryActionEnvelope(
    actionId = actionId,
    expectedRevision = expectedRevision,
    requestSha256 = requestSha256,
    action = action.toFfiModel(),
)

private fun FfiDiscoveryFailure.toAppModel(): DiscoveryFailure = DiscoveryFailure(
    code = code,
    messageKey = messageKey,
    recoverable = recoverable,
)

private fun DiscoveryFailure.toFfiModel(): FfiDiscoveryFailure = FfiDiscoveryFailure(
    code = code,
    messageKey = messageKey,
    recoverable = recoverable,
)

private fun FfiDiscoveryProgress.toAppModel(): ProviderDiscoveryProgress =
    ProviderDiscoveryProgress(phase.toWireName(), completed, total)

private fun FfiDiscoveryActionRequired.toAppModel(): DiscoveryActionRequired = when (this) {
    FfiDiscoveryActionRequired.SelectTemplate -> DiscoveryActionRequired.SelectTemplate
    FfiDiscoveryActionRequired.SupplyMoreEvidence -> DiscoveryActionRequired.SupplyMoreEvidence
    FfiDiscoveryActionRequired.ApproveAssistant -> DiscoveryActionRequired.ApproveAssistant
    FfiDiscoveryActionRequired.ApproveCredentialOrigin ->
        DiscoveryActionRequired.ApproveCredentialOrigin
    FfiDiscoveryActionRequired.ApproveProbes -> DiscoveryActionRequired.ApproveProbes
    FfiDiscoveryActionRequired.Review -> DiscoveryActionRequired.Review
    is FfiDiscoveryActionRequired.RestartInterrupted ->
        DiscoveryActionRequired.RestartInterrupted(operation.toWireName())
    is FfiDiscoveryActionRequired.ReconcileUnknownOutcome ->
        DiscoveryActionRequired.ReconcileUnknownOutcome(operation.toWireName())
}

private fun FfiDiscoveryCandidateSummary.toAppModel(): DiscoveryCandidateSummary = when (this) {
    is FfiDiscoveryCandidateSummary.ProviderTemplate ->
        DiscoveryCandidateSummary.ProviderTemplate(templateId, templateVersion)
    is FfiDiscoveryCandidateSummary.ApiOrigin ->
        DiscoveryCandidateSummary.ApiOrigin(origin)
    is FfiDiscoveryCandidateSummary.OfficialDocument ->
        DiscoveryCandidateSummary.OfficialDocument(contentSha256)
    is FfiDiscoveryCandidateSummary.ModelRoute ->
        DiscoveryCandidateSummary.ModelRoute(modelId)
    is FfiDiscoveryCandidateSummary.ManifestDraft ->
        DiscoveryCandidateSummary.ManifestDraft(schemaVersion, manifestSha256)
}

private fun FfiDiscoveryCandidate.toAppModel(): DiscoveryCandidate = DiscoveryCandidate(
    id = id,
    proposedRevision = proposedRevision,
    summary = summary.toAppModel(),
    evidenceIds = evidenceIds,
    createdAt = createdAt,
)

private fun FfiDiscoveryEvidence.toAppModel(): DiscoveryEvidence = DiscoveryEvidence(
    id = id,
    kind = kind.toWireName(),
    contentSha256 = contentSha256,
    fetchedAt = fetchedAt,
)

private fun FfiDiscoveryApprovalGrant.toAppModel(): DiscoveryApprovalGrant = when (this) {
    is FfiDiscoveryApprovalGrant.TemplateSelection ->
        DiscoveryApprovalGrant.TemplateSelection(candidateId)
    is FfiDiscoveryApprovalGrant.AssistantConsent ->
        DiscoveryApprovalGrant.AssistantConsent(
            assistantModelRouteId,
            evidenceIds,
            allowedDocumentOrigins,
            maxCalls,
            maxInputTokens,
            maxOutputTokens,
            maxToolCalls,
            maxRetries,
            maxCostMicroUnits,
        )
    is FfiDiscoveryApprovalGrant.CredentialOrigin ->
        DiscoveryApprovalGrant.CredentialOrigin(
            origin,
            authBinding.toAppModel(),
            manifestSha256,
        )
    is FfiDiscoveryApprovalGrant.CapabilityProbe ->
        DiscoveryApprovalGrant.CapabilityProbe(
            modelRouteIds = modelRouteIds,
            budget = budget.toAppModel(),
        )
    is FfiDiscoveryApprovalGrant.Review ->
        DiscoveryApprovalGrant.Review(reviewSha256, graphSha256)
    is FfiDiscoveryApprovalGrant.UnknownOutcomeResolution ->
        DiscoveryApprovalGrant.UnknownOutcomeResolution(
            operation.toWireName(),
            resolution.toAppModel(),
        )
}

private fun FfiDiscoveryProbeBudget.toAppModel(): DiscoveryProbeBudget =
    DiscoveryProbeBudget(
        maxRequests = maxRequests,
        maxTotalTokensPerRequest = maxTotalTokensPerRequest,
        maxOutputTokensPerRequest = maxOutputTokensPerRequest,
        maxCostMicroUsdPerRequest = maxCostMicroUsdPerRequest,
        maxDurationMillisPerRequest = maxDurationMillisPerRequest,
        maxCallsPerRequest = maxCallsPerRequest,
    )

private fun FfiDiscoveryApprovalProposal.toAppModel(): DiscoveryApprovalProposal =
    DiscoveryApprovalProposal(
        approvalId = approvalId,
        grant = grant.toAppModel(),
        grantSha256 = grantSha256,
    )

private fun FfiDiscoveryApproval.toAppModel(): DiscoveryApproval = DiscoveryApproval(
    id = id,
    sessionRevision = sessionRevision,
    decision = decision.toWireName(),
    grant = grant.toAppModel(),
    createdAt = createdAt,
)

private fun FfiDiscoveryReviewChange.toAppModel(): DiscoveryReviewChange =
    DiscoveryReviewChange(
        kind = kind.toWireName(),
        targetKind = targetKind.toWireName(),
        targetId = targetId,
        summaryKey = summaryKey,
        evidenceIds = evidenceIds,
    )

private fun FfiDiscoveryReview.toAppModel(): DiscoveryReview = DiscoveryReview(
    sha256 = sha256,
    graphSha256 = graphSha256,
    changes = changes.map(FfiDiscoveryReviewChange::toAppModel),
    unresolvedQuestionCount = unresolvedQuestionCount,
    warningCount = warningCount,
)

private fun FfiDiscoveryReviewProposal.toAppModel(): DiscoveryReviewProposal =
    DiscoveryReviewProposal(
        review = review.toAppModel(),
        approval = approval.toAppModel(),
        commitAttemptId = commitAttemptId,
        commitPlanSha256 = commitPlanSha256,
        requestPreview = requestPreview?.toAppModel()?.also {
            check(it.isSafeToDisplay) {
                "Provider discovery review preview failed the redaction contract."
            }
        },
    )

private fun FfiProviderDiscoverySnapshot.toAppModel(): ProviderDiscoverySnapshot =
    ProviderDiscoverySnapshot(
        snapshotSchemaVersion = snapshotSchemaVersion,
        sessionId = sessionId,
        pendingConnectionId = pendingConnectionId,
        pendingDisplayName = pendingDisplayName,
        connectionOptions = connectionOptions.toAppModel(),
        credentialSlotId = credentialSlotId,
        credentialSlotExpected = credentialSlotExpected,
        revision = revision,
        state = state.toWireName(),
        nextEventSequence = nextEventSequence,
        steps = steps.map {
            DiscoveryStep(it.id, it.titleKey, it.state.toWireName())
        },
        actionRequired = actionRequired?.toAppModel(),
        activeOperationId = activeOperationId,
        recoveryOperation = recoveryOperation?.toWireName(),
        unknownOperation = unknownOperation?.toWireName(),
        manifestSha256 = manifestSha256,
        commitPlanSha256 = commitPlanSha256,
        commitAttemptId = commitAttemptId,
        committedConnectionId = committedConnectionId,
        cancellationPending = cancellationPending,
        failure = failure?.toAppModel(),
        candidates = candidates.map(FfiDiscoveryCandidate::toAppModel),
        evidence = evidence.map(FfiDiscoveryEvidence::toAppModel),
        approvals = approvals.map(FfiDiscoveryApproval::toAppModel),
        approvalProposal = approvalProposal?.toAppModel(),
        review = review?.toAppModel(),
        reviewProposal = reviewProposal?.toAppModel(),
        createdAt = createdAt,
        updatedAt = updatedAt,
        assistantResumeBoundary = assistantResumeBoundary?.toAppModel(),
    ).also(::validateProviderDiscoverySnapshotContract)

internal fun validateProviderDiscoverySnapshotContract(
    snapshot: ProviderDiscoverySnapshot,
) {
        check(snapshot.snapshotSchemaVersion == SUPPORTED_DISCOVERY_SNAPSHOT_SCHEMA_VERSION) {
            "Unsupported provider discovery snapshot schema version."
        }
        check(
            if (snapshot.credentialSlotExpected) {
                snapshot.credentialSlotId == snapshot.pendingConnectionId
            } else {
                snapshot.credentialSlotId == null
            },
        ) {
            "Provider discovery credential slot is not bound to its pending connection."
        }
        check(
            when (snapshot.connectionOptions.networkMode) {
                ProviderNetworkMode.ApprovedLocalNetwork ->
                    snapshot.connectionOptions.localNetworkApproval != null
                ProviderNetworkMode.Public,
                ProviderNetworkMode.LocalLoopback,
                -> snapshot.connectionOptions.localNetworkApproval == null
            },
        ) {
            "Provider discovery snapshot has an inconsistent network policy."
        }
    }

private fun FfiDiscoveryAssistantCheckpoint.toAppModel(): DiscoveryAssistantCheckpoint =
    when (this) {
        FfiDiscoveryAssistantCheckpoint.READY -> DiscoveryAssistantCheckpoint.Ready
        FfiDiscoveryAssistantCheckpoint.AWAITING_ASSISTANT ->
            DiscoveryAssistantCheckpoint.AwaitingAssistant
        FfiDiscoveryAssistantCheckpoint.AWAITING_TOOL_RESULT ->
            DiscoveryAssistantCheckpoint.AwaitingToolResult
        FfiDiscoveryAssistantCheckpoint.AWAITING_MORE_EVIDENCE ->
            DiscoveryAssistantCheckpoint.AwaitingMoreEvidence
        FfiDiscoveryAssistantCheckpoint.AWAITING_RETRY_CONSENT ->
            DiscoveryAssistantCheckpoint.AwaitingRetryConsent
        FfiDiscoveryAssistantCheckpoint.DRAFT_READY ->
            DiscoveryAssistantCheckpoint.DraftReady
    }

private fun FfiDiscoveryAssistantResumeAction.toAppModel(): DiscoveryAssistantResumeAction =
    when (this) {
        FfiDiscoveryAssistantResumeAction.APPROVE_CONSENT ->
            DiscoveryAssistantResumeAction.ApproveConsent
        FfiDiscoveryAssistantResumeAction.RUN_ASSISTANT ->
            DiscoveryAssistantResumeAction.RunAssistant
        FfiDiscoveryAssistantResumeAction.WAIT_FOR_ASSISTANT_OUTCOME ->
            DiscoveryAssistantResumeAction.WaitForAssistantOutcome
        FfiDiscoveryAssistantResumeAction.RESUME_CORE_HOST_ACTION ->
            DiscoveryAssistantResumeAction.ResumeCoreHostAction
        FfiDiscoveryAssistantResumeAction.SUPPLY_MORE_EVIDENCE ->
            DiscoveryAssistantResumeAction.SupplyMoreEvidence
        FfiDiscoveryAssistantResumeAction.APPROVE_RETRY ->
            DiscoveryAssistantResumeAction.ApproveRetry
        FfiDiscoveryAssistantResumeAction.REVIEW_DRAFT ->
            DiscoveryAssistantResumeAction.ReviewDraft
        FfiDiscoveryAssistantResumeAction.RESTART_INTERRUPTED ->
            DiscoveryAssistantResumeAction.RestartInterrupted
        FfiDiscoveryAssistantResumeAction.RESOLVE_UNKNOWN_OUTCOME ->
            DiscoveryAssistantResumeAction.ResolveUnknownOutcome
    }

private fun FfiDiscoveryAssistantResumeBoundary.toAppModel(): DiscoveryAssistantResumeBoundary =
    DiscoveryAssistantResumeBoundary(
        checkpoint = checkpoint?.toAppModel(),
        action = action.toAppModel(),
        questions = questions.map(FfiDiscoveryAssistantQuestion::toAppModel),
        draftReview = draftReview?.toAppModel(),
    )

private fun FfiProviderDiscoveryConnectionOptions.toAppModel():
    ProviderDiscoveryConnectionOptions = ProviderDiscoveryConnectionOptions(
    values = values.map(FfiConnectionConfigEntry::toAppModel),
    apiBasePath = apiBasePath,
    timeoutSeconds = timeoutSeconds,
    networkMode = networkMode.toAppModel(),
    localNetworkApproval = localNetworkApproval?.toAppModel(),
)

private fun FfiDiscoveryEvent.toAppModel(): DiscoveryEvent = DiscoveryEvent(
    eventVersion = eventVersion,
    eventId = eventId,
    sessionId = sessionId,
    sequence = sequence,
    sessionRevision = sessionRevision,
    state = state.toWireName(),
    progress = progress?.toAppModel(),
    actionRequired = actionRequired?.toAppModel(),
    warning = warning?.toWireName(),
    actionId = actionId,
    failure = failure?.toAppModel(),
).also {
    check(it.eventVersion == SUPPORTED_DISCOVERY_EVENT_VERSION) {
        "Unsupported provider discovery event version."
    }
}

private fun FfiDiscoveryOutboxEvent.toAppModel(): DiscoveryOutboxEvent =
    DiscoveryOutboxEvent(
        event = event.toAppModel(),
        deliveryAttempts = deliveryAttempts,
        availableAt = availableAt,
        createdAt = createdAt,
    )

private fun FfiDiscoveryRecoveryResult.toAppModel(): DiscoveryRecoveryResult =
    DiscoveryRecoveryResult(
        operationId = operationId,
        sessionId = sessionId,
        state = state.toWireName(),
        event = event.toAppModel(),
    )

private fun FfiDiscoveryState.toWireName(): String = when (this) {
    FfiDiscoveryState.DRAFT -> "draft"
    FfiDiscoveryState.RESOLVING_KNOWN_PROVIDER -> "resolving_known_provider"
    FfiDiscoveryState.AWAITING_TEMPLATE_SELECTION -> "awaiting_template_selection"
    FfiDiscoveryState.FETCHING_DOCUMENTS -> "fetching_documents"
    FfiDiscoveryState.EXTRACTING_EVIDENCE -> "extracting_evidence"
    FfiDiscoveryState.AWAITING_MORE_EVIDENCE -> "awaiting_more_evidence"
    FfiDiscoveryState.AWAITING_ASSISTANT_CONSENT -> "awaiting_assistant_consent"
    FfiDiscoveryState.BUILDING_DETERMINISTIC_MANIFEST_DRAFT ->
        "building_deterministic_manifest_draft"
    FfiDiscoveryState.BUILDING_ASSISTANT_MANIFEST_DRAFT -> "building_assistant_manifest_draft"
    FfiDiscoveryState.VALIDATING_MANIFEST -> "validating_manifest"
    FfiDiscoveryState.AWAITING_CREDENTIAL_ORIGIN_APPROVAL ->
        "awaiting_credential_origin_approval"
    FfiDiscoveryState.LISTING_MODELS -> "listing_models"
    FfiDiscoveryState.AWAITING_PROBE_CONSENT -> "awaiting_probe_consent"
    FfiDiscoveryState.PROBING_CAPABILITIES -> "probing_capabilities"
    FfiDiscoveryState.AWAITING_REVIEW -> "awaiting_review"
    FfiDiscoveryState.COMMITTING -> "committing"
    FfiDiscoveryState.COMPENSATING -> "compensating"
    FfiDiscoveryState.INTERRUPTED -> "interrupted"
    FfiDiscoveryState.UNKNOWN_OUTCOME -> "unknown_outcome"
    FfiDiscoveryState.READY -> "ready"
    FfiDiscoveryState.FAILED -> "failed"
    FfiDiscoveryState.CANCELLED -> "cancelled"
}

private fun FfiDiscoveryProgressPhase.toWireName(): String = when (this) {
    FfiDiscoveryProgressPhase.PROVIDER_CANDIDATES -> "provider_candidates"
    FfiDiscoveryProgressPhase.DOCUMENTS -> "documents"
    FfiDiscoveryProgressPhase.EVIDENCE -> "evidence"
    FfiDiscoveryProgressPhase.MODELS -> "models"
    FfiDiscoveryProgressPhase.PROBES -> "probes"
}

private fun FfiDiscoveryOperationKind.toWireName(): String = when (this) {
    FfiDiscoveryOperationKind.RESOLVE_KNOWN_PROVIDER -> "resolve_known_provider"
    FfiDiscoveryOperationKind.FETCH_DOCUMENTS -> "fetch_documents"
    FfiDiscoveryOperationKind.EXTRACT_EVIDENCE -> "extract_evidence"
    FfiDiscoveryOperationKind.BUILD_DETERMINISTIC_MANIFEST_DRAFT ->
        "build_deterministic_manifest_draft"
    FfiDiscoveryOperationKind.BUILD_ASSISTANT_MANIFEST_DRAFT ->
        "build_assistant_manifest_draft"
    FfiDiscoveryOperationKind.VALIDATE_MANIFEST -> "validate_manifest"
    FfiDiscoveryOperationKind.LIST_MODELS -> "list_models"
    FfiDiscoveryOperationKind.PROBE_CAPABILITIES -> "probe_capabilities"
    FfiDiscoveryOperationKind.ATOMIC_COMMIT -> "atomic_commit"
    FfiDiscoveryOperationKind.COMPENSATION -> "compensation"
}

private fun FfiDiscoveryStepState.toWireName(): String = when (this) {
    FfiDiscoveryStepState.COMPLETED -> "completed"
    FfiDiscoveryStepState.CURRENT -> "current"
    FfiDiscoveryStepState.PENDING -> "pending"
}

private fun FfiDiscoveryEvidenceKind.toWireName(): String = when (this) {
    FfiDiscoveryEvidenceKind.HTML_DOCUMENT -> "html_document"
    FfiDiscoveryEvidenceKind.JSON_DOCUMENT -> "json_document"
    FfiDiscoveryEvidenceKind.YAML_DOCUMENT -> "yaml_document"
    FfiDiscoveryEvidenceKind.XML_DOCUMENT -> "xml_document"
    FfiDiscoveryEvidenceKind.PLAIN_TEXT_DOCUMENT -> "plain_text_document"
    FfiDiscoveryEvidenceKind.JSON_SCHEMA -> "json_schema"
    FfiDiscoveryEvidenceKind.OPEN_API -> "open_api"
}

private fun FfiDiscoveryApprovalDecision.toWireName(): String = when (this) {
    FfiDiscoveryApprovalDecision.APPROVED -> "approved"
    FfiDiscoveryApprovalDecision.REJECTED -> "rejected"
}

private fun FfiDiscoveryReviewChangeKind.toWireName(): String = when (this) {
    FfiDiscoveryReviewChangeKind.ADD -> "add"
    FfiDiscoveryReviewChangeKind.UPDATE -> "update"
    FfiDiscoveryReviewChangeKind.DEPRECATE -> "deprecate"
    FfiDiscoveryReviewChangeKind.PRESERVE_MISSING -> "preserve_missing"
}

private fun FfiDiscoveryReviewTargetKind.toWireName(): String = when (this) {
    FfiDiscoveryReviewTargetKind.PROVIDER_TEMPLATE -> "provider_template"
    FfiDiscoveryReviewTargetKind.PROVIDER_CONNECTION -> "provider_connection"
    FfiDiscoveryReviewTargetKind.MODEL_ROUTE -> "model_route"
}

private fun FfiDiscoveryWarning.toWireName(): String = when (this) {
    FfiDiscoveryWarning.ASSISTANT_DECLINED -> "assistant_declined"
    FfiDiscoveryWarning.PROBES_SKIPPED -> "probes_skipped"
    FfiDiscoveryWarning.COMPENSATION_REQUIRED -> "compensation_required"
    FfiDiscoveryWarning.EXPLICIT_RESTART_REQUIRED -> "explicit_restart_required"
    FfiDiscoveryWarning.UNKNOWN_EXTERNAL_OUTCOME -> "unknown_external_outcome"
}

private fun FfiDiscoveryCompensationKind.toAppModel(): DiscoveryCompensationKind =
    when (this) {
        FfiDiscoveryCompensationKind.REMOVE_CREDENTIAL_SLOT ->
            DiscoveryCompensationKind.RemoveCredentialSlot
        FfiDiscoveryCompensationKind.REMOVE_CONNECTION_GRAPH ->
            DiscoveryCompensationKind.RemoveConnectionGraph
        FfiDiscoveryCompensationKind.RESTORE_PREVIOUS_SELECTION ->
            DiscoveryCompensationKind.RestorePreviousSelection
    }

private fun FfiDiscoveryCompensationStatus.toAppModel(): DiscoveryCompensationStatus =
    when (this) {
        FfiDiscoveryCompensationStatus.PENDING -> DiscoveryCompensationStatus.Pending
        FfiDiscoveryCompensationStatus.IN_PROGRESS -> DiscoveryCompensationStatus.InProgress
        FfiDiscoveryCompensationStatus.COMPLETED -> DiscoveryCompensationStatus.Completed
        FfiDiscoveryCompensationStatus.FAILED -> DiscoveryCompensationStatus.Failed
        FfiDiscoveryCompensationStatus.OUTCOME_UNKNOWN ->
            DiscoveryCompensationStatus.OutcomeUnknown
    }

private fun FfiDiscoveryPreviousSelection.toAppModel(): DiscoveryPreviousSelection =
    when (this) {
        FfiDiscoveryPreviousSelection.None -> DiscoveryPreviousSelection.None
        is FfiDiscoveryPreviousSelection.RouteAndPreset ->
            DiscoveryPreviousSelection.RouteAndPreset(
                modelRouteId = modelRouteId,
                generationPresetId = generationPresetId,
            )
    }

private fun FfiDiscoveryCompensationTarget.toAppModel(): DiscoveryCompensationTarget =
    when (this) {
        is FfiDiscoveryCompensationTarget.RemoveCredentialSlot ->
            DiscoveryCompensationTarget.RemoveCredentialSlot(
                connectionId = connectionId,
                credentialRef = credentialRef,
            )
        is FfiDiscoveryCompensationTarget.RemoveConnectionGraph ->
            DiscoveryCompensationTarget.RemoveConnectionGraph(connectionId)
        is FfiDiscoveryCompensationTarget.RestorePreviousSelection ->
            DiscoveryCompensationTarget.RestorePreviousSelection(
                previousSelection.toAppModel(),
            )
    }

private fun FfiDiscoveryCompensationStep.toAppModel(): DiscoveryCompensationStep =
    DiscoveryCompensationStep(
        id = id,
        commitAttemptId = commitAttemptId,
        ordinal = ordinal,
        actionId = actionId,
        kind = kind.toAppModel(),
        target = target.toAppModel(),
        status = status.toAppModel(),
        attemptCount = attemptCount,
        lastFailure = lastFailure?.toAppModel(),
        createdAt = createdAt,
        updatedAt = updatedAt,
        completedAt = completedAt,
    )

private fun FfiProviderCatalogStatus.toAppModel(): ProviderCatalogStatus =
    ProviderCatalogStatus(
        statusSchemaVersion = statusSchemaVersion,
        stateVersion = stateVersion,
        activeRevision = activeRevision,
        activeSnapshotSha256 = activeSnapshotSha256,
        bundledBaselineSha256 = bundledBaselineSha256,
        snapshotCount = snapshotCount,
        signedUpdateCount = signedUpdateCount,
        highestAcceptedRevision = highestAcceptedRevision,
        latestIssuedAt = latestIssuedAt,
        activeSignedRevisions = activeSignedRevisions,
    ).also {
        check(it.statusSchemaVersion == SUPPORTED_CATALOG_STATUS_SCHEMA_VERSION) {
            "Unsupported provider catalog status schema version."
        }
    }

private fun FfiProviderCatalogRevision.toAppModel(): ProviderCatalogRevision =
    ProviderCatalogRevision(
        revision = revision,
        capturedAt = capturedAt,
        snapshotSha256 = snapshotSha256,
        signedRevisions = signedRevisions,
        active = active,
    )

private fun FfiProviderCatalogActivation.toAppModel(): ProviderCatalogActivation =
    ProviderCatalogActivation(
        actionId = actionId,
        stateVersion = stateVersion,
        kind = kind,
        fromRevision = fromRevision,
        toRevision = toRevision,
        activatedAt = activatedAt,
        diff = diff.toAppModel(),
    )

private fun FfiProviderCatalogHistory.toAppModel(): ProviderCatalogHistory =
    ProviderCatalogHistory(
        historySchemaVersion = historySchemaVersion,
        activeRevision = activeRevision,
        revisions = revisions.map(FfiProviderCatalogRevision::toAppModel),
        activations = activations.map(FfiProviderCatalogActivation::toAppModel),
        nextBeforeRevision = nextBeforeRevision,
        nextBeforeStateVersion = nextBeforeStateVersion,
    ).also {
        check(it.historySchemaVersion == SUPPORTED_CATALOG_HISTORY_SCHEMA_VERSION) {
            "Unsupported provider catalog history schema version."
        }
    }

private fun FfiProviderCatalogTemplateChangedSection.toWireName(): String = when (this) {
    FfiProviderCatalogTemplateChangedSection.DISPLAY_NAME -> "display_name"
    FfiProviderCatalogTemplateChangedSection.MANIFEST_VERSION -> "manifest_version"
    FfiProviderCatalogTemplateChangedSection.CONNECTION_FIELDS -> "connection_fields"
    FfiProviderCatalogTemplateChangedSection.API_FAMILY -> "api_family"
    FfiProviderCatalogTemplateChangedSection.SOURCES -> "sources"
    FfiProviderCatalogTemplateChangedSection.ORIGIN -> "origin"
    FfiProviderCatalogTemplateChangedSection.AUTHENTICATION -> "authentication"
    FfiProviderCatalogTemplateChangedSection.ENDPOINTS -> "endpoints"
    FfiProviderCatalogTemplateChangedSection.DECODERS -> "decoders"
    FfiProviderCatalogTemplateChangedSection.PARAMETERS -> "parameters"
    FfiProviderCatalogTemplateChangedSection.FRESHNESS -> "freshness"
}

private fun FfiProviderCatalogModelChangedSection.toWireName(): String = when (this) {
    FfiProviderCatalogModelChangedSection.MATCH -> "match"
    FfiProviderCatalogModelChangedSection.API_FAMILY -> "api_family"
    FfiProviderCatalogModelChangedSection.METADATA_VERSION -> "metadata_version"
    FfiProviderCatalogModelChangedSection.CAPABILITIES -> "capabilities"
    FfiProviderCatalogModelChangedSection.PARAMETERS -> "parameters"
    FfiProviderCatalogModelChangedSection.LIFECYCLE -> "lifecycle"
    FfiProviderCatalogModelChangedSection.SOURCES -> "sources"
    FfiProviderCatalogModelChangedSection.FRESHNESS -> "freshness"
}

private fun FfiProviderCatalogTemplateDiffEntry.toAppModel():
    ProviderCatalogManifestChange = ProviderCatalogManifestChange(
    providerTemplateId = providerTemplateId,
    previousManifestVersion = previousManifestVersion,
    nextManifestVersion = nextManifestVersion,
    previousSha256 = previousSha256,
    nextSha256 = nextSha256,
    changedSections = changedSections.map(
        FfiProviderCatalogTemplateChangedSection::toWireName,
    ),
)

private fun FfiProviderCatalogModelDiffEntry.toAppModel():
    ProviderCatalogModelChange = ProviderCatalogModelChange(
    modelEntryId = modelEntryId,
    providerTemplateId = providerTemplateId,
    previousMetadataVersion = previousMetadataVersion,
    nextMetadataVersion = nextMetadataVersion,
    previousSha256 = previousSha256,
    nextSha256 = nextSha256,
    changedSections = changedSections.map(
        FfiProviderCatalogModelChangedSection::toWireName,
    ),
)

private fun FfiProviderCatalogDiff.toAppModel(): ProviderCatalogDiff =
    ProviderCatalogDiff(
        diffSchemaVersion = diffSchemaVersion,
        fromRevision = fromRevision,
        toRevision = toRevision,
        addedProviderTemplates =
            addedProviderTemplates.map(FfiProviderCatalogTemplateDiffEntry::toAppModel),
        changedProviderTemplates =
            changedProviderTemplates.map(FfiProviderCatalogTemplateDiffEntry::toAppModel),
        removedProviderTemplates =
            removedProviderTemplates.map(FfiProviderCatalogTemplateDiffEntry::toAppModel),
        addedModels = addedModels.map(FfiProviderCatalogModelDiffEntry::toAppModel),
        changedModels = changedModels.map(FfiProviderCatalogModelDiffEntry::toAppModel),
        removedModels = removedModels.map(FfiProviderCatalogModelDiffEntry::toAppModel),
    ).also {
        check(it.diffSchemaVersion == SUPPORTED_CATALOG_DIFF_SCHEMA_VERSION) {
            "Unsupported provider catalog diff schema version."
        }
    }

private fun FfiProviderCatalogImportReview.toAppModel(): ProviderCatalogImportReview =
    ProviderCatalogImportReview(
        planSchemaVersion = planSchemaVersion,
        actionId = actionId,
        expectedStateVersion = expectedStateVersion,
        expectedActiveRevision = expectedActiveRevision,
        expectedActiveSnapshotSha256 = expectedActiveSnapshotSha256,
        expectedHighestAcceptedRevision = expectedHighestAcceptedRevision,
        envelopeByteCount = envelopeByteCount,
        envelopeSha256 = envelopeSha256,
        signingKeyId = signingKeyId,
        payloadSha256 = payloadSha256,
        signedCatalogRevision = signedCatalogRevision,
        candidateRevision = candidateRevision,
        candidateSnapshotSha256 = candidateSnapshotSha256,
        preparedAt = preparedAt,
        expiresAt = expiresAt,
        diff = diff.toAppModel(),
    )

private fun FfiProviderCatalogImportPlan.toAppModel(): ProviderCatalogImportPlan =
    ProviderCatalogImportPlan(
        review = review.toAppModel(),
        planSha256 = planSha256,
        opaquePlanJson = planJson,
    ).also {
        check(
            it.review.planSchemaVersion == SUPPORTED_CATALOG_IMPORT_PLAN_SCHEMA_VERSION,
        ) {
            "Unsupported provider catalog import plan schema version."
        }
    }

private fun FfiProviderCatalogImportResult.toAppModel(): ProviderCatalogImportResult =
    ProviderCatalogImportResult(
        signedCatalogRevision = signedCatalogRevision,
        activatedRevision = activatedRevision,
        diff = diff.toAppModel(),
        status = status.toAppModel(),
    )

private fun ProviderCatalogImportPlan.toFfiModel(): FfiProviderCatalogImportPlan =
    FfiProviderCatalogImportPlan(
        review = review.toFfiModel(),
        planSha256 = planSha256,
        planJson = opaquePlanJson,
    )

private fun ProviderCatalogImportReview.toFfiModel(): FfiProviderCatalogImportReview =
    FfiProviderCatalogImportReview(
        planSchemaVersion = planSchemaVersion,
        actionId = actionId,
        expectedStateVersion = expectedStateVersion,
        expectedActiveRevision = expectedActiveRevision,
        expectedActiveSnapshotSha256 = expectedActiveSnapshotSha256,
        expectedHighestAcceptedRevision = expectedHighestAcceptedRevision,
        envelopeByteCount = envelopeByteCount,
        envelopeSha256 = envelopeSha256,
        signingKeyId = signingKeyId,
        payloadSha256 = payloadSha256,
        signedCatalogRevision = signedCatalogRevision,
        candidateRevision = candidateRevision,
        candidateSnapshotSha256 = candidateSnapshotSha256,
        preparedAt = preparedAt,
        expiresAt = expiresAt,
        diff = diff.toFfiModel(),
    )

private fun ProviderCatalogDiff.toFfiModel(): FfiProviderCatalogDiff =
    FfiProviderCatalogDiff(
        diffSchemaVersion = diffSchemaVersion,
        fromRevision = fromRevision,
        toRevision = toRevision,
        addedProviderTemplates =
            addedProviderTemplates.map(ProviderCatalogManifestChange::toFfiModel),
        changedProviderTemplates =
            changedProviderTemplates.map(ProviderCatalogManifestChange::toFfiModel),
        removedProviderTemplates =
            removedProviderTemplates.map(ProviderCatalogManifestChange::toFfiModel),
        addedModels = addedModels.map(ProviderCatalogModelChange::toFfiModel),
        changedModels = changedModels.map(ProviderCatalogModelChange::toFfiModel),
        removedModels = removedModels.map(ProviderCatalogModelChange::toFfiModel),
    )

private fun ProviderCatalogManifestChange.toFfiModel():
    FfiProviderCatalogTemplateDiffEntry = FfiProviderCatalogTemplateDiffEntry(
    providerTemplateId = providerTemplateId,
    previousManifestVersion = previousManifestVersion,
    nextManifestVersion = nextManifestVersion,
    previousSha256 = previousSha256,
    nextSha256 = nextSha256,
    changedSections = changedSections.map(::templateChangedSectionFromWireName),
)

private fun ProviderCatalogModelChange.toFfiModel():
    FfiProviderCatalogModelDiffEntry = FfiProviderCatalogModelDiffEntry(
    modelEntryId = modelEntryId,
    providerTemplateId = providerTemplateId,
    previousMetadataVersion = previousMetadataVersion,
    nextMetadataVersion = nextMetadataVersion,
    previousSha256 = previousSha256,
    nextSha256 = nextSha256,
    changedSections = changedSections.map(::modelChangedSectionFromWireName),
)

private fun templateChangedSectionFromWireName(
    value: String,
): FfiProviderCatalogTemplateChangedSection = when (value) {
    "display_name" -> FfiProviderCatalogTemplateChangedSection.DISPLAY_NAME
    "manifest_version" -> FfiProviderCatalogTemplateChangedSection.MANIFEST_VERSION
    "connection_fields" -> FfiProviderCatalogTemplateChangedSection.CONNECTION_FIELDS
    "api_family" -> FfiProviderCatalogTemplateChangedSection.API_FAMILY
    "sources" -> FfiProviderCatalogTemplateChangedSection.SOURCES
    "origin" -> FfiProviderCatalogTemplateChangedSection.ORIGIN
    "authentication" -> FfiProviderCatalogTemplateChangedSection.AUTHENTICATION
    "endpoints" -> FfiProviderCatalogTemplateChangedSection.ENDPOINTS
    "decoders" -> FfiProviderCatalogTemplateChangedSection.DECODERS
    "parameters" -> FfiProviderCatalogTemplateChangedSection.PARAMETERS
    "freshness" -> FfiProviderCatalogTemplateChangedSection.FRESHNESS
    else -> error("Unsupported provider catalog template changed section.")
}

private fun modelChangedSectionFromWireName(
    value: String,
): FfiProviderCatalogModelChangedSection = when (value) {
    "match" -> FfiProviderCatalogModelChangedSection.MATCH
    "api_family" -> FfiProviderCatalogModelChangedSection.API_FAMILY
    "metadata_version" -> FfiProviderCatalogModelChangedSection.METADATA_VERSION
    "capabilities" -> FfiProviderCatalogModelChangedSection.CAPABILITIES
    "parameters" -> FfiProviderCatalogModelChangedSection.PARAMETERS
    "lifecycle" -> FfiProviderCatalogModelChangedSection.LIFECYCLE
    "sources" -> FfiProviderCatalogModelChangedSection.SOURCES
    "freshness" -> FfiProviderCatalogModelChangedSection.FRESHNESS
    else -> error("Unsupported provider catalog model changed section.")
}

private fun FfiProviderCatalogRollbackPlan.toAppModel(): ProviderCatalogRollbackPlan =
    ProviderCatalogRollbackPlan(
        planSchemaVersion = planSchemaVersion,
        actionId = actionId,
        expectedStateVersion = expectedStateVersion,
        planSha256 = planSha256,
        fromRevision = fromRevision,
        toRevision = toRevision,
        createdAt = createdAt,
        expiresAt = expiresAt,
        diff = diff.toAppModel(),
        opaquePlanJson = planJson,
    ).also {
        check(it.planSchemaVersion == SUPPORTED_CATALOG_ROLLBACK_PLAN_SCHEMA_VERSION) {
            "Unsupported provider catalog rollback plan schema version."
        }
    }

private fun ProviderCatalogRollbackPlan.toFfiModel(): FfiProviderCatalogRollbackPlan =
    FfiProviderCatalogRollbackPlan(
        planSchemaVersion = planSchemaVersion,
        actionId = actionId,
        expectedStateVersion = expectedStateVersion,
        planSha256 = planSha256,
        fromRevision = fromRevision,
        toRevision = toRevision,
        createdAt = createdAt,
        expiresAt = expiresAt,
        diff = diff.toFfiModel(),
        planJson = opaquePlanJson,
    )

private fun FfiProviderCatalogRollbackResult.toAppModel(): ProviderCatalogRollbackResult =
    ProviderCatalogRollbackResult(
        fromRevision = fromRevision,
        activatedRevision = activatedRevision,
        status = status.toAppModel(),
    )

private const val SUPPORTED_CURL_INSPECTION_SCHEMA_VERSION = 1u
private const val SUPPORTED_DISCOVERY_SNAPSHOT_SCHEMA_VERSION = 3u
private const val SUPPORTED_DISCOVERY_EVENT_VERSION = 2u
private const val SUPPORTED_CATALOG_STATUS_SCHEMA_VERSION = 1u
private const val SUPPORTED_CATALOG_HISTORY_SCHEMA_VERSION = 1u
private const val SUPPORTED_CATALOG_DIFF_SCHEMA_VERSION = 1u
private const val SUPPORTED_CATALOG_IMPORT_PLAN_SCHEMA_VERSION = 1u
private const val SUPPORTED_CATALOG_ROLLBACK_PLAN_SCHEMA_VERSION = 1u
