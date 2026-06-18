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

    func testSearchSinceWindowExcludesOlderMessages() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let now = Date()
        // Old message: 200 days ago, contains "invoice".
        _ = try await store.ingest(IngestMessage(
            accountID: acc, folder: "INBOX", messageID: "<old@x>",
            subject: "Ancient archive", fromAddress: "a@x",
            date: now.addingTimeInterval(-200 * 86400), sizeBytes: 100,
            plainBody: "Ancient invoice from another era."
        ))
        // Recent message: 5 days ago, also contains "invoice".
        _ = try await store.ingest(IngestMessage(
            accountID: acc, folder: "INBOX", messageID: "<new@x>",
            subject: "This week", fromAddress: "b@x",
            date: now.addingTimeInterval(-5 * 86400), sizeBytes: 100,
            plainBody: "Latest invoice attached."
        ))

        let allHits = try await store.search("invoice", limit: 10)
        XCTAssertEqual(allHits.count, 2)

        let windowed = try await store.search("invoice",
                                              since: now.addingTimeInterval(-30 * 86400),
                                              limit: 10)
        XCTAssertEqual(windowed.count, 1)
        XCTAssertEqual(windowed.first?.messageID, "<new@x>")
    }

    func testYearShardedSearchSpansShardsAndPrunes() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")

        // Three messages in three different years, all with "invoice" in body.
        let cal = Calendar(identifier: .gregorian)
        func dateInYear(_ y: Int) -> Date {
            var c = DateComponents()
            c.year = y; c.month = 6; c.day = 15
            return cal.date(from: c)!
        }
        for (i, year) in [2022, 2024, 2026].enumerated() {
            _ = try await store.ingest(IngestMessage(
                accountID: acc, folder: "INBOX", messageID: "<m\(i)@x>",
                subject: "Note \(year)", fromAddress: "a@x",
                date: dateInYear(year), sizeBytes: 100,
                plainBody: "Invoice for year \(year)."
            ))
        }

        let shardMonths = await store.shardMonths()
        XCTAssertEqual(shardMonths, ["2022-06", "2024-06", "2026-06"],
                       "one shard per month present in the data")

        // All-time: spans all three shards.
        let all = try await store.search("invoice", limit: 10)
        XCTAssertEqual(all.count, 3)

        // Windowed to 2025 onward: only 2026 shard contributes a hit.
        var sinceC = DateComponents()
        sinceC.year = 2025; sinceC.month = 1; sinceC.day = 1
        let since = cal.date(from: sinceC)!
        let recent = try await store.search("invoice", since: since, limit: 10)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.messageID, "<m2@x>")
    }

    func testAttachmentBlobIsDeduplicatedAcrossMessages() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let pdfBytes = Data(repeating: 0xCC, count: 16 * 1024)

        let id1 = try await store.ingest(IngestMessage(
            accountID: acc, folder: "INBOX", messageID: "<a1@x>",
            subject: "First mail with attachment", fromAddress: "a@x",
            date: Date(), sizeBytes: 100,
            plainBody: "see attached.",
            attachments: [AttachmentIn(filename: "report.pdf", mimeType: "application/pdf", data: pdfBytes)]
        ))
        let id2 = try await store.ingest(IngestMessage(
            accountID: acc, folder: "INBOX", messageID: "<a2@x>",
            subject: "Forwarded mail same attachment", fromAddress: "b@x",
            date: Date(), sizeBytes: 100,
            plainBody: "FYI.",
            attachments: [AttachmentIn(filename: "report.pdf", mimeType: "application/pdf", data: pdfBytes)]
        ))

        let refs1 = try await store.attachments(messageRowID: id1)
        let refs2 = try await store.attachments(messageRowID: id2)
        XCTAssertEqual(refs1.count, 1)
        XCTAssertEqual(refs2.count, 1)
        XCTAssertNotNil(refs1.first?.sha256Hex)
        XCTAssertEqual(refs1.first?.sha256Hex, refs2.first?.sha256Hex,
                       "identical attachment content must share a single sha256")
        XCTAssertEqual(refs1.first?.sizeBytes, Int64(pdfBytes.count))

        // The blob store itself should hold exactly one file.
        let blobStats = try await store.blobStore.stats()
        XCTAssertEqual(blobStats.count, 1, "identical bytes must dedupe to one blob")
        XCTAssertEqual(blobStats.bytes, Int64(pdfBytes.count))

        // Loading the attachment data round-trips.
        let loaded = await store.loadAttachmentData(sha256Hex: refs1.first!.sha256Hex!)
        XCTAssertEqual(loaded, pdfBytes)
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
