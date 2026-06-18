import XCTest
@testable import MaxMailCore

final class AutomationRulesTests: XCTestCase {

    // MARK: - Matcher

    private func snap(from: String = "a@x", subject: String = "S",
                      body: String = "b", attach: Bool = false) -> RuleMatcher.MessageSnapshot {
        .init(subject: subject, fromAddress: from, plainBody: body, hasAttachment: attach)
    }

    private func rule(name: String = "r",
                      conditions: RuleConditions,
                      actions: RuleActions = RuleActions(markSeen: true),
                      enabled: Bool = true) -> AutomationRule {
        AutomationRule(accountID: 1, name: name, enabled: enabled, priority: 0,
                       conditions: conditions, actions: actions)
    }

    func testMatchesFromContainsCaseInsensitive() {
        let r = rule(conditions: RuleConditions(fromContains: ["BOSS@COMPANY"]))
        XCTAssertTrue(RuleMatcher.matches(r, snap(from: "boss@company.com")))
        XCTAssertFalse(RuleMatcher.matches(r, snap(from: "other@company.com")))
    }

    func testMatchesAndCombinatorAcrossMultipleCriteria() {
        let r = rule(conditions: RuleConditions(
            fromContains: ["@vendor.com"],
            subjectContains: ["invoice"],
            hasAttachment: true,
            combinator: .and
        ))
        XCTAssertTrue(RuleMatcher.matches(r, snap(
            from: "billing@vendor.com",
            subject: "Q4 invoice attached",
            attach: true
        )))
        XCTAssertFalse(RuleMatcher.matches(r, snap(
            from: "billing@vendor.com",
            subject: "Q4 invoice attached",
            attach: false
        )))
    }

    func testMatchesOrCombinatorRequiresOnlyOne() {
        let r = rule(conditions: RuleConditions(
            fromContains: ["@vendor.com"],
            subjectContains: ["urgent"],
            combinator: .or
        ))
        XCTAssertTrue(RuleMatcher.matches(r, snap(
            from: "anyone@nope.com",
            subject: "urgent: please review",
            attach: false
        )))
        XCTAssertTrue(RuleMatcher.matches(r, snap(
            from: "billing@vendor.com",
            subject: "Hi",
            attach: false
        )))
        XCTAssertFalse(RuleMatcher.matches(r, snap(
            from: "x@y.com",
            subject: "Hi",
            attach: false
        )))
    }

    func testDisabledRuleNeverMatches() {
        let r = rule(conditions: RuleConditions(fromContains: ["a@x"]),
                     enabled: false)
        XCTAssertFalse(RuleMatcher.matches(r, snap(from: "a@x")))
    }

    func testRuleWithNoConditionsMatchesNothing() {
        let r = rule(conditions: RuleConditions())
        XCTAssertFalse(RuleMatcher.matches(r, snap()))
    }

    // MARK: - Store CRUD + sweep

    private func tempStore() throws -> MailStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rules-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try MailStore(url: dir.appendingPathComponent("mail.sqlite"))
    }

    @discardableResult
    private func ingest(_ store: MailStore, account: Int64, from: String,
                       subject: String = "S", body: String = "B",
                       attach: Bool = false, idSuffix: String = UUID().uuidString
    ) async throws -> Int64 {
        let flags: MessageFlags = attach ? [.hasAttachment] : []
        return try await store.ingest(IngestMessage(
            accountID: account, folder: "INBOX",
            messageID: "<\(idSuffix)@x>",
            subject: subject, fromAddress: from,
            date: Date(), sizeBytes: 100,
            flags: flags, plainBody: body
        ))
    }

    func testAddAndListRulesPersists() async throws {
        let store = try tempStore()
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let id = try await store.addRule(AutomationRule(
            accountID: acc, name: "Boss",
            conditions: RuleConditions(fromContains: ["boss@"]),
            actions: RuleActions(markFlagged: true)
        ))
        XCTAssertNotEqual(id, 0)
        let listed = try await store.rules(accountID: acc)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.name, "Boss")
        XCTAssertTrue(listed.first?.actions.markFlagged ?? false)
    }

    func testSweepMarksMatchingMessagesAndIsIdempotent() async throws {
        let store = try tempStore()
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        _ = try await store.addRule(AutomationRule(
            accountID: acc, name: "Boss flag",
            conditions: RuleConditions(fromContains: ["boss@"]),
            actions: RuleActions(markFlagged: true)
        ))

        let bossID = try await ingest(store, account: acc, from: "boss@co.com",
                                       idSuffix: "boss1")
        let otherID = try await ingest(store, account: acc, from: "newsletter@x",
                                       idSuffix: "n1")

        let applied = try await store.applyRulesBatch(accountID: acc)
        XCTAssertEqual(applied, 1, "only the boss message should match")

        let bossFlags = try await store.messageFlags(messageRowID: bossID) ?? []
        XCTAssertTrue(bossFlags.contains(.flagged))
        let otherFlags = try await store.messageFlags(messageRowID: otherID) ?? []
        XCTAssertFalse(otherFlags.contains(.flagged))

        // Sweep again: both messages already logged, no new applications.
        let second = try await store.applyRulesBatch(accountID: acc)
        XCTAssertEqual(second, 0, "second sweep should be idempotent")
    }

    func testSweepMovesMessageIntoNewFolder() async throws {
        let store = try tempStore()
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        _ = try await store.addRule(AutomationRule(
            accountID: acc, name: "Receipts",
            conditions: RuleConditions(fromContains: ["receipts@"]),
            actions: RuleActions(moveToFolder: "Receipts")
        ))
        let receipt = try await ingest(store, account: acc, from: "receipts@stripe.com",
                                       idSuffix: "r1")
        _ = try await ingest(store, account: acc, from: "x@y", idSuffix: "x1")

        _ = try await store.applyRulesBatch(accountID: acc)
        let receiptsHeaders = try await store.headers(in: "Receipts", accountID: acc, limit: 10)
        XCTAssertEqual(receiptsHeaders.first?.id, receipt)
        let inboxHeaders = try await store.headers(in: "INBOX", accountID: acc, limit: 10)
        XCTAssertFalse(inboxHeaders.contains { $0.id == receipt },
                       "receipt should have left INBOX")
    }
}
