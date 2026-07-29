import SwiftUI

/// The day marker in the transcript, and the control that opens the picker.
///
/// It names the day outright and carries a chevron, so it reads as somewhere
/// to go rather than as a label the reader cannot act on.
/// The day marker's shell: one capsule shared by the separator in the
/// transcript and the floating marker that rides the scroll.
///
/// Proportions follow the reference chat app, scaled to our body text: a
/// 24pt-tall capsule around 15pt text, with 11pt of breathing room each side.
struct ChatDayCapsule: View {
    let text: String
    var showsChevron = false
    /// Set while the capsule floats over the transcript. It wears the reply's
    /// fill, so passing over a reply would otherwise punch a hole in it.
    var isElevated = false

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        HStack(spacing: 3) {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 11)
        // The reference pads 8px around 20px glyphs; against SwiftUI's taller
        // line box that lands at 3pt for the same 24pt capsule.
        .padding(.vertical, 3)
        .background(fill, in: Capsule())
        .shadow(
            color: .black.opacity(isElevated ? 0.16 : 0),
            radius: isElevated ? 7 : 0,
            y: isElevated ? 2 : 0
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    /// The reply's own fill: the marker belongs to the transcript rather than
    /// to a layer above it, so it wears the same surface the messages do.
    private var fill: Color {
        LorepiaColor.incomingFill
    }
}

struct ChatDaySeparator: View {
    let text: String
    let accessibilityText: String
    let action: () -> Void

    var body: some View {
        // The capsule is the only tappable part; the width around it belongs
        // to the transcript, not to the control.
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            button
            Spacer(minLength: 0)
        }
    }

    private var button: some View {
        Button(action: action) {
            ChatDayCapsule(text: text, showsChevron: true)
                // The capsule stays visually 24pt tall. Its transparent
                // wrapper supplies the 10pt top and bottom breathing room and
                // makes the whole 44pt row tappable.
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("대화가 오간 날짜를 골라 이동합니다")
        .accessibilityIdentifier("chat-day-separator")
    }
}

/// Where a day's separator currently sits inside the scroll viewport.
///
/// The floating marker reads these to tell which day the top of the screen has
/// entered, without every message having to report its own frame.
struct ChatDayMarker: Equatable {
    let day: Date
    let label: String
    let minY: CGFloat
}

struct ChatDayMarkerPreferenceKey: PreferenceKey {
    static let defaultValue: [ChatDayMarker] = []

    static func reduce(
        value: inout [ChatDayMarker],
        nextValue: () -> [ChatDayMarker]
    ) {
        value.append(contentsOf: nextValue())
    }
}

/// The day the picker opens on: the separator the reader tapped.
struct ChatDayPickerAnchor: Identifiable, Equatable {
    let day: Date

    var id: Date {
        day
    }
}

/// A month grid limited to the days this conversation actually has messages on.
///
/// `DatePicker` can only bound a contiguous range, and a conversation's days
/// are a scattered set, so the grid is drawn here instead.
struct ChatDayPickerSheet: View {
    let availableDays: [Date]
    let selectedDay: Date?
    let calendar: Calendar
    let locale: Locale
    let onSelect: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var visibleMonth: Date

    init(
        availableDays: [Date],
        selectedDay: Date?,
        calendar: Calendar,
        locale: Locale,
        onSelect: @escaping (Date) -> Void
    ) {
        self.availableDays = availableDays
        self.selectedDay = selectedDay
        self.calendar = calendar
        self.locale = locale
        self.onSelect = onSelect

        let anchor = selectedDay ?? availableDays.last ?? Date()
        _visibleMonth = State(
            initialValue: calendar.dateInterval(
                of: .month,
                for: anchor
            )?.start ?? anchor
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: LorepiaSpacing.standard) {
                header

                HStack(spacing: 0) {
                    ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) {
                        _, symbol in
                        Text(symbol)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }

                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 2),
                        count: 7
                    ),
                    spacing: 2
                ) {
                    ForEach(Array(monthSlots.enumerated()), id: \.offset) {
                        _, day in
                        if let day {
                            dayCell(day)
                        } else {
                            Color.clear.frame(height: 44)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(LorepiaSpacing.standard)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Without an opaque surface the transcript reads through the
            // sheet and competes with the grid.
            .background(LorepiaColor.paper.ignoresSafeArea())
            .navigationTitle("날짜로 이동")
            .chatDayPickerTitleDisplayMode()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") {
                        dismiss()
                    }
                }
            }
        }
        .chatDayPickerPresentation()
        .accessibilityIdentifier("chat-day-picker")
    }

    private var header: some View {
        HStack {
            Button {
                step(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!canStep(by: -1))
            .accessibilityLabel("이전 달")

            Text(monthTitle)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("chat-day-picker-month")

            Button {
                step(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!canStep(by: 1))
            .accessibilityLabel("다음 달")
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isAvailable = availableDaySet.contains(day)
        let isSelected = selectedDay.map {
            calendar.isDate($0, inSameDayAs: day)
        } ?? false

        return Button {
            onSelect(day)
            dismiss()
        } label: {
            Text(dayNumber(day))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(
                    isSelected
                        ? Color.white
                        : (isAvailable ? Color.primary : Color.secondary)
                )
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background {
                    if isSelected {
                        Circle().fill(LorepiaColor.loreFill)
                    } else if isAvailable {
                        Circle().fill(LorepiaColor.thread.opacity(0.16))
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        // A day with nothing on it is dimmed rather than hidden, so the month
        // keeps its shape and the active days stay easy to find.
        .opacity(isAvailable ? 1 : 0.35)
        .accessibilityLabel(accessibilityLabel(for: day))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var availableDaySet: Set<Date> {
        Set(availableDays)
    }

    private var localizedCalendar: Calendar {
        var localized = calendar
        localized.locale = locale
        return localized
    }

    private var weekdaySymbols: [String] {
        let symbols = localizedCalendar.veryShortWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        guard shift > 0, shift < symbols.count else {
            return symbols
        }
        return Array(symbols[shift...] + symbols[..<shift])
    }

    /// The visible month's days, padded with empty leading and trailing slots
    /// so every row holds a full week.
    private var monthSlots: [Date?] {
        guard
            let interval = calendar.dateInterval(of: .month, for: visibleMonth),
            let dayCount = calendar.range(
                of: .day,
                in: .month,
                for: visibleMonth
            )?.count
        else {
            return []
        }

        let weekday = calendar.component(.weekday, from: interval.start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        var slots: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0 ..< dayCount {
            slots.append(
                calendar.date(byAdding: .day, value: offset, to: interval.start)
            )
        }
        while slots.count % 7 != 0 {
            slots.append(nil)
        }
        return slots
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        return formatter.string(from: visibleMonth)
    }

    private func dayNumber(_ day: Date) -> String {
        String(calendar.component(.day, from: day))
    }

    private func accessibilityLabel(for day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        let label = formatter.string(from: day)
        return availableDaySet.contains(day)
            ? label
            : "\(label), 대화 없음"
    }

    private func step(by months: Int) {
        guard
            let next = calendar.date(
                byAdding: .month,
                value: months,
                to: visibleMonth
            )
        else {
            return
        }
        visibleMonth = next
    }

    /// Stepping stops at the months the conversation spans; there is nothing
    /// to find beyond them.
    private func canStep(by months: Int) -> Bool {
        guard
            let first = availableDays.first,
            let last = availableDays.last,
            let candidate = calendar.date(
                byAdding: .month,
                value: months,
                to: visibleMonth
            )
        else {
            return false
        }
        if months < 0 {
            return candidate >= calendar.dateInterval(
                of: .month,
                for: first
            )?.start ?? first
        }
        return candidate <= calendar.dateInterval(
            of: .month,
            for: last
        )?.start ?? last
    }
}

private extension View {
    @ViewBuilder
    func chatDayPickerTitleDisplayMode() -> some View {
#if os(iOS)
        navigationBarTitleDisplayMode(.inline)
#else
        self
#endif
    }

    @ViewBuilder
    func chatDayPickerPresentation() -> some View {
#if os(iOS)
        presentationDetents([.medium])
            .presentationDragIndicator(.visible)
#else
        frame(minWidth: 320, minHeight: 380)
#endif
    }
}
