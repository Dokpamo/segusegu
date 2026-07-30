import XCTest
import Vision

final class IOSRootNavigationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func contentBounds(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CGRect? {
        let window = app.windows.firstMatch
        let tabBar = app.tabBars.firstMatch
        guard window.waitForExistence(timeout: 5),
              tabBar.waitForExistence(timeout: 5)
        else {
            XCTFail(
                "The app content bounds were not available.",
                file: file,
                line: line
            )
            return nil
        }

        let statusBar = app.statusBars.firstMatch
        let contentMinY = statusBar.exists
            ? statusBar.frame.maxY
            : window.frame.minY
        return CGRect(
            x: window.frame.minX,
            y: contentMinY,
            width: window.frame.width,
            height: max(0, tabBar.frame.minY - contentMinY)
        )
    }

    /// Settings lists what is connected; the profile form lives one page down.
    @MainActor
    private func openProviderProfileDetail(in app: XCUIApplication) {
        let row = app.buttons["settings-provider-profile-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(
            app.navigationBars["프로필 편집"].waitForExistence(timeout: 5)
        )
    }

    @MainActor
    private func visibleContentElements(
        matching elementType: XCUIElement.ElementType,
        in app: XCUIApplication,
        contentBounds suppliedContentBounds: CGRect? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [XCUIElement] {
        guard let contentBounds = suppliedContentBounds ?? contentBounds(
            in: app,
            file: file,
            line: line
        ) else {
            return []
        }

        return app.descendants(matching: elementType)
            .allElementsBoundByIndex
            .filter { element in
                let frame = element.frame
                return element.exists
                    && frame.width > 0
                    && frame.height > 0
                    && frame.intersects(contentBounds)
            }
    }

    @MainActor
    private func recognizedFrame(
        of expectedText: String,
        in screenshot: XCUIScreenshot,
        isolatesMatch: Bool = false,
        required: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CGRect? {
        guard let cgImage = screenshot.image.cgImage else {
            XCTFail(
                "The UI screenshot did not expose a CGImage.",
                file: file,
                line: line
            )
            return nil
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.usesLanguageCorrection = true

        do {
            try VNImageRequestHandler(
                cgImage: cgImage,
                orientation: .up
            ).perform([request])
        } catch {
            XCTFail(
                "Korean text recognition failed: \(error)",
                file: file,
                line: line
            )
            return nil
        }

        let normalizedExpected = expectedText.filter {
            !$0.isWhitespace
        }
        for observation in request.results ?? [] {
            for candidate in observation.topCandidates(3) {
                let normalizedCandidate = candidate.string.filter {
                    !$0.isWhitespace
                }
                guard normalizedCandidate.contains(normalizedExpected) else {
                    continue
                }

                let normalizedBounds: CGRect
                if isolatesMatch,
                   let candidateRange = candidate.string.range(
                       of: expectedText
                   ),
                   let isolatedObservation = try? candidate.boundingBox(
                       for: candidateRange
                   )
                {
                    normalizedBounds = isolatedObservation.boundingBox
                } else {
                    // Most checks intentionally keep the full detected line.
                    // A caller can isolate its substring when Vision merges a
                    // title with an adjacent timestamp.
                    normalizedBounds = observation.boundingBox
                }
                let imageSize = screenshot.image.size
                return CGRect(
                    x: normalizedBounds.minX * imageSize.width,
                    y: (1 - normalizedBounds.maxY) * imageSize.height,
                    width: normalizedBounds.width * imageSize.width,
                    height: normalizedBounds.height * imageSize.height
                )
            }
        }

        if required {
            XCTFail(
                "OCR did not find visible text: \(expectedText)",
                file: file,
                line: line
            )
        }
        return nil
    }

    @MainActor
    private func recognizedRightmostTextFrame(
        in screenshot: XCUIScreenshot,
        rowFrame: CGRect,
        after minimumLeading: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CGRect? {
        guard let cgImage = screenshot.image.cgImage else {
            XCTFail(
                "The UI screenshot did not expose a CGImage.",
                file: file,
                line: line
            )
            return nil
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.usesLanguageCorrection = true

        do {
            try VNImageRequestHandler(
                cgImage: cgImage,
                orientation: .up
            ).perform([request])
        } catch {
            XCTFail(
                "Timestamp recognition failed: \(error)",
                file: file,
                line: line
            )
            return nil
        }

        let imageSize = screenshot.image.size
        let candidates = (request.results ?? []).flatMap { observation in
            observation.topCandidates(3).compactMap {
                recognizedText -> CGRect? in
                guard let timestampRange = trailingTimestampRange(
                    in: recognizedText.string
                ) else {
                    return nil
                }

                let timestampObservation: VNRectangleObservation
                do {
                    guard let recognizedBounds = try recognizedText.boundingBox(
                        for: timestampRange
                    ) else {
                        return nil
                    }
                    timestampObservation = recognizedBounds
                } catch {
                    return nil
                }

                let normalizedBounds = timestampObservation.boundingBox
                let frame = CGRect(
                    x: normalizedBounds.minX * imageSize.width,
                    y: (1 - normalizedBounds.maxY) * imageSize.height,
                    width: normalizedBounds.width * imageSize.width,
                    height: normalizedBounds.height * imageSize.height
                )
                guard frame.minX >= minimumLeading,
                      frame.intersects(rowFrame)
                else {
                    return nil
                }
                return frame
            }
        }

        guard let rightmostFrame = candidates.max(by: {
            $0.maxX < $1.maxX
        }) else {
            XCTFail(
                "OCR did not find the row's trailing timestamp.",
                file: file,
                line: line
            )
            return nil
        }
        return rightmostFrame
    }

    private func trailingTimestampRange(
        in recognizedText: String
    ) -> Range<String.Index>? {
        let patterns = [
            #"(?:오전|오후)\s*\d{1,2}:\d{2}$"#,
            #"어제$"#,
            #"\d{4}년\s*\d{1,2}월\s*\d{1,2}일$"#,
        ]
        let fullRange = NSRange(
            recognizedText.startIndex ..< recognizedText.endIndex,
            in: recognizedText
        )

        for pattern in patterns {
            guard
                let expression = try? NSRegularExpression(pattern: pattern),
                let match = expression.firstMatch(
                    in: recognizedText,
                    range: fullRange
                ),
                let range = Range(match.range, in: recognizedText)
            else {
                continue
            }
            return range
        }
        return nil
    }

    @MainActor
    private func openPreviewChat(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let chats = app.tabBars.buttons["채팅"]
        guard chats.waitForExistence(timeout: 10) else {
            XCTFail("The Chats tab did not appear.", file: file, line: line)
            return false
        }
        chats.tap()

        let newConversation = app.buttons["새 대화 시작"]
        guard newConversation.waitForExistence(timeout: 5) else {
            XCTFail(
                "The empty-state new-conversation action did not appear.",
                file: file,
                line: line
            )
            return false
        }
        XCTAssertEqual(
            newConversation.label,
            "새 대화 시작",
            "The empty-state action must preserve the creation flow.",
            file: file,
            line: line
        )
        newConversation.tap()

        let sheet = app.descendants(matching: .any)[
            "new-conversation-sheet"
        ]
        guard sheet.waitForExistence(timeout: 5) else {
            XCTFail(
                "The new-conversation sheet did not appear.",
                file: file,
                line: line
            )
            return false
        }

        let firstPreviewCharacter = app.buttons[
            "미리보기 안내자"
        ].firstMatch
        guard firstPreviewCharacter.waitForExistence(timeout: 5) else {
            XCTFail(
                "The first preview character did not appear.",
                file: file,
                line: line
            )
            return false
        }
        firstPreviewCharacter.tap()

        let create = app.navigationBars["새 대화"].buttons["만들기"]
        guard create.waitForExistence(timeout: 5), create.isEnabled else {
            XCTFail(
                "The conversation create action was not enabled.",
                file: file,
                line: line
            )
            return false
        }
        create.tap()

        let composer = app.descendants(matching: .any)[
            "chat-composer-field"
        ]
        guard composer.waitForExistence(timeout: 5) else {
            XCTFail("ChatView did not appear.", file: file, line: line)
            return false
        }
        return true
    }

    @MainActor
    private func assertBlankCreateScreen(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            app.tabBars.buttons["생성"].isSelected,
            "The Create tab must remain selected.",
            file: file,
            line: line
        )
        let navigationBar = app.navigationBars["생성"]
        XCTAssertTrue(
            navigationBar.waitForExistence(timeout: 5),
            "The blank Create tab must retain its visible title.",
            file: file,
            line: line
        )
        let prohibitedTypes: [(XCUIElement.ElementType, String)] = [
            (.button, "buttons"),
            (.staticText, "text"),
            (.image, "images"),
            (.textField, "text fields"),
            (.secureTextField, "secure text fields"),
            (.textView, "text views"),
            (.switch, "switches"),
            (.slider, "sliders"),
            (.picker, "pickers"),
            (.link, "links"),
        ]
        guard let contentBounds = contentBounds(
            in: app,
            file: file,
            line: line
        ) else {
            return
        }
        let blankBodyBounds = CGRect(
            x: contentBounds.minX,
            y: max(contentBounds.minY, navigationBar.frame.maxY),
            width: contentBounds.width,
            height: max(
                0,
                contentBounds.maxY
                    - max(contentBounds.minY, navigationBar.frame.maxY)
            )
        )

        for (elementType, description) in prohibitedTypes {
            XCTAssertTrue(
                visibleContentElements(
                    matching: elementType,
                    in: app,
                    contentBounds: blankBodyBounds,
                    file: file,
                    line: line
                ).isEmpty,
                "The blank Create tab must not expose \(description).",
                file: file,
                line: line
            )
        }
    }

    @MainActor
    func testPrimaryTabsKeepHeadersAndChatHidesTopNewConversationAction() {
        let app = XCUIApplication()
        app.launchArguments = ["--lorepia-ui-test"]
        app.launch()

        let home = app.tabBars.buttons["홈"]
        let chats = app.tabBars.buttons["채팅"]
        let create = app.tabBars.buttons["생성"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        XCTAssertTrue(home.isSelected)
        XCTAssertTrue(
            app.navigationBars["홈"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.buttons["home-add-button"].waitForExistence(timeout: 5)
        )

        chats.tap()
        XCTAssertTrue(chats.isSelected)
        XCTAssertTrue(
            app.navigationBars["채팅"].waitForExistence(timeout: 5)
        )
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(format: "label == %@", "새 대화")
            ).count,
            0,
            "The Chats navigation bar must not expose a top new-chat action."
        )
        XCTAssertFalse(app.buttons["new-conversation-button"].exists)
        XCTAssertTrue(
            app.buttons["새 대화 시작"].waitForExistence(timeout: 5),
            "Removing the top action must not remove the empty-state flow."
        )

        create.tap()
        assertBlankCreateScreen(in: app)

        home.tap()
        XCTAssertTrue(home.isSelected)
        XCTAssertTrue(
            app.navigationBars["홈"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["home-add-button"].exists)
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
            app.navigationBars["홈"].waitForExistence(timeout: 5)
        )

        let add = app.buttons["home-add-button"]
        let window = app.windows.firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let homeButtons = visibleContentElements(
            matching: .button,
            in: app
        )
        XCTAssertEqual(homeButtons.count, 1)
        XCTAssertEqual(homeButtons.first?.identifier, "home-add-button")
        XCTAssertEqual(add.label, "추가하기")
        XCTAssertGreaterThanOrEqual(add.frame.width, 180)
        XCTAssertGreaterThanOrEqual(add.frame.height, 44)
        XCTAssertEqual(add.frame.midX, window.frame.midX, accuracy: 2)
        XCTAssertLessThanOrEqual(add.frame.width, window.frame.width - 32)
        XCTAssertGreaterThan(add.frame.midY, window.frame.midY)
        XCTAssertLessThan(add.frame.maxY, app.tabBars.firstMatch.frame.minY)

        add.tap()
        XCTAssertTrue(create.isSelected)
        assertBlankCreateScreen(in: app)

        chats.tap()
        XCTAssertTrue(chats.isSelected)
        XCTAssertTrue(
            app.navigationBars["채팅"].waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.buttons["new-conversation-button"].exists)
        XCTAssertFalse(
            app.navigationBars["채팅"].buttons["새 대화"].exists
        )
        XCTAssertTrue(
            app.staticTexts["아직 대화가 없습니다"].waitForExistence(timeout: 5)
        )

        create.tap()
        XCTAssertTrue(create.isSelected)
        assertBlankCreateScreen(in: app)

        settings.tap()
        XCTAssertTrue(settings.isSelected)
        let guestIdentity = app.descendants(matching: .any)[
            "settings-guest-identity"
        ]
        XCTAssertTrue(guestIdentity.waitForExistence(timeout: 5))
        XCTAssertEqual(guestIdentity.label, "게스트")
        XCTAssertFalse(app.buttons["settings-add-account"].exists)
        XCTAssertFalse(app.buttons["settings-account-avatar"].exists)
        // Editing a profile now lives one page down, behind the connection row.
        openProviderProfileDetail(in: app)
        XCTAssertTrue(app.textFields["표시 이름"].isHittable)
        app.navigationBars["프로필 편집"].buttons.firstMatch.tap()

        // Diagnostics, including the core status panel, live one page in.
        let diagnostics = app.buttons["settings-diagnostics-row"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
        diagnostics.tap()
        XCTAssertTrue(
            app.navigationBars["진단"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.buttons["코어 상태 새로 고침"].waitForExistence(timeout: 5)
        )
        app.navigationBars["진단"].buttons.firstMatch.tap()

        app.swipeDown()
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        home.tap()
        XCTAssertTrue(home.isSelected)
        XCTAssertTrue(
            app.navigationBars["홈"].waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testMistypedFixtureArgumentUsesLiveRuntimePath() {
        let app = XCUIApplication()
        app.launchArguments = ["--lorepia-dev-fixture"]
        app.launch()

        let settings = app.tabBars.buttons["설정"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        let diagnostics = app.buttons["settings-diagnostics-row"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        let diagnosticsReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "isEnabled == true AND isHittable == true"
            ),
            object: diagnostics
        )
        wait(for: [diagnosticsReady], timeout: 10)
        diagnostics.tap()
        XCTAssertTrue(
            app.navigationBars["진단"].waitForExistence(timeout: 5)
        )

        let liveRuntime = app.staticTexts.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Rust Core",
                "Core Unavailable"
            )
        ).firstMatch
        XCTAssertTrue(
            liveRuntime.waitForExistence(timeout: 5),
            "An unknown fixture argument must use the live core path."
        )
        XCTAssertFalse(
            app.staticTexts["Preview Core"].exists,
            "A mistyped fixture argument silently selected preview data."
        )
    }

    @MainActor
    func testHomeAddActionRemainsAccessibleAtLargestTextSize() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--lorepia-ui-test",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()

        let add = app.buttons["home-add-button"]
        let window = app.windows.firstMatch
        XCTAssertTrue(
            app.navigationBars["홈"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let homeButtons = visibleContentElements(
            matching: .button,
            in: app
        )
        XCTAssertEqual(homeButtons.count, 1)
        XCTAssertEqual(homeButtons.first?.identifier, "home-add-button")
        XCTAssertEqual(add.label, "추가하기")
        XCTAssertGreaterThanOrEqual(add.frame.width, 180)
        XCTAssertGreaterThanOrEqual(add.frame.height, 44)
        XCTAssertEqual(add.frame.midX, window.frame.midX, accuracy: 2)
        XCTAssertLessThanOrEqual(add.frame.width, window.frame.width - 32)
        XCTAssertGreaterThan(add.frame.midY, window.frame.midY)
        XCTAssertLessThan(add.frame.maxY, app.tabBars.firstMatch.frame.minY)

        add.tap()
        XCTAssertTrue(app.tabBars.buttons["생성"].isSelected)
        assertBlankCreateScreen(in: app)
    }

    @MainActor
    func testConversationSearchFiltersWithNativeField() {
        let app = XCUIApplication()
        app.launchArguments = ["--lorepia-chat-bubble-showcase"]
        app.launch()

        let chats = app.tabBars.buttons["채팅"]
        XCTAssertTrue(chats.waitForExistence(timeout: 10))
        chats.tap()

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        XCTAssertTrue(searchField.isHittable)
        XCTAssertEqual(
            searchField.value as? String,
            "캐릭터, 대화 제목 또는 메시지 검색"
        )

        let morningRow = app.descendants(matching: .any)[
            "conversation-row-showcase-morning-walk"
        ]
        let lastSceneRow = app.descendants(matching: .any)[
            "conversation-row-showcase-last-scene"
        ]
        XCTAssertTrue(morningRow.waitForExistence(timeout: 5))
        XCTAssertTrue(lastSceneRow.waitForExistence(timeout: 5))

        let screenshot = XCUIScreen.main.screenshot()
        let screenshotAttachment = XCTAttachment(screenshot: screenshot)
        screenshotAttachment.name = "Conversation search"
        screenshotAttachment.lifetime = .keepAlways
        add(screenshotAttachment)

        searchField.tap()
        searchField.typeText("마지막")
        XCTAssertTrue(lastSceneRow.waitForExistence(timeout: 5))
        XCTAssertTrue(morningRow.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testConversationSearchDrawerHidesWhenScrolling() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--lorepia-chat-bubble-showcase",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()

        let chats = app.tabBars.buttons["채팅"]
        XCTAssertTrue(chats.waitForExistence(timeout: 10))
        chats.tap()

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        XCTAssertTrue(searchField.isHittable)

        app.swipeUp()

        let hiddenSearch = expectation(
            for: NSPredicate(format: "hittable == false"),
            evaluatedWith: searchField
        )
        wait(for: [hiddenSearch], timeout: 5)
    }

    @MainActor
    func testConversationRowsMatchReferenceGeometryAndHideStoryBadge() {
        let app = XCUIApplication()
        app.launchArguments = ["--lorepia-chat-bubble-showcase"]
        app.launch()

        let chats = app.tabBars.buttons["채팅"]
        XCTAssertTrue(chats.waitForExistence(timeout: 10))
        chats.tap()
        XCTAssertTrue(
            app.navigationBars["채팅"].waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.buttons["new-conversation-button"].exists)
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(format: "label == %@", "새 대화")
            ).count,
            0,
            "Populated Chats must not restore the removed top action."
        )

        let newestRow = app.descendants(matching: .any)[
            "conversation-row-showcase-morning-walk"
        ]
        let storyRow = app.descendants(matching: .any)[
            "conversation-row-showcase-last-scene"
        ]
        XCTAssertTrue(newestRow.waitForExistence(timeout: 5))
        XCTAssertTrue(storyRow.waitForExistence(timeout: 5))

        let storyTitle = "마지막 장면부터 다시 시작해 보는 이야기"
        let recentMessage =
            "문이 닫히기 직전, 그녀가 뒤를 돌아 아주 작은 목소리로 이름을 불렀다."
        XCTAssertTrue(storyRow.label.contains(storyTitle))
        XCTAssertTrue(storyRow.label.contains(recentMessage))
        XCTAssertTrue(storyRow.label.contains("스토리 모드"))
        XCTAssertFalse(app.staticTexts["스토리 모드"].exists)
        XCTAssertFalse(app.staticTexts["스토리"].exists)

        let newestRowFrame = newestRow.frame
        let storyRowFrame = storyRow.frame
        XCTAssertTrue(newestRow.isHittable)
        XCTAssertTrue(storyRow.isHittable)
        XCTAssertGreaterThanOrEqual(newestRowFrame.height, 44)
        XCTAssertGreaterThanOrEqual(storyRowFrame.height, 44)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let screenshot = XCUIScreen.main.screenshot()
        guard let titleFrame = recognizedFrame(
            of: "새벽 산책",
            in: screenshot
        ),
        let previewFrame = recognizedFrame(
            of: "내 열 줄",
            in: screenshot
        ) else {
            XCTFail("Required title or preview OCR geometry was absent.")
            return
        }
        XCTAssertTrue(newestRowFrame.contains(titleFrame))
        XCTAssertTrue(newestRowFrame.contains(previewFrame))
        // Vision reports glyph-ink bounds, not the SwiftUI text container.
        // Different Korean leading glyphs can vary by several pixels even
        // when their layout origins are identical.
        let ocrLeadingTolerance: CGFloat = 6
        XCTAssertEqual(
            titleFrame.minX,
            previewFrame.minX,
            accuracy: ocrLeadingTolerance
        )

        guard let storyTitleFrame = recognizedFrame(
            of: "마지막 장면부터",
            in: screenshot,
            isolatesMatch: true
        ),
        let storyPreviewFrame = recognizedFrame(
            of: "문이 닫히기 직전",
            in: screenshot
        ),
        let timestampFrame = recognizedRightmostTextFrame(
            in: screenshot,
            rowFrame: newestRowFrame,
            after: window.frame.midX
        ),
        let storyTimestampFrame = recognizedRightmostTextFrame(
            in: screenshot,
            rowFrame: storyRowFrame,
            after: window.frame.midX
        ) else {
            XCTFail(
                "Required row text, avatar, or timestamp geometry was absent."
            )
            return
        }

        let timestampCenterDelta =
            timestampFrame.midY - titleFrame.midY
        let storyTimestampCenterDelta =
            storyTimestampFrame.midY - storyTitleFrame.midY
        let storyTitleTimestampGap =
            storyTimestampFrame.minX - storyTitleFrame.maxX
        let timestampTrailingInset =
            window.frame.maxX - timestampFrame.maxX
        let storyTimestampTrailingInset =
            window.frame.maxX - storyTimestampFrame.maxX
        let metrics = String(
            format:
                """
                row x=%.2f y=%.2f width=%.2f height=%.2f; \
                pitch=%.2f; inferred avatar gap=%.2f; \
                title x=%.2f y=%.2f width=%.2f height=%.2f; \
                preview x=%.2f y=%.2f width=%.2f height=%.2f; \
                story title x=%.2f y=%.2f width=%.2f height=%.2f; \
                story preview x=%.2f y=%.2f width=%.2f height=%.2f; \
                timestamp x=%.2f y=%.2f width=%.2f height=%.2f; \
                timestamp center delta=%.2f trailing inset=%.2f; \
                story timestamp x=%.2f y=%.2f width=%.2f height=%.2f; \
                story timestamp center delta=%.2f trailing inset=%.2f; \
                story title-to-timestamp visual gap=%.2f
                """,
            newestRowFrame.minX,
            newestRowFrame.minY,
            newestRowFrame.width,
            newestRowFrame.height,
            storyRowFrame.midY - newestRowFrame.midY,
            storyRowFrame.midY - newestRowFrame.midY - 52,
            titleFrame.minX,
            titleFrame.minY,
            titleFrame.width,
            titleFrame.height,
            previewFrame.minX,
            previewFrame.minY,
            previewFrame.width,
            previewFrame.height,
            storyTitleFrame.minX,
            storyTitleFrame.minY,
            storyTitleFrame.width,
            storyTitleFrame.height,
            storyPreviewFrame.minX,
            storyPreviewFrame.minY,
            storyPreviewFrame.width,
            storyPreviewFrame.height,
            timestampFrame.minX,
            timestampFrame.minY,
            timestampFrame.width,
            timestampFrame.height,
            timestampCenterDelta,
            timestampTrailingInset,
            storyTimestampFrame.minX,
            storyTimestampFrame.minY,
            storyTimestampFrame.width,
            storyTimestampFrame.height,
            storyTimestampCenterDelta,
            storyTimestampTrailingInset,
            storyTitleTimestampGap
        )
        let metricsAttachment = XCTAttachment(string: metrics)
        metricsAttachment.name = "Rendered conversation row measurements"
        metricsAttachment.lifetime = .keepAlways
        add(metricsAttachment)

        XCTAssertEqual(
            newestRowFrame.height,
            70,
            accuracy: 1
        )
        XCTAssertEqual(
            storyRowFrame.height,
            70,
            accuracy: 1
        )
        XCTAssertEqual(
            storyRowFrame.midY - newestRowFrame.midY,
            70,
            accuracy: 1
        )
        XCTAssertEqual(
            storyRowFrame.minY - newestRowFrame.maxY,
            0,
            accuracy: 1
        )
        XCTAssertEqual(
            storyRowFrame.midY - newestRowFrame.midY - 52,
            18,
            accuracy: 1
        )
        let expectedTextLeading = window.frame.minX + 16 + 52 + 13
        XCTAssertEqual(
            titleFrame.minX,
            expectedTextLeading,
            accuracy: 1.5
        )
        XCTAssertEqual(
            storyTitleFrame.minX,
            expectedTextLeading,
            accuracy: ocrLeadingTolerance
        )
        XCTAssertEqual(
            storyTitleFrame.minX,
            storyPreviewFrame.minX,
            accuracy: ocrLeadingTolerance
        )
        XCTAssertEqual(
            previewFrame.midY - titleFrame.midY,
            24.5,
            accuracy: 2
        )
        XCTAssertEqual(
            storyPreviewFrame.midY - storyTitleFrame.midY,
            24.5,
            accuracy: 3
        )
        XCTAssertEqual(
            timestampFrame.midY,
            titleFrame.midY,
            accuracy: 1.5,
            "The timestamp ink must be visually centered on the title ink."
        )
        XCTAssertEqual(
            storyTimestampFrame.midY,
            storyTitleFrame.midY,
            accuracy: 1.5,
            "Every timestamp must remain centered on its title row."
        )
        XCTAssertEqual(
            titleFrame.union(previewFrame).midY,
            newestRowFrame.midY,
            accuracy: 4
        )
        XCTAssertEqual(
            storyTitleFrame.union(storyPreviewFrame).midY,
            storyRowFrame.midY,
            accuracy: 4
        )
        // OCR bounds follow glyph shapes and cannot reliably compare adjacent
        // 16pt and 15pt fonts; vertical ordering is the stable visual signal.
        XCTAssertLessThan(titleFrame.midY, previewFrame.midY)

        XCTAssertNil(
            recognizedFrame(
                of: "스토리",
                in: screenshot,
                required: false
            ),
            "Story mode must remain available to assistive technology without "
                + "rendering a standalone badge."
        )
    }

    @MainActor
    func testConversationRowWhitespaceOpensChatAfterEdgeSwipeBack() {
        let app = XCUIApplication()
        app.launchArguments = ["--lorepia-chat-bubble-showcase"]
        app.launch()

        let chats = app.tabBars.buttons["채팅"]
        XCTAssertTrue(chats.waitForExistence(timeout: 10))
        chats.tap()

        let conversationRow = app.descendants(matching: .any)[
            "conversation-row-showcase-morning-walk"
        ]
        XCTAssertTrue(conversationRow.waitForExistence(timeout: 5))
        XCTAssertTrue(conversationRow.isHittable)

        let composer = app.descendants(matching: .any)[
            "chat-composer-field"
        ]
        // This point sits to the right of the intentionally short preview,
        // below the timestamp: it is transparent row whitespace.
        conversationRow.coordinate(
            withNormalizedOffset: CGVector(dx: 0.72, dy: 0.78)
        ).tap()
        XCTAssertTrue(
            composer.waitForExistence(timeout: 5),
            "행의 텍스트 바깥 빈 공간을 눌러도 채팅방이 열려야 합니다."
        )

        let window = app.windows.firstMatch
        let leadingEdge = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)
        )
        let destination = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)
        )
        leadingEdge.press(forDuration: 0.05, thenDragTo: destination)

        XCTAssertTrue(chats.waitForExistence(timeout: 5))
        XCTAssertTrue(chats.isSelected)
        XCTAssertTrue(
            app.descendants(matching: .any)["conversation-list-screen"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(composer.waitForNonExistence(timeout: 5))
        XCTAssertTrue(conversationRow.waitForExistence(timeout: 5))
        XCTAssertTrue(conversationRow.isHittable)
        // The top five percent is the row's vertical spacing, not visible
        // avatar or text content.
        conversationRow.coordinate(
            withNormalizedOffset: CGVector(dx: 0.72, dy: 0.05)
        ).tap()
        XCTAssertTrue(
            composer.waitForExistence(timeout: 5),
            "Edge swipe 복귀 후에도 행의 상단 여백으로 다시 열려야 합니다."
        )
        XCTAssertTrue(
            app.navigationBars.buttons["채팅"].waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.tabBars.buttons["채팅"].exists)
    }

    @MainActor
    func testChatShowsNamedSendersOnTheirMessageSides() {
        let app = XCUIApplication()
        app.launchArguments = ["--lorepia-chat-bubble-showcase"]
        app.launch()

        let chats = app.tabBars.buttons["채팅"]
        XCTAssertTrue(chats.waitForExistence(timeout: 10))
        chats.tap()

        let conversationRow = app.descendants(matching: .any)[
            "conversation-row-showcase-library-secret"
        ]
        XCTAssertTrue(conversationRow.waitForExistence(timeout: 5))
        XCTAssertTrue(conversationRow.isHittable)
        conversationRow.tap()

        let userName = app.descendants(matching: .any)[
            "chat-sender-name-user-showcase-library-secret-fixture-1"
        ]
        let assistantName = app.descendants(matching: .any)[
            "chat-sender-name-assistant-showcase-library-secret-fixture-2"
        ]
        let userAvatar = app.descendants(matching: .any)[
            "chat-sender-avatar-user-showcase-library-secret-fixture-1"
        ]
        let assistantAvatar = app.descendants(matching: .any)[
            "chat-sender-avatar-assistant-showcase-library-secret-fixture-2"
        ]
        let window = app.windows.firstMatch
        XCTAssertTrue(userName.waitForExistence(timeout: 5))
        XCTAssertTrue(assistantName.waitForExistence(timeout: 5))
        XCTAssertTrue(userAvatar.waitForExistence(timeout: 5))
        XCTAssertTrue(assistantAvatar.waitForExistence(timeout: 5))
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertEqual(userName.label, "게스트")
        XCTAssertEqual(assistantName.label, "미리보기 안내자")

        let windowMidX = window.frame.midX
        XCTAssertGreaterThan(userName.frame.midX, windowMidX)
        XCTAssertGreaterThan(userAvatar.frame.midX, windowMidX)
        XCTAssertLessThan(assistantName.frame.midX, windowMidX)
        XCTAssertLessThan(assistantAvatar.frame.midX, windowMidX)
        XCTAssertLessThan(userName.frame.maxX, userAvatar.frame.minX)
        XCTAssertLessThan(
            assistantAvatar.frame.maxX,
            assistantName.frame.minX
        )

        for avatar in [userAvatar, assistantAvatar] {
            XCTAssertGreaterThanOrEqual(avatar.frame.width, 28)
            XCTAssertGreaterThanOrEqual(avatar.frame.height, 28)
            XCTAssertEqual(
                avatar.frame.width,
                avatar.frame.height,
                accuracy: 1
            )
        }

        let screenshotAttachment = XCTAttachment(
            screenshot: XCUIScreen.main.screenshot()
        )
        screenshotAttachment.name = "chat-named-senders"
        screenshotAttachment.lifetime = .keepAlways
        add(screenshotAttachment)
    }

    @MainActor
    func testStoryModeSeparatesProseWithDividerAndBreathingRoom() {
        let app = XCUIApplication()
        app.launchArguments = ["--lorepia-chat-bubble-showcase"]
        app.launch()

        let chats = app.tabBars.buttons["채팅"]
        XCTAssertTrue(chats.waitForExistence(timeout: 10))
        chats.tap()

        let storyRow = app.descendants(matching: .any)[
            "conversation-row-showcase-last-scene"
        ]
        XCTAssertTrue(storyRow.waitForExistence(timeout: 5))
        XCTAssertTrue(storyRow.isHittable)
        storyRow.tap()

        let userMessage = app.descendants(matching: .any)[
            "chat-message-user-showcase-last-scene-fixture-1"
        ]
        let assistantMessage = app.descendants(matching: .any)[
            "chat-message-assistant-showcase-last-scene-fixture-2"
        ]
        let userAvatar = app.descendants(matching: .any)[
            "chat-sender-avatar-user-showcase-last-scene-fixture-1"
        ]
        let assistantAvatar = app.descendants(matching: .any)[
            "chat-sender-avatar-assistant-showcase-last-scene-fixture-2"
        ]
        let userName = app.descendants(matching: .any)[
            "chat-sender-name-user-showcase-last-scene-fixture-1"
        ]
        let assistantName = app.descendants(matching: .any)[
            "chat-sender-name-assistant-showcase-last-scene-fixture-2"
        ]
        let userActionRow = app.descendants(matching: .any)[
            "chat-message-action-row-user-showcase-last-scene-fixture-1"
        ]
        let assistantActionRow = app.descendants(matching: .any)[
            "chat-message-action-row-assistant-showcase-last-scene-fixture-2"
        ]
        let userEditID =
            "chat-message-action-edit-user-showcase-last-scene-fixture-1"
        let assistantRegenerateID =
            "chat-message-action-regenerate-assistant-"
                + "showcase-last-scene-fixture-2"
        let userEdit = app.buttons[userEditID]
        let assistantRegenerate = app.buttons[assistantRegenerateID]
        let composerMode = app.buttons["chat-composer-mode"]
        XCTAssertTrue(userMessage.waitForExistence(timeout: 5))
        XCTAssertTrue(assistantMessage.waitForExistence(timeout: 5))
        XCTAssertTrue(userAvatar.waitForExistence(timeout: 5))
        XCTAssertTrue(assistantAvatar.waitForExistence(timeout: 5))
        XCTAssertTrue(userName.waitForExistence(timeout: 5))
        XCTAssertTrue(assistantName.waitForExistence(timeout: 5))
        XCTAssertTrue(userActionRow.waitForExistence(timeout: 5))
        XCTAssertTrue(assistantActionRow.waitForExistence(timeout: 5))
        XCTAssertTrue(userEdit.waitForExistence(timeout: 5))
        XCTAssertTrue(assistantRegenerate.waitForExistence(timeout: 5))
        XCTAssertTrue(composerMode.waitForExistence(timeout: 5))
        XCTAssertEqual(composerMode.value as? String, "스토리 모드")
        XCTAssertTrue(userActionRow.isHittable)
        XCTAssertTrue(assistantActionRow.isHittable)
        XCTAssertTrue(userEdit.isHittable)
        XCTAssertTrue(assistantRegenerate.isHittable)
        XCTAssertEqual(userName.label, "게스트")
        XCTAssertEqual(assistantName.label, "별빛 지도사")
        for avatar in [userAvatar, assistantAvatar] {
            XCTAssertGreaterThanOrEqual(avatar.frame.width, 28)
            XCTAssertGreaterThanOrEqual(avatar.frame.height, 28)
            XCTAssertEqual(
                avatar.frame.width,
                avatar.frame.height,
                accuracy: 1
            )
        }
        for action in [userEdit, assistantRegenerate] {
            XCTAssertGreaterThanOrEqual(action.frame.width, 44)
            XCTAssertGreaterThanOrEqual(action.frame.height, 44)
        }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        for (avatar, message) in [
            (userAvatar, userMessage),
            (assistantAvatar, assistantMessage),
        ] {
            XCTAssertEqual(
                avatar.frame.minX - window.frame.minX,
                28,
                accuracy: 1
            )
            XCTAssertEqual(
                message.frame.minX - window.frame.minX,
                28,
                accuracy: 1
            )
            XCTAssertEqual(
                window.frame.maxX - message.frame.maxX,
                28,
                accuracy: 1
            )
        }

        let userFrame = userMessage.frame
        let assistantFrame = assistantMessage.frame
        XCTAssertLessThan(userFrame.midY, assistantFrame.midY)
        XCTAssertEqual(
            userActionRow.frame.minY,
            userFrame.maxY,
            accuracy: 1
        )
        XCTAssertLessThan(
            userActionRow.frame.maxY,
            assistantFrame.minY
        )
        XCTAssertEqual(
            assistantActionRow.frame.minY,
            assistantFrame.maxY,
            accuracy: 1
        )

        let screenshot = XCUIScreen.main.screenshot()
        guard let userTextFrame = recognizedFrame(
            of: "성문이 닫히기 직전 장면부터",
            in: screenshot
        ),
        let assistantTextFrame = recognizedFrame(
            of: "그녀가 뒤를 돌아",
            in: screenshot
        ) else {
            XCTFail("스토리 구분선 양쪽의 합성 문장을 찾지 못했습니다.")
            return
        }
        XCTAssertTrue(
            userFrame.insetBy(dx: -4, dy: -2).contains(userTextFrame)
        )
        XCTAssertTrue(
            assistantFrame.insetBy(dx: -4, dy: -2)
                .contains(assistantTextFrame)
        )
        XCTAssertLessThan(userAvatar.frame.maxY, userTextFrame.minY)
        XCTAssertLessThan(userTextFrame.maxY, userActionRow.frame.minY)
        XCTAssertLessThan(
            assistantAvatar.frame.maxY,
            assistantTextFrame.minY
        )
        XCTAssertLessThan(
            assistantTextFrame.maxY,
            assistantActionRow.frame.minY
        )
        let readingBreak =
            assistantTextFrame.minY - userTextFrame.maxY
        XCTAssertGreaterThanOrEqual(
            readingBreak,
            24,
            "스토리 단락 사이에는 구분선과 넉넉한 읽기 여백이 있어야 합니다."
        )

        let screenshotAttachment = XCTAttachment(
            screenshot: screenshot
        )
        screenshotAttachment.name =
            "story-mode-divider-and-breathing-room"
        screenshotAttachment.lifetime = .keepAlways
        add(screenshotAttachment)

        userMessage.press(forDuration: 0.6)
        XCTAssertEqual(
            app.buttons.matching(identifier: userEditID).count,
            1,
            "스토리 메시지를 길게 눌러도 편집 팝오버를 중복 생성하면 안 됩니다."
        )
        assistantMessage.press(forDuration: 0.6)
        XCTAssertEqual(
            app.buttons.matching(identifier: assistantRegenerateID).count,
            1,
            "스토리 메시지를 길게 눌러도 재생성 팝오버를 중복 생성하면 안 됩니다."
        )
    }

    @MainActor
    func testConversationRowsRemainReadableAtLargestTextSize() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--lorepia-chat-bubble-showcase",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()

        let chats = app.tabBars.buttons["채팅"]
        XCTAssertTrue(chats.waitForExistence(timeout: 10))
        chats.tap()

        let newestRow = app.descendants(matching: .any)[
            "conversation-row-showcase-morning-walk"
        ]
        let storyRow = app.descendants(matching: .any)[
            "conversation-row-showcase-last-scene"
        ]
        XCTAssertTrue(newestRow.waitForExistence(timeout: 5))
        XCTAssertTrue(newestRow.isHittable)
        XCTAssertGreaterThanOrEqual(newestRow.frame.height, 72)

        let screenshot = XCUIScreen.main.screenshot()
        guard let titleFrame = recognizedFrame(
            of: "새벽 산책",
            in: screenshot
        ),
        let previewFrame = recognizedFrame(
            of: "내 열 줄",
            in: screenshot
        ) else {
            XCTFail(
                "Required large-text conversation geometry was absent."
            )
            return
        }

        XCTAssertTrue(newestRow.frame.contains(titleFrame))
        XCTAssertTrue(newestRow.frame.contains(previewFrame))
        XCTAssertEqual(titleFrame.minX, previewFrame.minX, accuracy: 4)
        XCTAssertLessThan(titleFrame.midY, previewFrame.midY)
        XCTAssertLessThanOrEqual(
            max(titleFrame.maxX, previewFrame.maxX),
            app.windows.firstMatch.frame.maxX - 8
        )

        app.swipeUp()
        XCTAssertTrue(storyRow.waitForExistence(timeout: 5))
        XCTAssertTrue(storyRow.isHittable)
        XCTAssertGreaterThanOrEqual(storyRow.frame.height, 72)
        XCTAssertTrue(storyRow.label.contains("스토리 모드"))
        XCTAssertFalse(app.staticTexts["스토리 모드"].exists)
        XCTAssertFalse(app.staticTexts["스토리"].exists)
    }

    @MainActor
    func testChatBackButtonReturnsToConversationList() {
        let app = XCUIApplication()
        app.launchArguments = ["--lorepia-chat-bubble-showcase"]
        app.launch()

        let chats = app.tabBars.buttons["채팅"]
        XCTAssertTrue(chats.waitForExistence(timeout: 10))
        chats.tap()

        let conversationRow = app.descendants(matching: .any)[
            "conversation-row-showcase-morning-walk"
        ]
        XCTAssertTrue(conversationRow.waitForExistence(timeout: 5))
        XCTAssertTrue(conversationRow.isHittable)
        conversationRow.tap()

        let composer = app.descendants(matching: .any)[
            "chat-composer-field"
        ]
        let backButton = app.navigationBars.buttons["채팅"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))

        backButton.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["conversation-list-screen"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(composer.waitForNonExistence(timeout: 5))
        XCTAssertTrue(conversationRow.waitForExistence(timeout: 5))
        XCTAssertTrue(conversationRow.isHittable)
    }

    @MainActor
    func testChatRestoresIndependentDraftsWhenReenteringRooms() {
        let app = XCUIApplication()
        app.launchArguments = ["--lorepia-chat-bubble-showcase"]
        app.launch()

        let chats = app.tabBars.buttons["채팅"]
        XCTAssertTrue(chats.waitForExistence(timeout: 10))
        chats.tap()

        let firstRoom = app.descendants(matching: .any)[
            "conversation-row-showcase-morning-walk"
        ]
        let secondRoom = app.descendants(matching: .any)[
            "conversation-row-showcase-last-scene"
        ]
        XCTAssertTrue(firstRoom.waitForExistence(timeout: 5))
        XCTAssertTrue(secondRoom.waitForExistence(timeout: 5))

        let composer = app.descendants(matching: .any)[
            "chat-composer-field"
        ]
        firstRoom.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("첫 방 미전송 초안")
        app.navigationBars.buttons["채팅"].tap()
        XCTAssertTrue(firstRoom.waitForExistence(timeout: 5))

        secondRoom.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "")
        composer.tap()
        composer.typeText("둘째 방 미전송 초안")
        app.navigationBars.buttons["채팅"].tap()
        XCTAssertTrue(secondRoom.waitForExistence(timeout: 5))

        firstRoom.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(
            composer.value as? String,
            "첫 방 미전송 초안"
        )
        app.navigationBars.buttons["채팅"].tap()
        XCTAssertTrue(firstRoom.waitForExistence(timeout: 5))

        secondRoom.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(
            composer.value as? String,
            "둘째 방 미전송 초안"
        )
    }

    @MainActor
    func testLongRestoredDraftStaysInsideComposerWhenReenteringRoom() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--lorepia-native-navigation-ui-test",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryL",
        ]
        let longDraft = (1 ... 12)
            .map { "실험용 입력 \(String(format: "%02d", $0))" }
            .joined(separator: "\n")
        app.launchEnvironment["LOREPIA_UI_TEST_CHAT_DRAFT"] = longDraft
        app.launch()

        guard openPreviewChat(in: app) else {
            return
        }

        var composer = app.descendants(matching: .any)[
            "chat-composer-field"
        ]
        let initialDraft = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", longDraft),
            object: composer
        )
        wait(for: [initialDraft], timeout: 5)

        let backButton = app.navigationBars.buttons["채팅"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        backButton.tap()

        let restoredRoom = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "conversation-row-"
            )
        ).firstMatch
        XCTAssertTrue(restoredRoom.waitForExistence(timeout: 5))
        restoredRoom.tap()

        composer = app.descendants(matching: .any)[
            "chat-composer-field"
        ]
        let composerSurface = app.descendants(matching: .any)[
            "chat-composer-surface"
        ]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(
            composerSurface.exists,
            "The composer surface must appear with its restored editor."
        )
        XCTAssertEqual(composer.value as? String, longDraft)
        XCTAssertGreaterThan(
            composer.frame.height,
            80,
            "The restored compact editor must reopen at its five-line cap."
        )
        XCTAssertTrue(
            composerSurface.frame
                .insetBy(dx: -1, dy: -1)
                .contains(composer.frame),
            "The restored editor must remain inside its compact surface."
        )
    }

    @MainActor
    func testChatSupportsNativeEdgeSwipeBack() {
        let app = XCUIApplication()
        app.launchArguments = ["--lorepia-native-navigation-ui-test"]
        app.launch()

        guard openPreviewChat(in: app) else {
            return
        }

        let composer = app.descendants(matching: .any)[
            "chat-composer-field"
        ]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("제스처 복귀 초안")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))

        let window = app.windows.firstMatch
        let leadingEdge = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)
        )
        let destination = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)
        )

        let backButton = app.navigationBars.buttons["채팅"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["채팅"].exists)

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
        XCTAssertFalse(app.tabBars.buttons["채팅"].exists)
        XCTAssertTrue(
            app.keyboards.firstMatch.exists,
            "취소된 edge swipe 뒤에도 키보드가 열린 채팅 상태여야 합니다."
        )

        leadingEdge.press(forDuration: 0.05, thenDragTo: destination)

        let chats = app.tabBars.buttons["채팅"]
        XCTAssertTrue(chats.waitForExistence(timeout: 5))
        XCTAssertTrue(chats.isSelected)
        XCTAssertTrue(
            app.descendants(matching: .any)["conversation-list-screen"]
                .waitForExistence(timeout: 5)
        )

        XCTAssertTrue(composer.waitForNonExistence(timeout: 5))

        let conversationRow = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@",
                    "conversation-row-"
                )
            )
            .firstMatch
        XCTAssertTrue(conversationRow.waitForExistence(timeout: 5))
        XCTAssertTrue(
            conversationRow.isHittable,
            "Edge swipe 뒤 대화 row가 다시 터치 가능해야 합니다."
        )

        conversationRow.tap()

        XCTAssertTrue(
            composer.waitForExistence(timeout: 5),
            "Edge swipe 뒤 같은 대화를 다시 열 수 있어야 합니다."
        )
        XCTAssertTrue(
            app.navigationBars.buttons["채팅"].waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.tabBars.buttons["채팅"].exists)
    }

    @MainActor
    func testChatModelControlExposesAppWideDefaultProviderAndModel() {
        let app = XCUIApplication()
        app.launchArguments = ["--lorepia-native-navigation-ui-test"]
        app.launch()

        guard openPreviewChat(in: app) else {
            return
        }

        let model = app.buttons["chat-composer-model"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        XCTAssertEqual(model.label, "앱 전체 기본 모델")
        XCTAssertEqual(
            model.value as? String,
            "Preview Provider · preview-model"
        )

        model.tap()
        let selectedProvider = app.buttons[
            "chat-composer-model-option-preview-provider"
        ]
        let providerSettings = app.buttons[
            "chat-composer-provider-settings"
        ]
        XCTAssertTrue(selectedProvider.waitForExistence(timeout: 2))
        XCTAssertEqual(
            selectedProvider.label,
            "Preview Provider · preview-model"
        )
        XCTAssertTrue(providerSettings.waitForExistence(timeout: 2))
        XCTAssertEqual(providerSettings.label, "프로바이더 설정")
    }

    @MainActor
    func testMissingProviderEmptyChatCTAOpensSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["--lorepia-native-navigation-ui-test"]
        app.launch()

        let settingsTab = app.tabBars.buttons["설정"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10))
        settingsTab.tap()
        XCTAssertTrue(settingsTab.isSelected)
        openProviderProfileDetail(in: app)

        let profilePicker = app.buttons[
            "settings-provider-profile-picker"
        ]
        let profileName = app.textFields["표시 이름"]
        let newProfileButtons = app.buttons.matching(
            identifier: "settings-new-provider-profile"
        )
        let deleteProfileButtons = app.buttons.matching(
            identifier: "settings-delete-provider-profile"
        )
        let saveProfileButtons = app.buttons.matching(
            identifier: "settings-save-provider-profile"
        )
        XCTAssertTrue(profilePicker.waitForExistence(timeout: 5))
        XCTAssertEqual(profilePicker.value as? String, "Preview Provider")
        XCTAssertTrue(profileName.waitForExistence(timeout: 5))
        XCTAssertEqual(newProfileButtons.count, 1)
        XCTAssertEqual(deleteProfileButtons.count, 1)
        XCTAssertEqual(saveProfileButtons.count, 1)
        let deleteProfile = deleteProfileButtons.firstMatch
        XCTAssertTrue(deleteProfile.waitForExistence(timeout: 5))
        if !deleteProfile.isHittable {
            app.swipeUp()
        }
        XCTAssertEqual(deleteProfileButtons.count, 1)
        let visibleDeleteProfile = deleteProfileButtons.firstMatch
        XCTAssertTrue(visibleDeleteProfile.waitForExistence(timeout: 5))
        let deleteEnabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "isEnabled == true AND isHittable == true"
            ),
            object: visibleDeleteProfile
        )
        wait(for: [deleteEnabled], timeout: 5)
        XCTAssertEqual(profileName.value as? String, "Preview Provider")
        XCTAssertEqual(visibleDeleteProfile.label, "프로필 삭제")
        visibleDeleteProfile.tap()

        let deletionStarted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == false"),
            object: visibleDeleteProfile
        )
        wait(for: [deletionStarted], timeout: 5)

        let clearedProfileName = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value == nil OR value == '' OR value == %@",
                "표시 이름"
            ),
            object: app.textFields["표시 이름"]
        )
        let clearedModel = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value == nil OR value == '' OR value == %@",
                "모델"
            ),
            object: app.textFields["모델"]
        )
        wait(for: [clearedProfileName, clearedModel], timeout: 5)

        app.swipeDown()
        app.swipeDown()
        let noSelectedProfile = app.buttons[
            "settings-provider-profile-picker"
        ]
        XCTAssertTrue(noSelectedProfile.waitForExistence(timeout: 5))
        let noSelectedProfileValue = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value == %@",
                "선택 안 함"
            ),
            object: noSelectedProfile
        )
        let noSelectedProfileResult = XCTWaiter().wait(
            for: [noSelectedProfileValue],
            timeout: 5
        )
        if noSelectedProfileResult == .completed {
            let selectionMustRemainEmpty = XCTNSPredicateExpectation(
                predicate: NSPredicate(
                    format: "value != %@",
                    "선택 안 함"
                ),
                object: noSelectedProfile
            )
            selectionMustRemainEmpty.isInverted = true
            wait(for: [selectionMustRemainEmpty], timeout: 1)
        }
        let observedPickerValue = noSelectedProfile.value as? String
        XCTAssertFalse(
            app.buttons["settings-delete-provider-profile"].isEnabled
        )

        app.navigationBars["프로필 편집"].buttons.firstMatch.tap()
        let diagnostics = app.buttons["settings-diagnostics-row"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
        diagnostics.tap()
        XCTAssertTrue(
            app.navigationBars["진단"].waitForExistence(timeout: 5)
        )

        guard openPreviewChat(in: app) else {
            return
        }

        let providerCTA = app.buttons["chat-empty-provider-settings"]
        let providerCTAExists = providerCTA.waitForExistence(timeout: 5)

        let model = app.buttons["chat-composer-model"]
        let modelExists = model.waitForExistence(timeout: 5)
        let observedModelValue = model.value as? String

        XCTAssertTrue(
            noSelectedProfileResult == .completed,
            "Deleted profile remained selected: \(observedPickerValue ?? "nil")"
        )
        XCTAssertTrue(
            providerCTAExists,
            "Missing-provider CTA absent; model value: \(observedModelValue ?? "nil")"
        )
        XCTAssertTrue(modelExists)
        XCTAssertEqual(model.label, "앱 전체 기본 모델")
        XCTAssertEqual(model.value as? String, "선택 안 됨")

        if providerCTAExists {
            XCTAssertEqual(providerCTA.label, "프로바이더 설정")
            providerCTA.tap()
            XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
            XCTAssertTrue(settingsTab.isSelected)
            // The CTA targets provider configuration directly and replaces
            // any settings detail path that the tab previously preserved.
            XCTAssertTrue(
                app.navigationBars["프로필 편집"]
                    .waitForExistence(timeout: 5)
            )
            XCTAssertTrue(
                app.buttons["settings-provider-profile-picker"]
                    .waitForExistence(timeout: 5)
            )
        }
    }

    @MainActor
    func testChatComposerSoftWrapMovesAsOne() {
        let app = XCUIApplication()
        app.launchArguments = ["--lorepia-native-navigation-ui-test"]
        app.launch()

        guard openPreviewChat(in: app) else {
            return
        }

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
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "chat-message-assistant-",
                "이 응답은 테스트용 합성 메시지입니다."
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
        let retainedFocusValue = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value CONTAINS %@",
                "포커스유지"
            ),
            object: composer
        )
        wait(for: [retainedFocusValue], timeout: 2)
    }

    @MainActor
    func testChatComposerStaysOpenWhenKeyboardDismisses() {
        let app = XCUIApplication()
        app.launchArguments = ["--lorepia-native-navigation-ui-test"]
        app.launch()

        guard openPreviewChat(in: app) else {
            return
        }

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
    func testChatBalancesDaySeparatorSpacing() {
        let app = XCUIApplication()
        app.launchArguments = ["--lorepia-chat-history-showcase"]
        app.launch()

        let chats = app.tabBars.buttons["채팅"]
        XCTAssertTrue(chats.waitForExistence(timeout: 10))
        chats.tap()

        let history = app.buttons["conversation-row-history-long-run"]
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.tap()

        let messageQuery = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "chat-message-"
            )
        )
        XCTAssertTrue(messageQuery.firstMatch.waitForExistence(timeout: 5))

        let messages = messageQuery.allElementsBoundByIndex.filter {
            $0.frame.width > 0 && $0.frame.height > 0
        }
        let separators = app.buttons.matching(
            identifier: "chat-day-separator"
        ).allElementsBoundByIndex
        let measured = separators.compactMap { separator
            -> (XCUIElement, XCUIElement, XCUIElement)? in
            let before = messages
                .filter { $0.frame.maxY <= separator.frame.minY }
                .max { $0.frame.maxY < $1.frame.maxY }
            let after = messages
                .filter { $0.frame.minY >= separator.frame.maxY }
                .min { $0.frame.minY < $1.frame.minY }
            guard let before, let after else {
                return nil
            }
            return (separator, before, after)
        }
        guard let (separator, before, after) = measured.first else {
            XCTFail("The visible day separator was not found.")
            return
        }

        let upperGap = separator.frame.minY - before.frame.maxY
        let lowerGap = after.frame.minY - separator.frame.maxY
        XCTAssertEqual(upperGap, lowerGap, accuracy: 1)
        // The visible capsule remains 24pt, centered inside an accessible
        // control whose transparent top and bottom complete a 44pt target.
        XCTAssertGreaterThanOrEqual(separator.frame.height, 44)
        XCTAssertEqual(
            separator.frame.midX,
            app.windows.firstMatch.frame.midX,
            accuracy: 1
        )
    }

    @MainActor
    func testChatUsesSingleToolbarSearchAndSeparateSearchSteps() {
        let app = XCUIApplication()
        app.launchArguments = ["--lorepia-native-navigation-ui-test"]
        app.launch()

        guard openPreviewChat(in: app) else {
            return
        }

        let back = app.navigationBars.buttons["채팅"]
        let search: XCUIElement
        if #available(iOS 26.0, *) {
            search = app.buttons["검색"]
        } else {
            search = app.buttons["chat-room-search-trigger"]
        }
        let navigationBar = app.navigationBars.firstMatch
        let window = app.windows.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.buttons["chat-room-settings-trigger-toolbar"].exists
        )
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 5))
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(search.isHittable)
        XCTAssertGreaterThanOrEqual(search.frame.width, 36)
        XCTAssertGreaterThanOrEqual(search.frame.height, 36)
        XCTAssertEqual(search.frame.midY, back.frame.midY, accuracy: 1)
        XCTAssertEqual(
            back.frame.midX - window.frame.minX,
            window.frame.maxX - search.frame.midX,
            accuracy: 1
        )
        if #available(iOS 26.0, *) {
            // The minimized native search item's accessibility frame is its
            // 36pt inner control. Its system glass expands equally to the
            // back control's 44pt visual diameter.
            XCTAssertEqual(back.frame.width, 44, accuracy: 1)
            XCTAssertEqual(back.frame.height, 44, accuracy: 1)
            XCTAssertEqual(search.frame.width, 36, accuracy: 1)
            XCTAssertEqual(search.frame.height, 36, accuracy: 1)
            let searchGlassOutset =
                (back.frame.width - search.frame.width) / 2
            XCTAssertEqual(
                back.frame.minX - window.frame.minX,
                window.frame.maxX
                    - (search.frame.maxX + searchGlassOutset),
                accuracy: 1
            )
        }
        XCTAssertGreaterThanOrEqual(
            search.frame.minY,
            navigationBar.frame.minY
        )
        XCTAssertLessThanOrEqual(
            search.frame.maxY,
            navigationBar.frame.maxY
        )

        let restingSearchFrame = search.frame

        let toolbarEvidence = XCTAttachment(screenshot: app.screenshot())
        toolbarEvidence.name = "chat-toolbar-single-search"
        toolbarEvidence.lifetime = .keepAlways
        add(toolbarEvidence)

        app.swipeDown()
        XCTAssertFalse(
            app.searchFields.firstMatch.exists,
            "Pulling down must not reveal a native search field."
        )

        search.tap()
        let searchField = app.searchFields.firstMatch
        let closeSearch = app.buttons.matching(
            NSPredicate(format: "label == '닫기' OR label == '취소'")
        ).firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        XCTAssertTrue(closeSearch.waitForExistence(timeout: 5))
        XCTAssertTrue(searchField.isHittable)
        XCTAssertTrue(closeSearch.isHittable)
        let focusExpectation = expectation(
            for: NSPredicate(format: "hasKeyboardFocus == true"),
            evaluatedWith: searchField
        )
        wait(for: [focusExpectation], timeout: 2)
        app.typeText("preview")
        XCTAssertEqual(searchField.value as? String, "preview")

        let navigationBarFrame = navigationBar.frame
        XCTAssertGreaterThanOrEqual(
            searchField.frame.minY,
            navigationBarFrame.minY - 1
        )
        XCTAssertLessThanOrEqual(
            searchField.frame.maxY,
            navigationBarFrame.maxY + 1
        )
        XCTAssertGreaterThanOrEqual(
            closeSearch.frame.minY,
            navigationBarFrame.minY - 1
        )
        XCTAssertLessThanOrEqual(
            closeSearch.frame.maxY,
            navigationBarFrame.maxY + 1
        )

        let activeSearchFieldFrame = searchField.frame
        let activeCloseFrame = closeSearch.frame
        Thread.sleep(forTimeInterval: 0.35)
        XCTAssertEqual(
            searchField.frame.minX,
            activeSearchFieldFrame.minX,
            accuracy: 1
        )
        XCTAssertEqual(
            searchField.frame.midY,
            activeSearchFieldFrame.midY,
            accuracy: 1
        )
        XCTAssertEqual(
            searchField.frame.width,
            activeSearchFieldFrame.width,
            accuracy: 1
        )
        XCTAssertEqual(
            searchField.frame.height,
            activeSearchFieldFrame.height,
            accuracy: 1
        )
        XCTAssertEqual(
            closeSearch.frame.minX,
            activeCloseFrame.minX,
            accuracy: 1
        )
        XCTAssertEqual(
            closeSearch.frame.midY,
            activeCloseFrame.midY,
            accuracy: 1
        )
        XCTAssertEqual(
            closeSearch.frame.width,
            activeCloseFrame.width,
            accuracy: 1
        )
        XCTAssertEqual(
            closeSearch.frame.height,
            activeCloseFrame.height,
            accuracy: 1
        )

        let searchEvidence = XCTAttachment(screenshot: app.screenshot())
        searchEvidence.name = "chat-toolbar-top-only-search"
        searchEvidence.lifetime = .keepAlways
        add(searchEvidence)

        let previous = app.buttons["chat-search-previous-result"]
        let next = app.buttons["chat-search-next-result"]
        XCTAssertTrue(previous.waitForExistence(timeout: 5))
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertEqual(previous.frame.width, 44, accuracy: 1)
        XCTAssertEqual(previous.frame.height, 44, accuracy: 1)
        XCTAssertEqual(next.frame.width, 44, accuracy: 1)
        XCTAssertEqual(next.frame.height, 44, accuracy: 1)
        XCTAssertEqual(previous.frame.midX, next.frame.midX, accuracy: 1)
        XCTAssertGreaterThan(next.frame.minY - previous.frame.maxY, 0)

        closeSearch.tap()
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 5))
        XCTAssertTrue(closeSearch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.isHittable)
        XCTAssertFalse(
            app.buttons["chat-room-settings-trigger-toolbar"].exists
        )
        XCTAssertEqual(
            search.frame.minX,
            restingSearchFrame.minX,
            accuracy: 1
        )
        XCTAssertEqual(
            search.frame.midY,
            restingSearchFrame.midY,
            accuracy: 1
        )
        XCTAssertEqual(
            search.frame.width,
            restingSearchFrame.width,
            accuracy: 1
        )
        XCTAssertEqual(
            search.frame.height,
            restingSearchFrame.height,
            accuracy: 1
        )
        app.swipeDown()
        XCTAssertFalse(app.searchFields.firstMatch.exists)

        search.tap()
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        XCTAssertTrue(closeSearch.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(
            searchField.frame.minY,
            navigationBar.frame.minY - 1
        )
        XCTAssertLessThanOrEqual(
            searchField.frame.maxY,
            navigationBar.frame.maxY + 1
        )
    }

    @MainActor
    func testChatHidesRoomSettingsAndSupportsComposerGrowth() {
        let app = XCUIApplication()
        app.launchArguments = ["--lorepia-native-navigation-ui-test"]
        app.launch()

        guard openPreviewChat(in: app) else {
            return
        }

        XCTAssertFalse(
            app.buttons["chat-room-settings-trigger-toolbar"].exists
        )
        XCTAssertFalse(
            app.buttons["chat-room-settings-trigger-mode"].exists
        )
        let windowBounds = app.windows.firstMatch.frame
        // Establish the keyboard-dismissed baseline before measuring the
        // composer; the composer itself must remain fully open.
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
        XCTAssertEqual(
            model.value as? String,
            "Preview Provider · preview-model"
        )
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
        let usesLiquidGlassAccessibilityBounds =
            ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
        let expectedSurfaceHorizontalInset: CGFloat =
            usesLiquidGlassAccessibilityBounds
                ? 14
                : 12
        let expectedSurfaceBottomInset: CGFloat =
            usesLiquidGlassAccessibilityBounds
                ? 36
                : 34
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
        XCTAssertEqual(
            restingSurfaceBottomInset,
            expectedSurfaceBottomInset,
            accuracy: 2
        )

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
        XCTAssertEqual(
            model.value as? String,
            "Preview Provider · preview-model"
        )
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
            expectedSurfaceHorizontalInset,
            accuracy: 1
        )
        XCTAssertEqual(
            windowBounds.maxX - focusedSurfaceBounds.maxX,
            expectedSurfaceHorizontalInset,
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
        XCTAssertEqual(
            model.value as? String,
            "Preview Provider · preview-model"
        )
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

        // The multiline editor keeps one native compact 1...5 configuration.
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
        XCTAssertEqual(
            model.value as? String,
            "Preview Provider · preview-model"
        )
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
            String(repeating: "최대 높이 이후 내부 스크롤 ", count: 14)
        )
        let expand = app.buttons["chat-composer-expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        XCTAssertTrue(expand.isHittable)
        let maximumComposerBounds = tools.frame
            .union(composer.frame)
            .union(send.frame)
            .union(model.frame)
            .union(mode.frame)
        // The compact editor stops at five visual lines and exposes fullscreen
        // expansion instead of continuing to grow.
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
            String(repeating: " capped", count: 12)
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
    }

    @MainActor
    func testChatMessageActionPopoverUsesPerMessageActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--lorepia-native-navigation-ui-test"]
        app.launch()

        guard openPreviewChat(in: app) else {
            return
        }

        let composer = app.descendants(matching: .any)[
            "chat-composer-field"
        ]
        let send = app.buttons["메시지 보내기"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("액션 메뉴 확인")
        XCTAssertTrue(send.isEnabled)
        send.tap()

        // Message actions are revealed per message now, so the row has to be
        // asked for before it can be asserted on.
        let userMessage = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "chat-message-user-"
            )
        ).firstMatch
        XCTAssertTrue(userMessage.waitForExistence(timeout: 5))
        let assistantMessage = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "chat-message-assistant-"
            )
        ).firstMatch
        XCTAssertTrue(assistantMessage.waitForExistence(timeout: 5))

        composer.tap()
        composer.typeText("보존할 일반 초안")
        app.windows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)
        ).tap()
        XCTAssertTrue(
            String(describing: composer.value).contains("보존할 일반 초안")
        )
        XCTAssertTrue(userMessage.isHittable)
        userMessage.press(forDuration: 0.6)

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
        XCTAssertEqual(edit.label, "편집")

        // Only the pressed message's menu is up.
        XCTAssertFalse(regenerate.exists)
        // Dismiss the popover before asking for the next one.
        app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)
        ).tap()
        XCTAssertFalse(edit.waitForExistence(timeout: 1))
        assistantMessage.press(forDuration: 0.6)
        XCTAssertTrue(regenerate.waitForExistence(timeout: 5))
        XCTAssertTrue(regenerate.isHittable)
        XCTAssertEqual(regenerate.label, "재생성")
        XCTAssertFalse(edit.exists)

        app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)
        ).tap()
        userMessage.press(forDuration: 0.6)

        let copy = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "chat-message-action-copy-user-"
            )
        ).firstMatch
        XCTAssertTrue(copy.isHittable)
        XCTAssertEqual(copy.label, "복사")
        copy.tap()
        XCTAssertTrue(app.buttons["복사됨"].waitForExistence(timeout: 2))

        XCTAssertTrue(edit.isHittable)
        edit.tap()

        let composerSurface = app.descendants(matching: .any)[
            "chat-composer-surface"
        ]
        let editCancel = app.buttons["chat-composer-edit-cancel"]
        let editSave = app.buttons["chat-composer-edit-save"]
        let editExpand = app.buttons["chat-composer-edit-expand"]
        XCTAssertTrue(editCancel.waitForExistence(timeout: 5))
        XCTAssertTrue(editSave.waitForExistence(timeout: 5))
        XCTAssertFalse(editExpand.exists)
        XCTAssertEqual(
            composerSurface.value as? String,
            "메시지 편집 중"
        )
        XCTAssertTrue(
            String(describing: composer.value).contains("액션 메뉴 확인")
        )
        XCTAssertFalse(app.navigationBars["메시지 편집"].exists)

        // The existing composer becomes the focused editor; it is no longer
        // presented inside a separate navigation sheet or requires another tap.
        composer.typeText(" 수정 취소")
        let editedDraft = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value CONTAINS %@",
                "수정 취소"
            ),
            object: composer
        )
        wait(for: [editedDraft], timeout: 2)

        editCancel.tap()
        XCTAssertTrue(editSave.waitForNonExistence(timeout: 5))
        XCTAssertEqual(composerSurface.value as? String, "입력 준비")
        XCTAssertTrue(
            String(describing: composer.value).contains("보존할 일반 초안")
        )
        XCTAssertTrue(userMessage.label.contains("액션 메뉴 확인"))
        XCTAssertFalse(userMessage.label.contains("수정 취소"))
    }

    @MainActor
    func testComposerExpansionAppearsOnlyBeyondFiveLines() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--lorepia-native-navigation-ui-test",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryL",
        ]

        let fiveLines = "가\n나\n다\n라\n마"
        app.launchEnvironment["LOREPIA_UI_TEST_CHAT_DRAFT"] = fiveLines
        app.launch()

        guard openPreviewChat(in: app) else {
            return
        }

        var composer = app.descendants(matching: .any)[
            "chat-composer-field"
        ]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let fiveLineDraft = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value == %@",
                fiveLines
            ),
            object: composer
        )
        wait(for: [fiveLineDraft], timeout: 5)
        XCTAssertFalse(app.buttons["chat-composer-expand"].exists)
        XCTAssertFalse(app.buttons["chat-composer-collapse"].exists)

        app.terminate()

        let sixLines = "가\n나\n다\n라\n마\n바"
        app.launchEnvironment["LOREPIA_UI_TEST_CHAT_DRAFT"] = sixLines
        app.launch()

        guard openPreviewChat(in: app) else {
            return
        }

        composer = app.descendants(matching: .any)[
            "chat-composer-field"
        ]
        let composerSurface = app.descendants(matching: .any)[
            "chat-composer-surface"
        ]
        let expand = app.buttons["chat-composer-expand"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(composerSurface.waitForExistence(timeout: 5))
        let sixLineDraft = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value == %@",
                sixLines
            ),
            object: composer
        )
        wait(for: [sixLineDraft], timeout: 5)
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        XCTAssertTrue(expand.isHittable)
        XCTAssertEqual(expand.label, "입력창 확대")
        XCTAssertFalse(app.buttons["chat-composer-collapse"].exists)

        composer.tap()
        let collapsedFocus = expectation(
            for: NSPredicate(format: "hasKeyboardFocus == true"),
            evaluatedWith: composer
        )
        wait(for: [collapsedFocus], timeout: 5)
        expand.tap()

        let fullscreen = app.descendants(matching: .any)[
            "chat-composer-fullscreen"
        ]
        let collapse = app.buttons["chat-composer-collapse"]
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 5))
        XCTAssertTrue(collapse.waitForExistence(timeout: 5))
        let collapseReady = expectation(
            for: NSPredicate(format: "isHittable == true"),
            evaluatedWith: collapse
        )
        wait(for: [collapseReady], timeout: 5)
        XCTAssertTrue(expand.waitForNonExistence(timeout: 2))
        XCTAssertEqual(collapse.label, "입력창 축소")
        XCTAssertEqual(collapse.frame.width, 44, accuracy: 1)
        XCTAssertEqual(collapse.frame.height, 44, accuracy: 1)
        XCTAssertGreaterThan(
            collapse.frame.midX,
            app.windows.firstMatch.frame.midX
        )
        XCTAssertLessThanOrEqual(
            app.windows.firstMatch.frame.maxX - collapse.frame.maxX,
            24
        )
        XCTAssertLessThan(collapse.frame.minY, 100)

        composer = app.descendants(matching: .any)[
            "chat-composer-field"
        ]
        let fullscreenSurface = app.descendants(matching: .any)[
            "chat-composer-surface"
        ]
        let fullscreenSend = app.buttons["메시지 보내기"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(fullscreenSurface.waitForExistence(timeout: 5))
        XCTAssertTrue(fullscreenSend.waitForExistence(timeout: 5))
        XCTAssertEqual(
            fullscreenSend.frame.width,
            collapse.frame.width,
            accuracy: 1
        )
        XCTAssertEqual(
            fullscreenSend.frame.height,
            collapse.frame.height,
            accuracy: 1
        )
        XCTAssertEqual(
            fullscreenSend.frame.midX,
            collapse.frame.midX,
            accuracy: 1
        )
        XCTAssertEqual(
            app.windows.firstMatch.frame.maxX - fullscreenSend.frame.maxX,
            app.windows.firstMatch.frame.maxX - collapse.frame.maxX,
            accuracy: 1
        )
        let fullscreenFocus = expectation(
            for: NSPredicate(format: "hasKeyboardFocus == true"),
            evaluatedWith: composer
        )
        wait(for: [fullscreenFocus], timeout: 5)
        XCTAssertEqual(composer.value as? String, sixLines)
        XCTAssertTrue(fullscreenSend.isEnabled)
        XCTAssertFalse(app.buttons["chat-composer-tools"].exists)
        XCTAssertFalse(app.buttons["chat-composer-model"].exists)
        XCTAssertFalse(app.buttons["chat-composer-mode"].exists)
        XCTAssertFalse(app.buttons["chat-composer-edit-cancel"].exists)
        XCTAssertFalse(
            app.staticTexts["chat-composer-edit-status"].exists
        )
        XCTAssertFalse(app.navigationBars.firstMatch.isHittable)
        XCTAssertGreaterThanOrEqual(
            composer.frame.minY,
            collapse.frame.maxY - 4
        )
        XCTAssertEqual(
            composer.frame.maxY,
            fullscreenSend.frame.minY,
            accuracy: 4
        )
        XCTAssertGreaterThan(
            composer.frame.height,
            fullscreenSurface.frame.height
                - collapse.frame.height
                - fullscreenSend.frame.height
                - 40
        )
        XCTAssertLessThanOrEqual(
            fullscreenSurface.frame.maxY - fullscreenSend.frame.maxY,
            24
        )

        composer.typeText(" 확장 유지")
        XCTAssertTrue(
            String(describing: composer.value).contains("확장 유지")
        )
        collapse.tap()
        XCTAssertTrue(fullscreen.waitForNonExistence(timeout: 5))
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        XCTAssertTrue(collapse.waitForNonExistence(timeout: 2))
        composer = app.descendants(matching: .any)[
            "chat-composer-field"
        ]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let restoredFocus = expectation(
            for: NSPredicate(format: "hasKeyboardFocus == true"),
            evaluatedWith: composer
        )
        wait(for: [restoredFocus], timeout: 5)
        XCTAssertTrue(
            String(describing: composer.value).contains("확장 유지")
        )

        app.terminate()

        let wrappedDraft = String(
            repeating: "자동 줄바꿈으로 다섯 줄을 넘는 문장 ",
            count: 12
        )
        app.launchEnvironment["LOREPIA_UI_TEST_CHAT_DRAFT"] = wrappedDraft
        app.launch()

        guard openPreviewChat(in: app) else {
            return
        }

        composer = app.descendants(matching: .any)[
            "chat-composer-field"
        ]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let restoredWrappedDraft = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value == %@",
                wrappedDraft
            ),
            object: composer
        )
        wait(for: [restoredWrappedDraft], timeout: 5)
        XCTAssertTrue(
            app.buttons["chat-composer-expand"]
                .waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testInlineMessageEditorUsesFullscreenExpansion() {
        let app = XCUIApplication()
        app.launchArguments = ["--lorepia-native-navigation-ui-test"]
        let longDraft =
            "편집 확대 첫째 줄\n둘째 줄\n셋째 줄\n넷째 줄\n다섯째 줄\n여섯째 줄"
        app.launchEnvironment["LOREPIA_UI_TEST_CHAT_DRAFT"] = longDraft
        app.launch()

        guard openPreviewChat(in: app) else {
            return
        }

        let composer = app.descendants(matching: .any)[
            "chat-composer-field"
        ]
        let send = app.buttons["메시지 보내기"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(send.waitForExistence(timeout: 5))

        let restoredDraft = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value == %@",
                longDraft
            ),
            object: composer
        )
        wait(for: [restoredDraft], timeout: 5)
        XCTAssertTrue(send.isEnabled)
        send.tap()

        let userMessage = app.descendants(matching: .any).matching(
            NSPredicate(
                format:
                    "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "chat-message-user-",
                "편집 확대 첫째 줄"
            )
        ).firstMatch
        XCTAssertTrue(userMessage.waitForExistence(timeout: 5))
        app.windows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)
        ).tap()
        XCTAssertTrue(userMessage.isHittable)
        userMessage.press(forDuration: 0.6)

        let edit = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "chat-message-action-edit-user-"
            )
        ).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()

        let composerSurface = app.descendants(matching: .any)[
            "chat-composer-surface"
        ]
        let editCancel = app.buttons["chat-composer-edit-cancel"]
        let editSave = app.buttons["chat-composer-edit-save"]
        let editExpand = app.buttons["chat-composer-edit-expand"]
        XCTAssertTrue(composerSurface.waitForExistence(timeout: 5))
        XCTAssertTrue(editCancel.waitForExistence(timeout: 5))
        XCTAssertTrue(editSave.waitForExistence(timeout: 5))
        XCTAssertTrue(editExpand.waitForExistence(timeout: 5))
        XCTAssertEqual(
            composerSurface.value as? String,
            "메시지 편집 중"
        )
        composer.tap()
        let editFocus = expectation(
            for: NSPredicate(format: "hasKeyboardFocus == true"),
            evaluatedWith: composer
        )
        wait(for: [editFocus], timeout: 5)

        editExpand.tap()

        let fullscreen = app.descendants(matching: .any)[
            "chat-composer-fullscreen"
        ]
        let editCollapse = app.buttons["chat-composer-edit-collapse"]
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 5))
        XCTAssertTrue(editCollapse.waitForExistence(timeout: 5))
        let editCollapseReady = expectation(
            for: NSPredicate(format: "isHittable == true"),
            evaluatedWith: editCollapse
        )
        wait(for: [editCollapseReady], timeout: 5)
        XCTAssertTrue(editExpand.waitForNonExistence(timeout: 2))
        XCTAssertEqual(editCollapse.label, "편집창 축소")
        XCTAssertEqual(editCollapse.frame.width, 44, accuracy: 1)
        XCTAssertEqual(editCollapse.frame.height, 44, accuracy: 1)
        XCTAssertGreaterThan(
            editCollapse.frame.midX,
            app.windows.firstMatch.frame.midX
        )
        XCTAssertLessThanOrEqual(
            app.windows.firstMatch.frame.maxX - editCollapse.frame.maxX,
            24
        )

        let fullscreenField = app.descendants(matching: .any)[
            "chat-composer-field"
        ]
        let fullscreenSurface = app.descendants(matching: .any)[
            "chat-composer-surface"
        ]
        XCTAssertTrue(fullscreenField.waitForExistence(timeout: 5))
        XCTAssertTrue(fullscreenSurface.waitForExistence(timeout: 5))
        let fullscreenEditFocus = expectation(
            for: NSPredicate(format: "hasKeyboardFocus == true"),
            evaluatedWith: fullscreenField
        )
        wait(for: [fullscreenEditFocus], timeout: 5)
        XCTAssertEqual(
            fullscreenSurface.value as? String,
            "메시지 편집 중"
        )
        XCTAssertTrue(
            String(describing: fullscreenField.value).contains(
                "편집 확대 첫째 줄"
            )
        )
        XCTAssertTrue(app.buttons["chat-composer-edit-save"].exists)
        XCTAssertFalse(app.buttons["chat-composer-edit-cancel"].exists)
        XCTAssertFalse(
            app.staticTexts["chat-composer-edit-status"].exists
        )
        XCTAssertFalse(app.buttons["chat-composer-tools"].exists)
        XCTAssertFalse(app.buttons["chat-composer-model"].exists)
        XCTAssertFalse(app.buttons["chat-composer-mode"].exists)
        XCTAssertFalse(app.navigationBars.firstMatch.isHittable)
        XCTAssertFalse(userMessage.isHittable)

        // The full-screen native editor receives focus without another tap.
        fullscreenField.typeText(" 포커스 유지")
        XCTAssertTrue(
            String(describing: fullscreenField.value).contains(
                "포커스 유지"
            )
        )

        editCollapse.tap()
        XCTAssertTrue(fullscreen.waitForNonExistence(timeout: 5))
        XCTAssertTrue(editExpand.waitForExistence(timeout: 5))
        XCTAssertTrue(editCollapse.waitForNonExistence(timeout: 2))

        let collapsedField = app.descendants(matching: .any)[
            "chat-composer-field"
        ]
        let collapsedSurface = app.descendants(matching: .any)[
            "chat-composer-surface"
        ]
        let collapsedEditSave = app.buttons["chat-composer-edit-save"]
        XCTAssertTrue(collapsedField.waitForExistence(timeout: 5))
        XCTAssertTrue(collapsedSurface.waitForExistence(timeout: 5))
        XCTAssertTrue(editCancel.waitForExistence(timeout: 5))
        XCTAssertTrue(collapsedEditSave.waitForExistence(timeout: 5))
        let collapsedEditFocus = expectation(
            for: NSPredicate(format: "hasKeyboardFocus == true"),
            evaluatedWith: collapsedField
        )
        wait(for: [collapsedEditFocus], timeout: 5)
        XCTAssertEqual(
            collapsedSurface.value as? String,
            "메시지 편집 중"
        )
        XCTAssertTrue(
            String(describing: collapsedField.value).contains(
                "포커스 유지"
            )
        )
        XCTAssertTrue(collapsedEditSave.isEnabled)

        collapsedEditSave.tap()
        XCTAssertTrue(collapsedEditSave.waitForNonExistence(timeout: 5))
        XCTAssertEqual(collapsedSurface.value as? String, "입력 준비")

        let editedMessage = app.descendants(matching: .any).matching(
            NSPredicate(
                format:
                    "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "chat-message-user-",
                "포커스 유지"
            )
        ).firstMatch
        XCTAssertTrue(editedMessage.waitForExistence(timeout: 10))
    }
}
