import XCTest
import CryptoKit
@testable import MaxMailCore

final class DuplicateManagerTests: XCTestCase {

    private func tempDB() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mail.sqlite")
    }

    private func freshSecret() -> Data {
        Data(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    /// Seed two duplicate clusters and three unique messages.
    private func seedCorpus(in store: MailStore, accountID: Int64) async throws
        -> (dup1: [Int64], dup2: [Int64], unique: [Int64])
    {
        var dup1: [Int64] = []
        var dup2: [Int64] = []
        var unique: [Int64] = []

        // Cluster A: alice@x — "Project update" — 3 copies, distinct dates.
        for i in 0..<3 {
            let id = try await store.ingest(IngestMessage(
                accountID: accountID, folder: "INBOX",
                messageID: "<a-\(i)@x>",
                subject: "Project update",
                fromAddress: "alice@x",
                date: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 60),
                sizeBytes: 1, plainBody: "body \(i)"
            ))
            dup1.append(id)
        }
        // Cluster B: bob@y — "Lunch?" — 2 copies.
        for i in 0..<2 {
            let id = try await store.ingest(IngestMessage(
                accountID: accountID, folder: "INBOX",
                messageID: "<b-\(i)@x>",
                subject: "Lunch?",
                fromAddress: "bob@y",
                date: Date(timeIntervalSince1970: 1_700_001_000 + Double(i) * 60),
                sizeBytes: 1, plainBody: "body \(i)"
            ))
            dup2.append(id)
        }
        // Three uniques.
        for i in 0..<3 {
            let id = try await store.ingest(IngestMessage(
                accountID: accountID, folder: "INBOX",
                messageID: "<u-\(i)@x>",
                subject: "Unique \(i)",
                fromAddress: "carol@x",
                date: Date(timeIntervalSince1970: 1_700_002_000 + Double(i) * 60),
                sizeBytes: 1, plainBody: "body \(i)"
            ))
            unique.append(id)
        }
        return (dup1, dup2, unique)
    }

    // MARK: - Detect

    func testClustersFindsSubjectAndFromGroupsLargerThanOne() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let (dup1, dup2, _) = try await seedCorpus(in: store, accountID: acc)

        let audit = AuditLog(store: store, secret: freshSecret())
        let dups = DuplicateManager(store: store, auditLog: audit)
        let clusters = try await dups.clusters(accountID: acc)

        XCTAssertEqual(clusters.count, 2)
        // Largest cluster first.
        XCTAssertEqual(clusters[0].count, 3)
        XCTAssertEqual(Set(clusters[0].messageRowIDs), Set(dup1))
        XCTAssertEqual(clusters[1].count, 2)
        XCTAssertEqual(Set(clusters[1].messageRowIDs), Set(dup2))
    }

    func testClustersExcludesEmptySubject() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        // Two messages with no subject from same sender — should NOT
        // cluster, otherwise auto-archive would silently nuke the
        // entire "no subject" set.
        for i in 0..<2 {
            _ = try await store.ingest(IngestMessage(
                accountID: acc, folder: "INBOX",
                messageID: "<n-\(i)@x>",
                subject: "",
                fromAddress: "x@x",
                date: Date(timeIntervalSince1970: 1_700_010_000 + Double(i)),
                sizeBytes: 1, plainBody: ""
            ))
        }
        let audit = AuditLog(store: store, secret: freshSecret())
        let dups = DuplicateManager(store: store, auditLog: audit)
        let clusters = try await dups.clusters(accountID: acc)
        XCTAssertTrue(clusters.isEmpty)
    }

    // MARK: - Resolve

    func testResolveKeepOldestDeletesAllButFirst() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let (dup1, dup2, _) = try await seedCorpus(in: store, accountID: acc)

        let audit = AuditLog(store: store, secret: freshSecret())
        let dups = DuplicateManager(store: store, auditLog: audit)
        let clusters = try await dups.clusters(accountID: acc)
        let report = try await dups.resolve(
            clusters: clusters, using: .keepOldest, actor: "examiner"
        )

        XCTAssertEqual(report.clustersResolved, 2)
        XCTAssertEqual(report.messagesDeleted, 2 + 1, "2 from cluster A + 1 from cluster B")
        XCTAssertEqual(report.messagesFailed, 0)

        // Verify the oldest survived in each cluster (date-ascending
        // means the first rowID in messageRowIDs).
        let surviving = (try? await store.findMessagesInvolving(
            emailAddress: "alice@x"))?.map(\.messageRowID) ?? []
        XCTAssertEqual(surviving, [dup1.first!])

        let lunch = (try? await store.findMessagesInvolving(
            emailAddress: "bob@y"))?.map(\.messageRowID) ?? []
        XCTAssertEqual(lunch, [dup2.first!])

        // Chain stays intact.
        let v = try await audit.verify()
        XCTAssertTrue(v.isIntact)
    }

    func testResolveKeepNewestDeletesAllButLast() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let (dup1, _, _) = try await seedCorpus(in: store, accountID: acc)

        let audit = AuditLog(store: store, secret: freshSecret())
        let dups = DuplicateManager(store: store, auditLog: audit)
        let clusters = try await dups.clusters(accountID: acc)
        _ = try await dups.resolve(
            clusters: clusters, using: .keepNewest, actor: "examiner"
        )

        let surviving = (try? await store.findMessagesInvolving(
            emailAddress: "alice@x"))?.map(\.messageRowID) ?? []
        // The newest message in cluster A survives.
        XCTAssertEqual(surviving, [dup1.last!])
    }

    func testResolveIsNoOpWhenClusterListIsEmpty() async throws {
        let store = try MailStore(url: tempDB())
        let audit = AuditLog(store: store, secret: freshSecret())
        let dups = DuplicateManager(store: store, auditLog: audit)
        let report = try await dups.resolve(
            clusters: [], using: .keepOldest, actor: "examiner"
        )
        XCTAssertEqual(report.clustersResolved, 0)
        XCTAssertEqual(report.messagesDeleted, 0)
    }
}
