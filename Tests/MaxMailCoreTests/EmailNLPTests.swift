import XCTest
@testable import MaxMailCore

final class EmailNLPTests: XCTestCase {

    // MARK: - Sentiment

    func testSentimentSeparatesPositiveAndNegative() {
        let happy = EmailNLPAnalyzer.sentimentScore("""
        I love this idea. Fantastic work — the team is delighted with the results.
        This is wonderful news and I'm really happy.
        """)
        let angry = EmailNLPAnalyzer.sentimentScore("""
        I am very disappointed and frustrated. The product is terrible.
        We had a horrible experience. The support was awful.
        """)
        XCTAssertGreaterThan(happy, 0.1, "expected positive sentiment, got \(happy)")
        XCTAssertLessThan(angry, -0.1, "expected negative sentiment, got \(angry)")
    }

    func testMoodBucketing() {
        XCTAssertEqual(EmailNLP(sentiment:  0.9, language: nil, entities: [], keywords: []).mood, .veryPositive)
        XCTAssertEqual(EmailNLP(sentiment:  0.3, language: nil, entities: [], keywords: []).mood, .positive)
        XCTAssertEqual(EmailNLP(sentiment:  0.0, language: nil, entities: [], keywords: []).mood, .neutral)
        XCTAssertEqual(EmailNLP(sentiment: -0.3, language: nil, entities: [], keywords: []).mood, .negative)
        XCTAssertEqual(EmailNLP(sentiment: -0.9, language: nil, entities: [], keywords: []).mood, .veryNegative)
    }

    // MARK: - Language

    func testLanguageDetection() {
        XCTAssertEqual(
            EmailNLPAnalyzer.detectLanguage("The quarterly invoice review is scheduled for next Tuesday."),
            "en"
        )
    }

    // MARK: - Entities

    func testEntitiesExtractPeopleAndOrganizationsAndPlaces() {
        let text = "Tim Cook met with Microsoft executives in Seattle last week."
        let entities = EmailNLPAnalyzer.extractEntities(text)
        let people = entities.filter { $0.kind == .person }.map { $0.text }
        let orgs   = entities.filter { $0.kind == .organization }.map { $0.text }
        let places = entities.filter { $0.kind == .place }.map { $0.text }
        XCTAssertTrue(people.contains(where: { $0.contains("Tim") }), "expected person, got \(people)")
        XCTAssertTrue(orgs.contains(where: { $0.lowercased().contains("microsoft") }), "expected org, got \(orgs)")
        XCTAssertTrue(places.contains(where: { $0.contains("Seattle") }), "expected place, got \(places)")
    }

    // MARK: - Keywords

    func testKeywordsPickFrequentNounsAndIgnoreStopWords() {
        // "invoice" appears most; "deadline" second; common short words like
        // "the", "and", "for" should not appear in the result.
        let text = """
        The quarterly invoice is overdue. Please review the invoice and confirm
        the deadline. The invoice deadline matters because budget approvals
        cannot proceed without the signed invoice.
        """
        let kws = EmailNLPAnalyzer.extractKeywords(text, limit: 5)
        XCTAssertTrue(kws.contains("invoice"), "got \(kws)")
        XCTAssertFalse(kws.contains("the"))
        XCTAssertFalse(kws.contains("and"))
    }

    // MARK: - End-to-end via MailStore

    func testEnsureNLPCachesAndReturnsConsistentResults() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nlp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try MailStore(url: dir.appendingPathComponent("mail.sqlite"))
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let id = try await store.ingest(IngestMessage(
            accountID: acc, folder: "INBOX", messageID: "<n1@x>",
            subject: "Quarterly invoice review",
            fromAddress: "alice@example.com",
            date: Date(), sizeBytes: 100,
            plainBody: """
            Tim Cook met with Microsoft executives in Seattle. The quarterly
            invoice review is overdue and the deadline is tight. Please
            confirm the invoice and the new deadline by Friday. This is great
            progress and I'm pleased with the team.
            """
        ))

        let first = try await store.ensureNLP(messageRowID: id)
        XCTAssertEqual(first.language, "en")
        XCTAssertGreaterThan(first.sentiment, -1.0)
        XCTAssertLessThan(first.sentiment, 1.0)
        XCTAssertTrue(first.entities.contains { $0.kind == .organization })
        XCTAssertTrue(first.keywords.contains("invoice"))

        // Second call must hit the cache and return the same payload.
        let second = try await store.ensureNLP(messageRowID: id)
        XCTAssertEqual(first, second)

        let cached = try await store.loadNLP(messageRowID: id)
        XCTAssertEqual(cached, first)
    }
}
