import Foundation
import XCTest
@testable import LorepiaKit

@MainActor
final class ConversationListViewModelTests: XCTestCase {
    func testItemsSortByRecentActivityAndUseLastVisibleMessage() {
        let character = LibraryCharacter(
            id: "character",
            name: "하린",
            summary: "합성 테스트 캐릭터"
        )
        let older = conversation(
            id: "older",
            title: "첫 번째 방",
            updatedAt: "2026-07-26T01:00:00Z"
        )
        let newer = conversation(
            id: "newer",
            title: "두 번째 방",
            updatedAt: "2026-07-26T02:00:00Z"
        )
        let assistant = ChatMessage(
            id: "assistant",
            conversationID: older.id,
            role: .assistant,
            text: "마지막으로 보이는 답장"
        )
        let system = ChatMessage(
            id: "system",
            conversationID: older.id,
            role: .system,
            text: "내부 시스템 메시지"
        )

        let items = ConversationListViewModel.makeItems(
            conversations: [older, newer],
            characters: [character],
            lastMessages: [
                older.id: ConversationListViewModel.lastPreviewMessage(
                    in: [assistant, system]
                )!,
            ]
        )

        XCTAssertEqual(items.map(\.id), ["newer", "older"])
        XCTAssertEqual(items[1].lastMessage, assistant)
        XCTAssertEqual(items[1].character, character)
    }

    func testSearchMatchesConversationCharacterPreviewAndMode() {
        let character = LibraryCharacter(
            id: "character",
            name: "별빛 지도사",
            summary: "합성 테스트 캐릭터"
        )
        let item = ConversationListItem(
            conversation: conversation(
                id: "room",
                title: "달빛 도서관",
                updatedAt: "2026-07-26T02:00:00Z"
            ),
            character: character,
            lastMessage: ChatMessage(
                conversationID: "room",
                role: .assistant,
                text: "잠긴 서가가 열렸어."
            ),
            mode: .story
        )
        let viewModel = ConversationListViewModel(
            client: FakeCoreClient(),
            initialItems: [item],
            initialCharacters: [character]
        )

        for query in ["도서관", "지도사", "서가", "스토리"] {
            viewModel.query = query
            XCTAssertEqual(viewModel.filteredItems.map(\.id), ["room"])
        }

        viewModel.query = "없는 검색어"
        XCTAssertTrue(viewModel.filteredItems.isEmpty)
    }

    func testRefreshLoadsCharactersAndEmptyConversationState() async {
        let viewModel = ConversationListViewModel(client: FakeCoreClient())

        await viewModel.refresh()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(
            viewModel.characters.map(\.id),
            LibraryCharacter.previewCharacters.map(\.id)
        )
        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testCreateConversationPersistsSelectedMode() async throws {
        let client = FakeCoreClient()
        let viewModel = ConversationListViewModel(client: client)
        await viewModel.refresh()
        let character = try XCTUnwrap(viewModel.characters.first)

        let created = await viewModel.createConversation(
            character: character,
            mode: .story
        )

        XCTAssertEqual(created?.mode, .story)
        XCTAssertEqual(viewModel.items.first?.id, created?.id)
        XCTAssertEqual(viewModel.items.first?.character, character)
        XCTAssertNil(viewModel.creationErrorMessage)
        let persisted = try await client.listConversations()
        XCTAssertEqual(persisted.map(\.id), [created?.id].compactMap { $0 })
        let conversationID = try XCTUnwrap(created?.id)
        let state = try await client.getConversationState(
            conversationID: conversationID
        )
        XCTAssertEqual(state.selectedMode, .story)
    }

    func testRefreshReadsPersistedModeInsteadOfCachedCreationMode() async throws {
        let client = FakeCoreClient()
        let characters = try await client.listCharacters()
        let character = try XCTUnwrap(characters.first)
        let conversation = try await client.createConversation(
            characterID: character.id,
            title: "합성 스토리 방",
            mode: .chat
        )
        _ = try await client.setConversationMode(
            conversationID: conversation.id,
            mode: .story
        )
        let viewModel = ConversationListViewModel(client: client)

        await viewModel.refresh()

        XCTAssertEqual(
            viewModel.items.first(where: { $0.id == conversation.id })?.mode,
            .story
        )

        _ = try await client.setConversationMode(
            conversationID: conversation.id,
            mode: .chat
        )
        await viewModel.refresh()

        XCTAssertEqual(
            viewModel.items.first(where: { $0.id == conversation.id })?.mode,
            .chat
        )
    }

    func testRefreshAndCreationExposeRecoverableErrors() async {
        let client = UnavailableCoreClient(message: "synthetic failure")
        let viewModel = ConversationListViewModel(client: client)

        await viewModel.refresh()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertNotNil(viewModel.errorMessage)

        let created = await viewModel.createConversation(
            character: LibraryCharacter.previewCharacters[0],
            mode: .chat
        )
        XCTAssertNil(created)
        XCTAssertNotNil(viewModel.creationErrorMessage)
        XCTAssertFalse(viewModel.isCreatingConversation)
    }

    func testTimestampAcceptsCoreRFC3339VariantsAndLabelsYesterday() throws {
        XCTAssertNotNil(
            ConversationListTimestamp.date(
                from: "2026-07-26T02:00:00.123456Z"
            )
        )
        let calendar = try XCTUnwrap(
            Calendar(
                identifier: .gregorian
            ).settingTimeZone(identifier: "Asia/Seoul")
        )
        let now = try XCTUnwrap(
            ConversationListTimestamp.date(from: "2026-07-26T03:00:00Z")
        )
        let yesterday = try XCTUnwrap(
            ConversationListTimestamp.date(from: "2026-07-25T03:00:00Z")
        )

        XCTAssertEqual(
            ConversationListTimestamp.shortLabel(
                for: yesterday,
                now: now,
                calendar: calendar,
                locale: Locale(identifier: "ko_KR")
            ),
            "어제"
        )
    }

    private func conversation(
        id: String,
        title: String,
        updatedAt: String
    ) -> CoreConversation {
        CoreConversation(
            id: id,
            characterID: "character",
            title: title,
            createdAt: "2026-07-26T00:00:00Z",
            updatedAt: updatedAt
        )
    }
}

private extension Calendar {
    func settingTimeZone(identifier: String) -> Calendar? {
        guard let timeZone = TimeZone(identifier: identifier) else {
            return nil
        }
        var copy = self
        copy.timeZone = timeZone
        return copy
    }
}
