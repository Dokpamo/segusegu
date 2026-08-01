import Foundation

public struct HealthStatus: Equatable, Sendable {
    public let coreVersion: String
    public let databaseOpen: Bool
    public let schemaVersion: UInt32
    public let dataRootWritable: Bool
    public let stagingWritable: Bool
    public let recoveryPending: Bool
    public let activeJobs: UInt32

    public init(
        coreVersion: String,
        databaseOpen: Bool,
        schemaVersion: UInt32,
        dataRootWritable: Bool,
        stagingWritable: Bool,
        recoveryPending: Bool,
        activeJobs: UInt32
    ) {
        self.coreVersion = coreVersion
        self.databaseOpen = databaseOpen
        self.schemaVersion = schemaVersion
        self.dataRootWritable = dataRootWritable
        self.stagingWritable = stagingWritable
        self.recoveryPending = recoveryPending
        self.activeJobs = activeJobs
    }

    public var isHealthy: Bool {
        databaseOpen
            && dataRootWritable
            && stagingWritable
            && !recoveryPending
    }
}

public enum CoreClientFailure: Error, Equatable, Sendable {
    case bindingsUnavailable
    case startupFailed(String)
    case invalidResponse(String)
    case configurationRequired(String)
}

/// The native surface and generated UniFFI source are released as one
/// versioned contract. Fail closed when a different core is loaded instead of
/// silently dropping events or interpreting newer DTOs with older semantics.
public enum CoreRuntimeContract {
    public static let coreAPIVersion: UInt32 = 8
    public static let bindingAPIVersion: UInt32 = 8
    public static let chatEventVersion: UInt32 = 4
    public static let providerDiscoverySnapshotSchemaVersion: UInt32 = 3
    public static let providerDiscoveryEventVersion: UInt32 = 2
    public static let providerModelSyncEventVersion: UInt32 = 1
    public static let providerModelSyncRedactionVersion: UInt32 = 1

    public static func validate(_ versions: CoreVersionInfo) throws {
        guard versions.coreAPIVersion == coreAPIVersion,
              versions.bindingAPIVersion == bindingAPIVersion,
              versions.chatEventVersion == chatEventVersion
        else {
            throw CoreClientFailure.invalidResponse(
                "지원하지 않는 Core API 조합입니다. "
                    + "필요: Core \(coreAPIVersion), "
                    + "Binding \(bindingAPIVersion), "
                    + "Chat \(chatEventVersion)."
            )
        }
    }

    public static func validateProviderDiscoverySnapshotVersion(
        _ version: UInt32
    ) throws {
        guard version == providerDiscoverySnapshotSchemaVersion else {
            throw CoreClientFailure.invalidResponse(
                "지원하지 않는 provider discovery snapshot 버전입니다."
            )
        }
    }

    public static func validateProviderDiscoveryEventVersion(
        _ version: UInt32
    ) throws {
        guard version == providerDiscoveryEventVersion else {
            throw CoreClientFailure.invalidResponse(
                "지원하지 않는 provider discovery event 버전입니다."
            )
        }
    }

    public static func validateProviderModelSyncEventVersions(
        version: UInt32,
        redactionVersion: UInt32
    ) throws {
        guard version == providerModelSyncEventVersion,
              redactionVersion == providerModelSyncRedactionVersion
        else {
            throw CoreClientFailure.invalidResponse(
                "지원하지 않는 provider model sync event 버전입니다."
            )
        }
    }
}

extension CoreClientFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .bindingsUnavailable:
            "이 빌드에 Rust UniFFI 바인딩이 포함되지 않았습니다."
        case let .startupFailed(message):
            "Rust 코어를 열지 못했습니다: \(message)"
        case let .invalidResponse(message):
            "Rust 코어 응답을 해석할 수 없습니다: \(message)"
        case let .configurationRequired(message):
            message
        }
    }
}

public protocol CoreClient: Sendable {
    func version() async throws -> String
    func apiVersions() async throws -> CoreVersionInfo
    func health() async throws -> HealthStatus
    func listCharacters() async throws -> [CoreCharacter]
    func getCharacter(id: String) async throws -> CoreCharacter
    func inspectImport(stagedURL: URL) async throws -> ImportInspection
    func discardImport(inspectionID: String) async throws
    func commitImport(inspectionID: String) async throws -> CoreCharacter
    func listConversations() async throws -> [CoreConversation]
    func openConversation(characterID: String) async throws -> CoreConversation
    func createConversation(
        characterID: String,
        title: String,
        mode: ConversationMode
    ) async throws -> CoreConversation
    func listConversations(characterID: String) async throws -> [CoreConversation]
    func getConversation(id: String) async throws -> CoreConversation
    func getConversationState(
        conversationID: String
    ) async throws -> CoreConversationState
    func listConversationBranches(
        conversationID: String
    ) async throws -> [CoreConversationBranch]
    func createConversationBranch(
        conversationID: String,
        fromMessageID: String?,
        title: String?
    ) async throws -> CoreConversationBranch
    func selectConversationBranch(
        conversationID: String,
        branchID: String
    ) async throws -> CoreConversationState
    func setConversationMode(
        conversationID: String,
        mode: ConversationMode
    ) async throws -> CoreConversationState
    func listMessages(conversationID: String) async throws -> [ChatMessage]
    func listBranchMessages(branchID: String) async throws -> [ChatMessage]
    func sendMessage(
        conversationID: String,
        text: String,
        providerProfileID: String,
        credential: String?
    ) async throws -> String
    func sendMessageWithTarget(
        conversationID: String,
        text: String,
        target: ProviderGenerationTarget,
        credential: String?
    ) async throws -> String
    func sendMessageToBranch(
        conversationID: String,
        branchID: String,
        expectedHeadMessageID: String?,
        mode: ConversationMode,
        text: String,
        providerProfileID: String,
        credential: String?
    ) async throws -> String
    func sendMessageToBranchWithTarget(
        conversationID: String,
        branchID: String,
        expectedHeadMessageID: String?,
        mode: ConversationMode,
        text: String,
        target: ProviderGenerationTarget,
        credential: String?
    ) async throws -> String
    func editUserMessage(
        conversationID: String,
        branchID: String,
        expectedHeadMessageID: String?,
        messageID: String,
        replacementText: String,
        providerProfileID: String,
        credential: String?
    ) async throws -> CoreMessageActionGeneration
    func editUserMessageWithTarget(
        conversationID: String,
        branchID: String,
        expectedHeadMessageID: String?,
        messageID: String,
        replacementText: String,
        target: ProviderGenerationTarget,
        credential: String?
    ) async throws -> CoreMessageActionGeneration
    func regenerateAssistantMessage(
        conversationID: String,
        branchID: String,
        expectedHeadMessageID: String?,
        messageID: String,
        providerProfileID: String,
        credential: String?
    ) async throws -> CoreMessageActionGeneration
    func regenerateAssistantMessageWithTarget(
        conversationID: String,
        branchID: String,
        expectedHeadMessageID: String?,
        messageID: String,
        target: ProviderGenerationTarget,
        credential: String?
    ) async throws -> CoreMessageActionGeneration
    func removeMessageFromBranch(
        conversationID: String,
        branchID: String,
        expectedHeadMessageID: String?,
        messageID: String
    ) async throws -> CoreConversationBranch
    func cancelGeneration(generationID: String) async throws
    func pollEvents(maxEvents: UInt32) async throws -> ChatEventBatch
    func listProviderProfiles() async throws -> [ProviderProfile]
    func upsertProviderProfile(_ profile: ProviderProfile) async throws -> ProviderProfile
    func deleteProviderProfile(id: String) async throws
    func getSettings() async throws -> CoreAppSettings
    func updateSettings(_ settings: CoreAppSettings) async throws -> CoreAppSettings
    func setPreservePartialGenerations(_ value: Bool) async throws
        -> CoreAppSettings
    func selectProviderProfile(id: String?) async throws -> CoreAppSettings
    func selectProviderGenerationTarget(
        _ target: ProviderGenerationTarget?
    ) async throws -> CoreAppSettings
    func listProviderTemplates() async throws
        -> [ProviderTemplateDescriptor]
    func listProviderConnections() async throws
        -> [ProviderConnectionRecord]
    func deleteProviderConnection(id: String) async throws
    func listProviderModelRoutes(connectionID: String) async throws
        -> [ProviderModelRoute]
    func listProviderGenerationPresets(modelRouteID: String) async throws
        -> [ProviderGenerationPreset]
    func upsertProviderGenerationPreset(
        _ preset: ProviderGenerationPreset
    ) async throws -> ProviderGenerationPreset
    func validateProviderGenerationPreset(
        modelRouteID: String,
        generationPresetID: String
    ) async throws
    func validateProviderGenerationPresetCandidate(
        _ preset: ProviderGenerationPreset
    ) async throws
    func renderProviderReasoningControl(
        for preset: ProviderGenerationPreset
    ) async throws -> ProviderReasoningControl
    func renderProviderPromptCacheControl(
        for preset: ProviderGenerationPreset
    ) async throws -> ProviderPromptCacheControl
    func deleteProviderGenerationPreset(id: String) async throws
    func listProviderCapabilities(modelRouteID: String) async throws
        -> [ProviderEffectiveCapability]
    func listProviderParameterSpecs(modelRouteID: String) async throws
        -> [ProviderParameterSpec]
    func inspectProviderCurl(
        _ rawCurl: String,
        networkPolicy: ProviderNetworkPolicy
    ) async throws -> ProviderCurlInspection
    func takeProviderCurlCredential(
        handoffID: String
    ) async throws -> Data?
    func beginProviderDiscovery(
        input: ProviderDiscoveryInput,
        source: ProviderDiscoverySource,
        rawCurl: String?
    ) async throws -> ProviderDiscoverySnapshot
    func prepareProviderDiscoveryAction(
        actionID: String,
        expectedRevision: UInt64,
        action: ProviderDiscoveryAction
    ) async throws -> ProviderDiscoveryActionEnvelope
    func continueProviderDiscovery(
        sessionID: String,
        envelope: ProviderDiscoveryActionEnvelope,
        targetCredential: String?
    ) async throws -> ProviderDiscoverySnapshot
    func supplyProviderDiscoveryDocumentEvidence(
        sessionID: String,
        expectedRevision: UInt64,
        documentURL: String
    ) async throws -> ProviderDiscoverySnapshot
    func supplyProviderDiscoveryCurlEvidence(
        sessionID: String,
        expectedRevision: UInt64,
        redactedCurl: String
    ) async throws -> ProviderDiscoverySnapshot
    func runProviderDiscoveryAssistantTurn(
        sessionID: String,
        estimate: ProviderDiscoveryAssistantCallEstimate,
        assistantCredential: String?
    ) async throws -> ProviderDiscoveryAssistantHostAction
    func resumeProviderDiscoveryAssistantCoreHostAction(
        sessionID: String
    ) async throws -> ProviderDiscoverySnapshot
    func approveProviderDiscoveryAssistantRetry(
        sessionID: String
    ) async throws -> ProviderDiscoverySnapshot
    func requestProviderDiscoveryAssistantRevision(
        sessionID: String
    ) async throws -> ProviderDiscoverySnapshot
    func acceptProviderDiscoveryAssistantDraft(
        sessionID: String
    ) async throws -> ProviderDiscoverySnapshot
    func recordProviderDiscoveryAssistantFailure(
        sessionID: String,
        kind: String,
        retryable: Bool
    ) async throws -> ProviderDiscoverySnapshot
    func getProviderDiscovery(
        sessionID: String
    ) async throws -> ProviderDiscoverySnapshot
    func listProviderDiscoveries(
        limit: UInt32
    ) async throws -> [ProviderDiscoverySnapshot]
    func cancelProviderDiscovery(
        sessionID: String,
        expectedRevision: UInt64
    ) async throws -> ProviderDiscoverySnapshot
    func commitProviderDiscovery(
        sessionID: String,
        credentialSlotConfirmed: Bool
    ) async throws -> ProviderConnectionRecord
    func listProviderDiscoveryCompensationSteps(
        commitAttemptID: String
    ) async throws -> [ProviderDiscoveryCompensationStep]
    func continueProviderDiscoveryCompensation(
        sessionID: String
    ) async throws -> ProviderDiscoverySnapshot
    func startProviderDiscoveryCredentialCompensation(
        sessionID: String,
        stepID: String
    ) async throws -> ProviderDiscoveryCompensationStep
    func completeProviderDiscoveryCredentialCompensation(
        sessionID: String,
        stepID: String
    ) async throws -> ProviderDiscoverySnapshot
    func failProviderDiscoveryCredentialCompensation(
        sessionID: String,
        stepID: String,
        failure: ProviderDiscoveryFailure
    ) async throws -> ProviderDiscoverySnapshot
    func markProviderDiscoveryCredentialCompensationUnknown(
        sessionID: String,
        stepID: String
    ) async throws -> ProviderDiscoverySnapshot
    func resumeProviderDiscoveryCompensation(
        sessionID: String
    ) async throws -> ProviderDiscoverySnapshot
    func recoverProviderDiscoveries() async throws
        -> [ProviderDiscoveryRecoveryResult]
    func pollProviderDiscoveryEvents(
        limit: UInt32
    ) async throws -> [ProviderDiscoveryOutboxEvent]
    func ackProviderDiscoveryEvent(eventID: String) async throws -> Bool
    func startProviderModelSync(
        connectionID: String,
        credential: String?
    ) async throws -> ProviderModelSyncJob
    func getProviderModelSync(jobID: String) async throws
        -> ProviderModelSyncJob
    func listProviderModelSyncs(
        connectionID: String,
        limit: UInt32
    ) async throws -> [ProviderModelSyncJob]
    func pollProviderModelSyncEvents(
        jobID: String,
        limit: UInt32
    ) async throws -> [ProviderModelSyncEvent]
    func ackProviderModelSyncEvent(
        jobID: String,
        sequence: UInt64
    ) async throws -> Bool
    func approveProviderModelSync(
        jobID: String,
        expectedRevision: UInt64,
        reviewSHA256: String
    ) async throws -> ProviderModelSyncJob
    func cancelProviderModelSync(
        jobID: String,
        expectedRevision: UInt64
    ) async throws -> ProviderModelSyncJob
    func getProviderCatalogStatus() async throws -> ProviderCatalogStatus
    func prepareSignedProviderCatalogImport(
        envelopeJSON: Data
    ) async throws -> ProviderCatalogImportPlan
    func activateSignedProviderCatalogImport(
        plan: ProviderCatalogImportPlan,
        envelopeJSON: Data
    ) async throws -> ProviderCatalogImportResult
    func prepareProviderCatalogRollback(
        targetRevision: UInt64
    ) async throws -> ProviderCatalogRollbackPlan
    func activateProviderCatalogRollback(
        plan: ProviderCatalogRollbackPlan
    ) async throws -> ProviderCatalogRollbackResult
    func previewProviderRequest(
        modelRouteID: String,
        generationPresetID: String
    ) async throws -> ProviderRequestPreview
    func previewProviderRequestCandidate(
        _ preset: ProviderGenerationPreset
    ) async throws -> ProviderRequestPreview
    func databaseStats() async throws -> DatabaseStats
}

public enum CoreRuntimeMode: Equatable, Sendable {
    case live
    case preview
    case unavailable(String)

    public var displayName: String {
        switch self {
        case .live:
            "Rust Core"
        case .preview:
            "Preview Core"
        case .unavailable:
            "Core Unavailable"
        }
    }
}

public struct CoreClientSelection: Sendable {
    public let client: any CoreClient
    public let mode: CoreRuntimeMode

    public init(client: any CoreClient, mode: CoreRuntimeMode) {
        self.client = client
        self.mode = mode
    }
}
