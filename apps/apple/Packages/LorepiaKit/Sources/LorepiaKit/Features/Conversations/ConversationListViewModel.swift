import Combine
import Foundation

public extension ConversationMode {
    var systemImage: String {
        switch self {
        case .chat:
            "bubble.left.and.bubble.right"
        case .story:
            "book.pages"
        }
    }

    var detail: String {
        switch self {
        case .chat:
            "짧은 대화를 말풍선으로 주고받습니다."
        case .story:
            "장면과 서술을 중심으로 이야기를 이어갑니다."
        }
    }
}

public struct ConversationListItem: Identifiable, Equatable, Hashable, Sendable {
    public let conversation: CoreConversation
    public let character: LibraryCharacter?
    public let lastMessage: ChatMessage?
    public let mode: ConversationMode?

    public var id: String {
        conversation.id
    }

    public var displayTitle: String {
        let title = conversation.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !title.isEmpty {
            return title
        }
        return character?.name ?? "대화"
    }

    public var previewText: String {
        let preview = lastMessage?.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if let preview, !preview.isEmpty {
            return preview
        }
        return "아직 메시지가 없습니다."
    }

    public var updatedDate: Date? {
        ConversationListTimestamp.date(from: conversation.updatedAt)
    }

    public init(
        conversation: CoreConversation,
        character: LibraryCharacter?,
        lastMessage: ChatMessage?,
        mode: ConversationMode? = nil
    ) {
        self.conversation = conversation
        self.character = character
        self.lastMessage = lastMessage
        self.mode = mode
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

@MainActor
public final class ConversationListViewModel: ObservableObject {
    @Published public var query = ""
    @Published public private(set) var items: [ConversationListItem]
    @Published public private(set) var characters: [LibraryCharacter]
    @Published public private(set) var isLoading = false
    @Published public private(set) var hasLoaded = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isCreatingConversation = false
    @Published public private(set) var creationErrorMessage: String?

    private let client: any CoreClient
    private var modeOverrides: [String: ConversationMode]

    public init(
        client: any CoreClient,
        initialItems: [ConversationListItem] = [],
        initialCharacters: [LibraryCharacter] = []
    ) {
        self.client = client
        items = Self.sort(initialItems)
        characters = initialCharacters
        modeOverrides = Dictionary(
            uniqueKeysWithValues: initialItems.compactMap { item in
                item.mode.map { (item.id, $0) }
            }
        )
        hasLoaded = !initialItems.isEmpty || !initialCharacters.isEmpty
    }

    public var filteredItems: [ConversationListItem] {
        let searchTerm = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !searchTerm.isEmpty else {
            return items
        }

        return items.filter { item in
            [
                item.displayTitle,
                item.character?.name,
                item.lastMessage?.text,
                item.mode?.title,
            ]
            .compactMap { $0 }
            .contains {
                $0.localizedStandardContains(searchTerm)
            }
        }
    }

    public func refresh() async {
        guard !isLoading else {
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            async let coreCharactersTask = client.listCharacters()
            async let conversationsTask = client.listConversations()
            let (coreCharacters, conversations) = try await (
                coreCharactersTask,
                conversationsTask
            )
            let loadedCharacters = coreCharacters.map(\.libraryCharacter)
            async let lastMessagesTask = loadLastMessages(
                for: conversations
            )
            async let modesTask = loadModes(for: conversations)
            let (lastMessages, loadedModes) = try await (
                lastMessagesTask,
                modesTask
            )

            characters = loadedCharacters
            modeOverrides = loadedModes
            items = Self.makeItems(
                conversations: conversations,
                characters: loadedCharacters,
                lastMessages: lastMessages,
                modeOverrides: modeOverrides
            )
            errorMessage = nil
            hasLoaded = true
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            hasLoaded = true
        }
    }

    @discardableResult
    public func createConversation(
        character: LibraryCharacter,
        mode: ConversationMode
    ) async -> ConversationListItem? {
        guard !isCreatingConversation else {
            return nil
        }

        isCreatingConversation = true
        creationErrorMessage = nil
        defer { isCreatingConversation = false }

        do {
            let characterConversationCount = items.count {
                $0.conversation.characterID == character.id
            }
            let title = characterConversationCount == 0
                ? character.name
                : "\(character.name) · \(characterConversationCount + 1)번째 대화"
            let conversation = try await client.createConversation(
                characterID: character.id,
                title: title,
                mode: mode
            )
            modeOverrides[conversation.id] = mode
            let item = ConversationListItem(
                conversation: conversation,
                character: character,
                lastMessage: nil,
                mode: mode
            )
            items.removeAll { $0.id == item.id }
            items.insert(item, at: 0)
            if !characters.contains(where: { $0.id == character.id }) {
                characters.append(character)
                characters.sort {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }
            return item
        } catch is CancellationError {
            return nil
        } catch {
            creationErrorMessage = error.localizedDescription
            return nil
        }
    }

    public func clearCreationError() {
        creationErrorMessage = nil
    }

    private func loadLastMessages(
        for conversations: [CoreConversation]
    ) async throws -> [String: ChatMessage] {
        let client = self.client
        return try await withThrowingTaskGroup(
            of: (String, ChatMessage?).self,
            returning: [String: ChatMessage].self
        ) { group in
            for conversation in conversations {
                group.addTask {
                    let messages = try await client.listMessages(
                        conversationID: conversation.id
                    )
                    return (
                        conversation.id,
                        Self.lastPreviewMessage(in: messages)
                    )
                }
            }

            var messagesByConversation: [String: ChatMessage] = [:]
            for try await (conversationID, message) in group {
                if let message {
                    messagesByConversation[conversationID] = message
                }
            }
            return messagesByConversation
        }
    }

    private func loadModes(
        for conversations: [CoreConversation]
    ) async throws -> [String: ConversationMode] {
        let client = self.client
        return try await withThrowingTaskGroup(
            of: (String, ConversationMode).self,
            returning: [String: ConversationMode].self
        ) { group in
            for conversation in conversations {
                group.addTask {
                    let state = try await client.getConversationState(
                        conversationID: conversation.id
                    )
                    return (conversation.id, state.selectedMode)
                }
            }

            var modesByConversation: [String: ConversationMode] = [:]
            for try await (conversationID, mode) in group {
                modesByConversation[conversationID] = mode
            }
            return modesByConversation
        }
    }

    nonisolated static func makeItems(
        conversations: [CoreConversation],
        characters: [LibraryCharacter],
        lastMessages: [String: ChatMessage],
        modeOverrides: [String: ConversationMode] = [:]
    ) -> [ConversationListItem] {
        let charactersByID = Dictionary(
            characters.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return sort(
            conversations.map { conversation in
                ConversationListItem(
                    conversation: conversation,
                    character: charactersByID[conversation.characterID],
                    lastMessage: lastMessages[conversation.id],
                    mode: modeOverrides[conversation.id]
                )
            }
        )
    }

    nonisolated static func lastPreviewMessage(
        in messages: [ChatMessage]
    ) -> ChatMessage? {
        messages.reversed().first { message in
            (message.role == .user || message.role == .assistant)
                && !message.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
        }
    }

    nonisolated static func sort(
        _ items: [ConversationListItem]
    ) -> [ConversationListItem] {
        items.sorted { lhs, rhs in
            switch (lhs.updatedDate, rhs.updatedDate) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                if lhs.conversation.updatedAt != rhs.conversation.updatedAt {
                    return lhs.conversation.updatedAt
                        > rhs.conversation.updatedAt
                }
                return lhs.id < rhs.id
            }
        }
    }
}

enum ConversationListTimestamp {
    static func date(from timestamp: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(
            includingFractionalSeconds: true
        ).parse(timestamp) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(timestamp)
    }

    static func shortLabel(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(
                Date.FormatStyle(
                    date: .omitted,
                    time: .shortened,
                    locale: locale,
                    calendar: calendar,
                    timeZone: calendar.timeZone
                )
            )
        }
        if let yesterday = calendar.date(
            byAdding: .day,
            value: -1,
            to: now
        ), calendar.isDate(date, inSameDayAs: yesterday) {
            return "어제"
        }
        return date.formatted(
            Date.FormatStyle(
                date: .abbreviated,
                time: .omitted,
                locale: locale,
                calendar: calendar,
                timeZone: calendar.timeZone
            )
        )
    }

    static func accessibilityLabel(
        for date: Date,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        date.formatted(
            Date.FormatStyle(
                date: .complete,
                time: .shortened,
                locale: locale,
                calendar: calendar,
                timeZone: calendar.timeZone
            )
        )
    }
}
