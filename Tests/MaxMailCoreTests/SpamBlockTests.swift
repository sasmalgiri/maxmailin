import XCTest
@testable import MaxMailCore

final class SpamBlockTests: XCTestCase {

    private func tempDB() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spam-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mail.sqlite")
    }

    // MARK: - Routing helper

    func testRoutedFolderUntouchedWhenBlocklistEmpty() {
        XCTAssertEqual(
            MailStore.routedFolder(
                originalFolder: "INBOX",
                fromAddress: "alice@x",
                blocked: []
            ),
            "INBOX"
        )
    }

    func testRoutedFolderSendsBlockedSenderToSpam() {
        XCTAssertEqual(
            MailStore.routedFolder(
                originalFolder: "INBOX",
                fromAddress: "Alice <alice@x>",
                blocked: ["alice@x"]
            ),
            "Spam"
        )
    }

    func testRoutedFolderHonoursBareCaseAndAngleBrackets() {
        // Same parser as the rest of Core; either bracketed or bare,
        // either case, must collapse to the lowercased bare form.
        XCTAssertEqual(
            MailStore.routedFolder(
                originalFolder: "INBOX",
                fromAddress: "ALICE@X",
                blocked: ["alice@x"]
            ),
            "Spam"
        )
    }

    // MARK: - Blocklist CRUD

    func testBlockAndUnblockRoundTrip() async throws {
        let store = try MailStore(url: tempDB())
        try await store.blockSender(address: "Spammer@Bad.example",
                                    reason: "newsletter")
        let blocked = try await store.isBlocked(address: "spammer@bad.example")
        XCTAssertTrue(blocked)
        // Persists in lower-cased form so subsequent reads match
        // anything the parser produces.
        let listed = try await store.blockedSenders()
        XCTAssertEqual(listed.map(\.address), ["spammer@bad.example"])
        XCTAssertEqual(listed.first?.reason, "newsletter")

        try await store.unblockSender(address: "SPAMMER@bad.example")
        let stillBlocked = try await store.isBlocked(address: "spammer@bad.example")
        XCTAssertFalse(stillBlocked)
    }

    func testBlockingEmptyAddressIsANoOp() async throws {
        let store = try MailStore(url: tempDB())
        try await store.blockSender(address: "   ", reason: nil)
        let listed = try await store.blockedSenders()
        XCTAssertTrue(listed.isEmpty)
    }

    // MARK: - Ingest routing

    func testIngestRoutesBlockedSenderStraightToSpam() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        try await store.blockSender(address: "spammer@bad.example", reason: nil)

        // From the blocklist — must land in Spam even though the
        // ingest caller said INBOX.
        _ = try await store.ingest(IngestMessage(
            accountID: acc, folder: "INBOX",
            messageID: "<spam-1@x>", subject: "Buy",
            fromAddress: "Spammer <spammer@bad.example>",
            date: Date(timeIntervalSinceReferenceDate: 1_000),
            sizeBytes: 1, plainBody: "junk"
        ))
        // Clean sender — must stay in INBOX.
        _ = try await store.ingest(IngestMessage(
            accountID: acc, folder: "INBOX",
            messageID: "<good-1@x>", subject: "Hi",
            fromAddress: "alice@x",
            date: Date(timeIntervalSinceReferenceDate: 2_000),
            sizeBytes: 1, plainBody: "hi"
        ))

        let inbox = try await store.headers(in: "INBOX", accountID: acc, limit: 50)
        XCTAssertEqual(inbox.map(\.messageID), ["<good-1@x>"])
        let spam = try await store.headers(in: "Spam", accountID: acc, limit: 50)
        XCTAssertEqual(spam.map(\.messageID), ["<spam-1@x>"])
    }

    func testIngestKeepsCleanMessagesWhenBlocklistEmpty() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        // No blocked senders → ingest path is unchanged byte-for-byte.
        _ = try await store.ingest(IngestMessage(
            accountID: acc, folder: "INBOX",
            messageID: "<m1@x>", subject: "Hi",
            fromAddress: "alice@x",
            date: Date(timeIntervalSinceReferenceDate: 1_000),
            sizeBytes: 1, plainBody: "hi"
        ))
        let inbox = try await store.headers(in: "INBOX", accountID: acc, limit: 50)
        XCTAssertEqual(inbox.map(\.messageID), ["<m1@x>"])
    }

    // MARK: - Mark as spam / not spam

    func testMarkAsSpamMovesExistingMessageToSpamFolder() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let id = try await store.ingest(IngestMessage(
            accountID: acc, folder: "INBOX",
            messageID: "<m1@x>", subject: "Hi",
            fromAddress: "alice@x",
            date: Date(timeIntervalSinceReferenceDate: 1_000),
            sizeBytes: 1, plainBody: "hi"
        ))
        try await store.markAsSpam(messageRowID: id, accountID: acc)
        let inbox = try await store.headers(in: "INBOX", accountID: acc, limit: 50)
        XCTAssertTrue(inbox.isEmpty)
        let spam = try await store.headers(in: "Spam", accountID: acc, limit: 50)
        XCTAssertEqual(spam.map(\.id), [id])
    }

    func testMarkAsNotSpamRestoresIntoSuppliedFolder() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        try await store.blockSender(address: "spammer@bad.example", reason: nil)
        let id = try await store.ingest(IngestMessage(
            accountID: acc, folder: "INBOX",
            messageID: "<m1@x>", subject: "Hi",
            fromAddress: "spammer@bad.example",
            date: Date(timeIntervalSinceReferenceDate: 1_000),
            sizeBytes: 1, plainBody: "hi"
        ))
        // Started in Spam (auto-routed); now rescue it.
        try await store.markAsNotSpam(messageRowID: id, accountID: acc)
        let inbox = try await store.headers(in: "INBOX", accountID: acc, limit: 50)
        XCTAssertEqual(inbox.map(\.id), [id])
    }
}
