import XCTest

final class IOSRootNavigationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRootTabsNavigateBetweenNativeScreens() {
        let app = XCUIApplication()
        app.launchArguments = ["--lorepia-ui-test"]
        app.launch()

        let home = app.tabBars.buttons["홈"]
        let chats = app.tabBars.buttons["채팅"]
        let create = app.tabBars.buttons["생성"]
        let settings = app.tabBars.buttons["설정"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        XCTAssertTrue(home.isSelected)
        XCTAssertTrue(
            app.staticTexts["첫 이야기를 시작해 보세요"].waitForExistence(timeout: 5)
        )

        chats.tap()
        XCTAssertTrue(chats.isSelected)
        XCTAssertTrue(
            app.staticTexts["아직 대화가 없습니다"].waitForExistence(timeout: 5)
        )

        create.tap()
        XCTAssertTrue(create.isSelected)
        XCTAssertTrue(
            app.staticTexts["캐릭터 생성"].waitForExistence(timeout: 5)
        )

        settings.tap()
        XCTAssertTrue(settings.isSelected)
        XCTAssertTrue(
            app.staticTexts["프로필 편집"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.textFields["표시 이름"].isHittable)

        let coreStatus = app.buttons["코어 상태"]
        XCTAssertTrue(coreStatus.waitForExistence(timeout: 5))
        coreStatus.tap()
        XCTAssertTrue(
            app.navigationBars["코어 상태"].waitForExistence(timeout: 5)
        )
        app.buttons["완료"].tap()

        app.swipeUp()
        let technicalDetails = app.switches["기술 상태 패널 표시"]
        XCTAssertTrue(technicalDetails.waitForExistence(timeout: 5))
        technicalDetails.coordinate(
            withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
        ).tap()
        XCTAssertEqual(technicalDetails.value as? String, "0")
        XCTAssertTrue(coreStatus.waitForNonExistence(timeout: 5))

        app.swipeDown()
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        home.tap()
        XCTAssertTrue(home.isSelected)
    }

    @MainActor
    func testRootActionsReflowAtAccessibilityTextSize() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--lorepia-ui-test",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()

        let createAction = app.buttons["캐릭터 생성"].firstMatch
        let chatsAction = app.buttons["채팅 보기"].firstMatch
        XCTAssertTrue(createAction.waitForExistence(timeout: 10))
        XCTAssertTrue(chatsAction.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(chatsAction.frame.minY, createAction.frame.minY)

        createAction.tap()
        XCTAssertTrue(app.tabBars.buttons["생성"].isSelected)
        XCTAssertTrue(
            app.descendants(matching: .any)["create-manual-mode"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.descendants(matching: .any)["create-ai-mode"].exists)
        app.swipeUp()
        XCTAssertTrue(
            app.buttons["파일에서 가져오기"].waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testChatSupportsNativeEdgeSwipeBack() {
        let app = XCUIApplication()
        app.launchArguments = ["--lorepia-native-navigation-ui-test"]
        app.launch()

        let character = app.staticTexts["미리보기 안내자"].firstMatch
        XCTAssertTrue(character.waitForExistence(timeout: 10))

        let window = app.windows.firstMatch
        let leadingEdge = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)
        )
        let destination = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)
        )

        character.tap()

        let backButton = app.navigationBars.buttons["홈"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["홈"].exists)

        let cancellationPoint = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)
        )
        leadingEdge.press(
            forDuration: 0.05,
            thenDragTo: cancellationPoint,
            withVelocity: 100,
            thenHoldForDuration: 0.1
        )
        XCTAssertTrue(backButton.exists)
        XCTAssertFalse(app.tabBars.buttons["홈"].exists)

        leadingEdge.press(forDuration: 0.05, thenDragTo: destination)

        XCTAssertTrue(app.tabBars.buttons["홈"].waitForExistence(timeout: 5))
        XCTAssertTrue(character.waitForExistence(timeout: 5))
    }

    @MainActor
    func testChatShowsRoomSettingsAndDirectMessageActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--lorepia-native-navigation-ui-test"]
        app.launch()

        let character = app.staticTexts["미리보기 안내자"].firstMatch
        XCTAssertTrue(character.waitForExistence(timeout: 10))
        character.tap()

        let settings = app.buttons[
            "chat-room-settings-trigger-toolbar"
        ]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(
            app.navigationBars["대화 설정"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["채팅"].exists)
        XCTAssertTrue(app.buttons["스토리"].exists)
        app.buttons["완료"].tap()

        let composer = app.textFields["메시지"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("직접 액션 확인")
        app.buttons["메시지 보내기"].tap()

        let edit = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "chat-message-action-edit-user-"
            )
        ).firstMatch
        let regenerate = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "chat-message-action-regenerate-assistant-"
            )
        ).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertTrue(edit.isHittable)
        XCTAssertTrue(regenerate.waitForExistence(timeout: 5))
        XCTAssertTrue(regenerate.isHittable)

        let copy = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "chat-message-action-copy-user-"
            )
        ).firstMatch
        XCTAssertTrue(copy.isHittable)
        copy.tap()
        XCTAssertTrue(app.buttons["복사됨"].waitForExistence(timeout: 2))

        edit.tap()
        XCTAssertTrue(
            app.navigationBars["메시지 편집"].waitForExistence(timeout: 5)
        )
        app.buttons["취소"].tap()
    }
}
