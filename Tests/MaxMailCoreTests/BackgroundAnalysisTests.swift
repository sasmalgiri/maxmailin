import XCTest
@testable import MaxMailCore

final class BackgroundAnalysisTests: XCTestCase {

    private func makeStore() throws -> MailStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bg-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try MailStore(url: dir.appendingPathComponent("mail.sqlite"))
    }

    // MARK: - Batch + progress

    func testAnalyzeBatchProcessesUnanalyzedOnly() async throws {
        let store = try makeStore()
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        for i in 0..<25 {
            _ = try await store.ingest(IngestMessage(
                accountID: acc, folder: "INBOX", messageID: "<b\(i)@x>",
                subject: "Project \(i)", fromAddress: "alice@example.com",
                date: Date().addingTimeInterval(-Double(i) * 3600),
                sizeBytes: 100,
                plainBody: "Quarterly invoice review for project number \(i). Team is happy with results."
            ))
        }

        var p = try await store.analysisProgress(accountID: acc)
        XCTAssertEqual(p.analyzed, 0)
        XCTAssertEqual(p.total, 25)

        let n1 = try await store.analyzeBatch(accountID: acc, batchSize: 10)
        XCTAssertEqual(n1, 10)
        p = try await store.analysisProgress(accountID: acc)
        XCTAssertEqual(p.analyzed, 10)

        let n2 = try await store.analyzeBatch(accountID: acc, batchSize: 100)
        XCTAssertEqual(n2, 15)
        p = try await store.analysisProgress(accountID: acc)
        XCTAssertEqual(p.analyzed, 25)
        XCTAssertEqual(p.percentComplete, 1.0)

        // Idempotent: subsequent batches find no work.
        let n3 = try await store.analyzeBatch(accountID: acc, batchSize: 100)
        XCTAssertEqual(n3, 0)
    }

    // MARK: - BackgroundAnalyzer drives to completion

    func testBackgroundAnalyzerCompletesAndReportsProgress() async throws {
        let store = try makeStore()
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        for i in 0..<60 {
            _ = try await store.ingest(IngestMessage(
                accountID: acc, folder: "INBOX", messageID: "<a\(i)@x>",
                subject: "Notes \(i)", fromAddress: "alice@example.com",
                date: Date().addingTimeInterval(-Double(i) * 3600),
                sizeBytes: 100,
                plainBody: "Meeting with Microsoft team in Seattle. Loved the discussion."
            ))
        }

        let analyzer = BackgroundAnalyzer(store: store)
        let progressLog = ProgressLog()
        await analyzer.start(accountID: acc, batchSize: 25) { p in
            await progressLog.append(p)
        }

        // Poll until the analyzer drops the task.
        for _ in 0..<200 {
            if await !analyzer.isRunning { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let stillRunning = await analyzer.isRunning
        XCTAssertFalse(stillRunning, "analyzer should have completed")

        let final = try await store.analysisProgress(accountID: acc)
        XCTAssertEqual(final.analyzed, 60)
        let logs = await progressLog.snapshot()
        XCTAssertGreaterThanOrEqual(logs.count, 1)
        XCTAssertEqual(logs.last?.analyzed, 60)
    }

    // MARK: - Aggregates

    func testAggregatesReturnSentimentDistributionAndTopTerms() async throws {
        let store = try makeStore()
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        for (i, body) in [
            "Tim Cook met with Microsoft executives. I love this idea. Fantastic work!",
            "Tim Cook flagged the urgent invoice deadline. Happy with the resolution.",
            "Disappointed with vendor. Awful experience. Terrible support from vendor.",
            "Vendor invoice review went well. Thrilled with results from the team.",
            "Quarterly invoice is overdue. Please confirm deadline soon."
        ].enumerated() {
            _ = try await store.ingest(IngestMessage(
                accountID: acc, folder: "INBOX", messageID: "<agg\(i)@x>",
                subject: "Note \(i)", fromAddress: "alice@example.com",
                date: Date().addingTimeInterval(-Double(i) * 86400),
                sizeBytes: 100, plainBody: body
            ))
        }
        // Pre-fill NLP for every message.
        var processed = 0
        repeat {
            processed = try await store.analyzeBatch(accountID: acc, batchSize: 100)
        } while processed > 0

        let progress = try await store.analysisProgress(accountID: acc)
        XCTAssertEqual(progress.analyzed, 5)

        let dist = try await store.sentimentDistribution(accountID: acc)
        XCTAssertEqual(dist.total, 5)
        XCTAssertGreaterThanOrEqual(dist.positive + dist.veryPositive, 1)
        XCTAssertGreaterThanOrEqual(dist.negative + dist.veryNegative, 1)

        let kws = try await store.topKeywords(accountID: acc, limit: 5)
        XCTAssertTrue(kws.contains(where: { $0.keyword == "invoice" }),
                      "expected invoice in keywords, got \(kws.map(\.keyword))")

        let entities = try await store.topEntities(accountID: acc, limit: 10)
        let people = entities.filter { $0.entity.kind == .person }
        XCTAssertTrue(people.contains(where: { $0.entity.text.localizedCaseInsensitiveContains("Tim") }),
                      "expected Tim Cook as person, got \(people.map(\.entity.text))")

        let timeline = try await store.sentimentTimeline(accountID: acc)
        XCTAssertGreaterThanOrEqual(timeline.count, 1)
    }
}

/// Tiny actor-backed progress log so the async callback in
/// testBackgroundAnalyzerCompletesAndReportsProgress is Sendable-clean.
private actor ProgressLog {
    private var entries: [AnalysisProgress] = []
    func append(_ p: AnalysisProgress) { entries.append(p) }
    func snapshot() -> [AnalysisProgress] { entries }
}
