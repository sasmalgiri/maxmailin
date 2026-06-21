import XCTest
@testable import MaxMailCore

final class OutboxTests: XCTestCase {

    private func tempDB() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mail.sqlite")
    }

    private func sampleMessage(subject: String = "Hello") -> SMTPClient.OutboundMessage {
        SMTPClient.OutboundMessage(
            from: "alice@x", to: ["bob@x"],
            subject: subject,
            plainBody: "Body",
            messageID: "<m-\(subject)@x>"
        )
    }

    // MARK: - Round trip

    func testEnqueueRoundTripsThroughList() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let sendAt = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let id = try await store.enqueueOutbox(
            accountID: acc, message: sampleMessage(), sendAt: sendAt
        )
        let rows = try await store.listOutbox(accountID: acc)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, id)
        XCTAssertEqual(rows[0].status, .pending)
        XCTAssertEqual(rows[0].attempts, 0)
        XCTAssertEqual(rows[0].message.subject, "Hello")
        XCTAssertEqual(rows[0].sendAt.timeIntervalSinceReferenceDate,
                       sendAt.timeIntervalSinceReferenceDate)
    }

    // MARK: - Due filter

    func testDueOutboxOnlyReturnsPendingRowsWithSendAtPast() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        // Past — due.
        _ = try await store.enqueueOutbox(
            accountID: acc, message: sampleMessage(subject: "past"),
            sendAt: Date().addingTimeInterval(-10)
        )
        // Future — not due.
        _ = try await store.enqueueOutbox(
            accountID: acc, message: sampleMessage(subject: "future"),
            sendAt: Date().addingTimeInterval(3600)
        )
        let due = try await store.dueOutboxEntries()
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due[0].message.subject, "past")
    }

    func testSendingRowsAreNotReturnedByDueAgainstThePump() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let id = try await store.enqueueOutbox(
            accountID: acc, message: sampleMessage(),
            sendAt: Date().addingTimeInterval(-10)
        )
        try await store.markOutboxSending(id: id)
        let due = try await store.dueOutboxEntries()
        XCTAssertTrue(due.isEmpty,
                      "rows already being sent must not race a second pump tick")
    }

    // MARK: - Lifecycle

    func testMarkSendingIncrementsAttempts() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let id = try await store.enqueueOutbox(
            accountID: acc, message: sampleMessage(), sendAt: Date()
        )
        try await store.markOutboxSending(id: id)
        let after = try await store.listOutbox(accountID: acc).first
        XCTAssertEqual(after?.status, .sending)
        XCTAssertEqual(after?.attempts, 1)
    }

    func testMarkSentRecordsTimestampAndClearsError() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let id = try await store.enqueueOutbox(
            accountID: acc, message: sampleMessage(), sendAt: Date()
        )
        try await store.markOutboxFailed(id: id, error: "smtp 451")
        try await store.markOutboxSent(id: id, at: Date(timeIntervalSinceReferenceDate: 999))
        let after = try await store.listOutbox(accountID: acc).first
        XCTAssertEqual(after?.status, .sent)
        XCTAssertNil(after?.lastError)
        XCTAssertEqual(after?.sentAt?.timeIntervalSinceReferenceDate, 999)
    }

    func testRetryReopensFailedRowAsPending() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let id = try await store.enqueueOutbox(
            accountID: acc, message: sampleMessage(),
            sendAt: Date().addingTimeInterval(-10)
        )
        try await store.markOutboxFailed(id: id, error: "smtp 451")
        try await store.retryOutbox(id: id)
        let due = try await store.dueOutboxEntries()
        XCTAssertEqual(due.first?.id, id)
        XCTAssertEqual(due.first?.lastError, "smtp 451",
                       "previous error is kept on the row for the UI")
    }

    func testCancelRemovesPendingButNotSendingRows() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let pending = try await store.enqueueOutbox(
            accountID: acc, message: sampleMessage(subject: "pending"),
            sendAt: Date()
        )
        let sending = try await store.enqueueOutbox(
            accountID: acc, message: sampleMessage(subject: "sending"),
            sendAt: Date()
        )
        try await store.markOutboxSending(id: sending)
        try await store.cancelOutbox(id: pending)
        try await store.cancelOutbox(id: sending)
        let all = try await store.listOutbox(accountID: acc)
        // Sending row must survive the cancel; pending row is gone.
        XCTAssertEqual(all.map(\.id), [sending])
    }

    // MARK: - SendLaterOption math

    func testSendLaterInOneHourAddsExactly3600s() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            SendLaterOption.inOneHour.sendTime(from: now),
            now.addingTimeInterval(3600)
        )
    }

    func testSendLaterTomorrowMorningIs9AMNextDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(
            year: 2026, month: 6, day: 20, hour: 14
        ))!
        let expected = cal.date(from: DateComponents(
            year: 2026, month: 6, day: 21, hour: 9
        ))!
        XCTAssertEqual(
            SendLaterOption.tomorrowMorning.sendTime(from: now, calendar: cal),
            expected
        )
    }

    func testSendLaterNextMondayLandsOnAMonday() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(
            year: 2026, month: 6, day: 17, hour: 12 // Wednesday
        ))!
        let result = SendLaterOption.nextMonday.sendTime(from: now, calendar: cal)
        XCTAssertEqual(cal.component(.weekday, from: result), 2)
        XCTAssertEqual(cal.component(.hour, from: result), 9)
    }
}
