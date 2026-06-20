import XCTest
@testable import MaxMailCore

final class EntityResolverTests: XCTestCase {

    // MARK: - Parse

    func testParseBareAddress() {
        let r = EntityResolver.parse("alex@acme.com")
        XCTAssertEqual(r?.address, "alex@acme.com")
        XCTAssertNil(r?.displayName)
    }

    func testParseBracketedAddressWithName() {
        let r = EntityResolver.parse("Alex Morgan <alex@acme.com>")
        XCTAssertEqual(r?.address, "alex@acme.com")
        XCTAssertEqual(r?.displayName, "Alex Morgan")
    }

    func testParseQuotedDisplayName() {
        let r = EntityResolver.parse("\"Alex Morgan\" <alex@acme.com>")
        XCTAssertEqual(r?.address, "alex@acme.com")
        XCTAssertEqual(r?.displayName, "Alex Morgan")
    }

    func testParseTolerantOfSurroundingWhitespace() {
        let r = EntityResolver.parse("   alex@acme.com   ")
        XCTAssertEqual(r?.address, "alex@acme.com")
    }

    func testParseRejectsTokensWithoutAtSign() {
        XCTAssertNil(EntityResolver.parse("Confidential"))
        XCTAssertNil(EntityResolver.parse(""))
    }

    // MARK: - Normalize

    func testNormalizeCaseFoldsAndStripsSubaddress() {
        XCTAssertEqual(EntityResolver.normalize("Alex+Work@Acme.com"),
                       "alex@acme.com")
    }

    func testNormalizeStripsDotsOnGmailOnly() {
        XCTAssertEqual(EntityResolver.normalize("al.ex.morgan@gmail.com"),
                       "alexmorgan@gmail.com")
        XCTAssertEqual(EntityResolver.normalize("al.ex.morgan@googlemail.com"),
                       "alexmorgan@googlemail.com")
        // Non-Gmail domain keeps dots — they're real to most providers.
        XCTAssertEqual(EntityResolver.normalize("al.ex@acme.com"),
                       "al.ex@acme.com")
    }

    func testNormalizeLeavesAddressWithoutAtUnchanged() {
        XCTAssertEqual(EntityResolver.normalize("nope"), "nope")
    }

    // MARK: - Resolve

    func testResolveClustersSubaddressAliasesUnderOneIdentity() {
        let rows: [MailStore.CorrespondentRow] = [
            .init(rawHeaderValue: "alex+work@acme.com", messageCount: 12),
            .init(rawHeaderValue: "Alex Morgan <alex@acme.com>", messageCount: 5),
            .init(rawHeaderValue: "ALEX@ACME.COM", messageCount: 1)
        ]
        let ids = EntityResolver.resolve(rows)
        XCTAssertEqual(ids.count, 1)
        let id = ids[0]
        XCTAssertEqual(id.canonical, "alex@acme.com")
        XCTAssertEqual(id.messageCount, 18)
        XCTAssertEqual(id.displayName, "Alex Morgan")
        XCTAssertEqual(Set(id.aliases),
                       ["alex+work@acme.com", "alex@acme.com", "alex@acme.com".lowercased()])
    }

    func testResolveSortsByDescendingMessageCount() {
        let rows: [MailStore.CorrespondentRow] = [
            .init(rawHeaderValue: "small@x", messageCount: 1),
            .init(rawHeaderValue: "big@x", messageCount: 100),
            .init(rawHeaderValue: "mid@x", messageCount: 10)
        ]
        let ids = EntityResolver.resolve(rows)
        XCTAssertEqual(ids.map(\.canonical), ["big@x", "mid@x", "small@x"])
    }

    func testResolveKeepsLongestNameAsDisplayName() {
        let rows: [MailStore.CorrespondentRow] = [
            .init(rawHeaderValue: "alex@acme.com", messageCount: 1),
            .init(rawHeaderValue: "Alex <alex@acme.com>", messageCount: 1),
            .init(rawHeaderValue: "Alex Morgan <alex@acme.com>", messageCount: 1)
        ]
        let ids = EntityResolver.resolve(rows)
        XCTAssertEqual(ids.first?.displayName, "Alex Morgan")
    }

    func testResolveSkipsUnparseableRowsButPreservesOthers() {
        let rows: [MailStore.CorrespondentRow] = [
            .init(rawHeaderValue: "noaddress", messageCount: 99),
            .init(rawHeaderValue: "alex@acme.com", messageCount: 3)
        ]
        let ids = EntityResolver.resolve(rows)
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(ids[0].canonical, "alex@acme.com")
    }
}
