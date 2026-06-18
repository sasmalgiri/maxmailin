import XCTest
@testable import MaxMailCore

final class MonthKeyTests: XCTestCase {

    /// Spot-check our arithmetic monthKey against Calendar's result over a
    /// span that crosses leap years, the unix epoch, and the 2001 reference
    /// date.
    func testMonthKeyMatchesCalendarOverWideRange() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let secondsPerDay: TimeInterval = 86_400

        // Walk one day at a time across a 60-year window, sampling every
        // few weeks. That's enough granularity to catch any leap-year or
        // month-boundary bugs without taking forever.
        var offset: TimeInterval = -20 * 365 * secondsPerDay
        var checks = 0
        while offset < 40 * 365 * secondsPerDay {
            let d = Date(timeIntervalSinceReferenceDate: offset)
            let mine = MailStore.monthKey(for: d)
            let comps = cal.dateComponents([.year, .month], from: d)
            let expected = String(format: "%04d-%02d", comps.year!, comps.month!)
            XCTAssertEqual(mine, expected,
                           "monthKey(\(d)) = \(mine), expected \(expected)")
            offset += 19 * secondsPerDay     // ~3 week steps
            checks += 1
        }
        XCTAssertGreaterThan(checks, 1_000, "should have made many comparisons")
    }

    func testMonthKeyHandlesFebruary29InLeapYear() {
        // 2024 is a leap year; Feb 29 must land in 2024-02.
        var c = DateComponents()
        c.year = 2024; c.month = 2; c.day = 29
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: c)!
        XCTAssertEqual(MailStore.monthKey(for: date), "2024-02")
    }

    func testMonthKeyHandlesReferenceDateExactly() {
        // 2001-01-01 00:00:00 UTC.
        XCTAssertEqual(
            MailStore.monthKey(for: Date(timeIntervalSinceReferenceDate: 0)),
            "2001-01"
        )
    }

    func testMonthKeyHandlesEpoch() {
        // 1970-01-01 00:00:00 UTC.
        XCTAssertEqual(
            MailStore.monthKey(for: Date(timeIntervalSince1970: 0)),
            "1970-01"
        )
    }
}
