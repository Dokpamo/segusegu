import Foundation
import XCTest
@testable import LorepiaKit

@MainActor
final class ChatTimelineTests: XCTestCase {
    func testRFC3339ParserAcceptsCommonCoreVariants() {
        let utc = ChatTimeline.date(from: "2026-01-01T00:00:00Z")
        let offset = ChatTimeline.date(
            from: "2026-01-01T09:00:00+09:00"
        )

        XCTAssertNotNil(utc)
        XCTAssertNotNil(
            ChatTimeline.date(
                from: "2026-01-01T00:00:00.123456789+00:00"
            )
        )
        XCTAssertEqual(utc, offset)
        XCTAssertNil(ChatTimeline.date(from: nil))
        XCTAssertNil(ChatTimeline.date(from: ""))
        XCTAssertNil(ChatTimeline.date(from: "not-a-date"))
    }

    func testGroupingRequiresOrderedNearbyMessagesOnTheSameLocalDay() {
        let first = message(
            id: "first",
            timestamp: "2026-07-26T00:00:00Z"
        )
        let atBoundary = message(
            id: "boundary",
            timestamp: "2026-07-26T00:05:00Z"
        )
        let afterBoundary = message(
            id: "after",
            timestamp: "2026-07-26T00:05:01Z"
        )
        let backwards = message(
            id: "backwards",
            timestamp: "2026-07-25T23:59:59Z"
        )

        XCTAssertTrue(
            ChatTimeline.canGroup(
                previous: first,
                current: atBoundary,
                calendar: utcCalendar
            )
        )
        XCTAssertFalse(
            ChatTimeline.canGroup(
                previous: first,
                current: afterBoundary,
                calendar: utcCalendar
            )
        )
        XCTAssertEqual(
            ChatTimeline.separatorKind(
                before: backwards,
                after: first,
                calendar: utcCalendar
            ),
            .fullDateAndTime
        )
        XCTAssertFalse(
            ChatTimeline.canGroup(
                previous: first,
                current: backwards,
                calendar: utcCalendar
            )
        )
        XCTAssertFalse(
            ChatTimeline.canGroup(
                previous: first,
                current: message(
                    id: "assistant",
                    role: .assistant,
                    timestamp: "2026-07-26T00:01:00Z"
                ),
                calendar: utcCalendar
            )
        )
    }

    func testLocalMidnightStartsAFullSeparatorAndBreaksGrouping() {
        let beforeMidnight = message(
            id: "before-midnight",
            timestamp: "2026-07-26T14:59:00Z"
        )
        let afterMidnight = message(
            id: "after-midnight",
            timestamp: "2026-07-26T15:01:00Z"
        )

        XCTAssertEqual(
            ChatTimeline.separatorKind(
                before: afterMidnight,
                after: beforeMidnight,
                calendar: seoulCalendar
            ),
            .fullDateAndTime
        )
        XCTAssertFalse(
            ChatTimeline.canGroup(
                previous: beforeMidnight,
                current: afterMidnight,
                calendar: seoulCalendar
            )
        )
    }

    func testQuietGapSeparatorStartsAtExactlyOneHour() {
        let first = message(
            id: "first",
            timestamp: "2026-07-26T00:00:00Z"
        )
        let underHour = message(
            id: "under-hour",
            timestamp: "2026-07-26T00:59:59Z"
        )
        let atHour = message(
            id: "at-hour",
            timestamp: "2026-07-26T01:00:00Z"
        )

        XCTAssertEqual(
            ChatTimeline.separatorKind(
                before: first,
                after: nil,
                calendar: utcCalendar
            ),
            .fullDateAndTime
        )
        XCTAssertNil(
            ChatTimeline.separatorKind(
                before: underHour,
                after: first,
                calendar: utcCalendar
            )
        )
        XCTAssertEqual(
            ChatTimeline.separatorKind(
                before: atHour,
                after: first,
                calendar: utcCalendar
            ),
            .timeOnly
        )
    }

    func testInvalidTimestampStaysVisibleButBreaksTimelineContinuity() {
        let valid = message(
            id: "valid",
            timestamp: "2026-07-26T00:00:00Z"
        )
        let invalid = message(id: "invalid", timestamp: "garbage")
        let resumed = message(
            id: "resumed",
            timestamp: "2026-07-26T00:01:00Z"
        )

        XCTAssertFalse(
            ChatTimeline.canGroup(
                previous: valid,
                current: invalid,
                calendar: utcCalendar
            )
        )
        XCTAssertFalse(
            ChatTimeline.canGroup(
                previous: invalid,
                current: resumed,
                calendar: utcCalendar
            )
        )
        XCTAssertNil(
            ChatTimeline.separatorKind(
                before: invalid,
                after: valid,
                calendar: utcCalendar
            )
        )
        XCTAssertEqual(
            ChatTimeline.separatorKind(
                before: resumed,
                after: invalid,
                calendar: utcCalendar
            ),
            .fullDateAndTime
        )
    }

    func testSeparatorLabelsRespectInjectedLocaleAndTimeZone() {
        let timestamped = message(
            id: "localized",
            timestamp: "2026-07-26T03:30:00Z"
        )
        let locale = Locale(identifier: "ko_KR")
        let full = ChatTimeline.separatorText(
            for: timestamped,
            kind: .fullDateAndTime,
            calendar: seoulCalendar,
            locale: locale
        )
        let time = ChatTimeline.separatorText(
            for: timestamped,
            kind: .timeOnly,
            calendar: seoulCalendar,
            locale: locale
        )

        XCTAssertNotNil(full)
        XCTAssertNotNil(time)
        XCTAssertNotEqual(full, time)
        XCTAssertTrue(full?.contains("12:30") == true)
        XCTAssertTrue(time?.contains("12:30") == true)
        XCTAssertEqual(
            ChatTimeline.accessibilityText(
                for: timestamped,
                calendar: seoulCalendar,
                locale: locale
            ),
            full
        )
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var seoulCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    private func message(
        id: String,
        role: ChatMessage.Role = .user,
        timestamp: String?
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            role: role,
            text: id,
            createdAt: timestamp
        )
    }
}
