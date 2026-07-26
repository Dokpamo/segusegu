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
    func sendMessageToBranch(
        conversationID: String,
        branchID: String,
        expectedHeadMessageID: String?,
        mode: ConversationMode,
        text: String,
        providerProfileID: String,
        credential: String?
    ) async throws -> String
    func cancelGeneration(generationID: String) async throws
    func pollEvents(maxEvents: UInt32) async throws -> ChatEventBatch
    func listProviderProfiles() async throws -> [ProviderProfile]
    func upsertProviderProfile(_ profile: ProviderProfile) async throws -> ProviderProfile
    func deleteProviderProfile(id: String) async throws
    func getSettings() async throws -> CoreAppSettings
    func updateSettings(_ settings: CoreAppSettings) async throws -> CoreAppSettings
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
