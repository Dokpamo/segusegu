package dev.lorepia.app.bridge

/**
 * Secret-free durable discovery input. Native stores any secret under
 * [connectionId]; Core derives the opaque reference only after
 * [credentialSlotReady] confirms that slot exists.
 */
data class ProviderDiscoveryInput(
    val connectionId: String,
    val displayName: String,
    val siteUrl: String?,
    val docsUrl: String?,
    val credentialSlotReady: Boolean,
    val preferredAssistantModelRouteId: String?,
    val connectionOptions: ProviderDiscoveryConnectionOptions,
    val suppliedEvidenceIds: List<String> = emptyList(),
)

data class ProviderDiscoveryConnectionOptions(
    val values: List<ConnectionConfigEntry>,
    val apiBasePath: String?,
    val timeoutSeconds: UInt,
    val networkMode: ProviderNetworkMode,
    val localNetworkApproval: ProviderLocalNetworkApproval?,
)

sealed interface ProviderDiscoverySource {
    data class KnownProvider(val templateId: String) : ProviderDiscoverySource

    data object Site : ProviderDiscoverySource

    data object Curl : ProviderDiscoverySource
}

/**
 * One-shot native handoff. [credentialHandoffId] must be consumed immediately
 * through Core and never enters UI state.
 */
class ProviderCurlInspection(
    val inspectionSchemaVersion: UInt,
    val sanitizedSiteUrl: String,
    val apiOrigin: String,
    val method: String,
    val path: String,
    val headerNames: List<String>,
    val authBindingHint: AuthBinding?,
    val apiFamilyHint: String?,
    val modelHint: String?,
    val streamHint: Boolean?,
    val redactedCurl: String,
    val credentialHandoffId: String?,
) {
    override fun toString(): String =
        "ProviderCurlInspection(schema=$inspectionSchemaVersion, " +
            "origin=$apiOrigin, method=$method, path=$path, " +
            "credential=<redacted:${if (credentialHandoffId == null) 0 else 1} handoff>)"
}

sealed interface DiscoveryUnknownOutcomeResolution {
    data object ConfirmedNoEffect : DiscoveryUnknownOutcomeResolution

    data class ConfirmedCommitCompleted(
        val connectionId: String,
    ) : DiscoveryUnknownOutcomeResolution

    data object ConfirmedCompensated : DiscoveryUnknownOutcomeResolution

    data object ManuallyReconciledAsFailed : DiscoveryUnknownOutcomeResolution
}

sealed interface ProviderDiscoveryAction {
    data class SelectTemplate(val candidateId: String) : ProviderDiscoveryAction

    data object ContinueWithoutTemplate : ProviderDiscoveryAction

    data class SupplyMoreEvidence(val evidenceIds: List<String>) : ProviderDiscoveryAction

    data object RequestAssistant : ProviderDiscoveryAction

    data class ApproveAssistant(
        val approvalId: String,
        val approvalGrantSha256: String,
    ) : ProviderDiscoveryAction

    data object DeclineAssistant : ProviderDiscoveryAction

    data class ApproveCredentialOrigin(
        val approvalId: String,
    ) : ProviderDiscoveryAction

    data class ApproveProbes(
        val approvalId: String,
        val approvalGrantSha256: String,
    ) : ProviderDiscoveryAction

    data object SkipProbes : ProviderDiscoveryAction

    data class ApproveReview(
        val approvalId: String,
        val commitAttemptId: String,
        val commitPlanSha256: String,
        val graphSha256: String,
    ) : ProviderDiscoveryAction

    data object ResumeCompensation : ProviderDiscoveryAction

    data object RestartInterrupted : ProviderDiscoveryAction

    data class ResolveUnknownOutcome(
        val approvalId: String,
        val resolution: DiscoveryUnknownOutcomeResolution,
    ) : ProviderDiscoveryAction

    data object Cancel : ProviderDiscoveryAction
}

data class ProviderDiscoveryActionEnvelope(
    val actionId: String,
    val expectedRevision: ULong,
    val requestSha256: String,
    val action: ProviderDiscoveryAction,
)

data class DiscoveryFailure(
    val code: String,
    val messageKey: String,
    val recoverable: Boolean,
)

data class ProviderDiscoveryProgress(
    val phase: String,
    val completed: UInt,
    val total: UInt?,
)

sealed interface DiscoveryActionRequired {
    data object SelectTemplate : DiscoveryActionRequired

    data object SupplyMoreEvidence : DiscoveryActionRequired

    data object ApproveAssistant : DiscoveryActionRequired

    data object ApproveCredentialOrigin : DiscoveryActionRequired

    data object ApproveProbes : DiscoveryActionRequired

    data object Review : DiscoveryActionRequired

    data class RestartInterrupted(val operation: String) : DiscoveryActionRequired

    data class ReconcileUnknownOutcome(val operation: String) : DiscoveryActionRequired
}

data class DiscoveryStep(
    val id: String,
    val titleKey: String,
    val state: String,
)

sealed interface DiscoveryCandidateSummary {
    data class ProviderTemplate(
        val templateId: String,
        val templateVersion: UInt,
    ) : DiscoveryCandidateSummary

    data class ApiOrigin(val origin: String) : DiscoveryCandidateSummary

    data class OfficialDocument(val contentSha256: String) : DiscoveryCandidateSummary

    data class ModelRoute(val modelId: String) : DiscoveryCandidateSummary

    data class ManifestDraft(
        val schemaVersion: UInt,
        val manifestSha256: String,
    ) : DiscoveryCandidateSummary
}

data class DiscoveryCandidate(
    val id: String,
    val proposedRevision: ULong,
    val summary: DiscoveryCandidateSummary,
    val evidenceIds: List<String>,
    val createdAt: String,
)

data class DiscoveryEvidence(
    val id: String,
    val kind: String,
    val contentSha256: String,
    val fetchedAt: String,
)

sealed interface DiscoveryApprovalGrant {
    data class TemplateSelection(val candidateId: String) : DiscoveryApprovalGrant

    data class AssistantConsent(
        val assistantModelRouteId: String,
        val evidenceIds: List<String>,
        val allowedDocumentOrigins: List<String>,
        val maxCalls: UInt,
        val maxInputTokens: UInt,
        val maxOutputTokens: UInt,
        val maxToolCalls: UInt,
        val maxRetries: UInt,
        val maxCostMicroUnits: ULong,
    ) : DiscoveryApprovalGrant

    data class CredentialOrigin(
        val origin: String,
        val authBinding: AuthBinding,
        val manifestSha256: String,
    ) : DiscoveryApprovalGrant

    data class CapabilityProbe(
        val modelRouteIds: List<String>,
        val budget: DiscoveryProbeBudget,
    ) : DiscoveryApprovalGrant

    data class Review(
        val reviewSha256: String,
        val graphSha256: String,
    ) : DiscoveryApprovalGrant

    data class UnknownOutcomeResolution(
        val operation: String,
        val resolution: DiscoveryUnknownOutcomeResolution,
    ) : DiscoveryApprovalGrant
}

data class DiscoveryProbeBudget(
    val maxRequests: UInt,
    val maxTotalTokensPerRequest: ULong,
    val maxOutputTokensPerRequest: ULong,
    val maxCostMicroUsdPerRequest: ULong,
    val maxDurationMillisPerRequest: ULong,
    val maxCallsPerRequest: UInt,
)

data class DiscoveryApprovalProposal(
    val approvalId: String,
    val grant: DiscoveryApprovalGrant,
    val grantSha256: String,
)

data class DiscoveryApproval(
    val id: String,
    val sessionRevision: ULong,
    val decision: String,
    val grant: DiscoveryApprovalGrant,
    val createdAt: String,
)

data class DiscoveryReviewChange(
    val kind: String,
    val targetKind: String,
    val targetId: String,
    val summaryKey: String,
    val evidenceIds: List<String>,
)

data class DiscoveryReview(
    val sha256: String,
    val graphSha256: String,
    val changes: List<DiscoveryReviewChange>,
    val unresolvedQuestionCount: UInt,
    val warningCount: UInt,
)

data class DiscoveryReviewProposal(
    val review: DiscoveryReview,
    val approval: DiscoveryApprovalProposal,
    val commitAttemptId: String,
    val commitPlanSha256: String,
    val requestPreview: RequestPreview?,
)

data class ProviderDiscoverySnapshot(
    val snapshotSchemaVersion: UInt,
    val sessionId: String,
    val pendingConnectionId: String,
    val pendingDisplayName: String,
    val connectionOptions: ProviderDiscoveryConnectionOptions,
    val credentialSlotId: String?,
    val credentialSlotExpected: Boolean,
    val revision: ULong,
    val state: String,
    val nextEventSequence: ULong,
    val steps: List<DiscoveryStep>,
    val actionRequired: DiscoveryActionRequired?,
    val activeOperationId: String?,
    val recoveryOperation: String?,
    val unknownOperation: String?,
    val manifestSha256: String?,
    val commitPlanSha256: String?,
    val commitAttemptId: String?,
    val committedConnectionId: String?,
    val cancellationPending: Boolean,
    val failure: DiscoveryFailure?,
    val candidates: List<DiscoveryCandidate>,
    val evidence: List<DiscoveryEvidence>,
    val approvals: List<DiscoveryApproval>,
    val approvalProposal: DiscoveryApprovalProposal?,
    val review: DiscoveryReview?,
    val reviewProposal: DiscoveryReviewProposal?,
    val createdAt: String,
    val updatedAt: String,
    val assistantResumeBoundary: DiscoveryAssistantResumeBoundary? = null,
)

data class DiscoveryEvent(
    val eventVersion: UInt,
    val eventId: String,
    val sessionId: String,
    val sequence: ULong,
    val sessionRevision: ULong,
    val state: String,
    val progress: ProviderDiscoveryProgress?,
    val actionRequired: DiscoveryActionRequired?,
    val warning: String?,
    val actionId: String,
    val failure: DiscoveryFailure?,
)

data class DiscoveryOutboxEvent(
    val event: DiscoveryEvent,
    val deliveryAttempts: UInt,
    val availableAt: String,
    val createdAt: String,
)

data class DiscoveryRecoveryResult(
    val operationId: String,
    val sessionId: String,
    val state: String,
    val event: DiscoveryEvent,
)

enum class DiscoveryCompensationKind {
    RemoveCredentialSlot,
    RemoveConnectionGraph,
    RestorePreviousSelection,
}

enum class DiscoveryCompensationStatus {
    Pending,
    InProgress,
    Completed,
    Failed,
    OutcomeUnknown,
}

sealed interface DiscoveryPreviousSelection {
    data object None : DiscoveryPreviousSelection

    data class RouteAndPreset(
        val modelRouteId: String,
        val generationPresetId: String,
    ) : DiscoveryPreviousSelection
}

sealed interface DiscoveryCompensationTarget {
    data class RemoveCredentialSlot(
        val connectionId: String,
        val credentialRef: String,
    ) : DiscoveryCompensationTarget

    data class RemoveConnectionGraph(
        val connectionId: String,
    ) : DiscoveryCompensationTarget

    data class RestorePreviousSelection(
        val previousSelection: DiscoveryPreviousSelection,
    ) : DiscoveryCompensationTarget
}

data class DiscoveryCompensationStep(
    val id: String,
    val commitAttemptId: String,
    val ordinal: UInt,
    val actionId: String,
    val kind: DiscoveryCompensationKind,
    val target: DiscoveryCompensationTarget,
    val status: DiscoveryCompensationStatus,
    val attemptCount: UInt,
    val lastFailure: DiscoveryFailure?,
    val createdAt: String,
    val updatedAt: String,
    val completedAt: String?,
)

data class DiscoveryAssistantCallEstimate(
    val inputTokens: ULong,
    val maximumOutputTokens: ULong,
    val maximumCostMicroUnits: ULong,
)

enum class DiscoveryAssistantCheckpoint {
    Ready,
    AwaitingAssistant,
    AwaitingToolResult,
    AwaitingMoreEvidence,
    AwaitingRetryConsent,
    DraftReady,
}

enum class DiscoveryAssistantResumeAction {
    ApproveConsent,
    RunAssistant,
    WaitForAssistantOutcome,
    ResumeCoreHostAction,
    SupplyMoreEvidence,
    ApproveRetry,
    ReviewDraft,
    RestartInterrupted,
    ResolveUnknownOutcome,
}

data class DiscoveryAssistantResumeBoundary(
    val checkpoint: DiscoveryAssistantCheckpoint?,
    val action: DiscoveryAssistantResumeAction,
    val questions: List<DiscoveryAssistantQuestion>,
    val draftReview: DiscoveryAssistantDraftReview?,
)

sealed interface DiscoveryAssistantOutcome {
    data class MoreEvidenceRequired(
        val sessionId: String,
        val questions: List<DiscoveryAssistantQuestion>,
    ) : DiscoveryAssistantOutcome

    data class DraftReadyForReview(
        val review: DiscoveryAssistantDraftReview,
    ) : DiscoveryAssistantOutcome
}

sealed interface DiscoveryAssistantDraftField {
    data object ApiFamily : DiscoveryAssistantDraftField

    data object DefaultApiOrigin : DiscoveryAssistantDraftField

    data object Auth : DiscoveryAssistantDraftField

    data object GenerateEndpoint : DiscoveryAssistantDraftField

    data object ModelsEndpoint : DiscoveryAssistantDraftField

    data object ResponseDecoder : DiscoveryAssistantDraftField

    data object StreamingDecoder : DiscoveryAssistantDraftField

    data class Parameter(val parameterId: String) : DiscoveryAssistantDraftField
}

data class DiscoveryAssistantQuestion(
    val id: String,
    val field: DiscoveryAssistantDraftField?,
    val question: String,
    val requiredEvidence: String,
)

data class DiscoveryAssistantEvidenceMapping(
    val field: DiscoveryAssistantDraftField,
    val evidenceIds: List<String>,
    val explanation: String,
)

enum class DiscoveryAssistantConfidenceLevel {
    Unknown,
    Low,
    Medium,
    High,
}

data class DiscoveryAssistantFieldConfidence(
    val field: DiscoveryAssistantDraftField,
    val level: DiscoveryAssistantConfidenceLevel,
    val rationale: String,
)

sealed interface DiscoveryAssistantConflictDisposition {
    data object Unresolved : DiscoveryAssistantConflictDisposition

    data class Resolved(
        val selectedEvidenceId: String,
        val rationale: String,
    ) : DiscoveryAssistantConflictDisposition
}

data class DiscoveryAssistantEvidenceConflict(
    val field: DiscoveryAssistantDraftField,
    val evidenceIds: List<String>,
    val disposition: DiscoveryAssistantConflictDisposition,
)

data class DiscoveryAssistantManifestSource(
    val kind: String,
    val url: String,
    val contentSha256: String?,
)

data class DiscoveryAssistantEndpoint(
    val method: String,
    val path: String,
)

data class DiscoveryAssistantManifest(
    val schemaVersion: UInt,
    val apiFamily: String,
    val sources: List<DiscoveryAssistantManifestSource>,
    val defaultApiOrigin: String?,
    val auth: AuthBinding,
    val modelsEndpoint: DiscoveryAssistantEndpoint?,
    val generateEndpoint: DiscoveryAssistantEndpoint,
    val responseDecoder: String,
    val streamingDecoder: String?,
    val parameters: List<ParameterSpec>,
)

data class DiscoveryAssistantManifestDraft(
    val manifest: DiscoveryAssistantManifest,
    val evidenceMappings: List<DiscoveryAssistantEvidenceMapping>,
    val conflicts: List<DiscoveryAssistantEvidenceConflict>,
    val unresolvedQuestions: List<DiscoveryAssistantQuestion>,
    val confidence: List<DiscoveryAssistantFieldConfidence>,
    val summary: String,
)

enum class DiscoveryAssistantDraftReviewCheck {
    ManifestValidation,
    UrlPolicyValidation,
    CredentialOriginApproval,
    UserReview,
}

enum class DiscoveryAssistantDraftPersistence {
    BlockedUntilChecksPass,
}

data class DiscoveryAssistantDraftReview(
    val draft: DiscoveryAssistantManifestDraft,
    val unresolvedConflicts: List<DiscoveryAssistantDraftField>,
    val requiredChecks: List<DiscoveryAssistantDraftReviewCheck>,
    val persistence: DiscoveryAssistantDraftPersistence,
)
