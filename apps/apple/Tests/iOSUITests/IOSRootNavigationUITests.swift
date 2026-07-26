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

        let library = app.tabBars.buttons["서재"]
        let chat = app.tabBars.buttons["채팅"]
        let settings = app.tabBars.buttons["설정"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        XCTAssertTrue(library.isSelected)

        chat.tap()
        XCTAssertTrue(chat.isSelected)
        XCTAssertTrue(
            app.staticTexts["대화를 선택하세요"].waitForExistence(timeout: 5)
        )

        settings.tap()
        XCTAssertTrue(settings.isSelected)
        XCTAssertTrue(
            app.staticTexts["프로필 편집"].waitForExistence(timeout: 5)
        )

        library.tap()
        XCTAssertTrue(library.isSelected)
    }
}
