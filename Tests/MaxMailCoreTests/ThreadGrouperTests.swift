import XCTest
@testable import MaxMailCore

final class ThreadGrouperTests: XCTestCase {

    private func header(
        id: Int64, messageID: String, subject: String = "S",
        from: String = "x@x", date: TimeInterval, seen: Bool = false
    ) -> MessageHeader {
        MessageHeader(
            id: id, messageID: messageID, folder: "INBOX",
            subject: subject, fromAddress: from,
            date: Date(timeIntervalSinceReferenceDate: date),
            sizeBytes: 0,
            flags: seen ? .seen : [],
            snippet: nil
        )
    }

    private func threadable(
        id: Int64, messageID: String, subject: String = "S",
        date: TimeInterval,
        inReplyTo: String? = nil, references: [String] = [],
        from: String = "x@x", seen: Bool = false
    ) -> MailStore.ThreadableHeader {
        MailStore.ThreadableHeader(
            header: header(id: id, messageID: messageID, subject: subject,
                           from: from, date: date, seen: seen),
            messageID: messageID,
            inReplyTo: inReplyTo,
            references: references
        )
    }

    // MARK: - Clustering

    func testInReplyToLinksRepliesToTheirRoot() {
        let root = threadable(id: 1, messageID: "<a@x>", date: 10, from: "alice@x")
        let r1 = threadable(id: 2, messageID: "<b@x>", date: 20,
                            inReplyTo: "<a@x>", from: "bob@x")
        let r2 = threadable(id: 3, messageID: "<c@x>", date: 30,
                            inReplyTo: "<b@x>", references: ["<a@x>", "<b@x>"],
                            from: "carol@x")
        let threads = ThreadGrouper.group([root, r1, r2])
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].messageRowIDs, [1, 2, 3])
        XCTAssertEqual(threads[0].id, "<a@x>")
        XCTAssertEqual(threads[0].participants, ["alice@x", "bob@x", "carol@x"])
        XCTAssertEqual(threads[0].count, 3)
    }

    func testReferencesPullInOffPageAncestorAsPlaceholder() {
        // a reply to a message we don't have on this page. Both
        // replies should still cluster together via the shared
        // off-page parent.
        let r1 = threadable(id: 1, messageID: "<r1@x>", date: 10,
                            inReplyTo: "<root@x>")
        let r2 = threadable(id: 2, messageID: "<r2@x>", date: 20,
                            inReplyTo: "<root@x>", references: ["<root@x>"])
        let threads = ThreadGrouper.group([r1, r2])
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].count, 2)
    }

    func testUnrelatedMessagesProduceSeparateThreads() {
        let a = threadable(id: 1, messageID: "<a@x>", date: 10)
        let b = threadable(id: 2, messageID: "<b@x>", date: 20)
        let c = threadable(id: 3, messageID: "<c@x>", date: 30)
        let threads = ThreadGrouper.group([a, b, c])
        XCTAssertEqual(threads.count, 3)
        // Sorted newest activity first.
        XCTAssertEqual(threads.map(\.id), ["<c@x>", "<b@x>", "<a@x>"])
    }

    // MARK: - Ordering and metadata

    func testThreadIDIsRootMessageIDAndOrderIsChronological() {
        // Insert replies before the root to verify root selection
        // doesn't depend on input order.
        let r1 = threadable(id: 2, messageID: "<b@x>", date: 20,
                            inReplyTo: "<a@x>")
        let root = threadable(id: 1, messageID: "<a@x>", date: 10)
        let threads = ThreadGrouper.group([r1, root])
        XCTAssertEqual(threads[0].id, "<a@x>")
        XCTAssertEqual(threads[0].messageRowIDs, [1, 2])
    }

    func testUnreadCountSumsAcrossUnreadMessagesOnly() {
        let root = threadable(id: 1, messageID: "<a@x>", date: 10, seen: true)
        let r1 = threadable(id: 2, messageID: "<b@x>", date: 20,
                            inReplyTo: "<a@x>", seen: false)
        let r2 = threadable(id: 3, messageID: "<c@x>", date: 30,
                            inReplyTo: "<b@x>", seen: false)
        let threads = ThreadGrouper.group([root, r1, r2])
        XCTAssertEqual(threads[0].unreadCount, 2)
    }

    func testLatestDateDrivesThreadOrdering() {
        // Thread A activity: 10 + 100. Thread B activity: 20 + 50.
        let a1 = threadable(id: 1, messageID: "<a1@x>", date: 10)
        let a2 = threadable(id: 2, messageID: "<a2@x>", date: 100,
                            inReplyTo: "<a1@x>")
        let b1 = threadable(id: 3, messageID: "<b1@x>", date: 20)
        let b2 = threadable(id: 4, messageID: "<b2@x>", date: 50,
                            inReplyTo: "<b1@x>")
        let threads = ThreadGrouper.group([a1, a2, b1, b2])
        // Thread A is newest (date 100) so should come first.
        XCTAssertEqual(threads[0].id, "<a1@x>")
        XCTAssertEqual(threads[1].id, "<b1@x>")
    }

    // MARK: - Subject normalisation

    func testStripReplyPrefixHandlesNestedAndMixedCases() {
        XCTAssertEqual(ThreadGrouper.stripReplyPrefix("Re: Hello"), "Hello")
        XCTAssertEqual(ThreadGrouper.stripReplyPrefix("Re: Re: Hello"), "Hello")
        XCTAssertEqual(ThreadGrouper.stripReplyPrefix("FWD: Re: Hello"), "Hello")
        XCTAssertEqual(ThreadGrouper.stripReplyPrefix("Fw: Hello"), "Hello")
        XCTAssertEqual(ThreadGrouper.stripReplyPrefix("Hello"), "Hello")
        XCTAssertEqual(ThreadGrouper.stripReplyPrefix("   Re:   Hello "), "Hello")
    }

    func testDisplaySubjectKeepsPrefixesIntact() {
        let r = threadable(id: 1, messageID: "<x@x>", subject: "Re: Hello", date: 10)
        let threads = ThreadGrouper.group([r])
        XCTAssertEqual(threads[0].displaySubject, "Re: Hello")
        XCTAssertEqual(threads[0].subject, "Hello")
    }

    // MARK: - Edge

    func testEmptyInputProducesEmptyOutput() {
        XCTAssertTrue(ThreadGrouper.group([]).isEmpty)
    }
}
