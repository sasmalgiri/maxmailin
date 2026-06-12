import XCTest
@testable import MaxMailCore

final class MboxImportTests: XCTestCase {

    // MARK: - MboxStream

    func testStreamYieldsEachMessageOnce() throws {
        let mbox = """
        From foo@bar Mon Jan 01 12:00:00 2024
        From: alice@x.com
        Subject: First
        Date: Mon, 1 Jan 2024 12:00:00 +0000

        Body of first message.

        From bar@baz Tue Feb 02 13:00:00 2024
        From: bob@x.com
        Subject: Second
        Date: Tue, 2 Feb 2024 13:00:00 +0000

        Body of second message.
        """
        let url = try writeTemp(mbox)
        let stream = try MboxStream(url: url)
        var subjects: [String] = []
        try stream.iterate { raw, _ in
            let p = RFC5322Parser.parse(raw, fallbackDate: Date())
            subjects.append(p.subject)
        }
        XCTAssertEqual(subjects, ["First", "Second"])
    }

    func testStreamUnescapesQuotedFromLines() throws {
        // mbox-rd quotes interior "From " as ">From " — verify we put it back.
        let mbox = """
        From envelope@x Mon Jan 01 12:00:00 2024
        From: alice@x
        Subject: Has quoted From
        Date: Mon, 1 Jan 2024 12:00:00 +0000

        Reply to your last email.
        >From was the quoted prefix.
        >>From doubly quoted too.

        """
        let url = try writeTemp(mbox)
        let stream = try MboxStream(url: url)
        try stream.iterate { raw, _ in
            let body = String(data: RFC5322Parser.splitHeaderBody(raw).body, encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("\nFrom was"), "single-quote should be unescaped: \(body)")
            XCTAssertTrue(body.contains("\n>From doubly"), "double-quote should drop one >: \(body)")
        }
    }

    // MARK: - RFC5322Parser

    func testHeaderFoldingAndAddressExtraction() throws {
        let raw = Data("""
        From: "Alice (admin)"
         \t<ALICE@Example.COM>
        To: Bob <bob@x.com>, carol@y.com
        Cc: Dave <dave@z.com>
        Subject: Folded subject
         continues here
        Date: Mon, 1 Jan 2024 12:00:00 +0000
        Message-ID: <abc@x.com>

        body
        """.utf8)
        let p = RFC5322Parser.parse(raw, fallbackDate: Date())
        XCTAssertEqual(p.fromAddress, "alice@example.com")
        XCTAssertEqual(p.toAddresses, ["bob@x.com", "carol@y.com"])
        XCTAssertEqual(p.ccAddresses, ["dave@z.com"])
        XCTAssertEqual(p.subject, "Folded subject continues here")
        XCTAssertEqual(p.messageID, "<abc@x.com>")
    }

    func testRFC2047EncodedWordsAreDecoded() {
        // "=?UTF-8?B?SGVsbG8sIHdvcmxk?=" → "Hello, world"
        let decoded = RFC5322Parser.decodeEncodedWords("=?UTF-8?B?SGVsbG8sIHdvcmxk?=")
        XCTAssertEqual(decoded, "Hello, world")

        // Q-encoded: =?ISO-8859-1?Q?caf=E9_break?=  → "café break"
        let q = RFC5322Parser.decodeEncodedWords("=?ISO-8859-1?Q?caf=E9_break?=")
        XCTAssertEqual(q, "café break")
    }

    func testMessageIDIsSynthesizedWhenMissing() {
        let raw = Data("""
        From: alice@x.com
        Subject: No id
        Date: Mon, 1 Jan 2024 12:00:00 +0000

        body
        """.utf8)
        let p = RFC5322Parser.parse(raw, fallbackDate: Date())
        XCTAssertTrue(p.messageID.contains("synth-"), "expected synthesized message id, got \(p.messageID)")
    }

    func testDateFallback() {
        let raw = Data("""
        From: alice@x.com
        Subject: No date header

        body
        """.utf8)
        let fallback = Date(timeIntervalSince1970: 1_700_000_000)
        let p = RFC5322Parser.parse(raw, fallbackDate: fallback)
        XCTAssertEqual(p.date, fallback)
    }

    // MARK: - MboxImporter end-to-end

    func testImporterStreamsIntoMailStore() async throws {
        let mbox = """
        From envelope@x Mon Jan 01 12:00:00 2024
        From: alice@x.com
        To: bob@y.com
        Subject: Quarterly report
        Date: Mon, 1 Jan 2024 12:00:00 +0000
        Message-ID: <q1@x.com>

        Reviewing the invoice deadline.

        From envelope@x Tue Feb 02 13:00:00 2024
        From: carol@x.com
        To: alice@x.com
        Subject: Lunch plans
        Date: Tue, 2 Feb 2024 13:00:00 +0000
        Message-ID: <q2@x.com>

        Want pizza later this week?

        From envelope@x Wed Mar 03 14:00:00 2024
        From: alice@x.com
        Subject: Re: Quarterly report
        In-Reply-To: <q1@x.com>
        References: <q1@x.com>
        Date: Wed, 3 Mar 2024 14:00:00 +0000
        Message-ID: <q3@x.com>

        Looping back on that invoice review.
        """
        let url = try writeTemp(mbox)

        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mbox-import-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let store = try MailStore(url: dbDir.appendingPathComponent("mail.sqlite"))
        let acc = try await store.upsertAccount(name: "test", address: "test@example.com", kind: "import")

        let importer = MboxImporter(store: store, accountID: acc,
                                    options: .init(batchSize: 100, folder: "Imported"))
        let (ingested, skipped) = try await importer.importFile(at: url)
        XCTAssertEqual(ingested, 3)
        XCTAssertEqual(skipped, 0)

        let stats = try await store.stats()
        XCTAssertEqual(stats.messageCount, 3)

        // Search across imported corpus.
        let hits = try await store.search("invoice", limit: 10)
        XCTAssertEqual(hits.count, 2, "two messages mention invoice")

        // Threading data preserved.
        let headers = try await store.headers(in: "Imported", accountID: acc, limit: 10)
        XCTAssertEqual(headers.count, 3)

        // Idempotency: re-importing the same file inserts nothing new.
        let (ingested2, skipped2) = try await importer.importFile(at: url)
        XCTAssertEqual(ingested2, 0)
        XCTAssertEqual(skipped2, 3)
    }

    // MARK: - Helpers

    private func writeTemp(_ s: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mbox-test-\(UUID().uuidString).mbox")
        try s.data(using: .utf8)!.write(to: url)
        return url
    }
}
