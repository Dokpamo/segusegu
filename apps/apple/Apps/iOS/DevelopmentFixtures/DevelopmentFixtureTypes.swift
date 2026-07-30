#if DEBUG
import Foundation
import LorepiaKit

enum DevelopmentFixtureScenario: String, CaseIterable {
    case comprehensive
    case empty
    case providerMissing
    case credentialMissing
    case providerUnselected
    case healthWarning
    case coreUnavailable
    case load
}

struct IOSDevelopmentFixtureSet {
    let characters: [LibraryCharacter]
    let coreCharacters: [CoreCharacter]
    let profiles: [ProviderProfile]
    let credentialValues: [String: String]
    let settings: CoreAppSettings
    let initialConversationMessages: [ChatMessage]
    let conversations: [FakeConversationFixture]
    let conversationGraphs: [FakeConversationGraphFixture]
    let health: HealthStatus

    init(
        characters: [LibraryCharacter],
        profiles: [ProviderProfile],
        credentialValues: [String: String],
        settings: CoreAppSettings,
        initialConversationMessages: [ChatMessage],
        conversations: [FakeConversationFixture],
        conversationGraphs: [FakeConversationGraphFixture],
        health: HealthStatus
    ) {
        self.characters = characters
        coreCharacters = characters.map {
            CoreCharacter(
                id: $0.id,
                name: $0.name,
                description: $0.summary,
                sourceHash: "synthetic-\($0.id)",
                avatarAssetHash: nil,
                createdAt: DevelopmentFixtureClock.timestamp(
                    DevelopmentFixtureClock.characterCreationDate
                )
            )
        }
        self.profiles = profiles
        self.credentialValues = credentialValues
        self.settings = settings
        self.initialConversationMessages = initialConversationMessages
        self.conversations = conversations
        self.conversationGraphs = conversationGraphs
        self.health = health

        validate()
    }

    private func validate() {
        precondition(
            Set(characters.map(\.id)).count == characters.count,
            "Development fixture character IDs must be unique."
        )
        precondition(
            Set(profiles.map(\.id)).count == profiles.count,
            "Development fixture provider IDs must be unique."
        )
        precondition(
            Set(
                conversations.map(\.conversation.id)
                    + conversationGraphs.map(\.conversation.id)
            ).count == conversations.count + conversationGraphs.count,
            "Development fixture conversation IDs must be unique."
        )

        let characterIDs = Set(characters.map(\.id))
        precondition(
            (
                conversations.map(\.conversation)
                    + conversationGraphs.map(\.conversation)
            ).allSatisfy {
                characterIDs.contains($0.characterID)
            },
            "Every development conversation must reference a character."
        )

        let knownProviderIDs = Set(profiles.map(\.id))
        precondition(
            Set(credentialValues.keys).isSubset(of: knownProviderIDs),
            "Development credentials must reference an existing provider."
        )
        if let selectedProfileID = settings.selectedProviderProfileID {
            precondition(
                knownProviderIDs.contains(selectedProfileID),
                "The selected development provider must exist."
            )
        }

        let allMessages = initialConversationMessages
            + conversations.flatMap(\.messages)
            + conversationGraphs.flatMap { graph in
                graph.branches.flatMap(\.messages)
            }
        precondition(
            allMessages.allSatisfy { $0.status != .pending },
            "Pending messages would be mistaken for live generations."
        )
        let legacyMessages = initialConversationMessages
            + conversations.flatMap(\.messages)
        precondition(
            Set(legacyMessages.map(\.id)).count == legacyMessages.count,
            "Development fixture message IDs must be unique."
        )

        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for fixture in conversations {
            guard
                let createdAt = parser.date(
                    from: fixture.conversation.createdAt
                ),
                let updatedAt = parser.date(
                    from: fixture.conversation.updatedAt
                )
            else {
                preconditionFailure(
                    "Development conversation timestamps must be ISO-8601."
                )
            }
            precondition(
                createdAt <= updatedAt,
                "A development conversation cannot update before creation."
            )

            var previousMessageDate: Date?
            for message in fixture.messages {
                guard
                    let timestamp = message.createdAt,
                    let messageDate = parser.date(from: timestamp)
                else {
                    preconditionFailure(
                        "Development messages need ISO-8601 timestamps."
                    )
                }
                if let previousMessageDate {
                    precondition(
                        previousMessageDate <= messageDate,
                        "Development messages must be chronological."
                    )
                }
                precondition(
                    messageDate <= updatedAt,
                    "A message cannot be newer than its conversation."
                )
                previousMessageDate = messageDate
            }
        }
    }
}

enum DevelopmentFixtureClock {
    static let minute: TimeInterval = 60
    static let hour: TimeInterval = 60 * minute
    static let day: TimeInterval = 24 * hour
    static let characterCreationDate = Date(
        timeIntervalSince1970: 1_767_225_600
    )

    static func timestamp(_ date: Date) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        )
    }
}
#endif
