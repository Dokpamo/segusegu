#if DEBUG
import Foundation
import LorepiaKit

@MainActor
enum DevelopmentFixtures {
    static func makeEnvironment(
        for scenario: DevelopmentFixtureScenario,
        anchor: Date = Date()
    ) -> AppEnvironment {
        if scenario == .coreUnavailable {
            let message = "개발용 코어 연결 실패 시나리오"
            return AppEnvironment(
                coreClient: UnavailableCoreClient(message: message),
                runtimeMode: .unavailable(message),
                credentialStore: InMemoryCredentialStore(),
                characters: []
            )
        }

        let fixtureSet = makeFixtureSet(
            for: scenario,
            anchor: anchor
        )
        let client: FakeCoreClient
        do {
            client = try FakeCoreClient(
                version: DevelopmentProviderCatalog.coreVersion,
                health: fixtureSet.health,
                characters: fixtureSet.coreCharacters,
                profiles: fixtureSet.profiles,
                initialSettings: fixtureSet.settings,
                initialConversationMessages:
                    fixtureSet.initialConversationMessages,
                initialConversationFixtures: fixtureSet.conversations,
                initialConversationGraphs:
                    fixtureSet.conversationGraphs
            )
        } catch {
            preconditionFailure(
                "Invalid development fixtures: \(error.localizedDescription)"
            )
        }
        return AppEnvironment(
            coreClient: client,
            runtimeMode: .preview,
            credentialStore: InMemoryCredentialStore(
                values: fixtureSet.credentialValues
            ),
            characters: fixtureSet.characters
        )
    }

    static func makeFixtureSet(
        for scenario: DevelopmentFixtureScenario,
        anchor: Date = Date()
    ) -> IOSDevelopmentFixtureSet {
        let conversations =
            DevelopmentConversationCatalog.comprehensiveFixtures(
                anchor: anchor
            )
        let conversationGraphs = [
            DevelopmentBranchCatalog.moaBlue17Graph(anchor: anchor),
        ]
        let selectedProviderSettings = CoreAppSettings(
            preservePartialGenerations: true,
            selectedProviderProfileID:
                DevelopmentProviderCatalog.profiles.first?.id
        )
        let unselectedProviderSettings = CoreAppSettings(
            preservePartialGenerations: true,
            selectedProviderProfileID: nil
        )

        switch scenario {
        case .comprehensive:
            return IOSDevelopmentFixtureSet(
                characters: DevelopmentCharacterCatalog.characters,
                profiles: DevelopmentProviderCatalog.profiles,
                credentialValues:
                    DevelopmentProviderCatalog.credentialValues,
                settings: selectedProviderSettings,
                initialConversationMessages:
                    DevelopmentMessageCatalog.initialConversationMessages,
                conversations: conversations,
                conversationGraphs: conversationGraphs,
                health: DevelopmentProviderCatalog.healthy
            )

        case .empty:
            return IOSDevelopmentFixtureSet(
                characters: [],
                profiles: [],
                credentialValues: [:],
                settings: unselectedProviderSettings,
                initialConversationMessages: [],
                conversations: [],
                conversationGraphs: [],
                health: DevelopmentProviderCatalog.healthy
            )

        case .providerMissing:
            return IOSDevelopmentFixtureSet(
                characters: DevelopmentCharacterCatalog.characters,
                profiles: [],
                credentialValues: [:],
                settings: unselectedProviderSettings,
                initialConversationMessages:
                    DevelopmentMessageCatalog.initialConversationMessages,
                conversations: conversations,
                conversationGraphs: conversationGraphs,
                health: DevelopmentProviderCatalog.healthy
            )

        case .credentialMissing:
            return IOSDevelopmentFixtureSet(
                characters: DevelopmentCharacterCatalog.characters,
                profiles: DevelopmentProviderCatalog.profiles,
                credentialValues: [:],
                settings: selectedProviderSettings,
                initialConversationMessages:
                    DevelopmentMessageCatalog.initialConversationMessages,
                conversations: conversations,
                conversationGraphs: conversationGraphs,
                health: DevelopmentProviderCatalog.healthy
            )

        case .providerUnselected:
            return IOSDevelopmentFixtureSet(
                characters: DevelopmentCharacterCatalog.characters,
                profiles: DevelopmentProviderCatalog.profiles,
                credentialValues:
                    DevelopmentProviderCatalog.credentialValues,
                settings: unselectedProviderSettings,
                initialConversationMessages:
                    DevelopmentMessageCatalog.initialConversationMessages,
                conversations: conversations,
                conversationGraphs: conversationGraphs,
                health: DevelopmentProviderCatalog.healthy
            )

        case .healthWarning:
            return IOSDevelopmentFixtureSet(
                characters: DevelopmentCharacterCatalog.characters,
                profiles: DevelopmentProviderCatalog.profiles,
                credentialValues:
                    DevelopmentProviderCatalog.credentialValues,
                settings: selectedProviderSettings,
                initialConversationMessages:
                    DevelopmentMessageCatalog.initialConversationMessages,
                conversations: conversations,
                conversationGraphs: conversationGraphs,
                health: DevelopmentProviderCatalog.warning
            )

        case .coreUnavailable:
            preconditionFailure(
                "The unavailable-core scenario has no in-memory fixture set."
            )

        case .load:
            let loadConversations =
                DevelopmentConversationCatalog.loadFixtures(
                    anchor: anchor
                )
            return IOSDevelopmentFixtureSet(
                characters: DevelopmentCharacterCatalog.characters,
                profiles: DevelopmentProviderCatalog.profiles,
                credentialValues:
                    DevelopmentProviderCatalog.credentialValues,
                settings: selectedProviderSettings,
                initialConversationMessages:
                    DevelopmentMessageCatalog.initialConversationMessages,
                conversations: conversations + loadConversations,
                conversationGraphs: conversationGraphs,
                health: DevelopmentProviderCatalog.healthy
            )
        }
    }
}
#endif
