package dev.lorepia.app.feature.settings

import dev.lorepia.app.bridge.AppSettings
import dev.lorepia.app.bridge.CapabilityObservation
import dev.lorepia.app.bridge.CoreHealthStatus
import dev.lorepia.app.bridge.EffectiveCapability
import dev.lorepia.app.bridge.DiscoveryAssistantOutcome
import dev.lorepia.app.bridge.DiscoveryUnknownOutcomeResolution
import dev.lorepia.app.bridge.GenerationPreset
import dev.lorepia.app.bridge.ModelRoute
import dev.lorepia.app.bridge.ParameterLiteral
import dev.lorepia.app.bridge.ParameterSpec
import dev.lorepia.app.bridge.ProviderConnection
import dev.lorepia.app.bridge.ProviderDiscoverySnapshot
import dev.lorepia.app.bridge.ProviderLocalNetworkApproval
import dev.lorepia.app.bridge.ProviderNetworkMode
import dev.lorepia.app.bridge.ProviderTemplate
import dev.lorepia.app.bridge.PromptCacheControl
import dev.lorepia.app.bridge.ReasoningControl
import dev.lorepia.app.bridge.RequestPreview
import dev.lorepia.app.bridge.RequestBodyShape
import dev.lorepia.app.bridge.UiParameterLevel
import dev.lorepia.app.platform.credentials.CredentialRecordStatus
import java.time.Instant

sealed interface SettingsUiState {
    data object Loading : SettingsUiState

    data class Ready(
        val health: CoreHealthStatus,
        val settings: AppSettings,
        val templates: List<ProviderTemplate>,
        val connections: List<ProviderConnectionDetails>,
        val setup: ProviderSetupState? = null,
        val connectionEditor: ConnectionEditor? = null,
        val presetEditor: PresetEditor? = null,
        val presetReview: PresetCandidateReview? = null,
        val presetControls: PresetControls? = null,
        val modelSync: ModelSyncUiState? = null,
        val catalog: ProviderCatalogUiState = ProviderCatalogUiState.Loading,
        val busyOperation: BusyOperation? = null,
        val notice: String? = null,
        val error: String? = null,
    ) : SettingsUiState {
        val isBusy: Boolean
            get() = busyOperation != null
    }

    data class Error(
        val cause: Throwable,
    ) : SettingsUiState
}

internal fun SettingsUiState.Ready.isCredentialBearingRoute(
    modelRouteId: String,
): Boolean {
    val owner = connections.firstOrNull { details ->
        details.routes.any { it.route.id == modelRouteId }
    } ?: return true
    return owner.template?.requiresCredential == true ||
        owner.connection.credentialSlotReady ||
        owner.connection.credentialScope != null ||
        owner.connection.approvedCredentialOrigins.isNotEmpty() ||
        owner.credentialRecordStatus == CredentialRecordStatus.Available ||
        owner.credentialRecordStatus == CredentialRecordStatus.Unreadable
}

enum class BusyOperation {
    SavingConnection,
    DeletingConnection,
    SelectingModel,
    ValidatingPreset,
    SavingPreset,
    DeletingPreset,
    SynchronizingModels,
    RunningDiscoveryAction,
    CancellingDiscovery,
    PreparingCatalogImport,
    ActivatingCatalogImport,
    PreparingCatalogRollback,
    ActivatingCatalogRollback,
}

data class ProviderConnectionDetails(
    val connection: ProviderConnection,
    val template: ProviderTemplate?,
    val routes: List<ModelRouteDetails>,
    val credentialRecordStatus: CredentialRecordStatus? = null,
)

data class ModelRouteDetails(
    val route: ModelRoute,
    val presets: List<GenerationPreset>,
    val capabilities: List<CapabilityDetails>,
    val presetPreviews: Map<String, RequestPreview> = emptyMap(),
    val parameterSpecs: List<ParameterSpec> = emptyList(),
)

internal data class SetupAssistantTarget(
    val connectionId: String,
    val connectionDisplayName: String,
    val modelRouteId: String,
    val modelDisplayName: String,
    val generationPresetId: String,
    val generationPresetDisplayName: String,
)

internal fun SettingsUiState.Ready.activeSetupAssistantTarget(): SetupAssistantTarget? {
    val routeId = settings.selectedModelRouteId ?: return null
    val presetId = settings.selectedGenerationPresetId ?: return null
    val (connection, route) = connections.firstNotNullOfOrNull { details ->
        details.routes.firstOrNull { it.route.id == routeId }
            ?.let { details to it }
    } ?: return null
    if (route.route.availability in SETUP_ASSISTANT_UNAVAILABLE_ROUTE_STATES) {
        return null
    }
    if (
        connection.connection.credentialSlotReady &&
        connection.credentialRecordStatus != CredentialRecordStatus.Available
    ) {
        return null
    }
    val preset = route.presets.firstOrNull { it.id == presetId } ?: return null
    return SetupAssistantTarget(
        connectionId = connection.connection.id,
        connectionDisplayName = connection.connection.displayName,
        modelRouteId = route.route.id,
        modelDisplayName = route.route.displayName ?: route.route.modelId,
        generationPresetId = preset.id,
        generationPresetDisplayName = preset.displayName,
    )
}

private val SETUP_ASSISTANT_UNAVAILABLE_ROUTE_STATES = setOf(
    "retired",
    "deprecated",
    "access_denied",
    "missing_temporarily",
)

data class CapabilityDetails(
    val key: String,
    val effective: EffectiveCapability?,
    val observations: List<CapabilityObservation>,
)

enum class ProviderSetupKind {
    KnownProvider,
    UnknownSite,
    LocalServer,
    CurlExample,
}

enum class ProviderSetupStep {
    ChooseMethod,
    EnterDetails,
    Discovering,
    ApproveCredentialOrigin,
    Review,
    Committing,
    Completed,
    Failed,
    Cancelled,
}

data class DiscoveryProgress(
    val completedSteps: Int,
    val totalSteps: Int,
    val currentLabel: String,
)

data class ProviderSetupState(
    val kind: ProviderSetupKind? = null,
    val step: ProviderSetupStep = ProviderSetupStep.ChooseMethod,
    val connectionId: String,
    val templateId: String? = null,
    val displayName: String = "",
    val siteUrl: String = "",
    val docsUrl: String = "",
    val preferredAssistantModelRouteId: String? = null,
    val apiOrigin: String = "",
    val apiBasePath: String = "",
    val networkMode: ProviderNetworkMode = ProviderNetworkMode.Public,
    val localNetworkOrigin: String = "",
    val localNetworkAddresses: String = "",
    val timeoutSeconds: String = "60",
    val connectionValues: Map<String, String> = emptyMap(),
    val approvedCredentialOrigin: String? = null,
    val progress: DiscoveryProgress? = null,
    val review: ProviderSetupReview? = null,
    val discovery: ProviderDiscoverySnapshot? = null,
    val assistantOutcome: DiscoveryAssistantOutcome? = null,
    val hasPendingCredential: Boolean = false,
    val error: String? = null,
) {
    val localNetworkApproval: ProviderLocalNetworkApproval?
        get() = if (networkMode == ProviderNetworkMode.ApprovedLocalNetwork) {
            ProviderLocalNetworkApproval(
                origin = localNetworkOrigin.trim(),
                addresses = localNetworkAddresses
                    .lineSequence()
                    .flatMap { it.split(',').asSequence() }
                    .map(String::trim)
                    .filter(String::isNotEmpty)
                    .distinct()
                    .toList(),
            )
        } else {
            null
        }
}

data class ProviderSetupReview(
    val providerName: String,
    val apiOrigin: String,
    val credentialOrigin: String?,
    val apiFamily: String,
    val models: List<String>,
    val capabilitySummary: List<String>,
    val evidenceSummary: List<String>,
    val redactedRequestPreview: String?,
    val reviewHash: String,
)

sealed interface ProviderDiscoveryUiAction {
    data class SelectCandidate(val candidateId: String) : ProviderDiscoveryUiAction

    data object ContinueWithoutTemplate : ProviderDiscoveryUiAction

    data object RequestAssistant : ProviderDiscoveryUiAction

    data object ApproveAssistant : ProviderDiscoveryUiAction

    data object DeclineAssistant : ProviderDiscoveryUiAction

    data object RunAssistant : ProviderDiscoveryUiAction

    data object ApproveAssistantRetry : ProviderDiscoveryUiAction

    data object ResumeAssistantCoreHostAction : ProviderDiscoveryUiAction

    data object ApproveProbes : ProviderDiscoveryUiAction

    data object SkipProbes : ProviderDiscoveryUiAction

    data object AcceptAssistantDraft : ProviderDiscoveryUiAction

    data class SupplyDocument(val url: String) : ProviderDiscoveryUiAction

    data class SupplyCurl(val rawCurl: String) : ProviderDiscoveryUiAction

    data object RestartInterrupted : ProviderDiscoveryUiAction

    data object ResumeCompensation : ProviderDiscoveryUiAction

    data class ResolveUnknownOutcome(
        val resolution: DiscoveryUnknownOutcomeResolution,
    ) : ProviderDiscoveryUiAction
}

sealed interface ProviderCatalogUiAction {
    data object Refresh : ProviderCatalogUiAction

    data object ChooseSignedDocument : ProviderCatalogUiAction

    data object ActivateImport : ProviderCatalogUiAction

    data object CancelImport : ProviderCatalogUiAction

    data class PrepareRollback(val revision: ULong) : ProviderCatalogUiAction

    data object ActivateRollback : ProviderCatalogUiAction

    data object CancelRollback : ProviderCatalogUiAction
}

data class ConnectionEditor(
    val original: ProviderConnection,
    val displayName: String = original.displayName,
    val apiBasePath: String = original.apiBasePath.orEmpty(),
    val timeoutSeconds: String = original.timeoutSeconds.toString(),
    val values: Map<String, String> = original.values.associate { entry ->
        entry.key to entry.value.toEditorString()
    },
)

data class PresetEditor(
    val id: String,
    val modelRouteId: String,
    val displayName: String,
    val parameterSpecs: List<ParameterSpec>,
    val explicitValues: Map<String, ParameterLiteral>,
    val reasoningMode: String = "provider_default",
    val reasoningEffort: String? = null,
    val reasoningBudgetTokens: String = "",
    val reasoningSummary: String = "provider_default",
    val preserveOpaqueReasoningState: Boolean = false,
    val promptCacheMode: String = "provider_default",
    val promptCacheTtl: String = "provider_default",
    val promptCacheCustomTtlSeconds: String = "",
    val promptCacheContextReference: String = "",
    val createdAt: String = Instant.now().toString(),
    val updatedAt: String = Instant.now().toString(),
    val isExisting: Boolean = false,
    val visibleLevel: UiParameterLevel = UiParameterLevel.Basic,
    val redactedRequestPreview: String? = null,
    val validationMessages: List<String> = emptyList(),
)

data class PresetCandidateReview(
    val candidate: GenerationPreset,
    val preview: RequestPreview,
)

data class PresetControls(
    val reasoning: ReasoningControl,
    val promptCache: PromptCacheControl,
)

sealed interface ModelSyncUiState {
    val connectionId: String

    sealed interface Actionable : ModelSyncUiState {
        val jobId: String
    }

    data class Running(
        override val connectionId: String,
        override val jobId: String,
        val progress: DiscoveryProgress,
    ) : Actionable

    data class AwaitingReview(
        override val connectionId: String,
        override val jobId: String,
        val reviewHash: String,
        val targetSummary: String,
        val addedModels: List<String>,
        val changedModels: List<String>,
        val missingModels: List<String>,
        val capabilityChanges: List<String>,
        val initialPresets: List<String>,
        val routesRequiringPresetConfiguration: List<String>,
        val provenance: List<String>,
    ) : Actionable

    data class Blocked(
        override val connectionId: String,
        override val jobId: String,
        val message: String,
    ) : Actionable

    data class Interrupted(
        override val connectionId: String,
        override val jobId: String,
    ) : Actionable

    data class MultipleActive(
        val jobs: List<Actionable>,
    ) : ModelSyncUiState {
        override val connectionId: String = ""

        init {
            require(jobs.size > 1) {
                "Multiple-active model sync state requires at least two jobs."
            }
            require(jobs.map(Actionable::jobId).distinct().size == jobs.size) {
                "Multiple-active model sync jobs must have unique IDs."
            }
        }
    }

    data class Failed(
        override val connectionId: String,
        val message: String,
        val retryable: Boolean,
    ) : ModelSyncUiState
}

internal fun ModelSyncUiState.actionableJobs(): List<ModelSyncUiState.Actionable> = when (this) {
    is ModelSyncUiState.Actionable -> listOf(this)
    is ModelSyncUiState.MultipleActive -> jobs
    is ModelSyncUiState.Failed -> emptyList()
}

internal fun ModelSyncUiState?.hasActionableModelSync(): Boolean =
    this?.actionableJobs()?.isNotEmpty() == true

private fun dev.lorepia.app.bridge.ConnectionConfigValue.toEditorString(): String = when (this) {
    is dev.lorepia.app.bridge.ConnectionConfigValue.Boolean -> value.toString()
    is dev.lorepia.app.bridge.ConnectionConfigValue.Integer -> value.toString()
    is dev.lorepia.app.bridge.ConnectionConfigValue.Text -> value
}

internal fun RequestBodyShape.displayLabel(): String = when (this) {
    RequestBodyShape.Null -> "null"
    RequestBodyShape.Boolean -> "boolean"
    RequestBodyShape.Number -> "number"
    RequestBodyShape.StringValue -> "string"
    is RequestBodyShape.Array -> buildString {
        append("array[")
        append(items.joinToString(limit = 16) { it.displayLabel() })
        append(']')
        if (truncated) append("…")
    }
    is RequestBodyShape.Object -> buildString {
        append('{')
        append(
            fields.joinToString(limit = 64) { field ->
                "${field.name}: ${field.shape.displayLabel()}"
            },
        )
        append('}')
        if (truncated) append("…")
    }
    RequestBodyShape.Redacted -> "<redacted>"
    RequestBodyShape.Truncated -> "<truncated>"
}
