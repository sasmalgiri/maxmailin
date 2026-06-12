import XCTest
@testable import MaxMailCore

final class MailStoreTests: XCTestCase {
    private func tempDB() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maxmailin-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mail.sqlite")
    }

    func testIngestAndPagedRead() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "Test", address: "test@example.com", kind: "local")

        for i in 0..<120 {
            _ = try await store.ingest(IngestMessage(
                accountID: acc,
                folder: "INBOX",
                messageID: "<m-\(i)@example.com>",
                subject: "Hello \(i)",
                fromAddress: "alice@example.com",
                toAddresses: ["bob@example.com"],
                date: Date(timeIntervalSinceReferenceDate: Double(i)),
                sizeBytes: 1024,
                plainBody: "This is the body of message number \(i). It mentions invoices and deadlines."
            ))
        }

        let page1 = try await store.headers(in: "INBOX", accountID: acc, limit: 50)
        XCTAssertEqual(page1.count, 50)
        // Newest first: the highest i should appear first.
        XCTAssertEqual(page1.first?.subject, "Hello 119")

        let page2 = try await store.headers(in: "INBOX", accountID: acc, before: page1.last!.date, limit: 50)
        XCTAssertEqual(page2.count, 50)
        XCTAssertNotEqual(page1.last?.id, page2.first?.id)

        let stats = try await store.stats()
        XCTAssertEqual(stats.messageCount, 120)
        XCTAssertEqual(stats.folderCount, 1)
        XCTAssertEqual(stats.accountCount, 1)
    }

    func testIdempotentIngest() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "Test", address: "test@example.com", kind: "local")
        let m = IngestMessage(
            accountID: acc,
            folder: "INBOX",
            messageID: "<dup@example.com>",
            subject: "Dup test",
            fromAddress: "a@x",
            date: Date(),
            sizeBytes: 100,
            plainBody: "Body."
        )
        let id1 = try await store.ingest(m)
        let id2 = try await store.ingest(m)
        XCTAssertEqual(id1, id2)
        let stats = try await store.stats()
        XCTAssertEqual(stats.messageCount, 1)
    }

    func testFullTextSearchRanks() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "Test", address: "test@example.com", kind: "local")

        _ = try await store.ingest(IngestMessage(
            accountID: acc, folder: "INBOX", messageID: "<a@x>",
            subject: "Project update", fromAddress: "carol@x",
            date: Date(), sizeBytes: 100,
            plainBody: "Quarterly invoice attached. Please review the deadline."
        ))
        _ = try await store.ingest(IngestMessage(
            accountID: acc, folder: "INBOX", messageID: "<b@x>",
            subject: "Lunch?", fromAddress: "dave@x",
            date: Date(), sizeBytes: 100,
            plainBody: "Want to grab pizza later?"
        ))

        let hits = try await store.search("invoice deadline", limit: 10)
        XCTAssertGreaterThanOrEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.messageID, "<a@x>")
        let snip = hits.first!.snippet
        XCTAssertTrue(snip.contains("⟦invoice⟧"), "snippet should bracket the match: \(snip)")
        XCTAssertTrue(snip.contains("⟦deadline⟧"), "snippet should bracket the match: \(snip)")
    }

    func testBodyIsNotLoadedByHeaderQuery() async throws {
        // Sanity: the headers() call returns no body field, and loadBody returns it on demand.
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let id = try await store.ingest(IngestMessage(
            accountID: acc, folder: "INBOX", messageID: "<c@x>",
            subject: "Body test", fromAddress: "a@x",
            date: Date(), sizeBytes: 100,
            plainBody: "Secret body content."
        ))
        let headers = try await store.headers(in: "INBOX", accountID: acc, limit: 10)
        XCTAssertEqual(headers.count, 1)
        XCTAssertNotNil(headers.first?.snippet)
        let body = try await store.loadBody(messageRowID: id)
        XCTAssertEqual(body?.plain, "Secret body content.")
    }
}
