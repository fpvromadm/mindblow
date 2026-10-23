import XCTest
@testable import MindBlow

/// Due dates are calendar *days*, but they are stored as instants. Picking a
/// day used to store local midnight, which lands within a few hours of the day
/// boundary — so any time-zone change (travel, a system update, a stale
/// snapshot of `Calendar.current` inside a long-running app) rendered the date
/// as the day before. These tests pin the day down.
final class DueDateTests: XCTestCase {
    private var savedZone: TimeZone!

    override func setUp() {
        super.setUp()
        savedZone = NSTimeZone.default
    }

    override func tearDown() {
        NSTimeZone.default = savedZone
        super.tearDown()
    }

    private func calendar(_ identifier: String) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: identifier)!
        return cal
    }

    private func day(_ y: Int, _ m: Int, _ d: Int, in cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// The reported bug: the picker ran on a UTC+4 calendar, the label
    /// formatter on UTC+3, and "5 Aug" came out as "Tue, 4 Aug".
    func testPickedDayKeepsItsDayWhenTheZoneShiftsWest() {
        let picker = calendar("Asia/Dubai")          // UTC+4, what the grid used
        let picked = DueDay.canonical(day(2026, 8, 5, in: picker), in: picker)

        NSTimeZone.default = TimeZone(identifier: "Europe/Moscow")!  // UTC+3
        XCTAssertEqual(Metrics.dueLongString(picked), "Wed, 5 Aug")
        XCTAssertEqual(Metrics.dueString(picked), "5 Aug")
    }

    /// Same map opened from a zone to the east: still the picked day.
    func testPickedDayKeepsItsDayWhenTheZoneShiftsEast() {
        let picker = calendar("Europe/Lisbon")        // UTC+1
        let picked = DueDay.canonical(day(2026, 8, 5, in: picker), in: picker)

        NSTimeZone.default = TimeZone(identifier: "Asia/Tokyo")!     // UTC+9
        XCTAssertEqual(Metrics.dueString(picked), "5 Aug")
    }

    /// The guarantee midday buys, stated exactly: a due date survives any shift
    /// of up to 11 hours either way between the zone that picked it and the one
    /// that reads it. Beyond ±12h an instant simply cannot carry a day — that
    /// would need a day-valued field in the file format.
    func testPickedDaySurvivesElevenHoursOfShiftInEitherDirection() {
        let picker = calendar("UTC")
        let picked = DueDay.canonical(day(2026, 8, 5, in: picker), in: picker)

        for offsetHours in -11...11 {
            NSTimeZone.default = TimeZone(secondsFromGMT: offsetHours * 3600)!
            XCTAssertEqual(Metrics.dueString(picked), "5 Aug",
                           "drifted at UTC\(offsetHours >= 0 ? "+" : "")\(offsetHours)")
        }
    }

    /// Canonical form is midday, the furthest point from either boundary.
    func testCanonicalIsMiddayOfThePickedDay() {
        let cal = calendar("Europe/Moscow")
        let canonical = DueDay.canonical(day(2026, 8, 5, in: cal), in: cal)
        XCTAssertEqual(cal.component(.day, from: canonical), 5)
        XCTAssertEqual(cal.component(.hour, from: canonical), 12)
        XCTAssertEqual(cal.component(.minute, from: canonical), 0)
    }

    /// Re-picking the same day must not walk the date forward.
    func testCanonicalIsIdempotent() {
        let cal = calendar("Europe/Moscow")
        let once = DueDay.canonical(day(2026, 8, 5, in: cal), in: cal)
        XCTAssertEqual(DueDay.canonical(once, in: cal), once)
    }

    /// A day picked at any hour canonicalises to that same day.
    func testCanonicalKeepsTheDayOfAnyTimeOfDay() {
        let cal = calendar("Europe/Moscow")
        let start = day(2026, 8, 5, in: cal)
        for hour in 0..<24 {
            let stamped = start.addingTimeInterval(TimeInterval(hour) * 3600)
            XCTAssertEqual(cal.component(.day, from: DueDay.canonical(stamped, in: cal)), 5,
                           "hour \(hour) drifted off 5 Aug")
        }
    }

    /// Overdue/today classification still works on midday values.
    func testMiddayValuesClassifyAsTodayAndOverdue() {
        let cal = Calendar.current
        let today = DueDay.canonical(Date(), in: cal)
        XCTAssertTrue(DayClock.isToday(today))
        XCTAssertFalse(DayClock.isOverdue(today))

        let yesterday = DueDay.canonical(cal.date(byAdding: .day, value: -1, to: Date())!, in: cal)
        XCTAssertTrue(DayClock.isOverdue(yesterday))

        let tomorrow = DueDay.canonical(cal.date(byAdding: .day, value: 1, to: Date())!, in: cal)
        XCTAssertFalse(DayClock.isOverdue(tomorrow))
        XCTAssertFalse(DayClock.isToday(tomorrow))
    }
}
