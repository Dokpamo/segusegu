package dev.lorepia.app.bridge

/**
 * Kotlin-facing boundary for the platform-independent Rust core.
 *
 * UI and ViewModel code depend on this interface instead of generated UniFFI
 * classes. The adapter contains mapping only; product decisions stay in Rust
 * or in the native UI layer that owns them.
 */
interface CoreClient : AutoCloseable {
    suspend fun coreVersion(): String

    suspend fun versionInfo(): CoreVersionInfo

    suspend fun healthCheck(): CoreHealthStatus

    suspend fun databaseStats(): DatabaseStats

    suspend fun listCharacters(): List<CharacterSummary>

    suspend fun getCharacter(characterId: String): CharacterSummary

    suspend fun inspectImport(stagedPath: String): ImportInspection

    suspend fun commitImport(inspectionId: String): CharacterSummary

    suspend fun discardImport(inspectionId: String)

    suspend fun listConversations(): List<ConversationSummary>

    suspend fun openConversation(characterId: String): ConversationSummary

    suspend fun listMessages(conversationId: String): List<ChatMessage>

    suspend fun sendMessage(
        conversationId: String,
        text: String,
        providerProfileId: String,
        credential: String?,
    ): String

    suspend fun sendMessageWithTarget(
        conversationId: String,
        text: String,
        target: GenerationTarget,
        credential: String?,
    ): String

    suspend fun cancelGeneration(generationId: String)

    suspend fun pollEvents(maxEvents: UInt = 64u): ChatEventBatch

    suspend fun getSettings(): AppSettings

    suspend fun updateSettings(settings: AppSettings): AppSettings

    suspend fun listProviderProfiles(): List<ProviderProfile>

    suspend fun upsertProviderProfile(profile: ProviderProfile): ProviderProfile

    suspend fun deleteProviderProfile(profileId: String)

    suspend fun listProviderTemplates(): List<ProviderTemplate>

    suspend fun inspectProviderCurl(
        rawCurl: String,
        networkPolicy: ProviderNetworkPolicy,
    ): ProviderCurlInspection

    suspend fun takeProviderCurlCredential(
        credentialHandoffId: String,
    ): ByteArray?

    suspend fun beginProviderDiscovery(
        input: ProviderDiscoveryInput,
        source: ProviderDiscoverySource,
        rawCurl: String?,
    ): ProviderDiscoverySnapshot

    suspend fun prepareProviderDiscoveryAction(
        actionId: String,
        expectedRevision: ULong,
        action: ProviderDiscoveryAction,
    ): ProviderDiscoveryActionEnvelope

    suspend fun getProviderDiscovery(
        sessionId: String,
    ): ProviderDiscoverySnapshot

    suspend fun listProviderDiscoveries(
        limit: UInt = 20u,
    ): List<ProviderDiscoverySnapshot>

    suspend fun continueProviderDiscovery(
        sessionId: String,
        envelope: ProviderDiscoveryActionEnvelope,
        credential: String?,
    ): ProviderDiscoverySnapshot

    suspend fun supplyProviderDiscoveryDocumentEvidence(
        sessionId: String,
        expectedRevision: ULong,
        documentUrl: String,
    ): ProviderDiscoverySnapshot

    suspend fun supplyProviderDiscoveryCurlEvidence(
        sessionId: String,
        expectedRevision: ULong,
        rawCurl: String,
    ): ProviderDiscoverySnapshot

    suspend fun cancelProviderDiscovery(
        sessionId: String,
        expectedRevision: ULong,
    ): ProviderDiscoverySnapshot

    suspend fun commitProviderDiscovery(
        sessionId: String,
        credentialReferenceConfirmed: Boolean,
    ): ProviderConnection

    suspend fun listProviderDiscoveryCompensationSteps(
        commitAttemptId: String,
    ): List<DiscoveryCompensationStep>

    suspend fun continueProviderDiscoveryCompensation(
        sessionId: String,
    ): ProviderDiscoverySnapshot

    suspend fun startProviderDiscoveryCredentialCompensation(
        sessionId: String,
        stepId: String,
    ): DiscoveryCompensationStep

    suspend fun completeProviderDiscoveryCredentialCompensation(
        sessionId: String,
        stepId: String,
    ): ProviderDiscoverySnapshot

    suspend fun failProviderDiscoveryCredentialCompensation(
        sessionId: String,
        stepId: String,
        failure: DiscoveryFailure,
    ): ProviderDiscoverySnapshot

    suspend fun markProviderDiscoveryCredentialCompensationUnknown(
        sessionId: String,
        stepId: String,
    ): ProviderDiscoverySnapshot

    suspend fun resumeProviderDiscoveryCompensation(
        sessionId: String,
    ): ProviderDiscoverySnapshot

    suspend fun recoverProviderDiscoveries(): List<DiscoveryRecoveryResult>

    suspend fun pollProviderDiscoveryEvents(
        limit: UInt = 64u,
    ): List<DiscoveryOutboxEvent>

    suspend fun ackProviderDiscoveryEvent(eventId: String): Boolean

    suspend fun runProviderDiscoveryAssistantTurn(
        sessionId: String,
        estimate: DiscoveryAssistantCallEstimate,
        assistantCredential: String?,
    ): DiscoveryAssistantOutcome

    suspend fun approveProviderDiscoveryAssistantRetry(
        sessionId: String,
    ): ProviderDiscoverySnapshot

    suspend fun requestProviderDiscoveryAssistantRevision(
        sessionId: String,
    ): ProviderDiscoverySnapshot

    suspend fun acceptProviderDiscoveryAssistantDraft(
        sessionId: String,
    ): ProviderDiscoverySnapshot

    suspend fun resumeProviderDiscoveryAssistantCoreHostAction(
        sessionId: String,
    ): ProviderDiscoverySnapshot

    suspend fun recordProviderDiscoveryAssistantFailure(
        sessionId: String,
        kind: String,
        retryable: Boolean,
    ): ProviderDiscoverySnapshot

    suspend fun createProviderConnection(
        draft: ProviderConnectionDraft,
    ): ProviderConnection

    suspend fun listProviderConnections(): List<ProviderConnection>

    suspend fun upsertProviderConnection(
        connection: ProviderConnection,
    ): ProviderConnection

    suspend fun deleteProviderConnection(connectionId: String)

    suspend fun listModelRoutes(connectionId: String): List<ModelRoute>

    suspend fun startProviderModelSync(
        connectionId: String,
        credential: String?,
    ): String

    suspend fun getProviderModelSync(jobId: String): ModelSyncJob

    suspend fun listProviderModelSyncs(
        connectionId: String,
        limit: UInt = 20u,
    ): List<ModelSyncJob>

    suspend fun approveProviderModelSync(
        jobId: String,
        reviewSha256: String,
    ): ModelSyncJob

    suspend fun cancelProviderModelSync(jobId: String): ModelSyncJob

    suspend fun pollProviderModelSyncJobEvents(
        jobId: String,
        limit: UInt = 64u,
    ): List<ModelSyncEvent>

    suspend fun ackProviderModelSyncEvent(jobId: String, sequence: ULong): Boolean

    suspend fun providerCatalogStatus(): ProviderCatalogStatus

    suspend fun providerCatalogHistory(
        limit: UInt = 20u,
        beforeRevision: ULong? = null,
        beforeStateVersion: ULong? = null,
    ): ProviderCatalogHistory

    suspend fun prepareSignedProviderCatalogImport(
        envelopeJson: ByteArray,
    ): ProviderCatalogImportPlan

    suspend fun activateSignedProviderCatalogImport(
        plan: ProviderCatalogImportPlan,
        envelopeJson: ByteArray,
    ): ProviderCatalogImportResult

    suspend fun diffProviderCatalogRevisions(
        fromRevision: ULong,
        toRevision: ULong,
    ): ProviderCatalogDiff

    suspend fun prepareProviderCatalogRollback(
        targetRevision: ULong,
    ): ProviderCatalogRollbackPlan

    suspend fun activateProviderCatalogRollback(
        plan: ProviderCatalogRollbackPlan,
    ): ProviderCatalogRollbackResult

    suspend fun listGenerationPresets(modelRouteId: String): List<GenerationPreset>

    suspend fun upsertGenerationPreset(preset: GenerationPreset): GenerationPreset

    suspend fun validateGenerationPresetCandidate(preset: GenerationPreset)

    suspend fun renderReasoningControlForPreset(
        preset: GenerationPreset,
    ): ReasoningControl

    suspend fun renderPromptCacheControlForPreset(
        preset: GenerationPreset,
    ): PromptCacheControl

    suspend fun previewProviderRequestCandidate(
        preset: GenerationPreset,
    ): RequestPreview

    suspend fun validateGenerationPreset(
        modelRouteId: String,
        generationPresetId: String,
    )

    suspend fun previewProviderRequest(
        modelRouteId: String,
        generationPresetId: String,
    ): RequestPreview

    suspend fun deleteGenerationPreset(generationPresetId: String)

    suspend fun listCapabilityObservations(
        modelRouteId: String,
    ): List<CapabilityObservation>

    suspend fun effectiveCapability(
        modelRouteId: String,
        key: String,
    ): EffectiveCapability?

    suspend fun effectiveParameterSpecs(modelRouteId: String): List<ParameterSpec>

    suspend fun selectGenerationTarget(target: GenerationTarget?): AppSettings
}

class CoreFailure(
    val code: String,
    detail: String,
    val recoverable: Boolean,
    val operationId: String,
) : RuntimeException(detail)

data class CoreVersionInfo(
    val coreVersion: String,
    val coreApiVersion: UInt,
    val bindingApiVersion: UInt,
    val chatEventVersion: UInt,
)

data class CoreHealthStatus(
    val coreVersion: String,
    val databaseOpen: Boolean,
    val schemaVersion: Long,
    val dataRootWritable: Boolean,
    val stagingWritable: Boolean,
    val recoveryPending: Boolean,
    val activeJobs: Long,
) {
    val isHealthy: Boolean
        get() = databaseOpen && dataRootWritable && stagingWritable
}

data class DatabaseStats(
    val characters: ULong,
    val conversations: ULong,
    val messages: ULong,
    val pendingImports: ULong,
)

data class CharacterSummary(
    val id: String,
    val name: String,
    val description: String,
    val sourceHash: String,
    val avatarAssetHash: String? = null,
    val createdAt: String = "",
)

data class ImportWarning(
    val code: String,
    val message: String,
)

data class ImportImagePreview(
    val logicalAssetId: String,
    val mediaType: String,
    val sizeBytes: ULong,
)

data class ImportInspection(
    val id: String,
    val contentKind: String,
    val displayName: String,
    val description: String,
    val sourceSha256: String,
    val sourceSize: ULong,
    val estimatedStoredSize: ULong,
    val assetCount: UInt,
    val warnings: List<ImportWarning>,
    val blockedReasons: List<String>,
    val isAllowed: Boolean,
    val representativeImage: ImportImagePreview? = null,
    val unsupportedOptionalFields: List<String> = emptyList(),
) {
    val isBlocked: Boolean
        get() = !isAllowed || blockedReasons.isNotEmpty()
}

data class ConversationSummary(
    val id: String,
    val characterId: String,
    val title: String,
    val createdAt: String,
    val updatedAt: String,
)

data class ChatMessage(
    val id: String,
    val conversationId: String,
    val parentId: String?,
    val role: String,
    val content: String,
    val status: String,
    val generationId: String?,
    val createdAt: String,
)

data class ChatEvent(
    val eventVersion: UInt,
    val generationId: String,
    val conversationId: String,
    val branchId: String?,
    val assistantMessageId: String?,
    val sequence: ULong,
    val emittedAt: String,
    val kind: String,
    val text: String?,
    val toolCallId: String? = null,
    val toolName: String? = null,
    val toolArgumentsDelta: String? = null,
    val messageId: String?,
    val messageStatus: String?,
    val errorCode: String?,
    val errorMessage: String?,
    val usageInputTokens: ULong?,
    val usageCachedReadTokens: ULong? = null,
    val usageCachedWriteTokens: ULong? = null,
    val usageOutputTokens: ULong?,
    val usageReasoningTokens: ULong? = null,
    val usageToolTokens: ULong? = null,
    val usageProviderRawSummary: String? = null,
)

data class ChatEventBatch(
    val events: List<ChatEvent>,
    val droppedEventCount: ULong,
)

data class ProviderProfile(
    val id: String,
    val displayName: String,
    val baseUrl: String,
    val model: String,
    val timeoutSeconds: UInt,
)

data class AppSettings(
    val preservePartialGenerations: Boolean,
    val selectedProviderProfileId: String?,
    val selectedModelRouteId: String? = null,
    val selectedGenerationPresetId: String? = null,
)

data class GenerationTarget(
    val modelRouteId: String,
    val generationPresetId: String,
)

data class RequestBodyField(
    val name: String,
    val shape: RequestBodyShape,
)

sealed interface RequestBodyShape {
    data object Null : RequestBodyShape

    data object Boolean : RequestBodyShape

    data object Number : RequestBodyShape

    data object StringValue : RequestBodyShape

    data class Array(
        val items: List<RequestBodyShape>,
        val truncated: kotlin.Boolean,
    ) : RequestBodyShape

    data class Object(
        val fields: List<RequestBodyField>,
        val truncated: kotlin.Boolean,
    ) : RequestBodyShape

    data object Redacted : RequestBodyShape

    data object Truncated : RequestBodyShape
}

data class RequestPreview(
    val redactionVersion: UInt,
    val method: String,
    val origin: String,
    val path: String,
    val headerNames: List<String>,
    val queryParameterNames: List<String>,
    val bodyShape: RequestBodyShape?,
    val bodyTruncated: Boolean,
    val includesPrivateMessage: Boolean,
    val includesCredentialValue: Boolean,
    val includesOpaqueReasoningState: Boolean,
) {
    val isSafeToDisplay: Boolean
        get() = redactionVersion == SUPPORTED_REDACTION_VERSION &&
            !includesPrivateMessage &&
            !includesCredentialValue &&
            !includesOpaqueReasoningState
}

private const val SUPPORTED_REDACTION_VERSION = 1u

sealed interface AuthBinding {
    data object None : AuthBinding

    data object BearerHeader : AuthBinding

    data class HeaderApiKey(
        val headerName: String,
    ) : AuthBinding
}

enum class ConnectionFieldType {
    Text,
    Integer,
    Boolean,
    Credential,
}

data class ConnectionFieldSpec(
    val key: String,
    val labelKey: String,
    val descriptionKey: String?,
    val valueType: ConnectionFieldType,
    val required: Boolean,
)

sealed interface ConnectionConfigValue {
    data class Text(
        val value: String,
    ) : ConnectionConfigValue

    data class Integer(
        val value: Long,
    ) : ConnectionConfigValue

    data class Boolean(
        val value: kotlin.Boolean,
    ) : ConnectionConfigValue
}

data class ConnectionConfigEntry(
    val key: String,
    val value: ConnectionConfigValue,
)

enum class ParameterType {
    Boolean,
    Integer,
    Number,
    String,
    Enum,
    StringList,
    JsonSchema,
    StopSequenceList,
    ToolPolicy,
}

enum class ToolPolicy {
    None,
    Auto,
    Required,
}

sealed interface ParameterLiteral {
    data class Boolean(
        val value: kotlin.Boolean,
    ) : ParameterLiteral

    data class Integer(
        val value: Long,
    ) : ParameterLiteral

    data class Number(
        val value: Double,
    ) : ParameterLiteral

    data class StringValue(
        val value: String,
    ) : ParameterLiteral

    data class EnumValue(
        val value: String,
    ) : ParameterLiteral

    data class StringList(
        val values: List<String>,
    ) : ParameterLiteral

    data class JsonSchema(
        val value: String,
    ) : ParameterLiteral

    data class StopSequenceList(
        val values: List<String>,
    ) : ParameterLiteral

    data class ToolPolicyValue(
        val value: ToolPolicy,
    ) : ParameterLiteral
}

sealed interface ParameterValueState {
    data object InheritProviderDefault : ParameterValueState

    data class Explicit(
        val value: ParameterLiteral,
    ) : ParameterValueState
}

data class ParameterValue(
    val parameterId: String,
    val state: ParameterValueState,
)

data class ParameterChoice(
    val value: ParameterLiteral,
    val labelKey: String,
)

enum class ParameterDefaultMode {
    ProviderDefault,
    ExplicitRequired,
}

enum class ParameterConditionOperator {
    Equals,
    NotEquals,
}

data class ParameterCondition(
    val parameterId: String,
    val operator: ParameterConditionOperator,
    val value: ParameterLiteral,
)

enum class ParameterConflictKind {
    MutuallyExclusive,
    Requires,
}

data class ParameterConflict(
    val parameterId: String,
    val kind: ParameterConflictKind,
    val messageKey: String,
)

enum class ProviderParameterTarget {
    RequestBody,
    RequestHeader,
}

data class ProviderParameterMapping(
    val target: ProviderParameterTarget,
    val fieldName: String,
)

enum class UiParameterLevel {
    Basic,
    Advanced,
    Expert,
    HiddenInternal,
}

data class ParameterSpec(
    val id: String,
    val labelKey: String,
    val descriptionKey: String?,
    val valueType: ParameterType,
    val allowedValues: List<ParameterChoice>,
    val minimum: Double?,
    val maximum: Double?,
    val step: Double?,
    val defaultMode: ParameterDefaultMode,
    val visibility: ParameterCondition?,
    val conflicts: List<ParameterConflict>,
    val providerMapping: ProviderParameterMapping,
    val level: UiParameterLevel,
)

data class ProviderTemplate(
    val id: String,
    val displayName: String,
    val manifestVersion: UInt,
    val source: String,
    val apiFamily: String,
    val defaultApiOrigin: String?,
    val requiresCredential: Boolean,
    val supportsModelListing: Boolean,
    val authBinding: AuthBinding,
    val connectionFields: List<ConnectionFieldSpec>,
    val parameters: List<ParameterSpec>,
    val defaultNetworkMode: ProviderNetworkMode = ProviderNetworkMode.Public,
)

enum class ProviderNetworkMode {
    Public,
    LocalLoopback,
    ApprovedLocalNetwork,
}

data class ProviderNetworkPolicy(
    val networkMode: ProviderNetworkMode,
    val localNetworkApproval: ProviderLocalNetworkApproval? = null,
)

data class ProviderConnectionDraft(
    val id: String,
    val templateId: String,
    val templateVersion: UInt,
    val displayName: String,
    val apiOrigin: String,
    val apiBasePath: String?,
    val networkMode: ProviderNetworkMode,
    val values: List<ConnectionConfigEntry>,
    val approvedCredentialOrigin: String?,
    val timeoutSeconds: UInt,
    val localNetworkApproval: ProviderLocalNetworkApproval? = null,
)

data class ProviderLocalNetworkApproval(
    val origin: String,
    val addresses: List<String>,
)

enum class CredentialRedirectPolicy {
    Deny,
    FollowWithoutCredential,
}

data class CredentialScope(
    val allowedOrigins: List<String>,
    val authBinding: AuthBinding,
    val redirectPolicy: CredentialRedirectPolicy,
)

data class ProviderConnection(
    val id: String,
    val templateId: String,
    val templateVersion: UInt,
    val displayName: String,
    val apiOrigin: String,
    val apiBasePath: String?,
    val networkMode: ProviderNetworkMode,
    val values: List<ConnectionConfigEntry>,
    val credentialSlotReady: Boolean,
    val credentialScope: CredentialScope?,
    val approvedCredentialOrigins: List<String>,
    val timeoutSeconds: UInt,
    val status: String,
    val createdAt: String,
    val updatedAt: String,
    val localNetworkApproval: ProviderLocalNetworkApproval? = null,
)

data class ModelRouteConfig(
    val deploymentId: String?,
    val region: String?,
    val endpointPath: String?,
    val values: List<ConnectionConfigEntry>,
)

data class ModelRoute(
    val id: String,
    val connectionId: String,
    val apiFamily: String,
    val modelId: String,
    val displayName: String?,
    val routeConfig: ModelRouteConfig,
    val availability: String,
    val missCount: UInt = 0u,
    val rawMetadataJson: String? = null,
    val metadataSource: String = "unknown",
    val metadataObservedAt: String? = null,
    val lastReconciledSyncJobId: String? = null,
    val metadataSyncJobId: String? = null,
    val firstSeenAt: String,
    val lastSeenAt: String?,
)

data class ModelSyncFailure(
    val code: String,
    val messageKey: String,
    val recoverable: Boolean,
)

data class ModelSyncProvenance(
    val source: String,
    val apiFamily: String,
    val apiOrigin: String,
    val endpointPath: String,
    val pagesFetched: UInt,
    val responseBytes: ULong,
)

data class ModelSyncReview(
    val sha256: String,
    val connectionId: String,
    val expectedConnection: ProviderConnection,
    val observedAt: String,
    val expectedModelRoutes: List<ModelRoute>,
    val listedRoutes: List<ModelRoute>,
    val newlySeenModelRouteIds: List<String>,
    val missingModelRouteIds: List<String>,
    val initialPresets: List<GenerationPreset>,
    val capabilityObservations: List<CapabilityObservation>,
    val routesRequiringPresetConfiguration: List<String>,
    val provenance: ModelSyncProvenance,
)

data class ModelSyncJob(
    val id: String,
    val connectionId: String,
    val state: String,
    val revision: ULong,
    val review: ModelSyncReview?,
    val failure: ModelSyncFailure?,
    val createdAt: String,
    val updatedAt: String,
)

data class ModelSyncEvent(
    val version: UInt,
    val jobId: String,
    val sequence: ULong,
    val jobRevision: ULong,
    val redactionVersion: UInt,
    val state: String,
    val completedSteps: UInt,
    val totalSteps: UInt,
    val messageKey: String,
    val reviewSha256: String?,
    val failure: ModelSyncFailure?,
    val emittedAt: String,
)

data class GenerationPreset(
    val id: String,
    val modelRouteId: String,
    val displayName: String,
    val values: List<ParameterValue>,
    val reasoningMode: String,
    val reasoningEffort: String?,
    val reasoningBudgetTokens: UInt?,
    val reasoningSummary: String,
    val preserveOpaqueReasoningState: Boolean,
    val promptCacheMode: String,
    val promptCacheTtl: String,
    val promptCacheCustomTtlSeconds: UInt?,
    val promptCacheContextReference: String?,
    val createdAt: String,
    val updatedAt: String,
)

data class ParameterIssue(
    val code: String,
    val parameterId: String?,
    val relatedParameterId: String?,
    val message: String,
)

data class ReasoningControl(
    val state: String,
    val mode: String,
    val effort: String?,
    val budgetTokens: UInt?,
    val summary: String,
    val preserveOpaqueState: Boolean,
    val allowedModes: List<String>,
    val allowedEfforts: List<String>,
    val allowedSummaries: List<String>,
    val minimumBudgetTokens: UInt?,
    val maximumBudgetTokens: UInt?,
    val effortField: String,
    val budgetField: String,
    val summaryField: String,
    val issues: List<ParameterIssue>,
)

data class PromptCacheControl(
    val state: String,
    val mode: String,
    val ttl: String,
    val customTtlSeconds: UInt?,
    val contextReference: String?,
    val allowedModes: List<String>,
    val allowedTtls: List<String>,
    val supportsCustomTtl: Boolean,
    val minimumCustomTtlSeconds: UInt?,
    val maximumCustomTtlSeconds: UInt?,
    val ttlField: String,
    val contextReferenceField: String,
    val issues: List<ParameterIssue>,
)

data class CapabilityValue(
    val kind: String,
    val booleanValue: Boolean?,
    val integerValue: ULong?,
    val enumValues: List<String>,
    val structuredJson: String?,
)

data class CapabilityObservation(
    val id: String,
    val modelRouteId: String,
    val key: String,
    val value: CapabilityValue,
    val status: String,
    val source: String,
    val confidence: String,
    val observedAt: String,
    val expiresAt: String?,
    val evidenceRef: String?,
)

data class EffectiveCapability(
    val selected: CapabilityObservation,
    val alternatives: List<CapabilityObservation>,
    val evaluatedAt: String,
    val selectedIsStale: Boolean,
    val hasConflict: Boolean,
)
