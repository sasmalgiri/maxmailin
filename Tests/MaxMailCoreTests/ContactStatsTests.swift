import XCTest
@testable import MaxMailCore

final class ContactStatsTests: XCTestCase {

    private func makeStore() throws -> MailStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("contact-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try MailStore(url: dir.appendingPathComponent("mail.sqlite"))
    }

    @discardableResult
    private func ingest(_ store: MailStore, account: Int64, from: String,
                       hasAttachment: Bool = false, date: Date = Date()) async throws -> Int64 {
        let flags: MessageFlags = hasAttachment ? [.hasAttachment] : []
        return try await store.ingest(IngestMessage(
            accountID: account, folder: "INBOX",
            messageID: "<m-\(UUID().uuidString)@x>",
            subject: "n",
            fromAddress: from,
            date: date,
            sizeBytes: 100,
            flags: flags,
            plainBody: "great success"
        ))
    }

    func testTopSendersOrderedByCount() async throws {
        let store = try makeStore()
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        for _ in 0..<5 { try await ingest(store, account: acc, from: "alice@x") }
        for _ in 0..<3 { try await ingest(store, account: acc, from: "bob@x") }
        try await ingest(store, account: acc, from: "carol@x")

        let top = try await store.topSenders(accountID: acc, limit: 10)
        XCTAssertEqual(top.map(\.address), ["alice@x", "bob@x", "carol@x"])
        XCTAssertEqual(top.first?.messageCount, 5)
    }

    func testTopSendersHonorsSinceWindow() async throws {
        let store = try makeStore()
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let oldDate = Date().addingTimeInterval(-180 * 86_400)
        let recent  = Date().addingTimeInterval(-5 * 86_400)
        for _ in 0..<10 { try await ingest(store, account: acc, from: "old@x", date: oldDate) }
        for _ in 0..<2  { try await ingest(store, account: acc, from: "new@x", date: recent) }

        let all = try await store.topSenders(accountID: acc)
        XCTAssertEqual(all.first?.address, "old@x", "all-time leader is the high-volume sender")

        let lastMonth = try await store.topSenders(
            accountID: acc, since: Date().addingTimeInterval(-30 * 86_400)
        )
        XCTAssertEqual(lastMonth.map(\.address), ["new@x"],
                       "30-day window should exclude old@x entirely")
    }

    func testTopSendersIncludesAttachmentCountAndDateSpan() async throws {
        let store = try makeStore()
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let early = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let late  = Date(timeIntervalSinceReferenceDate: 5_000_000)
        try await ingest(store, account: acc, from: "alice@x", hasAttachment: false, date: early)
        try await ingest(store, account: acc, from: "alice@x", hasAttachment: true,  date: late)

        let top = try await store.topSenders(accountID: acc)
        let alice = top.first { $0.address == "alice@x" }!
        XCTAssertEqual(alice.messageCount, 2)
        XCTAssertEqual(alice.attachmentMessageCount, 1)
        XCTAssertEqual(alice.firstSeen.timeIntervalSinceReferenceDate, 1_000_000, accuracy: 1)
        XCTAssertEqual(alice.lastSeen.timeIntervalSinceReferenceDate,  5_000_000, accuracy: 1)
    }

    func testSenderStatWithNLPMeanSentiment() async throws {
        let store = try makeStore()
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let id1 = try await ingest(store, account: acc, from: "alice@x")
        let id2 = try await ingest(store, account: acc, from: "alice@x")
        _ = try await store.ensureNLP(messageRowID: id1)
        _ = try await store.ensureNLP(messageRowID: id2)

        let stat = try await store.senderStat(accountID: acc, address: "alice@x")
        XCTAssertNotNil(stat)
        XCTAssertEqual(stat?.messageCount, 2)
        XCTAssertNotNil(stat?.meanSentiment, "with two analyzed messages, mean should be non-nil")
    }

    func testMessagesFromSenderReturnsNewestFirst() async throws {
        let store = try makeStore()
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let d1 = Date().addingTimeInterval(-7 * 86_400)
        let d2 = Date().addingTimeInterval(-2 * 86_400)
        let d3 = Date()
        try await ingest(store, account: acc, from: "alice@x", date: d1)
        try await ingest(store, account: acc, from: "alice@x", date: d3)
        try await ingest(store, account: acc, from: "alice@x", date: d2)
        try await ingest(store, account: acc, from: "bob@x", date: d3)

        let aliceMail = try await store.messagesFromSender(accountID: acc, address: "alice@x", limit: 10)
        XCTAssertEqual(aliceMail.count, 3, "filter to alice only")
        let dates = aliceMail.map(\.date)
        XCTAssertEqual(dates, dates.sorted(by: >), "newest first")
    }
}
