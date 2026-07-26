import Foundation

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
            summary: "생성 바인딩이 없는 프레임 빌드에서만 표시되는 합성 캐릭터입니다.",
            symbolName: "sparkles"
        ),
        LibraryCharacter(
            id: "preview-cartographer",
            name: "별빛 지도사",
            summary: "서재와 채팅 화면의 네이티브 동작을 확인하기 위한 합성 자료입니다.",
            symbolName: "map"
        ),
    ]
}

public struct ChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        case user
        case assistant
        case notice
    }

    public let id: UUID
    public let role: Role
    public let text: String

    public init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
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
