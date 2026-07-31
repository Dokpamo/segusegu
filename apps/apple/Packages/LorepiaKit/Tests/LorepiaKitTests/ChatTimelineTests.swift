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
        XCTAssertTrue(
            ChatTimeline.needsDateSeparator(
                before: backwards,
                after: first,
                calendar: utcCalendar
            )
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

    func testLocalMidnightStartsADateSeparatorAndBreaksGrouping() {
        let beforeMidnight = message(
            id: "before-midnight",
            timestamp: "2026-07-26T14:59:00Z"
        )
        let afterMidnight = message(
            id: "after-midnight",
            timestamp: "2026-07-26T15:01:00Z"
        )

        XCTAssertTrue(
            ChatTimeline.needsDateSeparator(
                before: afterMidnight,
                after: beforeMidnight,
                calendar: seoulCalendar
            )
        )
        XCTAssertFalse(
            ChatTimeline.canGroup(
                previous: beforeMidnight,
                current: afterMidnight,
                calendar: seoulCalendar
            )
        )
    }

    /// A quiet gap inside one day no longer earns a separator: the bubbles
    /// carry their own stamps, so a time-only rule would only repeat them.
    func testQuietGapWithinADayCarriesNoSeparator() {
        let first = message(
            id: "first",
            timestamp: "2026-07-26T00:00:00Z"
        )
        let hoursLater = message(
            id: "hours-later",
            timestamp: "2026-07-26T09:30:00Z"
        )

        XCTAssertTrue(
            ChatTimeline.needsDateSeparator(
                before: first,
                after: nil,
                calendar: utcCalendar
            )
        )
        XCTAssertFalse(
            ChatTimeline.needsDateSeparator(
                before: hoursLater,
                after: first,
                calendar: utcCalendar
            )
        )
    }

    func testBackwardTimestampWithinSameDayDoesNotRepeatDateSeparator() {
        let later = message(
            id: "later",
            timestamp: "2026-07-26T10:00:00Z"
        )
        let earlier = message(
            id: "earlier",
            timestamp: "2026-07-26T09:59:00Z"
        )

        XCTAssertFalse(
            ChatTimeline.needsDateSeparator(
                before: earlier,
                after: later,
                calendar: utcCalendar
            )
        )
        XCTAssertFalse(
            ChatTimeline.canGroup(
                previous: later,
                current: earlier,
                calendar: utcCalendar
            )
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
        XCTAssertFalse(
            ChatTimeline.needsDateSeparator(
                before: invalid,
                after: valid,
                calendar: utcCalendar
            )
        )
        XCTAssertTrue(
            ChatTimeline.needsDateSeparator(
                before: resumed,
                after: invalid,
                calendar: utcCalendar
            )
        )
    }

    func testSeparatorLabelsRespectInjectedLocaleAndTimeZone() {
        let timestamped = message(
            id: "localized",
            timestamp: "2026-07-26T03:30:00Z"
        )
        let locale = Locale(identifier: "ko_KR")
        // 03:30Z is 12:30 on the 26th in Seoul, so the day itself depends on
        // the injected time zone.
        let sameYear = ChatTimeline.separatorText(
            for: timestamped,
            calendar: seoulCalendar,
            locale: locale,
            now: ChatTimeline.date(from: "2026-02-01T00:00:00Z")!
        )
        let earlierYear = ChatTimeline.separatorText(
            for: timestamped,
            calendar: seoulCalendar,
            locale: locale,
            now: ChatTimeline.date(from: "2027-02-01T00:00:00Z")!
        )
        let accessibility = ChatTimeline.accessibilityText(
            for: timestamped,
            calendar: seoulCalendar,
            locale: locale
        )

        XCTAssertEqual(sameYear, "7월 26일")
        XCTAssertEqual(earlierYear, "2026년 7월 26일")
        // The visible marker carries no clock time; the bubble under it does.
        XCTAssertFalse(sameYear?.contains("12:30") == true)
        // Spoken aloud there is no neighbouring marker to infer the year from.
        XCTAssertEqual(accessibility, "2026년 7월 26일")
    }

    func testMessageDaysCollapseToLocalDaysAndDropUnstampedMessages() {
        let messages = [
            message(id: "a", timestamp: "2026-07-26T14:59:00Z"),
            message(id: "b", timestamp: "2026-07-26T15:01:00Z"),
            message(id: "c", timestamp: "2026-07-26T20:00:00Z"),
            message(id: "d", timestamp: "garbage"),
            message(id: "e", timestamp: "2026-07-24T02:00:00Z"),
        ]

        // Seoul is UTC+9, so 14:59Z and 15:01Z fall on different local days.
        let days = ChatTimeline.messageDays(
            in: messages,
            calendar: seoulCalendar
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = seoulCalendar
        formatter.timeZone = seoulCalendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        XCTAssertEqual(
            days.map { formatter.string(from: $0) },
            ["2026-07-24", "2026-07-26", "2026-07-27"]
        )
    }

    func testDayBeforeWalksTheConversationsOwnDays() {
        let messages = [
            message(id: "a", timestamp: "2026-07-24T01:00:00Z"),
            message(id: "b", timestamp: "2026-07-26T01:00:00Z"),
            message(id: "c", timestamp: "2026-07-27T01:00:00Z"),
        ]
        let days = ChatTimeline.messageDays(
            in: messages,
            calendar: utcCalendar
        )

        // Days the conversation skipped are skipped here too: the 26th's
        // predecessor is the 24th, not the 25th.
        XCTAssertEqual(
            ChatTimeline.dayBefore(
                days[1],
                in: messages,
                calendar: utcCalendar
            ),
            days[0]
        )
        // The first day has nothing above it to name.
        XCTAssertNil(
            ChatTimeline.dayBefore(
                days[0],
                in: messages,
                calendar: utcCalendar
            )
        )
    }

    func testJumpingToADayLandsOnItsFirstMessage() {
        let messages = [
            message(id: "earlier-day", timestamp: "2026-07-25T01:00:00Z"),
            message(id: "first-of-day", timestamp: "2026-07-26T01:00:00Z"),
            message(id: "later-same-day", timestamp: "2026-07-26T05:00:00Z"),
        ]
        let day = ChatTimeline.date(from: "2026-07-26T23:00:00Z")!

        XCTAssertEqual(
            ChatTimeline.firstMessageID(
                on: day,
                in: messages,
                calendar: utcCalendar
            ),
            "first-of-day"
        )
        XCTAssertNil(
            ChatTimeline.firstMessageID(
                on: ChatTimeline.date(from: "2026-07-27T01:00:00Z")!,
                in: messages,
                calendar: utcCalendar
            )
        )
    }

    func testFloatingMarkerNamesTheDayTheTopHasEntered() {
        // Offsets are viewport-relative: negative means scrolled past the top.
        XCTAssertEqual(
            ChatTimeline.enteredMarkerIndex(
                markerOffsets: [-820, -400, 260, 900]
            ),
            1
        )
        // A marker still below the edge opens the day underneath it, so the
        // top belongs to an earlier day and no marker names it.
        XCTAssertNil(
            ChatTimeline.enteredMarkerIndex(markerOffsets: [140, 900])
        )
        // A marker resting exactly on the threshold counts as entered.
        XCTAssertEqual(
            ChatTimeline.enteredMarkerIndex(
                markerOffsets: [-500, 8],
                threshold: 8
            ),
            1
        )
        XCTAssertNil(ChatTimeline.enteredMarkerIndex(markerOffsets: []))
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
