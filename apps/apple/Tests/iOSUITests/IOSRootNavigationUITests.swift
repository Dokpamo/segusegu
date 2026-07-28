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
    func testChatComposerSoftWrapMovesAsOne() {
        let app = XCUIApplication()
        app.launchArguments = ["--lorepia-native-navigation-ui-test"]
        app.launch()

        let character = app.staticTexts["미리보기 안내자"].firstMatch
        XCTAssertTrue(character.waitForExistence(timeout: 10))
        character.tap()

        let windowBounds = app.windows.firstMatch.frame
        let composer = app.descendants(matching: .any)[
            "chat-composer-field"
        ]
        let composerSurface = app.descendants(matching: .any)[
            "chat-composer-surface"
        ]
        let tools = app.buttons["chat-composer-tools"]
        let model = app.buttons["chat-composer-model"]
        let mode = app.buttons["chat-composer-mode"]
        var send = app.buttons["메시지 보내기"]

        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(composerSurface.waitForExistence(timeout: 5))
        composer.tap()
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertTrue(send.waitForExistence(timeout: 5))

        // A real bottom-aligned bubble is a more stable transcript marker than
        // the centered empty-state label when the composer changes the viewport.
        composer.typeText("시드")
        send.tap()
        let transcript = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label == %@",
                "캐릭터: 이 응답은 테스트용 합성 메시지입니다."
            )
        ).firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        send = app.buttons["메시지 보내기"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))

        composer.tap()
        guard let openComposerState = composerSurface.value as? String else {
            XCTFail("The open composer must expose an accessibility state.")
            return
        }
        // Make the field prove it owns first responder before taking geometry.
        // After the seeded response arrives, the software keyboard can still
        // be completing its native return animation even though the composer
        // already exposes its stable open state. Sampling before the first
        // accepted key makes the keyboard's ~335 pt travel look like a composer
        // resize.
        composer.typeText("가")

        // Let the message insertion and keyboard geometry settle before
        // establishing the one-line reference frame.
        let unexpectedPreWrapStateChange = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value != %@",
                openComposerState
            ),
            object: composerSurface
        )
        unexpectedPreWrapStateChange.isInverted = true
        wait(for: [unexpectedPreWrapStateChange], timeout: 0.7)

        let keyboard = app.keyboards.firstMatch
        let softwareKeyboardWasVisible =
            keyboard.exists && keyboard.frame.minY < windowBounds.maxY
        let oneLineSurface = composerSurface.frame
        let oneLineField = composer.frame
        let oneLineTranscript = transcript.frame
        let anchoredRailBottom = send.frame.maxY
        let oneLineKeyboardTop =
            softwareKeyboardWasVisible ? keyboard.frame.minY : nil

        XCTAssertEqual(tools.frame.maxY, anchoredRailBottom, accuracy: 1)
        XCTAssertEqual(model.frame.maxY, anchoredRailBottom, accuracy: 1)
        XCTAssertEqual(mode.frame.maxY, anchoredRailBottom, accuracy: 1)

        // Identical glyphs make the first natural 1 -> 2 line wrap independent
        // of locale word-breaking. Geometry is unchanged until that first wrap.
        var didSoftWrap = false
        for _ in 0 ..< 64 {
            composer.typeText("가")
            if composer.frame.height > oneLineField.height + 8 {
                didSoftWrap = true
                break
            }
        }
        XCTAssertTrue(didSoftWrap)

        // Let accessibility publish the atomically resolved native wrap. This
        // also proves the editor did not lose first responder during relayout.
        let unexpectedPostWrapStateChange = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value != %@",
                openComposerState
            ),
            object: composerSurface
        )
        unexpectedPostWrapStateChange.isInverted = true
        wait(for: [unexpectedPostWrapStateChange], timeout: 0.4)

        let twoLineSurface = composerSurface.frame
        let twoLineField = composer.frame
        let twoLineTranscript = transcript.frame
        let upwardTravel =
            oneLineSurface.minY - twoLineSurface.minY

        XCTAssertGreaterThan(upwardTravel, 12)
        XCTAssertLessThan(upwardTravel, 32)
        XCTAssertEqual(
            twoLineSurface.height - oneLineSurface.height,
            upwardTravel,
            accuracy: 2
        )
        XCTAssertEqual(
            twoLineField.height - oneLineField.height,
            upwardTravel,
            accuracy: 2
        )
        XCTAssertEqual(
            oneLineField.minY - twoLineField.minY,
            upwardTravel,
            accuracy: 2
        )
        XCTAssertEqual(
            oneLineTranscript.minY - twoLineTranscript.minY,
            upwardTravel,
            accuracy: 3
        )
        XCTAssertEqual(
            oneLineTranscript.maxY - twoLineTranscript.maxY,
            upwardTravel,
            accuracy: 3
        )
        XCTAssertEqual(
            twoLineTranscript.height,
            oneLineTranscript.height,
            accuracy: 1
        )
        XCTAssertEqual(
            twoLineSurface.maxY,
            oneLineSurface.maxY,
            accuracy: 1
        )
        XCTAssertEqual(twoLineField.maxY, oneLineField.maxY, accuracy: 2)
        XCTAssertEqual(send.frame.maxY, anchoredRailBottom, accuracy: 1)
        XCTAssertEqual(tools.frame.maxY, anchoredRailBottom, accuracy: 1)
        XCTAssertEqual(model.frame.maxY, anchoredRailBottom, accuracy: 1)
        XCTAssertEqual(mode.frame.maxY, anchoredRailBottom, accuracy: 1)
        XCTAssertEqual(composerSurface.value as? String, openComposerState)
        XCTAssertTrue(composer.isHittable)

        if let oneLineKeyboardTop {
            XCTAssertTrue(keyboard.exists)
            XCTAssertLessThan(keyboard.frame.minY, windowBounds.maxY)
            XCTAssertEqual(
                keyboard.frame.minY,
                oneLineKeyboardTop,
                accuracy: 3
            )
        }

        // Removing the character that caused the first wrap must mirror the
        // same geometry in the opposite direction. The field, glass, and
        // transcript settle together while the bottom rail stays anchored.
        composer.typeText(XCUIKeyboardKey.delete.rawValue)
        let unexpectedCollapseStateChange = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value != %@",
                openComposerState
            ),
            object: composerSurface
        )
        unexpectedCollapseStateChange.isInverted = true
        wait(for: [unexpectedCollapseStateChange], timeout: 0.4)

        let collapsedSurface = composerSurface.frame
        let collapsedField = composer.frame
        let collapsedTranscript = transcript.frame
        let downwardTravel =
            collapsedSurface.minY - twoLineSurface.minY

        XCTAssertEqual(downwardTravel, upwardTravel, accuracy: 2)
        XCTAssertEqual(
            twoLineSurface.height - collapsedSurface.height,
            downwardTravel,
            accuracy: 2
        )
        XCTAssertEqual(
            twoLineField.height - collapsedField.height,
            downwardTravel,
            accuracy: 2
        )
        XCTAssertEqual(
            collapsedField.minY - twoLineField.minY,
            downwardTravel,
            accuracy: 2
        )
        XCTAssertEqual(
            collapsedTranscript.minY - twoLineTranscript.minY,
            downwardTravel,
            accuracy: 3
        )
        XCTAssertEqual(
            collapsedSurface.maxY,
            twoLineSurface.maxY,
            accuracy: 1
        )
        XCTAssertEqual(collapsedField.maxY, twoLineField.maxY, accuracy: 2)
        XCTAssertEqual(send.frame.maxY, anchoredRailBottom, accuracy: 1)
        XCTAssertEqual(tools.frame.maxY, anchoredRailBottom, accuracy: 1)
        XCTAssertEqual(model.frame.maxY, anchoredRailBottom, accuracy: 1)
        XCTAssertEqual(mode.frame.maxY, anchoredRailBottom, accuracy: 1)
        XCTAssertEqual(composerSurface.value as? String, openComposerState)
        XCTAssertTrue(composer.isHittable)

        // No extra tap: successful input proves the native field's
        // accessibility frame and first-responder state still match the pixels.
        composer.typeText("포커스유지")
        XCTAssertTrue(
            String(describing: composer.value).contains("포커스유지")
        )
    }

    @MainActor
    func testChatComposerStaysOpenWhenKeyboardDismisses() {
        let app = XCUIApplication()
        app.launchArguments = ["--lorepia-native-navigation-ui-test"]
        app.launch()

        let character = app.staticTexts["미리보기 안내자"].firstMatch
        XCTAssertTrue(character.waitForExistence(timeout: 10))
        character.tap()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let windowBounds = window.frame
        let composer = app.descendants(matching: .any)[
            "chat-composer-field"
        ]
        let composerSurface = app.descendants(matching: .any)[
            "chat-composer-surface"
        ]
        let tools = app.buttons["chat-composer-tools"]
        let model = app.buttons["chat-composer-model"]
        let mode = app.buttons["chat-composer-mode"]
        let send = app.buttons["메시지 보내기"]
        let keyboard = app.keyboards.firstMatch

        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(composerSurface.waitForExistence(timeout: 5))
        XCTAssertTrue(tools.waitForExistence(timeout: 5))
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertTrue(send.waitForExistence(timeout: 5))

        guard let openComposerState = composerSurface.value as? String else {
            XCTFail("The open composer must expose an accessibility state.")
            return
        }
        let initialSurface = composerSurface.frame
        let initialField = composer.frame
        let initialRail = tools.frame
            .union(model.frame)
            .union(mode.frame)
            .union(send.frame)

        XCTAssertFalse(
            keyboard.exists && keyboard.frame.minY < windowBounds.maxY
        )

        for cycle in 0 ..< 2 {
            composer.tap()
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            XCTAssertLessThan(keyboard.frame.minY, windowBounds.maxY)
            if cycle == 0 {
                composer.typeText("항상 열린 입력바")
            }

            let unexpectedFocusedStateChange = XCTNSPredicateExpectation(
                predicate: NSPredicate(
                    format: "value != %@",
                    openComposerState
                ),
                object: composerSurface
            )
            unexpectedFocusedStateChange.isInverted = true
            wait(for: [unexpectedFocusedStateChange], timeout: 0.4)

            let focusedSurface = composerSurface.frame
            let focusedField = composer.frame
            let focusedRail = tools.frame
                .union(model.frame)
                .union(mode.frame)
                .union(send.frame)

            XCTAssertEqual(
                composerSurface.value as? String,
                openComposerState
            )
            XCTAssertTrue(model.exists)
            XCTAssertTrue(mode.exists)
            XCTAssertTrue(
                String(describing: composer.value)
                    .contains("항상 열린 입력바")
            )
            XCTAssertEqual(
                focusedSurface.width,
                initialSurface.width,
                accuracy: 1
            )
            XCTAssertEqual(
                focusedSurface.height,
                initialSurface.height,
                accuracy: 1
            )
            XCTAssertEqual(focusedField.width, initialField.width, accuracy: 1)
            XCTAssertEqual(
                focusedField.height,
                initialField.height,
                accuracy: 1
            )
            XCTAssertEqual(focusedRail.width, initialRail.width, accuracy: 1)
            XCTAssertEqual(focusedRail.height, initialRail.height, accuracy: 1)

            window.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)
            ).tap()
            let keyboardNoLongerExists =
                keyboard.waitForNonExistence(timeout: 5)
            XCTAssertTrue(
                keyboardNoLongerExists
                    || keyboard.frame.minY >= windowBounds.maxY
            )

            let unexpectedDismissedStateChange = XCTNSPredicateExpectation(
                predicate: NSPredicate(
                    format: "value != %@",
                    openComposerState
                ),
                object: composerSurface
            )
            unexpectedDismissedStateChange.isInverted = true
            wait(for: [unexpectedDismissedStateChange], timeout: 0.4)

            let dismissedSurface = composerSurface.frame
            let dismissedField = composer.frame
            let dismissedRail = tools.frame
                .union(model.frame)
                .union(mode.frame)
                .union(send.frame)

            XCTAssertEqual(
                composerSurface.value as? String,
                openComposerState
            )
            XCTAssertTrue(model.exists)
            XCTAssertTrue(mode.exists)
            XCTAssertTrue(
                String(describing: composer.value)
                    .contains("항상 열린 입력바")
            )
            XCTAssertEqual(
                dismissedSurface.width,
                focusedSurface.width,
                accuracy: 1
            )
            XCTAssertEqual(
                dismissedSurface.height,
                focusedSurface.height,
                accuracy: 1
            )
            XCTAssertEqual(
                dismissedField.width,
                focusedField.width,
                accuracy: 1
            )
            XCTAssertEqual(
                dismissedField.height,
                focusedField.height,
                accuracy: 1
            )
            XCTAssertEqual(
                dismissedRail.width,
                focusedRail.width,
                accuracy: 1
            )
            XCTAssertEqual(
                dismissedRail.height,
                focusedRail.height,
                accuracy: 1
            )
        }
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
        let backButton = app.navigationBars.buttons["홈"]
        let windowBounds = app.windows.firstMatch.frame
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        if #available(iOS 26.0, *) {
            // Messages uses its centered contact identity as the room-settings
            // entry point: a 60 pt avatar overlapping a 32 pt glass capsule.
            XCTAssertGreaterThanOrEqual(settings.frame.width, 60)
            XCTAssertEqual(settings.frame.height, 87, accuracy: 2)
            XCTAssertEqual(settings.frame.midX, windowBounds.midX, accuracy: 1)
            // Anchor the custom contact stack to the native back control,
            // rather than to a device-specific status-bar coordinate.
            XCTAssertEqual(
                settings.frame.minY,
                backButton.frame.minY,
                accuracy: 3
            )
        }
        XCTAssertFalse(
            app.buttons["chat-room-settings-trigger-mode"].exists
        )
        settings.tap()
        XCTAssertTrue(
            app.navigationBars["대화 설정"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["채팅"].exists)
        XCTAssertTrue(app.buttons["스토리"].exists)
        let doneButton = app.navigationBars["대화 설정"]
            .descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "label == %@",
                    "완료"
                )
            )
            .element(boundBy: 1)
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))
        let doneFrame = doneButton.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(
                CGVector(
                    dx: doneFrame.midX,
                    dy: doneFrame.midY
                )
            )
            .tap()
        XCTAssertTrue(
            app.navigationBars["대화 설정"].waitForNonExistence(timeout: 5)
        )
        // Sheet dismissal may restore the field's previous first-responder
        // state. A transcript tap establishes the keyboard-dismissed baseline;
        // the composer itself must remain fully open.
        app.windows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)
        ).tap()

        let composer = app.descendants(matching: .any)[
            "chat-composer-field"
        ]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let composerSurface = app.descendants(matching: .any)[
            "chat-composer-surface"
        ]
        XCTAssertTrue(composerSurface.waitForExistence(timeout: 5))
        let tools = app.buttons["chat-composer-tools"]
        XCTAssertTrue(tools.waitForExistence(timeout: 5))
        let send = app.buttons["메시지 보내기"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        let model = app.buttons["chat-composer-model"]
        let mode = app.buttons["chat-composer-mode"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        guard let openComposerState = composerSurface.value as? String else {
            XCTFail("The open composer must expose an accessibility state.")
            return
        }
        XCTAssertEqual(model.value as? String, "preview-model")
        XCTAssertEqual(mode.value as? String, "채팅 모드")

        let restingComposerBounds = tools.frame
            .union(composer.frame)
            .union(send.frame)
            .union(model.frame)
            .union(mode.frame)
        XCTAssertEqual(tools.frame.width, 44, accuracy: 1)
        XCTAssertEqual(tools.frame.height, 44, accuracy: 1)
        XCTAssertEqual(send.frame.width, 44, accuracy: 1)
        XCTAssertEqual(send.frame.height, 44, accuracy: 1)
        XCTAssertEqual(model.frame.height, 44, accuracy: 1)
        XCTAssertEqual(mode.frame.height, 44, accuracy: 1)
        XCTAssertGreaterThan(restingComposerBounds.height, 44)

        // XCUITest sees the 44 pt child hit targets, not the rendered glass.
        // Reconstruct the rim from the measured visual clearance around
        // the 32 pt control inside each 44 pt target.
        let childToGlassRim: CGFloat = 2
        let restingRailBounds = tools.frame
            .union(model.frame)
            .union(mode.frame)
            .union(send.frame)
        let restingVisualBounds = CGRect(
            x: restingRailBounds.minX - childToGlassRim,
            y: composer.frame.minY - 16,
            width: restingRailBounds.width + childToGlassRim * 2,
            height: restingRailBounds.maxY
                + childToGlassRim
                - (composer.frame.minY - 16)
        )
        XCTAssertGreaterThanOrEqual(restingVisualBounds.height, 92)

        let restingSurfaceBounds = composerSurface.frame
        let restingFieldBounds = composer.frame
        let restingSurfaceLeadingInset =
            restingSurfaceBounds.minX - windowBounds.minX
        let restingSurfaceTrailingInset =
            windowBounds.maxX - restingSurfaceBounds.maxX
        let restingSurfaceBottomInset =
            windowBounds.maxY - restingSurfaceBounds.maxY
        // iOS 26 reports the Liquid Glass effect's inset accessibility
        // bounds. Earlier fallback rendering reports the 12 pt layout rim.
        let expectedSurfaceHorizontalInset: CGFloat =
            ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
                ? 14
                : 12
        XCTAssertEqual(
            restingSurfaceLeadingInset,
            expectedSurfaceHorizontalInset,
            accuracy: 1
        )
        XCTAssertEqual(
            restingSurfaceTrailingInset,
            expectedSurfaceHorizontalInset,
            accuracy: 1
        )
        XCTAssertEqual(restingSurfaceBottomInset, 36, accuracy: 2)

        let restingLeadingInset =
            restingVisualBounds.minX - windowBounds.minX
        let restingTrailingInset =
            windowBounds.maxX - restingVisualBounds.maxX
        let restingBottomInset =
            windowBounds.maxY - restingVisualBounds.maxY
        XCTAssertEqual(restingLeadingInset, restingTrailingInset, accuracy: 1)
        XCTAssertEqual(restingLeadingInset, 12, accuracy: 1)
        XCTAssertEqual(restingTrailingInset, 12, accuracy: 1)
        XCTAssertEqual(restingBottomInset, 34, accuracy: 2)
        XCTAssertEqual(
            tools.frame.midX - restingVisualBounds.minX,
            24,
            accuracy: 1
        )
        XCTAssertEqual(
            restingVisualBounds.maxX - send.frame.midX,
            24,
            accuracy: 1
        )
        XCTAssertEqual(
            restingVisualBounds.maxY - send.frame.midY,
            24,
            accuracy: 1
        )
        XCTAssertEqual(tools.frame.midY, send.frame.midY, accuracy: 1)
        XCTAssertEqual(tools.frame.midY, model.frame.midY, accuracy: 1)
        XCTAssertEqual(tools.frame.midY, mode.frame.midY, accuracy: 1)
        XCTAssertEqual(
            composer.frame.minX - restingVisualBounds.minX,
            18,
            accuracy: 1
        )
        XCTAssertEqual(
            restingVisualBounds.maxX - composer.frame.maxX,
            18,
            accuracy: 1
        )
        let restingComposerBottom = tools.frame.maxY

        composer.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertEqual(composerSurface.value as? String, openComposerState)
        XCTAssertEqual(model.value as? String, "preview-model")
        XCTAssertEqual(mode.value as? String, "채팅 모드")
        let focusedSurfaceBounds = composerSurface.frame
        let focusedFieldBounds = composer.frame
        let focusedComposerBounds = tools.frame
            .union(composer.frame)
            .union(send.frame)
            .union(model.frame)
            .union(mode.frame)
        let focusedRailBounds = tools.frame
            .union(model.frame)
            .union(mode.frame)
            .union(send.frame)
        let focusedVisualBounds = CGRect(
            x: focusedRailBounds.minX - childToGlassRim,
            y: composer.frame.minY - 16,
            width: focusedRailBounds.width + childToGlassRim * 2,
            height: focusedRailBounds.maxY
                + childToGlassRim
                - (composer.frame.minY - 16)
        )
        XCTAssertEqual(
            focusedVisualBounds.height,
            restingVisualBounds.height,
            accuracy: 3
        )
        XCTAssertEqual(
            focusedVisualBounds.width,
            restingVisualBounds.width,
            accuracy: 2
        )
        XCTAssertEqual(
            focusedSurfaceBounds.width,
            restingSurfaceBounds.width,
            accuracy: 2
        )
        XCTAssertEqual(
            focusedSurfaceBounds.height,
            restingSurfaceBounds.height,
            accuracy: 2
        )
        XCTAssertEqual(
            focusedFieldBounds.width,
            restingFieldBounds.width,
            accuracy: 2
        )
        XCTAssertEqual(
            focusedFieldBounds.height,
            restingFieldBounds.height,
            accuracy: 2
        )
        XCTAssertEqual(
            focusedRailBounds.width,
            restingRailBounds.width,
            accuracy: 2
        )
        XCTAssertEqual(
            focusedRailBounds.height,
            restingRailBounds.height,
            accuracy: 1
        )
        XCTAssertEqual(
            focusedVisualBounds.minX - windowBounds.minX,
            12,
            accuracy: 1
        )
        XCTAssertEqual(
            windowBounds.maxX - focusedVisualBounds.maxX,
            12,
            accuracy: 1
        )
        XCTAssertEqual(
            focusedSurfaceBounds.minX - windowBounds.minX,
            14,
            accuracy: 1
        )
        XCTAssertEqual(
            windowBounds.maxX - focusedSurfaceBounds.maxX,
            14,
            accuracy: 1
        )
        XCTAssertEqual(tools.frame.height, 44, accuracy: 1)
        XCTAssertEqual(send.frame.height, 44, accuracy: 1)
        XCTAssertEqual(model.frame.height, 44, accuracy: 1)
        XCTAssertEqual(mode.frame.height, 44, accuracy: 1)
        XCTAssertEqual(tools.frame.midY, send.frame.midY, accuracy: 1)
        XCTAssertEqual(tools.frame.midY, model.frame.midY, accuracy: 1)
        XCTAssertEqual(tools.frame.midY, mode.frame.midY, accuracy: 1)
        XCTAssertEqual(
            tools.frame.midX - focusedVisualBounds.minX,
            24,
            accuracy: 1
        )
        XCTAssertEqual(
            focusedVisualBounds.maxX - send.frame.midX,
            24,
            accuracy: 1
        )
        XCTAssertEqual(
            focusedVisualBounds.maxY - send.frame.midY,
            24,
            accuracy: 1
        )
        XCTAssertEqual(
            composer.frame.minX - focusedVisualBounds.minX,
            18,
            accuracy: 1
        )
        XCTAssertEqual(
            focusedVisualBounds.maxX - composer.frame.maxX,
            18,
            accuracy: 1
        )

        // Native menus own their presentation. iOS may temporarily lower the
        // software keyboard while a menu is open, so verify the semantic
        // choice and that the focused composer and draft survive dismissal.
        let draftBeforeNativeMenus = String(describing: composer.value)

        mode.tap()
        let currentModeOption = app.buttons[
            "chat-composer-mode-option-chat"
        ]
        let storyModeOption = app.buttons[
            "chat-composer-mode-option-story"
        ]
        XCTAssertTrue(currentModeOption.waitForExistence(timeout: 2))
        XCTAssertTrue(storyModeOption.waitForExistence(timeout: 2))
        storyModeOption.tap()
        XCTAssertTrue(storyModeOption.waitForNonExistence(timeout: 5))
        XCTAssertEqual(composerSurface.value as? String, openComposerState)
        XCTAssertEqual(
            String(describing: composer.value),
            draftBeforeNativeMenus
        )

        mode.tap()
        XCTAssertTrue(currentModeOption.waitForExistence(timeout: 2))
        currentModeOption.tap()
        XCTAssertTrue(currentModeOption.waitForNonExistence(timeout: 5))
        XCTAssertEqual(
            String(describing: composer.value),
            draftBeforeNativeMenus
        )

        model.tap()
        let currentModelOption = app.buttons[
            "chat-composer-model-option-preview-provider"
        ]
        XCTAssertTrue(currentModelOption.waitForExistence(timeout: 2))
        app.windows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)
        ).tap()
        XCTAssertTrue(currentModelOption.waitForNonExistence(timeout: 2))
        XCTAssertEqual(
            String(describing: composer.value),
            draftBeforeNativeMenus
        )

        tools.tap()
        let settingsTool = app.buttons["chat-composer-tools-settings"]
        XCTAssertTrue(settingsTool.waitForExistence(timeout: 2))
        app.windows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)
        ).tap()
        XCTAssertTrue(settingsTool.waitForNonExistence(timeout: 2))
        XCTAssertEqual(
            String(describing: composer.value),
            draftBeforeNativeMenus
        )

        if keyboard.exists, keyboard.frame.minY < windowBounds.maxY {
            // The keyboard accessibility frame starts at its first key row,
            // below the visible keyboard surface. Verify the composer moved
            // above it and remains interactive instead of comparing those
            // non-equivalent visual bounds.
            XCTAssertLessThan(
                focusedVisualBounds.maxY,
                keyboard.frame.minY
            )
            XCTAssertLessThan(
                tools.frame.maxY,
                restingComposerBottom - 100
            )
            XCTAssertTrue(tools.isHittable)
        } else {
            // A connected hardware keyboard leaves the software keyboard's
            // accessibility frame offscreen. Focusing alone must not pull the
            // composer toward the screen edge; it keeps the same resting
            // clearance until a software keyboard is actually visible.
            let focusedBottomInset =
                windowBounds.maxY - focusedVisualBounds.maxY
            XCTAssertEqual(
                focusedBottomInset,
                restingBottomInset,
                accuracy: 2
            )
            XCTAssertEqual(
                tools.frame.maxY,
                restingComposerBottom,
                accuracy: 1
            )
            XCTAssertTrue(composer.isHittable)
        }
        // Native menus can release first responder even while the composer
        // correctly remains in its editing layout. Reacquire the field before
        // asking XCUITest to synthesize keyboard input.
        composer.tap()
        composer.typeText("키보드를 닫아도 남는 초안")
        let oneLineFocusedSurfaceBounds = composerSurface.frame
        let oneLineFocusedFieldBounds = composer.frame
        let oneLineFocusedRailBounds = tools.frame
            .union(model.frame)
            .union(mode.frame)
            .union(send.frame)
        let oneLineSoftwareKeyboardWasVisible =
            keyboard.exists && keyboard.frame.minY < windowBounds.maxY
        app.windows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)
        ).tap()
        let unexpectedDismissStateChange = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value != %@",
                openComposerState
            ),
            object: composerSurface
        )
        unexpectedDismissStateChange.isInverted = true
        wait(for: [unexpectedDismissStateChange], timeout: 0.4)
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertEqual(composerSurface.value as? String, openComposerState)
        XCTAssertEqual(model.value as? String, "preview-model")
        XCTAssertEqual(mode.value as? String, "채팅 모드")
        XCTAssertTrue(
            String(describing: composer.value)
                .contains("키보드를 닫아도 남는 초안")
        )
        let oneLineRestingSurfaceBounds = composerSurface.frame
        let oneLineRestingFieldBounds = composer.frame
        let oneLineRestingRailBounds = tools.frame
            .union(model.frame)
            .union(mode.frame)
            .union(send.frame)
        // A transcript tap closes only the software keyboard. The open
        // surface, field, and accessory rail keep their exact layout.
        XCTAssertFalse(
            keyboard.exists && keyboard.frame.minY < windowBounds.maxY
        )
        XCTAssertEqual(
            oneLineRestingSurfaceBounds.width,
            oneLineFocusedSurfaceBounds.width,
            accuracy: 2
        )
        XCTAssertEqual(
            oneLineRestingSurfaceBounds.height,
            oneLineFocusedSurfaceBounds.height,
            accuracy: 3
        )
        XCTAssertEqual(
            oneLineRestingFieldBounds.width,
            oneLineFocusedFieldBounds.width,
            accuracy: 2
        )
        XCTAssertEqual(
            oneLineRestingFieldBounds.height,
            oneLineFocusedFieldBounds.height,
            accuracy: 2
        )
        XCTAssertEqual(
            oneLineRestingRailBounds.width,
            oneLineFocusedRailBounds.width,
            accuracy: 2
        )
        XCTAssertEqual(
            oneLineRestingRailBounds.height,
            oneLineFocusedRailBounds.height,
            accuracy: 1
        )
        if oneLineSoftwareKeyboardWasVisible {
            XCTAssertGreaterThan(
                oneLineRestingSurfaceBounds.maxY,
                oneLineFocusedSurfaceBounds.maxY + 20
            )
        }
        XCTAssertEqual(
            windowBounds.maxY - oneLineRestingSurfaceBounds.maxY,
            restingSurfaceBottomInset,
            accuracy: 1
        )

        // Repeated focus and transcript taps must only toggle the keyboard.
        // The composer state and all three layout regions remain unchanged.
        for _ in 0 ..< 3 {
            composer.tap()
            let unexpectedFocusStateChange = XCTNSPredicateExpectation(
                predicate: NSPredicate(
                    format: "value != %@",
                    openComposerState
                ),
                object: composerSurface
            )
            unexpectedFocusStateChange.isInverted = true
            wait(for: [unexpectedFocusStateChange], timeout: 0.25)
            XCTAssertEqual(composerSurface.value as? String, openComposerState)
            XCTAssertTrue(model.exists)
            XCTAssertTrue(mode.exists)
            let cycleFocusedSurfaceBounds = composerSurface.frame
            let cycleFocusedFieldBounds = composer.frame
            let cycleFocusedRailBounds = tools.frame
                .union(model.frame)
                .union(mode.frame)
                .union(send.frame)
            XCTAssertEqual(
                cycleFocusedSurfaceBounds.size.width,
                oneLineFocusedSurfaceBounds.size.width,
                accuracy: 2
            )
            XCTAssertEqual(
                cycleFocusedSurfaceBounds.size.height,
                oneLineFocusedSurfaceBounds.size.height,
                accuracy: 3
            )
            XCTAssertEqual(
                cycleFocusedFieldBounds.size.width,
                oneLineFocusedFieldBounds.size.width,
                accuracy: 2
            )
            XCTAssertEqual(
                cycleFocusedFieldBounds.size.height,
                oneLineFocusedFieldBounds.size.height,
                accuracy: 2
            )
            XCTAssertEqual(
                cycleFocusedRailBounds.size.width,
                oneLineFocusedRailBounds.size.width,
                accuracy: 2
            )
            XCTAssertEqual(
                cycleFocusedRailBounds.size.height,
                oneLineFocusedRailBounds.size.height,
                accuracy: 1
            )

            app.windows.firstMatch.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)
            ).tap()
            let unexpectedRestingStateChange = XCTNSPredicateExpectation(
                predicate: NSPredicate(
                    format: "value != %@",
                    openComposerState
                ),
                object: composerSurface
            )
            unexpectedRestingStateChange.isInverted = true
            wait(for: [unexpectedRestingStateChange], timeout: 0.4)
            XCTAssertEqual(composerSurface.value as? String, openComposerState)
            let cycleRestingSurfaceBounds = composerSurface.frame
            let cycleRestingFieldBounds = composer.frame
            let cycleRestingRailBounds = tools.frame
                .union(model.frame)
                .union(mode.frame)
                .union(send.frame)
            XCTAssertEqual(
                cycleRestingSurfaceBounds.size.width,
                oneLineRestingSurfaceBounds.size.width,
                accuracy: 2
            )
            XCTAssertEqual(
                cycleRestingSurfaceBounds.size.height,
                oneLineRestingSurfaceBounds.size.height,
                accuracy: 3
            )
            XCTAssertEqual(
                cycleRestingFieldBounds.size.width,
                oneLineRestingFieldBounds.size.width,
                accuracy: 2
            )
            XCTAssertEqual(
                cycleRestingFieldBounds.size.height,
                oneLineRestingFieldBounds.size.height,
                accuracy: 2
            )
            XCTAssertEqual(
                cycleRestingRailBounds.size.width,
                oneLineRestingRailBounds.size.width,
                accuracy: 2
            )
            XCTAssertEqual(
                cycleRestingRailBounds.size.height,
                oneLineRestingRailBounds.size.height,
                accuracy: 1
            )
            XCTAssertEqual(
                windowBounds.maxY - cycleRestingSurfaceBounds.maxY,
                restingSurfaceBottomInset,
                accuracy: 2
            )
            XCTAssertTrue(model.exists)
            XCTAssertTrue(mode.exists)
        }

        composer.tap()
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        // `tap()` can return before an older simulator finishes presenting
        // its software keyboard. Accept one key before sampling the anchored
        // rail so line growth is never compared across two keyboard states.
        composer.typeText("가")
        XCTAssertEqual(composerSurface.value as? String, openComposerState)
        let unexpectedStateChange = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value != %@",
                openComposerState
            ),
            object: composerSurface
        )
        unexpectedStateChange.isInverted = true
        wait(for: [unexpectedStateChange], timeout: 1.2)
        let anchoredLineGrowthBottom = send.frame.maxY
        composer.typeText(
            String(repeating: "입력바 확장 확인 ", count: 8)
        )
        let grownComposerBounds = tools.frame
            .union(composer.frame)
            .union(send.frame)
            .union(model.frame)
            .union(mode.frame)
        XCTAssertGreaterThan(
            grownComposerBounds.height,
            focusedComposerBounds.height + 20
        )
        XCTAssertEqual(tools.frame.maxY, send.frame.maxY, accuracy: 1)
        XCTAssertEqual(tools.frame.maxY, model.frame.maxY, accuracy: 1)
        XCTAssertEqual(tools.frame.maxY, mode.frame.maxY, accuracy: 1)
        XCTAssertEqual(
            send.frame.maxY,
            anchoredLineGrowthBottom,
            accuracy: 1
        )

        // A multiline TextField keeps one native 1...10 configuration.
        // Dismissing the keyboard keeps the accessory rail and rendered draft
        // height instead of clipping the editor to one line.
        let multilineDraftValue = String(describing: composer.value)
        let multilineFieldBounds = composer.frame
        let multilineSurfaceBounds = composerSurface.frame
        let multilineRailBounds = tools.frame
            .union(model.frame)
            .union(mode.frame)
            .union(send.frame)
        let multilineSoftwareKeyboardWasVisible =
            keyboard.exists && keyboard.frame.minY < windowBounds.maxY
        XCTAssertGreaterThan(
            multilineFieldBounds.height,
            focusedFieldBounds.height + 20
        )

        app.windows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)
        ).tap()
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertEqual(
            composerSurface.value as? String,
            openComposerState
        )
        XCTAssertEqual(model.value as? String, "preview-model")
        XCTAssertEqual(mode.value as? String, "채팅 모드")
        XCTAssertEqual(
            String(describing: composer.value),
            multilineDraftValue
        )
        let restingMultilineSurfaceBounds = composerSurface.frame
        let restingMultilineFieldBounds = composer.frame
        let restingMultilineRailBounds = tools.frame
            .union(model.frame)
            .union(mode.frame)
            .union(send.frame)
        XCTAssertEqual(
            restingMultilineFieldBounds.width,
            multilineFieldBounds.width,
            accuracy: 2
        )
        XCTAssertEqual(
            restingMultilineFieldBounds.height,
            multilineFieldBounds.height,
            accuracy: 3
        )
        XCTAssertEqual(
            restingMultilineSurfaceBounds.width,
            multilineSurfaceBounds.width,
            accuracy: 2
        )
        XCTAssertEqual(
            restingMultilineSurfaceBounds.height,
            multilineSurfaceBounds.height,
            accuracy: 3
        )
        XCTAssertEqual(
            restingMultilineRailBounds.width,
            multilineRailBounds.width,
            accuracy: 2
        )
        XCTAssertEqual(
            restingMultilineRailBounds.height,
            multilineRailBounds.height,
            accuracy: 1
        )
        if multilineSoftwareKeyboardWasVisible {
            XCTAssertGreaterThan(
                restingMultilineSurfaceBounds.maxY,
                multilineSurfaceBounds.maxY + 20
            )
        }
        XCTAssertEqual(
            windowBounds.maxY - restingMultilineSurfaceBounds.maxY,
            restingSurfaceBottomInset,
            accuracy: 3
        )
        XCTAssertEqual(tools.frame.maxY, send.frame.maxY, accuracy: 1)
        XCTAssertGreaterThan(tools.frame.minY, composer.frame.maxY)
        XCTAssertTrue(composer.isHittable)
        XCTAssertTrue(tools.isHittable)
        XCTAssertTrue(send.isHittable)

        composer.tap()
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertEqual(composerSurface.value as? String, openComposerState)
        XCTAssertEqual(
            String(describing: composer.value),
            multilineDraftValue
        )

        let refocusedFieldBounds = composer.frame
        let refocusedSurfaceBounds = composerSurface.frame
        let refocusedRailBounds = tools.frame
            .union(model.frame)
            .union(mode.frame)
            .union(send.frame)
        XCTAssertEqual(
            refocusedFieldBounds.width,
            multilineFieldBounds.width,
            accuracy: 2
        )
        XCTAssertEqual(
            refocusedFieldBounds.height,
            multilineFieldBounds.height,
            accuracy: 3
        )
        XCTAssertEqual(
            refocusedSurfaceBounds.width,
            multilineSurfaceBounds.width,
            accuracy: 2
        )
        XCTAssertEqual(
            refocusedSurfaceBounds.height,
            multilineSurfaceBounds.height,
            accuracy: 3
        )
        XCTAssertEqual(
            refocusedRailBounds.width,
            multilineRailBounds.width,
            accuracy: 2
        )
        XCTAssertEqual(
            refocusedRailBounds.height,
            multilineRailBounds.height,
            accuracy: 1
        )
        XCTAssertTrue(composer.isHittable)
        composer.typeText(" 재포커스 입력")
        XCTAssertTrue(
            String(describing: composer.value).contains("재포커스 입력")
        )

        composer.typeText(
            String(repeating: "최대 높이 이후 내부 스크롤 ", count: 24)
        )
        let maximumComposerBounds = tools.frame
            .union(composer.frame)
            .union(send.frame)
            .union(model.frame)
            .union(mode.frame)
        XCTAssertGreaterThan(
            maximumComposerBounds.height,
            grownComposerBounds.height + 20
        )
        // Ten regular body lines should grow substantially beyond the
        // two-line focused state; the former six-line cap cannot satisfy this.
        XCTAssertGreaterThan(
            maximumComposerBounds.height,
            focusedComposerBounds.height + 100
        )
        XCTAssertLessThan(
            maximumComposerBounds.height,
            windowBounds.height * 0.4
        )
        XCTAssertEqual(
            send.frame.maxY,
            anchoredLineGrowthBottom,
            accuracy: 1
        )

        composer.typeText(
            String(repeating: " capped", count: 40)
        )
        let cappedComposerBounds = tools.frame
            .union(composer.frame)
            .union(send.frame)
            .union(model.frame)
            .union(mode.frame)
        XCTAssertEqual(
            cappedComposerBounds.height,
            maximumComposerBounds.height,
            accuracy: 3
        )
        XCTAssertEqual(
            send.frame.maxY,
            anchoredLineGrowthBottom,
            accuracy: 1
        )
        XCTAssertTrue(
            String(describing: composer.value).contains("capped")
        )
        XCTAssertTrue(tools.isHittable)
        XCTAssertTrue(model.isHittable)
        XCTAssertTrue(mode.isHittable)
        XCTAssertTrue(send.isHittable)
        send.tap()

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
