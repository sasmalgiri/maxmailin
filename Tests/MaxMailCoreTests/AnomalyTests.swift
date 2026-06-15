import XCTest
@testable import MaxMailCore

final class AnomalyTests: XCTestCase {

    private func makeStore() throws -> MailStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anomaly-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try MailStore(url: dir.appendingPathComponent("mail.sqlite"))
    }

    private func ingest(_ store: MailStore, account: Int64, from: String, date: Date,
                       id: String = UUID().uuidString) async throws -> Int64 {
        try await store.ingest(IngestMessage(
            accountID: account, folder: "INBOX",
            messageID: "<\(id)@x>",
            subject: "Note",
            fromAddress: from,
            date: date,
            sizeBytes: 100,
            plainBody: "body"
        ))
    }

    // MARK: - First-time contact

    func testFirstTimeContactRaisedExactlyOnce() async throws {
        let store = try makeStore()
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")

        let first = try await ingest(store, account: acc, from: "stranger@x.com",
                                     date: Date(timeIntervalSinceReferenceDate: 1_000_000),
                                     id: "f1")
        let second = try await ingest(store, account: acc, from: "stranger@x.com",
                                      date: Date(timeIntervalSinceReferenceDate: 1_000_500),
                                      id: "f2")

        let a1 = try await store.anomalies(forMessageRowID: first)
        XCTAssertTrue(a1.contains { $0.kind == .firstTimeContact })
        let a2 = try await store.anomalies(forMessageRowID: second)
        XCTAssertFalse(a2.contains { $0.kind == .firstTimeContact },
                       "second message from same sender should not be first-time")
    }

    // MARK: - Dormant sender revival

    func testDormantRevivalRaisedAfterLongGap() async throws {
        let store = try makeStore()
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")

        // Old message two years ago, recent message today.
        let twoYearsAgo = Date().addingTimeInterval(-2 * 365 * 86_400)
        let yesterday  = Date().addingTimeInterval(-86_400)
        _ = try await ingest(store, account: acc, from: "old.friend@x.com",
                             date: twoYearsAgo, id: "d1")
        let revival = try await ingest(store, account: acc, from: "old.friend@x.com",
                                       date: yesterday, id: "d2")

        let a = try await store.anomalies(forMessageRowID: revival)
        let dormant = a.first(where: { $0.kind == .dormantSenderRevival })
        XCTAssertNotNil(dormant, "expected dormant-sender flag, got \(a)")
        XCTAssertEqual(dormant?.severity, .high, "≥365 days should escalate to high severity")
        XCTAssertFalse(a.contains { $0.kind == .firstTimeContact },
                       "revival is not the first message")
    }

    func testShortGapDoesNotRaiseDormant() async throws {
        let store = try makeStore()
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let now = Date()
        _ = try await ingest(store, account: acc, from: "regular@x.com",
                             date: now.addingTimeInterval(-10 * 86_400),
                             id: "r1")
        let recent = try await ingest(store, account: acc, from: "regular@x.com",
                                      date: now, id: "r2")
        let a = try await store.anomalies(forMessageRowID: recent)
        XCTAssertFalse(a.contains { $0.kind == .dormantSenderRevival },
                       "10-day gap should not trigger dormant flag")
    }

    // MARK: - Off-hours arrival

    func testOffHoursArrivalUsesLocalTime() async throws {
        let store = try makeStore()
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")

        // Build a date at 02:30 local time and one at 14:00 local time.
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 2; comps.minute = 30
        let nightDate = cal.date(from: comps)!
        comps.hour = 14; comps.minute = 0
        let dayDate = cal.date(from: comps)!

        let nightID = try await ingest(store, account: acc, from: "burst@x.com",
                                       date: nightDate, id: "off1")
        let dayID = try await ingest(store, account: acc, from: "burst@x.com",
                                     date: dayDate, id: "off2")

        let night = try await store.anomalies(forMessageRowID: nightID)
        XCTAssertTrue(night.contains { $0.kind == .offHoursArrival },
                      "02:30 arrival should be flagged")
        let day = try await store.anomalies(forMessageRowID: dayID)
        XCTAssertFalse(day.contains { $0.kind == .offHoursArrival },
                       "14:00 arrival is not off-hours")
    }

    // MARK: - Batch view

    func testRecentAnomaliesReturnsNewestFirst() async throws {
        let store = try makeStore()
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let now = Date()

        // Three distinct first-time senders in the last week + one repeat.
        _ = try await ingest(store, account: acc, from: "new1@x.com",
                             date: now.addingTimeInterval(-3 * 86_400), id: "n1")
        _ = try await ingest(store, account: acc, from: "new2@x.com",
                             date: now.addingTimeInterval(-2 * 86_400), id: "n2")
        // Same sender — second message must NOT show up as first-time.
        _ = try await ingest(store, account: acc, from: "new1@x.com",
                             date: now.addingTimeInterval(-1 * 86_400), id: "n3")
        _ = try await ingest(store, account: acc, from: "new3@x.com",
                             date: now, id: "n4")

        let since = now.addingTimeInterval(-7 * 86_400)
        let recent = try await store.recentAnomalies(accountID: acc, since: since, limit: 20)
        let firstTime = recent.filter { $0.kind == .firstTimeContact }
        XCTAssertEqual(firstTime.count, 3,
                       "exactly three distinct senders should land as first-time")
        // Newest first.
        let ids = firstTime.map(\.messageRowID)
        XCTAssertEqual(ids, ids.sorted(by: >))
    }
}
