import Foundation
import XCTest
@testable import LorepiaKit

@MainActor
final class FeatureViewModelTests: XCTestCase {
    func testLibraryFilteringMatchesSummary() {
        let viewModel = LibraryViewModel(
            characters: LibraryCharacter.previewCharacters
        )

        viewModel.query = "합성 자료"

        XCTAssertEqual(
            viewModel.filteredCharacters.map(\.id),
            ["preview-cartographer"]
        )
    }

    func testSelectingCharacterEnablesPreviewChat() {
        let viewModel = ChatViewModel(previewEnabled: true)
        let character = LibraryCharacter.previewCharacters[0]

        viewModel.setCharacter(character)
        viewModel.draft = "안녕"
        XCTAssertTrue(viewModel.canSubmit)

        viewModel.submitPreviewMessage()

        XCTAssertEqual(viewModel.messages.count, 3)
        XCTAssertEqual(viewModel.messages[1].role, .user)
        XCTAssertEqual(viewModel.messages[2].role, .assistant)
        XCTAssertTrue(viewModel.draft.isEmpty)
    }

    func testLiveFrameDoesNotGenerateNativeChatResponses() {
        let viewModel = ChatViewModel(previewEnabled: false)
        viewModel.setCharacter(LibraryCharacter.previewCharacters[0])
        viewModel.draft = "전송하지 않기"

        viewModel.submitPreviewMessage()

        XCTAssertFalse(viewModel.canSubmit)
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testImportReviewNeverAcceptsWithoutPreviewMode() {
        let viewModel = ImportReviewViewModel(previewEnabled: false)
        let candidate = ImportCandidate(
            sourceURL: URL(fileURLWithPath: "/synthetic/minimal.charx")
        )

        viewModel.select(candidate)
        viewModel.acceptForPreview()

        XCTAssertEqual(viewModel.state, .selected(candidate))
    }

    func testEnvironmentCoordinatesSelectedCharacter() {
        let environment = AppEnvironment(
            coreClient: FakeCoreClient(),
            runtimeMode: .preview,
            characters: LibraryCharacter.previewCharacters
        )
        let character = LibraryCharacter.previewCharacters[1]

        environment.selectCharacter(character)

        XCTAssertEqual(environment.sharedState.selectedCharacter, character)
        XCTAssertEqual(environment.chatViewModel.character, character)
    }
}
