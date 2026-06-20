import XCTest
import CryptoKit
@testable import MaxMailCore

final class InvestigationReportTests: XCTestCase {

    private func tempDB() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("investigation-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mail.sqlite")
    }

    private func freshSecret() -> Data {
        Data(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    private func seedCorpus(in store: MailStore, accountID: Int64) async throws -> [Int64] {
        var ids: [Int64] = []
        for i in 0..<6 {
            // Spread the messages across two adjacent months so the
            // monthly histogram has more than one bucket.
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            let date = base.addingTimeInterval(Double(i) * 86_400 * 20)
            let id = try await store.ingest(IngestMessage(
                accountID: accountID, folder: "INBOX",
                messageID: "<m-\(i)@x>",
                subject: "Hello \(i)",
                fromAddress: i % 2 == 0 ? "alice@x" : "bob@y",
                toAddresses: ["examiner@x"],
                date: date,
                sizeBytes: 100,
                plainBody: "Body \(i)"
            ))
            ids.append(id)
        }
        return ids
    }

    // MARK: - Empty store

    func testGenerateOnEmptyAccountStillReturnsCoherentReport() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let secret = freshSecret()
        let audit = AuditLog(store: store, secret: secret)
        let gen = InvestigationReportGenerator(store: store, auditLog: audit)

        let report = try await gen.generate(
            accountID: acc, accountAddress: "t@x",
            title: "Empty case", caseNumber: "C-001", examiner: "examiner"
        )

        XCTAssertEqual(report.totalMessages, 0)
        XCTAssertTrue(report.monthlyVolume.isEmpty)
        XCTAssertTrue(report.topSenders.isEmpty)
        XCTAssertNil(report.bates)
        XCTAssertTrue(report.evidenceMarkers.isEmpty)
        XCTAssertTrue(report.auditSummary.isIntact,
                       "chain should be intact even with just the generation entry")
    }

    // MARK: - Populated

    func testGenerateAggregatesVolumeSendersBatesAndEvidence() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let ids = try await seedCorpus(in: store, accountID: acc)

        let secret = freshSecret()
        let audit = AuditLog(store: store, secret: secret)
        let custody = ChainOfCustodyManager(store: store, auditLog: audit)
        let bates = BatesNumberingManager(store: store, auditLog: audit)
        let gen = InvestigationReportGenerator(store: store, auditLog: audit)

        // Tag two as evidence + mark one privileged.
        _ = try await custody.recordEvent(
            kind: .taggedAsEvidence, actor: "examiner",
            subjectKind: "message", subjectID: String(ids[0]),
            description: "Smoking gun"
        )
        _ = try await custody.recordEvent(
            kind: .taggedAsEvidence, actor: "examiner",
            subjectKind: "message", subjectID: String(ids[1]),
            description: "Follow-up"
        )
        _ = try await custody.recordEvent(
            kind: .markedPrivileged, actor: "examiner",
            subjectKind: "message", subjectID: String(ids[2]),
            description: "Counsel involved"
        )
        // Seal one — should NOT appear in evidence markers (different kind).
        _ = try await custody.sealMessages(rowIDs: [ids[3]], actor: "examiner")

        // Assign Bates so the report's Bates range is non-nil.
        _ = try await bates.assignNumbers(accountID: acc, actor: "examiner")

        let report = try await gen.generate(
            accountID: acc, accountAddress: "t@x",
            title: "Case 42", caseNumber: "C-042", examiner: "examiner"
        )

        XCTAssertEqual(report.totalMessages, 6)
        XCTAssertFalse(report.monthlyVolume.isEmpty,
                       "monthly histogram should have at least one bucket")
        XCTAssertEqual(report.monthlyVolume.reduce(0) { $0 + Int($1.count) }, 6,
                       "monthly buckets must sum to total messages")

        // Two senders (alice@x and bob@y) — verify both appear.
        let addresses = Set(report.topSenders.map(\.address))
        XCTAssertTrue(addresses.contains("alice@x"))
        XCTAssertTrue(addresses.contains("bob@y"))

        // Evidence markers: exactly 3 (2 tagged + 1 privileged). Seal
        // entries do NOT show up here.
        XCTAssertEqual(report.evidenceMarkers.count, 3)
        XCTAssertTrue(report.evidenceMarkers.contains { $0.kind == "tagged_as_evidence" })
        XCTAssertTrue(report.evidenceMarkers.contains { $0.kind == "marked_privileged" })

        XCTAssertNotNil(report.bates)
        XCTAssertEqual(report.bates?.count, 6)
        XCTAssertEqual(report.bates?.first, "MAILIN000001")
        XCTAssertEqual(report.bates?.last,  "MAILIN000006")

        XCTAssertTrue(report.auditSummary.isIntact)
        XCTAssertEqual(report.header.caseNumber, "C-042")
    }

    // MARK: - Export

    func testExportBundleProducesSignedJSONAndCSVs() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        _ = try await seedCorpus(in: store, accountID: acc)

        let secret = freshSecret()
        let audit = AuditLog(store: store, secret: secret)
        let signer = ExportSigner(secret: secret)
        let gen = InvestigationReportGenerator(store: store, auditLog: audit)

        let report = try await gen.generate(
            accountID: acc, accountAddress: "t@x",
            title: "Case X", caseNumber: "C-X", examiner: "examiner"
        )

        let bundleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("inv-export-\(UUID().uuidString)", isDirectory: true)
        _ = try await gen.exportBundle(
            actor: "examiner", bundleName: "case-x-2026-06",
            bundleRoot: bundleRoot, report: report, signer: signer
        )

        for name in ["case.json", "monthly.csv", "top_senders.csv",
                     "evidence.csv", "manifest.json", "manifest.sig"] {
            let url = bundleRoot.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "missing \(name) in bundle")
        }

        // JSON round-trips back into the same model.
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let jsonURL = bundleRoot.appendingPathComponent("case.json")
        let decoded = try dec.decode(InvestigationCaseReport.self,
                                     from: try Data(contentsOf: jsonURL))
        XCTAssertEqual(decoded.header.caseNumber, "C-X")
        XCTAssertEqual(decoded.totalMessages, 6)

        // Manifest signature must verify with the same secret.
        let manifest = try Data(contentsOf: bundleRoot.appendingPathComponent("manifest.json"))
        let sigHex = String(data: try Data(contentsOf: bundleRoot.appendingPathComponent("manifest.sig")),
                            encoding: .utf8) ?? ""
        let verified = await signer.verifySignature(
            manifestJSON: manifest, signatureHex: sigHex
        )
        XCTAssertTrue(verified)
    }
}
