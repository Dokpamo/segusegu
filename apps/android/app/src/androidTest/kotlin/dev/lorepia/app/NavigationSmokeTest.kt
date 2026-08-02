package dev.lorepia.app

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import dev.lorepia.app.app.LorepiaApp
import dev.lorepia.app.bridge.*
import dev.lorepia.app.platform.credentials.CredentialStore
import dev.lorepia.app.platform.credentials.CredentialRecordStatus
import org.junit.Rule
import org.junit.Test

class NavigationSmokeTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun primaryDestinationsAreReachable() {
        composeRule.setContent {
            LorepiaApp(
                coreClientFactory = { InstrumentedFakeCoreClient() },
                credentialStore = InstrumentedCredentialStore,
            )
        }

        composeRule.waitUntil(timeoutMillis = 5_000) {
            composeRule.onAllNodesWithText("서재").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText("채팅").performClick()
        composeRule.onNodeWithText("열린 대화가 없습니다").assertIsDisplayed()

        composeRule.onNodeWithText("설정").performClick()
        composeRule.onNodeWithText("이 기기에 저장됨").assertIsDisplayed()
    }

    @Test
    fun libraryCharacterOpensCharacterChat() {
        composeRule.setContent {
            LorepiaApp(
                coreClientFactory = { InstrumentedFakeCoreClient() },
                credentialStore = InstrumentedCredentialStore,
            )
        }

        composeRule.waitUntil(timeoutMillis = 5_000) {
            composeRule.onAllNodesWithText("합성 캐릭터").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText("합성 캐릭터").performClick()
        composeRule.waitUntil(timeoutMillis = 5_000) {
            composeRule.onAllNodesWithText(
                "메시지를 보내려면 설정에서 AI 연결의 model route와 " +
                    "generation preset을 선택하세요.",
            ).fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText(
            "메시지를 보내려면 설정에서 AI 연결의 model route와 " +
                "generation preset을 선택하세요.",
        ).assertIsDisplayed()
    }
}

private class InstrumentedFakeCoreClient : CoreClient {
    private val health = CoreHealthStatus(
        coreVersion = "instrumented-test",
        databaseOpen = true,
        schemaVersion = 1,
        dataRootWritable = true,
        stagingWritable = true,
        recoveryPending = false,
        activeJobs = 0,
    )
    private val character = CharacterSummary(
        id = "character-1",
        name = "합성 캐릭터",
        description = "합성 설명",
        sourceHash = "a".repeat(64),
    )
    private val conversations = mutableListOf<ConversationSummary>()

    override suspend fun coreVersion(): String = health.coreVersion

    override suspend fun healthCheck(): CoreHealthStatus = health

    override suspend fun versionInfo(): CoreVersionInfo = CoreVersionInfo(
        coreVersion = health.coreVersion,
        coreApiVersion = 8u,
        bindingApiVersion = 8u,
        chatEventVersion = 4u,
    )

    override suspend fun databaseStats(): DatabaseStats =
        DatabaseStats(0uL, 0uL, 0uL, 0uL)

    override suspend fun listCharacters(): List<CharacterSummary> = listOf(character)

    override suspend fun getCharacter(characterId: String): CharacterSummary =
        character.takeIf { it.id == characterId } ?: error("Character not found.")

    override suspend fun inspectImport(stagedPath: String): ImportInspection =
        error("The navigation smoke test does not select a document.")

    override suspend fun commitImport(inspectionId: String): CharacterSummary =
        error("The navigation smoke test does not commit an import.")

    override suspend fun discardImport(inspectionId: String) = Unit

    override suspend fun listConversations(): List<ConversationSummary> =
        conversations.toList()

    override suspend fun openConversation(characterId: String): ConversationSummary =
        ConversationSummary(
            id = "conversation-${conversations.size + 1}",
            characterId = characterId,
            title = character.name,
            createdAt = "2026-01-01T00:00:00Z",
            updatedAt = "2026-01-01T00:00:00Z",
        ).also(conversations::add)

    override suspend fun listMessages(conversationId: String): List<ChatMessage> = emptyList()

    override suspend fun sendMessage(
        conversationId: String,
        text: String,
        providerProfileId: String,
        credential: String?,
    ): String = error("No provider is configured.")

    override suspend fun sendMessageWithTarget(
        conversationId: String,
        text: String,
        target: GenerationTarget,
        credential: String?,
    ): String = error("No provider is configured.")

    override suspend fun cancelGeneration(generationId: String) = Unit

    override suspend fun pollEvents(maxEvents: UInt): ChatEventBatch =
        ChatEventBatch(emptyList(), 0uL)

    override suspend fun getSettings(): AppSettings = AppSettings(false, null)

    override suspend fun updateSettings(settings: AppSettings): AppSettings = settings

    override suspend fun listProviderProfiles(): List<ProviderProfile> = emptyList()

    override suspend fun upsertProviderProfile(profile: ProviderProfile): ProviderProfile = profile

    override suspend fun deleteProviderProfile(profileId: String) = Unit

    override suspend fun listProviderTemplates(): List<ProviderTemplate> = emptyList()

    override suspend fun inspectProviderCurl(
        rawCurl: String,
        networkPolicy: ProviderNetworkPolicy,
    ): ProviderCurlInspection = error("No provider discovery is configured.")

    override suspend fun takeProviderCurlCredential(
        credentialHandoffId: String,
    ): ByteArray? = null

    override suspend fun beginProviderDiscovery(
        input: ProviderDiscoveryInput,
        source: ProviderDiscoverySource,
        rawCurl: String?,
    ): ProviderDiscoverySnapshot = error("No provider discovery is configured.")

    override suspend fun prepareProviderDiscoveryAction(
        actionId: String,
        expectedRevision: ULong,
        action: ProviderDiscoveryAction,
    ): ProviderDiscoveryActionEnvelope = error("No provider discovery is configured.")

    override suspend fun getProviderDiscovery(
        sessionId: String,
    ): ProviderDiscoverySnapshot = error("No provider discovery is configured.")

    override suspend fun listProviderDiscoveries(
        limit: UInt,
    ): List<ProviderDiscoverySnapshot> = emptyList()

    override suspend fun continueProviderDiscovery(
        sessionId: String,
        envelope: ProviderDiscoveryActionEnvelope,
        credential: String?,
    ): ProviderDiscoverySnapshot = error("No provider discovery is configured.")

    override suspend fun supplyProviderDiscoveryDocumentEvidence(
        sessionId: String,
        expectedRevision: ULong,
        documentUrl: String,
    ): ProviderDiscoverySnapshot = error("No provider discovery is configured.")

    override suspend fun supplyProviderDiscoveryCurlEvidence(
        sessionId: String,
        expectedRevision: ULong,
        rawCurl: String,
    ): ProviderDiscoverySnapshot = error("No provider discovery is configured.")

    override suspend fun cancelProviderDiscovery(
        sessionId: String,
        expectedRevision: ULong,
    ): ProviderDiscoverySnapshot = error("No provider discovery is configured.")

    override suspend fun commitProviderDiscovery(
        sessionId: String,
        credentialReferenceConfirmed: Boolean,
    ): ProviderConnection = error("No provider discovery is configured.")

    override suspend fun listProviderDiscoveryCompensationSteps(
        commitAttemptId: String,
    ): List<DiscoveryCompensationStep> = emptyList()

    override suspend fun continueProviderDiscoveryCompensation(
        sessionId: String,
    ): ProviderDiscoverySnapshot = error("No provider discovery is configured.")

    override suspend fun startProviderDiscoveryCredentialCompensation(
        sessionId: String,
        stepId: String,
    ): DiscoveryCompensationStep = error("No provider discovery is configured.")

    override suspend fun completeProviderDiscoveryCredentialCompensation(
        sessionId: String,
        stepId: String,
    ): ProviderDiscoverySnapshot = error("No provider discovery is configured.")

    override suspend fun failProviderDiscoveryCredentialCompensation(
        sessionId: String,
        stepId: String,
        failure: DiscoveryFailure,
    ): ProviderDiscoverySnapshot = error("No provider discovery is configured.")

    override suspend fun markProviderDiscoveryCredentialCompensationUnknown(
        sessionId: String,
        stepId: String,
    ): ProviderDiscoverySnapshot = error("No provider discovery is configured.")

    override suspend fun resumeProviderDiscoveryCompensation(
        sessionId: String,
    ): ProviderDiscoverySnapshot = error("No provider discovery is configured.")

    override suspend fun recoverProviderDiscoveries(): List<DiscoveryRecoveryResult> = emptyList()

    override suspend fun pollProviderDiscoveryEvents(
        limit: UInt,
    ): List<DiscoveryOutboxEvent> = emptyList()

    override suspend fun ackProviderDiscoveryEvent(eventId: String): Boolean = true

    override suspend fun runProviderDiscoveryAssistantTurn(
        sessionId: String,
        estimate: DiscoveryAssistantCallEstimate,
        assistantCredential: String?,
    ): DiscoveryAssistantOutcome = error("No provider discovery is configured.")

    override suspend fun approveProviderDiscoveryAssistantRetry(
        sessionId: String,
    ): ProviderDiscoverySnapshot = error("No provider discovery is configured.")

    override suspend fun requestProviderDiscoveryAssistantRevision(
        sessionId: String,
    ): ProviderDiscoverySnapshot = error("No provider discovery is configured.")

    override suspend fun acceptProviderDiscoveryAssistantDraft(
        sessionId: String,
    ): ProviderDiscoverySnapshot = error("No provider discovery is configured.")

    override suspend fun resumeProviderDiscoveryAssistantCoreHostAction(
        sessionId: String,
    ): ProviderDiscoverySnapshot = error("No provider discovery is configured.")

    override suspend fun recordProviderDiscoveryAssistantFailure(
        sessionId: String,
        kind: String,
        retryable: Boolean,
    ): ProviderDiscoverySnapshot = error("No provider discovery is configured.")

    override suspend fun createProviderConnection(
        draft: ProviderConnectionDraft,
    ): ProviderConnection = error("No provider is configured.")

    override suspend fun listProviderConnections(): List<ProviderConnection> = emptyList()

    override suspend fun upsertProviderConnection(
        connection: ProviderConnection,
    ): ProviderConnection = connection

    override suspend fun deleteProviderConnection(connectionId: String) = Unit

    override suspend fun listModelRoutes(connectionId: String): List<ModelRoute> = emptyList()

    override suspend fun startProviderModelSync(
        connectionId: String,
        credential: String?,
    ): String = error("No provider is configured.")

    override suspend fun getProviderModelSync(jobId: String): ModelSyncJob =
        error("No model sync exists.")

    override suspend fun listProviderModelSyncs(
        connectionId: String,
        limit: UInt,
    ): List<ModelSyncJob> = emptyList()

    override suspend fun approveProviderModelSync(
        jobId: String,
        reviewSha256: String,
    ): ModelSyncJob = error("No model sync exists.")

    override suspend fun cancelProviderModelSync(jobId: String): ModelSyncJob =
        error("No model sync exists.")

    override suspend fun pollProviderModelSyncJobEvents(
        jobId: String,
        limit: UInt,
    ): List<ModelSyncEvent> = emptyList()

    override suspend fun ackProviderModelSyncEvent(
        jobId: String,
        sequence: ULong,
    ): Boolean = true

    override suspend fun providerCatalogStatus(): ProviderCatalogStatus =
        ProviderCatalogStatus(
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

    override suspend fun providerCatalogHistory(
        limit: UInt,
        beforeRevision: ULong?,
        beforeStateVersion: ULong?,
    ): ProviderCatalogHistory = ProviderCatalogHistory(
        historySchemaVersion = 1u,
        activeRevision = 1uL,
        revisions = emptyList(),
        activations = emptyList(),
        nextBeforeRevision = null,
        nextBeforeStateVersion = null,
    )

    override suspend fun prepareSignedProviderCatalogImport(
        envelopeJson: ByteArray,
    ): ProviderCatalogImportPlan = error("No catalog import is configured.")

    override suspend fun activateSignedProviderCatalogImport(
        plan: ProviderCatalogImportPlan,
        envelopeJson: ByteArray,
    ): ProviderCatalogImportResult = error("No catalog import is configured.")

    override suspend fun diffProviderCatalogRevisions(
        fromRevision: ULong,
        toRevision: ULong,
    ): ProviderCatalogDiff = error("No catalog diff is configured.")

    override suspend fun prepareProviderCatalogRollback(
        targetRevision: ULong,
    ): ProviderCatalogRollbackPlan = error("No catalog rollback is configured.")

    override suspend fun activateProviderCatalogRollback(
        plan: ProviderCatalogRollbackPlan,
    ): ProviderCatalogRollbackResult = error("No catalog rollback is configured.")

    override suspend fun listGenerationPresets(
        modelRouteId: String,
    ): List<GenerationPreset> = emptyList()

    override suspend fun upsertGenerationPreset(
        preset: GenerationPreset,
    ): GenerationPreset = preset

    override suspend fun validateGenerationPresetCandidate(preset: GenerationPreset) = Unit

    override suspend fun renderReasoningControlForPreset(
        preset: GenerationPreset,
    ): ReasoningControl = error("No generation preset exists.")

    override suspend fun renderPromptCacheControlForPreset(
        preset: GenerationPreset,
    ): PromptCacheControl = error("No generation preset exists.")

    override suspend fun previewProviderRequestCandidate(
        preset: GenerationPreset,
    ): RequestPreview = error("No generation preset exists.")

    override suspend fun validateGenerationPreset(
        modelRouteId: String,
        generationPresetId: String,
    ) = Unit

    override suspend fun previewProviderRequest(
        modelRouteId: String,
        generationPresetId: String,
    ): RequestPreview = error("No generation preset exists.")

    override suspend fun deleteGenerationPreset(generationPresetId: String) = Unit

    override suspend fun listCapabilityObservations(
        modelRouteId: String,
    ): List<CapabilityObservation> = emptyList()

    override suspend fun effectiveCapability(
        modelRouteId: String,
        key: String,
    ): EffectiveCapability? = null

    override suspend fun effectiveParameterSpecs(modelRouteId: String): List<ParameterSpec> =
        emptyList()

    override suspend fun selectGenerationTarget(target: GenerationTarget?): AppSettings =
        getSettings().copy(
            selectedProviderProfileId = null,
            selectedModelRouteId = target?.modelRouteId,
            selectedGenerationPresetId = target?.generationPresetId,
        )

    override fun close() = Unit
}

private object InstrumentedCredentialStore : CredentialStore {
    override suspend fun read(credentialRef: String): String? = null

    override suspend fun inspect(credentialRef: String): CredentialRecordStatus =
        CredentialRecordStatus.Missing

    override suspend fun write(credentialRef: String, credential: String) = Unit

    override suspend fun writeBytes(credentialRef: String, credential: ByteArray) = Unit

    override suspend fun delete(credentialRef: String) = Unit
}
