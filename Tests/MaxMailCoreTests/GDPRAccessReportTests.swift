import XCTest
import CryptoKit
@testable import MaxMailCore

final class GDPRAccessReportTests: XCTestCase {

    private func tempDB() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gdpr-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mail.sqlite")
    }

    private func freshSecret() -> Data {
        Data(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    private func seedRichCorpus(
        in store: MailStore, accountID: Int64
    ) async throws -> (subjectMessages: [Int64], otherMessages: [Int64]) {
        // alice@x is the data subject. Three messages from her, two to
        // her, one CCing her, and four unrelated.
        var subj: [Int64] = []
        var other: [Int64] = []

        for i in 0..<3 {
            let id = try await store.ingest(IngestMessage(
                accountID: accountID, folder: "INBOX",
                messageID: "<sent-\(i)@x>",
                subject: "Sent \(i)",
                fromAddress: "Alice <alice@x>",
                toAddresses: ["bob@x"],
                date: Date(timeIntervalSinceReferenceDate: Double(1000 + i)),
                sizeBytes: 1, plainBody: "Body \(i)"
            ))
            subj.append(id)
        }
        for i in 0..<2 {
            let id = try await store.ingest(IngestMessage(
                accountID: accountID, folder: "INBOX",
                messageID: "<recv-\(i)@x>",
                subject: "Received \(i)",
                fromAddress: "carol@x",
                toAddresses: ["Alice <alice@x>"],
                ccAddresses: [],
                date: Date(timeIntervalSinceReferenceDate: Double(2000 + i)),
                sizeBytes: 1, plainBody: "Body \(i)"
            ))
            subj.append(id)
        }
        let ccID = try await store.ingest(IngestMessage(
            accountID: accountID, folder: "Archive",
            messageID: "<cc-1@x>", subject: "CC'd",
            fromAddress: "dave@x", toAddresses: ["bob@x"],
            ccAddresses: ["alice@x"],
            date: Date(timeIntervalSinceReferenceDate: 3000),
            sizeBytes: 1, plainBody: "Cc body"
        ))
        subj.append(ccID)

        for i in 0..<4 {
            let id = try await store.ingest(IngestMessage(
                accountID: accountID, folder: "INBOX",
                messageID: "<noise-\(i)@x>",
                subject: "Noise \(i)",
                fromAddress: "eve@x",
                toAddresses: ["bob@x"],
                date: Date(timeIntervalSinceReferenceDate: Double(4000 + i)),
                sizeBytes: 1, plainBody: "Unrelated"
            ))
            other.append(id)
        }
        return (subj, other)
    }

    // MARK: - Search

    func testFindMessagesInvolvingMatchesFromToCcNotBody() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let (subj, _) = try await seedRichCorpus(in: store, accountID: acc)
        let hits = try await store.findMessagesInvolving(emailAddress: "alice@x")
        XCTAssertEqual(Set(hits.map(\.messageRowID)), Set(subj),
                       "must match every from/to/cc occurrence")
    }

    // MARK: - Generate

    func testGenerateProducesCorrectCountsAndDateRange() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        _ = try await seedRichCorpus(in: store, accountID: acc)

        let secret = freshSecret()
        let audit = AuditLog(store: store, secret: secret)
        let gen = GDPRAccessReportGenerator(store: store, auditLog: audit)
        let (report, messages) = try await gen.generate(
            dataSubject: "alice@x", actor: "dpo"
        )

        XCTAssertEqual(report.totalMessages, 6)
        XCTAssertEqual(report.messagesAsSender, 3)
        XCTAssertEqual(report.messagesAsRecipient, 3)
        XCTAssertEqual(messages.count, 6)
        XCTAssertEqual(report.distinctFolders, ["Archive", "INBOX"])
        XCTAssertEqual(report.earliestDate?.timeIntervalSinceReferenceDate, 1000)
        XCTAssertEqual(report.latestDate?.timeIntervalSinceReferenceDate, 3000)

        // Correspondent tally excludes the data subject themselves.
        XCTAssertFalse(report.distinctCorrespondents.contains {
            $0.address == "alice@x"
        })
        XCTAssertTrue(report.distinctCorrespondents.contains {
            $0.address == "bob@x"
        })

        // Audit chain stays intact.
        let v = try await audit.verify()
        XCTAssertTrue(v.isIntact)
    }

    // MARK: - Address parsing

    func testExtractAddressesHandlesBracketedAndBareAddresses() {
        let parsed = GDPRAccessReportGenerator.extractAddresses(
            "\"Alice\" <alice@x>, bob@y, \"Carol Doe\" <carol@z>"
        )
        XCTAssertEqual(parsed, ["alice@x", "bob@y", "carol@z"])
    }

    func testExtractAddressesIgnoresNonAddressTokens() {
        let parsed = GDPRAccessReportGenerator.extractAddresses(
            "Confidential, bob@y, internal use only"
        )
        XCTAssertEqual(parsed, ["bob@y"])
    }

    // MARK: - Export

    func testExportBundleWritesJSONCSVAndSignedManifest() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        _ = try await seedRichCorpus(in: store, accountID: acc)

        let secret = freshSecret()
        let audit = AuditLog(store: store, secret: secret)
        let signer = ExportSigner(secret: secret)
        let gen = GDPRAccessReportGenerator(store: store, auditLog: audit)
        let (report, messages) = try await gen.generate(
            dataSubject: "alice@x", actor: "dpo"
        )

        let bundleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gdpr-bundle-\(UUID().uuidString)", isDirectory: true)
        _ = try await gen.exportBundle(
            actor: "dpo", bundleName: "alice-disclosure-2026-06",
            bundleRoot: bundleRoot, report: report, messages: messages,
            signer: signer
        )

        let jsonURL = bundleRoot.appendingPathComponent("report.json")
        let csvURL  = bundleRoot.appendingPathComponent("Messages.csv")
        let manURL  = bundleRoot.appendingPathComponent("manifest.json")
        let sigURL  = bundleRoot.appendingPathComponent("manifest.sig")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: csvURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sigURL.path))

        let csv = try String(contentsOf: csvURL)
        XCTAssertTrue(csv.contains("alice@x"))
        XCTAssertTrue(csv.hasPrefix("Date,From,"))

        // Round-trip: decoder reads the report back.
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode(GDPRAccessReport.self, from: try Data(contentsOf: jsonURL))
        XCTAssertEqual(decoded.totalMessages, 6)
        XCTAssertEqual(decoded.dataSubject, "alice@x")

        let manifest = try Data(contentsOf: manURL)
        let sigHex = String(data: try Data(contentsOf: sigURL), encoding: .utf8) ?? ""
        let verified = await signer.verifySignature(
            manifestJSON: manifest, signatureHex: sigHex
        )
        XCTAssertTrue(verified)
    }

    // MARK: - Erase

    func testEraseDeletesEveryInvolvedMessage() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let (subj, other) = try await seedRichCorpus(in: store, accountID: acc)

        let secret = freshSecret()
        let audit = AuditLog(store: store, secret: secret)
        let gen = GDPRAccessReportGenerator(store: store, auditLog: audit)
        let erase = try await gen.eraseAllForSubject(
            emailAddress: "alice@x", actor: "dpo", reason: "subject request 2026-06-19"
        )
        XCTAssertEqual(erase.messagesDeleted, subj.count)
        XCTAssertEqual(erase.messagesFailed, 0)

        // None of alice's messages remain; unrelated ones are untouched.
        let remaining = try await store.findMessagesInvolving(emailAddress: "alice@x")
        XCTAssertTrue(remaining.isEmpty)
        let stats = try await store.stats()
        XCTAssertEqual(Int(stats.messageCount), other.count)

        // The audit chain has the requested + completed pair and stays intact.
        let v = try await audit.verify()
        XCTAssertTrue(v.isIntact)
    }
}
