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
        let library = app.tabBars.buttons["서재"]
        let create = app.tabBars.buttons["생성"]
        let settings = app.tabBars.buttons["설정"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        XCTAssertTrue(home.isSelected)
        XCTAssertTrue(
            app.staticTexts["첫 이야기를 시작해 보세요"].waitForExistence(timeout: 5)
        )

        library.tap()
        XCTAssertTrue(library.isSelected)
        XCTAssertTrue(
            app.staticTexts["서재가 비어 있습니다"].waitForExistence(timeout: 5)
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
        technicalDetails.tap()
        XCTAssertFalse(coreStatus.exists)

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
        let libraryAction = app.buttons["서재 보기"].firstMatch
        XCTAssertTrue(createAction.waitForExistence(timeout: 10))
        XCTAssertTrue(libraryAction.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(libraryAction.frame.minY, createAction.frame.minY)

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
}
