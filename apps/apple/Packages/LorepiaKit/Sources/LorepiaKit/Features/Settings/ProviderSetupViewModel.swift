import Combine
import Darwin
import Foundation

@MainActor
public final class ProviderSetupViewModel: ObservableObject {
    public enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    private struct ResolvedActiveGenerationSelection {
        let target: ProviderGenerationTarget?
        let connectionID: String?
    }

    private struct SelectionContext {
        let connectionID: String
        let modelRouteID: String?
        let presetID: String?
        let connectionGeneration: UInt64
        let routeGeneration: UInt64
        let refreshGeneration: UInt64
        let previewGeneration: UInt64

        func replacingPreset(
            id: String?,
            previewGeneration: UInt64
        ) -> SelectionContext {
            SelectionContext(
                connectionID: connectionID,
                modelRouteID: modelRouteID,
                presetID: id,
                connectionGeneration: connectionGeneration,
                routeGeneration: routeGeneration,
                refreshGeneration: refreshGeneration,
                previewGeneration: previewGeneration
            )
        }
    }

    private struct ConnectionHierarchyOwner {
        let refreshGeneration: UInt64
        let selectionGeneration: UInt64
        let selectedConnectionID: String?
    }

    private struct NormalizedPresetCandidate {
        let preset: ProviderGenerationPreset
        let reasoningControl: ProviderReasoningControl
    }

    private enum ModelSyncMutationOperation {
        case approve
        case cancel
    }

    private enum MutationRefreshOutcome: Equatable {
        case success
        case superseded
        case failed
    }

    private struct ConnectionHydrationOwner {
        let hierarchyOwner: ConnectionHierarchyOwner
        let routeSelectionGeneration: UInt64
        let selectedModelRouteID: String?
    }

    private struct ConnectionHydrationResult {
        let outcome: MutationRefreshOutcome
        let owner: ConnectionHydrationOwner?
    }

    private enum DiscoveryCommitReconciliationOutcome {
        case ready(MutationRefreshOutcome)
        case compensating
        case notCommitted
        case unresolved
    }

    private enum CredentialCompensationAcknowledgement: Sendable {
        case completed(ProviderDiscoverySnapshot)
        case outcomeUnknown(ProviderDiscoverySnapshot?)
    }

    @Published public private(set) var loadState: LoadState = .idle
    @Published public private(set) var templates: [ProviderTemplateDescriptor] = []
    @Published public private(set) var connections: [ProviderConnectionRecord] = []
    @Published public private(set) var catalogStatus: ProviderCatalogStatus?
    @Published public private(set) var pendingCatalogImport:
        ProviderCatalogImportPlan?
    @Published public private(set) var pendingCatalogImportFilename:
        String?
    @Published public private(set) var pendingCatalogRollback:
        ProviderCatalogRollbackPlan?
    @Published public private(set) var selectedConnectionID: String?
    @Published public private(set) var modelRoutes: [ProviderModelRoute] = []
    @Published public private(set) var selectedModelRouteID: String?
    @Published public private(set) var assistantModelRoutes:
        [ProviderModelRoute] = []
    @Published public private(set) var selectedAssistantModelRouteID:
        String?
    @Published public private(set) var presets: [ProviderGenerationPreset] = []
    @Published public private(set) var selectedPresetID: String?
    @Published public private(set) var activeGenerationTarget:
        ProviderGenerationTarget? {
        didSet {
            reconcileAssistantRouteSelectionWithActiveTarget()
        }
    }
    @Published public private(set) var capabilities: [ProviderEffectiveCapability] = []
    @Published public private(set) var routeParameterSpecs:
        [ProviderParameterSpec]?
    @Published public private(set) var reasoningControl:
        ProviderReasoningControl?
    @Published public private(set) var promptCacheControl:
        ProviderPromptCacheControl?
    @Published public private(set) var requestPreview: ProviderRequestPreview?
    @Published public private(set) var discovery: ProviderDiscoverySnapshot?
    @Published public private(set) var assistantHostAction:
        ProviderDiscoveryAssistantHostAction?
    @Published public private(set) var compensationSteps:
        [ProviderDiscoveryCompensationStep] = []
    @Published public private(set) var modelSyncJob: ProviderModelSyncJob?
    @Published public private(set) var modelSyncEventMessageKey: String?
    @Published public private(set) var isBusy = false
    @Published public private(set) var isSelectionLoading = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var statusMessage: String?

    @Published public var discoveryMethod: ProviderDiscoveryMethod = .knownProvider
    @Published public var discoveryDisplayName = ""
    @Published public var selectedTemplateID: String?
    @Published public var discoveryURL = ""
    @Published public var curlExample = ""
    @Published public var connectionFieldTextValues:
        [String: String] = [:]
    @Published public var connectionFieldBooleanValues:
        [String: Bool] = [:]
    @Published public var supplementalDocumentURL = ""
    @Published public var supplementalCurlExample = ""
    @Published public var approvesSupplementalCredentialOverwrite =
        false
    @Published public var credentialDraft = ""
    @Published public var discoveryNetworkMode:
        ProviderNetworkMode = .publicInternet
    @Published public var approvedLANOrigin = ""
    @Published public var approvedLANAddresses = ""
    @Published public private(set) var draftDiscoveryConnectionID =
        UUID().uuidString.lowercased()

    @Published public var presetName = "" {
        didSet { presetEditorGeneration &+= 1 }
    }
    @Published public var parameterValues: [
        String: ProviderParameterValueState
    ] = [:] {
        didSet { presetEditorGeneration &+= 1 }
    }
    @Published public private(set) var reasoningMode =
        "provider_default" {
        didSet { presetEditorGeneration &+= 1 }
    }
    @Published public var reasoningEffort = "" {
        didSet { presetEditorGeneration &+= 1 }
    }
    @Published public var reasoningBudgetTokens = "" {
        didSet { presetEditorGeneration &+= 1 }
    }
    @Published public var reasoningSummary = "provider_default" {
        didSet { presetEditorGeneration &+= 1 }
    }
    @Published public var preservesOpaqueReasoningState = false {
        didSet { presetEditorGeneration &+= 1 }
    }
    @Published public var promptCacheMode = "provider_default" {
        didSet { presetEditorGeneration &+= 1 }
    }
    @Published public var promptCacheTTL = "provider_default" {
        didSet { presetEditorGeneration &+= 1 }
    }
    @Published public var promptCacheCustomTTLSeconds = "" {
        didSet { presetEditorGeneration &+= 1 }
    }
    @Published public var promptCacheContextReference = "" {
        didSet { presetEditorGeneration &+= 1 }
    }

    public let runtimeMode: CoreRuntimeMode

    private let client: any CoreClient
    private let credentialStore: any CredentialStore
    private let providerConfigurationStore: ProviderConfigurationStore
    private var hasStagedDiscoveryCredential = false
    private var stagedDiscoveryConnectionID: String?
    private var activeGenerationConnectionID: String?
    private var refreshGeneration: UInt64 = 0
    private var connectionSelectionGeneration: UInt64 = 0
    private var modelRouteSelectionGeneration: UInt64 = 0
    private var requestPreviewGeneration: UInt64 = 0
    private var modelSyncOperationGeneration: UInt64 = 0
    private var discoveryOperationGeneration: UInt64 = 0
    private var assistantRouteSelectionGeneration: UInt64 = 0
    private var catalogReviewGeneration: UInt64 = 0
    private var catalogActivationInProgress = false
    private var draftPresetID = UUID().uuidString.lowercased()
    private var draftPresetCreatedAt =
        ISO8601DateFormatter().string(from: Date())
    private var previewedPresetCandidate: ProviderGenerationPreset?
    private var renderedPresetControlCandidate:
        ProviderGenerationPreset?
    private var presetEditorGeneration: UInt64 = 0
    private var presetControlRenderGeneration: UInt64 = 0
    private var presetControlRefreshTask: Task<Void, Never>?
    private var pendingCatalogEnvelopeJSON: Data?
    private var modelSyncMonitorTask: Task<Void, Never>?
    private var modelSyncEventConsumers: Set<String> = []
    private var discoveryMonitorTask: Task<Void, Never>?
    private var discoveryEventConsumers: Set<String> = []
    private var discoveryCompensationConsumers: Set<String> = []
    private var discoveryAssistantRouteSessionID: String?
    private var discoveryAssistantRouteID: String?
    private var restoredDiscoveryAssistantRouteIsUnavailable = false
    private var assistantCallEstimate:
        ProviderDiscoveryAssistantCallEstimate?
#if DEBUG
    private var activeGenerationSelectionCommitHookForTesting:
        (@MainActor () async -> Void)?
    private var activeGenerationReconciliationCommitHookForTesting:
        (@MainActor () async -> Void)?
    private var refreshPostCommitHookForTesting:
        (@MainActor () async -> Void)?
    private var refreshHydrationHookForTesting:
        (@MainActor () async -> Void)?
    private var modelSyncEventPollHookForTesting:
        (@MainActor () async throws -> Void)?
    private var modelSyncEventSnapshotCommitHookForTesting:
        (@MainActor () async -> Void)?
    private var modelSyncRestoreFailureHookForTesting:
        (@MainActor () async throws -> Void)?
    private var connectionHydrationCommitHookForTesting:
        (@MainActor () async -> Void)?
    private var connectionHydrationFailureHookForTesting:
        (@MainActor () async throws -> Void)?
    private var modelRouteHydrationCommitHookForTesting:
        (@MainActor () async -> Void)?
    private var requestPreviewCommitHookForTesting:
        (@MainActor () async throws -> Void)?
    private var presetNormalizationCommitHookForTesting:
        (@MainActor () async -> Void)?
    private var presetSaveCommitHookForTesting:
        (@MainActor () async throws -> Void)?
    private var presetSavePrePublishHookForTesting:
        (@MainActor () async -> Void)?
    private var presetSaveResponseFailureHookForTesting:
        (@MainActor () async throws -> Void)?
    private var presetDeletionCommitHookForTesting:
        (@MainActor () async throws -> Void)?
    private var connectionDeletionCommitHookForTesting:
        (@MainActor () async throws -> Void)?
    private var connectionDeletionPreCommitHookForTesting:
        (@MainActor () async -> Void)?
    private var cancellationIndependentSelectionStartHookForTesting:
        (@MainActor () async -> Void)?
    private var cancellationIndependentSelectionCompletionHookForTesting:
        (@MainActor () async -> Void)?
    private var providerMutationRefreshCommitHookForTesting:
        (@MainActor () async throws -> Void)?
    private var catalogActivationCommitHookForTesting:
        (@MainActor () async -> Void)?
    private var catalogPostActivationRefreshHookForTesting:
        (@MainActor () async throws -> Void)?
    private var catalogReviewCommitHookForTesting:
        (@MainActor () async -> Void)?
    private var catalogImportResultTransformForTesting:
        (@MainActor (
            ProviderCatalogImportResult
        ) -> ProviderCatalogImportResult)?
    private var catalogRollbackResultTransformForTesting:
        (@MainActor (
            ProviderCatalogRollbackResult
        ) -> ProviderCatalogRollbackResult)?
    private var discoveryCredentialStageCommitHookForTesting:
        (@MainActor () async -> Void)?
    private var discoveryBeginCommitHookForTesting:
        (@MainActor () async -> Void)?
    private var discoveryAssistantTurnCommitHookForTesting:
        (@MainActor () async throws -> Void)?
    private var discoveryAssistantCoreHostResumeCommitHookForTesting:
        (@MainActor () async throws -> Void)?
    private var discoveryAssistantCoreHostResumeInvocationForTesting:
        (@MainActor (
            String
        ) async throws -> ProviderDiscoverySnapshot)?
    private var discoveryAssistantRetryCommitHookForTesting:
        (@MainActor () async throws -> Void)?
    private var discoveryCancellationCommitHookForTesting:
        (@MainActor () async -> Void)?
    private var discoveryConnectionTransformForTesting:
        (@MainActor (
            ProviderConnectionRecord
        ) -> ProviderConnectionRecord)?
    private var discoveryPostCommitSnapshotHookForTesting:
        (@MainActor () async throws -> Void)?
    private var discoveryCompensationCredentialDeletionCommitHookForTesting:
        (@MainActor () async throws -> Void)?
    private var discoveryCompensationClaimCommitHookForTesting:
        (@MainActor () async -> Void)?
    private var discoveryCompensationResumeCommitHookForTesting:
        (@MainActor () async throws -> Void)?
    private var defaultSelectionCommitHookForTesting:
        (@MainActor () async -> Void)?
    private var defaultSelectionResultTransformForTesting:
        (@MainActor (CoreAppSettings) -> CoreAppSettings)?
    private var modelSyncOperationCommitHookForTesting:
        (@MainActor () async -> Void)?
    private var modelSyncStartInvocationForTesting:
        (@MainActor (
            String,
            String?
        ) async throws -> ProviderModelSyncJob)?
    private var modelSyncResponseTransformForTesting:
        (@MainActor (ProviderModelSyncJob) -> ProviderModelSyncJob)?
    private var presetSaveResultTransformForTesting:
        (@MainActor (
            ProviderGenerationPreset
        ) -> ProviderGenerationPreset)?
    private var discoveryEventSnapshotCommitHookForTesting:
        (@MainActor () async -> Void)?
    private var discoveryEventConsumerCompletionHookForTesting:
        (@MainActor (String) -> Void)?
    private var discoverySnapshotTransformForTesting:
        (@MainActor (
            ProviderDiscoverySnapshot
        ) -> ProviderDiscoverySnapshot)?
#endif

    public init(
        client: any CoreClient,
        credentialStore: any CredentialStore,
        runtimeMode: CoreRuntimeMode,
        providerConfigurationStore: ProviderConfigurationStore
    ) {
        self.client = client
        self.credentialStore = credentialStore
        self.runtimeMode = runtimeMode
        self.providerConfigurationStore = providerConfigurationStore
    }

#if DEBUG
    func setActiveGenerationSelectionCommitHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        activeGenerationSelectionCommitHookForTesting = hook
    }

    func setActiveGenerationReconciliationCommitHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        activeGenerationReconciliationCommitHookForTesting = hook
    }

    func setRefreshPostCommitHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        refreshPostCommitHookForTesting = hook
    }

    func setRefreshHydrationHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        refreshHydrationHookForTesting = hook
    }

    func setModelSyncEventPollHookForTesting(
        _ hook: (@MainActor () async throws -> Void)?
    ) {
        modelSyncEventPollHookForTesting = hook
    }

    func setModelSyncEventSnapshotCommitHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        modelSyncEventSnapshotCommitHookForTesting = hook
    }

    func setModelSyncRestoreFailureHookForTesting(
        _ hook: (@MainActor () async throws -> Void)?
    ) {
        modelSyncRestoreFailureHookForTesting = hook
    }

    func setConnectionHydrationCommitHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        connectionHydrationCommitHookForTesting = hook
    }

    func setConnectionHydrationFailureHookForTesting(
        _ hook: (@MainActor () async throws -> Void)?
    ) {
        connectionHydrationFailureHookForTesting = hook
    }

    func setModelRouteHydrationCommitHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        modelRouteHydrationCommitHookForTesting = hook
    }

    func setRequestPreviewCommitHookForTesting(
        _ hook: (@MainActor () async throws -> Void)?
    ) {
        requestPreviewCommitHookForTesting = hook
    }

    func setPresetNormalizationCommitHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        presetNormalizationCommitHookForTesting = hook
    }

    func setPresetSaveCommitHookForTesting(
        _ hook: (@MainActor () async throws -> Void)?
    ) {
        presetSaveCommitHookForTesting = hook
    }

    func setPresetSavePrePublishHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        presetSavePrePublishHookForTesting = hook
    }

    func setPresetSaveResponseFailureHookForTesting(
        _ hook: (@MainActor () async throws -> Void)?
    ) {
        presetSaveResponseFailureHookForTesting = hook
    }

    func setPresetDeletionCommitHookForTesting(
        _ hook: (@MainActor () async throws -> Void)?
    ) {
        presetDeletionCommitHookForTesting = hook
    }

    func setConnectionDeletionCommitHookForTesting(
        _ hook: (@MainActor () async throws -> Void)?
    ) {
        connectionDeletionCommitHookForTesting = hook
    }

    func setConnectionDeletionPreCommitHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        connectionDeletionPreCommitHookForTesting = hook
    }

    func setCancellationIndependentSelectionStartHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        cancellationIndependentSelectionStartHookForTesting = hook
    }

    func setCancellationIndependentSelectionCompletionHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        cancellationIndependentSelectionCompletionHookForTesting = hook
    }

    func setProviderMutationRefreshCommitHookForTesting(
        _ hook: (@MainActor () async throws -> Void)?
    ) {
        providerMutationRefreshCommitHookForTesting = hook
    }

    func setCatalogActivationCommitHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        catalogActivationCommitHookForTesting = hook
    }

    func setCatalogPostActivationRefreshHookForTesting(
        _ hook: (@MainActor () async throws -> Void)?
    ) {
        catalogPostActivationRefreshHookForTesting = hook
    }

    func setCatalogReviewCommitHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        catalogReviewCommitHookForTesting = hook
    }

    func setCatalogImportResultTransformForTesting(
        _ transform:
            (@MainActor (
                ProviderCatalogImportResult
            ) -> ProviderCatalogImportResult)?
    ) {
        catalogImportResultTransformForTesting = transform
    }

    func setCatalogRollbackResultTransformForTesting(
        _ transform:
            (@MainActor (
                ProviderCatalogRollbackResult
            ) -> ProviderCatalogRollbackResult)?
    ) {
        catalogRollbackResultTransformForTesting = transform
    }

    func setDiscoveryCredentialStageCommitHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        discoveryCredentialStageCommitHookForTesting = hook
    }

    func setDiscoveryBeginCommitHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        discoveryBeginCommitHookForTesting = hook
    }

    func setDiscoveryAssistantTurnCommitHookForTesting(
        _ hook: (@MainActor () async throws -> Void)?
    ) {
        discoveryAssistantTurnCommitHookForTesting = hook
    }

    func setDiscoveryAssistantCoreHostResumeCommitHookForTesting(
        _ hook: (@MainActor () async throws -> Void)?
    ) {
        discoveryAssistantCoreHostResumeCommitHookForTesting = hook
    }

    func setDiscoveryAssistantCoreHostResumeInvocationForTesting(
        _ invocation:
            (@MainActor (
                String
            ) async throws -> ProviderDiscoverySnapshot)?
    ) {
        discoveryAssistantCoreHostResumeInvocationForTesting =
            invocation
    }

    func setDiscoveryAssistantRetryCommitHookForTesting(
        _ hook: (@MainActor () async throws -> Void)?
    ) {
        discoveryAssistantRetryCommitHookForTesting = hook
    }

    func setDiscoveryCancellationCommitHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        discoveryCancellationCommitHookForTesting = hook
    }

    func setDiscoveryConnectionTransformForTesting(
        _ transform:
            (@MainActor (
                ProviderConnectionRecord
            ) -> ProviderConnectionRecord)?
    ) {
        discoveryConnectionTransformForTesting = transform
    }

    func setDiscoveryPostCommitSnapshotHookForTesting(
        _ hook: (@MainActor () async throws -> Void)?
    ) {
        discoveryPostCommitSnapshotHookForTesting = hook
    }

    func setDiscoveryCompensationCredentialDeletionCommitHookForTesting(
        _ hook: (@MainActor () async throws -> Void)?
    ) {
        discoveryCompensationCredentialDeletionCommitHookForTesting =
            hook
    }

    func setDiscoveryCompensationClaimCommitHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        discoveryCompensationClaimCommitHookForTesting = hook
    }

    func setDiscoveryCompensationResumeCommitHookForTesting(
        _ hook: (@MainActor () async throws -> Void)?
    ) {
        discoveryCompensationResumeCommitHookForTesting = hook
    }

    func setDefaultSelectionCommitHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        defaultSelectionCommitHookForTesting = hook
    }

    func setDefaultSelectionResultTransformForTesting(
        _ transform:
            (@MainActor (CoreAppSettings) -> CoreAppSettings)?
    ) {
        defaultSelectionResultTransformForTesting = transform
    }

    func setModelSyncOperationCommitHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        modelSyncOperationCommitHookForTesting = hook
    }

    func setModelSyncStartInvocationForTesting(
        _ invocation:
            (@MainActor (
                String,
                String?
            ) async throws -> ProviderModelSyncJob)?
    ) {
        modelSyncStartInvocationForTesting = invocation
    }

    func setModelSyncResponseTransformForTesting(
        _ transform:
            (@MainActor (ProviderModelSyncJob) -> ProviderModelSyncJob)?
    ) {
        modelSyncResponseTransformForTesting = transform
    }

    func setPresetSaveResultTransformForTesting(
        _ transform:
            (@MainActor (
                ProviderGenerationPreset
            ) -> ProviderGenerationPreset)?
    ) {
        presetSaveResultTransformForTesting = transform
    }

    func setDiscoveryEventSnapshotCommitHookForTesting(
        _ hook: (@MainActor () async -> Void)?
    ) {
        discoveryEventSnapshotCommitHookForTesting = hook
    }

    func setDiscoveryEventConsumerCompletionHookForTesting(
        _ hook: (@MainActor (String) -> Void)?
    ) {
        discoveryEventConsumerCompletionHookForTesting = hook
    }

    func setDiscoverySnapshotTransformForTesting(
        _ transform:
            (@MainActor (
                ProviderDiscoverySnapshot
            ) -> ProviderDiscoverySnapshot)?
    ) {
        discoverySnapshotTransformForTesting = transform
    }

    func replaceDiscoverySnapshotForTesting(
        _ snapshot: ProviderDiscoverySnapshot
    ) {
        guard discovery?.id == snapshot.id,
              discovery?.pendingConnectionID
                == snapshot.pendingConnectionID
        else {
            return
        }
        discovery = snapshot
        reconcileDiscoveryAssistantRoute(
            snapshot,
            establishesNewSession: false,
            establishedAssistantRouteID: nil,
            restoresAssistantRouteFromSnapshot: false
        )
        assistantHostAction = hostAction(
            from: snapshot.assistantResumeBoundary,
            sessionID: snapshot.id
        )
    }
#endif

    public var selectedConnection: ProviderConnectionRecord? {
        connections.first { $0.id == selectedConnectionID }
    }

    public var selectedModelRoute: ProviderModelRoute? {
        modelRoutes.first { $0.id == selectedModelRouteID }
    }

    public var selectedAssistantModelRoute: ProviderModelRoute? {
        assistantModelRoutes.first {
            $0.id == selectedAssistantModelRouteID
        }
    }

    public var selectedAssistantRouteConnection:
        ProviderConnectionRecord?
    {
        guard let connectionID =
            selectedAssistantModelRoute?.connectionID
        else {
            return nil
        }
        return connections.first { $0.id == connectionID }
    }

    public var assistantRouteSelectionIsRunnable: Bool {
        guard let route = selectedAssistantModelRoute,
              activeGenerationTarget?.modelRouteID == route.id
        else {
            return false
        }
        guard let discovery else {
            return true
        }
        return discoveryAssistantRouteSessionID == discovery.id
            && discoveryAssistantRouteID == route.id
            && !restoredDiscoveryAssistantRouteIsUnavailable
    }

    public var canRequestDiscoveryAssistant: Bool {
        guard let discovery,
              discovery.state == .awaitingMoreEvidence,
              discovery.actionRequired == .supplyMoreEvidence
        else {
            return false
        }
        return assistantRouteSelectionIsRunnable
    }

    public var assistantRouteSelectionMessage: String? {
        if let discovery,
           discoveryAssistantRouteSessionID == discovery.id,
           restoredDiscoveryAssistantRouteIsUnavailable
        {
            return
                "복원한 탐색에는 원래 선택한 문서 분석 모델 route가 공개 snapshot에 없습니다. 다른 모델로 추측하지 않고 탐색을 취소한 뒤 다시 시작해야 합니다."
        }
        if let discovery,
           discoveryAssistantRouteSessionID == discovery.id,
           let boundRouteID = discoveryAssistantRouteID,
           !assistantModelRoutes.contains(where: {
               $0.id == boundRouteID
           })
        {
            return
                "이 탐색에 고정된 문서 분석 모델 route ‘\(boundRouteID)’를 더 이상 찾을 수 없습니다. 다른 모델로 바꾸지 말고 탐색을 취소한 뒤 다시 시작하세요."
        }
        guard !assistantModelRoutes.isEmpty else {
            return
                "연결된 문서 분석 모델이 없어 설정 도우미만 사용할 수 없습니다. 결정론적 문서 탐색은 계속할 수 있고, 막히면 공식 문서나 redacted cURL을 추가하세요."
        }
        guard let activeRouteID =
            activeGenerationTarget?.modelRouteID
        else {
            return
                "문서 분석 AI를 사용하려면 연결 상세에서 앱 기본 모델과 프리셋을 먼저 선택하세요."
        }
        guard let selectedAssistantModelRouteID else {
            return
                "문서 분석에 사용할 모델을 선택하세요."
        }
        guard assistantModelRoutes.contains(where: {
            $0.id == selectedAssistantModelRouteID
        }) else {
            return
                "선택했던 문서 분석 모델 route가 더 이상 존재하지 않습니다. 모델 목록을 새로고침하거나 다른 모델을 선택하세요."
        }
        guard selectedAssistantModelRouteID == activeRouteID else {
            return
                "설정 도우미는 현재 앱 기본 모델과 프리셋으로 실행됩니다. 선택한 모델을 앱 기본 모델로 지정하거나 현재 기본 모델을 선택하세요."
        }
        return nil
    }

    public func assistantRouteIdentity(
        routeID: String
    ) -> (provider: String, model: String)? {
        guard let route = assistantModelRoutes.first(where: {
            $0.id == routeID
        }), let connection = connections.first(where: {
            $0.id == route.connectionID
        }) else {
            return nil
        }
        return (
            provider: connection.displayName,
            model: route.title
        )
    }

    public func assistantRouteTitle(
        _ route: ProviderModelRoute
    ) -> String {
        let provider = connections.first {
            $0.id == route.connectionID
        }?.displayName ?? route.connectionID
        return "\(provider) · \(route.title)"
    }

    public var selectedPreset: ProviderGenerationPreset? {
        presets.first { $0.id == selectedPresetID }
    }

    public var currentRequestPreview: ProviderRequestPreview? {
        guard let requestPreview,
              let previewedPresetCandidate,
              makePresetCandidate(
                  updatedAt: previewedPresetCandidate.updatedAt
              ) == previewedPresetCandidate
        else {
            return nil
        }
        return requestPreview
    }

    public var currentReasoningControl: ProviderReasoningControl? {
        guard let reasoningControl,
              let renderedPresetControlCandidate,
              makePresetCandidate(
                  updatedAt: renderedPresetControlCandidate.updatedAt
              ) == renderedPresetControlCandidate
        else {
            return nil
        }
        return reasoningControl
    }

    public var canEditOpaqueReasoningContinuity: Bool {
        selectedConnection?.hasCredential != true
            && currentReasoningControl?.preservesOpaqueState == true
    }

    public var currentPromptCacheControl: ProviderPromptCacheControl? {
        guard let promptCacheControl,
              let renderedPresetControlCandidate,
              makePresetCandidate(
                  updatedAt: renderedPresetControlCandidate.updatedAt
              ) == renderedPresetControlCandidate
        else {
            return nil
        }
        return promptCacheControl
    }

    public var selectedPresetIsAppDefault: Bool {
        guard let selectedPresetID,
              let selectedModelRouteID
        else {
            return false
        }
        return activeGenerationTarget == ProviderGenerationTarget(
            modelRouteID: selectedModelRouteID,
            generationPresetID: selectedPresetID
        )
    }

    public var selectedPresetCanBeDeleted: Bool {
        guard !isSelectionLoading,
              let selectedConnection,
              let selectedModelRoute,
              selectedModelRoute.connectionID == selectedConnection.id,
              let selectedPreset,
              selectedPreset.modelRouteID == selectedModelRoute.id
        else {
            return false
        }
        return selectedPreset.id != selectedModelRoute.id
    }

    public var selectedDiscoveryTemplate: ProviderTemplateDescriptor? {
        guard let selectedTemplateID else {
            return nil
        }
        return templates.first { $0.id == selectedTemplateID }
    }

    public var selectedConnectionTemplate: ProviderTemplateDescriptor? {
        guard let selectedConnection else {
            return nil
        }
        return templates.first {
            $0.id == selectedConnection.templateID
        }
    }

    public var visibleParameterSpecs: [ProviderParameterSpec] {
        allParameterSpecs.filter {
            $0.level != .hidden && parameterIsVisible($0)
        }
    }

    private var allParameterSpecs: [ProviderParameterSpec] {
        routeParameterSpecs
            ?? selectedConnectionTemplate?.parameters
            ?? []
    }

    public var canStartDiscovery: Bool {
        guard !isBusy,
              !hasStagedDiscoveryCredential,
              discoveryNetworkConfigurationIsValid,
              discoveryConnectionFieldsAreValid,
              !discoveryDisplayName.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty
        else {
            return false
        }
        switch discoveryMethod {
        case .knownProvider:
            guard let selectedDiscoveryTemplate else {
                return false
            }
            return !selectedDiscoveryTemplate.requiresCredential
                || normalizedCredentialDraft != nil
        case .website:
            return normalizedURLDraft != nil
                && normalizedCredentialDraft != nil
        case .curl:
            return !curlExample.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        case .localServer:
            return discoveryNetworkMode != .publicInternet
                && normalizedURLDraft != nil
        }
    }

    public func canApproveDiscoveryAssistant(
        _ consent: ProviderDiscoveryAssistantConsent
    ) -> Bool {
        guard let discovery,
              discovery.actionRequired == .assistantConsent(consent),
              discoveryAssistantRouteSessionID == discovery.id,
              discoveryAssistantRouteID
                == consent.assistantModelRouteID,
              selectedAssistantModelRouteID
                == consent.assistantModelRouteID
        else {
            return false
        }
        return assistantRouteSelectionIsRunnable
    }

    public var hasActiveDiscovery: Bool {
        guard let discovery else {
            return false
        }
        return !discovery.state.isTerminal
    }

    public var hasPendingDiscoveryCredentialCleanup: Bool {
        hasStagedDiscoveryCredential
            && stagedDiscoveryConnectionID != nil
    }

    public var hasPendingDiscoveryCompensation: Bool {
        discovery?.state == .compensating
            || compensationSteps.contains {
                $0.status != .completed
            }
    }

    public var selectedPresetParameterSummary: String {
        let explicitCount = parameterValues.values.reduce(into: 0) {
            count, value in
            if case .explicit = value {
                count += 1
            }
        }
        return explicitCount == 0
            ? "모든 옵션이 프로바이더 기본값"
            : "명시적으로 설정한 옵션 \(explicitCount)개"
    }

    public var parameterConflictMessages: [String] {
        allParameterSpecs.flatMap { spec -> [String] in
            guard explicitLiteral(for: spec.id) != nil else {
                return []
            }
            return spec.conflicts.compactMap { conflict in
                let otherIsExplicit =
                    explicitLiteral(for: conflict.parameterID) != nil
                switch conflict.kind {
                case .mutuallyExclusive where otherIsExplicit:
                    return conflict.message
                case .requires where !otherIsExplicit:
                    return conflict.message
                default:
                    return nil
                }
            }
        }
    }

    public func refresh() async {
        let preferredConnectionID = selectedConnectionID
        let preferredModelRouteID = selectedModelRouteID
        refreshGeneration &+= 1
        let generation = refreshGeneration
        connectionSelectionGeneration &+= 1
        let selectionGeneration =
            connectionSelectionGeneration
        invalidateConnectionHierarchy(clearsModelSync: false)
        isSelectionLoading = true
        loadState = .loading
        errorMessage = nil

        do {
            async let loadedTemplates = client.listProviderTemplates()
            async let loadedConnections = client.listProviderConnections()
            async let loadedSettings = client.getSettings()
            async let loadedCatalogStatus =
                try? client.getProviderCatalogStatus()
            let (newTemplates, newConnections, settings) = try await (
                loadedTemplates,
                loadedConnections,
                loadedSettings
            )
            let newCatalogStatus = await loadedCatalogStatus
            try Task.checkCancellation()
            guard generation == refreshGeneration,
                  selectionGeneration
                    == connectionSelectionGeneration
            else {
                finishSupersededRefreshIfCurrent(
                    generation: generation
                )
                return
            }
            let sortedTemplates = newTemplates.sorted {
                $0.displayName.localizedStandardCompare($1.displayName)
                    == .orderedAscending
            }
            let sortedConnections = newConnections.sorted {
                $0.displayName.localizedStandardCompare($1.displayName)
                    == .orderedAscending
            }
            let resolvedActiveSelection =
                try await resolveActiveGenerationSelection(
                    settings,
                    connections: sortedConnections
                )
            let loadedAssistantRoutes =
                try await loadAssistantModelRoutes(
                    connections: sortedConnections
                )
#if DEBUG
            await activeGenerationSelectionCommitHookForTesting?()
#endif
            try Task.checkCancellation()
            guard generation == refreshGeneration,
                  selectionGeneration
                    == connectionSelectionGeneration
            else {
                finishSupersededRefreshIfCurrent(
                    generation: generation
                )
                return
            }
            templates = sortedTemplates
            connections = sortedConnections
            applyActiveGenerationSelection(resolvedActiveSelection)
            replaceAssistantModelRoutes(loadedAssistantRoutes)
            catalogStatus = newCatalogStatus
            if selectedTemplateID == nil {
                selectDiscoveryTemplate(id: templates.first?.id)
            }
            selectedConnectionID = connections.contains(where: {
                $0.id == preferredConnectionID
            }) ? preferredConnectionID : connections.first?.id
            loadState = .loaded
#if DEBUG
            await refreshPostCommitHookForTesting?()
#endif
            try Task.checkCancellation()
            guard generation == refreshGeneration,
                  selectionGeneration
                    == connectionSelectionGeneration
            else {
                finishSupersededRefreshIfCurrent(
                    generation: generation
                )
                return
            }
#if DEBUG
            await refreshHydrationHookForTesting?()
#endif
            try Task.checkCancellation()
            guard generation == refreshGeneration,
                  selectionGeneration
                    == connectionSelectionGeneration
            else {
                finishSupersededRefreshIfCurrent(
                    generation: generation
                )
                return
            }
            await restoreProviderDiscovery(
                expectedRefreshGeneration: generation
            )
            try Task.checkCancellation()
            guard generation == refreshGeneration,
                  selectionGeneration
                    == connectionSelectionGeneration
            else {
                finishSupersededRefreshIfCurrent(
                    generation: generation
                )
                return
            }

            if let selectedConnectionID {
                await selectConnection(
                    id: selectedConnectionID,
                    expectedRefreshGeneration: generation,
                    preferredModelRouteID: preferredModelRouteID
                )
            } else {
                isSelectionLoading = false
            }
            try Task.checkCancellation()
            guard generation == refreshGeneration else {
                return
            }
            publishConfigurationSnapshotIfResolved()
        } catch is CancellationError {
            if generation == refreshGeneration {
                isSelectionLoading = false
                loadState = connections.isEmpty
                    ? .idle
                    : .loaded
            }
            return
        } catch {
            guard !Task.isCancelled,
                  generation == refreshGeneration,
                  selectionGeneration
                    == connectionSelectionGeneration
            else {
                finishSupersededRefreshIfCurrent(
                    generation: generation
                )
                return
            }
            loadState = .failed
            isSelectionLoading = false
            errorMessage = safeFailureMessage(
                action: "프로바이더 연결을 불러오지",
                error: error
            )
        }
    }

    public func prepareDiscovery(
        method: ProviderDiscoveryMethod
    ) {
        guard !isBusy,
              !hasActiveDiscovery,
              !hasStagedDiscoveryCredential
        else {
            errorMessage =
                "진행 중인 탐색 또는 Keychain 정리를 먼저 완료하세요."
            return
        }
        discoveryOperationGeneration &+= 1
        discoveryMethod = method
        discovery = nil
        stopDiscoveryMonitor()
        discoveryDisplayName = switch method {
        case .knownProvider:
            ""
        case .website:
            "새 웹사이트 AI"
        case .curl:
            "가져온 API 연결"
        case .localServer:
            "로컬 AI 서버"
        }
        discoveryURL = ""
        curlExample = ""
        connectionFieldTextValues = [:]
        connectionFieldBooleanValues = [:]
        supplementalDocumentURL = ""
        supplementalCurlExample = ""
        approvesSupplementalCredentialOverwrite = false
        credentialDraft = ""
        assistantHostAction = nil
        discoveryAssistantRouteSessionID = nil
        discoveryAssistantRouteID = nil
        restoredDiscoveryAssistantRouteIsUnavailable = false
        compensationSteps = []
        approvedLANOrigin = ""
        approvedLANAddresses = ""
        discoveryNetworkMode = method == .localServer
            ? .localLoopback
            : .publicInternet
        draftDiscoveryConnectionID =
            UUID().uuidString.lowercased()
        if method == .knownProvider {
            selectDiscoveryTemplate(id: templates.first?.id)
        } else {
            selectedTemplateID = templates.first?.id
        }
        reconcileAssistantRouteSelectionWithActiveTarget()
        errorMessage = nil
        statusMessage = nil
    }

    public func selectAssistantModelRoute(id: String?) {
        guard discovery == nil else {
            return
        }
        let validatedID = assistantModelRoutes.contains {
            $0.id == id
        } ? id : nil
        setSelectedAssistantModelRouteID(validatedID)
        errorMessage = nil
    }

    public func selectDiscoveryTemplate(id: String?) {
        let previousTemplate = selectedDiscoveryTemplate
        let shouldUseTemplateDisplayName =
            discoveryDisplayName.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
            || discoveryDisplayName
                == previousTemplate?.displayName
        selectedTemplateID = id
        guard discoveryMethod == .knownProvider,
              let template = templates.first(where: {
                  $0.id == id
              })
        else {
            return
        }
        if shouldUseTemplateDisplayName {
            discoveryDisplayName = template.displayName
        }
        discoveryNetworkMode = template.defaultNetworkMode
        connectionFieldTextValues = Dictionary(
            uniqueKeysWithValues:
                template.connectionFields.compactMap { field in
                    switch field.type {
                    case .text, .integer:
                        (field.key, "")
                    case .boolean, .credential:
                        nil
                    }
                }
        )
        connectionFieldBooleanValues = Dictionary(
            uniqueKeysWithValues:
                template.connectionFields.compactMap { field in
                    field.type == .boolean
                        ? (field.key, false)
                        : nil
                }
        )
        if discoveryNetworkMode != .approvedLocalNetwork {
            approvedLANOrigin = ""
            approvedLANAddresses = ""
        }
    }

    public func startDiscovery() async {
        guard canStartDiscovery, beginOperation() else {
            if !canStartDiscovery {
                errorMessage = discoveryValidationMessage
            }
            return
        }
        defer { endOperation() }
        discoveryOperationGeneration &+= 1
        let operationGeneration = discoveryOperationGeneration
        let assistantSelectionGeneration =
            assistantRouteSelectionGeneration
        let selectedAssistantRouteIDAtStart =
            selectedAssistantModelRouteID
        let activeAssistantRouteIDAtStart =
            activeGenerationTarget?.modelRouteID
        let assistantRouteID = assistantRouteSelectionIsRunnable
            ? selectedAssistantRouteIDAtStart
            : nil

        let connectionID = draftDiscoveryConnectionID
        let displayName = discoveryDisplayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        var rawCurl = discoveryMethod == .curl ? curlExample : nil
        curlExample = ""
        defer {
            rawCurl?.removeAll(keepingCapacity: false)
        }
        var inspectedCurl: String?
        defer {
            inspectedCurl?.removeAll(keepingCapacity: false)
        }
        var typedCredential = normalizedCredentialDraft.map {
            Data($0.utf8)
        }
        defer {
            if let count = typedCredential?.count {
                typedCredential?.resetBytes(in: 0 ..< count)
            }
        }

        let connectionOptions: ProviderDiscoveryConnectionOptions
        do {
            connectionOptions = try makeDiscoveryConnectionOptions()
        } catch {
            credentialDraft = ""
            errorMessage = safeFailureMessage(
                action: "네트워크 승인 범위를 확인하지",
                error: error
            )
            return
        }

        do {
            try requireNewDiscoveryConnectionID(connectionID)
            let existingCredential =
                try await credentialStore.credentialData(
                for: connectionID
            )
            guard discoveryDraftOperationIsCurrent(
                operationGeneration,
                connectionID: connectionID
            ), assistantRouteDraftIsCurrent(
                generation: assistantSelectionGeneration,
                selectedRouteID:
                    selectedAssistantRouteIDAtStart,
                activeRouteID:
                    activeAssistantRouteIDAtStart
            ) else {
                return
            }
            guard existingCredential == nil else {
                throw CoreClientFailure.invalidResponse(
                    "새 연결의 Keychain 슬롯이 이미 사용 중입니다."
                )
            }

            if var curlForInspection = rawCurl {
                let inspection = try await client.inspectProviderCurl(
                    curlForInspection,
                    networkPolicy: ProviderNetworkPolicy(
                        mode: connectionOptions.networkMode,
                        localNetworkApproval:
                            connectionOptions.localNetworkApproval
                    )
                )
                guard discoveryDraftOperationIsCurrent(
                    operationGeneration,
                    connectionID: connectionID
                ), assistantRouteDraftIsCurrent(
                    generation: assistantSelectionGeneration,
                    selectedRouteID:
                        selectedAssistantRouteIDAtStart,
                    activeRouteID:
                        activeAssistantRouteIDAtStart
                ) else {
                    return
                }
                curlForInspection.removeAll(keepingCapacity: false)
                rawCurl?.removeAll(keepingCapacity: false)
                guard inspection.schemaVersion > 0 else {
                    throw CoreClientFailure.invalidResponse(
                        "지원하지 않는 cURL 검사 결과입니다."
                    )
                }
                inspectedCurl = inspection.redactedCurl
                guard normalizedNonempty(inspectedCurl ?? "") != nil else {
                    throw CoreClientFailure.invalidResponse(
                        "cURL 검사 결과에 재파싱 가능한 redacted 요청이 없습니다."
                    )
                }
                if let handoffID = inspection.credentialHandoffID {
                    guard var extracted = try await client
                        .takeProviderCurlCredential(
                            handoffID: handoffID
                        )
                    else {
                        throw CoreClientFailure.invalidResponse(
                            "cURL 인증값의 일회성 이관이 만료되었거나 이미 사용되었습니다."
                        )
                    }
                    defer {
                        extracted.resetBytes(in: 0 ..< extracted.count)
                    }
                    guard discoveryDraftOperationIsCurrent(
                        operationGeneration,
                        connectionID: connectionID
                    ), assistantRouteDraftIsCurrent(
                        generation: assistantSelectionGeneration,
                        selectedRouteID:
                            selectedAssistantRouteIDAtStart,
                        activeRouteID:
                            activeAssistantRouteIDAtStart
                    ) else {
                        return
                    }
                    if let typedCredential,
                       typedCredential != extracted
                    {
                        throw CoreClientFailure.invalidResponse(
                            "cURL 인증값과 별도로 입력한 API 키가 다릅니다."
                        )
                    }
                    try await stageDiscoveryCredentialData(
                        &extracted,
                        connectionID: connectionID,
                        expectedOperationGeneration:
                            operationGeneration
                    )
                } else if var typedCredential {
                    try await stageDiscoveryCredentialData(
                        &typedCredential,
                        connectionID: connectionID,
                        expectedOperationGeneration:
                            operationGeneration
                    )
                }
            } else if var typedCredential {
                try await stageDiscoveryCredentialData(
                    &typedCredential,
                    connectionID: connectionID,
                    expectedOperationGeneration:
                        operationGeneration
                )
            }
        } catch {
            let ownsDraft = discoveryDraftIdentityIsCurrent(
                operationGeneration,
                connectionID: connectionID
            ) && assistantRouteDraftIsCurrent(
                generation: assistantSelectionGeneration,
                selectedRouteID:
                    selectedAssistantRouteIDAtStart,
                activeRouteID:
                    activeAssistantRouteIDAtStart
            )
            let cleaned =
                await clearDiscoveryCredentialAfterFailure(
                    expectedOperationGeneration:
                        operationGeneration,
                    expectedConnectionID: connectionID
                )
            guard ownsDraft,
                  !Task.isCancelled,
                  discoveryDraftIdentityIsCurrent(
                      operationGeneration,
                      connectionID: connectionID
                  ),
                  assistantRouteDraftIsCurrent(
                      generation: assistantSelectionGeneration,
                      selectedRouteID:
                          selectedAssistantRouteIDAtStart,
                      activeRouteID:
                          activeAssistantRouteIDAtStart
                  )
            else {
                return
            }
            credentialDraft = ""
            errorMessage = cleaned
                ? safeFailureMessage(
                    action: "API 키와 cURL을 안전하게 준비하지",
                    error: error
                )
                : "탐색 준비 실패 후 새 연결의 API 키를 Keychain에서 지우지 못했습니다. 정리를 다시 시도하세요."
            return
        }

        guard discoveryDraftOperationIsCurrent(
            operationGeneration,
            connectionID: connectionID
        ), assistantRouteDraftIsCurrent(
            generation: assistantSelectionGeneration,
            selectedRouteID:
                selectedAssistantRouteIDAtStart,
            activeRouteID:
                activeAssistantRouteIDAtStart
        ) else {
            await cleanupCancelledDiscoveryStart(
                snapshot: nil,
                connectionID: connectionID,
                operationGeneration: operationGeneration
            )
            return
        }
        credentialDraft = ""
        let source: ProviderDiscoverySource
        switch discoveryMethod {
        case .knownProvider:
            guard let selectedTemplateID else {
                errorMessage = "선택한 프로바이더를 확인하세요."
                return
            }
            source = .knownProvider(templateID: selectedTemplateID)
        case .website, .localServer:
            source = .site
        case .curl:
            source = .curl
        }

        let input = ProviderDiscoveryInput(
            connectionID: connectionID,
            displayName: displayName,
            siteURL: discoveryMethod == .website
                || discoveryMethod == .localServer
                ? normalizedURLDraft
                : nil,
            credentialSlotReady: hasStagedDiscoveryCredential,
            preferredAssistantModelRouteID: assistantRouteID,
            connectionOptions: connectionOptions
        )

        var begunSnapshot: ProviderDiscoverySnapshot?
        do {
            guard discoveryDraftOperationIsCurrent(
                operationGeneration,
                connectionID: connectionID
            ), assistantRouteDraftIsCurrent(
                generation: assistantSelectionGeneration,
                selectedRouteID:
                    selectedAssistantRouteIDAtStart,
                activeRouteID:
                    activeAssistantRouteIDAtStart
            ) else {
                return
            }
            var snapshot = try await client.beginProviderDiscovery(
                input: input,
                source: source,
                rawCurl: inspectedCurl
            )
#if DEBUG
            await discoveryBeginCommitHookForTesting?()
#endif
            begunSnapshot = snapshot
            try validateDiscoverySnapshot(
                snapshot,
                expectedConnectionID: connectionID
            )
            guard discoveryDraftOperationIsCurrent(
                operationGeneration,
                connectionID: connectionID
            ), assistantRouteDraftIsCurrent(
                generation: assistantSelectionGeneration,
                selectedRouteID:
                    selectedAssistantRouteIDAtStart,
                activeRouteID:
                    activeAssistantRouteIDAtStart
            ) else {
                await cleanupCancelledDiscoveryStart(
                    snapshot: snapshot,
                    connectionID: connectionID,
                    operationGeneration: operationGeneration
                )
                return
            }
#if DEBUG
            snapshot =
                discoverySnapshotTransformForTesting?(snapshot)
                    ?? snapshot
#endif
            try validateDiscoverySnapshot(
                snapshot,
                expectedConnectionID: connectionID
            )
            guard applyDiscoverySnapshot(
                snapshot,
                expectedConnectionID: connectionID,
                expectedOperationGeneration: operationGeneration,
                allowsSessionEstablishment: true,
                establishedAssistantRouteID: assistantRouteID
            ) else {
                return
            }
            startDiscoveryMonitor(
                sessionID: snapshot.id,
                expectedOperationGeneration: operationGeneration
            )
            errorMessage = nil
            statusMessage = "탐색을 시작했습니다. 각 전송과 검사는 승인 후 진행됩니다."
        } catch is CancellationError {
            await cleanupCancelledDiscoveryStart(
                snapshot: begunSnapshot,
                connectionID: connectionID,
                operationGeneration: operationGeneration
            )
            return
        } catch {
            let ownsDraft = discoveryDraftIdentityIsCurrent(
                operationGeneration,
                connectionID: connectionID
            ) && assistantRouteDraftIsCurrent(
                generation: assistantSelectionGeneration,
                selectedRouteID:
                    selectedAssistantRouteIDAtStart,
                activeRouteID:
                    activeAssistantRouteIDAtStart
            )
            await cleanupCancelledDiscoveryStart(
                snapshot: begunSnapshot,
                connectionID: connectionID,
                operationGeneration: operationGeneration
            )
            guard ownsDraft,
                  !Task.isCancelled,
                  discoveryDraftIdentityIsCurrent(
                      operationGeneration,
                      connectionID: connectionID
                  ),
                  assistantRouteDraftIsCurrent(
                      generation: assistantSelectionGeneration,
                      selectedRouteID:
                          selectedAssistantRouteIDAtStart,
                      activeRouteID:
                          activeAssistantRouteIDAtStart
                  )
            else {
                return
            }
            errorMessage = safeFailureMessage(
                action: "프로바이더 자동 탐색을 시작하지",
                error: error
            )
            if hasStagedDiscoveryCredential {
                errorMessage =
                    "탐색 시작 실패 후 새 연결의 API 키를 Keychain에서 지우지 못했습니다. 정리를 다시 시도하세요."
            }
        }
    }

    public func continueDiscovery(
        _ action: ProviderDiscoveryAction
    ) async {
        if action == .requestAssistant,
           !canRequestDiscoveryAssistant
        {
            errorMessage = assistantRouteSelectionMessage
                ?? "문서 분석 AI를 안전하게 선택할 수 없어 설정 도우미를 요청하지 않았습니다."
            return
        }
        if case let .approveAssistant(
            approvalID,
            grantSHA256
        ) = action {
            guard case let .assistantConsent(consent) =
                discovery?.actionRequired,
                consent.approvalID == approvalID,
                consent.grantSHA256 == grantSHA256,
                canApproveDiscoveryAssistant(consent)
            else {
                errorMessage = assistantRouteSelectionMessage
                    ?? "승인할 문서 분석 AI의 연결과 모델이 현재 선택과 일치하지 않습니다."
                return
            }
        }
        guard let discovery, beginOperation() else {
            return
        }
        defer { endOperation() }
        let operationGeneration = discoveryOperationGeneration
        var didInvokeMutation = false

        do {
            let assistantConsent: ProviderDiscoveryAssistantConsent?
            if case .approveAssistant = action,
               case let .assistantConsent(consent) =
                   discovery.actionRequired
            {
                assistantConsent = consent
            } else {
                assistantConsent = nil
            }
            let actionID = UUID().uuidString.lowercased()
            let envelope = try await client.prepareProviderDiscoveryAction(
                actionID: actionID,
                expectedRevision: discovery.revision,
                action: action
            )
            guard envelope.actionID == actionID,
                  envelope.expectedRevision == discovery.revision,
                  envelope.action == action,
                  !envelope.requestSHA256.isEmpty
            else {
                throw CoreClientFailure.invalidResponse(
                    "Rust가 준비한 탐색 작업 봉투가 요청과 일치하지 않습니다."
                )
            }
            guard discoveryContextIsCurrent(
                sessionID: discovery.id,
                connectionID: discovery.pendingConnectionID,
                expectedOperationGeneration: operationGeneration,
                expectedRevision: discovery.revision
            ) else {
                return
            }
            let targetCredential =
                try await requestScopedTargetCredential(
                    for: action,
                    snapshot: discovery
                )
            guard discoveryContextIsCurrent(
                sessionID: discovery.id,
                connectionID: discovery.pendingConnectionID,
                expectedOperationGeneration: operationGeneration,
                expectedRevision: discovery.revision
            ) else {
                return
            }
            didInvokeMutation = true
            var snapshot = try await client.continueProviderDiscovery(
                sessionID: discovery.id,
                envelope: envelope,
                targetCredential: targetCredential
            )
#if DEBUG
            snapshot =
                discoverySnapshotTransformForTesting?(snapshot)
                    ?? snapshot
#endif
            try validateDiscoverySnapshot(
                snapshot,
                expectedConnectionID: discovery.pendingConnectionID,
                expectedSessionID: discovery.id
            )
            let reconciliation =
                await reconcileDiscoverySessionIgnoringCallerCancellation(
                    sessionID: discovery.id,
                    expectedConnectionID:
                        discovery.pendingConnectionID,
                    expectedOperationGeneration:
                        operationGeneration
                )
            guard reconciliation == .success,
                  let snapshot = self.discovery,
                  snapshot.id == discovery.id
            else {
                return
            }
            errorMessage = nil
            statusMessage = discoveryStatus(snapshot)
            if let assistantConsent,
               snapshot.state == .buildingAssistantManifestDraft
            {
                assistantCallEstimate =
                    makeAssistantCallEstimate(assistantConsent)
                try await performDiscoveryAssistantTurn(
                    snapshot: snapshot,
                    expectedOperationGeneration:
                        operationGeneration
                )
            }
            if snapshot.state == .compensating {
                _ = try await performDiscoveryCompensation(
                    startingFrom: snapshot,
                    expectedOperationGeneration:
                        operationGeneration
                )
            }
            if snapshot.state == .cancelled
                || snapshot.state == .failed
            {
                guard discoveryContextIsCurrent(
                    sessionID: snapshot.id,
                    connectionID: snapshot.pendingConnectionID,
                    expectedOperationGeneration:
                        operationGeneration
                ) else {
                    return
                }
                do {
                    try await clearStagedDiscoveryCredential()
                } catch {
                    errorMessage =
                        "탐색은 끝났지만 새 연결의 API 키를 Keychain에서 지우지 못했습니다. 정리를 다시 시도하세요."
                }
            }
        } catch {
            if didInvokeMutation {
                let reconciliation =
                    await reconcileDiscoverySessionIgnoringCallerCancellation(
                        sessionID: discovery.id,
                        expectedConnectionID:
                            discovery.pendingConnectionID,
                        expectedOperationGeneration:
                            operationGeneration
                    )
                guard reconciliation != .superseded else {
                    return
                }
                if reconciliation == .success,
                   discoveryContextOwns(
                       sessionID: discovery.id,
                       connectionID:
                           discovery.pendingConnectionID,
                       expectedOperationGeneration:
                           operationGeneration
                   )
                {
                    errorMessage = safeFailureMessage(
                        action: "처리된 탐색 단계의 완료 응답을 검증하지",
                        error: error
                    )
                    statusMessage =
                        "탐색 단계는 처리됐지만 완료 응답을 다시 확인했습니다."
                    return
                }
            }
            guard discoveryContextIsCurrent(
                sessionID: discovery.id,
                connectionID: discovery.pendingConnectionID,
                expectedOperationGeneration: operationGeneration
            ) else {
                return
            }
            errorMessage = safeFailureMessage(
                action: "탐색 단계를 진행하지",
                error: error
            )
        }
    }

    public func requestDiscoveryAssistant() async {
        guard canRequestDiscoveryAssistant else {
            errorMessage = assistantRouteSelectionMessage
                ?? "문서 분석 AI를 안전하게 선택할 수 없어 설정 도우미를 요청하지 않았습니다."
            return
        }
        await continueDiscovery(.requestAssistant)
    }

    public func supplyFreshDocumentEvidence() async {
        guard let discovery,
              let documentURL = normalizedNonempty(
                  supplementalDocumentURL
              ),
              beginOperation()
        else {
            if normalizedNonempty(supplementalDocumentURL) == nil {
                errorMessage = "추가할 공식 문서 주소를 입력하세요."
            }
            return
        }
        supplementalDocumentURL = ""
        defer { endOperation() }
        let operationGeneration = discoveryOperationGeneration
        var didInvokeMutation = false

        do {
            didInvokeMutation = true
            var snapshot =
                try await client
                    .supplyProviderDiscoveryDocumentEvidence(
                        sessionID: discovery.id,
                        expectedRevision: discovery.revision,
                        documentURL: documentURL
                    )
#if DEBUG
            snapshot =
                discoverySnapshotTransformForTesting?(snapshot)
                    ?? snapshot
#endif
            try validateDiscoverySnapshot(
                snapshot,
                expectedConnectionID:
                    discovery.pendingConnectionID,
                expectedSessionID: discovery.id
            )
            let reconciliation =
                await reconcileDiscoverySessionIgnoringCallerCancellation(
                    sessionID: discovery.id,
                    expectedConnectionID:
                        discovery.pendingConnectionID,
                    expectedOperationGeneration:
                        operationGeneration
                )
            guard reconciliation == .success else {
                return
            }
            errorMessage = nil
            statusMessage =
                "새 문서를 Core가 가져와 검증된 증거로 추가했습니다."
        } catch {
            if didInvokeMutation {
                let reconciliation =
                    await reconcileDiscoverySessionIgnoringCallerCancellation(
                        sessionID: discovery.id,
                        expectedConnectionID:
                            discovery.pendingConnectionID,
                        expectedOperationGeneration:
                            operationGeneration
                    )
                guard reconciliation != .superseded else {
                    return
                }
                if reconciliation == .success,
                   discoveryContextOwns(
                       sessionID: discovery.id,
                       connectionID:
                           discovery.pendingConnectionID,
                       expectedOperationGeneration:
                           operationGeneration
                   )
                {
                    errorMessage = safeFailureMessage(
                        action: "추가된 문서 증거의 완료 응답을 검증하지",
                        error: error
                    )
                    statusMessage =
                        "문서 증거는 추가됐지만 완료 응답을 다시 확인했습니다."
                    return
                }
            }
            guard discoveryContextIsCurrent(
                sessionID: discovery.id,
                connectionID: discovery.pendingConnectionID,
                expectedOperationGeneration: operationGeneration
            ) else {
                return
            }
            errorMessage = safeFailureMessage(
                action: "추가 문서를 검증해 증거로 넣지",
                error: error
            )
        }
    }

    public func supplyFreshCurlEvidence() async {
        guard let discovery,
              normalizedNonempty(supplementalCurlExample) != nil,
              beginOperation()
        else {
            if normalizedNonempty(supplementalCurlExample) == nil {
                errorMessage = "추가할 cURL 예제를 입력하세요."
            }
            return
        }
        var rawCurl = supplementalCurlExample
        supplementalCurlExample = ""
        defer {
            rawCurl.removeAll(keepingCapacity: false)
            approvesSupplementalCredentialOverwrite = false
            endOperation()
        }
        let operationGeneration = discoveryOperationGeneration
        var didInvokeMutation = false

        do {
            let inspection = try await client.inspectProviderCurl(
                rawCurl,
                networkPolicy: ProviderNetworkPolicy(
                    mode: discovery.connectionOptions.networkMode,
                    localNetworkApproval:
                        discovery.connectionOptions
                            .localNetworkApproval
                )
            )
            rawCurl.removeAll(keepingCapacity: false)
            var redactedCurl = inspection.redactedCurl
            defer {
                redactedCurl.removeAll(keepingCapacity: false)
            }

            if let handoffID = inspection.credentialHandoffID {
                guard var extracted = try await client
                    .takeProviderCurlCredential(
                        handoffID: handoffID
                    )
                else {
                    throw CoreClientFailure.invalidResponse(
                        "cURL 인증값의 일회성 이관이 만료되었거나 이미 사용되었습니다."
                    )
                }
                defer {
                    extracted.resetBytes(in: 0 ..< extracted.count)
                }
                guard discovery.credentialSlotExpected,
                      discovery.credentialSlotID
                        == discovery.pendingConnectionID
                else {
                    throw CoreClientFailure.invalidResponse(
                        "현재 탐색은 Keychain 슬롯을 기대하지 않습니다. API 키 입력 또는 cURL 방식으로 새 탐색을 시작하세요."
                    )
                }
                let existing = try await credentialStore
                    .credentialData(
                        for: discovery.pendingConnectionID
                    )
                if let existing {
                    if existing != extracted {
                        guard
                            approvesSupplementalCredentialOverwrite
                        else {
                            throw CoreClientFailure
                                .configurationRequired(
                                    "cURL의 API 키가 기존 Keychain 값과 다릅니다. 별도의 ‘기존 API 키 교체’ 승인을 켠 뒤 cURL을 다시 붙여넣으세요."
                                )
                        }
                        guard discoveryContextIsCurrent(
                            sessionID: discovery.id,
                            connectionID:
                                discovery.pendingConnectionID,
                            expectedOperationGeneration:
                                operationGeneration,
                            expectedRevision: discovery.revision
                        ) else {
                            return
                        }
                        try await stageDiscoveryCredentialData(
                            &extracted,
                            connectionID:
                                discovery.pendingConnectionID
                        )
                    } else {
                        stagedDiscoveryConnectionID =
                            discovery.pendingConnectionID
                        hasStagedDiscoveryCredential = true
                    }
                } else {
                    guard discoveryContextIsCurrent(
                        sessionID: discovery.id,
                        connectionID:
                            discovery.pendingConnectionID,
                        expectedOperationGeneration:
                            operationGeneration,
                        expectedRevision: discovery.revision
                    ) else {
                        return
                    }
                    try await stageDiscoveryCredentialData(
                        &extracted,
                        connectionID:
                            discovery.pendingConnectionID
                    )
                }
            }

            didInvokeMutation = true
            var snapshot =
                try await client.supplyProviderDiscoveryCurlEvidence(
                    sessionID: discovery.id,
                    expectedRevision: discovery.revision,
                    redactedCurl: redactedCurl
                )
#if DEBUG
            snapshot =
                discoverySnapshotTransformForTesting?(snapshot)
                    ?? snapshot
#endif
            try validateDiscoverySnapshot(
                snapshot,
                expectedConnectionID:
                    discovery.pendingConnectionID,
                expectedSessionID: discovery.id
            )
            let reconciliation =
                await reconcileDiscoverySessionIgnoringCallerCancellation(
                    sessionID: discovery.id,
                    expectedConnectionID:
                        discovery.pendingConnectionID,
                    expectedOperationGeneration:
                        operationGeneration
                )
            guard reconciliation == .success else {
                return
            }
            errorMessage = nil
            statusMessage =
                "cURL 원문은 지우고, 재파싱 가능한 redacted cURL만 증거로 추가했습니다."
        } catch {
            if didInvokeMutation {
                let reconciliation =
                    await reconcileDiscoverySessionIgnoringCallerCancellation(
                        sessionID: discovery.id,
                        expectedConnectionID:
                            discovery.pendingConnectionID,
                        expectedOperationGeneration:
                            operationGeneration
                    )
                guard reconciliation != .superseded else {
                    return
                }
                if reconciliation == .success,
                   discoveryContextOwns(
                       sessionID: discovery.id,
                       connectionID:
                           discovery.pendingConnectionID,
                       expectedOperationGeneration:
                           operationGeneration
                   )
                {
                    errorMessage = safeFailureMessage(
                        action: "추가된 cURL 증거의 완료 응답을 검증하지",
                        error: error
                    )
                    statusMessage =
                        "cURL 증거는 추가됐지만 완료 응답을 다시 확인했습니다."
                    return
                }
            }
            guard discoveryContextIsCurrent(
                sessionID: discovery.id,
                connectionID: discovery.pendingConnectionID,
                expectedOperationGeneration: operationGeneration
            ) else {
                return
            }
            errorMessage = safeFailureMessage(
                action: "추가 cURL을 안전하게 검사해 증거로 넣지",
                error: error
            )
        }
    }

    public func runDiscoveryAssistant() async {
        guard let discovery else {
            return
        }
        guard discovery.assistantResumeBoundary?.action
            == .runAssistant
        else {
            errorMessage =
                "Core가 설정 도우미 모델 호출을 실행할 수 있는 재개 경계를 반환하지 않았습니다."
            return
        }
        guard beginOperation() else {
            return
        }
        defer { endOperation() }
        let operationGeneration = discoveryOperationGeneration
        do {
            try await performDiscoveryAssistantTurn(
                snapshot: discovery,
                expectedOperationGeneration:
                    operationGeneration
            )
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            await refreshDiscoveryAfterAssistantFailure(
                sessionID: discovery.id,
                expectedOperationGeneration:
                    operationGeneration
            )
            guard discoveryContextIsCurrent(
                sessionID: discovery.id,
                connectionID: discovery.pendingConnectionID,
                expectedOperationGeneration: operationGeneration
            ) else {
                return
            }
            errorMessage = safeFailureMessage(
                action: "문서 분석용 설정 도우미를 실행하지",
                error: error
            )
        }
    }

    public func resumeDiscoveryAssistantCoreHostAction() async {
        guard let discovery else {
            return
        }
        guard discovery.assistantResumeBoundary?.action
            == .resumeCoreHostAction
        else {
            errorMessage =
                "Core가 재개할 수 있는 설정 도우미 도구 작업이 없습니다."
            return
        }
        guard beginOperation() else {
            return
        }
        defer { endOperation() }
        let operationGeneration = discoveryOperationGeneration
        var didInvokeResume = false
        do {
            didInvokeResume = true
            var resumed: ProviderDiscoverySnapshot
#if DEBUG
            if let
                discoveryAssistantCoreHostResumeInvocationForTesting
            {
                resumed =
                    try await
                        discoveryAssistantCoreHostResumeInvocationForTesting(
                            discovery.id
                        )
            } else {
                resumed =
                    try await client
                        .resumeProviderDiscoveryAssistantCoreHostAction(
                            sessionID: discovery.id
                        )
            }
#else
            resumed =
                try await client
                    .resumeProviderDiscoveryAssistantCoreHostAction(
                        sessionID: discovery.id
                    )
#endif
#if DEBUG
            try await
                discoveryAssistantCoreHostResumeCommitHookForTesting?()
            resumed =
                discoverySnapshotTransformForTesting?(resumed)
                    ?? resumed
#endif
            try validateDiscoverySnapshot(
                resumed,
                expectedConnectionID:
                    discovery.pendingConnectionID,
                expectedSessionID: discovery.id
            )
            let reconciliation =
                await reconcileDiscoverySessionIgnoringCallerCancellation(
                    sessionID: discovery.id,
                    expectedConnectionID:
                        discovery.pendingConnectionID,
                    expectedOperationGeneration:
                        operationGeneration
                )
            guard reconciliation != .superseded else {
                return
            }
            guard reconciliation == .success else {
                if discoveryContextOwns(
                    sessionID: discovery.id,
                    connectionID:
                        discovery.pendingConnectionID,
                    expectedOperationGeneration:
                        operationGeneration
                ) {
                    errorMessage =
                        "Core 설정 도우미 도구 재개 후 durable 상태를 확인하지 못했습니다. 새로고침하세요."
                    statusMessage =
                        "Core 설정 도우미 도구 재개 결과를 다시 확인해야 합니다."
                }
                return
            }
            guard discoveryContextOwns(
                      sessionID: discovery.id,
                      connectionID:
                          discovery.pendingConnectionID,
                      expectedOperationGeneration:
                          operationGeneration
                  ),
                  let durable = self.discovery,
                  durable.revision > discovery.revision
            else {
                return
            }
            guard durable.assistantResumeBoundary?.action
                == .runAssistant
            else {
                throw CoreClientFailure.invalidResponse(
                    "Core 도구 작업을 재개한 뒤 모델 호출 경계가 준비되지 않았습니다."
                )
            }
            guard !Task.isCancelled else {
                statusMessage =
                    "Core 설정 도우미 도구 작업은 재개됐지만 후속 모델 호출은 취소됐습니다."
                return
            }
            try await performDiscoveryAssistantTurn(
                snapshot: durable,
                expectedOperationGeneration:
                    operationGeneration
            )
            errorMessage = nil
        } catch is CancellationError {
            if didInvokeResume {
                let reconciliation =
                    await reconcileDiscoverySessionIgnoringCallerCancellation(
                        sessionID: discovery.id,
                        expectedConnectionID:
                            discovery.pendingConnectionID,
                        expectedOperationGeneration:
                            operationGeneration
                    )
                if reconciliation == .success,
                   discoveryContextOwns(
                       sessionID: discovery.id,
                       connectionID:
                           discovery.pendingConnectionID,
                       expectedOperationGeneration:
                           operationGeneration
                   ),
                   (self.discovery?.revision ?? 0)
                       > discovery.revision
                {
                    statusMessage =
                        "Core 설정 도우미 도구 작업은 재개됐지만 완료 응답 처리가 취소돼 durable 상태를 다시 확인했습니다."
                } else if reconciliation == .failed,
                          discoveryContextOwns(
                              sessionID: discovery.id,
                              connectionID:
                                  discovery.pendingConnectionID,
                              expectedOperationGeneration:
                                  operationGeneration
                          )
                {
                    statusMessage =
                        "Core 설정 도우미 도구 재개 결과를 확인하지 못했습니다. 새로고침하세요."
                }
            }
            return
        } catch {
            if didInvokeResume {
                let reconciliation =
                    await reconcileDiscoverySessionIgnoringCallerCancellation(
                        sessionID: discovery.id,
                        expectedConnectionID:
                            discovery.pendingConnectionID,
                        expectedOperationGeneration:
                            operationGeneration
                    )
                guard reconciliation != .superseded else {
                    return
                }
                if reconciliation == .success,
                   discoveryContextOwns(
                       sessionID: discovery.id,
                       connectionID:
                           discovery.pendingConnectionID,
                       expectedOperationGeneration:
                           operationGeneration
                   ),
                   (self.discovery?.revision ?? 0)
                       > discovery.revision
                {
                    errorMessage = safeFailureMessage(
                        action: "재개된 Core 설정 도우미 도구 작업의 완료 응답을 처리하지",
                        error: error
                    )
                    statusMessage =
                        "Core 설정 도우미 도구 작업은 재개됐지만 완료 응답을 처리하지 못했습니다."
                    return
                }
                if reconciliation == .failed,
                   discoveryContextOwns(
                       sessionID: discovery.id,
                       connectionID:
                           discovery.pendingConnectionID,
                       expectedOperationGeneration:
                           operationGeneration
                   )
                {
                    errorMessage =
                        "Core 설정 도우미 도구 재개 결과를 확인하지 못했습니다. 새로고침하세요."
                    statusMessage =
                        "Core 설정 도우미 도구 재개 결과를 다시 확인해야 합니다."
                    return
                }
            }
            await refreshDiscoveryAfterAssistantFailure(
                sessionID: discovery.id,
                expectedOperationGeneration:
                    operationGeneration
            )
            guard discoveryContextIsCurrent(
                sessionID: discovery.id,
                connectionID: discovery.pendingConnectionID,
                expectedOperationGeneration: operationGeneration
            ) else {
                return
            }
            errorMessage = safeFailureMessage(
                action: "중단된 Core 설정 도우미 도구 작업을 재개하지",
                error: error
            )
        }
    }

    public func acceptDiscoveryAssistantDraft() async {
        guard let discovery, beginOperation() else {
            return
        }
        defer { endOperation() }
        let operationGeneration = discoveryOperationGeneration
        var didInvokeMutation = false
        do {
            didInvokeMutation = true
            var snapshot =
                try await client
                    .acceptProviderDiscoveryAssistantDraft(
                        sessionID: discovery.id
                    )
#if DEBUG
            snapshot =
                discoverySnapshotTransformForTesting?(snapshot)
                    ?? snapshot
#endif
            try validateDiscoverySnapshot(
                snapshot,
                expectedConnectionID:
                    discovery.pendingConnectionID,
                expectedSessionID: discovery.id
            )
            let reconciliation =
                await reconcileDiscoverySessionIgnoringCallerCancellation(
                    sessionID: discovery.id,
                    expectedConnectionID:
                        discovery.pendingConnectionID,
                    expectedOperationGeneration:
                        operationGeneration
                )
            guard reconciliation == .success else {
                return
            }
            errorMessage = nil
            statusMessage =
                "설정 도우미 초안을 채택하고 Core 검증 단계로 이동했습니다."
        } catch {
            if didInvokeMutation {
                let reconciliation =
                    await reconcileDiscoverySessionIgnoringCallerCancellation(
                        sessionID: discovery.id,
                        expectedConnectionID:
                            discovery.pendingConnectionID,
                        expectedOperationGeneration:
                            operationGeneration
                    )
                guard reconciliation != .superseded else {
                    return
                }
                if reconciliation == .success,
                   discoveryContextOwns(
                       sessionID: discovery.id,
                       connectionID:
                           discovery.pendingConnectionID,
                       expectedOperationGeneration:
                           operationGeneration
                   )
                {
                    errorMessage = safeFailureMessage(
                        action: "채택된 설정 도우미 초안의 완료 응답을 검증하지",
                        error: error
                    )
                    statusMessage =
                        "설정 도우미 초안은 채택됐지만 완료 응답을 다시 확인했습니다."
                    return
                }
            }
            guard discoveryContextIsCurrent(
                sessionID: discovery.id,
                connectionID: discovery.pendingConnectionID,
                expectedOperationGeneration: operationGeneration
            ) else {
                return
            }
            errorMessage = safeFailureMessage(
                action: "설정 도우미 초안을 채택하지",
                error: error
            )
        }
    }

    public func requestDiscoveryAssistantRevision() async {
        guard let discovery, beginOperation() else {
            return
        }
        defer { endOperation() }
        let operationGeneration = discoveryOperationGeneration
        var didInvokeMutation = false
        do {
            didInvokeMutation = true
            var snapshot =
                try await client
                    .requestProviderDiscoveryAssistantRevision(
                        sessionID: discovery.id
                    )
#if DEBUG
            snapshot =
                discoverySnapshotTransformForTesting?(snapshot)
                    ?? snapshot
#endif
            try validateDiscoverySnapshot(
                snapshot,
                expectedConnectionID:
                    discovery.pendingConnectionID,
                expectedSessionID: discovery.id
            )
            let reconciliation =
                await reconcileDiscoverySessionIgnoringCallerCancellation(
                    sessionID: discovery.id,
                    expectedConnectionID:
                        discovery.pendingConnectionID,
                    expectedOperationGeneration:
                        operationGeneration
                )
            guard reconciliation == .success else {
                return
            }
            errorMessage = nil
            statusMessage =
                "설정 도우미 수정 요청을 기록했습니다. 추가 모델 호출 한도를 확인한 뒤 재시도를 승인하세요."
        } catch {
            if didInvokeMutation {
                let reconciliation =
                    await reconcileDiscoverySessionIgnoringCallerCancellation(
                        sessionID: discovery.id,
                        expectedConnectionID:
                            discovery.pendingConnectionID,
                        expectedOperationGeneration:
                            operationGeneration
                    )
                guard reconciliation != .superseded else {
                    return
                }
                if reconciliation == .success,
                   discoveryContextOwns(
                       sessionID: discovery.id,
                       connectionID:
                           discovery.pendingConnectionID,
                       expectedOperationGeneration:
                           operationGeneration
                   )
                {
                    errorMessage = safeFailureMessage(
                        action: "기록된 설정 도우미 수정 요청의 완료 응답을 검증하지",
                        error: error
                    )
                    statusMessage =
                        "설정 도우미 수정 요청은 기록됐지만 완료 응답을 다시 확인했습니다."
                    return
                }
            }
            guard discoveryContextIsCurrent(
                sessionID: discovery.id,
                connectionID: discovery.pendingConnectionID,
                expectedOperationGeneration: operationGeneration
            ) else {
                return
            }
            errorMessage = safeFailureMessage(
                action: "설정 도우미 수정을 요청하지",
                error: error
            )
        }
    }

    public func approveDiscoveryAssistantRetry() async {
        guard let discovery else {
            return
        }
        guard discovery.assistantResumeBoundary?.action
            == .approveRetry
        else {
            errorMessage =
                "Core가 승인할 수 있는 설정 도우미 재시도 경계를 반환하지 않았습니다."
            return
        }
        guard beginOperation() else {
            return
        }
        defer { endOperation() }
        let operationGeneration = discoveryOperationGeneration
        var didInvokeRetryApproval = false
        do {
            didInvokeRetryApproval = true
            var retry = try await client
                .approveProviderDiscoveryAssistantRetry(
                    sessionID: discovery.id
                )
#if DEBUG
            try await discoveryAssistantRetryCommitHookForTesting?()
            retry =
                discoverySnapshotTransformForTesting?(retry)
                    ?? retry
#endif
            try validateDiscoverySnapshot(
                retry,
                expectedConnectionID:
                    discovery.pendingConnectionID,
                expectedSessionID: discovery.id
            )
            let reconciliation =
                await reconcileDiscoverySessionIgnoringCallerCancellation(
                    sessionID: discovery.id,
                    expectedConnectionID:
                        discovery.pendingConnectionID,
                    expectedOperationGeneration:
                        operationGeneration
                )
            guard reconciliation != .superseded else {
                return
            }
            guard reconciliation == .success else {
                if discoveryContextOwns(
                    sessionID: discovery.id,
                    connectionID:
                        discovery.pendingConnectionID,
                    expectedOperationGeneration:
                        operationGeneration
                ) {
                    errorMessage =
                        "설정 도우미 재시도 승인 후 durable 상태를 확인하지 못했습니다. 새로고침하세요."
                    statusMessage =
                        "설정 도우미 재시도 승인 결과를 다시 확인해야 합니다."
                }
                return
            }
            guard discoveryContextOwns(
                      sessionID: discovery.id,
                      connectionID:
                          discovery.pendingConnectionID,
                      expectedOperationGeneration:
                          operationGeneration
                  ),
                  let durable = self.discovery,
                  durable.revision > discovery.revision
            else {
                return
            }
            guard durable.assistantResumeBoundary?.action
                == .runAssistant
            else {
                throw CoreClientFailure.invalidResponse(
                    "설정 도우미 재시도 승인 후 모델 호출 경계가 준비되지 않았습니다."
                )
            }
            guard !Task.isCancelled else {
                statusMessage =
                    "설정 도우미 재시도는 승인됐지만 후속 모델 호출은 취소됐습니다."
                return
            }
            try await performDiscoveryAssistantTurn(
                snapshot: durable,
                expectedOperationGeneration:
                    operationGeneration
            )
            errorMessage = nil
        } catch is CancellationError {
            if didInvokeRetryApproval {
                let reconciliation =
                    await reconcileDiscoverySessionIgnoringCallerCancellation(
                        sessionID: discovery.id,
                        expectedConnectionID:
                            discovery.pendingConnectionID,
                        expectedOperationGeneration:
                            operationGeneration
                    )
                if reconciliation == .success,
                   discoveryContextOwns(
                       sessionID: discovery.id,
                       connectionID:
                           discovery.pendingConnectionID,
                       expectedOperationGeneration:
                           operationGeneration
                   ),
                   (self.discovery?.revision ?? 0)
                       > discovery.revision
                {
                    statusMessage =
                        "설정 도우미 재시도는 승인됐지만 완료 응답 처리가 취소돼 durable 상태를 다시 확인했습니다."
                } else if reconciliation == .failed,
                          discoveryContextOwns(
                              sessionID: discovery.id,
                              connectionID:
                                  discovery.pendingConnectionID,
                              expectedOperationGeneration:
                                  operationGeneration
                          )
                {
                    statusMessage =
                        "설정 도우미 재시도 승인 결과를 확인하지 못했습니다. 새로고침하세요."
                }
            }
            return
        } catch {
            if didInvokeRetryApproval {
                let reconciliation =
                    await reconcileDiscoverySessionIgnoringCallerCancellation(
                        sessionID: discovery.id,
                        expectedConnectionID:
                            discovery.pendingConnectionID,
                        expectedOperationGeneration:
                            operationGeneration
                    )
                guard reconciliation != .superseded else {
                    return
                }
                if reconciliation == .success,
                   discoveryContextOwns(
                       sessionID: discovery.id,
                       connectionID:
                           discovery.pendingConnectionID,
                       expectedOperationGeneration:
                           operationGeneration
                   ),
                   (self.discovery?.revision ?? 0)
                       > discovery.revision
                {
                    errorMessage = safeFailureMessage(
                        action: "승인된 설정 도우미 재시도의 완료 응답을 처리하지",
                        error: error
                    )
                    statusMessage =
                        "설정 도우미 재시도는 승인됐지만 완료 응답을 처리하지 못했습니다."
                    return
                }
                if reconciliation == .failed,
                   discoveryContextOwns(
                       sessionID: discovery.id,
                       connectionID:
                           discovery.pendingConnectionID,
                       expectedOperationGeneration:
                           operationGeneration
                   )
                {
                    errorMessage =
                        "설정 도우미 재시도 승인 결과를 확인하지 못했습니다. 새로고침하세요."
                    statusMessage =
                        "설정 도우미 재시도 승인 결과를 다시 확인해야 합니다."
                    return
                }
            }
            await refreshDiscoveryAfterAssistantFailure(
                sessionID: discovery.id,
                expectedOperationGeneration:
                    operationGeneration
            )
            guard discoveryContextIsCurrent(
                sessionID: discovery.id,
                connectionID: discovery.pendingConnectionID,
                expectedOperationGeneration: operationGeneration
            ) else {
                return
            }
            errorMessage = safeFailureMessage(
                action: "설정 도우미 재시도를 승인하지",
                error: error
            )
        }
    }

    public func cancelDiscovery() async {
        guard let discovery, beginOperation() else {
            return
        }
        defer { endOperation() }
        let operationGeneration = discoveryOperationGeneration
        var terminalSnapshot: ProviderDiscoverySnapshot?
        var didInvokeCancellation = false

        do {
            didInvokeCancellation = true
            var snapshot = try await client.cancelProviderDiscovery(
                sessionID: discovery.id,
                expectedRevision: discovery.revision
            )
#if DEBUG
            await discoveryCancellationCommitHookForTesting?()
#endif
#if DEBUG
            snapshot =
                discoverySnapshotTransformForTesting?(snapshot)
                    ?? snapshot
#endif
            try validateDiscoverySnapshot(
                snapshot,
                expectedConnectionID: discovery.pendingConnectionID,
                expectedSessionID: discovery.id
            )
            if snapshot.state.isTerminal {
                terminalSnapshot = snapshot
            }
            let reconciliation =
                await reconcileDiscoverySessionIgnoringCallerCancellation(
                    sessionID: discovery.id,
                    expectedConnectionID:
                        discovery.pendingConnectionID,
                    expectedOperationGeneration:
                        operationGeneration
                )
            guard reconciliation == .success,
                  let snapshot = self.discovery
            else {
                return
            }
            errorMessage = nil
            if snapshot.state.isTerminal {
                credentialDraft = ""
                curlExample = ""
                do {
                    try await clearStagedDiscoveryCredential(
                        expectedDiscoveryOperationGeneration:
                            operationGeneration,
                        expectedConnectionID:
                            discovery.pendingConnectionID
                    )
                    guard discoveryContextOwns(
                        sessionID: snapshot.id,
                        connectionID:
                            snapshot.pendingConnectionID,
                        expectedOperationGeneration:
                            operationGeneration
                    ) else {
                        return
                    }
                    statusMessage = discoveryStatus(snapshot)
                } catch {
                    guard discoveryContextOwns(
                        sessionID: snapshot.id,
                        connectionID:
                            snapshot.pendingConnectionID,
                        expectedOperationGeneration:
                            operationGeneration
                    ) else {
                        return
                    }
                    errorMessage =
                        "탐색은 취소했지만 새 연결의 API 키를 Keychain에서 지우지 못했습니다. 정리를 다시 시도하세요."
                }
            } else {
                statusMessage =
                    "취소 결과가 확정되지 않았습니다. 현재 상태를 확인한 뒤 다시 진행하세요."
            }
        } catch {
            if didInvokeCancellation {
                let reconciliation =
                    await reconcileDiscoverySessionIgnoringCallerCancellation(
                        sessionID: discovery.id,
                        expectedConnectionID:
                            discovery.pendingConnectionID,
                        expectedOperationGeneration:
                            operationGeneration
                    )
                guard reconciliation != .superseded else {
                    return
                }
                if reconciliation == .success,
                   let latest = self.discovery,
                   latest.id == discovery.id
                {
                    terminalSnapshot = latest.state.isTerminal
                        ? latest
                        : terminalSnapshot
                    if latest.state.isTerminal {
                        try? await clearStagedDiscoveryCredential(
                            expectedDiscoveryOperationGeneration:
                                operationGeneration,
                            expectedConnectionID:
                                latest.pendingConnectionID
                        )
                    }
                    guard discoveryContextOwns(
                        sessionID: discovery.id,
                        connectionID:
                            discovery.pendingConnectionID,
                        expectedOperationGeneration:
                            operationGeneration
                    ) else {
                        return
                    }
                    errorMessage = safeFailureMessage(
                        action: "처리된 탐색 취소의 완료 응답을 검증하지",
                        error: error
                    )
                    statusMessage = latest.state.isTerminal
                        ? "탐색은 취소됐지만 완료 응답을 다시 확인했습니다."
                        : "탐색 취소 결과를 다시 확인했습니다."
                    return
                }
            }
            guard discoveryContextIsCurrent(
                sessionID: discovery.id,
                connectionID: discovery.pendingConnectionID,
                expectedOperationGeneration: operationGeneration
            ) else {
                return
            }
            errorMessage = safeFailureMessage(
                action: "프로바이더 탐색을 취소하지",
                error: error
            )
        }
    }

    public func cleanupDiscoveryCredential() async {
        guard beginOperation() else {
            return
        }
        defer { endOperation() }
        do {
            try await clearStagedDiscoveryCredential()
            errorMessage = nil
            statusMessage = "새 연결의 API 키를 Keychain에서 정리했습니다."
        } catch {
            errorMessage =
                "새 연결의 API 키를 Keychain에서 지우지 못했습니다. 다시 시도하세요."
        }
    }

    public func resumeDiscoveryCompensation() async {
        guard let discovery, beginOperation() else {
            return
        }
        defer { endOperation() }
        let operationGeneration = discoveryOperationGeneration
        var didInvokeCompensationResume = false
        do {
            didInvokeCompensationResume = true
            var snapshot =
                try await client
                    .resumeProviderDiscoveryCompensation(
                        sessionID: discovery.id
                    )
#if DEBUG
            try await discoveryCompensationResumeCommitHookForTesting?()
            snapshot =
                discoverySnapshotTransformForTesting?(snapshot)
                    ?? snapshot
#endif
            try validateDiscoverySnapshot(
                snapshot,
                expectedConnectionID:
                    discovery.pendingConnectionID,
                expectedSessionID: discovery.id,
                expectedCommitAttemptID:
                    discovery.commitAttemptID
            )
            let reconciliation =
                await reconcileDiscoverySessionIgnoringCallerCancellation(
                    sessionID: discovery.id,
                    expectedConnectionID:
                        discovery.pendingConnectionID,
                    expectedOperationGeneration:
                        operationGeneration
                )
            guard reconciliation != .superseded else {
                return
            }
            guard reconciliation == .success else {
                if discoveryContextOwns(
                    sessionID: discovery.id,
                    connectionID:
                        discovery.pendingConnectionID,
                    expectedOperationGeneration:
                        operationGeneration
                ) {
                    errorMessage =
                        "프로바이더 저장 보상 재개 후 durable 상태를 확인하지 못했습니다. 새로고침하세요."
                    statusMessage =
                        "프로바이더 저장 보상 재개 결과를 다시 확인해야 합니다."
                }
                return
            }
            guard discoveryContextOwns(
                      sessionID: discovery.id,
                      connectionID:
                          discovery.pendingConnectionID,
                      expectedOperationGeneration:
                          operationGeneration
                  ),
                  let durable = self.discovery
            else {
                return
            }
            guard !Task.isCancelled else {
                statusMessage =
                    "프로바이더 저장 보상은 재개됐지만 후속 처리가 취소돼 durable 상태를 다시 확인했습니다."
                return
            }
            let completed =
                try await performDiscoveryCompensation(
                    startingFrom: durable,
                    expectedOperationGeneration:
                        operationGeneration
                )
            guard applyDiscoverySnapshot(
                completed,
                expectedSessionID: discovery.id,
                expectedConnectionID:
                    discovery.pendingConnectionID,
                expectedOperationGeneration: operationGeneration,
                ignoresTaskCancellation: true
            ) else {
                return
            }
            errorMessage = nil
            statusMessage =
                completed.state == .failed
                ? "저장 실패 후 연결 graph와 Keychain 정리를 완료했습니다."
                : discoveryStatus(completed)
        } catch is CancellationError {
            if didInvokeCompensationResume {
                let reconciliation =
                    await reconcileDiscoverySessionIgnoringCallerCancellation(
                        sessionID: discovery.id,
                        expectedConnectionID:
                            discovery.pendingConnectionID,
                        expectedOperationGeneration:
                            operationGeneration
                    )
                if reconciliation == .success,
                   discoveryContextOwns(
                       sessionID: discovery.id,
                       connectionID:
                           discovery.pendingConnectionID,
                       expectedOperationGeneration:
                           operationGeneration
                   )
                {
                    statusMessage =
                        "프로바이더 저장 보상 재개 후 취소돼 durable 상태를 다시 확인했습니다."
                } else if reconciliation == .failed,
                          discoveryContextOwns(
                              sessionID: discovery.id,
                              connectionID:
                                  discovery.pendingConnectionID,
                              expectedOperationGeneration:
                                  operationGeneration
                          )
                {
                    statusMessage =
                        "프로바이더 저장 보상 재개 결과를 확인하지 못했습니다. 새로고침하세요."
                }
            }
            return
        } catch {
            if didInvokeCompensationResume {
                let reconciliation =
                    await reconcileDiscoverySessionIgnoringCallerCancellation(
                        sessionID: discovery.id,
                        expectedConnectionID:
                            discovery.pendingConnectionID,
                        expectedOperationGeneration:
                            operationGeneration
                    )
                guard reconciliation != .superseded else {
                    return
                }
                if reconciliation == .success,
                   discoveryContextOwns(
                       sessionID: discovery.id,
                       connectionID:
                           discovery.pendingConnectionID,
                       expectedOperationGeneration:
                           operationGeneration
                   )
                {
                    errorMessage = safeFailureMessage(
                        action: "재개된 프로바이더 저장 보상의 완료 응답을 처리하지",
                        error: error
                    )
                    statusMessage =
                        "프로바이더 저장 보상은 재개됐지만 완료 응답을 처리하지 못했습니다."
                    return
                }
                if reconciliation == .failed,
                   discoveryContextOwns(
                       sessionID: discovery.id,
                       connectionID:
                           discovery.pendingConnectionID,
                       expectedOperationGeneration:
                           operationGeneration
                   )
                {
                    errorMessage =
                        "프로바이더 저장 보상 재개 결과를 확인하지 못했습니다. 새로고침하세요."
                    statusMessage =
                        "프로바이더 저장 보상 재개 결과를 다시 확인해야 합니다."
                    return
                }
            }
            guard discoveryContextIsCurrent(
                sessionID: discovery.id,
                connectionID: discovery.pendingConnectionID,
                expectedOperationGeneration: operationGeneration
            ) else {
                return
            }
            errorMessage = safeFailureMessage(
                action: "프로바이더 저장 보상을 재개하지",
                error: error
            )
        }
    }

    public func commitDiscovery() async {
        guard let discovery,
              discovery.state == .awaitingReview,
              let proposal = discovery.reviewProposal,
              beginOperation()
        else {
            return
        }
        defer { endOperation() }
        let operationGeneration = discoveryOperationGeneration
        let hierarchyOwner = connectionHierarchyOwner()
        var didInvokeCommit = false

        do {
            let action = ProviderDiscoveryAction.approveReview(
                approvalID: proposal.approvalID,
                commitAttemptID: proposal.commitAttemptID,
                commitPlanSHA256: proposal.commitPlanSHA256,
                graphSHA256: proposal.review.graphSHA256
            )
            let actionID = UUID().uuidString.lowercased()
            let envelope = try await client.prepareProviderDiscoveryAction(
                actionID: actionID,
                expectedRevision: discovery.revision,
                action: action
            )
            guard envelope.actionID == actionID,
                  envelope.expectedRevision == discovery.revision,
                  envelope.action == action,
                  !envelope.requestSHA256.isEmpty
            else {
                throw CoreClientFailure.invalidResponse(
                    "Rust가 준비한 최종 승인 봉투가 검토 내용과 일치하지 않습니다."
                )
            }
            guard discoveryContextIsCurrent(
                sessionID: discovery.id,
                connectionID: discovery.pendingConnectionID,
                expectedOperationGeneration: operationGeneration,
                expectedRevision: discovery.revision
            ) else {
                return
            }
            var approved = try await client.continueProviderDiscovery(
                sessionID: discovery.id,
                envelope: envelope,
                targetCredential: nil
            )
#if DEBUG
            approved =
                discoverySnapshotTransformForTesting?(approved)
                    ?? approved
#endif
            try validateDiscoverySnapshot(
                approved,
                expectedConnectionID: discovery.pendingConnectionID,
                expectedSessionID: discovery.id,
                expectedCommitAttemptID:
                    proposal.commitAttemptID
            )
            guard applyDiscoverySnapshot(
                approved,
                expectedSessionID: discovery.id,
                expectedConnectionID:
                    discovery.pendingConnectionID,
                expectedOperationGeneration: operationGeneration
            ) else {
                return
            }

            let credentialSlotConfirmed =
                try await credentialSlotIsReady(for: approved)
            guard discoveryContextIsCurrent(
                sessionID: approved.id,
                connectionID: approved.pendingConnectionID,
                expectedOperationGeneration: operationGeneration
            ) else {
                return
            }
            didInvokeCommit = true
            var connection = try await client.commitProviderDiscovery(
                sessionID: approved.id,
                credentialSlotConfirmed: credentialSlotConfirmed
            )
#if DEBUG
            connection =
                discoveryConnectionTransformForTesting?(connection)
                    ?? connection
            try await discoveryPostCommitSnapshotHookForTesting?()
#endif
            let responseWasExact =
                connection.id == approved.pendingConnectionID
                    && connection.hasCredential
                        == approved.credentialSlotExpected
            let reconciliation =
                await reconcileDiscoveryAfterCommit(
                    sessionID: approved.id,
                    expectedConnectionID:
                        approved.pendingConnectionID,
                    expectedCommitAttemptID:
                        proposal.commitAttemptID,
                    expectedOperationGeneration:
                        operationGeneration,
                    hierarchyOwner: hierarchyOwner
                )
            switch reconciliation {
            case let .ready(refreshOutcome):
                guard refreshOutcome != .superseded else {
                    return
                }
                if !responseWasExact {
                    if refreshOutcome == .success {
                        errorMessage =
                            "연결은 저장됐지만 Core 응답의 연결 정보가 검토 내용과 달라 durable 상태를 다시 확인했습니다."
                        statusMessage =
                            "연결은 저장됐으며 저장된 연결 상태를 다시 확인했습니다."
                    } else {
                        errorMessage =
                            "연결은 저장됐지만 Core 응답의 연결 정보가 검토 내용과 다르고 프로바이더 상태 새로고침에도 실패했습니다."
                        statusMessage =
                            "연결은 저장됐지만 프로바이더 상태를 새로고침하지 못했습니다."
                    }
                } else if refreshOutcome == .failed {
                    errorMessage =
                        "연결과 모델은 저장했지만 프로바이더 상태를 새로고침하지 못했습니다. 새로고침하세요."
                    statusMessage =
                        "연결과 모델은 저장했지만 프로바이더 상태 새로고침에 실패했습니다."
                } else {
                    errorMessage = nil
                    statusMessage = "연결과 모델을 저장했습니다."
                }
            case .compensating:
                errorMessage =
                    "연결 저장을 완료하지 못해 안전한 보상 절차를 진행했습니다."
                statusMessage =
                    "연결 저장 실패 후 보상 상태를 다시 확인했습니다."
            case .notCommitted:
                errorMessage =
                    "프로바이더 연결이 저장되지 않았습니다. 검토 상태를 확인하고 다시 시도하세요."
                statusMessage =
                    "프로바이더 연결은 저장되지 않았으며 검토 상태로 남아 있습니다."
            case .unresolved:
                errorMessage =
                    "연결 저장 결과를 확정할 수 없어 해당 연결을 격리했습니다. 상태를 새로고침하세요."
                statusMessage =
                    "연결 저장 결과를 다시 확인해야 합니다."
            }
        } catch is CancellationError {
            if didInvokeCommit {
                let reconciliation =
                    await reconcileDiscoveryAfterCommit(
                        sessionID: discovery.id,
                        expectedConnectionID:
                            discovery.pendingConnectionID,
                        expectedCommitAttemptID:
                            proposal.commitAttemptID,
                        expectedOperationGeneration:
                            operationGeneration,
                        hierarchyOwner: hierarchyOwner
                    )
                switch reconciliation {
                case let .ready(refreshOutcome):
                    guard refreshOutcome != .superseded else {
                        return
                    }
                    if refreshOutcome == .success {
                        errorMessage = nil
                        statusMessage =
                            "연결과 모델을 저장했습니다."
                    } else {
                        errorMessage =
                            "연결과 모델은 저장했지만 프로바이더 상태를 새로고침하지 못했습니다. 새로고침하세요."
                        statusMessage =
                            "연결과 모델은 저장했지만 프로바이더 상태 새로고침에 실패했습니다."
                    }
                case .compensating:
                    errorMessage =
                        "연결 저장 실패 후 안전한 보상 절차를 진행했습니다."
                    statusMessage =
                        "연결 저장 보상 상태를 다시 확인했습니다."
                case .notCommitted:
                    errorMessage =
                        "프로바이더 연결 저장이 취소되어 검토 상태를 유지합니다."
                    statusMessage =
                        "프로바이더 연결은 아직 검토 상태이며 저장되지 않았습니다."
                case .unresolved:
                    errorMessage =
                        "연결 저장 결과를 확정할 수 없어 해당 연결을 격리했습니다. 상태를 새로고침하세요."
                    statusMessage =
                        "연결 저장 결과를 다시 확인해야 합니다."
                }
            }
            return
        } catch {
            if didInvokeCommit {
                let reconciliation =
                    await reconcileDiscoveryAfterCommit(
                        sessionID: discovery.id,
                        expectedConnectionID:
                            discovery.pendingConnectionID,
                        expectedCommitAttemptID:
                            proposal.commitAttemptID,
                        expectedOperationGeneration:
                            operationGeneration,
                        hierarchyOwner: hierarchyOwner
                    )
                switch reconciliation {
                case let .ready(refreshOutcome):
                    guard refreshOutcome != .superseded else {
                        return
                    }
                    if refreshOutcome == .success {
                        errorMessage =
                            "연결은 저장됐지만 저장 완료 응답을 처리하는 중 문제가 발생해 durable 상태를 다시 확인했습니다."
                        statusMessage =
                            "연결과 모델은 저장됐지만 저장 완료 응답을 처리하지 못했습니다."
                    } else {
                        errorMessage =
                            "연결은 저장됐지만 저장 완료 응답 처리와 프로바이더 상태 새로고침에 실패했습니다."
                        statusMessage =
                            "연결은 저장됐지만 완료 응답과 프로바이더 상태를 확인하지 못했습니다."
                    }
                case .compensating:
                    errorMessage =
                        "연결 저장 실패 후 안전한 보상 절차를 진행했습니다."
                    statusMessage =
                        "연결 저장 실패 후 보상 상태를 다시 확인했습니다."
                case .notCommitted:
                    errorMessage = safeFailureMessage(
                        action: "검토한 프로바이더 연결을 저장하지",
                        error: error
                    )
                    statusMessage =
                        "프로바이더 연결은 저장되지 않았으며 검토 상태로 남아 있습니다."
                case .unresolved:
                    errorMessage =
                        "연결 저장 결과를 확정할 수 없어 해당 연결을 격리했습니다. 상태를 새로고침하세요."
                    statusMessage =
                        "연결 저장 결과를 다시 확인해야 합니다."
                }
                return
            }
            if var latest = try? await client.getProviderDiscovery(
                sessionID: discovery.id
            )
            {
                #if DEBUG
                latest =
                    discoverySnapshotTransformForTesting?(latest)
                        ?? latest
                #endif
                if (try? validateDiscoverySnapshot(
                    latest,
                    expectedConnectionID:
                        discovery.pendingConnectionID,
                    expectedSessionID: discovery.id,
                    expectedCommitAttemptID:
                        proposal.commitAttemptID
                )) != nil,
                    latest.state == .compensating,
                    applyDiscoverySnapshot(
                        latest,
                        expectedSessionID: discovery.id,
                        expectedConnectionID:
                            discovery.pendingConnectionID,
                        expectedOperationGeneration:
                            operationGeneration
                    )
                {
                    _ = try? await performDiscoveryCompensation(
                        startingFrom: latest,
                        expectedOperationGeneration:
                            operationGeneration
                    )
                }
            }
            guard discoveryContextIsCurrent(
                sessionID: discovery.id,
                connectionID: discovery.pendingConnectionID,
                expectedOperationGeneration: operationGeneration
            ) else {
                return
            }
            errorMessage = safeFailureMessage(
                action: "검토한 프로바이더 연결을 저장하지",
                error: error
            )
        }
    }

    private func reconcileDiscoveryAfterCommit(
        sessionID: String,
        expectedConnectionID: String,
        expectedCommitAttemptID: String,
        expectedOperationGeneration: UInt64,
        hierarchyOwner: ConnectionHierarchyOwner
    ) async -> DiscoveryCommitReconciliationOutcome {
        await Task { @MainActor [weak self] in
            guard let self else {
                return .unresolved
            }
            return await self.performDiscoveryPostCommitReconciliation(
                sessionID: sessionID,
                expectedConnectionID: expectedConnectionID,
                expectedCommitAttemptID:
                    expectedCommitAttemptID,
                expectedOperationGeneration:
                    expectedOperationGeneration,
                hierarchyOwner: hierarchyOwner
            )
        }.value
    }

    private func performDiscoveryPostCommitReconciliation(
        sessionID: String,
        expectedConnectionID: String,
        expectedCommitAttemptID: String,
        expectedOperationGeneration: UInt64,
        hierarchyOwner: ConnectionHierarchyOwner
    ) async -> DiscoveryCommitReconciliationOutcome {
        providerConfigurationStore.beginMutation(
            profileID: expectedConnectionID
        )
        defer {
            providerConfigurationStore.endMutation(
                profileID: expectedConnectionID
            )
        }
        do {
            var latest = try await client.getProviderDiscovery(
                sessionID: sessionID
            )
#if DEBUG
            latest =
                discoverySnapshotTransformForTesting?(latest)
                    ?? latest
#endif
            try validateDiscoverySnapshot(
                latest,
                expectedConnectionID: expectedConnectionID,
                expectedSessionID: sessionID,
                expectedCommitAttemptID:
                    expectedCommitAttemptID
            )
            _ = applyDiscoverySnapshot(
                latest,
                expectedSessionID: sessionID,
                expectedConnectionID: expectedConnectionID,
                expectedOperationGeneration:
                    expectedOperationGeneration,
                ignoresTaskCancellation: true
            )

            switch latest.state {
            case .ready:
                guard latest.committedConnectionID
                    == expectedConnectionID
                else {
                    throw CoreClientFailure.invalidResponse(
                        "저장 완료 탐색이 검토한 연결 ID와 일치하지 않습니다."
                    )
                }
                hasStagedDiscoveryCredential = false
                stagedDiscoveryConnectionID = nil
                stopDiscoveryMonitor()
                providerConfigurationStore.clearQuarantine(
                    profileID: expectedConnectionID
                )
                let refreshed = await performRefreshAfterMutation(
                    selecting: expectedConnectionID,
                    owner: hierarchyOwner
                )
                return .ready(refreshed)
            case .compensating:
                do {
                    latest = try await performDiscoveryCompensation(
                        startingFrom: latest,
                        expectedOperationGeneration:
                            expectedOperationGeneration
                    )
                    _ = applyDiscoverySnapshot(
                        latest,
                        expectedSessionID: sessionID,
                        expectedConnectionID:
                            expectedConnectionID,
                        expectedOperationGeneration:
                            expectedOperationGeneration,
                        ignoresTaskCancellation: true
                    )
                    return .compensating
                } catch {
                    hasStagedDiscoveryCredential = false
                    stagedDiscoveryConnectionID = nil
                    providerConfigurationStore.quarantine(
                        profileID: expectedConnectionID
                    )
                    return .unresolved
                }
            case .awaitingReview:
                return .notCommitted
            default:
                // The commit call may have changed durable state even when
                // the exact outcome is not yet knowable. Relinquish native
                // cleanup ownership so UI cannot delete a credential that
                // may now belong to a live connection.
                hasStagedDiscoveryCredential = false
                stagedDiscoveryConnectionID = nil
                providerConfigurationStore.quarantine(
                    profileID: expectedConnectionID
                )
                return .unresolved
            }
        } catch {
            hasStagedDiscoveryCredential = false
            stagedDiscoveryConnectionID = nil
            providerConfigurationStore.quarantine(
                profileID: expectedConnectionID
            )
            return .unresolved
        }
    }

    public func selectConnection(id: String) async {
        let generation = refreshGeneration
        _ = await selectConnection(
            id: id,
            expectedRefreshGeneration: generation,
            preferredModelRouteID: selectedModelRouteID
        )
    }

    @discardableResult
    private func selectConnection(
        id: String,
        expectedRefreshGeneration: UInt64?,
        preferredModelRouteID: String? = nil
    ) async -> MutationRefreshOutcome {
        guard refreshGenerationIsCurrent(
            expectedRefreshGeneration
        ) else {
            return .superseded
        }
        connectionSelectionGeneration &+= 1
        let selectionGeneration = connectionSelectionGeneration
        selectedConnectionID = id
        invalidateConnectionHierarchy()
        isSelectionLoading = true

        do {
            let routes = try await client.listProviderModelRoutes(
                connectionID: id
            )
#if DEBUG
            try await connectionHydrationFailureHookForTesting?()
            await connectionHydrationCommitHookForTesting?()
#endif
            if Task.isCancelled {
                if selectedConnectionID == id,
                   selectionGeneration
                       == connectionSelectionGeneration,
                   refreshGenerationIsCurrent(
                       expectedRefreshGeneration
                   )
                {
                    isSelectionLoading = false
                }
                return .superseded
            }
            guard selectedConnectionID == id,
                  selectionGeneration
                    == connectionSelectionGeneration,
                  refreshGenerationIsCurrent(
                      expectedRefreshGeneration
                  )
            else {
                return .superseded
            }
            try validateModelRoutes(
                routes,
                expectedConnectionID: id
            )
            modelRoutes = routes.sorted {
                $0.title.localizedStandardCompare($1.title)
                    == .orderedAscending
            }
            replaceAssistantModelRoutes(
                for: id,
                with: modelRoutes
            )
            if let activeGenerationTarget,
               modelRoutes.contains(where: {
                   $0.id == activeGenerationTarget.modelRouteID
               })
            {
                activeGenerationConnectionID = id
            }
            let routeID = modelRoutes.contains(where: {
                $0.id == preferredModelRouteID
            }) ? preferredModelRouteID : modelRoutes.first?.id
            if let routeID {
                let routeHydrated = await selectModelRoute(
                    id: routeID,
                    expectedRefreshGeneration:
                        expectedRefreshGeneration
                )
                guard routeHydrated else {
                    if selectedConnectionID == id,
                       selectionGeneration
                           == connectionSelectionGeneration,
                       refreshGenerationIsCurrent(
                           expectedRefreshGeneration
                       )
                    {
                        isSelectionLoading = false
                    }
                    return Task.isCancelled
                        || selectedConnectionID != id
                        || selectionGeneration
                            != connectionSelectionGeneration
                        || !refreshGenerationIsCurrent(
                            expectedRefreshGeneration
                        )
                        ? .superseded
                        : .failed
                }
            }
            guard !Task.isCancelled,
                  selectedConnectionID == id,
                  selectionGeneration
                    == connectionSelectionGeneration,
                  refreshGenerationIsCurrent(
                      expectedRefreshGeneration
                  )
            else {
                return .superseded
            }
            isSelectionLoading = false
            let restoreOutcome = await restoreModelSync(
                for: id,
                expectedConnectionSelectionGeneration:
                    selectionGeneration,
                expectedRefreshGeneration:
                    expectedRefreshGeneration
            )
            guard !Task.isCancelled,
                  selectedConnectionID == id,
                  selectionGeneration
                    == connectionSelectionGeneration,
                  refreshGenerationIsCurrent(
                      expectedRefreshGeneration
                  )
            else {
                return .superseded
            }
            guard restoreOutcome != .superseded else {
                return .superseded
            }
            guard restoreOutcome == .success else {
                return .failed
            }
            publishConfigurationSnapshotIfResolved()
            return .success
        } catch is CancellationError {
            if selectedConnectionID == id,
               selectionGeneration == connectionSelectionGeneration,
               refreshGenerationIsCurrent(
                   expectedRefreshGeneration
               )
            {
                isSelectionLoading = false
            }
            return .superseded
        } catch {
            if Task.isCancelled {
                if selectedConnectionID == id,
                   selectionGeneration
                       == connectionSelectionGeneration,
                   refreshGenerationIsCurrent(
                       expectedRefreshGeneration
                   )
                {
                    isSelectionLoading = false
                }
                return .superseded
            }
            guard selectedConnectionID == id,
                  selectionGeneration
                    == connectionSelectionGeneration,
                  refreshGenerationIsCurrent(
                      expectedRefreshGeneration
                  )
            else {
                return .superseded
            }
            isSelectionLoading = false
            errorMessage = safeFailureMessage(
                action: "모델 목록을 불러오지",
                error: error
            )
            return .failed
        }
    }

    private func selectConnectionIgnoringCallerCancellation(
        id: String,
        expectedRefreshGeneration: UInt64?,
        owner: ConnectionHierarchyOwner,
        expectedModelRouteSelectionGeneration: UInt64? = nil,
        expectedSelectedModelRouteID: String? = nil,
        expectedModelSyncOperationGeneration: UInt64? = nil,
        preferredModelRouteID: String? = nil
    ) async -> ConnectionHydrationResult {
        await Task { @MainActor [weak self] in
            guard let self else {
                return ConnectionHydrationResult(
                    outcome: .failed,
                    owner: nil
                )
            }
#if DEBUG
            await self
                .cancellationIndependentSelectionStartHookForTesting?()
#endif
            guard self.connectionHierarchyOwnerIsCurrent(owner)
            else {
                return self.connectionHydrationResult(.superseded)
            }
            if let expectedModelRouteSelectionGeneration,
               self.modelRouteSelectionGeneration
                   != expectedModelRouteSelectionGeneration
            {
                return self.connectionHydrationResult(.superseded)
            }
            if let expectedSelectedModelRouteID,
               self.selectedModelRouteID
                   != expectedSelectedModelRouteID
            {
                return self.connectionHydrationResult(.superseded)
            }
            if let expectedModelSyncOperationGeneration,
               self.modelSyncOperationGeneration
                   != expectedModelSyncOperationGeneration
            {
                return self.connectionHydrationResult(.superseded)
            }
            let outcome = await self.selectConnection(
                id: id,
                expectedRefreshGeneration:
                    expectedRefreshGeneration,
                preferredModelRouteID:
                    preferredModelRouteID
            )
            return self.connectionHydrationResult(outcome)
        }.value
    }

    public func selectModelRoute(id: String) async {
        let generation = refreshGeneration
        _ = await selectModelRoute(
            id: id,
            expectedRefreshGeneration: generation
        )
    }

    @discardableResult
    private func selectModelRoute(
        id: String,
        expectedRefreshGeneration: UInt64?
    ) async -> Bool {
        guard refreshGenerationIsCurrent(
            expectedRefreshGeneration
        ), let connection = selectedConnection,
           let route = modelRoutes.first(where: {
               $0.id == id && $0.connectionID == connection.id
           })
        else {
            return false
        }
        let parentConnectionID = connection.id
        let parentSelectionGeneration =
            connectionSelectionGeneration
        modelRouteSelectionGeneration &+= 1
        let selectionGeneration = modelRouteSelectionGeneration
        selectedModelRouteID = route.id
        invalidateModelRouteHierarchy()
        isSelectionLoading = true
        do {
            async let loadedPresets =
                client.listProviderGenerationPresets(
                    modelRouteID: route.id
                )
            async let loadedCapabilities =
                client.listProviderCapabilities(modelRouteID: route.id)
            let (newPresets, newCapabilities) = try await (
                loadedPresets,
                loadedCapabilities
            )
            let newParameterSpecs =
                try? await client.listProviderParameterSpecs(
                    modelRouteID: route.id
                )
#if DEBUG
            await modelRouteHydrationCommitHookForTesting?()
#endif
            if Task.isCancelled {
                if selectedConnectionID == parentConnectionID,
                   parentSelectionGeneration
                       == connectionSelectionGeneration,
                   selectedModelRouteID == route.id,
                   selectionGeneration
                       == modelRouteSelectionGeneration,
                   refreshGenerationIsCurrent(
                       expectedRefreshGeneration
                   )
                {
                    isSelectionLoading = false
                }
                return false
            }
            guard selectedConnectionID == parentConnectionID,
                  parentSelectionGeneration
                    == connectionSelectionGeneration,
                  selectedModelRouteID == route.id,
                  selectionGeneration
                    == modelRouteSelectionGeneration,
                  refreshGenerationIsCurrent(
                      expectedRefreshGeneration
                  )
            else {
                return false
            }
            try validateGenerationPresets(
                newPresets,
                expectedModelRouteID: route.id
            )
            presets = newPresets.sorted {
                $0.displayName.localizedStandardCompare($1.displayName)
                    == .orderedAscending
            }
            capabilities = newCapabilities.sorted {
                $0.selected.key.localizedStandardCompare($1.selected.key)
                    == .orderedAscending
            }
            routeParameterSpecs = newParameterSpecs
            if !presets.contains(where: { $0.id == selectedPresetID }) {
                selectedPresetID = presets.first?.id
            }
            isSelectionLoading = false
            if let preset = selectedPreset {
                editPreset(preset)
                await loadRequestPreview()
            } else {
                beginNewPreset()
                await refreshPresetControls()
            }
            guard !Task.isCancelled,
                  selectedConnectionID == parentConnectionID,
                  parentSelectionGeneration
                    == connectionSelectionGeneration,
                  selectedModelRouteID == route.id,
                  selectionGeneration
                    == modelRouteSelectionGeneration,
                  refreshGenerationIsCurrent(
                      expectedRefreshGeneration
                  )
            else {
                return false
            }
            isSelectionLoading = false
            errorMessage = nil
            return true
        } catch is CancellationError {
            if selectedConnectionID == parentConnectionID,
               parentSelectionGeneration
                   == connectionSelectionGeneration,
               selectedModelRouteID == route.id,
               selectionGeneration == modelRouteSelectionGeneration,
               refreshGenerationIsCurrent(
                   expectedRefreshGeneration
               )
            {
                isSelectionLoading = false
            }
            return false
        } catch {
            if Task.isCancelled {
                if selectedConnectionID == parentConnectionID,
                   parentSelectionGeneration
                       == connectionSelectionGeneration,
                   selectedModelRouteID == route.id,
                   selectionGeneration
                       == modelRouteSelectionGeneration,
                   refreshGenerationIsCurrent(
                       expectedRefreshGeneration
                   )
                {
                    isSelectionLoading = false
                }
                return false
            }
            guard selectedConnectionID == parentConnectionID,
                  parentSelectionGeneration
                    == connectionSelectionGeneration,
                  selectedModelRouteID == route.id,
                  selectionGeneration
                    == modelRouteSelectionGeneration,
                  refreshGenerationIsCurrent(
                      expectedRefreshGeneration
                  )
            else {
                return false
            }
            isSelectionLoading = false
            errorMessage = safeFailureMessage(
                action: "모델 기능과 프리셋을 불러오지",
                error: error
            )
            return false
        }
    }

    public func selectPreset(id: String) async {
        guard !isSelectionLoading,
              let connection = selectedConnection,
              let route = selectedModelRoute,
              route.connectionID == connection.id,
              let preset = presets.first(where: {
                  $0.id == id && $0.modelRouteID == route.id
              })
        else {
            return
        }
        selectedPresetID = id
        editPreset(preset)
        await loadRequestPreview()
    }

    public func useSelectedPresetAsAppDefault() async {
        guard !isSelectionLoading,
              let connection = selectedConnection,
              let route = selectedModelRoute,
              route.connectionID == connection.id,
              let preset = selectedPreset,
              preset.modelRouteID == route.id,
              beginOperation()
        else {
            return
        }
        defer { endOperation() }
        let context = selectionContext(
            connectionID: connection.id,
            modelRouteID: route.id,
            presetID: preset.id
        )
        let routeTitle = route.title
        let presetDisplayName = preset.displayName

        let target = ProviderGenerationTarget(
            modelRouteID: route.id,
            generationPresetID: preset.id
        )
        do {
            var settings = try await client
                .selectProviderGenerationTarget(target)
#if DEBUG
            await defaultSelectionCommitHookForTesting?()
            settings =
                defaultSelectionResultTransformForTesting?(settings)
                    ?? settings
#endif
            let responseWasExact =
                settings.selectedGenerationTarget == target
            let reconciliation =
                await reconcileActiveGenerationSelectionAfterCommittedMutation(
                    expectedRefreshGeneration:
                        context.refreshGeneration
                )
            guard selectionContextOwnsHierarchy(context),
                  reconciliation != .superseded
            else {
                return
            }
            guard responseWasExact else {
                errorMessage =
                    "기본 모델 변경은 처리됐지만 Core 응답이 요청과 달라 현재 설정을 다시 확인했습니다."
                statusMessage = reconciliation == .success
                    ? "현재 앱 기본 모델 설정을 다시 확인했습니다."
                    : "앱 기본 모델 설정을 다시 확인하지 못했습니다. 새로고침하세요."
                return
            }
            guard reconciliation == .success,
                  activeGenerationTarget == target,
                  activeGenerationConnectionID == connection.id,
                  selectedGenerationHierarchyIsValid
            else {
                errorMessage =
                    "기본 모델 변경 결과가 다른 최신 설정으로 대체됐거나 현재 상태를 확인하지 못했습니다."
                statusMessage =
                    "현재 앱 기본 모델 설정을 유지합니다."
                return
            }
            errorMessage = nil
            statusMessage =
                "‘\(routeTitle)’ · ‘\(presetDisplayName)’을 앱 기본 모델로 선택했습니다."
        } catch {
            let reconciliation =
                await reconcileActiveGenerationSelectionAfterCommittedMutation(
                    expectedRefreshGeneration:
                        context.refreshGeneration
                )
            guard selectionContextOwnsHierarchy(context),
                  reconciliation != .superseded
            else {
                return
            }
            if activeGenerationTarget == target,
               activeGenerationConnectionID == connection.id
            {
                errorMessage =
                    "기본 모델은 변경됐지만 완료 응답을 처리하지 못해 현재 설정을 다시 확인했습니다."
                statusMessage =
                    "선택한 프리셋이 앱 기본 모델로 저장됐습니다."
                return
            }
            errorMessage = safeFailureMessage(
                action: "앱 기본 모델을 변경하지",
                error: error
            )
        }
    }

    public func beginNewPreset() {
        guard !isSelectionLoading,
              let connection = selectedConnection,
              let route = selectedModelRoute,
              route.connectionID == connection.id
        else {
            return
        }
        invalidateRequestPreview()
        selectedPresetID = nil
        draftPresetID = UUID().uuidString.lowercased()
        draftPresetCreatedAt =
            ISO8601DateFormatter().string(from: Date())
        presetName = "새 프리셋"
        parameterValues = Dictionary(
            uniqueKeysWithValues: visibleParameterSpecs.map {
                ($0.id, defaultValueState(for: $0))
            }
        )
        reasoningMode = "provider_default"
        reasoningEffort = ""
        reasoningBudgetTokens = ""
        reasoningSummary = "provider_default"
        preservesOpaqueReasoningState = false
        promptCacheMode = "provider_default"
        promptCacheTTL = "provider_default"
        promptCacheCustomTTLSeconds = ""
        promptCacheContextReference = ""
        clearRenderedPresetControls()
        schedulePresetControlRefresh()
        statusMessage = "‘\(route.title)’에 사용할 새 프리셋을 편집합니다."
    }

    public func setParameterUsesProviderDefault(
        id: String,
        usesDefault: Bool
    ) {
        guard let spec = visibleParameterSpecs.first(where: {
            $0.id == id
        }) else {
            return
        }
        parameterValues[id] = usesDefault
            ? .providerDefault
            : initialExplicitValue(for: spec)
        normalizeHiddenParameterValues()
        schedulePresetControlRefresh()
    }

    public func setParameterLiteral(
        id: String,
        literal: ProviderParameterLiteral
    ) {
        parameterValues[id] = .explicit(literal)
        normalizeHiddenParameterValues()
        schedulePresetControlRefresh()
    }

    public func setReasoningMode(_ mode: String) {
        reasoningMode = mode
        guard mode == "provider_default" else {
            return
        }
        reasoningEffort = ""
        reasoningBudgetTokens = ""
        reasoningSummary = "provider_default"
    }

    public func refreshPresetControls(
        reportingFailure: Bool = false
    ) async {
        presetControlRefreshTask?.cancel()
        presetControlRefreshTask = nil
        await performPresetControlRefresh(
            reportingFailure: reportingFailure,
            remainingCanonicalizationPasses: 1
        )
    }

    private func performPresetControlRefresh(
        reportingFailure: Bool,
        remainingCanonicalizationPasses: Int
    ) async {
        guard !Task.isCancelled else {
            return
        }
        normalizeOpaqueReasoningContinuityForSelectedConnection()
        presetControlRenderGeneration &+= 1
        let generation = presetControlRenderGeneration
        let renderedAt = ISO8601DateFormatter().string(from: Date())
        guard let candidate = makePresetCandidate(
            updatedAt: renderedAt
        ) else {
            guard generation == presetControlRenderGeneration else {
                return
            }
            reasoningControl = nil
            promptCacheControl = nil
            renderedPresetControlCandidate = nil
            return
        }

        do {
            async let loadedReasoning =
                client.renderProviderReasoningControl(for: candidate)
            async let loadedCache =
                client.renderProviderPromptCacheControl(for: candidate)
            let (newReasoning, newCache) = try await (
                loadedReasoning,
                loadedCache
            )
            guard !Task.isCancelled,
                  generation == presetControlRenderGeneration,
                  makePresetCandidate(updatedAt: renderedAt)
                    == candidate
            else {
                return
            }
            let canonicalOpaqueReasoningState =
                selectedConnection?.hasCredential == true
                    ? false
                    : newReasoning.preservesOpaqueState
            let canonicalEffort = canonicalRenderedEnabledEffort(
                from: newReasoning,
                for: candidate
            )
            if preservesOpaqueReasoningState
                != canonicalOpaqueReasoningState
                || canonicalEffort != nil
            {
                // Core owns canonical reasoning values. Adopt only its
                // explicit Enabled default and the credential-gated opaque
                // value, then render once more against the new candidate.
                reasoningControl = newReasoning
                promptCacheControl = newCache
                renderedPresetControlCandidate = candidate
                preservesOpaqueReasoningState =
                    canonicalOpaqueReasoningState
                if let canonicalEffort {
                    reasoningEffort = canonicalEffort
                }
                guard remainingCanonicalizationPasses > 0 else {
                    reasoningControl = nil
                    promptCacheControl = nil
                    renderedPresetControlCandidate = nil
                    if reportingFailure {
                        errorMessage =
                            "Core 추론 기본값이 한 번의 재검증으로 수렴하지 않았습니다."
                    }
                    return
                }
                await performPresetControlRefresh(
                    reportingFailure: reportingFailure,
                    remainingCanonicalizationPasses:
                        remainingCanonicalizationPasses - 1
                )
                return
            }
            reasoningControl = newReasoning
            promptCacheControl = newCache
            renderedPresetControlCandidate = candidate
            if reportingFailure {
                errorMessage = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == presetControlRenderGeneration else {
                return
            }
            reasoningControl = nil
            promptCacheControl = nil
            renderedPresetControlCandidate = nil
            if reportingFailure {
                errorMessage = safeFailureMessage(
                    action: "모델별 추론과 캐시 제어를 불러오지",
                    error: error
                )
            }
        }
    }

    public func savePreset() async {
        normalizeOpaqueReasoningContinuityForSelectedConnection()
        guard !isSelectionLoading,
              let connection = selectedConnection,
              let route = selectedModelRoute,
              route.connectionID == connection.id,
              normalizedNonempty(presetName) != nil,
              beginOperation()
        else {
            if normalizedNonempty(presetName) == nil {
                errorMessage = "프리셋 이름을 입력하세요."
            }
            return
        }
        defer { endOperation() }
        let previewGeneration = beginRequestPreviewOperation()
        let context = selectionContext(
            connectionID: connection.id,
            modelRouteID: route.id,
            presetID: selectedPresetID,
            previewGeneration: previewGeneration
        )

        let now = ISO8601DateFormatter().string(from: Date())
        guard let preset = makePresetCandidate(updatedAt: now) else {
            errorMessage = "프리셋 이름과 모델 경로를 확인하세요."
            return
        }
        var ownedPreset = preset
        var committedPreset: ProviderGenerationPreset?
        var committedContext: SelectionContext?
        var submittedPresetForUpsert: ProviderGenerationPreset?
        var editorGenerationAtUpsert: UInt64?

        do {
            let normalized =
                try await presetCandidateByAdoptingRenderedEffort(
                    preset,
                    context: context
                )
            guard presetCandidateIsCurrent(
                preset,
                updatedAt: now,
                context: context
            ) else {
                return
            }
            ownedPreset = normalized.preset
            applyPresetNormalization(normalized)
            guard presetCandidateIsCurrent(
                ownedPreset,
                updatedAt: now,
                context: context
            ) else {
                return
            }
            try await client.validateProviderGenerationPresetCandidate(
                ownedPreset
            )
            guard presetCandidateIsCurrent(
                ownedPreset,
                updatedAt: now,
                context: context
            ) else {
                return
            }
            let candidateForControls = ownedPreset
            async let candidateReasoning =
                client.renderProviderReasoningControl(
                    for: candidateForControls
                )
            async let candidateCache =
                client.renderProviderPromptCacheControl(
                    for: candidateForControls
                )
            async let candidatePreview =
                client.previewProviderRequestCandidate(
                    candidateForControls
                )
            let (
                candidateReasoningControl,
                candidateCacheControl,
                _
            ) = try await (
                candidateReasoning,
                candidateCache,
                candidatePreview
            )
            guard presetCandidateIsCurrent(
                candidateForControls,
                updatedAt: now,
                context: context
            ) else {
                return
            }
            ownedPreset = candidateForControls
            reasoningControl = candidateReasoningControl
            promptCacheControl = candidateCacheControl
            renderedPresetControlCandidate = ownedPreset
            let blockingIssues =
                (
                    candidateReasoningControl.state == .invalid
                        ? candidateReasoningControl.issues
                        : []
                )
                + (
                    candidateCacheControl.state == .invalid
                        ? candidateCacheControl.issues
                        : []
                )
            guard blockingIssues.isEmpty else {
                errorMessage =
                    blockingIssues.first?.message
                    ?? "추론 또는 프롬프트 캐시 설정을 확인하세요."
                return
            }
            let submittedPreset = ownedPreset
            submittedPresetForUpsert = submittedPreset
            editorGenerationAtUpsert = presetEditorGeneration
            let persisted = try await client.upsertProviderGenerationPreset(
                submittedPreset
            )
#if DEBUG
            try await presetSaveResponseFailureHookForTesting?()
            let saved =
                presetSaveResultTransformForTesting?(persisted)
                    ?? persisted
#else
            let saved = persisted
#endif
#if DEBUG
            await presetSavePrePublishHookForTesting?()
#endif
            guard saved.id == ownedPreset.id,
                  saved.modelRouteID == ownedPreset.modelRouteID
            else {
                let reconciliation =
                    await reconcileGenerationPresetsAfterCommittedMutation(
                        modelRouteID: submittedPreset.modelRouteID,
                        owner: context
                    )
                guard reconciliation != .superseded,
                      modelRouteSelectionContextOwnsHierarchy(context)
                else {
                    return
                }
                guard let editorGenerationAtUpsert,
                      presetEditorOwnsCandidate(
                          submittedPreset,
                          editorGeneration:
                              editorGenerationAtUpsert,
                          context: context
                      )
                else {
                    return
                }
                errorMessage =
                    "프리셋 저장은 처리됐지만 Core 응답의 ID 또는 모델 경로가 요청과 달라 저장 목록을 다시 확인했습니다."
                statusMessage = reconciliation == .success
                    ? "저장된 프리셋 목록을 다시 확인했습니다."
                    : "프리셋 저장 결과와 목록을 확인하지 못했습니다. 새로고침하세요."
                return
            }
            ownedPreset = saved
            committedPreset = saved
            let savedContext = context.replacingPreset(
                id: saved.id,
                previewGeneration: previewGeneration
            )
            committedContext = savedContext
            // The upsert is already durable. Publish the exact record before
            // optional postflight rendering so cancellation or a renderer
            // failure cannot make a successful save look absent.
            guard modelRouteSelectionContextOwnsHierarchy(context) else {
                return
            }
            presets.removeAll {
                $0.id == saved.id
                    && $0.modelRouteID == saved.modelRouteID
            }
            presets.append(saved)
            presets.sort {
                $0.displayName.localizedStandardCompare($1.displayName)
                    == .orderedAscending
            }
            publishConfigurationSnapshotIfResolved()
            guard let editorGenerationAtUpsert,
                  presetEditorOwnsCandidate(
                submittedPreset,
                editorGeneration: editorGenerationAtUpsert,
                context: context
            ) else {
                return
            }
            selectedPresetID = saved.id
            editPreset(saved, invalidatesPreview: false)
            statusMessage =
                "프리셋은 저장됐으며 모델별 제어와 미리보기를 확인하고 있습니다."
#if DEBUG
            try await presetSaveCommitHookForTesting?()
#endif
            if Task.isCancelled {
                guard presetCandidateIsOwnedByHierarchy(
                    saved,
                    updatedAt: saved.updatedAt,
                    context: savedContext
                ) else {
                    return
                }
                statusMessage =
                    "프리셋은 저장됐지만 모델별 제어와 미리보기 확인이 취소됐습니다."
                return
            }
            try await client.validateProviderGenerationPreset(
                modelRouteID: saved.modelRouteID,
                generationPresetID: saved.id
            )
            guard presetCandidateIsCurrent(
                ownedPreset,
                updatedAt: saved.updatedAt,
                context: savedContext
            ) else {
                return
            }
            async let loadedReasoning =
                client.renderProviderReasoningControl(for: saved)
            async let loadedCache =
                client.renderProviderPromptCacheControl(for: saved)
            async let loadedPreview = client.previewProviderRequest(
                modelRouteID: saved.modelRouteID,
                generationPresetID: saved.id
            )
            let (savedReasoning, savedCache, savedPreview) =
                try await (
                    loadedReasoning,
                    loadedCache,
                    loadedPreview
                )
            guard presetCandidateIsCurrent(
                saved,
                updatedAt: saved.updatedAt,
                context: savedContext
            ) else {
                return
            }
            requestPreview = savedPreview
            previewedPresetCandidate = saved
            reasoningControl = savedReasoning
            promptCacheControl = savedCache
            renderedPresetControlCandidate = saved
            errorMessage = nil
            statusMessage = "프리셋을 저장했습니다."
        } catch is CancellationError {
            if let committedPreset,
               let committedContext,
               presetCandidateIsOwnedByHierarchy(
                   committedPreset,
                   updatedAt: committedPreset.updatedAt,
                   context: committedContext
               )
            {
                statusMessage =
                    "프리셋은 저장됐지만 모델별 제어와 미리보기 확인이 취소됐습니다."
            } else if let submittedPresetForUpsert,
                      let editorGenerationAtUpsert
            {
                let reconciliation =
                    await reconcileGenerationPresetsAfterCommittedMutation(
                        modelRouteID:
                            submittedPresetForUpsert.modelRouteID,
                        owner: context
                    )
                guard reconciliation != .superseded,
                      presetEditorOwnsCandidate(
                          submittedPresetForUpsert,
                          editorGeneration:
                              editorGenerationAtUpsert,
                          context: context
                      )
                else {
                    return
                }
                if reconciliation == .success,
                   let durable = presets.first(where: {
                       $0.id == submittedPresetForUpsert.id
                           && $0.modelRouteID
                               == submittedPresetForUpsert.modelRouteID
                   }),
                   presetPersistedContentMatches(
                       durable,
                       submittedPresetForUpsert
                   )
                {
                    statusMessage =
                        "프리셋은 저장됐지만 완료 응답 처리가 취소돼 저장 목록을 다시 확인했습니다."
                } else {
                    statusMessage = reconciliation == .success
                        ? "프리셋 저장 취소 후 저장 목록을 다시 확인했습니다."
                        : "프리셋 저장 취소 후 저장 결과를 확인하지 못했습니다. 새로고침하세요."
                }
            }
            return
        } catch {
            if let committedPreset,
               let committedContext,
               presetCandidateIsOwnedByHierarchy(
                   committedPreset,
                   updatedAt: committedPreset.updatedAt,
                   context: committedContext
               )
            {
                errorMessage = safeFailureMessage(
                    action: "저장된 프리셋의 모델별 제어와 미리보기를 불러오지",
                    error: error
                )
                statusMessage =
                    "프리셋은 저장됐지만 모델별 제어와 미리보기 확인에 실패했습니다."
                return
            }
            if let submittedPresetForUpsert,
               let editorGenerationAtUpsert
            {
                let reconciliation =
                    await reconcileGenerationPresetsAfterCommittedMutation(
                        modelRouteID:
                            submittedPresetForUpsert.modelRouteID,
                        owner: context
                    )
                guard reconciliation != .superseded,
                      presetEditorOwnsCandidate(
                          submittedPresetForUpsert,
                          editorGeneration:
                              editorGenerationAtUpsert,
                          context: context
                      )
                else {
                    return
                }
                if reconciliation == .success,
                   let durable = presets.first(where: {
                       $0.id == submittedPresetForUpsert.id
                           && $0.modelRouteID
                               == submittedPresetForUpsert.modelRouteID
                   }),
                   presetPersistedContentMatches(
                       durable,
                       submittedPresetForUpsert
                   )
                {
                    errorMessage = safeFailureMessage(
                        action: "저장된 프리셋의 완료 응답을 처리하지",
                        error: error
                    )
                    statusMessage =
                        "프리셋은 저장됐지만 완료 응답을 처리하지 못해 저장 목록을 다시 확인했습니다."
                    return
                }
                if reconciliation == .failed {
                    errorMessage =
                        "프리셋 저장 결과를 확인하지 못했습니다. 새로고침하세요."
                    statusMessage =
                        "프리셋 저장 결과를 다시 확인해야 합니다."
                    return
                }
            }
            guard presetCandidateIsCurrent(
                ownedPreset,
                updatedAt: ownedPreset.updatedAt,
                context: context
            ) else {
                return
            }
            errorMessage = safeFailureMessage(
                action: "프리셋을 저장하지",
                error: error
            )
        }
    }

    public func deleteSelectedPreset() async {
        guard !isSelectionLoading,
              let connection = selectedConnection,
              let route = selectedModelRoute,
              route.connectionID == connection.id,
              let selectedPreset,
              selectedPreset.modelRouteID == route.id
        else {
            return
        }
        guard selectedPresetCanBeDeleted else {
            errorMessage =
                "마이그레이션된 기본 프리셋은 연결과 별도로 삭제할 수 없습니다."
            return
        }
        guard beginOperation() else {
            return
        }
        defer { endOperation() }
        let previewGeneration = beginRequestPreviewOperation()
        var context = selectionContext(
            connectionID: connection.id,
            modelRouteID: route.id,
            presetID: selectedPreset.id,
            previewGeneration: previewGeneration
        )
        do {
            try await client.deleteProviderGenerationPreset(
                id: selectedPreset.id
            )
            var postCommitHookError: Error?
#if DEBUG
            do {
                try await presetDeletionCommitHookForTesting?()
            } catch {
                postCommitHookError = error
            }
#endif
            let deletedTarget = ProviderGenerationTarget(
                modelRouteID: route.id,
                generationPresetID: selectedPreset.id
            )
            if activeGenerationTarget == deletedTarget {
                activeGenerationTarget = nil
                activeGenerationConnectionID = nil
                publishConfigurationSnapshotIfResolved()
            }
            let activeSelectionReconciliation =
                await reconcileActiveGenerationSelectionAfterCommittedMutation(
                    expectedRefreshGeneration:
                        context.refreshGeneration
                )
            guard modelRouteSelectionContextOwnsHierarchy(context) else {
                return
            }
            presets.removeAll {
                $0.id == selectedPreset.id
                    && $0.modelRouteID == route.id
            }
            publishConfigurationSnapshotIfResolved()
            guard selectedPresetID == selectedPreset.id else {
                // A newer sibling selection owns the editor and messages.
                return
            }
            selectedPresetID = presets.first?.id
            context = context.replacingPreset(
                id: selectedPresetID,
                previewGeneration: previewGeneration
            )
            if let replacement = presets.first {
                editPreset(
                    replacement,
                    invalidatesPreview: false
                )
                await refreshPresetControlsIgnoringCallerCancellation()
            } else {
                clearPresetEditor()
                clearRenderedPresetControls()
            }
            guard selectionContextOwnsHierarchy(context) else {
                return
            }
            guard activeSelectionReconciliation
                != .failed
            else {
                errorMessage =
                    "프리셋은 삭제했지만 앱 기본 모델 상태를 다시 확인하지 못했습니다. 새로고침하세요."
                return
            }
            if let postCommitHookError {
                errorMessage = safeFailureMessage(
                    action: "삭제된 프리셋의 후속 상태를 확인하지",
                    error: postCommitHookError
                )
                statusMessage =
                    "프리셋은 삭제됐지만 후속 상태 확인에 실패했습니다."
                return
            }
            errorMessage = nil
            statusMessage = "프리셋을 삭제했습니다."
        } catch {
            let presetReconciliation =
                await reconcileGenerationPresetsAfterCommittedMutation(
                    modelRouteID: route.id,
                    owner: context
                )
            let activeReconciliation =
                await reconcileActiveGenerationSelectionAfterCommittedMutation(
                    expectedRefreshGeneration:
                        context.refreshGeneration
                )
            guard presetReconciliation != .superseded,
                  modelRouteSelectionContextOwnsHierarchy(context)
            else {
                return
            }
            guard !presets.contains(where: {
                $0.id == selectedPreset.id
                    && $0.modelRouteID == route.id
            }) else {
                guard selectionContextIsCurrent(context) else {
                    return
                }
                errorMessage = safeFailureMessage(
                    action: "프리셋을 삭제하지",
                    error: error
                )
                return
            }
            if selectedPresetID == selectedPreset.id {
                selectedPresetID = presets.first?.id
                context = context.replacingPreset(
                    id: selectedPresetID,
                    previewGeneration: previewGeneration
                )
                if let replacement = presets.first {
                    editPreset(
                        replacement,
                        invalidatesPreview: false
                    )
                    await refreshPresetControlsIgnoringCallerCancellation()
                } else {
                    clearPresetEditor()
                    clearRenderedPresetControls()
                }
            }
            guard selectionContextOwnsHierarchy(context) else {
                return
            }
            errorMessage = safeFailureMessage(
                action: "삭제된 프리셋의 완료 응답을 처리하지",
                error: error
            )
            statusMessage = activeReconciliation == .failed
                ? "프리셋은 삭제됐지만 앱 기본 모델 상태를 다시 확인하지 못했습니다."
                : "프리셋은 삭제됐지만 완료 응답을 처리하지 못했습니다."
        }
    }

    public func loadRequestPreview() async {
        let previewGeneration = beginRequestPreviewOperation()
        normalizeOpaqueReasoningContinuityForSelectedConnection()
        guard !isSelectionLoading,
              let connection = selectedConnection,
              let route = selectedModelRoute,
              route.connectionID == connection.id,
              let presetID = selectedPresetID,
              let preset = selectedPreset,
              preset.modelRouteID == route.id,
              let editorCandidate = makePresetCandidate(
                  updatedAt: preset.updatedAt
              )
        else {
            requestPreview = nil
            previewedPresetCandidate = nil
            return
        }
        let context = selectionContext(
            connectionID: connection.id,
            modelRouteID: route.id,
            presetID: presetID,
            previewGeneration: previewGeneration
        )
        var ownedCandidate = editorCandidate
        do {
            let normalized =
                try await presetCandidateByAdoptingRenderedEffort(
                    editorCandidate,
                    context: context
                )
            guard presetCandidateIsCurrent(
                editorCandidate,
                updatedAt: editorCandidate.updatedAt,
                context: context
            ) else {
                return
            }
            ownedCandidate = normalized.preset
            applyPresetNormalization(normalized)
            guard presetCandidateIsCurrent(
                ownedCandidate,
                updatedAt: ownedCandidate.updatedAt,
                context: context
            ) else {
                return
            }
            try await client.validateProviderGenerationPreset(
                modelRouteID: route.id,
                generationPresetID: presetID
            )
            guard presetCandidateIsCurrent(
                ownedCandidate,
                updatedAt: ownedCandidate.updatedAt,
                context: context
            ) else {
                return
            }
            try await client.validateProviderGenerationPresetCandidate(
                ownedCandidate
            )
            guard presetCandidateIsCurrent(
                ownedCandidate,
                updatedAt: ownedCandidate.updatedAt,
                context: context
            ) else {
                return
            }
            let candidateForPreview = ownedCandidate
            async let loadedReasoning =
                client.renderProviderReasoningControl(
                    for: candidateForPreview
                )
            async let loadedCache =
                client.renderProviderPromptCacheControl(
                    for: candidateForPreview
                )
            async let loadedPreview =
                client.previewProviderRequestCandidate(
                    candidateForPreview
                )
            let (loadedReasoningControl, loadedCacheControl, preview) =
                try await (
                    loadedReasoning,
                    loadedCache,
                    loadedPreview
                )
#if DEBUG
            try await requestPreviewCommitHookForTesting?()
#endif
            guard presetCandidateIsCurrent(
                candidateForPreview,
                updatedAt: candidateForPreview.updatedAt,
                context: context
            ) else {
                return
            }
            ownedCandidate = candidateForPreview
            requestPreview = preview
            previewedPresetCandidate = ownedCandidate
            reasoningControl = loadedReasoningControl
            promptCacheControl = loadedCacheControl
            renderedPresetControlCandidate =
                ownedCandidate
        } catch is CancellationError {
            return
        } catch {
            guard presetCandidateIsCurrent(
                ownedCandidate,
                updatedAt: ownedCandidate.updatedAt,
                context: context
            ) else {
                return
            }
            requestPreview = nil
            previewedPresetCandidate = nil
            if currentReasoningControl?.state != .invalid {
                clearRenderedPresetControls()
            }
        }
    }

    public func previewEditedPreset() async {
        normalizeOpaqueReasoningContinuityForSelectedConnection()
        guard !isSelectionLoading,
              let connection = selectedConnection,
              let route = selectedModelRoute,
              route.connectionID == connection.id,
              beginOperation()
        else {
            return
        }
        defer { endOperation() }
        let previewGeneration = beginRequestPreviewOperation()
        let context = selectionContext(
            connectionID: connection.id,
            modelRouteID: route.id,
            presetID: selectedPresetID,
            previewGeneration: previewGeneration
        )

        let now = ISO8601DateFormatter().string(from: Date())
        guard let candidate = makePresetCandidate(updatedAt: now) else {
            errorMessage = "프리셋 이름과 모델 경로를 확인하세요."
            return
        }
        var ownedCandidate = candidate

        do {
            let normalized =
                try await presetCandidateByAdoptingRenderedEffort(
                    candidate,
                    context: context
                )
            guard presetCandidateIsCurrent(
                candidate,
                updatedAt: now,
                context: context
            ) else {
                return
            }
            ownedCandidate = normalized.preset
            applyPresetNormalization(normalized)
            guard presetCandidateIsCurrent(
                ownedCandidate,
                updatedAt: now,
                context: context
            ) else {
                return
            }
            try await client.validateProviderGenerationPresetCandidate(
                ownedCandidate
            )
            guard presetCandidateIsCurrent(
                ownedCandidate,
                updatedAt: now,
                context: context
            ) else {
                return
            }
            let candidateForPreview = ownedCandidate
            async let loadedReasoning =
                client.renderProviderReasoningControl(
                    for: candidateForPreview
                )
            async let loadedCache =
                client.renderProviderPromptCacheControl(
                    for: candidateForPreview
                )
            async let loadedPreview =
                client.previewProviderRequestCandidate(
                    candidateForPreview
                )
            let (loadedReasoningControl, loadedCacheControl, preview) =
                try await (
                    loadedReasoning,
                    loadedCache,
                    loadedPreview
                )
#if DEBUG
            try await requestPreviewCommitHookForTesting?()
#endif
            guard presetCandidateIsCurrent(
                candidateForPreview,
                updatedAt: now,
                context: context
            ) else {
                return
            }
            ownedCandidate = candidateForPreview
            let blockingIssues =
                (
                    loadedReasoningControl.state == .invalid
                        ? loadedReasoningControl.issues
                        : []
                )
                + (
                    loadedCacheControl.state == .invalid
                        ? loadedCacheControl.issues
                        : []
                )
            guard blockingIssues.isEmpty else {
                requestPreview = nil
                previewedPresetCandidate = nil
                reasoningControl = loadedReasoningControl
                promptCacheControl = loadedCacheControl
                renderedPresetControlCandidate =
                    ownedCandidate
                errorMessage =
                    blockingIssues.first?.message
                    ?? "추론 또는 프롬프트 캐시 설정을 확인하세요."
                return
            }
            requestPreview = preview
            previewedPresetCandidate = ownedCandidate
            reasoningControl = loadedReasoningControl
            promptCacheControl = loadedCacheControl
            renderedPresetControlCandidate = ownedCandidate
            errorMessage = nil
            statusMessage =
                "현재 편집 값으로 scalar-free 요청 미리보기를 만들었습니다."
        } catch is CancellationError {
            return
        } catch {
            guard presetCandidateIsCurrent(
                ownedCandidate,
                updatedAt: ownedCandidate.updatedAt,
                context: context
            ) else {
                return
            }
            requestPreview = nil
            previewedPresetCandidate = nil
            if currentReasoningControl?.state != .invalid {
                clearRenderedPresetControls()
            }
            errorMessage = safeFailureMessage(
                action: "편집 중인 프리셋을 검증하거나 미리보기를 만들지",
                error: error
            )
        }
    }

    public func startModelSync() async {
        guard !isSelectionLoading,
              let connection = selectedConnection,
              selectedConnectionID == connection.id,
              beginOperation()
        else {
            return
        }
        defer { endOperation() }
        modelSyncOperationGeneration &+= 1
        let operationGeneration = modelSyncOperationGeneration
        let selectionGeneration = connectionSelectionGeneration
        let expectedRefreshGeneration = refreshGeneration

        providerConfigurationStore.beginMutation(
            profileID: connection.id
        )
        defer {
            providerConfigurationStore.endMutation(
                profileID: connection.id
            )
        }
        var didInvokeStart = false
        var returnedJobID: String?
        var modelSyncJobIDsBeforeStart: Set<String>?
        do {
            let credential = try await credentialStore.credential(
                for: connection.id
            )
            guard modelSyncOperationContextIsCurrent(
                connectionID: connection.id,
                expectedConnectionSelectionGeneration:
                    selectionGeneration,
                expectedRefreshGeneration:
                    expectedRefreshGeneration,
                expectedOperationGeneration: operationGeneration
            ) else {
                return
            }
            let jobsBeforeStart =
                try await client.listProviderModelSyncs(
                    connectionID: connection.id,
                    limit: 64
                )
            for job in jobsBeforeStart {
                try validateStartedModelSyncJob(
                    job,
                    expectedConnectionID: connection.id
                )
            }
            guard modelSyncOperationContextIsCurrent(
                connectionID: connection.id,
                expectedConnectionSelectionGeneration:
                    selectionGeneration,
                expectedRefreshGeneration:
                    expectedRefreshGeneration,
                expectedOperationGeneration: operationGeneration
            ) else {
                return
            }
            modelSyncJobIDsBeforeStart =
                Set(jobsBeforeStart.map(\.id))
            didInvokeStart = true
            let returned: ProviderModelSyncJob
#if DEBUG
            if let modelSyncStartInvocationForTesting {
                returned = try await modelSyncStartInvocationForTesting(
                    connection.id,
                    credential
                )
            } else {
                returned = try await client.startProviderModelSync(
                    connectionID: connection.id,
                    credential: credential
                )
            }
#else
            returned = try await client.startProviderModelSync(
                connectionID: connection.id,
                credential: credential
            )
#endif
            returnedJobID = returned.id
            var job = returned
#if DEBUG
            job = modelSyncResponseTransformForTesting?(job) ?? job
            await modelSyncOperationCommitHookForTesting?()
#endif
            let responseWasExact =
                (try? validateStartedModelSyncJob(
                    job,
                    expectedConnectionID: connection.id
                )) != nil
            let reconciliation =
                await reconcileDurableModelSyncJobIgnoringCallerCancellation(
                    jobID: returned.id,
                    expectedConnectionID: connection.id,
                    allowsNewJob: true
                )
            guard reconciliation != .superseded else {
                return
            }
            guard reconciliation == .success,
                  let durableJob = modelSyncJob,
                  durableJob.id == returned.id
            else {
                guard modelSyncOperationContextOwns(
                    connectionID: connection.id,
                    expectedConnectionSelectionGeneration:
                        selectionGeneration,
                    expectedRefreshGeneration:
                        expectedRefreshGeneration,
                    expectedOperationGeneration:
                        modelSyncOperationGeneration
                ) else {
                    return
                }
                errorMessage =
                    "모델 동기화 시작 후 durable 작업 상태를 다시 확인하지 못했습니다."
                statusMessage =
                    "모델 동기화 시작 결과를 새로고침하세요."
                return
            }
            let committedSelectionGeneration =
                connectionSelectionGeneration
            let committedRefreshGeneration = refreshGeneration
            let committedOperationGeneration =
                modelSyncOperationGeneration
            let eventOutcome =
                await consumeModelSyncEventsIgnoringCallerCancellation(
                    jobID: durableJob.id,
                expectedConnectionID: connection.id,
                expectedConnectionSelectionGeneration:
                    committedSelectionGeneration,
                expectedRefreshGeneration:
                    committedRefreshGeneration,
                expectedOperationGeneration:
                    committedOperationGeneration
            )
            if modelSyncJob?.id == durableJob.id,
               modelSyncJob?.state.isTerminal == false,
               modelSyncContextOwns(
                   jobID: durableJob.id,
                   expectedConnectionID: connection.id,
                   expectedConnectionSelectionGeneration:
                       committedSelectionGeneration,
                   expectedRefreshGeneration:
                       committedRefreshGeneration,
                   expectedOperationGeneration:
                       committedOperationGeneration
               )
            {
                startModelSyncMonitor(
                    jobID: durableJob.id,
                    connectionID: connection.id,
                    expectedConnectionSelectionGeneration:
                        committedSelectionGeneration,
                    expectedRefreshGeneration:
                        committedRefreshGeneration,
                    expectedOperationGeneration:
                        committedOperationGeneration
                )
            }
            guard modelSyncContextOwns(
                jobID: durableJob.id,
                expectedConnectionID: connection.id,
                expectedConnectionSelectionGeneration:
                    committedSelectionGeneration,
                expectedRefreshGeneration:
                    committedRefreshGeneration,
                expectedOperationGeneration:
                    committedOperationGeneration
            ) else {
                return
            }
            guard responseWasExact else {
                errorMessage =
                    "모델 동기화는 시작됐지만 Core 응답이 요청한 작업과 달라 durable 상태를 다시 확인했습니다."
                statusMessage =
                    "모델 동기화 작업 상태를 다시 확인했습니다."
                return
            }
            guard eventOutcome != .superseded else {
                return
            }
            guard eventOutcome == .success else {
                statusMessage =
                    "모델 동기화는 시작됐지만 최신 이벤트를 불러오지 못했습니다."
                return
            }
            errorMessage = nil
            statusMessage = modelSyncJob?.state == .awaitingReview
                ? "모델 변경 사항을 검토한 뒤 적용하세요."
                : "모델 동기화를 시작했습니다."
        } catch {
            if didInvokeStart,
               let returnedJobID
            {
                let reconciliation =
                    await reconcileDurableModelSyncJobIgnoringCallerCancellation(
                        jobID: returnedJobID,
                        expectedConnectionID: connection.id,
                        allowsNewJob: true
                    )
                if reconciliation == .success,
                   let durableJob = modelSyncJob,
                   modelSyncContextOwns(
                       jobID: durableJob.id,
                       expectedConnectionID: connection.id,
                       expectedConnectionSelectionGeneration:
                           connectionSelectionGeneration,
                       expectedRefreshGeneration:
                           refreshGeneration,
                       expectedOperationGeneration:
                           modelSyncOperationGeneration
                   )
                {
                    errorMessage = safeFailureMessage(
                        action: "시작된 모델 동기화의 완료 응답을 처리하지",
                        error: error
                    )
                    statusMessage =
                        "모델 동기화는 시작됐지만 완료 응답을 처리하지 못했습니다."
                    return
                }
                if reconciliation == .superseded {
                    return
                }
            } else if didInvokeStart,
                      let modelSyncJobIDsBeforeStart
            {
                let reconciliation =
                    await reconcileNewModelSyncAfterUnknownStartResponse(
                        connectionID: connection.id,
                        excludingJobIDs:
                            modelSyncJobIDsBeforeStart,
                        expectedConnectionSelectionGeneration:
                            selectionGeneration,
                        expectedRefreshGeneration:
                            expectedRefreshGeneration,
                        expectedOperationGeneration:
                            operationGeneration
                    )
                if reconciliation == .success,
                   let durableJob = modelSyncJob,
                   modelSyncContextOwns(
                       jobID: durableJob.id,
                       expectedConnectionID: connection.id,
                       expectedConnectionSelectionGeneration:
                           selectionGeneration,
                       expectedRefreshGeneration:
                           expectedRefreshGeneration,
                       expectedOperationGeneration:
                           modelSyncOperationGeneration
                   )
                {
                    errorMessage = safeFailureMessage(
                        action: "시작된 모델 동기화의 완료 응답을 처리하지",
                        error: error
                    )
                    statusMessage =
                        durableJob.state == .awaitingReview
                        ? "모델 동기화는 시작됐지만 완료 응답을 처리하지 못했습니다. 변경 사항을 검토하세요."
                        : "모델 동기화는 시작됐지만 완료 응답을 처리하지 못해 durable 상태를 다시 확인했습니다."
                    return
                }
                if reconciliation == .superseded {
                    return
                }
            }
            guard modelSyncOperationContextIsCurrent(
                connectionID: connection.id,
                expectedConnectionSelectionGeneration:
                    selectionGeneration,
                expectedRefreshGeneration:
                    expectedRefreshGeneration,
                expectedOperationGeneration: operationGeneration
            ) else {
                return
            }
            errorMessage = safeFailureMessage(
                action: "모델과 기능 새로고침을 시작하지",
                error: error
            )
        }
    }

    public func approveModelSync() async {
        guard !isSelectionLoading,
              let job = modelSyncJob,
              let sha256 = job.reviewSHA256,
              let connection = selectedConnection,
              job.connectionID == connection.id,
              beginOperation()
        else {
            return
        }
        defer { endOperation() }
        modelSyncOperationGeneration &+= 1
        let operationGeneration = modelSyncOperationGeneration
        let selectionGeneration = connectionSelectionGeneration
        let expectedRefreshGeneration = refreshGeneration
        let preferredModelRouteID = selectedModelRouteID
        let expectedModelRouteSelectionGeneration =
            modelRouteSelectionGeneration
        var didInvokeApproval = false

        do {
            didInvokeApproval = true
            let returned = try await client.approveProviderModelSync(
                jobID: job.id,
                expectedRevision: job.revision,
                reviewSHA256: sha256
            )
            var updated = returned
#if DEBUG
            updated =
                modelSyncResponseTransformForTesting?(updated)
                    ?? updated
            await modelSyncOperationCommitHookForTesting?()
#endif
            let responseWasExact =
                (try? validateModelSyncMutationResponse(
                    updated,
                    requestedJob: job,
                    operation: .approve
                )) != nil
            let reconciliation =
                await reconcileDurableModelSyncJobIgnoringCallerCancellation(
                    jobID: job.id,
                    expectedConnectionID: connection.id
                )
            guard reconciliation != .superseded else {
                return
            }
            guard reconciliation == .success,
                  let durableJob = modelSyncJob,
                  durableJob.id == job.id
            else {
                guard modelSyncOperationContextOwns(
                    connectionID: connection.id,
                    expectedConnectionSelectionGeneration:
                        selectionGeneration,
                    expectedRefreshGeneration:
                        expectedRefreshGeneration,
                    expectedOperationGeneration:
                        modelSyncOperationGeneration
                ) else {
                    return
                }
                errorMessage =
                    "모델 동기화 적용 후 durable 작업 상태를 다시 확인하지 못했습니다."
                statusMessage =
                    "모델 동기화 적용 결과를 새로고침하세요."
                return
            }
            if durableJob.state == .completed {
                guard connectionSelectionGeneration
                    == selectionGeneration,
                    refreshGeneration == expectedRefreshGeneration,
                    modelRouteSelectionGeneration
                        == expectedModelRouteSelectionGeneration,
                    selectedConnectionID == connection.id,
                    selectedModelRouteID == preferredModelRouteID
                else {
                    return
                }
                let hydrationOwner = connectionHierarchyOwner()
                let hydrationOperationGeneration =
                    modelSyncOperationGeneration
                let hydrationResult =
                    await selectConnectionIgnoringCallerCancellation(
                        id: connection.id,
                        expectedRefreshGeneration:
                            hydrationOwner.refreshGeneration,
                        owner: hydrationOwner,
                        expectedModelRouteSelectionGeneration:
                            expectedModelRouteSelectionGeneration,
                        expectedSelectedModelRouteID:
                            preferredModelRouteID,
                        expectedModelSyncOperationGeneration:
                            hydrationOperationGeneration,
                        preferredModelRouteID:
                            preferredModelRouteID
                    )
#if DEBUG
                await
                    cancellationIndependentSelectionCompletionHookForTesting?()
#endif
                guard hydrationResult.outcome != .superseded,
                      let completedHydrationOwner =
                          hydrationResult.owner,
                      connectionHydrationOwnerIsCurrent(
                          completedHydrationOwner
                      )
                else {
                    return
                }
                let finalReconciliation =
                    await reconcileDurableModelSyncJobIgnoringCallerCancellation(
                        jobID: job.id,
                        expectedConnectionID: connection.id
                    )
                guard finalReconciliation == .success,
                      let visibleJob = modelSyncJob,
                      visibleJob.id == job.id,
                      visibleJob.state == .completed,
                      connectionHydrationOwnerIsCurrent(
                          completedHydrationOwner
                      )
                else {
                    return
                }
                guard responseWasExact else {
                    errorMessage =
                        "모델 변경은 적용됐지만 Core 응답이 요청과 달라 durable 상태를 다시 확인했습니다."
                    statusMessage =
                        "적용된 모델 변경 상태를 다시 확인했습니다."
                    return
                }
                guard hydrationResult.outcome == .success else {
                    statusMessage =
                        "모델 변경은 적용됐지만 연결의 모델 목록을 다시 불러오지 못했습니다."
                    return
                }
                errorMessage = nil
                statusMessage =
                    "검토한 모델 변경을 적용했습니다. 보이지 않은 모델의 기존 참조는 유지됩니다."
            } else {
                let committedSelectionGeneration =
                    connectionSelectionGeneration
                let committedRefreshGeneration =
                    refreshGeneration
                let committedOperationGeneration =
                    modelSyncOperationGeneration
                let eventOutcome =
                    await consumeModelSyncEventsIgnoringCallerCancellation(
                    jobID: durableJob.id,
                    expectedConnectionID: connection.id,
                    expectedConnectionSelectionGeneration:
                        committedSelectionGeneration,
                    expectedRefreshGeneration:
                        committedRefreshGeneration,
                    expectedOperationGeneration:
                        committedOperationGeneration
                )
                if modelSyncContextOwns(
                    jobID: durableJob.id,
                    expectedConnectionID: connection.id,
                    expectedConnectionSelectionGeneration:
                        committedSelectionGeneration,
                    expectedRefreshGeneration:
                        committedRefreshGeneration,
                    expectedOperationGeneration:
                        committedOperationGeneration
                ), modelSyncJob?.state.isTerminal == false
                {
                    startModelSyncMonitor(
                        jobID: durableJob.id,
                        connectionID: connection.id,
                        expectedConnectionSelectionGeneration:
                            committedSelectionGeneration,
                        expectedRefreshGeneration:
                            committedRefreshGeneration,
                        expectedOperationGeneration:
                            committedOperationGeneration
                    )
                }
                guard modelSyncContextOwns(
                    jobID: durableJob.id,
                    expectedConnectionID: connection.id,
                    expectedConnectionSelectionGeneration:
                        committedSelectionGeneration,
                    expectedRefreshGeneration:
                        committedRefreshGeneration,
                    expectedOperationGeneration:
                        committedOperationGeneration
                ) else {
                    return
                }
                guard responseWasExact else {
                    errorMessage =
                        "모델 동기화 적용은 처리됐지만 Core 응답이 요청과 달라 durable 상태를 다시 확인했습니다."
                    statusMessage =
                        "모델 동기화 작업 상태를 다시 확인했습니다."
                    return
                }
                if eventOutcome == .failed {
                    statusMessage =
                        "모델 동기화 적용은 처리됐지만 최신 이벤트를 불러오지 못했습니다."
                }
            }
        } catch {
            if didInvokeApproval {
                let reconciliation =
                    await reconcileDurableModelSyncJobIgnoringCallerCancellation(
                        jobID: job.id,
                        expectedConnectionID: connection.id
                    )
                if reconciliation == .success,
                   let durableJob = modelSyncJob,
                   modelSyncContextOwns(
                       jobID: durableJob.id,
                       expectedConnectionID: connection.id,
                       expectedConnectionSelectionGeneration:
                           connectionSelectionGeneration,
                       expectedRefreshGeneration:
                           refreshGeneration,
                       expectedOperationGeneration:
                           modelSyncOperationGeneration
                   )
                {
                    errorMessage = safeFailureMessage(
                        action: "적용된 모델 동기화의 완료 응답을 처리하지",
                        error: error
                    )
                    statusMessage =
                        "모델 동기화 적용은 처리됐지만 완료 응답을 처리하지 못했습니다."
                    return
                }
                if reconciliation == .superseded {
                    return
                }
            }
            guard modelSyncOperationContextIsCurrent(
                connectionID: connection.id,
                expectedConnectionSelectionGeneration:
                    selectionGeneration,
                expectedRefreshGeneration:
                    expectedRefreshGeneration,
                expectedOperationGeneration: operationGeneration
            ) else {
                return
            }
            errorMessage = safeFailureMessage(
                action: "모델 동기화 변경을 적용하지",
                error: error
            )
        }
    }

    public func cancelModelSync() async {
        guard !isSelectionLoading,
              let job = modelSyncJob,
              let connection = selectedConnection,
              job.connectionID == connection.id,
              beginOperation()
        else {
            return
        }
        defer { endOperation() }
        modelSyncOperationGeneration &+= 1
        let operationGeneration = modelSyncOperationGeneration
        let selectionGeneration = connectionSelectionGeneration
        let expectedRefreshGeneration = refreshGeneration
        var didInvokeCancellation = false
        do {
            didInvokeCancellation = true
            let returned = try await client.cancelProviderModelSync(
                jobID: job.id,
                expectedRevision: job.revision
            )
            var updated = returned
#if DEBUG
            updated =
                modelSyncResponseTransformForTesting?(updated)
                    ?? updated
            await modelSyncOperationCommitHookForTesting?()
#endif
            let responseWasExact =
                (try? validateModelSyncMutationResponse(
                    updated,
                    requestedJob: job,
                    operation: .cancel
                )) != nil
            let reconciliation =
                await reconcileDurableModelSyncJobIgnoringCallerCancellation(
                    jobID: job.id,
                    expectedConnectionID: connection.id
                )
            guard reconciliation != .superseded else {
                return
            }
            stopModelSyncMonitor()
            guard reconciliation == .success,
                  modelSyncContextOwns(
                      jobID: job.id,
                      expectedConnectionID: connection.id,
                      expectedConnectionSelectionGeneration:
                          selectionGeneration,
                      expectedRefreshGeneration:
                          expectedRefreshGeneration,
                      expectedOperationGeneration:
                          modelSyncOperationGeneration
                  )
            else {
                return
            }
            guard responseWasExact else {
                errorMessage =
                    "모델 동기화 취소는 처리됐지만 Core 응답이 요청과 달라 durable 상태를 다시 확인했습니다."
                statusMessage =
                    "모델 동기화 취소 상태를 다시 확인했습니다."
                return
            }
            errorMessage = nil
            statusMessage = "모델 동기화를 취소했습니다."
        } catch {
            if didInvokeCancellation {
                let reconciliation =
                    await reconcileDurableModelSyncJobIgnoringCallerCancellation(
                        jobID: job.id,
                        expectedConnectionID: connection.id
                    )
                if reconciliation == .success,
                   modelSyncContextOwns(
                       jobID: job.id,
                       expectedConnectionID: connection.id,
                       expectedConnectionSelectionGeneration:
                           selectionGeneration,
                       expectedRefreshGeneration:
                           expectedRefreshGeneration,
                       expectedOperationGeneration:
                           modelSyncOperationGeneration
                   )
                {
                    errorMessage = safeFailureMessage(
                        action: "취소된 모델 동기화의 완료 응답을 처리하지",
                        error: error
                    )
                    statusMessage =
                        "모델 동기화는 취소됐지만 완료 응답을 처리하지 못했습니다."
                    return
                }
                if reconciliation == .superseded {
                    return
                }
            }
            guard modelSyncOperationContextIsCurrent(
                connectionID: connection.id,
                expectedConnectionSelectionGeneration:
                    selectionGeneration,
                expectedRefreshGeneration:
                    expectedRefreshGeneration,
                expectedOperationGeneration: operationGeneration
            ) else {
                return
            }
            errorMessage = safeFailureMessage(
                action: "모델 동기화를 취소하지",
                error: error
            )
        }
    }

    public func refreshModelSyncEvents() async {
        guard let job = modelSyncJob,
              let connection = selectedConnection,
              job.connectionID == connection.id
        else {
            return
        }
        await consumeModelSyncEvents(
            jobID: job.id,
            expectedConnectionID: connection.id,
            expectedConnectionSelectionGeneration:
                connectionSelectionGeneration,
            expectedRefreshGeneration: refreshGeneration,
            expectedOperationGeneration:
                modelSyncOperationGeneration
        )
    }

    public func deleteSelectedConnection() async {
        guard let connection = selectedConnection,
              beginOperation()
        else {
            return
        }
        defer { endOperation() }
        providerConfigurationStore.beginMutation(profileID: connection.id)
        defer {
            providerConfigurationStore.endMutation(profileID: connection.id)
        }
        let context = selectionContext(
            connectionID: connection.id,
            modelRouteID: selectedModelRouteID,
            presetID: selectedPresetID
        )

        let storedCredential: Data?
        do {
            storedCredential = try await credentialStore.credentialData(
                for: connection.id
            )
        } catch {
            guard connectionSelectionContextIsCurrent(context) else {
                return
            }
            providerConfigurationStore.quarantine(profileID: connection.id)
            errorMessage =
                "Keychain 상태를 확인할 수 없어 연결을 삭제하지 않았습니다."
            return
        }
        guard connectionSelectionContextIsCurrent(context) else {
            return
        }

        do {
            try await credentialStore.deleteCredential(for: connection.id)
            guard try await credentialStore.credentialData(
                for: connection.id
            ) == nil else {
                throw CredentialStoreError.verificationFailed
            }
        } catch {
            let restored = await restoreCredentialData(
                storedCredential,
                connectionID: connection.id
            )
            if !restored {
                providerConfigurationStore.quarantine(
                    profileID: connection.id
                )
            }
            guard connectionSelectionContextIsCurrent(context) else {
                return
            }
            if restored {
                errorMessage =
                    "API 키 삭제를 확인하지 못해 원래 값을 복구하고 연결을 유지했습니다."
            } else {
                errorMessage =
                    "API 키 삭제를 확인하지 못했고 원래 값을 복구할 수도 없어 이 연결을 격리했습니다."
            }
            return
        }
        guard connectionSelectionContextIsCurrent(context) else {
            let restored = await restoreCredentialData(
                storedCredential,
                connectionID: connection.id
            )
            if !restored {
                providerConfigurationStore.quarantine(
                    profileID: connection.id
                )
            }
            return
        }

        do {
#if DEBUG
            await connectionDeletionPreCommitHookForTesting?()
#endif
            try await client.deleteProviderConnection(id: connection.id)
        } catch {
            let restored = await restoreCredentialData(
                storedCredential,
                connectionID: connection.id
            )
            if !restored {
                providerConfigurationStore.quarantine(
                    profileID: connection.id
                )
            }
            guard connectionSelectionContextIsCurrent(context) else {
                return
            }
            if restored {
                errorMessage = safeFailureMessage(
                    action: "프로바이더 연결을 삭제하지",
                    error: error
                )
            } else {
                errorMessage =
                    "연결 삭제 실패 후 API 키를 복구하지 못했습니다. 이 연결은 사용하지 않도록 격리했습니다."
            }
            return
        }

#if DEBUG
        do {
            try await connectionDeletionCommitHookForTesting?()
        } catch {
            // The Core deletion has already committed. Reconcile it below;
            // the hook only makes the post-commit failure window testable.
        }
#endif
        let selectedDeletedConnection =
            selectedConnectionID == connection.id
        var replacementOwner: ConnectionHierarchyOwner?
        if selectedDeletedConnection {
            selectedConnectionID = nil
            connectionSelectionGeneration &+= 1
            invalidateConnectionHierarchy()
            isSelectionLoading = false
            replacementOwner = connectionHierarchyOwner()
        }
        providerConfigurationStore.clearQuarantine(
            profileID: connection.id
        )
        connections.removeAll { $0.id == connection.id }
        replaceAssistantModelRoutes(
            assistantModelRoutes.filter {
                $0.connectionID != connection.id
            }
        )
        if activeGenerationConnectionID == connection.id {
            activeGenerationTarget = nil
            activeGenerationConnectionID = nil
        }
        publishConfigurationSnapshotIfResolved()
        let activeSelectionReconciliation =
            await reconcileActiveGenerationSelectionAfterCommittedMutation(
                expectedRefreshGeneration: refreshGeneration
            )
        guard let replacementOwner,
              connectionHierarchyOwnerIsCurrent(replacementOwner)
        else {
            return
        }

        let replacementConnectionID = connections.first?.id
        if let replacementConnectionID {
            let hydrationResult =
                await selectConnectionIgnoringCallerCancellation(
                    id: replacementConnectionID,
                    expectedRefreshGeneration:
                        replacementOwner.refreshGeneration,
                    owner: replacementOwner
                )
#if DEBUG
            await
                cancellationIndependentSelectionCompletionHookForTesting?()
#endif
            guard hydrationResult.outcome != .superseded,
                  let completedHydrationOwner =
                      hydrationResult.owner,
                  connectionHydrationOwnerIsCurrent(
                      completedHydrationOwner
                  )
            else {
                return
            }
            if hydrationResult.outcome == .failed {
                statusMessage =
                    "연결과 API 키는 삭제했지만 다음 연결을 불러오지 못했습니다."
                return
            }
        }

        guard activeSelectionReconciliation != .failed else {
            errorMessage =
                "연결과 API 키는 삭제했지만 앱 기본 모델 상태를 다시 확인하지 못했습니다. 새로고침하세요."
            return
        }
        errorMessage = nil
        statusMessage = "프로바이더 연결과 Keychain API 키를 삭제했습니다."
    }

    public func prepareCatalogRollback(
        to targetRevision: UInt64
    ) async {
        guard beginOperation() else {
            return
        }
        defer { endOperation() }
        catalogReviewGeneration &+= 1
        let reviewGeneration = catalogReviewGeneration
        pendingCatalogRollback = nil
        let activeRevisionBeforePrepare =
            catalogStatus?.currentRevision
        do {
            let plan =
                try await client.prepareProviderCatalogRollback(
                    targetRevision: targetRevision
                )
            guard !Task.isCancelled,
                  reviewGeneration == catalogReviewGeneration
            else {
                return
            }
            guard plan.toRevision == targetRevision,
                  plan.fromRevision
                    == activeRevisionBeforePrepare
            else {
                throw CoreClientFailure.invalidResponse(
                    "Core가 준비한 카탈로그 롤백 범위가 선택한 revision과 다릅니다."
                )
            }
            let statusAfterPrepare =
                try await client.getProviderCatalogStatus()
            guard !Task.isCancelled,
                  reviewGeneration == catalogReviewGeneration
            else {
                return
            }
#if DEBUG
            await catalogReviewCommitHookForTesting?()
#endif
            guard !Task.isCancelled,
                  reviewGeneration == catalogReviewGeneration
            else {
                return
            }
            guard statusAfterPrepare.currentRevision
                == activeRevisionBeforePrepare
            else {
                throw CoreClientFailure.invalidResponse(
                    "롤백 검토 준비 중 활성 카탈로그가 예상과 다르게 변경되었습니다."
                )
            }
            catalogStatus = statusAfterPrepare
            pendingCatalogRollback = plan
            errorMessage = nil
            statusMessage =
                "r\(plan.fromRevision) → r\(plan.toRevision) 롤백 변경을 준비했습니다. 활성 카탈로그는 아직 바뀌지 않았습니다."
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  reviewGeneration == catalogReviewGeneration
            else {
                return
            }
            pendingCatalogRollback = nil
            errorMessage = safeFailureMessage(
                action: "카탈로그 롤백 변경을 준비하지",
                error: error
            )
        }
    }

    public func activatePreparedCatalogRollback() async {
        guard let plan = pendingCatalogRollback,
              beginOperation()
        else {
            return
        }
        catalogActivationInProgress = true
        defer {
            catalogActivationInProgress = false
            endOperation()
        }
        let reviewGeneration = catalogReviewGeneration
        let hierarchyOwner = connectionHierarchyOwner()
        var didInvokeActivation = false
        do {
            didInvokeActivation = true
            var result =
                try await client.activateProviderCatalogRollback(
                    plan: plan
                )
#if DEBUG
            result =
                catalogRollbackResultTransformForTesting?(result)
                    ?? result
            await catalogActivationCommitHookForTesting?()
#endif
            guard result.fromRevision == plan.fromRevision,
                  result.activatedRevision == plan.toRevision,
                  result.status.currentRevision
                    == plan.toRevision
            else {
                statusMessage =
                    "카탈로그 롤백 처리 결과를 다시 확인하고 있습니다."
                let reconciled =
                    await refreshAfterCatalogActivation(
                        owner: hierarchyOwner
                    )
                if reviewGeneration == catalogReviewGeneration {
                    pendingCatalogRollback = nil
                }
                guard reconciled != .superseded,
                      reviewGeneration == catalogReviewGeneration
                else {
                    return
                }
                errorMessage =
                    "카탈로그 롤백은 처리됐지만 Core 응답 revision이 검토 계획과 일치하지 않아 현재 상태를 다시 확인했습니다."
                statusMessage =
                    "카탈로그 롤백 결과를 다시 확인해야 합니다."
                return
            }
            catalogStatus = result.status
            if reviewGeneration == catalogReviewGeneration {
                pendingCatalogRollback = nil
            }
            errorMessage = nil
            statusMessage =
                "카탈로그 r\(result.activatedRevision) 롤백을 적용했으며 프로바이더 상태를 확인하고 있습니다."
            let refreshed =
                await refreshAfterCatalogActivation(
                    owner: hierarchyOwner
                )
            guard reviewGeneration == catalogReviewGeneration,
                  refreshed != .superseded
            else {
                return
            }
            guard refreshed == .success else {
                statusMessage =
                    "카탈로그 r\(result.activatedRevision) 롤백은 적용됐지만 프로바이더 상태 새로고침에 실패했습니다."
                return
            }
            errorMessage = nil
            statusMessage =
                "검토한 카탈로그 r\(result.activatedRevision) 롤백을 활성화했습니다."
        } catch {
            guard reviewGeneration == catalogReviewGeneration else {
                return
            }
            pendingCatalogRollback = nil
            if didInvokeActivation {
                statusMessage =
                    "카탈로그 롤백 처리 결과를 다시 확인하고 있습니다."
                let reconciled =
                    await refreshAfterCatalogActivation(
                        owner: hierarchyOwner
                    )
                guard reviewGeneration == catalogReviewGeneration,
                      reconciled != .superseded
                else {
                    return
                }
                if catalogStatus?.currentRevision == plan.toRevision {
                    errorMessage = safeFailureMessage(
                        action: "적용된 카탈로그 롤백의 완료 응답을 처리하지",
                        error: error
                    )
                    statusMessage =
                        "카탈로그 r\(plan.toRevision) 롤백은 적용됐지만 완료 응답을 처리하지 못했습니다."
                    return
                }
            }
            errorMessage = safeFailureMessage(
                action: "카탈로그를 되돌리지",
                error: error
            )
        }
    }

    public func cancelPreparedCatalogRollback() {
        guard !catalogActivationInProgress else {
            return
        }
        catalogReviewGeneration &+= 1
        pendingCatalogRollback = nil
        statusMessage = "카탈로그 롤백 검토를 취소했습니다."
    }

    public func prepareSignedCatalogImport(
        from fileURL: URL
    ) async {
        guard beginOperation() else {
            return
        }
        defer { endOperation() }
        catalogReviewGeneration &+= 1
        let reviewGeneration = catalogReviewGeneration
        clearPendingCatalogImport()

        let activeRevisionBeforePrepare =
            catalogStatus?.currentRevision
        do {
            let envelopeJSON = try await Task.detached(
                priority: .userInitiated
            ) {
                try Self.readCatalogEnvelope(from: fileURL)
            }.value
            guard !Task.isCancelled,
                  reviewGeneration == catalogReviewGeneration
            else {
                return
            }
            let plan =
                try await client.prepareSignedProviderCatalogImport(
                    envelopeJSON: envelopeJSON
                )
            guard !Task.isCancelled,
                  reviewGeneration == catalogReviewGeneration
            else {
                return
            }
            guard plan.review.envelopeByteCount
                == UInt64(envelopeJSON.count),
                plan.review.expectedActiveRevision
                    == activeRevisionBeforePrepare
            else {
                throw CoreClientFailure.invalidResponse(
                    "검토 계획의 파일 크기 또는 활성 revision이 선택한 상태와 다릅니다."
                )
            }
            let statusAfterPrepare =
                try await client.getProviderCatalogStatus()
            guard !Task.isCancelled,
                  reviewGeneration == catalogReviewGeneration
            else {
                return
            }
#if DEBUG
            await catalogReviewCommitHookForTesting?()
#endif
            guard !Task.isCancelled,
                  reviewGeneration == catalogReviewGeneration
            else {
                return
            }
            guard statusAfterPrepare.currentRevision
                == activeRevisionBeforePrepare
            else {
                throw CoreClientFailure.invalidResponse(
                    "검토 준비 중 활성 카탈로그가 예상과 다르게 변경되었습니다."
                )
            }
            catalogStatus = statusAfterPrepare
            pendingCatalogEnvelopeJSON = envelopeJSON
            pendingCatalogImport = plan
            pendingCatalogImportFilename = fileURL.lastPathComponent
            errorMessage = nil
            statusMessage =
                "서명과 변경 내용을 확인했습니다. 활성 카탈로그는 아직 바뀌지 않았습니다."
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  reviewGeneration == catalogReviewGeneration
            else {
                return
            }
            clearPendingCatalogImport()
            errorMessage = safeFailureMessage(
                action: "서명 카탈로그 파일을 검토하지",
                error: error
            )
        }
    }

    public func activatePreparedCatalogImport() async {
        guard let plan = pendingCatalogImport,
              let envelopeJSON = pendingCatalogEnvelopeJSON,
              beginOperation()
        else {
            return
        }
        catalogActivationInProgress = true
        defer {
            catalogActivationInProgress = false
            endOperation()
        }
        let reviewGeneration = catalogReviewGeneration
        let hierarchyOwner = connectionHierarchyOwner()
        var didInvokeActivation = false

        guard plan.review.envelopeByteCount
            == UInt64(envelopeJSON.count)
        else {
            clearPendingCatalogImport()
            errorMessage =
                "검토한 카탈로그 파일 바이트가 일치하지 않아 적용하지 않았습니다."
            return
        }

        do {
            didInvokeActivation = true
            var result =
                try await client.activateSignedProviderCatalogImport(
                    plan: plan,
                    envelopeJSON: envelopeJSON
                )
#if DEBUG
            result =
                catalogImportResultTransformForTesting?(result)
                    ?? result
            await catalogActivationCommitHookForTesting?()
#endif
            guard result.activatedRevision
                == plan.review.candidateRevision,
                result.status.currentRevision
                    == result.activatedRevision
            else {
                statusMessage =
                    "서명 카탈로그 처리 결과를 다시 확인하고 있습니다."
                let reconciled =
                    await refreshAfterCatalogActivation(
                        owner: hierarchyOwner
                    )
                if reviewGeneration == catalogReviewGeneration {
                    clearPendingCatalogImport()
                }
                guard reconciled != .superseded,
                      reviewGeneration == catalogReviewGeneration
                else {
                    return
                }
                errorMessage =
                    "서명 카탈로그는 처리됐지만 Core 응답 revision이 검토 내용과 일치하지 않아 현재 상태를 다시 확인했습니다."
                statusMessage =
                    "서명 카탈로그 적용 결과를 다시 확인해야 합니다."
                return
            }
            catalogStatus = result.status
            if reviewGeneration == catalogReviewGeneration {
                clearPendingCatalogImport()
            }
            errorMessage = nil
            statusMessage =
                "서명 카탈로그 r\(result.activatedRevision)을 적용했으며 프로바이더 상태를 확인하고 있습니다."
            let refreshed =
                await refreshAfterCatalogActivation(
                    owner: hierarchyOwner
                )
            guard reviewGeneration == catalogReviewGeneration,
                  refreshed != .superseded
            else {
                return
            }
            guard refreshed == .success else {
                statusMessage =
                    "서명 카탈로그 r\(result.activatedRevision)은 적용됐지만 프로바이더 상태 새로고침에 실패했습니다."
                return
            }
            errorMessage = nil
            statusMessage =
                "검토한 서명 카탈로그 r\(result.activatedRevision)을 활성화했습니다."
        } catch {
            guard reviewGeneration == catalogReviewGeneration else {
                return
            }
            clearPendingCatalogImport()
            if didInvokeActivation {
                statusMessage =
                    "서명 카탈로그 처리 결과를 다시 확인하고 있습니다."
                let reconciled =
                    await refreshAfterCatalogActivation(
                        owner: hierarchyOwner
                    )
                guard reviewGeneration == catalogReviewGeneration,
                      reconciled != .superseded
                else {
                    return
                }
                if catalogStatus?.currentRevision
                    == plan.review.candidateRevision
                {
                    errorMessage = safeFailureMessage(
                        action: "적용된 서명 카탈로그의 완료 응답을 처리하지",
                        error: error
                    )
                    statusMessage =
                        "서명 카탈로그 r\(plan.review.candidateRevision)은 적용됐지만 완료 응답을 처리하지 못했습니다."
                    return
                }
            }
            errorMessage = safeFailureMessage(
                action: "검토한 서명 카탈로그를 활성화하지",
                error: error
            )
        }
    }

    public func cancelPreparedCatalogImport() {
        guard !catalogActivationInProgress else {
            return
        }
        catalogReviewGeneration &+= 1
        clearPendingCatalogImport()
        errorMessage = nil
        statusMessage = "서명 카탈로그 변경 검토를 취소했습니다."
    }

    private var normalizedCredentialDraft: String? {
        normalizedNonempty(credentialDraft)
    }

    private var normalizedURLDraft: String? {
        normalizedNonempty(discoveryURL)
    }

    private var discoveryValidationMessage: String {
        switch discoveryMethod {
        case .knownProvider:
            "연결 이름, 프로바이더와 필요한 API 키를 확인하세요."
        case .website:
            "연결 이름, API 키를 발급받은 사이트와 API 키를 확인하세요."
        case .curl:
            "연결 이름과 API 문서의 cURL 예제를 확인하세요."
        case .localServer:
            "로컬 네트워크 사용을 확인하고 서버 주소를 입력하세요."
        }
    }

    private func beginOperation() -> Bool {
        guard !isBusy else {
            return false
        }
        isBusy = true
        errorMessage = nil
        return true
    }

    nonisolated private static func readCatalogEnvelope(
        from fileURL: URL
    ) throws -> Data {
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        let values = try fileURL.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        )
        guard values.isRegularFile == true else {
            throw CoreClientFailure.invalidResponse(
                "일반 파일만 서명 카탈로그로 선택할 수 있습니다."
            )
        }
        // This native read cap protects the UI process. Rust applies the
        // stricter product envelope limit and signature validation.
        let nativeReadCap = 16 * 1_024 * 1_024
        guard let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= nativeReadCap
        else {
            throw CoreClientFailure.invalidResponse(
                "선택한 카탈로그 파일 크기를 처리할 수 없습니다."
            )
        }
        return try Data(contentsOf: fileURL)
    }

    private func clearPendingCatalogImport() {
        pendingCatalogImport = nil
        pendingCatalogImportFilename = nil
        let envelope = pendingCatalogEnvelopeJSON
        pendingCatalogEnvelopeJSON = nil
        if var envelope {
            envelope.resetBytes(in: 0 ..< envelope.count)
        }
    }

    private func endOperation() {
        isBusy = false
    }

    private func discoveryStatus(
        _ snapshot: ProviderDiscoverySnapshot
    ) -> String {
        switch snapshot.state {
        case .awaitingAssistantConsent:
            "문서 분석 전송 대상을 확인하세요."
        case .awaitingCredentialOriginApproval:
            "API 키를 보낼 서버를 확인하세요."
        case .awaitingProbeConsent:
            "비용이 들 수 있는 기능 검사를 선택하세요."
        case .awaitingReview:
            "연결, 모델과 기능 변경을 검토하세요."
        case .cancelled:
            "탐색을 취소했습니다."
        case .failed:
            "탐색을 완료하지 못했습니다."
        default:
            "프로바이더 탐색을 진행했습니다."
        }
    }

    private func makeAssistantCallEstimate(
        _ consent: ProviderDiscoveryAssistantConsent
    ) -> ProviderDiscoveryAssistantCallEstimate {
        let callCount = max(UInt64(consent.maximumCalls), 1)
        return ProviderDiscoveryAssistantCallEstimate(
            inputTokens: max(
                UInt64(consent.maximumInputTokens) / callCount,
                1
            ),
            maximumOutputTokens: max(
                UInt64(consent.maximumOutputTokens) / callCount,
                1
            ),
            maximumCostMicroUnits:
                consent.maximumCostMicroUnits / callCount
        )
    }

    private func makeAssistantCallEstimate(
        _ binding: ProviderDiscoveryAssistantApprovalBinding
    ) -> ProviderDiscoveryAssistantCallEstimate {
        let callCount = max(UInt64(binding.maximumCalls), 1)
        return ProviderDiscoveryAssistantCallEstimate(
            inputTokens: max(
                UInt64(binding.maximumInputTokens) / callCount,
                1
            ),
            maximumOutputTokens: max(
                UInt64(binding.maximumOutputTokens) / callCount,
                1
            ),
            maximumCostMicroUnits:
                binding.maximumCostMicroUnits / callCount
        )
    }

    private func performDiscoveryAssistantTurn(
        snapshot: ProviderDiscoverySnapshot,
        expectedOperationGeneration: UInt64
    ) async throws {
        guard snapshot.assistantResumeBoundary?.action
            == .runAssistant
        else {
            throw CoreClientFailure.invalidResponse(
                "설정 도우미 모델 호출은 Core의 run_assistant 재개 경계에서만 실행할 수 있습니다."
            )
        }
        guard discoveryContextIsCurrent(
            sessionID: snapshot.id,
            connectionID: snapshot.pendingConnectionID,
            expectedOperationGeneration:
                expectedOperationGeneration
        ) else {
            throw CancellationError()
        }
        let estimate = assistantCallEstimate
            ?? ProviderDiscoveryAssistantCallEstimate(
                inputTokens: 512,
                maximumOutputTokens: 512,
                maximumCostMicroUnits: 0
            )
        var credential = try await assistantCredential(
            for: snapshot
        )
        defer {
            credential = nil
        }
        var didInvokeAssistant = false
        do {
            didInvokeAssistant = true
            let action =
                try await client.runProviderDiscoveryAssistantTurn(
                    sessionID: snapshot.id,
                    estimate: estimate,
                    assistantCredential: credential
                )
#if DEBUG
            try await discoveryAssistantTurnCommitHookForTesting?()
#endif
            let nextStatusMessage: String
            switch action {
            case let .requestMoreEvidence(sessionID, questions):
                guard sessionID == snapshot.id,
                      !questions.isEmpty,
                      questions.allSatisfy({
                          !$0.id.isEmpty
                              && !$0.question.isEmpty
                              && !$0.requiredEvidence.isEmpty
                      })
                else {
                    throw CoreClientFailure.invalidResponse(
                        "설정 도우미가 현재 탐색과 다른 추가 증거 요청을 반환했습니다."
                    )
                }
                nextStatusMessage =
                    "설정 도우미가 공식 문서 또는 redacted cURL 증거를 더 요청했습니다."
            case let .reviewDraft(review):
                guard review.draft.manifest.schemaVersion > 0,
                      !review.draft.summary.isEmpty
                else {
                    throw CoreClientFailure.invalidResponse(
                        "설정 도우미의 typed draft 검토 결과가 비어 있습니다."
                    )
                }
                nextStatusMessage =
                    "설정 도우미 초안을 검토한 뒤 채택하거나 수정을 요청하세요."
            }
            let reconciliation =
                await reconcileDiscoverySessionIgnoringCallerCancellation(
                    sessionID: snapshot.id,
                    expectedConnectionID:
                        snapshot.pendingConnectionID,
                    expectedOperationGeneration:
                        expectedOperationGeneration
                )
            guard reconciliation == .success,
                  discoveryContextOwns(
                      sessionID: snapshot.id,
                      connectionID:
                          snapshot.pendingConnectionID,
                      expectedOperationGeneration:
                          expectedOperationGeneration
                  ),
                  let durable = discovery,
                  durable.revision > snapshot.revision,
                  assistantHostAction == action
            else {
                if reconciliation == .superseded {
                    throw CancellationError()
                }
                throw CoreClientFailure.invalidResponse(
                    "설정 도우미 실행 후 durable 탐색 상태를 확인하지 못했습니다."
                )
            }
            if Task.isCancelled {
                statusMessage =
                    "설정 도우미 작업은 진행됐지만 완료 응답 처리가 취소돼 durable 상태를 다시 확인했습니다."
                throw CancellationError()
            }
            statusMessage = nextStatusMessage
        } catch {
            if didInvokeAssistant {
                let reconciliation =
                    await reconcileDiscoverySessionIgnoringCallerCancellation(
                        sessionID: snapshot.id,
                        expectedConnectionID:
                            snapshot.pendingConnectionID,
                        expectedOperationGeneration:
                            expectedOperationGeneration
                    )
                if reconciliation == .success,
                   discoveryContextOwns(
                       sessionID: snapshot.id,
                       connectionID:
                           snapshot.pendingConnectionID,
                       expectedOperationGeneration:
                           expectedOperationGeneration
                   ),
                   (discovery?.revision ?? 0) > snapshot.revision
                {
                    statusMessage =
                        "설정 도우미 작업은 진행됐지만 완료 응답을 처리하지 못해 durable 상태를 다시 확인했습니다."
                } else if reconciliation == .failed,
                          discoveryContextOwns(
                              sessionID: snapshot.id,
                              connectionID:
                                  snapshot.pendingConnectionID,
                              expectedOperationGeneration:
                                  expectedOperationGeneration
                          )
                {
                    statusMessage =
                        "설정 도우미 실행 결과를 확인하지 못했습니다. 새로고침하세요."
                }
            }
            throw error
        }
    }

    private func assistantCredential(
        for snapshot: ProviderDiscoverySnapshot
    ) async throws -> String? {
        let assistantRouteID: String
        if case let .assistantConsent(consent) =
            snapshot.actionRequired
        {
            assistantRouteID = consent.assistantModelRouteID
        } else if let binding =
            snapshot.assistantApprovalBinding
        {
            assistantRouteID =
                binding.assistantModelRouteID
        } else {
            throw CoreClientFailure.invalidResponse(
                "승인된 설정 도우미 모델 경로가 탐색 snapshot에 없습니다."
            )
        }
        guard activeGenerationTarget?.modelRouteID
            == assistantRouteID
        else {
            throw CoreClientFailure.configurationRequired(
                "승인한 문서 분석 모델이 현재 앱 기본 모델과 다릅니다. 탐색 상태를 새로고침하세요."
            )
        }

        for connection in connections {
            let routes = try await client.listProviderModelRoutes(
                connectionID: connection.id
            )
            if routes.contains(where: {
                $0.id == assistantRouteID
            }) {
                let credential =
                    try await credentialStore.credential(
                        for: connection.id
                    )
                return try validatedDiscoveryCredential(
                    credential
                )
            }
        }
        throw CoreClientFailure.invalidResponse(
            "문서 분석 모델 경로에 연결된 Keychain 슬롯을 찾지 못했습니다."
        )
    }

    private func refreshDiscoveryAfterAssistantFailure(
        sessionID: String,
        expectedOperationGeneration: UInt64
    ) async {
        guard var snapshot = try? await client.getProviderDiscovery(
            sessionID: sessionID
        ), discoveryContextIsCurrent(
            sessionID: sessionID,
            connectionID:
                discovery?.pendingConnectionID
                    ?? snapshot.pendingConnectionID,
            expectedOperationGeneration:
                expectedOperationGeneration
        )
        else {
            return
        }
#if DEBUG
        snapshot =
            discoverySnapshotTransformForTesting?(snapshot)
                ?? snapshot
#endif
        guard (try? validateDiscoverySnapshot(
            snapshot,
            expectedConnectionID:
                discovery?.pendingConnectionID
                    ?? snapshot.pendingConnectionID,
            expectedSessionID: sessionID
        )) != nil else {
            return
        }
        _ = applyDiscoverySnapshot(
            snapshot,
            expectedSessionID: sessionID,
            expectedConnectionID:
                snapshot.pendingConnectionID,
            expectedOperationGeneration:
                expectedOperationGeneration
        )
    }

    private func restoreModelSync(
        for connectionID: String,
        expectedConnectionSelectionGeneration: UInt64,
        expectedRefreshGeneration: UInt64?
    ) async -> MutationRefreshOutcome {
        let operationGeneration = modelSyncOperationGeneration
        do {
            let jobs = try await client.listProviderModelSyncs(
                connectionID: connectionID,
                limit: 20
            )
#if DEBUG
            try await modelSyncRestoreFailureHookForTesting?()
#endif
            guard selectedConnectionID == connectionID,
                  expectedConnectionSelectionGeneration
                    == connectionSelectionGeneration,
                  refreshGenerationIsCurrent(
                      expectedRefreshGeneration
                  )
            else {
                return .superseded
            }
            guard let restorable = jobs.first(where: {
                !$0.state.isTerminal
            }) else {
                if modelSyncOperationContextIsCurrent(
                    connectionID: connectionID,
                    expectedConnectionSelectionGeneration:
                        expectedConnectionSelectionGeneration,
                    expectedRefreshGeneration:
                        expectedRefreshGeneration,
                    expectedOperationGeneration:
                        operationGeneration
                ) {
                    modelSyncJob = nil
                    modelSyncEventMessageKey = nil
                    return .success
                }
                return .superseded
            }
            try validateStartedModelSyncJob(
                restorable,
                expectedConnectionID: connectionID
            )
            guard applyModelSyncJob(
                restorable,
                expectedConnectionID: connectionID,
                expectedConnectionSelectionGeneration:
                    expectedConnectionSelectionGeneration,
                expectedRefreshGeneration:
                    expectedRefreshGeneration,
                expectedOperationGeneration:
                    operationGeneration,
                expectedJobID: nil,
                allowsNewJob: true
            ) else {
                return .superseded
            }
            let eventOutcome = await consumeModelSyncEvents(
                jobID: restorable.id,
                expectedConnectionID: connectionID,
                expectedConnectionSelectionGeneration:
                    expectedConnectionSelectionGeneration,
                expectedRefreshGeneration:
                    expectedRefreshGeneration,
                expectedOperationGeneration:
                    operationGeneration
            )
            guard eventOutcome == .success else {
                return eventOutcome
            }
            guard modelSyncContextIsCurrent(
                jobID: restorable.id,
                expectedConnectionID: connectionID,
                expectedConnectionSelectionGeneration:
                    expectedConnectionSelectionGeneration,
                expectedRefreshGeneration:
                    expectedRefreshGeneration,
                expectedOperationGeneration:
                    operationGeneration
            ) else {
                return .superseded
            }
            if modelSyncJob?.state.isTerminal == false {
                startModelSyncMonitor(
                    jobID: restorable.id,
                    connectionID: connectionID,
                    expectedConnectionSelectionGeneration:
                        expectedConnectionSelectionGeneration,
                    expectedRefreshGeneration:
                        expectedRefreshGeneration,
                    expectedOperationGeneration:
                        operationGeneration
                )
            }
            return .success
        } catch is CancellationError {
            return .superseded
        } catch {
            guard selectedConnectionID == connectionID,
                  expectedConnectionSelectionGeneration
                    == connectionSelectionGeneration,
                  refreshGenerationIsCurrent(
                      expectedRefreshGeneration
                  ),
                  modelSyncOperationGeneration
                    == operationGeneration
            else {
                return .superseded
            }
            errorMessage = safeFailureMessage(
                action: "진행 중인 모델 동기화를 복구하지",
                error: error
            )
            return .failed
        }
    }

    @discardableResult
    private func consumeModelSyncEvents(
        jobID: String,
        expectedConnectionID: String? = nil,
        expectedConnectionSelectionGeneration: UInt64? = nil,
        expectedRefreshGeneration: UInt64? = nil,
        expectedOperationGeneration: UInt64? = nil
    ) async -> MutationRefreshOutcome {
        guard modelSyncContextIsCurrent(
            jobID: jobID,
            expectedConnectionID: expectedConnectionID,
            expectedConnectionSelectionGeneration:
                expectedConnectionSelectionGeneration,
            expectedRefreshGeneration:
                expectedRefreshGeneration,
            expectedOperationGeneration:
                expectedOperationGeneration
        ), !modelSyncEventConsumers.contains(jobID)
        else {
            return .superseded
        }
        modelSyncEventConsumers.insert(jobID)
        defer {
            modelSyncEventConsumers.remove(jobID)
        }

        do {
            let events = try await client.pollProviderModelSyncEvents(
                jobID: jobID,
                limit: 64
            ).sorted {
                $0.sequence < $1.sequence
            }
#if DEBUG
            try await modelSyncEventPollHookForTesting?()
#endif
            guard modelSyncContextIsCurrent(
                jobID: jobID,
                expectedConnectionID: expectedConnectionID,
                expectedConnectionSelectionGeneration:
                    expectedConnectionSelectionGeneration,
                expectedRefreshGeneration:
                    expectedRefreshGeneration,
                expectedOperationGeneration:
                    expectedOperationGeneration
            ) else {
                return .superseded
            }
            for event in events {
                guard modelSyncContextIsCurrent(
                    jobID: jobID,
                    expectedConnectionID: expectedConnectionID,
                    expectedConnectionSelectionGeneration:
                        expectedConnectionSelectionGeneration,
                    expectedRefreshGeneration:
                        expectedRefreshGeneration,
                    expectedOperationGeneration:
                        expectedOperationGeneration
                ) else {
                    return .superseded
                }
                try CoreRuntimeContract
                    .validateProviderModelSyncEventVersions(
                        version: event.version,
                        redactionVersion: event.redactionVersion
                    )
                guard event.jobID == jobID
                else {
                    throw CoreClientFailure.invalidResponse(
                        "다른 작업의 모델 동기화 이벤트를 현재 작업에 적용하지 않습니다."
                    )
                }
                let snapshot = try await client.getProviderModelSync(
                    jobID: jobID
                )
#if DEBUG
                await modelSyncEventSnapshotCommitHookForTesting?()
#endif
                guard modelSyncContextIsCurrent(
                    jobID: jobID,
                    expectedConnectionID: expectedConnectionID,
                    expectedConnectionSelectionGeneration:
                        expectedConnectionSelectionGeneration,
                    expectedRefreshGeneration:
                        expectedRefreshGeneration,
                    expectedOperationGeneration:
                        expectedOperationGeneration
                ) else {
                    return .superseded
                }
                guard snapshot.id == jobID,
                      snapshot.revision >= event.jobRevision
                else {
                    throw CoreClientFailure.invalidResponse(
                        "모델 동기화 이벤트와 작업 상태가 일치하지 않습니다."
                    )
                }
                if snapshot.revision == event.jobRevision,
                   snapshot.state != event.state
                {
                    throw CoreClientFailure.invalidResponse(
                        "모델 동기화 이벤트 상태가 현재 revision과 일치하지 않습니다."
                    )
                }
                guard selectedConnectionID == snapshot.connectionID,
                      modelSyncJob?.id == jobID,
                      snapshot.revision
                        >= (modelSyncJob?.revision ?? 0)
                else {
                    // Leave the event unacknowledged for the exact job's
                    // eventual consumer. Never drain another job globally.
                    return .superseded
                }

                let eventIsCurrent =
                    snapshot.revision == event.jobRevision
                let applied = ProviderModelSyncJob(
                    id: snapshot.id,
                    connectionID: snapshot.connectionID,
                    state: eventIsCurrent
                        ? event.state
                        : snapshot.state,
                    revision: snapshot.revision,
                    completedSteps: eventIsCurrent
                        ? event.completedSteps
                        : snapshot.completedSteps,
                    totalSteps: eventIsCurrent
                        ? event.totalSteps
                        : snapshot.totalSteps,
                    reviewSHA256:
                        snapshot.reviewSHA256
                        ?? event.reviewSHA256,
                    diff: snapshot.diff,
                    failureMessageKey:
                        snapshot.failureMessageKey
                        ?? event.failureMessageKey,
                    updatedAt: snapshot.updatedAt
                )
                guard applyModelSyncJob(
                    applied,
                    expectedConnectionID:
                        expectedConnectionID
                            ?? snapshot.connectionID,
                    expectedConnectionSelectionGeneration:
                        expectedConnectionSelectionGeneration,
                    expectedRefreshGeneration:
                        expectedRefreshGeneration,
                    expectedOperationGeneration:
                        expectedOperationGeneration,
                    expectedJobID: jobID,
                    allowsNewJob: false
                ) else {
                    return .superseded
                }
                modelSyncEventMessageKey = event.messageKey

                _ = try await client.ackProviderModelSyncEvent(
                    jobID: jobID,
                    sequence: event.sequence
                )
                guard modelSyncContextIsCurrent(
                    jobID: jobID,
                    expectedConnectionID: expectedConnectionID,
                    expectedConnectionSelectionGeneration:
                        expectedConnectionSelectionGeneration,
                    expectedRefreshGeneration:
                        expectedRefreshGeneration,
                    expectedOperationGeneration:
                        expectedOperationGeneration
                ) else {
                    return .superseded
                }
            }
            if modelSyncJob?.id == jobID,
               modelSyncJob?.state.isTerminal == true
            {
                stopModelSyncMonitor()
            }
            return .success
        } catch is CancellationError {
            return .superseded
        } catch {
            guard modelSyncContextIsCurrent(
                jobID: jobID,
                expectedConnectionID: expectedConnectionID,
                expectedConnectionSelectionGeneration:
                    expectedConnectionSelectionGeneration,
                expectedRefreshGeneration:
                    expectedRefreshGeneration,
                expectedOperationGeneration:
                    expectedOperationGeneration
            ) else {
                return .superseded
            }
            errorMessage = safeFailureMessage(
                action: "모델 동기화 진행 이벤트를 처리하지",
                error: error
            )
            return .failed
        }
    }

    private func startModelSyncMonitor(
        jobID: String,
        connectionID: String? = nil,
        expectedConnectionSelectionGeneration: UInt64? = nil,
        expectedRefreshGeneration: UInt64? = nil,
        expectedOperationGeneration: UInt64? = nil
    ) {
        guard let boundConnectionID =
            connectionID ?? selectedConnectionID
        else {
            return
        }
        let boundSelectionGeneration =
            expectedConnectionSelectionGeneration
            ?? connectionSelectionGeneration
        stopModelSyncMonitor()
        modelSyncMonitorTask = Task { [weak self] in
            guard let self else {
                return
            }
            while !Task.isCancelled {
                await self.consumeModelSyncEvents(
                    jobID: jobID,
                    expectedConnectionID: boundConnectionID,
                    expectedConnectionSelectionGeneration:
                        boundSelectionGeneration,
                    expectedRefreshGeneration:
                        expectedRefreshGeneration,
                    expectedOperationGeneration:
                        expectedOperationGeneration
                )
                guard self.modelSyncContextIsCurrent(
                          jobID: jobID,
                          expectedConnectionID: boundConnectionID,
                          expectedConnectionSelectionGeneration:
                              boundSelectionGeneration,
                          expectedRefreshGeneration:
                              expectedRefreshGeneration,
                          expectedOperationGeneration:
                              expectedOperationGeneration
                      ),
                      self.modelSyncJob?.state.isTerminal == false
                else {
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(800))
                } catch {
                    return
                }
            }
        }
    }

    private func stopModelSyncMonitor() {
        modelSyncMonitorTask?.cancel()
        modelSyncMonitorTask = nil
    }

    private func editPreset(
        _ preset: ProviderGenerationPreset,
        invalidatesPreview: Bool = true
    ) {
        if invalidatesPreview {
            invalidateRequestPreview()
        }
        draftPresetID = preset.id
        draftPresetCreatedAt = preset.createdAt
        presetName = preset.displayName
        parameterValues = Dictionary(
            uniqueKeysWithValues: preset.values.map {
                ($0.parameterID, $0.state)
            }
        )
        for spec in visibleParameterSpecs where
            parameterValues[spec.id] == nil
        {
            parameterValues[spec.id] = defaultValueState(for: spec)
        }
        reasoningMode = preset.reasoningMode
        reasoningEffort = preset.reasoningEffort ?? ""
        reasoningBudgetTokens = preset.reasoningBudgetTokens.map(String.init)
            ?? ""
        reasoningSummary = preset.reasoningSummary
        preservesOpaqueReasoningState =
            selectedConnection?.hasCredential == true
                ? false
                : preset.preservesOpaqueReasoningState
        promptCacheMode = preset.promptCacheMode
        promptCacheTTL = preset.promptCacheTTL
        promptCacheCustomTTLSeconds =
            preset.promptCacheCustomTTLSeconds.map(String.init) ?? ""
        promptCacheContextReference =
            preset.promptCacheContextReference ?? ""
    }

    private var selectedGenerationHierarchyIsValid: Bool {
        guard !isSelectionLoading,
              let connection = selectedConnection,
              let route = selectedModelRoute,
              route.connectionID == connection.id,
              let preset = selectedPreset,
              preset.modelRouteID == route.id
        else {
            return false
        }
        return true
    }

    private func invalidateConnectionHierarchy(
        clearsModelSync: Bool = true
    ) {
        modelRouteSelectionGeneration &+= 1
        modelSyncOperationGeneration &+= 1
        stopModelSyncMonitor()
        if clearsModelSync {
            modelSyncJob = nil
            modelSyncEventMessageKey = nil
        }
        modelRoutes = []
        selectedModelRouteID = nil
        invalidateModelRouteHierarchy()
    }

    private func invalidateModelRouteHierarchy() {
        presetControlRefreshTask?.cancel()
        presetControlRefreshTask = nil
        presets = []
        selectedPresetID = nil
        capabilities = []
        routeParameterSpecs = nil
        invalidateRequestPreview()
        clearRenderedPresetControls()
        clearPresetEditor()
    }

    private func clearPresetEditor() {
        draftPresetID = UUID().uuidString.lowercased()
        draftPresetCreatedAt =
            ISO8601DateFormatter().string(from: Date())
        presetName = ""
        parameterValues = [:]
        reasoningMode = "provider_default"
        reasoningEffort = ""
        reasoningBudgetTokens = ""
        reasoningSummary = "provider_default"
        preservesOpaqueReasoningState = false
        promptCacheMode = "provider_default"
        promptCacheTTL = "provider_default"
        promptCacheCustomTTLSeconds = ""
        promptCacheContextReference = ""
    }

    private func selectionContext(
        connectionID: String,
        modelRouteID: String?,
        presetID: String?,
        previewGeneration: UInt64? = nil
    ) -> SelectionContext {
        SelectionContext(
            connectionID: connectionID,
            modelRouteID: modelRouteID,
            presetID: presetID,
            connectionGeneration:
                connectionSelectionGeneration,
            routeGeneration: modelRouteSelectionGeneration,
            refreshGeneration: refreshGeneration,
            previewGeneration:
                previewGeneration ?? requestPreviewGeneration
        )
    }

    private func connectionHierarchyOwner()
        -> ConnectionHierarchyOwner
    {
        ConnectionHierarchyOwner(
            refreshGeneration: refreshGeneration,
            selectionGeneration: connectionSelectionGeneration,
            selectedConnectionID: selectedConnectionID
        )
    }

    private func connectionHierarchyOwnerIsCurrent(
        _ owner: ConnectionHierarchyOwner
    ) -> Bool {
        refreshGeneration == owner.refreshGeneration
            && connectionSelectionGeneration
                == owner.selectionGeneration
            && selectedConnectionID == owner.selectedConnectionID
    }

    private func connectionHydrationResult(
        _ outcome: MutationRefreshOutcome
    ) -> ConnectionHydrationResult {
        ConnectionHydrationResult(
            outcome: outcome,
            owner: ConnectionHydrationOwner(
                hierarchyOwner: connectionHierarchyOwner(),
                routeSelectionGeneration:
                    modelRouteSelectionGeneration,
                selectedModelRouteID: selectedModelRouteID
            )
        )
    }

    private func connectionHydrationOwnerIsCurrent(
        _ owner: ConnectionHydrationOwner
    ) -> Bool {
        connectionHierarchyOwnerIsCurrent(
            owner.hierarchyOwner
        )
            && modelRouteSelectionGeneration
                == owner.routeSelectionGeneration
            && selectedModelRouteID == owner.selectedModelRouteID
    }

    private func connectionSelectionContextIsCurrent(
        _ context: SelectionContext
    ) -> Bool {
        !Task.isCancelled
            && connectionSelectionContextOwnsHierarchy(context)
    }

    private func connectionSelectionContextOwnsHierarchy(
        _ context: SelectionContext
    ) -> Bool {
        refreshGeneration == context.refreshGeneration
            && connectionSelectionGeneration
                == context.connectionGeneration
            && selectedConnectionID == context.connectionID
            && selectedConnection?.id == context.connectionID
    }

    private func selectionContextIsCurrent(
        _ context: SelectionContext
    ) -> Bool {
        !Task.isCancelled
            && selectionContextOwnsHierarchy(context)
    }

    private func selectionContextOwnsHierarchy(
        _ context: SelectionContext
    ) -> Bool {
        guard modelRouteSelectionContextOwnsHierarchy(context),
              requestPreviewGeneration
                == context.previewGeneration,
              selectedPresetID == context.presetID
        else {
            return false
        }
        if let presetID = context.presetID {
            guard let modelRouteID = context.modelRouteID,
                  presets.contains(where: {
                      $0.id == presetID
                          && $0.modelRouteID == modelRouteID
                  })
            else {
                return false
            }
        }
        return true
    }

    private func modelRouteSelectionContextOwnsHierarchy(
        _ context: SelectionContext
    ) -> Bool {
        guard connectionSelectionContextOwnsHierarchy(context),
              !isSelectionLoading,
              modelRouteSelectionGeneration
                == context.routeGeneration,
              selectedModelRouteID == context.modelRouteID
        else {
            return false
        }
        if let modelRouteID = context.modelRouteID {
            return modelRoutes.contains {
                $0.id == modelRouteID
                    && $0.connectionID == context.connectionID
            }
        }
        return true
    }

    private func presetCandidateIsCurrent(
        _ candidate: ProviderGenerationPreset,
        updatedAt: String,
        context: SelectionContext
    ) -> Bool {
        !Task.isCancelled
            && presetCandidateIsOwnedByHierarchy(
                candidate,
                updatedAt: updatedAt,
                context: context
            )
    }

    private func presetCandidateIsOwnedByHierarchy(
        _ candidate: ProviderGenerationPreset,
        updatedAt: String,
        context: SelectionContext
    ) -> Bool {
        selectionContextOwnsHierarchy(context)
            && candidate.modelRouteID == context.modelRouteID
            && makePresetCandidate(updatedAt: updatedAt)
                == candidate
    }

    private func presetEditorOwnsCandidate(
        _ candidate: ProviderGenerationPreset,
        editorGeneration: UInt64,
        context: SelectionContext
    ) -> Bool {
        presetEditorGeneration == editorGeneration
            && presetCandidateIsOwnedByHierarchy(
                candidate,
                updatedAt: candidate.updatedAt,
                context: context
            )
    }

    private func presetPersistedContentMatches(
        _ lhs: ProviderGenerationPreset,
        _ rhs: ProviderGenerationPreset
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.modelRouteID == rhs.modelRouteID
            && lhs.displayName == rhs.displayName
            && lhs.values == rhs.values
            && lhs.reasoningMode == rhs.reasoningMode
            && lhs.reasoningEffort == rhs.reasoningEffort
            && lhs.reasoningBudgetTokens
                == rhs.reasoningBudgetTokens
            && lhs.reasoningSummary == rhs.reasoningSummary
            && lhs.preservesOpaqueReasoningState
                == rhs.preservesOpaqueReasoningState
            && lhs.promptCacheMode == rhs.promptCacheMode
            && lhs.promptCacheTTL == rhs.promptCacheTTL
            && lhs.promptCacheCustomTTLSeconds
                == rhs.promptCacheCustomTTLSeconds
            && lhs.promptCacheContextReference
                == rhs.promptCacheContextReference
            && lhs.createdAt == rhs.createdAt
    }

    @discardableResult
    private func beginRequestPreviewOperation() -> UInt64 {
        presetControlRefreshTask?.cancel()
        presetControlRefreshTask = nil
        requestPreviewGeneration &+= 1
        requestPreview = nil
        previewedPresetCandidate = nil
        return requestPreviewGeneration
    }

    private func invalidateRequestPreview() {
        _ = beginRequestPreviewOperation()
    }

    private func requestPreviewContextIsCurrent(
        connectionID: String,
        modelRouteID: String,
        presetID: String?,
        connectionSelectionGeneration expectedConnectionGeneration:
            UInt64,
        modelRouteSelectionGeneration expectedRouteGeneration:
            UInt64,
        refreshGeneration expectedRefreshGeneration: UInt64,
        requestPreviewGeneration expectedPreviewGeneration: UInt64
    ) -> Bool {
        guard !Task.isCancelled,
              !isSelectionLoading,
              refreshGeneration == expectedRefreshGeneration,
              connectionSelectionGeneration
                == expectedConnectionGeneration,
              modelRouteSelectionGeneration
                == expectedRouteGeneration,
              requestPreviewGeneration == expectedPreviewGeneration,
              selectedConnectionID == connectionID,
              selectedModelRouteID == modelRouteID,
              selectedPresetID == presetID,
              let connection = selectedConnection,
              let route = selectedModelRoute,
              route.connectionID == connection.id
        else {
            return false
        }
        if let presetID {
            return presets.contains {
                $0.id == presetID
                    && $0.modelRouteID == modelRouteID
            }
        }
        return true
    }

    private func validateModelRoutes(
        _ routes: [ProviderModelRoute],
        expectedConnectionID: String
    ) throws {
        guard routes.allSatisfy({
            $0.connectionID == expectedConnectionID
        }), Set(routes.map(\.id)).count == routes.count
        else {
            throw CoreClientFailure.invalidResponse(
                "모델 목록에 다른 연결의 경로 또는 중복 ID가 포함되어 있습니다."
            )
        }
    }

    private func validateGenerationPresets(
        _ presets: [ProviderGenerationPreset],
        expectedModelRouteID: String
    ) throws {
        guard presets.allSatisfy({
            $0.modelRouteID == expectedModelRouteID
        }), Set(presets.map(\.id)).count == presets.count
        else {
            throw CoreClientFailure.invalidResponse(
                "프리셋 목록에 다른 모델 경로의 항목 또는 중복 ID가 포함되어 있습니다."
            )
        }
    }

    private func makePresetCandidate(
        updatedAt: String
    ) -> ProviderGenerationPreset? {
        guard let route = selectedModelRoute,
              let normalizedName = normalizedNonempty(presetName)
        else {
            return nil
        }
        return ProviderGenerationPreset(
            id: draftPresetID,
            modelRouteID: route.id,
            displayName: normalizedName,
            values: allParameterSpecs.map { spec in
                ProviderParameterValue(
                    parameterID: spec.id,
                    state: parameterValues[spec.id]
                        ?? defaultValueState(for: spec)
                )
            },
            reasoningMode: reasoningMode,
            reasoningEffort: normalizedNonempty(reasoningEffort),
            reasoningBudgetTokens: UInt32(reasoningBudgetTokens),
            reasoningSummary: reasoningSummary,
            preservesOpaqueReasoningState:
                preservesOpaqueReasoningState
                && selectedConnection?.hasCredential != true
                && reasoningControl?.preservesOpaqueState == true,
            promptCacheMode: promptCacheMode,
            promptCacheTTL: promptCacheTTL,
            promptCacheCustomTTLSeconds:
                UInt32(promptCacheCustomTTLSeconds),
            promptCacheContextReference:
                normalizedNonempty(promptCacheContextReference),
            createdAt: draftPresetCreatedAt,
            updatedAt: updatedAt
        )
    }

    private func canonicalRenderedEnabledEffort(
        from control: ProviderReasoningControl,
        for candidate: ProviderGenerationPreset
    ) -> String? {
        guard candidate.reasoningMode == "enabled",
              candidate.reasoningEffort == nil,
              control.mode == "enabled",
              control.state == .ready,
              control.effortField.isVisible,
              let renderedEffort = control.effort,
              let effort = normalizedNonempty(renderedEffort),
              control.allowedEfforts.contains(effort)
        else {
            return nil
        }
        return effort
    }

    private func presetCandidateByAdoptingRenderedEffort(
        _ candidate: ProviderGenerationPreset,
        context: SelectionContext
    ) async throws -> NormalizedPresetCandidate {
        let rendered = try await client.renderProviderReasoningControl(
            for: candidate
        )
#if DEBUG
        await presetNormalizationCommitHookForTesting?()
#endif
        try Task.checkCancellation()
        guard presetCandidateIsCurrent(
            candidate,
            updatedAt: candidate.updatedAt,
            context: context
        )
        else {
            throw CancellationError()
        }
        guard let effort = canonicalRenderedEnabledEffort(
            from: rendered,
            for: candidate
        ) else {
            return NormalizedPresetCandidate(
                preset: candidate,
                reasoningControl: rendered
            )
        }

        let normalized = preset(
            candidate,
            replacingReasoningEffort: effort
        )
        let verified = try await client.renderProviderReasoningControl(
            for: normalized
        )
        try Task.checkCancellation()
        guard presetCandidateIsCurrent(
                  candidate,
                  updatedAt: candidate.updatedAt,
                  context: context
              ),
              verified.mode == normalized.reasoningMode,
              verified.effort == normalized.reasoningEffort,
              verified.state != .invalid
        else {
            throw CoreClientFailure.invalidResponse(
                "Core 추론 기본값이 한 번의 재검증으로 수렴하지 않았습니다."
            )
        }
        return NormalizedPresetCandidate(
            preset: normalized,
            reasoningControl: verified
        )
    }

    private func preset(
        _ candidate: ProviderGenerationPreset,
        replacingReasoningEffort effort: String
    ) -> ProviderGenerationPreset {
        ProviderGenerationPreset(
            id: candidate.id,
            modelRouteID: candidate.modelRouteID,
            displayName: candidate.displayName,
            values: candidate.values,
            reasoningMode: candidate.reasoningMode,
            reasoningEffort: effort,
            reasoningBudgetTokens:
                candidate.reasoningBudgetTokens,
            reasoningSummary: candidate.reasoningSummary,
            preservesOpaqueReasoningState:
                candidate.preservesOpaqueReasoningState,
            promptCacheMode: candidate.promptCacheMode,
            promptCacheTTL: candidate.promptCacheTTL,
            promptCacheCustomTTLSeconds:
                candidate.promptCacheCustomTTLSeconds,
            promptCacheContextReference:
                candidate.promptCacheContextReference,
            createdAt: candidate.createdAt,
            updatedAt: candidate.updatedAt
        )
    }

    private func applyPresetNormalization(
        _ normalized: NormalizedPresetCandidate
    ) {
        if reasoningEffort
            != (normalized.preset.reasoningEffort ?? "")
        {
            reasoningEffort =
                normalized.preset.reasoningEffort ?? ""
            presetControlRenderGeneration &+= 1
        }
        reasoningControl = normalized.reasoningControl
        promptCacheControl = nil
        renderedPresetControlCandidate = normalized.preset
    }

    private func parameterIsVisible(
        _ spec: ProviderParameterSpec
    ) -> Bool {
        guard let condition = spec.visibility,
              let actual = explicitLiteral(
                  for: condition.parameterID
              )
        else {
            return spec.visibility == nil
        }
        switch condition.conditionOperator {
        case .equals:
            return actual == condition.value
        case .notEquals:
            return actual != condition.value
        }
    }

    private func explicitLiteral(
        for parameterID: String
    ) -> ProviderParameterLiteral? {
        guard let state = parameterValues[parameterID],
              case let .explicit(value) = state
        else {
            return nil
        }
        return value
    }

    private func normalizeHiddenParameterValues() {
        for spec in allParameterSpecs where !parameterIsVisible(spec) {
            parameterValues[spec.id] = .providerDefault
        }
    }

    private func defaultValueState(
        for spec: ProviderParameterSpec
    ) -> ProviderParameterValueState {
        switch spec.defaultMode {
        case .providerDefault:
            .providerDefault
        case .explicitRequired:
            initialExplicitValue(for: spec)
        }
    }

    private func initialExplicitValue(
        for spec: ProviderParameterSpec
    ) -> ProviderParameterValueState {
        if let first = spec.choices.first {
            return .explicit(first.value)
        }
        switch spec.type {
        case .boolean:
            return .explicit(.boolean(false))
        case .integer:
            return .explicit(.integer(Int64(spec.minimum ?? 0)))
        case .number:
            return .explicit(.number(spec.minimum ?? 0))
        case .enumeration:
            return .explicit(.enumeration(""))
        case .string:
            return .explicit(.string(""))
        case .stringList:
            return .explicit(.stringList([]))
        case .jsonSchema:
            return .explicit(.jsonSchema("{}"))
        case .stopSequenceList:
            return .explicit(.stopSequenceList([]))
        case .toolPolicy:
            return .explicit(.toolPolicy("none"))
        }
    }

    private func restoreCredentialData(
        _ credential: Data?,
        connectionID: String
    ) async -> Bool {
        let credentialStore = credentialStore
        return await Task.detached {
            do {
                try await credentialStore.setCredentialData(
                    credential,
                    for: connectionID
                )
                return try await credentialStore.credentialData(
                    for: connectionID
                ) == credential
            } catch {
                return false
            }
        }.value
    }

    private func stageDiscoveryCredentialData(
        _ credential: inout Data,
        connectionID: String,
        expectedOperationGeneration: UInt64? = nil
    ) async throws {
        defer {
            credential.resetBytes(in: 0 ..< credential.count)
        }
        try requireNewDiscoveryConnectionID(connectionID)
        guard !credential.isEmpty else {
            throw CredentialStoreError.invalidEncoding
        }
        guard
            credential.count
                <= CredentialStorePolicy.maximumCredentialUTF8Bytes
        else {
            throw CredentialStoreError.credentialTooLarge
        }

        if let expectedOperationGeneration,
           !discoveryDraftOperationIsCurrent(
               expectedOperationGeneration,
               connectionID: connectionID
           )
        {
            throw CancellationError()
        }
        stagedDiscoveryConnectionID = connectionID
        hasStagedDiscoveryCredential = true
        try await credentialStore.setCredentialData(
            credential,
            for: connectionID
        )
#if DEBUG
        await discoveryCredentialStageCommitHookForTesting?()
#endif
        try Task.checkCancellation()
        guard try await credentialStore.credentialData(
            for: connectionID
        ) == credential else {
            throw CredentialStoreError.verificationFailed
        }
        try Task.checkCancellation()
    }

    private func requireNewDiscoveryConnectionID(
        _ connectionID: String
    ) throws {
        guard !connections.contains(where: {
            $0.id == connectionID
        }) else {
            throw CoreClientFailure.configurationRequired(
                "기존 연결의 API 키나 설정은 변경할 수 없습니다. 새 AI 연결을 만들어 별도의 연결, 모델 경로와 프리셋을 사용하세요."
            )
        }
    }

    private func clearStagedDiscoveryCredential(
        expectedRefreshGeneration: UInt64? = nil,
        expectedDiscoveryOperationGeneration: UInt64? = nil,
        expectedConnectionID: String? = nil
    ) async throws {
        guard refreshGenerationIsCurrent(
            expectedRefreshGeneration
        ) else {
            return
        }
        if let expectedDiscoveryOperationGeneration,
           discoveryOperationGeneration
               != expectedDiscoveryOperationGeneration
        {
            return
        }
        guard let connectionID = stagedDiscoveryConnectionID else {
            if expectedConnectionID == nil {
                hasStagedDiscoveryCredential = false
            }
            return
        }
        if let expectedConnectionID,
           connectionID != expectedConnectionID
        {
            return
        }
        hasStagedDiscoveryCredential = true
        let credentialStore = credentialStore
        let deleted = try await Task.detached {
            try await credentialStore.deleteCredential(
                for: connectionID
            )
            return try await credentialStore.credentialData(
                for: connectionID
            ) == nil
        }.value
        guard deleted else {
            throw CredentialStoreError.verificationFailed
        }
        guard refreshGenerationIsCurrent(
            expectedRefreshGeneration
        ) else {
            return
        }
        if let expectedDiscoveryOperationGeneration,
           discoveryOperationGeneration
               != expectedDiscoveryOperationGeneration
        {
            return
        }
        guard stagedDiscoveryConnectionID == connectionID else {
            return
        }
        hasStagedDiscoveryCredential = false
        stagedDiscoveryConnectionID = nil
    }

    private func clearDiscoveryCredentialAfterFailure(
        expectedOperationGeneration: UInt64? = nil,
        expectedConnectionID: String? = nil
    ) async -> Bool {
        do {
            try await clearStagedDiscoveryCredential(
                expectedDiscoveryOperationGeneration:
                    expectedOperationGeneration,
                expectedConnectionID: expectedConnectionID
            )
            return true
        } catch {
            return false
        }
    }

    private func cleanupCancelledDiscoveryStart(
        snapshot: ProviderDiscoverySnapshot?,
        connectionID: String,
        operationGeneration: UInt64
    ) async {
        if let snapshot,
           snapshot.pendingConnectionID == connectionID,
           !snapshot.state.isTerminal
        {
            let client = client
            _ = try? await Task.detached {
                try await client.cancelProviderDiscovery(
                    sessionID: snapshot.id,
                    expectedRevision: snapshot.revision
                )
            }.value
        }
        _ = await clearDiscoveryCredentialAfterFailure(
            expectedOperationGeneration: operationGeneration,
            expectedConnectionID: connectionID
        )
    }

    private func credentialSlotIsReady(
        for snapshot: ProviderDiscoverySnapshot
    ) async throws -> Bool {
        if snapshot.credentialSlotExpected {
            guard snapshot.credentialSlotID
                == snapshot.pendingConnectionID
            else {
                throw CoreClientFailure.invalidResponse(
                    "Core가 현재 탐색과 다른 Keychain 슬롯을 확인하려고 했습니다."
                )
            }
            guard stagedDiscoveryConnectionID
                == snapshot.pendingConnectionID,
                hasStagedDiscoveryCredential
            else {
                return false
            }
            return try await credentialStore.credentialData(
                for: snapshot.pendingConnectionID
            ) != nil
        }
        guard snapshot.credentialSlotID == nil,
              stagedDiscoveryConnectionID == nil,
              !hasStagedDiscoveryCredential
        else {
            throw CoreClientFailure.invalidResponse(
                "자격증명이 필요 없는 연결에 Keychain 슬롯이 연결되었습니다."
            )
        }
        return false
    }

    private func requestScopedTargetCredential(
        for action: ProviderDiscoveryAction,
        snapshot: ProviderDiscoverySnapshot
    ) async throws -> String? {
        let requiresProviderRequest: Bool
        switch action {
        case .approveCredentialOrigin, .approveProbes:
            requiresProviderRequest = true
        case .restartInterrupted:
            requiresProviderRequest =
                snapshot.recoveryOperation == "list_models"
                    || snapshot.recoveryOperation
                        == "probe_capabilities"
        default:
            requiresProviderRequest = false
        }
        guard requiresProviderRequest,
              snapshot.credentialSlotExpected
        else {
            return nil
        }
        guard snapshot.credentialSlotID
            == snapshot.pendingConnectionID,
            stagedDiscoveryConnectionID
                == snapshot.pendingConnectionID,
            let credential = try await credentialStore.credential(
                for: snapshot.pendingConnectionID
            )
        else {
            throw CredentialStoreError.verificationFailed
        }
        return try validatedDiscoveryCredential(credential)
    }

    private func validateDiscoverySnapshot(
        _ snapshot: ProviderDiscoverySnapshot,
        expectedConnectionID: String,
        expectedSessionID: String? = nil,
        expectedCommitAttemptID: String? = nil
    ) throws {
        try CoreRuntimeContract
            .validateProviderDiscoverySnapshotVersion(
                snapshot.schemaVersion
            )
        guard !snapshot.id.isEmpty,
              snapshot.pendingConnectionID == expectedConnectionID,
              !snapshot.pendingDisplayName.isEmpty
        else {
            throw CoreClientFailure.invalidResponse(
                "프로바이더 탐색 snapshot의 연결 식별자가 일치하지 않습니다."
            )
        }
        if let expectedSessionID,
           snapshot.id != expectedSessionID
        {
            throw CoreClientFailure.invalidResponse(
                "프로바이더 탐색 snapshot의 세션 ID가 요청과 일치하지 않습니다."
            )
        }
        if let expectedCommitAttemptID,
           snapshot.commitAttemptID != expectedCommitAttemptID
        {
            throw CoreClientFailure.invalidResponse(
                "프로바이더 탐색 snapshot의 commit attempt ID가 요청과 일치하지 않습니다."
            )
        }
        if snapshot.credentialSlotExpected {
            guard snapshot.credentialSlotID
                == snapshot.pendingConnectionID
            else {
                throw CoreClientFailure.invalidResponse(
                    "Core가 다른 Keychain 슬롯을 요청했습니다."
                )
            }
        } else if snapshot.credentialSlotID != nil {
            throw CoreClientFailure.invalidResponse(
                "자격증명 슬롯 기대 상태가 일치하지 않습니다."
            )
        }
        if let committedConnectionID = snapshot.committedConnectionID,
           committedConnectionID != snapshot.pendingConnectionID
        {
            throw CoreClientFailure.invalidResponse(
                "완료된 연결 ID가 탐색 draft와 일치하지 않습니다."
            )
        }
        switch snapshot.connectionOptions.networkMode {
        case .publicInternet, .localLoopback:
            guard snapshot.connectionOptions.localNetworkApproval == nil
            else {
                throw CoreClientFailure.invalidResponse(
                    "탐색 snapshot의 네트워크 승인 범위가 모드와 일치하지 않습니다."
                )
            }
        case .approvedLocalNetwork:
            guard let approval =
                snapshot.connectionOptions.localNetworkApproval,
                (1 ... 16).contains(approval.addresses.count)
            else {
                throw CoreClientFailure.invalidResponse(
                    "탐색 snapshot에 승인된 LAN 범위가 없습니다."
                )
            }
        }
        let consentRouteID: String?
        if case let .assistantConsent(consent) =
            snapshot.actionRequired
        {
            consentRouteID = consent.assistantModelRouteID
        } else {
            consentRouteID = nil
        }
        if let consentRouteID,
           let approvedRouteID =
               snapshot.assistantApprovalBinding?
                   .assistantModelRouteID,
           consentRouteID != approvedRouteID
        {
            throw CoreClientFailure.invalidResponse(
                "설정 도우미 동의 route와 승인된 route가 일치하지 않습니다."
            )
        }
    }

    @discardableResult
    private func applyDiscoverySnapshot(
        _ snapshot: ProviderDiscoverySnapshot,
        expectedSessionID: String? = nil,
        expectedConnectionID: String? = nil,
        expectedOperationGeneration: UInt64? = nil,
        allowsSessionEstablishment: Bool = false,
        ignoresTaskCancellation: Bool = false,
        establishedAssistantRouteID: String? = nil,
        restoresAssistantRouteFromSnapshot: Bool = false
    ) -> Bool {
        guard ignoresTaskCancellation || !Task.isCancelled else {
            return false
        }
        if let expectedOperationGeneration,
           discoveryOperationGeneration
               != expectedOperationGeneration
        {
            return false
        }
        if let expectedSessionID,
           snapshot.id != expectedSessionID
        {
            return false
        }
        if let expectedConnectionID,
           snapshot.pendingConnectionID != expectedConnectionID
        {
            return false
        }
        if let current = discovery {
            if current.id == snapshot.id {
                guard current.pendingConnectionID
                    == snapshot.pendingConnectionID,
                    snapshot.revision > current.revision
                        || snapshot == current
                else {
                    return false
                }
            } else {
                guard allowsSessionEstablishment,
                      current.state.isTerminal
                else {
                    return false
                }
            }
        } else if expectedSessionID != nil,
                  !allowsSessionEstablishment
        {
            return false
        }
        let establishesNewSession = discovery?.id != snapshot.id
        discovery = snapshot
        reconcileDiscoveryAssistantRoute(
            snapshot,
            establishesNewSession: establishesNewSession,
            establishedAssistantRouteID:
                establishedAssistantRouteID,
            restoresAssistantRouteFromSnapshot:
                restoresAssistantRouteFromSnapshot
        )
        draftDiscoveryConnectionID = snapshot.pendingConnectionID
        discoveryNetworkMode = snapshot.connectionOptions.networkMode
        approvedLANOrigin =
            snapshot.connectionOptions.localNetworkApproval?.origin ?? ""
        approvedLANAddresses =
            snapshot.connectionOptions.localNetworkApproval?.addresses
                .joined(separator: ", ") ?? ""
        assistantCallEstimate =
            snapshot.assistantApprovalBinding.map(
                makeAssistantCallEstimate
            )
        assistantHostAction = hostAction(
            from: snapshot.assistantResumeBoundary,
            sessionID: snapshot.id
        )
        return true
    }

    private func reconcileDiscoveryAssistantRoute(
        _ snapshot: ProviderDiscoverySnapshot,
        establishesNewSession: Bool,
        establishedAssistantRouteID: String?,
        restoresAssistantRouteFromSnapshot: Bool
    ) {
        let consentRouteID: String?
        if case let .assistantConsent(consent) =
            snapshot.actionRequired
        {
            consentRouteID = consent.assistantModelRouteID
        } else {
            consentRouteID = nil
        }
        let typedRouteID =
            snapshot.assistantApprovalBinding?
                .assistantModelRouteID
            ?? consentRouteID

        if let typedRouteID {
            discoveryAssistantRouteSessionID = snapshot.id
            discoveryAssistantRouteID = typedRouteID
            restoredDiscoveryAssistantRouteIsUnavailable = false
            setSelectedAssistantModelRouteID(
                assistantModelRoutes.contains {
                    $0.id == typedRouteID
                } ? typedRouteID : nil
            )
            return
        }

        if !establishesNewSession,
           discoveryAssistantRouteSessionID == snapshot.id
        {
            reconcileAssistantRouteSelectionWithActiveTarget()
            return
        }

        discoveryAssistantRouteSessionID = snapshot.id
        discoveryAssistantRouteID = establishedAssistantRouteID
        restoredDiscoveryAssistantRouteIsUnavailable =
            restoresAssistantRouteFromSnapshot
                && establishedAssistantRouteID == nil
        setSelectedAssistantModelRouteID(
            establishedAssistantRouteID.flatMap { routeID in
                assistantModelRoutes.contains {
                    $0.id == routeID
                } ? routeID : nil
            }
        )
    }

    private func hostAction(
        from boundary: ProviderDiscoveryAssistantResumeBoundary?,
        sessionID: String
    ) -> ProviderDiscoveryAssistantHostAction? {
        guard let boundary else {
            return nil
        }
        switch boundary.action {
        case .supplyMoreEvidence:
            return .requestMoreEvidence(
                sessionID: sessionID,
                questions: boundary.questions
            )
        case .reviewDraft:
            return boundary.draftReview.map {
                .reviewDraft($0)
            }
        default:
            return nil
        }
    }

    private var discoveryNetworkConfigurationIsValid: Bool {
        (try? makeDiscoveryConnectionOptions()) != nil
    }

    private var discoveryConnectionFieldsAreValid: Bool {
        guard discoveryMethod == .knownProvider,
              let template = selectedDiscoveryTemplate
        else {
            return true
        }
        return template.connectionFields.allSatisfy { field in
            switch field.type {
            case .credential:
                return !field.isRequired
                    || normalizedCredentialDraft != nil
            case .boolean:
                return connectionFieldBooleanValues[
                    field.key
                ] != nil
            case .text:
                let value = normalizedNonempty(
                    connectionFieldTextValues[field.key] ?? ""
                )
                return !field.isRequired || value != nil
            case .integer:
                let raw = connectionFieldTextValues[
                    field.key
                ] ?? ""
                if normalizedNonempty(raw) == nil {
                    return !field.isRequired
                }
                return Int64(raw) != nil
            }
        }
    }

    private func makeDiscoveryConnectionOptions() throws
        -> ProviderDiscoveryConnectionOptions
    {
        let approval: ProviderLocalNetworkApproval?
        switch discoveryNetworkMode {
        case .publicInternet:
            approval = nil
        case .localLoopback:
            approval = nil
            if discoveryMethod != .curl,
               let origin = discoveryEndpointOrigin,
               !isLoopbackHost(origin.host)
            {
                throw CoreClientFailure.invalidResponse(
                    "loopback 모드는 localhost, 127.0.0.0/8 또는 ::1 주소만 허용합니다."
                )
            }
        case .approvedLocalNetwork:
            approval = try makeApprovedLocalNetworkApproval()
        }
        let values = try makeDiscoveryConnectionValues()
        return ProviderDiscoveryConnectionOptions(
            values: values,
            timeoutSeconds: 60,
            networkMode: discoveryNetworkMode,
            localNetworkApproval: approval
        )
    }

    private func makeDiscoveryConnectionValues() throws
        -> [ProviderConfigurationEntry]
    {
        guard discoveryMethod == .knownProvider,
              let template = selectedDiscoveryTemplate
        else {
            return []
        }
        return try template.connectionFields.compactMap {
            field in
            switch field.type {
            case .credential:
                return nil
            case .boolean:
                guard let value =
                    connectionFieldBooleanValues[field.key]
                else {
                    throw CoreClientFailure.invalidResponse(
                        "\(field.label) 값을 확인하세요."
                    )
                }
                return ProviderConfigurationEntry(
                    key: field.key,
                    value: .boolean(value)
                )
            case .text:
                guard let value = normalizedNonempty(
                    connectionFieldTextValues[field.key] ?? ""
                ) else {
                    if field.isRequired {
                        throw CoreClientFailure.invalidResponse(
                            "\(field.label) 값을 입력하세요."
                        )
                    }
                    return nil
                }
                return ProviderConfigurationEntry(
                    key: field.key,
                    value: .text(value)
                )
            case .integer:
                let raw = connectionFieldTextValues[
                    field.key
                ] ?? ""
                guard let normalized = normalizedNonempty(raw)
                else {
                    if field.isRequired {
                        throw CoreClientFailure.invalidResponse(
                            "\(field.label) 값을 입력하세요."
                        )
                    }
                    return nil
                }
                guard let value = Int64(normalized) else {
                    throw CoreClientFailure.invalidResponse(
                        "\(field.label)은 정수여야 합니다."
                    )
                }
                return ProviderConfigurationEntry(
                    key: field.key,
                    value: .integer(value)
                )
            }
        }
    }

    private func makeApprovedLocalNetworkApproval() throws
        -> ProviderLocalNetworkApproval
    {
        guard let enteredOrigin = canonicalOrigin(
            from: approvedLANOrigin
        )
        else {
            throw CoreClientFailure.invalidResponse(
                "승인할 LAN origin은 정확한 scheme, host와 port여야 합니다."
            )
        }
        if discoveryMethod != .curl {
            guard let endpointOrigin = discoveryEndpointOrigin,
                  enteredOrigin.origin == endpointOrigin.origin
            else {
                throw CoreClientFailure.invalidResponse(
                    "승인할 LAN origin은 서버 주소의 scheme, host와 port에 정확히 일치해야 합니다."
                )
            }
        }
        let addresses = approvedLANAddresses
            .split(whereSeparator: {
                $0 == "," || $0 == "\n" || $0 == " "
                    || $0 == "\t"
            })
            .map(String.init)
            .reduce(into: [String]()) { result, address in
                if !result.contains(address) {
                    result.append(address)
                }
            }
        guard (1 ... 16).contains(addresses.count),
              addresses.allSatisfy(isApprovedPrivateAddress)
        else {
            throw CoreClientFailure.invalidResponse(
                "승인된 LAN IP를 1~16개 입력하세요. RFC1918 IPv4 또는 ULA IPv6만 허용됩니다."
            )
        }
        return ProviderLocalNetworkApproval(
            origin: enteredOrigin.origin,
            addresses: addresses
        )
    }

    private var discoveryEndpointOrigin:
        (origin: String, host: String)?
    {
        if let normalizedURLDraft,
           let origin = canonicalOrigin(
               from: normalizedURLDraft,
               allowsPath: true
           )
        {
            return origin
        }
        if discoveryMethod == .knownProvider,
           let defaultAPIOrigin =
               selectedDiscoveryTemplate?.defaultAPIOrigin
        {
            return canonicalOrigin(from: defaultAPIOrigin)
        }
        return nil
    }

    private func canonicalOrigin(
        from value: String,
        allowsPath: Bool = false
    ) -> (origin: String, host: String)? {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              allowsPath
                || components.path.isEmpty
                || components.path == "/"
        else {
            return nil
        }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = components.port ?? defaultPort
        let renderedHost = host.contains(":")
            ? "[\(host)]"
            : host
        let renderedPort =
            port == defaultPort ? "" : ":\(port)"
        return (
            "\(scheme)://\(renderedHost)\(renderedPort)",
            host
        )
    }

    private func isLoopbackHost(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" {
            return true
        }
        let parts = host.split(separator: ".")
        return parts.count == 4
            && parts.first == "127"
            && parts.allSatisfy { UInt8($0) != nil }
    }

    private func isApprovedPrivateAddress(_ value: String) -> Bool {
        let ipv4 = value.split(separator: ".").compactMap {
            UInt8($0)
        }
        if ipv4.count == 4 {
            return ipv4[0] == 10
                || (ipv4[0] == 172
                    && (16 ... 31).contains(ipv4[1]))
                || (ipv4[0] == 192 && ipv4[1] == 168)
        }

        var address = in6_addr()
        let parsed = value.withCString {
            Darwin.inet_pton(AF_INET6, $0, &address)
        }
        guard parsed == 1 else {
            return false
        }
        return withUnsafeBytes(of: address) {
            guard let first = $0.first else {
                return false
            }
            return first & 0xFE == 0xFC
        }
    }

    private func performDiscoveryCompensation(
        startingFrom initialSnapshot: ProviderDiscoverySnapshot,
        expectedRefreshGeneration: UInt64? = nil,
        expectedOperationGeneration: UInt64? = nil
    ) async throws -> ProviderDiscoverySnapshot {
        let expectedSessionID = initialSnapshot.id
        guard discoveryCompensationConsumers.insert(
            expectedSessionID
        ).inserted else {
            return initialSnapshot
        }
        defer {
            discoveryCompensationConsumers.remove(
                expectedSessionID
            )
        }
        let expectedConnectionID =
            initialSnapshot.pendingConnectionID
        let expectedCommitAttemptID =
            initialSnapshot.commitAttemptID
        var snapshot = initialSnapshot
        for _ in 0 ..< 32 {
            try Task.checkCancellation()
            guard refreshGenerationIsCurrent(
                expectedRefreshGeneration
            ) else {
                return snapshot
            }
            try validateDiscoverySnapshot(
                snapshot,
                expectedConnectionID: expectedConnectionID,
                expectedSessionID: expectedSessionID,
                expectedCommitAttemptID:
                    expectedCommitAttemptID
            )
            guard applyDiscoverySnapshot(
                snapshot,
                expectedSessionID: expectedSessionID,
                expectedConnectionID: expectedConnectionID,
                expectedOperationGeneration:
                    expectedOperationGeneration
            ) else {
                return snapshot
            }
            guard snapshot.state == .compensating else {
                compensationSteps = []
                return snapshot
            }
            guard let commitAttemptID =
                snapshot.commitAttemptID
            else {
                throw CoreClientFailure.invalidResponse(
                    "보상 중인 탐색에 commit attempt ID가 없습니다."
                )
            }
            let steps =
                try await client
                    .listProviderDiscoveryCompensationSteps(
                        commitAttemptID: commitAttemptID
                    )
                .sorted {
                    $0.ordinal < $1.ordinal
                }
            guard refreshGenerationIsCurrent(
                expectedRefreshGeneration
            ), discoveryContextIsCurrent(
                sessionID: expectedSessionID,
                connectionID: expectedConnectionID,
                expectedOperationGeneration:
                    expectedOperationGeneration,
                expectedRevision: snapshot.revision
            ) else {
                return snapshot
            }
            guard steps.allSatisfy({
                $0.commitAttemptID == commitAttemptID
            }) else {
                throw CoreClientFailure.invalidResponse(
                    "다른 commit의 보상 단계를 현재 탐색에 적용하지 않습니다."
                )
            }
            compensationSteps = steps

            if let nativeStep = steps.first(where: {
                $0.kind == .removeCredentialSlot
                    && $0.status != .completed
            }) {
                if nativeStep.status == .outcomeUnknown {
                    return snapshot
                }
                if nativeStep.status == .inProgress {
                    let marked =
                        await markDiscoveryCredentialCompensationUnknownIgnoringCancellation(
                            sessionID: snapshot.id,
                            stepID: nativeStep.id
                        )
                    if let marked {
                        snapshot = marked
                        _ = applyDiscoverySnapshot(
                            snapshot,
                            expectedSessionID:
                                expectedSessionID,
                            expectedConnectionID:
                                expectedConnectionID,
                            expectedOperationGeneration:
                                expectedOperationGeneration,
                            ignoresTaskCancellation: true
                        )
                    }
                    return snapshot
                }
                if nativeStep.status == .failed {
                    guard discoveryContextIsCurrent(
                        sessionID: expectedSessionID,
                        connectionID: expectedConnectionID,
                        expectedOperationGeneration:
                            expectedOperationGeneration,
                        expectedRevision: snapshot.revision
                    ) else {
                        return snapshot
                    }
                    snapshot =
                        try await client
                            .resumeProviderDiscoveryCompensation(
                                sessionID: snapshot.id
                            )
                    continue
                }
                let claimed: ProviderDiscoveryCompensationStep
                if nativeStep.status == .pending {
                    guard discoveryContextIsCurrent(
                        sessionID: expectedSessionID,
                        connectionID: expectedConnectionID,
                        expectedOperationGeneration:
                            expectedOperationGeneration,
                        expectedRevision: snapshot.revision
                    ) else {
                        return snapshot
                    }
                    claimed =
                        try await client
                            .startProviderDiscoveryCredentialCompensation(
                                sessionID: snapshot.id,
                                stepID: nativeStep.id
                            )
                } else {
                    claimed = nativeStep
                }
#if DEBUG
                await discoveryCompensationClaimCommitHookForTesting?()
#endif
                let confirmedSteps =
                    try await client
                        .listProviderDiscoveryCompensationSteps(
                            commitAttemptID: commitAttemptID
                        )
                compensationSteps = confirmedSteps.sorted {
                    $0.ordinal < $1.ordinal
                }
                guard let confirmedClaim =
                    confirmedSteps.first(where: {
                        $0.id == claimed.id
                    }),
                    confirmedClaim.status == .inProgress
                else {
                    return snapshot
                }
                guard refreshGenerationIsCurrent(
                    expectedRefreshGeneration
                ), discoveryContextIsCurrent(
                    sessionID: expectedSessionID,
                    connectionID: expectedConnectionID,
                    expectedOperationGeneration:
                        expectedOperationGeneration,
                    expectedRevision: snapshot.revision
                ) else {
                    return snapshot
                }
                guard claimed.id == nativeStep.id,
                      claimed.commitAttemptID == commitAttemptID,
                      claimed.kind == .removeCredentialSlot,
                      case let .removeCredentialSlot(
                          connectionID,
                          credentialReference
                      ) =
                          claimed.target,
                      connectionID
                        == snapshot.pendingConnectionID,
                      credentialReference
                        == snapshot.pendingConnectionID
                else {
                    throw CoreClientFailure.invalidResponse(
                        "Core가 현재 탐색과 다른 Keychain 보상 대상을 반환했습니다."
                    )
                }

                do {
                    try await credentialStore.deleteCredential(
                        for: connectionID
                    )
                    guard try await credentialStore.credentialData(
                        for: connectionID
                    ) == nil else {
                        throw CredentialStoreError.verificationFailed
                    }
                    if stagedDiscoveryConnectionID == connectionID {
                        stagedDiscoveryConnectionID = nil
                        hasStagedDiscoveryCredential = false
                    }
#if DEBUG
                    try await discoveryCompensationCredentialDeletionCommitHookForTesting?()
#endif
                } catch {
                    let marked =
                        await markDiscoveryCredentialCompensationUnknownIgnoringCancellation(
                            sessionID: snapshot.id,
                            stepID: claimed.id
                        )
                    if let marked {
                        snapshot = marked
                        _ = applyDiscoverySnapshot(
                            snapshot,
                            expectedSessionID:
                                expectedSessionID,
                            expectedConnectionID:
                                expectedConnectionID,
                            expectedOperationGeneration:
                                expectedOperationGeneration,
                            ignoresTaskCancellation: true
                        )
                    }
                    throw error
                }

                let acknowledgement =
                    await acknowledgeDiscoveryCredentialCompensationIgnoringCancellation(
                        sessionID: snapshot.id,
                        stepID: claimed.id
                    )
                switch acknowledgement {
                case let .completed(completed):
                    try validateDiscoverySnapshot(
                        completed,
                        expectedConnectionID:
                            expectedConnectionID,
                        expectedSessionID:
                            expectedSessionID,
                        expectedCommitAttemptID:
                            expectedCommitAttemptID
                    )
                    snapshot = completed
                    guard applyDiscoverySnapshot(
                        snapshot,
                        expectedSessionID:
                            expectedSessionID,
                        expectedConnectionID:
                            expectedConnectionID,
                        expectedOperationGeneration:
                            expectedOperationGeneration,
                        ignoresTaskCancellation: true
                    ) else {
                        return snapshot
                    }
                    if let refreshedSteps =
                        await loadDiscoveryCompensationStepsIgnoringCancellation(
                            commitAttemptID: commitAttemptID
                        )
                    {
                        compensationSteps = refreshedSteps
                    }
                    if snapshot.state.isTerminal {
                        errorMessage = nil
                        statusMessage = discoveryStatus(snapshot)
                        return snapshot
                    }
                case let .outcomeUnknown(marked):
                    if let marked {
                        snapshot = marked
                        _ = applyDiscoverySnapshot(
                            snapshot,
                            expectedSessionID:
                                expectedSessionID,
                            expectedConnectionID:
                                expectedConnectionID,
                            expectedOperationGeneration:
                                expectedOperationGeneration,
                            ignoresTaskCancellation: true
                        )
                    }
                    return snapshot
                }
                continue
            }

            guard discoveryContextIsCurrent(
                sessionID: expectedSessionID,
                connectionID: expectedConnectionID,
                expectedOperationGeneration:
                    expectedOperationGeneration,
                expectedRevision: snapshot.revision
            ) else {
                return snapshot
            }
            snapshot =
                try await client
                    .continueProviderDiscoveryCompensation(
                        sessionID: snapshot.id
                    )
        }
        throw CoreClientFailure.invalidResponse(
            "프로바이더 보상 단계가 안전한 반복 한도를 초과했습니다."
        )
    }

    private func acknowledgeDiscoveryCredentialCompensationIgnoringCancellation(
        sessionID: String,
        stepID: String
    ) async -> CredentialCompensationAcknowledgement {
        await Task { @MainActor [weak self] in
            guard let self else {
                return .outcomeUnknown(nil)
            }
            do {
                let completed =
                    try await self.client
                        .completeProviderDiscoveryCredentialCompensation(
                            sessionID: sessionID,
                            stepID: stepID
                        )
                return .completed(completed)
            } catch {
                let marked =
                    try? await self.client
                        .markProviderDiscoveryCredentialCompensationUnknown(
                            sessionID: sessionID,
                            stepID: stepID
                        )
                return .outcomeUnknown(marked)
            }
        }.value
    }

    private func loadDiscoveryCompensationStepsIgnoringCancellation(
        commitAttemptID: String
    ) async -> [ProviderDiscoveryCompensationStep]? {
        await Task { @MainActor [weak self] in
            guard let self else {
                return nil
            }
            return try? await self.client
                .listProviderDiscoveryCompensationSteps(
                    commitAttemptID: commitAttemptID
                )
                .sorted {
                    $0.ordinal < $1.ordinal
                }
        }.value
    }

    private func markDiscoveryCredentialCompensationUnknownIgnoringCancellation(
        sessionID: String,
        stepID: String
    ) async -> ProviderDiscoverySnapshot? {
        await Task { @MainActor [weak self] in
            guard let self else {
                return nil
            }
            return try? await self.client
                .markProviderDiscoveryCredentialCompensationUnknown(
                    sessionID: sessionID,
                    stepID: stepID
                )
        }.value
    }

    private func restoreProviderDiscovery(
        expectedRefreshGeneration: UInt64
    ) async {
        let operationGeneration = discoveryOperationGeneration
        guard refreshGenerationIsCurrent(
            expectedRefreshGeneration
        ), discoveryOperationGeneration == operationGeneration,
           !hasActiveDiscovery
        else {
            return
        }
        do {
            _ = try await client.recoverProviderDiscoveries()
            guard refreshGenerationIsCurrent(
                expectedRefreshGeneration
            ), discoveryOperationGeneration == operationGeneration
            else {
                return
            }
            let snapshots = try await client.listProviderDiscoveries(
                limit: 50
            )
            guard refreshGenerationIsCurrent(
                expectedRefreshGeneration
            ), discoveryOperationGeneration == operationGeneration
            else {
                return
            }
            guard let restorable = snapshots.first(where: {
                !$0.state.isTerminal
            }) else {
                return
            }
            try validateDiscoverySnapshot(
                restorable,
                expectedConnectionID: restorable.pendingConnectionID
            )
            let hasCredential: Bool?
            if restorable.credentialSlotExpected {
                hasCredential =
                    try await credentialStore.credentialData(
                        for: restorable.pendingConnectionID
                    ) != nil
            } else {
                hasCredential = nil
            }
            guard refreshGenerationIsCurrent(
                expectedRefreshGeneration
            ), discoveryOperationGeneration == operationGeneration
            else {
                return
            }
            guard applyDiscoverySnapshot(
                restorable,
                expectedConnectionID:
                    restorable.pendingConnectionID,
                expectedOperationGeneration:
                    operationGeneration,
                allowsSessionEstablishment: true,
                restoresAssistantRouteFromSnapshot: true
            ) else {
                return
            }
            if let hasCredential {
                stagedDiscoveryConnectionID =
                    restorable.pendingConnectionID
                hasStagedDiscoveryCredential = hasCredential
                if !hasStagedDiscoveryCredential {
                    errorMessage =
                        "복원한 탐색에 필요한 API 키가 Keychain에 없습니다. 취소하거나 다시 연결하세요."
                }
            }
            if restorable.state == .compensating {
                _ = try await performDiscoveryCompensation(
                    startingFrom: restorable,
                    expectedRefreshGeneration:
                        expectedRefreshGeneration,
                    expectedOperationGeneration:
                        operationGeneration
                )
            }
            guard refreshGenerationIsCurrent(
                expectedRefreshGeneration
            ), discovery?.id == restorable.id
            else {
                return
            }
            startDiscoveryMonitor(
                sessionID: restorable.id,
                expectedOperationGeneration: operationGeneration
            )
            await consumeDiscoveryEvents(
                sessionID: restorable.id,
                expectedRefreshGeneration:
                    expectedRefreshGeneration,
                expectedOperationGeneration:
                    operationGeneration
            )
        } catch is CancellationError {
            return
        } catch {
            guard refreshGenerationIsCurrent(
                expectedRefreshGeneration
            ), discoveryOperationGeneration == operationGeneration
            else {
                return
            }
            errorMessage = safeFailureMessage(
                action: "진행 중인 프로바이더 탐색을 복구하지",
                error: error
            )
        }
    }

    private func consumeDiscoveryEvents(
        sessionID: String,
        expectedRefreshGeneration: UInt64? = nil,
        expectedOperationGeneration: UInt64? = nil
    ) async {
        guard let expectedConnectionID =
            discovery?.pendingConnectionID,
              discoveryContextIsCurrent(
                  sessionID: sessionID,
                  connectionID: expectedConnectionID,
                  expectedOperationGeneration:
                      expectedOperationGeneration
              ),
              refreshGenerationIsCurrent(
            expectedRefreshGeneration
              ),
              !discoveryEventConsumers.contains(sessionID)
        else {
            return
        }
        discoveryEventConsumers.insert(sessionID)
        defer {
            discoveryEventConsumers.remove(sessionID)
#if DEBUG
            discoveryEventConsumerCompletionHookForTesting?(sessionID)
#endif
        }

        do {
            let events = try await client.pollProviderDiscoveryEvents(
                limit: 64
            ).filter {
                $0.event.sessionID == sessionID
            }
            .sorted {
                $0.event.sequence < $1.event.sequence
            }
            guard refreshGenerationIsCurrent(
                expectedRefreshGeneration
            ), discoveryContextIsCurrent(
                sessionID: sessionID,
                connectionID: expectedConnectionID,
                expectedOperationGeneration:
                    expectedOperationGeneration
            ) else {
                return
            }
            for outbox in events {
                let event = outbox.event
                try CoreRuntimeContract
                    .validateProviderDiscoveryEventVersion(
                        event.version
                    )
                guard event.sessionID == sessionID,
                      discovery?.id == sessionID
                else {
                    return
                }
                var snapshot = try await client.getProviderDiscovery(
                    sessionID: sessionID
                )
#if DEBUG
                snapshot =
                    discoverySnapshotTransformForTesting?(snapshot)
                        ?? snapshot
                await discoveryEventSnapshotCommitHookForTesting?()
#endif
                guard refreshGenerationIsCurrent(
                    expectedRefreshGeneration
                ), discoveryContextIsCurrent(
                    sessionID: sessionID,
                    connectionID: expectedConnectionID,
                    expectedOperationGeneration:
                        expectedOperationGeneration
                )
                else {
                    return
                }
                try validateDiscoverySnapshot(
                    snapshot,
                    expectedConnectionID: expectedConnectionID,
                    expectedSessionID: sessionID
                )
                guard snapshot.revision >= event.sessionRevision else {
                    throw CoreClientFailure.invalidResponse(
                        "탐색 이벤트 revision이 현재 snapshot보다 앞서 있습니다."
                    )
                }
                if snapshot.revision == event.sessionRevision,
                   snapshot.state != event.state
                {
                    throw CoreClientFailure.invalidResponse(
                        "탐색 이벤트 상태와 snapshot이 일치하지 않습니다."
                    )
                }
                guard applyDiscoverySnapshot(
                    snapshot,
                    expectedSessionID: sessionID,
                    expectedConnectionID: expectedConnectionID,
                    expectedOperationGeneration:
                        expectedOperationGeneration
                ) else {
                    return
                }
                if snapshot.state == .compensating {
                    _ = try await performDiscoveryCompensation(
                        startingFrom: snapshot,
                        expectedRefreshGeneration:
                            expectedRefreshGeneration,
                        expectedOperationGeneration:
                            expectedOperationGeneration
                    )
                }
                guard refreshGenerationIsCurrent(
                    expectedRefreshGeneration
                ), discoveryContextIsCurrent(
                    sessionID: sessionID,
                    connectionID: expectedConnectionID,
                    expectedOperationGeneration:
                        expectedOperationGeneration
                ) else {
                    return
                }
                _ = try await client.ackProviderDiscoveryEvent(
                    eventID: event.id
                )
            }
            guard refreshGenerationIsCurrent(
                expectedRefreshGeneration
            ), discoveryContextIsCurrent(
                sessionID: sessionID,
                connectionID: expectedConnectionID,
                expectedOperationGeneration:
                    expectedOperationGeneration
            ) else {
                return
            }
            if discovery?.id == sessionID,
               (
                   discovery?.state == .cancelled
                       || discovery?.state == .failed
               )
            {
                try await clearStagedDiscoveryCredential(
                    expectedRefreshGeneration:
                        expectedRefreshGeneration
                )
                guard refreshGenerationIsCurrent(
                    expectedRefreshGeneration
                ), discoveryContextIsCurrent(
                    sessionID: sessionID,
                    connectionID: expectedConnectionID,
                    expectedOperationGeneration:
                        expectedOperationGeneration
                ) else {
                    return
                }
                stopDiscoveryMonitor()
            } else if discovery?.id == sessionID,
                      discovery?.state == .ready
            {
                hasStagedDiscoveryCredential = false
                stagedDiscoveryConnectionID = nil
                stopDiscoveryMonitor()
            }
        } catch is CancellationError {
            return
        } catch {
            guard refreshGenerationIsCurrent(
                expectedRefreshGeneration
            ), discoveryContextIsCurrent(
                sessionID: sessionID,
                connectionID: expectedConnectionID,
                expectedOperationGeneration:
                    expectedOperationGeneration
            )
            else {
                return
            }
            errorMessage = safeFailureMessage(
                action: "프로바이더 탐색 이벤트를 처리하지",
                error: error
            )
        }
    }

    private func startDiscoveryMonitor(
        sessionID: String,
        expectedOperationGeneration: UInt64? = nil
    ) {
        guard let connectionID = discovery?.pendingConnectionID else {
            return
        }
        stopDiscoveryMonitor()
        discoveryMonitorTask = Task { [weak self] in
            guard let self else {
                return
            }
            while !Task.isCancelled {
                await self.consumeDiscoveryEvents(
                    sessionID: sessionID,
                    expectedOperationGeneration:
                        expectedOperationGeneration
                )
                guard self.discoveryContextIsCurrent(
                          sessionID: sessionID,
                          connectionID: connectionID,
                          expectedOperationGeneration:
                              expectedOperationGeneration
                      ),
                      self.discovery?.state.isTerminal == false
                else {
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(800))
                } catch {
                    return
                }
            }
        }
    }

    private func stopDiscoveryMonitor() {
        discoveryMonitorTask?.cancel()
        discoveryMonitorTask = nil
    }

    private func validatedDiscoveryCredential(
        _ credential: String?
    ) throws -> String? {
        guard let normalized = credential?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !normalized.isEmpty
        else {
            return nil
        }
        guard
            normalized.utf8.count
                <= CredentialStorePolicy.maximumCredentialUTF8Bytes
        else {
            throw CredentialStoreError.credentialTooLarge
        }
        return normalized
    }

    private func schedulePresetControlRefresh() {
        presetControlRefreshTask?.cancel()
        presetControlRefreshTask = Task { [weak self] in
            await self?.performPresetControlRefresh(
                reportingFailure: false,
                remainingCanonicalizationPasses: 1
            )
        }
    }

    private func refreshPresetControlsIgnoringCallerCancellation() async {
        await Task { @MainActor [weak self] in
            await self?.refreshPresetControls()
        }.value
    }

    private func normalizeOpaqueReasoningContinuityForSelectedConnection() {
        guard selectedConnection?.hasCredential == true,
              preservesOpaqueReasoningState
        else {
            return
        }
        preservesOpaqueReasoningState = false
    }

    private func clearRenderedPresetControls() {
        presetControlRenderGeneration &+= 1
        reasoningControl = nil
        promptCacheControl = nil
        renderedPresetControlCandidate = nil
    }

    private func reconcileGenerationPresetsAfterCommittedMutation(
        modelRouteID: String,
        owner: SelectionContext
    ) async -> MutationRefreshOutcome {
        await Task { @MainActor [weak self] in
            guard let self else {
                return .failed
            }
            do {
                let loaded =
                    try await self.client
                        .listProviderGenerationPresets(
                            modelRouteID: modelRouteID
                        )
                try self.validateGenerationPresets(
                    loaded,
                    expectedModelRouteID: modelRouteID
                )
                guard self
                    .modelRouteSelectionContextOwnsHierarchy(owner)
                else {
                    return .superseded
                }
                self.presets = loaded.sorted {
                    $0.displayName.localizedStandardCompare(
                        $1.displayName
                    ) == .orderedAscending
                }
                self.publishConfigurationSnapshotIfResolved()
                return .success
            } catch {
                return self
                    .modelRouteSelectionContextOwnsHierarchy(owner)
                    ? .failed
                    : .superseded
            }
        }.value
    }

    private func refreshAfterMutation(
        selecting connectionID: String? = nil,
        owner: ConnectionHierarchyOwner
    ) async -> MutationRefreshOutcome {
        await Task { @MainActor [weak self] in
            guard let self else {
                return .failed
            }
            return await self.performRefreshAfterMutation(
                selecting: connectionID,
                owner: owner
            )
        }.value
    }

    private func performRefreshAfterMutation(
        selecting connectionID: String?,
        owner: ConnectionHierarchyOwner
    ) async -> MutationRefreshOutcome {
        let preferredID =
            connectionID ?? owner.selectedConnectionID
        do {
            async let loadedTemplates =
                client.listProviderTemplates()
            async let loadedConnections =
                client.listProviderConnections()
            async let loadedSettings = client.getSettings()
            async let loadedCatalogStatus =
                try? client.getProviderCatalogStatus()
            let (
                newTemplates,
                newConnections,
                settings
            ) = try await (
                loadedTemplates,
                loadedConnections,
                loadedSettings
            )
            let newCatalogStatus = await loadedCatalogStatus
            let sortedConnections = newConnections
                .sorted {
                    $0.displayName.localizedStandardCompare(
                        $1.displayName
                    ) == .orderedAscending
                }
            let resolvedActiveSelection =
                try await resolveActiveGenerationSelection(
                    settings,
                    connections: sortedConnections
                )
            let loadedAssistantRoutes =
                try await loadAssistantModelRoutes(
                    connections: sortedConnections
                )
#if DEBUG
            try await providerMutationRefreshCommitHookForTesting?()
#endif
            guard refreshGeneration == owner.refreshGeneration else {
                return .superseded
            }
            templates = newTemplates.sorted {
                $0.displayName.localizedStandardCompare($1.displayName)
                    == .orderedAscending
            }
            connections = sortedConnections
            catalogStatus = newCatalogStatus
            applyActiveGenerationSelection(resolvedActiveSelection)
            replaceAssistantModelRoutes(loadedAssistantRoutes)
            publishConfigurationSnapshotIfResolved()

            guard connectionSelectionGeneration
                == owner.selectionGeneration,
                selectedConnectionID == owner.selectedConnectionID
            else {
                // A newer user selection owns the visible hierarchy. The
                // latest collections/global target above are still safe to
                // publish because no newer lifecycle refresh superseded us.
                return .superseded
            }
            let nextConnectionID = connections.contains(where: {
                $0.id == preferredID
            }) ? preferredID : connections.first?.id
            if let nextConnectionID {
                let hydrationOutcome = await selectConnection(
                    id: nextConnectionID,
                    expectedRefreshGeneration:
                        owner.refreshGeneration
                )
                guard hydrationOutcome == .success else {
                    return hydrationOutcome
                }
            } else {
                selectedConnectionID = nil
                connectionSelectionGeneration &+= 1
                invalidateConnectionHierarchy()
                isSelectionLoading = false
            }
            return .success
        } catch {
            guard connectionHierarchyOwnerIsCurrent(owner) else {
                return .superseded
            }
            errorMessage = safeFailureMessage(
                action: "변경 후 프로바이더 상태를 불러오지",
                error: error
            )
            return .failed
        }
    }

    private func refreshAfterCatalogActivation(
        owner: ConnectionHierarchyOwner
    ) async -> MutationRefreshOutcome {
#if DEBUG
        do {
            try await catalogPostActivationRefreshHookForTesting?()
        } catch {
            errorMessage = safeFailureMessage(
                action: "카탈로그 적용 후 프로바이더 상태를 새로고침하지",
                error: error
            )
            return .failed
        }
#endif
        return await refreshAfterMutation(owner: owner)
    }

    private func reloadActiveGenerationSelection() async throws {
        let loaded = try await loadActiveGenerationSelection()
        guard connections == loaded.connections else {
            return
        }
        applyActiveGenerationSelection(
            loaded.selection
        )
        publishConfigurationSnapshotIfResolved()
    }

    private func reconcileActiveGenerationSelectionAfterCommittedMutation(
        expectedRefreshGeneration: UInt64
    ) async -> MutationRefreshOutcome {
        await Task { @MainActor [weak self] in
            guard let self else {
                return .failed
            }
            return await self
                .performActiveGenerationSelectionReconciliation(
                    expectedRefreshGeneration:
                        expectedRefreshGeneration
                )
        }.value
    }

    private func performActiveGenerationSelectionReconciliation(
        expectedRefreshGeneration: UInt64
    ) async -> MutationRefreshOutcome {
        do {
            let loaded = try await loadActiveGenerationSelection()
#if DEBUG
            await activeGenerationReconciliationCommitHookForTesting?()
#endif
            guard refreshGeneration == expectedRefreshGeneration,
                  connections == loaded.connections
            else {
                // A newer lifecycle refresh owns the global snapshot.
                return .superseded
            }
            applyActiveGenerationSelection(loaded.selection)
            publishConfigurationSnapshotIfResolved()
            return .success
        } catch {
            return .failed
        }
    }

    private func loadActiveGenerationSelection() async throws -> (
        connections: [ProviderConnectionRecord],
        selection: ResolvedActiveGenerationSelection
    ) {
        let connectionSnapshot = connections
        let settings = try await client.getSettings()
        let resolvedSelection =
            try await resolveActiveGenerationSelection(
                settings,
                connections: connectionSnapshot
            )
        return (
            connections: connectionSnapshot,
            selection: resolvedSelection
        )
    }

    private func resolveActiveGenerationSelection(
        _ settings: CoreAppSettings,
        connections: [ProviderConnectionRecord]
    ) async throws -> ResolvedActiveGenerationSelection {
        let target =
            settings.selectedGenerationTarget
            ?? settings.selectedProviderProfileID.map {
                ProviderGenerationTarget(
                    modelRouteID: $0,
                    generationPresetID: $0
                )
            }
        guard let target else {
            return ResolvedActiveGenerationSelection(
                target: nil,
                connectionID: nil
            )
        }

        for connection in connections {
            let routes = try await client.listProviderModelRoutes(
                connectionID: connection.id
            )
            try validateModelRoutes(
                routes,
                expectedConnectionID: connection.id
            )
            guard routes.contains(where: {
                $0.id == target.modelRouteID
            }) else {
                continue
            }
            let routePresets =
                try await client.listProviderGenerationPresets(
                    modelRouteID: target.modelRouteID
                )
            try validateGenerationPresets(
                routePresets,
                expectedModelRouteID: target.modelRouteID
            )
            guard routePresets.contains(where: {
                $0.id == target.generationPresetID
            }) else {
                return ResolvedActiveGenerationSelection(
                    target: nil,
                    connectionID: nil
                )
            }
            return ResolvedActiveGenerationSelection(
                target: target,
                connectionID: connection.id
            )
        }

        return ResolvedActiveGenerationSelection(
            target: nil,
            connectionID: nil
        )
    }

    private func applyActiveGenerationSelection(
        _ selection: ResolvedActiveGenerationSelection
    ) {
        activeGenerationTarget = selection.target
        activeGenerationConnectionID = selection.connectionID
    }

    private func loadAssistantModelRoutes(
        connections: [ProviderConnectionRecord]
    ) async throws -> [ProviderModelRoute] {
        var loadedRoutes: [ProviderModelRoute] = []
        for connection in connections {
            try Task.checkCancellation()
            let routes = try await client.listProviderModelRoutes(
                connectionID: connection.id
            )
            try validateModelRoutes(
                routes,
                expectedConnectionID: connection.id
            )
            loadedRoutes.append(contentsOf: routes)
        }
        guard Set(loadedRoutes.map(\.id)).count
            == loadedRoutes.count
        else {
            throw CoreClientFailure.invalidResponse(
                "문서 분석 모델 목록에 연결 간 중복 route ID가 포함되어 있습니다."
            )
        }
        return sortedAssistantModelRoutes(loadedRoutes)
    }

    private func replaceAssistantModelRoutes(
        _ routes: [ProviderModelRoute]
    ) {
        assistantModelRoutes =
            sortedAssistantModelRoutes(routes)
        reconcileAssistantRouteSelectionWithActiveTarget()
    }

    private func replaceAssistantModelRoutes(
        for connectionID: String,
        with routes: [ProviderModelRoute]
    ) {
        var merged = assistantModelRoutes.filter {
            $0.connectionID != connectionID
        }
        merged.append(contentsOf: routes)
        replaceAssistantModelRoutes(merged)
    }

    private func sortedAssistantModelRoutes(
        _ routes: [ProviderModelRoute]
    ) -> [ProviderModelRoute] {
        routes.sorted { lhs, rhs in
            let lhsTitle = assistantRouteTitle(lhs)
            let rhsTitle = assistantRouteTitle(rhs)
            if lhsTitle == rhsTitle {
                return lhs.id.localizedStandardCompare(rhs.id)
                    == .orderedAscending
            }
            return lhsTitle.localizedStandardCompare(rhsTitle)
                == .orderedAscending
        }
    }

    private func setSelectedAssistantModelRouteID(
        _ routeID: String?
    ) {
        guard selectedAssistantModelRouteID != routeID else {
            return
        }
        assistantRouteSelectionGeneration &+= 1
        selectedAssistantModelRouteID = routeID
    }

    private func reconcileAssistantRouteSelectionWithActiveTarget() {
        if let discovery,
           !discovery.state.isTerminal
        {
            let boundRouteID =
                discoveryAssistantRouteSessionID == discovery.id
                    ? discoveryAssistantRouteID
                    : nil
            setSelectedAssistantModelRouteID(
                boundRouteID.flatMap { routeID in
                    assistantModelRoutes.contains {
                        $0.id == routeID
                    } ? routeID : nil
                }
            )
            return
        }
        let activeRouteID =
            activeGenerationTarget?.modelRouteID
        setSelectedAssistantModelRouteID(
            activeRouteID.flatMap { routeID in
                assistantModelRoutes.contains {
                    $0.id == routeID
                } ? routeID : nil
            }
        )
    }

    private func assistantRouteDraftIsCurrent(
        generation: UInt64,
        selectedRouteID: String?,
        activeRouteID: String?
    ) -> Bool {
        assistantRouteSelectionGeneration == generation
            && selectedAssistantModelRouteID
                == selectedRouteID
            && activeGenerationTarget?.modelRouteID
                == activeRouteID
    }

    private func refreshGenerationIsCurrent(
        _ expectedGeneration: UInt64?
    ) -> Bool {
        expectedGeneration == nil
            || expectedGeneration == refreshGeneration
    }

    private func finishSupersededRefreshIfCurrent(
        generation: UInt64
    ) {
        guard generation == refreshGeneration,
              loadState == .loading
        else {
            return
        }
        loadState = connections.isEmpty ? .idle : .loaded
    }

    private func discoveryDraftOperationIsCurrent(
        _ expectedOperationGeneration: UInt64,
        connectionID: String
    ) -> Bool {
        !Task.isCancelled
            && discoveryDraftIdentityIsCurrent(
                expectedOperationGeneration,
                connectionID: connectionID
            )
    }

    private func discoveryDraftIdentityIsCurrent(
        _ expectedOperationGeneration: UInt64,
        connectionID: String
    ) -> Bool {
        discoveryOperationGeneration
            == expectedOperationGeneration
            && draftDiscoveryConnectionID == connectionID
            && discovery == nil
    }

    private func discoveryContextIsCurrent(
        sessionID: String,
        connectionID: String,
        expectedOperationGeneration: UInt64?,
        expectedRevision: UInt64? = nil
    ) -> Bool {
        !Task.isCancelled
            && discoveryContextOwns(
                sessionID: sessionID,
                connectionID: connectionID,
                expectedOperationGeneration:
                    expectedOperationGeneration,
                expectedRevision: expectedRevision
            )
    }

    private func discoveryContextOwns(
        sessionID: String,
        connectionID: String,
        expectedOperationGeneration: UInt64?,
        expectedRevision: UInt64? = nil
    ) -> Bool {
        guard let discovery,
              discovery.id == sessionID,
              discovery.pendingConnectionID == connectionID
        else {
            return false
        }
        if let expectedOperationGeneration,
           discoveryOperationGeneration
               != expectedOperationGeneration
        {
            return false
        }
        if let expectedRevision,
           discovery.revision != expectedRevision
        {
            return false
        }
        return true
    }

    private func reconcileDiscoverySessionIgnoringCallerCancellation(
        sessionID: String,
        expectedConnectionID: String,
        expectedOperationGeneration: UInt64
    ) async -> MutationRefreshOutcome {
        await Task { @MainActor [weak self] in
            guard let self else {
                return .failed
            }
            do {
                let snapshot = try await self.client
                    .getProviderDiscovery(sessionID: sessionID)
                try self.validateDiscoverySnapshot(
                    snapshot,
                    expectedConnectionID: expectedConnectionID,
                    expectedSessionID: sessionID
                )
                guard self.applyDiscoverySnapshot(
                    snapshot,
                    expectedSessionID: sessionID,
                    expectedConnectionID:
                        expectedConnectionID,
                    expectedOperationGeneration:
                        expectedOperationGeneration,
                    ignoresTaskCancellation: true
                ) else {
                    return .superseded
                }
                return .success
            } catch {
                return self.discoveryContextOwns(
                    sessionID: sessionID,
                    connectionID: expectedConnectionID,
                    expectedOperationGeneration:
                        expectedOperationGeneration
                ) ? .failed : .superseded
            }
        }.value
    }

    private func modelSyncContextIsCurrent(
        jobID: String,
        expectedConnectionID: String?,
        expectedConnectionSelectionGeneration: UInt64?,
        expectedRefreshGeneration: UInt64?,
        expectedOperationGeneration: UInt64?
    ) -> Bool {
        !Task.isCancelled
            && modelSyncContextOwns(
                jobID: jobID,
                expectedConnectionID: expectedConnectionID,
                expectedConnectionSelectionGeneration:
                    expectedConnectionSelectionGeneration,
                expectedRefreshGeneration:
                    expectedRefreshGeneration,
                expectedOperationGeneration:
                    expectedOperationGeneration
            )
    }

    private func modelSyncContextOwns(
        jobID: String,
        expectedConnectionID: String?,
        expectedConnectionSelectionGeneration: UInt64?,
        expectedRefreshGeneration: UInt64?,
        expectedOperationGeneration: UInt64?
    ) -> Bool {
        guard refreshGenerationIsCurrent(
            expectedRefreshGeneration
        ),
              modelSyncJob?.id == jobID
        else {
            return false
        }
        if let expectedConnectionID,
           selectedConnectionID != expectedConnectionID
        {
            return false
        }
        if let expectedConnectionSelectionGeneration,
           connectionSelectionGeneration
               != expectedConnectionSelectionGeneration
        {
            return false
        }
        if let expectedOperationGeneration,
           modelSyncOperationGeneration
               != expectedOperationGeneration
        {
            return false
        }
        return true
    }

    private func modelSyncOperationContextIsCurrent(
        connectionID: String,
        expectedConnectionSelectionGeneration: UInt64,
        expectedRefreshGeneration: UInt64?,
        expectedOperationGeneration: UInt64
    ) -> Bool {
        !Task.isCancelled
            && modelSyncOperationContextOwns(
                connectionID: connectionID,
                expectedConnectionSelectionGeneration:
                    expectedConnectionSelectionGeneration,
                expectedRefreshGeneration:
                    expectedRefreshGeneration,
                expectedOperationGeneration:
                    expectedOperationGeneration
            )
    }

    private func modelSyncOperationContextOwns(
        connectionID: String,
        expectedConnectionSelectionGeneration: UInt64,
        expectedRefreshGeneration: UInt64?,
        expectedOperationGeneration: UInt64
    ) -> Bool {
        selectedConnectionID == connectionID
            && connectionSelectionGeneration
                == expectedConnectionSelectionGeneration
            && refreshGenerationIsCurrent(
                expectedRefreshGeneration
            )
            && modelSyncOperationGeneration
                == expectedOperationGeneration
    }

    @discardableResult
    private func applyModelSyncJob(
        _ job: ProviderModelSyncJob,
        expectedConnectionID: String,
        expectedConnectionSelectionGeneration: UInt64?,
        expectedRefreshGeneration: UInt64?,
        expectedOperationGeneration: UInt64?,
        expectedJobID: String?,
        allowsNewJob: Bool
    ) -> Bool {
        guard !Task.isCancelled,
              job.connectionID == expectedConnectionID,
              selectedConnectionID == expectedConnectionID,
              refreshGenerationIsCurrent(
                  expectedRefreshGeneration
              )
        else {
            return false
        }
        if let expectedConnectionSelectionGeneration,
           connectionSelectionGeneration
               != expectedConnectionSelectionGeneration
        {
            return false
        }
        if let expectedOperationGeneration,
           modelSyncOperationGeneration
               != expectedOperationGeneration
        {
            return false
        }
        if let expectedJobID {
            guard job.id == expectedJobID,
                  modelSyncJob?.id == expectedJobID
            else {
                return false
            }
        } else if !allowsNewJob,
                  modelSyncJob?.id != job.id
        {
            return false
        }
        if let current = modelSyncJob {
            guard current.id == job.id || allowsNewJob else {
                return false
            }
            if current.id == job.id,
               !(
                   job.revision > current.revision
                       || job == current
               )
            {
                return false
            }
        }
        modelSyncJob = job
        return true
    }

    private func reconcileCommittedModelSyncJobIfVisible(
        _ job: ProviderModelSyncJob,
        expectedConnectionID: String,
        allowsNewJob: Bool = false
    ) -> UInt64? {
        guard job.connectionID == expectedConnectionID,
              selectedConnectionID == expectedConnectionID,
              connections.contains(where: {
                  $0.id == expectedConnectionID
              })
        else {
            return nil
        }
        if let current = modelSyncJob {
            guard current.id == job.id || allowsNewJob else {
                return nil
            }
            if current.id == job.id,
               current.revision > job.revision
            {
                return modelSyncOperationGeneration
            }
        }
        stopModelSyncMonitor()
        modelSyncOperationGeneration &+= 1
        modelSyncJob = job
        if job.state.isTerminal {
            modelSyncEventMessageKey = nil
        }
        return modelSyncOperationGeneration
    }

    private func reconcileNewModelSyncAfterUnknownStartResponse(
        connectionID: String,
        excludingJobIDs: Set<String>,
        expectedConnectionSelectionGeneration: UInt64,
        expectedRefreshGeneration: UInt64,
        expectedOperationGeneration: UInt64
    ) async -> MutationRefreshOutcome {
        await Task { @MainActor [weak self] in
            guard let self else {
                return .failed
            }
            guard self.modelSyncOperationContextOwns(
                connectionID: connectionID,
                expectedConnectionSelectionGeneration:
                    expectedConnectionSelectionGeneration,
                expectedRefreshGeneration:
                    expectedRefreshGeneration,
                expectedOperationGeneration:
                    expectedOperationGeneration
            ) else {
                return .superseded
            }
            do {
                let jobs =
                    try await self.client.listProviderModelSyncs(
                        connectionID: connectionID,
                        limit: 64
                    )
                for job in jobs {
                    try self.validateStartedModelSyncJob(
                        job,
                        expectedConnectionID: connectionID
                    )
                }
                guard self.modelSyncOperationContextOwns(
                    connectionID: connectionID,
                    expectedConnectionSelectionGeneration:
                        expectedConnectionSelectionGeneration,
                    expectedRefreshGeneration:
                        expectedRefreshGeneration,
                    expectedOperationGeneration:
                        expectedOperationGeneration
                ) else {
                    return .superseded
                }
                let newJobs = jobs.filter {
                    !excludingJobIDs.contains($0.id)
                }
                guard newJobs.count == 1,
                      let recovered = newJobs.first,
                      let recoveredOperationGeneration =
                          self
                              .reconcileCommittedModelSyncJobIfVisible(
                                  recovered,
                                  expectedConnectionID:
                                      connectionID,
                                  allowsNewJob: true
                              )
                else {
                    return .failed
                }
                let eventOutcome =
                    await self.consumeModelSyncEvents(
                        jobID: recovered.id,
                        expectedConnectionID: connectionID,
                        expectedConnectionSelectionGeneration:
                            expectedConnectionSelectionGeneration,
                        expectedRefreshGeneration:
                            expectedRefreshGeneration,
                        expectedOperationGeneration:
                            recoveredOperationGeneration
                    )
                guard eventOutcome != .superseded else {
                    return .superseded
                }
                guard self.modelSyncContextOwns(
                    jobID: recovered.id,
                    expectedConnectionID: connectionID,
                    expectedConnectionSelectionGeneration:
                        expectedConnectionSelectionGeneration,
                    expectedRefreshGeneration:
                        expectedRefreshGeneration,
                    expectedOperationGeneration:
                        recoveredOperationGeneration
                ) else {
                    return .superseded
                }
                if self.modelSyncJob?.state.isTerminal == false {
                    self.startModelSyncMonitor(
                        jobID: recovered.id,
                        connectionID: connectionID,
                        expectedConnectionSelectionGeneration:
                            expectedConnectionSelectionGeneration,
                        expectedRefreshGeneration:
                            expectedRefreshGeneration,
                        expectedOperationGeneration:
                            recoveredOperationGeneration
                    )
                }
                return .success
            } catch {
                return self.modelSyncOperationContextOwns(
                    connectionID: connectionID,
                    expectedConnectionSelectionGeneration:
                        expectedConnectionSelectionGeneration,
                    expectedRefreshGeneration:
                        expectedRefreshGeneration,
                    expectedOperationGeneration:
                        expectedOperationGeneration
                )
                    ? .failed
                    : .superseded
            }
        }.value
    }

    private func reconcileDurableModelSyncJobIgnoringCallerCancellation(
        jobID: String,
        expectedConnectionID: String,
        allowsNewJob: Bool = false
    ) async -> MutationRefreshOutcome {
        await Task { @MainActor [weak self] in
            guard let self else {
                return .failed
            }
            do {
                let durable = try await self.client
                    .getProviderModelSync(jobID: jobID)
                try self.validateStartedModelSyncJob(
                    durable,
                    expectedConnectionID: expectedConnectionID
                )
                guard durable.id == jobID else {
                    return .failed
                }
                return self
                    .reconcileCommittedModelSyncJobIfVisible(
                        durable,
                        expectedConnectionID:
                            expectedConnectionID,
                        allowsNewJob: allowsNewJob
                    ) == nil
                    ? .superseded
                    : .success
            } catch {
                return self.selectedConnectionID
                    == expectedConnectionID
                    ? .failed
                    : .superseded
            }
        }.value
    }

    private func consumeModelSyncEventsIgnoringCallerCancellation(
        jobID: String,
        expectedConnectionID: String,
        expectedConnectionSelectionGeneration: UInt64,
        expectedRefreshGeneration: UInt64,
        expectedOperationGeneration: UInt64
    ) async -> MutationRefreshOutcome {
        await Task { @MainActor [weak self] in
            guard let self else {
                return .failed
            }
            return await self.consumeModelSyncEvents(
                jobID: jobID,
                expectedConnectionID: expectedConnectionID,
                expectedConnectionSelectionGeneration:
                    expectedConnectionSelectionGeneration,
                expectedRefreshGeneration:
                    expectedRefreshGeneration,
                expectedOperationGeneration:
                    expectedOperationGeneration
            )
        }.value
    }

    private func validateStartedModelSyncJob(
        _ job: ProviderModelSyncJob,
        expectedConnectionID: String
    ) throws {
        guard !job.id.isEmpty,
              job.connectionID == expectedConnectionID,
              job.revision > 0
        else {
            throw CoreClientFailure.invalidResponse(
                "모델 동기화 시작 결과의 작업 또는 연결 ID가 요청과 일치하지 않습니다."
            )
        }
    }

    private func validateModelSyncMutationResponse(
        _ updated: ProviderModelSyncJob,
        requestedJob: ProviderModelSyncJob,
        operation: ModelSyncMutationOperation
    ) throws {
        guard updated.id == requestedJob.id,
              updated.connectionID == requestedJob.connectionID,
              updated.revision >= requestedJob.revision
        else {
            throw CoreClientFailure.invalidResponse(
                "모델 동기화 결과가 요청한 작업 또는 연결과 일치하지 않습니다."
            )
        }
        let transitionIsLegal = switch operation {
        case .approve:
            requestedJob.state == .awaitingReview
                && (
                    updated.state == .awaitingReview
                        || updated.state == .completed
                        || updated.state == .failed
                )
        case .cancel:
            updated.state == .cancelled
        }
        guard transitionIsLegal else {
            throw CoreClientFailure.invalidResponse(
                "모델 동기화 결과의 상태 전이가 요청과 일치하지 않습니다."
            )
        }
    }

    private func publishConfigurationSnapshotIfResolved() {
        if activeGenerationTarget != nil,
           activeGenerationConnectionID == nil
        {
            publishNoActiveGenerationSelection()
            return
        }
        providerConfigurationStore.replace(
            connections: connections,
            selectedConnectionID: activeGenerationConnectionID,
            selectedGenerationTarget: activeGenerationTarget
        )
    }

    private func publishNoActiveGenerationSelection() {
        providerConfigurationStore.replace(
            connections: connections,
            selectedConnectionID: nil,
            selectedGenerationTarget: nil
        )
    }

    private func normalizedNonempty(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return normalized.isEmpty ? nil : normalized
    }

    private func safeFailureMessage(
        action: String,
        error: Error
    ) -> String {
        if case let CoreClientFailure.configurationRequired(message) = error {
            return message
        }
        if error is CredentialStoreError {
            return "\(action) 못했습니다. Keychain 상태를 확인하고 다시 시도하세요."
        }
        return "\(action) 못했습니다. 상태를 새로고침한 뒤 다시 시도하세요."
    }
}
