import XCTest
@testable import MaxMailCore

final class UnifiedInboxTests: XCTestCase {

    private func tempDB() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("unified-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mail.sqlite")
    }

    /// Seed two accounts with overlapping INBOX rows and one row in a
    /// different folder so the cross-account / folder-bound filter
    /// can be exercised independently.
    private func seedTwoAccounts(in store: MailStore) async throws
        -> (a: Int64, b: Int64, rows: [Int64])
    {
        let a = try await store.upsertAccount(name: "A", address: "alice@x", kind: "local")
        let b = try await store.upsertAccount(name: "B", address: "bob@y", kind: "local")
        var rows: [Int64] = []
        for i in 0..<3 {
            let id = try await store.ingest(IngestMessage(
                accountID: a, folder: "INBOX",
                messageID: "<a-\(i)@x>",
                subject: "A \(i)", fromAddress: "x@x",
                date: Date(timeIntervalSinceReferenceDate: Double(100 + i * 60)),
                sizeBytes: 1, plainBody: ""
            ))
            rows.append(id)
        }
        for i in 0..<2 {
            let id = try await store.ingest(IngestMessage(
                accountID: b, folder: "INBOX",
                messageID: "<b-\(i)@x>",
                subject: "B \(i)", fromAddress: "y@y",
                date: Date(timeIntervalSinceReferenceDate: Double(150 + i * 60)),
                sizeBytes: 1, plainBody: ""
            ))
            rows.append(id)
        }
        // Non-INBOX row that the unified query must NOT include.
        _ = try await store.ingest(IngestMessage(
            accountID: a, folder: "Archive",
            messageID: "<arch@x>",
            subject: "Archived", fromAddress: "x@x",
            date: Date(timeIntervalSinceReferenceDate: 999),
            sizeBytes: 1, plainBody: ""
        ))
        return (a, b, rows)
    }

    // MARK: - Cross-account merge

    func testUnifiedHeadersMergesAllAccountsForFolder() async throws {
        let store = try MailStore(url: tempDB())
        let (_, _, rows) = try await seedTwoAccounts(in: store)
        let unified = try await store.unifiedHeaders()
        XCTAssertEqual(Set(unified.map(\.id)), Set(rows),
                       "must return every INBOX row across both accounts")
        XCTAssertEqual(unified.count, 5,
                       "must not include rows from non-INBOX folders")
    }

    func testUnifiedHeadersAreDateDescending() async throws {
        let store = try MailStore(url: tempDB())
        _ = try await seedTwoAccounts(in: store)
        let unified = try await store.unifiedHeaders()
        let dates = unified.map(\.date)
        XCTAssertEqual(dates, dates.sorted(by: >))
    }

    // MARK: - Snooze interaction

    func testUnifiedHeadersHideSnoozedMessages() async throws {
        let store = try MailStore(url: tempDB())
        let (_, _, rows) = try await seedTwoAccounts(in: store)
        // Snooze one row well into the future.
        let snoozed = rows[0]
        try await store.snoozeMessage(messageRowID: snoozed,
                                      until: Date().addingTimeInterval(3600))
        let unified = try await store.unifiedHeaders()
        XCTAssertFalse(unified.contains { $0.id == snoozed },
                       "snoozed row must drop out of the unified inbox until due")
    }

    // MARK: - Threadable + counts

    func testUnifiedThreadableHeadersCarryThreadingFields() async throws {
        let store = try MailStore(url: tempDB())
        _ = try await seedTwoAccounts(in: store)
        let rows = try await store.unifiedThreadableHeaders()
        XCTAssertEqual(rows.count, 5)
        XCTAssertTrue(rows.allSatisfy { !$0.messageID.isEmpty })
    }

    func testUnifiedFolderCountsAggregateTotalAndUnreadAcrossAccounts() async throws {
        let store = try MailStore(url: tempDB())
        let (_, _, rows) = try await seedTwoAccounts(in: store)
        // Mark one row read.
        try await store.updateMessageFlags(messageRowID: rows[0], flags: .seen)
        let counts = try await store.unifiedFolderCounts()
        XCTAssertEqual(counts.total, 5)
        XCTAssertEqual(counts.unread, 4)
    }
}
