import Foundation

enum ChatTimeline {
    enum SeparatorKind: Equatable {
        case fullDateAndTime
        case timeOnly
    }

    static let groupingInterval: TimeInterval = 5 * 60
    static let separatorInterval: TimeInterval = 60 * 60

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

    static func separatorKind(
        before message: ChatMessage,
        after previous: ChatMessage?,
        calendar: Calendar = .autoupdatingCurrent
    ) -> SeparatorKind? {
        guard let messageDate = date(from: message.createdAt) else {
            return nil
        }
        guard let previous else {
            return .fullDateAndTime
        }
        guard let previousDate = date(from: previous.createdAt) else {
            return .fullDateAndTime
        }

        let elapsed = messageDate.timeIntervalSince(previousDate)
        if elapsed < 0
            || !calendar.isDate(messageDate, inSameDayAs: previousDate)
        {
            return .fullDateAndTime
        }
        if elapsed >= separatorInterval {
            return .timeOnly
        }
        return nil
    }

    static func separatorText(
        for message: ChatMessage,
        kind: SeparatorKind,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String? {
        guard let date = date(from: message.createdAt) else {
            return nil
        }

        switch kind {
        case .fullDateAndTime:
            return formattedDateAndTime(
                date,
                calendar: calendar,
                locale: locale
            )
        case .timeOnly:
            return formattedTime(
                date,
                calendar: calendar,
                locale: locale
            )
        }
    }

    static func accessibilityText(
        for message: ChatMessage,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String? {
        guard let date = date(from: message.createdAt) else {
            return nil
        }
        return formattedDateAndTime(
            date,
            calendar: calendar,
            locale: locale
        )
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

    private static func formattedDateAndTime(
        _ date: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }

    private static func formattedTime(
        _ date: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}
