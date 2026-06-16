import XCTest
@testable import MaxMailCore

final class ComposeDraftTests: XCTestCase {

    private func sample(
        subject: String = "Q4 review",
        from: String = "alice@example.com",
        to: [String] = ["bob@example.com"],
        cc: [String] = [],
        body: String = "Two sentences.\nSecond line.",
        messageID: String = "<m1@x>",
        references: [String] = [],
        userAddress: String = "bob@example.com"
    ) -> ComposeDraft {
        ComposePrefill.build(
            mode: .reply,
            originalSubject: subject,
            originalFrom: from,
            originalTo: to,
            originalCc: cc,
            originalDate: Date(timeIntervalSince1970: 1_700_000_000),
            originalBody: body,
            originalMessageID: messageID,
            originalReferences: references,
            currentUserAddress: userAddress
        )
    }

    // MARK: - Reply

    func testReplyTargetsOnlyOriginalSender() {
        let d = sample()
        XCTAssertEqual(d.to, "alice@example.com")
    }

    func testReplyAddsReSubjectOnlyOnce() {
        let first = sample(subject: "Q4 review")
        XCTAssertEqual(first.subject, "Re: Q4 review")
        let second = sample(subject: "Re: Q4 review")
        XCTAssertEqual(second.subject, "Re: Q4 review", "duplicate Re: must not stack")
    }

    func testReplyAppendsInReplyToAndReferences() {
        let d = sample(
            subject: "Topic", from: "alice@example.com",
            messageID: "<m9@x>", references: ["<m1@x>", "<m5@x>"]
        )
        XCTAssertEqual(d.inReplyTo, "<m9@x>")
        XCTAssertEqual(d.references, ["<m1@x>", "<m5@x>", "<m9@x>"])
    }

    func testReplyBodyQuotesOriginalAndAttribution() {
        let d = sample(body: "Hi there\nLine two.")
        XCTAssertTrue(d.body.contains("alice@example.com wrote:"),
                      "expected attribution; got: \(d.body)")
        XCTAssertTrue(d.body.contains("> Hi there"))
        XCTAssertTrue(d.body.contains("> Line two."))
    }

    // MARK: - Reply All

    func testReplyAllIncludesOriginalToAndCcExceptSelf() {
        let d = ComposePrefill.build(
            mode: .replyAll,
            originalSubject: "Sync",
            originalFrom: "alice@example.com",
            originalTo: ["bob@example.com", "carol@example.com"],
            originalCc: ["dave@example.com", "BOB@example.com"],
            originalDate: Date(),
            originalBody: "body",
            originalMessageID: "<id@x>",
            originalReferences: [],
            currentUserAddress: "bob@example.com"
        )
        // Should include alice, carol, dave but not bob (the user), and
        // shouldn't double-add bob/BOB.
        let recipients = d.to.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(Set(recipients), [
            "alice@example.com", "carol@example.com", "dave@example.com"
        ])
    }

    // MARK: - Forward

    func testForwardLeavesRecipientsEmpty() {
        let d = ComposePrefill.build(
            mode: .forward,
            originalSubject: "Q4 review",
            originalFrom: "alice@example.com",
            originalTo: ["bob@example.com"],
            originalCc: [],
            originalDate: Date(),
            originalBody: "Body text",
            originalMessageID: "<m9@x>",
            originalReferences: [],
            currentUserAddress: "me@example.com"
        )
        XCTAssertEqual(d.to, "")
        XCTAssertEqual(d.subject, "Fwd: Q4 review")
        XCTAssertNil(d.inReplyTo)
        XCTAssertTrue(d.references.isEmpty)
        XCTAssertTrue(d.body.contains("--- Forwarded message ---"))
        XCTAssertTrue(d.body.contains("Body text"))
    }

    func testForwardDoesNotDuplicateFwdPrefix() {
        let d = ComposePrefill.build(
            mode: .forward,
            originalSubject: "Fwd: already forwarded",
            originalFrom: "a@x",
            originalTo: [],
            originalCc: [],
            originalDate: Date(),
            originalBody: "",
            originalMessageID: "<m@x>",
            originalReferences: [],
            currentUserAddress: "me@example.com"
        )
        XCTAssertEqual(d.subject, "Fwd: already forwarded")
    }

    // MARK: - hasContent

    func testHasContentDetectsAnyMeaningfulField() {
        XCTAssertFalse(ComposeDraft().hasContent)
        XCTAssertTrue(ComposeDraft(to: "a@b").hasContent)
        XCTAssertTrue(ComposeDraft(body: " not empty ").hasContent)
        XCTAssertFalse(ComposeDraft(to: "   ", subject: "  ", body: " \n ").hasContent)
    }
}
