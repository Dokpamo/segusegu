import XCTest

final class IOSDevelopmentFixturesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testComprehensiveFixturesSupportSearchAndOpenFromWholeRow() {
        let app = XCUIApplication()
        app.launchArguments = ["--lorepia-dev-fixtures"]
        app.launch()

        let chats = app.tabBars.buttons["채팅"]
        XCTAssertTrue(
            chats.waitForExistence(timeout: 10),
            "The comprehensive fixture app did not expose the Chats tab."
        )
        chats.tap()

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(
            searchField.waitForExistence(timeout: 5),
            "The conversation search field did not appear."
        )
        searchField.tap()
        searchField.typeText("LANTERN")

        let room = app.descendants(matching: .any)[
            "conversation-row-fixture-room-mir-lantern"
        ]
        XCTAssertTrue(
            room.waitForExistence(timeout: 5),
            "The LANTERN fixture room was not returned by search."
        )
        XCTAssertTrue(room.isHittable)
        XCTAssertTrue(
            room.label.contains("LANTERN / 항구 신호"),
            "The filtered fixture row did not expose its expected title."
        )

        // Exercise the row's trailing empty area rather than its text. This
        // guards the full-row hit target while remaining independent of exact
        // pixel geometry and text length.
        room.coordinate(
            withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)
        ).tap()

        XCTAssertTrue(
            app.navigationBars["항구 라디오지기 미르"]
                .waitForExistence(timeout: 5),
            "Tapping the trailing part of the row did not open the room."
        )

        let userMessage = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@",
                "LANTERN 신호가 세 번 들어왔어."
            )
        ).firstMatch
        let assistantMessage = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@",
                "세 번이면 귀항 신호야. 북쪽 부표부터 확인해."
            )
        ).firstMatch
        XCTAssertTrue(
            userMessage.waitForExistence(timeout: 5),
            "The known LANTERN user message was not restored."
        )
        XCTAssertTrue(
            assistantMessage.waitForExistence(timeout: 5),
            "The known LANTERN assistant message was not restored."
        )

        let composer = app.descendants(matching: .any)[
            "chat-composer-field"
        ]
        XCTAssertTrue(
            composer.waitForExistence(timeout: 5),
            "The opened fixture room did not expose the composer."
        )
        XCTAssertTrue(composer.isHittable)

        let model = app.buttons["chat-composer-model"]
        XCTAssertTrue(
            model.waitForExistence(timeout: 5),
            "The fixture room did not expose its selected model."
        )
        XCTAssertTrue(
            String(describing: model.value).contains("개발용 응답기"),
            "The synthetic provider was not selected: \(model.value ?? "nil")."
        )
    }

    @MainActor
    func testEveryDevelopmentScenarioLaunchesWithoutFixtureFailure() {
        let scenarioArguments = [
            "--lorepia-dev-empty",
            "--lorepia-dev-provider-missing",
            "--lorepia-dev-credential-missing",
            "--lorepia-dev-provider-unselected",
            "--lorepia-dev-health-warning",
            "--lorepia-dev-core-unavailable",
            "--lorepia-dev-load",
        ]

        for scenarioArgument in scenarioArguments {
            let app = XCUIApplication()
            app.launchArguments = [scenarioArgument]
            app.launch()

            let home = app.tabBars.buttons["홈"]
            XCTAssertTrue(
                home.waitForExistence(timeout: 10),
                "\(scenarioArgument) did not reach the native root UI."
            )
            app.terminate()
        }
    }
}
