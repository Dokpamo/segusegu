import Foundation

public struct CoreVersionInfo: Equatable, Sendable {
    public let coreVersion: String
    public let coreAPIVersion: UInt32
    public let bindingAPIVersion: UInt32
    public let chatEventVersion: UInt32

    public init(
        coreVersion: String,
        coreAPIVersion: UInt32,
        bindingAPIVersion: UInt32,
        chatEventVersion: UInt32
    ) {
        self.coreVersion = coreVersion
        self.coreAPIVersion = coreAPIVersion
        self.bindingAPIVersion = bindingAPIVersion
        self.chatEventVersion = chatEventVersion
    }
}

public struct LibraryCharacter: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let symbolName: String

    public init(
        id: String,
        name: String,
        summary: String,
        symbolName: String = "person.crop.circle"
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.symbolName = symbolName
    }

    public static let previewCharacters: [LibraryCharacter] = [
        LibraryCharacter(
            id: "preview-librarian",
            name: "미리보기 안내자",
            summary: "테스트와 SwiftUI 프리뷰에서만 사용하는 합성 캐릭터입니다.",
            symbolName: "sparkles"
        ),
        LibraryCharacter(
            id: "preview-cartographer",
            name: "별빛 지도사",
            summary: "네이티브 화면 동작을 검증하기 위한 합성 자료입니다.",
            symbolName: "map"
        ),
    ]
}

public struct CoreCharacter: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let sourceHash: String
    public let avatarAssetHash: String?
    public let createdAt: String

    public init(
        id: String,
        name: String,
        description: String,
        sourceHash: String,
        avatarAssetHash: String?,
        createdAt: String
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.sourceHash = sourceHash
        self.avatarAssetHash = avatarAssetHash
        self.createdAt = createdAt
    }

    public var libraryCharacter: LibraryCharacter {
        LibraryCharacter(id: id, name: name, summary: description)
    }
}

public enum ConversationMode: String, CaseIterable, Equatable, Hashable, Sendable {
    case chat
    case story

    public var title: String {
        switch self {
        case .chat:
            "채팅"
        case .story:
            "스토리"
        }
    }
}

public struct CoreConversation: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let characterID: String
    public let title: String
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        characterID: String,
        title: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.characterID = characterID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CoreConversationBranch: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let conversationID: String
    public let title: String?
    public let forkMessageID: String?
    public let headMessageID: String?
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        conversationID: String,
        title: String?,
        forkMessageID: String?,
        headMessageID: String?,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.conversationID = conversationID
        self.title = title
        self.forkMessageID = forkMessageID
        self.headMessageID = headMessageID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CoreConversationState: Equatable, Sendable {
    public let conversationID: String
    public let activeBranchID: String
    public let selectedMode: ConversationMode
    public let updatedAt: String

    public init(
        conversationID: String,
        activeBranchID: String,
        selectedMode: ConversationMode,
        updatedAt: String
    ) {
        self.conversationID = conversationID
        self.activeBranchID = activeBranchID
        self.selectedMode = selectedMode
        self.updatedAt = updatedAt
    }
}

public struct CoreMessageActionGeneration: Equatable, Sendable {
    public let branch: CoreConversationBranch
    public let generationID: String

    public init(
        branch: CoreConversationBranch,
        generationID: String
    ) {
        self.branch = branch
        self.generationID = generationID
    }
}

public struct ChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: String, Equatable, Sendable {
        case system
        case user
        case assistant
        case notice
    }

    public enum Status: String, Equatable, Sendable {
        case pending
        case complete
        case cancelled
        case failed
        case notice
    }

    public let id: String
    public let conversationID: String?
    public let parentID: String?
    public let role: Role
    public var text: String
    public var status: Status
    public let generationID: String?
    public let createdAt: String?

    public init(
        id: String = UUID().uuidString,
        conversationID: String? = nil,
        parentID: String? = nil,
        role: Role,
        text: String,
        status: Status = .complete,
        generationID: String? = nil,
        createdAt: String? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.parentID = parentID
        self.role = role
        self.text = text
        self.status = status
        self.generationID = generationID
        self.createdAt = createdAt
    }
}

public struct ImportWarning: Identifiable, Equatable, Sendable {
    public let code: String
    public let message: String

    public var id: String {
        "\(code):\(message)"
    }

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct ImportImagePreview: Equatable, Sendable {
    public let logicalAssetID: String
    public let mediaType: String
    public let sizeBytes: UInt64

    public init(
        logicalAssetID: String,
        mediaType: String,
        sizeBytes: UInt64
    ) {
        self.logicalAssetID = logicalAssetID
        self.mediaType = mediaType
        self.sizeBytes = sizeBytes
    }
}

public struct ImportInspection: Identifiable, Equatable, Sendable {
    public let id: String
    public let contentKind: String
    public let displayName: String
    public let description: String
    public let sourceSHA256: String
    public let sourceSize: UInt64
    public let estimatedStoredSize: UInt64
    public let assetCount: UInt32
    public let warnings: [ImportWarning]
    public let blockedReasons: [String]
    public let isAllowed: Bool
    public let representativeImage: ImportImagePreview?
    public let unsupportedOptionalFields: [String]

    public init(
        id: String,
        contentKind: String,
        displayName: String,
        description: String,
        sourceSHA256: String,
        sourceSize: UInt64,
        estimatedStoredSize: UInt64,
        assetCount: UInt32,
        warnings: [ImportWarning],
        blockedReasons: [String],
        isAllowed: Bool,
        representativeImage: ImportImagePreview? = nil,
        unsupportedOptionalFields: [String] = []
    ) {
        self.id = id
        self.contentKind = contentKind
        self.displayName = displayName
        self.description = description
        self.sourceSHA256 = sourceSHA256
        self.sourceSize = sourceSize
        self.estimatedStoredSize = estimatedStoredSize
        self.assetCount = assetCount
        self.warnings = warnings
        self.blockedReasons = blockedReasons
        self.isAllowed = isAllowed
        self.representativeImage = representativeImage
        self.unsupportedOptionalFields = unsupportedOptionalFields
    }
}

public struct ProviderProfile: Identifiable, Equatable, Sendable {
    public let id: String
    public var displayName: String
    public var baseURL: String
    public var model: String
    public var timeoutSeconds: UInt32

    public init(
        id: String,
        displayName: String,
        baseURL: String,
        model: String,
        timeoutSeconds: UInt32
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct CoreAppSettings: Equatable, Sendable {
    public var preservePartialGenerations: Bool
    /// Retained only so existing databases can be read and migrated.
    ///
    /// New model selection writes use `selectedGenerationTarget`.
    public var selectedProviderProfileID: String?
    public var selectedModelRouteID: String?
    public var selectedGenerationPresetID: String?

    public init(
        preservePartialGenerations: Bool,
        selectedProviderProfileID: String?,
        selectedModelRouteID: String? = nil,
        selectedGenerationPresetID: String? = nil
    ) {
        self.preservePartialGenerations = preservePartialGenerations
        self.selectedProviderProfileID = selectedProviderProfileID
        self.selectedModelRouteID = selectedModelRouteID
        self.selectedGenerationPresetID = selectedGenerationPresetID
    }

    public var selectedGenerationTarget: ProviderGenerationTarget? {
        guard let selectedModelRouteID,
              let selectedGenerationPresetID
        else {
            return nil
        }
        return ProviderGenerationTarget(
            modelRouteID: selectedModelRouteID,
            generationPresetID: selectedGenerationPresetID
        )
    }
}

public struct ChatEvent: Equatable, Sendable {
    public let eventVersion: UInt32
    public let generationID: String
    public let conversationID: String
    public let branchID: String?
    public let assistantMessageID: String?
    public let sequence: UInt64
    public let emittedAt: String
    public let kind: String
    public let text: String?
    public let messageID: String?
    public let messageStatus: String?
    public let errorCode: String?
    public let errorMessage: String?
    public let usageInputTokens: UInt64?
    public let usageOutputTokens: UInt64?

    public init(
        eventVersion: UInt32 = CoreRuntimeContract.chatEventVersion,
        generationID: String,
        conversationID: String,
        branchID: String? = nil,
        assistantMessageID: String? = nil,
        sequence: UInt64,
        emittedAt: String = "",
        kind: String,
        text: String? = nil,
        messageID: String? = nil,
        messageStatus: String? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        usageInputTokens: UInt64? = nil,
        usageOutputTokens: UInt64? = nil
    ) {
        self.eventVersion = eventVersion
        self.generationID = generationID
        self.conversationID = conversationID
        self.branchID = branchID
        self.assistantMessageID = assistantMessageID
        self.sequence = sequence
        self.emittedAt = emittedAt
        self.kind = kind
        self.text = text
        self.messageID = messageID
        self.messageStatus = messageStatus
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.usageInputTokens = usageInputTokens
        self.usageOutputTokens = usageOutputTokens
    }
}

public struct ChatEventBatch: Equatable, Sendable {
    public let events: [ChatEvent]
    public let droppedEventCount: UInt64

    public init(events: [ChatEvent], droppedEventCount: UInt64) {
        self.events = events
        self.droppedEventCount = droppedEventCount
    }
}

public struct DatabaseStats: Equatable, Sendable {
    public let characters: UInt64
    public let conversations: UInt64
    public let messages: UInt64
    public let pendingImports: UInt64

    public init(
        characters: UInt64,
        conversations: UInt64,
        messages: UInt64,
        pendingImports: UInt64
    ) {
        self.characters = characters
        self.conversations = conversations
        self.messages = messages
        self.pendingImports = pendingImports
    }
}

public struct ImportCandidate: Identifiable, Equatable, Sendable {
    public let sourceURL: URL
    public let displayName: String

    public var id: URL {
        sourceURL
    }

    public init(sourceURL: URL) {
        self.sourceURL = sourceURL
        displayName = sourceURL.lastPathComponent
    }
}
