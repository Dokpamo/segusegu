import XCTest
@testable import LorepiaKit

@MainActor
final class FakeCoreClientFixtureTests: XCTestCase {
    func testLegacyConversationFixtureStillBuildsStableLinearMessages()
        async throws
    {
        let conversation = CoreConversation(
            id: "legacy-room",
            characterID: "preview-librarian",
            title: "레거시 합성 대화",
            createdAt: "2026-07-01T00:00:00Z",
            updatedAt: "2026-07-02T00:00:00Z"
        )
        let client = FakeCoreClient(
            initialConversationFixtures: [
                FakeConversationFixture(
                    conversation: conversation,
                    mode: .story,
                    messages: [
                        ChatMessage(
                            id: "ignored-user-template-id",
                            role: .user,
                            text: "첫 메시지",
                            createdAt: "2026-07-01T01:00:00Z"
                        ),
                        ChatMessage(
                            id: "ignored-assistant-template-id",
                            role: .assistant,
                            text: "합성 답장",
                            status: .cancelled,
                            generationID: "template-generation",
                            createdAt: "2026-07-01T01:01:00Z"
                        ),
                    ]
                ),
            ]
        )

        let messages = try await client.listMessages(
            conversationID: conversation.id
        )
        let branches = try await client.listConversationBranches(
            conversationID: conversation.id
        )
        let state = try await client.getConversationState(
            conversationID: conversation.id
        )

        XCTAssertEqual(
            messages.map(\.id),
            [
                "legacy-room-fixture-1",
                "legacy-room-fixture-2",
            ]
        )
        XCTAssertNil(messages[0].parentID)
        XCTAssertEqual(messages[1].parentID, messages[0].id)
        XCTAssertEqual(
            messages[1].generationID,
            "legacy-room-fixture-generation-2"
        )
        XCTAssertEqual(messages[1].status, .cancelled)
        XCTAssertEqual(messages[0].createdAt, "2026-07-01T01:00:00Z")
        XCTAssertEqual(branches.map(\.id), ["legacy-room-fixture-main"])
        XCTAssertEqual(branches.first?.headMessageID, messages.last?.id)
        XCTAssertEqual(state.selectedMode, .story)
        XCTAssertEqual(state.activeBranchID, branches.first?.id)
    }

    func testRichConversationGraphRestoresBranchesStateAndMessagesExactly()
        async throws
    {
        let conversation = CoreConversation(
            id: "graph-room",
            characterID: "preview-librarian",
            title: "분기 합성 대화",
            createdAt: "2026-07-10T00:00:00Z",
            updatedAt: "2026-07-10T00:05:00Z"
        )
        let system = ChatMessage(
            id: "graph-system",
            conversationID: conversation.id,
            parentID: nil,
            role: .system,
            text: "합성 시스템 메시지",
            status: .notice,
            createdAt: "2026-07-10T00:00:10Z"
        )
        let initialUser = ChatMessage(
            id: "graph-initial-user",
            conversationID: conversation.id,
            parentID: system.id,
            role: .user,
            text: "어느 길로 갈까?",
            createdAt: "2026-07-10T00:01:00Z"
        )
        let sharedAssistant = ChatMessage(
            id: "graph-shared-assistant",
            conversationID: conversation.id,
            parentID: initialUser.id,
            role: .assistant,
            text: "두 길 모두 입구까지 살펴봤어.",
            generationID: "graph-generation-shared",
            createdAt: "2026-07-10T00:01:20Z"
        )
        let user = ChatMessage(
            id: "graph-user",
            conversationID: conversation.id,
            parentID: sharedAssistant.id,
            role: .user,
            text: "그럼 하나를 골라 줘.",
            createdAt: "2026-07-10T00:01:40Z"
        )
        let mainAssistant = ChatMessage(
            id: "graph-main-assistant",
            conversationID: conversation.id,
            parentID: user.id,
            role: .assistant,
            text: "왼쪽 길로 가자.",
            status: .complete,
            generationID: "graph-generation-main",
            createdAt: "2026-07-10T00:02:00Z"
        )
        let alternateAssistant = ChatMessage(
            id: "graph-alternate-assistant",
            conversationID: conversation.id,
            parentID: user.id,
            role: .assistant,
            text: "오른쪽 길을 살펴보자.",
            status: .failed,
            generationID: "graph-generation-alternate",
            createdAt: "2026-07-10T00:03:00Z"
        )
        let mainBranch = CoreConversationBranch(
            id: "graph-main",
            conversationID: conversation.id,
            title: "왼쪽 길",
            forkMessageID: nil,
            headMessageID: mainAssistant.id,
            createdAt: "2026-07-10T00:00:00Z",
            updatedAt: "2026-07-10T00:02:00Z"
        )
        let alternateBranch = CoreConversationBranch(
            id: "graph-alternate",
            conversationID: conversation.id,
            title: "오른쪽 길",
            forkMessageID: user.id,
            headMessageID: alternateAssistant.id,
            createdAt: "2026-07-10T00:02:30Z",
            updatedAt: "2026-07-10T00:03:00Z"
        )
        let state = CoreConversationState(
            conversationID: conversation.id,
            activeBranchID: alternateBranch.id,
            selectedMode: .story,
            updatedAt: "2026-07-10T00:04:00Z"
        )
        let mainMessages = [
            system,
            initialUser,
            sharedAssistant,
            user,
            mainAssistant,
        ]
        let alternateMessages = [
            system,
            initialUser,
            sharedAssistant,
            user,
            alternateAssistant,
        ]

        let client = try FakeCoreClient(
            initialSettings: CoreAppSettings(
                preservePartialGenerations: false,
                selectedProviderProfileID: "preview-provider"
            ),
            initialConversationGraphs: [
                FakeConversationGraphFixture(
                    conversation: conversation,
                    state: state,
                    branches: [
                        FakeConversationBranchFixture(
                            branch: mainBranch,
                            messages: mainMessages
                        ),
                        FakeConversationBranchFixture(
                            branch: alternateBranch,
                            messages: alternateMessages
                        ),
                    ]
                ),
            ]
        )

        let conversations = try await client.listConversations()
        let branches = try await client.listConversationBranches(
            conversationID: conversation.id
        )
        let restoredState = try await client.getConversationState(
            conversationID: conversation.id
        )
        let activeMessages = try await client.listMessages(
            conversationID: conversation.id
        )
        let restoredMainMessages = try await client.listBranchMessages(
            branchID: mainBranch.id
        )
        let restoredAlternateMessages = try await client.listBranchMessages(
            branchID: alternateBranch.id
        )

        XCTAssertEqual(conversations, [conversation])
        XCTAssertEqual(branches, [mainBranch, alternateBranch])
        XCTAssertEqual(restoredState, state)
        XCTAssertEqual(activeMessages, alternateMessages)
        XCTAssertEqual(restoredMainMessages, mainMessages)
        XCTAssertEqual(restoredAlternateMessages, alternateMessages)
    }

    func testRichFixtureInitialSettingsSelectMiddleOrNoProfile() async throws {
        let profiles = [
            ProviderProfile(
                id: "profile-first",
                displayName: "첫 프로필",
                baseURL: "https://first.invalid/v1",
                model: "first-model",
                timeoutSeconds: 10
            ),
            ProviderProfile(
                id: "profile-middle",
                displayName: "중간 프로필",
                baseURL: "https://middle.invalid/v1",
                model: "middle-model",
                timeoutSeconds: 20
            ),
            ProviderProfile(
                id: "profile-last",
                displayName: "마지막 프로필",
                baseURL: "https://last.invalid/v1",
                model: "last-model",
                timeoutSeconds: 30
            ),
        ]
        let middleSettings = CoreAppSettings(
            preservePartialGenerations: false,
            selectedProviderProfileID: profiles[1].id
        )
        let noneSettings = CoreAppSettings(
            preservePartialGenerations: true,
            selectedProviderProfileID: nil
        )

        let middleClient = try FakeCoreClient(
            profiles: profiles,
            initialSettings: middleSettings
        )
        let noneClient = try FakeCoreClient(
            profiles: profiles,
            initialSettings: noneSettings
        )

        let restoredProfiles = try await middleClient.listProviderProfiles()
        let restoredMiddleSettings = try await middleClient.getSettings()
        let restoredNoneSettings = try await noneClient.getSettings()

        XCTAssertEqual(restoredProfiles, profiles)
        XCTAssertEqual(restoredMiddleSettings, middleSettings)
        XCTAssertEqual(restoredNoneSettings, noneSettings)
    }

    func testRichFixtureRejectsMissingActiveBranchBeforeCreatingClient() {
        let conversation = CoreConversation(
            id: "invalid-room",
            characterID: "preview-librarian",
            title: "잘못된 합성 대화",
            createdAt: "2026-07-20T00:00:00Z",
            updatedAt: "2026-07-20T00:00:00Z"
        )
        let branch = CoreConversationBranch(
            id: "existing-branch",
            conversationID: conversation.id,
            title: nil,
            forkMessageID: nil,
            headMessageID: nil,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt
        )
        let graph = FakeConversationGraphFixture(
            conversation: conversation,
            state: CoreConversationState(
                conversationID: conversation.id,
                activeBranchID: "missing-branch",
                selectedMode: .chat,
                updatedAt: conversation.updatedAt
            ),
            branches: [
                FakeConversationBranchFixture(
                    branch: branch,
                    messages: []
                ),
            ]
        )

        XCTAssertThrowsError(
            try FakeCoreClient(
                initialSettings: CoreAppSettings(
                    preservePartialGenerations: true,
                    selectedProviderProfileID: "preview-provider"
                ),
                initialConversationGraphs: [graph]
            )
        ) { error in
            XCTAssertEqual(
                error as? FakeCoreClientFixtureError,
                .invalid(
                    "대화 invalid-room의 활성 분기가 없습니다: "
                        + "missing-branch"
                )
            )
        }
    }

    func testRichFixtureRejectsSiblingMessagesInsteadOfALinearChain() {
        let conversationID = "sibling-room"
        let root = ChatMessage(
            id: "sibling-root",
            conversationID: conversationID,
            parentID: nil,
            role: .user,
            text: "뿌리"
        )
        let firstChild = ChatMessage(
            id: "sibling-first-child",
            conversationID: conversationID,
            parentID: root.id,
            role: .assistant,
            text: "첫 번째 자식"
        )
        let sibling = ChatMessage(
            id: "sibling-second-child",
            conversationID: conversationID,
            parentID: root.id,
            role: .assistant,
            text: "두 번째 자식"
        )
        let graph = makeGraph(
            conversationID: conversationID,
            branchID: "sibling-branch",
            messages: [root, firstChild, sibling]
        )

        XCTAssertThrowsError(
            try FakeCoreClient(
                initialSettings: previewSettings,
                initialConversationGraphs: [graph]
            )
        ) { error in
            XCTAssertEqual(
                error as? FakeCoreClientFixtureError,
                .invalid(
                    "분기 sibling-branch의 메시지 sibling-second-child 부모가 "
                        + "선형 체인과 다릅니다."
                )
            )
        }
    }

    func testRichFixtureRejectsMessageIDCollidingWithLegacyStorage() {
        let legacyConversation = CoreConversation(
            id: "legacy-message-collision",
            characterID: "preview-librarian",
            title: "레거시 대화",
            createdAt: "2026-07-21T00:00:00Z",
            updatedAt: "2026-07-21T00:00:00Z"
        )
        let collidingMessage = ChatMessage(
            id: "legacy-message-collision-fixture-1",
            conversationID: "rich-message-collision",
            parentID: nil,
            role: .assistant,
            text: "다른 대화의 메시지"
        )
        let graph = makeGraph(
            conversationID: "rich-message-collision",
            branchID: "rich-message-collision-branch",
            messages: [collidingMessage]
        )

        XCTAssertThrowsError(
            try FakeCoreClient(
                initialSettings: previewSettings,
                initialConversationFixtures: [
                    FakeConversationFixture(
                        conversation: legacyConversation,
                        mode: .chat,
                        messages: [
                            ChatMessage(role: .user, text: "레거시 메시지"),
                        ]
                    ),
                ],
                initialConversationGraphs: [graph]
            )
        ) { error in
            XCTAssertEqual(
                error as? FakeCoreClientFixtureError,
                .invalid(
                    "메시지 ID가 전역 중복됩니다: "
                        + "legacy-message-collision-fixture-1"
                )
            )
        }
    }

    func testRichFixtureRejectsGenerationIDCollidingWithLegacyStorage() {
        let legacyConversation = CoreConversation(
            id: "legacy-generation-collision",
            characterID: "preview-librarian",
            title: "레거시 생성 대화",
            createdAt: "2026-07-22T00:00:00Z",
            updatedAt: "2026-07-22T00:00:00Z"
        )
        let collidingGenerationID =
            "legacy-generation-collision-fixture-generation-1"
        let richMessage = ChatMessage(
            id: "rich-generation-message",
            conversationID: "rich-generation-collision",
            parentID: nil,
            role: .assistant,
            text: "다른 대화의 생성 결과",
            generationID: collidingGenerationID
        )
        let graph = makeGraph(
            conversationID: "rich-generation-collision",
            branchID: "rich-generation-collision-branch",
            messages: [richMessage]
        )

        XCTAssertThrowsError(
            try FakeCoreClient(
                initialSettings: previewSettings,
                initialConversationFixtures: [
                    FakeConversationFixture(
                        conversation: legacyConversation,
                        mode: .chat,
                        messages: [
                            ChatMessage(
                                role: .assistant,
                                text: "레거시 생성 결과",
                                generationID: "template-generation"
                            ),
                        ]
                    ),
                ],
                initialConversationGraphs: [graph]
            )
        ) { error in
            XCTAssertEqual(
                error as? FakeCoreClientFixtureError,
                .invalid(
                    "생성 ID가 전역 중복됩니다: \(collidingGenerationID)"
                )
            )
        }
    }

    private var previewSettings: CoreAppSettings {
        CoreAppSettings(
            preservePartialGenerations: true,
            selectedProviderProfileID: "preview-provider"
        )
    }

    private func makeGraph(
        conversationID: String,
        branchID: String,
        messages: [ChatMessage]
    ) -> FakeConversationGraphFixture {
        let timestamp = "2026-07-23T00:00:00Z"
        let conversation = CoreConversation(
            id: conversationID,
            characterID: "preview-librarian",
            title: "검증용 합성 대화",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let branch = CoreConversationBranch(
            id: branchID,
            conversationID: conversationID,
            title: nil,
            forkMessageID: nil,
            headMessageID: messages.last?.id,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        return FakeConversationGraphFixture(
            conversation: conversation,
            state: CoreConversationState(
                conversationID: conversationID,
                activeBranchID: branchID,
                selectedMode: .chat,
                updatedAt: timestamp
            ),
            branches: [
                FakeConversationBranchFixture(
                    branch: branch,
                    messages: messages
                ),
            ]
        )
    }
}
