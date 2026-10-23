import SwiftUI

/// Custom due-date calendar from the design spec (pop-ups, 1b): month title
/// with paging chevrons, single-letter weekday row, blue rounded selected
/// day, amber "today", faded adjacent-month days, and a tinted red
/// "Remove due date" row at the bottom.
struct DueDateCalendar: View {
    var selection: Date?
    var onSelect: (Date) -> Void
    /// Shown as the bottom remove row when non-nil and a date is set.
    var onRemove: (() -> Void)?

    @State private var displayedMonth: Date

    /// Autoupdating, never a snapshot: a `static let Calendar.current` freezes
    /// the time zone at first use, so a machine that changes zone while the app
    /// is open kept building the grid on the old offset while every
    /// `DateFormatter` had already moved to the new one — the grid said 5 Aug
    /// and the label said 4 Aug.
    private static var cal: Calendar { .autoupdatingCurrent }

    init(selection: Date?, onSelect: @escaping (Date) -> Void, onRemove: (() -> Void)? = nil) {
        self.selection = selection
        self.onSelect = onSelect
        self.onRemove = onRemove
        let base = selection ?? Date()
        _displayedMonth = State(initialValue: Self.cal.dateInterval(of: .month, for: base)?.start ?? base)
    }

    // Spec colors (#9AA3B4, #3A465A, #C2C9D4, #DD8A09) with dark variants.
    private let subdued = Color(light: NSColor(red: 0.604, green: 0.639, blue: 0.706, alpha: 1),
                                dark: NSColor(white: 0.58, alpha: 1))
    private let dayText = Color(light: NSColor(red: 0.227, green: 0.275, blue: 0.353, alpha: 1),
                                dark: NSColor(white: 0.88, alpha: 1))
    private let faded = Color(light: NSColor(red: 0.761, green: 0.788, blue: 0.831, alpha: 1),
                              dark: NSColor(white: 0.34, alpha: 1))
    private let amber = Color(light: NSColor(red: 0.867, green: 0.541, blue: 0.035, alpha: 1),
                              dark: NSColor(red: 0.96, green: 0.65, blue: 0.14, alpha: 1))

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "LLLL yyyy"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            weekdayRow
                .padding(.bottom, 6)
            dayGrid
            if let onRemove, selection != nil {
                Button(action: onRemove) {
                    HStack(spacing: 6) {
                        Image(systemName: "trash").font(.system(size: 11, weight: .semibold))
                        Text("Remove due date").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Chrome.redText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Chrome.redBg))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.chip)
                .padding(.top, 14)
            }
        }
        .padding(18)
        .frame(width: 268)
        .onChange(of: selection) { _, new in
            guard let new else { return }
            displayedMonth = Self.cal.dateInterval(of: .month, for: new)?.start ?? new
        }
    }

    private var header: some View {
        HStack {
            Text(Self.monthFormatter.string(from: displayedMonth))
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Chrome.text)
            Spacer()
            HStack(spacing: 6) {
                pageButton("chevron.left", by: -1)
                pageButton("chevron.right", by: 1)
            }
        }
        .padding(.bottom, 14)
    }

    private func pageButton(_ systemName: String, by months: Int) -> some View {
        Button {
            if let next = Self.cal.date(byAdding: .month, value: months, to: displayedMonth) {
                displayedMonth = next
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(subdued)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.nodeBadge)
    }

    /// Weekday letters in the user's calendar order (spec shows one letter
    /// per column).
    private var weekdaySymbols: [String] {
        let symbols = Self.cal.veryShortStandaloneWeekdaySymbols
        let first = Self.cal.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var weekdayRow: some View {
        HStack(spacing: 2) {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(subdued)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// 6 fixed weeks starting at the first weekday on or before the 1st —
    /// always shows leading/trailing adjacent-month days like the spec.
    private var gridDays: [Date] {
        let weekday = Self.cal.component(.weekday, from: displayedMonth)
        let lead = (weekday - Self.cal.firstWeekday + 7) % 7
        guard let start = Self.cal.date(byAdding: .day, value: -lead, to: displayedMonth) else { return [] }
        return (0..<42).compactMap { Self.cal.date(byAdding: .day, value: $0, to: start) }
    }

    private var dayGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7),
                  spacing: 2) {
            ForEach(gridDays, id: \.self) { day in
                dayCell(day)
            }
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let inMonth = Self.cal.isDate(date, equalTo: displayedMonth, toGranularity: .month)
        let isSelected = selection.map { Self.cal.isDate($0, inSameDayAs: date) } ?? false
        let isToday = Self.cal.isDateInToday(date)
        return Button {
            onSelect(DueDay.canonical(date, in: Self.cal))
        } label: {
            Text("\(Self.cal.component(.day, from: date))")
                .font(.system(size: 12, weight: isSelected || (isToday && inMonth) ? .bold : .medium))
                .foregroundStyle(isSelected ? .white
                                 : !inMonth ? faded
                                 : isToday ? amber : dayText)
                .frame(maxWidth: .infinity)
                .frame(height: 25)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Palette.selection)
                            .padding(.horizontal, 3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.panel)
    }
}
