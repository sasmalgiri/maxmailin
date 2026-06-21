import XCTest
@testable import MaxMailCore

final class SnoozeTests: XCTestCase {

    private func tempDB() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snooze-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mail.sqlite")
    }

    private func gregorianCal(timeZone: TimeZone = TimeZone(identifier: "UTC")!) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    // MARK: - Store-level snooze filter

    func testSnoozedMessageHidesFromHeadersUntilDue() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let a = try await store.ingest(IngestMessage(
            accountID: acc, folder: "INBOX",
            messageID: "<a@x>", subject: "Visible",
            fromAddress: "alice@x",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            sizeBytes: 1, plainBody: "v"
        ))
        let b = try await store.ingest(IngestMessage(
            accountID: acc, folder: "INBOX",
            messageID: "<b@x>", subject: "Snoozed",
            fromAddress: "bob@x",
            date: Date(timeIntervalSince1970: 1_700_001_000),
            sizeBytes: 1, plainBody: "s"
        ))

        // Snooze b until well in the future.
        try await store.snoozeMessage(messageRowID: b,
                                      until: Date().addingTimeInterval(3600))
        let visible = try await store.headers(in: "INBOX", accountID: acc, limit: 50)
        XCTAssertEqual(visible.map(\.id), [a])

        // Unsnooze: b reappears.
        try await store.unsnoozeMessage(messageRowID: b)
        let restored = try await store.headers(in: "INBOX", accountID: acc, limit: 50)
        XCTAssertEqual(Set(restored.map(\.id)), [a, b])
    }

    func testDueSnoozeAppearsAgainAutomatically() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let a = try await store.ingest(IngestMessage(
            accountID: acc, folder: "INBOX",
            messageID: "<a@x>", subject: "Visible",
            fromAddress: "alice@x",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            sizeBytes: 1, plainBody: "v"
        ))
        // Snooze to a time in the past — should be reported as already
        // due and therefore visible on the next read.
        try await store.snoozeMessage(messageRowID: a,
                                      until: Date().addingTimeInterval(-3600))
        let headers = try await store.headers(in: "INBOX", accountID: acc, limit: 50)
        XCTAssertEqual(headers.map(\.id), [a])
    }

    func testSnoozeUntilReturnsTheStoredWakeTime() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let a = try await store.ingest(IngestMessage(
            accountID: acc, folder: "INBOX",
            messageID: "<a@x>", subject: "S",
            fromAddress: "alice@x",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            sizeBytes: 1, plainBody: ""
        ))
        let until = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.snoozeMessage(messageRowID: a, until: until)
        let read = try await store.snoozeUntil(messageRowID: a)
        XCTAssertEqual(read?.timeIntervalSince1970, until.timeIntervalSince1970)
    }

    func testReSnoozingOverwritesWakeTime() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let a = try await store.ingest(IngestMessage(
            accountID: acc, folder: "INBOX",
            messageID: "<a@x>", subject: "S",
            fromAddress: "alice@x",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            sizeBytes: 1, plainBody: ""
        ))
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        let second = Date(timeIntervalSince1970: 1_900_000_000)
        try await store.snoozeMessage(messageRowID: a, until: first)
        try await store.snoozeMessage(messageRowID: a, until: second)
        let stored = try await store.snoozeUntil(messageRowID: a)?.timeIntervalSince1970
        XCTAssertEqual(stored, second.timeIntervalSince1970)
    }

    // MARK: - SnoozeOption wake-time math

    func testLaterTodayAddsThreeHoursWhenWithinDay() {
        let cal = gregorianCal()
        // Friday 2026-06-20 10:00 UTC.
        let now = cal.date(from: DateComponents(
            year: 2026, month: 6, day: 20, hour: 10
        ))!
        XCTAssertEqual(
            SnoozeOption.laterToday.wakeTime(from: now, calendar: cal),
            now.addingTimeInterval(3 * 3600)
        )
    }

    func testLaterTodayClampsPast9PMToTomorrowMorning() {
        let cal = gregorianCal()
        // 8 PM + 3h = 11 PM → too late, must bounce to tomorrow 9 AM.
        let now = cal.date(from: DateComponents(
            year: 2026, month: 6, day: 20, hour: 20
        ))!
        let expected = cal.date(from: DateComponents(
            year: 2026, month: 6, day: 21, hour: 9
        ))!
        XCTAssertEqual(
            SnoozeOption.laterToday.wakeTime(from: now, calendar: cal),
            expected
        )
    }

    func testTomorrowMorningIs9AMNextDay() {
        let cal = gregorianCal()
        let now = cal.date(from: DateComponents(
            year: 2026, month: 6, day: 20, hour: 14
        ))!
        let expected = cal.date(from: DateComponents(
            year: 2026, month: 6, day: 21, hour: 9
        ))!
        XCTAssertEqual(
            SnoozeOption.tomorrowMorning.wakeTime(from: now, calendar: cal),
            expected
        )
    }

    func testThisWeekendFromTuesdayHitsTheNextSaturday() {
        let cal = gregorianCal()
        // 2026-06-16 is a Tuesday.
        let now = cal.date(from: DateComponents(
            year: 2026, month: 6, day: 16, hour: 12
        ))!
        let result = SnoozeOption.thisWeekend.wakeTime(from: now, calendar: cal)
        let comps = cal.dateComponents([.year, .month, .day, .hour, .weekday], from: result)
        XCTAssertEqual(comps.weekday, 7, "Saturday is weekday 7")
        XCTAssertEqual(comps.hour, 9)
    }

    func testThisWeekendFromSaturdayStepsToNextSaturday() {
        let cal = gregorianCal()
        // 2026-06-20 is a Saturday — "This weekend" should be the
        // following Saturday rather than today (which is already
        // weekend-time).
        let now = cal.date(from: DateComponents(
            year: 2026, month: 6, day: 20, hour: 12
        ))!
        let result = SnoozeOption.thisWeekend.wakeTime(from: now, calendar: cal)
        let day = cal.component(.day, from: result)
        XCTAssertEqual(day, 27)
    }

    func testNextWeekIsMondayAt9AM() {
        let cal = gregorianCal()
        let now = cal.date(from: DateComponents(
            year: 2026, month: 6, day: 16, hour: 12 // Tuesday
        ))!
        let result = SnoozeOption.nextWeek.wakeTime(from: now, calendar: cal)
        let comps = cal.dateComponents([.weekday, .hour], from: result)
        XCTAssertEqual(comps.weekday, 2, "Monday is weekday 2")
        XCTAssertEqual(comps.hour, 9)
    }
}
