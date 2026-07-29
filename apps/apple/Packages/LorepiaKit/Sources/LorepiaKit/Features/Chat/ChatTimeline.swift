import Foundation

enum ChatTimeline {
    static let groupingInterval: TimeInterval = 5 * 60

    static func canGroup(
        previous: ChatMessage?,
        current: ChatMessage?,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        guard
            let previous,
            let current,
            previous.role == current.role,
            current.role == .user || current.role == .assistant,
            let previousDate = date(from: previous.createdAt),
            let currentDate = date(from: current.createdAt)
        else {
            return false
        }

        let elapsed = currentDate.timeIntervalSince(previousDate)
        return elapsed >= 0
            && elapsed <= groupingInterval
            && calendar.isDate(currentDate, inSameDayAs: previousDate)
    }

    /// Only a change of day earns a separator.
    ///
    /// Every settled bubble carries its own send time, so an hourly time
    /// separator would just repeat the stamp sitting right below it.
    static func needsDateSeparator(
        before message: ChatMessage,
        after previous: ChatMessage?,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        guard let messageDate = date(from: message.createdAt) else {
            return false
        }
        guard
            let previous,
            let previousDate = date(from: previous.createdAt)
        else {
            return true
        }

        return !calendar.isDate(messageDate, inSameDayAs: previousDate)
    }

    static func separatorText(
        for message: ChatMessage,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        now: Date = Date()
    ) -> String? {
        guard let date = date(from: message.createdAt) else {
            return nil
        }
        return dayLabel(
            for: date,
            calendar: calendar,
            locale: locale,
            now: now
        )
    }

    /// The day a marker names. The year is only worth the width when the
    /// conversation reaches back past this one.
    static func dayLabel(
        for date: Date,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        now: Date = Date()
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let isThisYear = calendar.component(.year, from: date)
            == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(
            isThisYear ? "MMMMd" : "yMMMMd"
        )
        return formatter.string(from: date)
    }

    /// The local days this conversation has messages on, oldest first.
    ///
    /// The date picker offers exactly these, so a day the conversation never
    /// touched is never a place the reader can land.
    static func messageDays(
        in messages: [ChatMessage],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [Date] {
        var seen: Set<Date> = []
        var days: [Date] = []
        for message in messages {
            guard let date = date(from: message.createdAt) else {
                continue
            }
            let day = calendar.startOfDay(for: date)
            if seen.insert(day).inserted {
                days.append(day)
            }
        }
        return days.sorted()
    }

    /// Which day marker names the day the top of the viewport has entered.
    ///
    /// Markers are given as their vertical offsets inside the viewport. Only
    /// a marker that has crossed the top edge names the day on screen: a
    /// marker still below the edge starts the *next* day, so the top belongs
    /// to the day before it and the caller has to name that one instead.
    static func enteredMarkerIndex(
        markerOffsets: [CGFloat],
        threshold: CGFloat = 8
    ) -> Int? {
        markerOffsets.enumerated()
            .filter { $0.element <= threshold }
            .max { $0.element < $1.element }?
            .offset
    }

    /// The day before `day` in this conversation, if it has one.
    static func dayBefore(
        _ day: Date,
        in messages: [ChatMessage],
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date? {
        let days = messageDays(in: messages, calendar: calendar)
        guard let index = days.firstIndex(of: day), index > 0 else {
            return nil
        }
        return days[index - 1]
    }

    /// The message a jump to `day` should land on: the first one sent that day.
    static func firstMessageID(
        on day: Date,
        in messages: [ChatMessage],
        calendar: Calendar = .autoupdatingCurrent
    ) -> String? {
        messages.first { message in
            guard let date = date(from: message.createdAt) else {
                return false
            }
            return calendar.isDate(date, inSameDayAs: day)
        }?.id
    }

    /// What the day marker is called out loud.
    ///
    /// The capsule drops this year to save width; spoken aloud there is no
    /// width to save and no neighbouring marker to infer the year from.
    static func accessibilityText(
        for message: ChatMessage,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String? {
        guard let date = date(from: message.createdAt) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("yMMMMd")
        return formatter.string(from: date)
    }

    static func date(from timestamp: String?) -> Date? {
        guard let timestamp, !timestamp.isEmpty else {
            return nil
        }

        if let date = try? Date.ISO8601FormatStyle(
            includingFractionalSeconds: true
        ).parse(timestamp) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(timestamp)
    }

}
