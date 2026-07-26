import XCTest
@testable import LorepiaKit

@MainActor
final class ChatBranchControlsTests: XCTestCase {
    func testComposerModesExposeStableDomainFacingValuesAndLabels() {
        XCTAssertEqual(ChatComposerMode.allCases, [.chat, .story])
        XCTAssertEqual(ChatComposerMode.chat.rawValue, "chat")
        XCTAssertEqual(ChatComposerMode.story.rawValue, "story")
        XCTAssertEqual(ChatComposerMode.chat.title, "채팅")
        XCTAssertEqual(ChatComposerMode.story.title, "스토리")
        XCTAssertFalse(ChatComposerMode.chat.accessibilityHint.isEmpty)
        XCTAssertFalse(ChatComposerMode.story.accessibilityHint.isEmpty)
    }

    func testBranchPresentationSeparatesCurrentBranchWithoutReorderingOthers() {
        let branches = syntheticBranches

        XCTAssertEqual(
            ChatBranchPresentation.currentBranch(
                in: branches,
                selectedBranchID: "middle"
            )?.id,
            "middle"
        )
        XCTAssertEqual(
            ChatBranchPresentation.alternativeBranches(
                in: branches,
                selectedBranchID: "middle"
            ).map(\.id),
            ["root", "latest"]
        )
        XCTAssertEqual(
            ChatBranchPresentation.toolbarAccessibilityValue(
                branches: branches,
                selectedBranchID: "middle"
            ),
            "현재 두 번째 흐름, 분기 3개"
        )
    }

    func testMissingSelectionLeavesEveryBranchAvailable() {
        let branches = syntheticBranches

        XCTAssertNil(
            ChatBranchPresentation.currentBranch(
                in: branches,
                selectedBranchID: "missing"
            )
        )
        XCTAssertEqual(
            ChatBranchPresentation.alternativeBranches(
                in: branches,
                selectedBranchID: "missing"
            ),
            branches
        )
        XCTAssertEqual(
            ChatBranchPresentation.toolbarAccessibilityValue(
                branches: branches,
                selectedBranchID: nil
            ),
            "분기 3개"
        )
    }

    private var syntheticBranches: [ChatBranchOption] {
        [
            ChatBranchOption(
                id: "root",
                title: "기본 흐름",
                subtitle: "처음 시작한 이야기"
            ),
            ChatBranchOption(
                id: "middle",
                title: "두 번째 흐름",
                subtitle: "다른 대답을 고른 이야기"
            ),
            ChatBranchOption(
                id: "latest",
                title: "세 번째 흐름"
            ),
        ]
    }
}
