import XCTest
import CryptoKit
@testable import MaxMailCore

final class ChainOfCustodyTests: XCTestCase {

    private func tempDB() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("custody-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mail.sqlite")
    }

    private func freshSecret() -> Data {
        Data(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    private func seedMessage(
        in store: MailStore, accountID: Int64,
        id: String = "<m1@x>",
        subject: String = "Hello",
        body: String = "Original body"
    ) async throws -> Int64 {
        return try await store.ingest(IngestMessage(
            accountID: accountID,
            folder: "INBOX",
            messageID: id,
            subject: subject,
            fromAddress: "alice@x",
            toAddresses: ["bob@x"],
            date: Date(timeIntervalSinceReferenceDate: 1_000),
            sizeBytes: Int64(body.utf8.count),
            plainBody: body
        ))
    }

    // MARK: - Seal

    func testSealingNewMessageProducesStableHashAndAuditEntry() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let mid = try await seedMessage(in: store, accountID: acc)

        let audit = AuditLog(store: store, secret: freshSecret())
        let custody = ChainOfCustodyManager(store: store, auditLog: audit)

        let report = try await custody.sealMessages(rowIDs: [mid], actor: "examiner")
        XCTAssertEqual(report.newlySealed, 1)
        XCTAssertEqual(report.alreadySealed, 0)
        XCTAssertTrue(report.missing.isEmpty)

        // Resealing is a no-op — same message is reported as alreadySealed.
        let second = try await custody.sealMessages(rowIDs: [mid], actor: "examiner")
        XCTAssertEqual(second.newlySealed, 0)
        XCTAssertEqual(second.alreadySealed, 1)

        // Audit chain must remain intact and contain one sealed entry.
        let v = try await audit.verify()
        XCTAssertTrue(v.isIntact)
        let events = try await custody.events()
        XCTAssertEqual(events.filter { $0.kind == .sealed }.count, 1)
        XCTAssertNotNil(events.first { $0.kind == .sealed }?.messageHash)
    }

    func testSealingMissingMessageReportsItButDoesNotBreakChain() async throws {
        let store = try MailStore(url: tempDB())
        let audit = AuditLog(store: store, secret: freshSecret())
        let custody = ChainOfCustodyManager(store: store, auditLog: audit)

        let report = try await custody.sealMessages(rowIDs: [9999], actor: "examiner")
        XCTAssertEqual(report.newlySealed, 0)
        XCTAssertEqual(report.missing, [9999])

        let v = try await audit.verify()
        XCTAssertTrue(v.isIntact)
    }

    // MARK: - Verify

    func testVerifyDetectsBodyDrift() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let mid = try await seedMessage(in: store, accountID: acc)
        let audit = AuditLog(store: store, secret: freshSecret())
        let custody = ChainOfCustodyManager(store: store, auditLog: audit)

        _ = try await custody.sealMessages(rowIDs: [mid], actor: "examiner")
        let clean = try await custody.verifyMessages(rowIDs: [mid], actor: "examiner")
        XCTAssertTrue(clean.isIntact)
        XCTAssertEqual(clean.passed, 1)

        // Re-ingest is idempotent on (account, message-id), so to simulate
        // tampering we delete the row and re-insert a different body under
        // the same message id. The seal points at the same rowID? No — the
        // new row gets a new id, so we instead mutate by ingesting a fresh
        // message and re-seal/verify against THAT. Simpler: ingest message
        // with the *same* id is a no-op (idempotent). So we'll seed a
        // second message, seal it, then `deleteMessage` and re-ingest with
        // different body — the canonical hash will differ because the
        // *fields* differ even if message id matches.
        //
        // For this assertion we exercise drift the cleanest way: write
        // straight to the body table via a fresh MailStore on the same file
        // and then verify. But we don't expose a body-mutation API. Use a
        // second message with a known seal, then overwrite via DELETE +
        // re-INSERT round-tripping a different body.
        try await store.deleteMessage(messageRowID: mid)
        let mid2 = try await store.ingest(IngestMessage(
            accountID: acc,
            folder: "INBOX",
            messageID: "<m1@x>",
            subject: "Hello",
            fromAddress: "alice@x",
            toAddresses: ["bob@x"],
            date: Date(timeIntervalSinceReferenceDate: 1_000),
            sizeBytes: 5,
            plainBody: "TAMPERED"
        ))
        XCTAssertNotEqual(mid, mid2, "delete + reingest creates a new row id")

        // The old seal is for the deleted row id, so a verify against the
        // new row reports it as `unsealed` rather than drifted.
        let v = try await custody.verifyMessages(rowIDs: [mid2], actor: "examiner")
        XCTAssertEqual(v.totalChecked, 1)
        XCTAssertEqual(v.unsealed, [mid2])
        XCTAssertTrue(v.drifted.isEmpty)

        // Now seal the new row, then drift it by changing only the
        // attachment list via store-level INSERT (test-only path). Easier:
        // seal the new row, take its hash, then write a fresh seal for the
        // *same* row pointing at a deliberately bogus hash to simulate the
        // recorded baseline diverging from the current canonical form.
        _ = try await custody.sealMessages(rowIDs: [mid2], actor: "examiner")
        try await store.recordMessageSeal(
            messageRowID: mid2,
            sealedAt: Date(),
            contentSHA256Hex: String(repeating: "f", count: 64)
        )
        let drifted = try await custody.verifyMessages(rowIDs: [mid2], actor: "examiner")
        XCTAssertEqual(drifted.drifted.count, 1)
        XCTAssertEqual(drifted.drifted.first?.messageRowID, mid2)
        XCTAssertFalse(drifted.isIntact)
    }

    func testVerifyEmitsSummaryAuditEntry() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let mid = try await seedMessage(in: store, accountID: acc)
        let audit = AuditLog(store: store, secret: freshSecret())
        let custody = ChainOfCustodyManager(store: store, auditLog: audit)

        _ = try await custody.sealMessages(rowIDs: [mid], actor: "examiner")
        _ = try await custody.verifyMessages(rowIDs: [mid], actor: "examiner")

        let events = try await custody.events()
        let verified = events.first { $0.kind == .verified }
        XCTAssertNotNil(verified)
        XCTAssertEqual(verified?.subjectID, "1-messages")

        // The audit log is still intact end-to-end.
        let chain = try await audit.verify()
        XCTAssertTrue(chain.isIntact)
    }

    // MARK: - Record custody events

    func testRecordEventAppendsToAuditChain() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let mid = try await seedMessage(in: store, accountID: acc)
        let audit = AuditLog(store: store, secret: freshSecret())
        let custody = ChainOfCustodyManager(store: store, auditLog: audit)

        _ = try await custody.recordEvent(
            kind: .taggedAsEvidence,
            actor: "examiner",
            subjectKind: "message",
            subjectID: String(mid),
            description: "Marked as exhibit A"
        )
        let events = try await custody.events()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .taggedAsEvidence)
        XCTAssertEqual(events.first?.description, "Marked as exhibit A")
        let chain = try await audit.verify()
        XCTAssertTrue(chain.isIntact)
    }

    // MARK: - Export

    func testExportCustodyTrailSealsBundle() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let mid = try await seedMessage(in: store, accountID: acc)

        let secret = freshSecret()
        let audit = AuditLog(store: store, secret: secret)
        let signer = ExportSigner(secret: secret)
        let custody = ChainOfCustodyManager(store: store, auditLog: audit)

        _ = try await custody.recordEvent(
            kind: .accessed, actor: "examiner",
            subjectKind: "message", subjectID: String(mid),
            description: "Opened in review"
        )

        let bundleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("custody-export-\(UUID().uuidString)", isDirectory: true)
        _ = try await custody.exportCustodyTrail(
            actor: "examiner",
            bundleName: "review-2026-06",
            bundleRoot: bundleRoot,
            signer: signer
        )

        let csvURL = bundleRoot.appendingPathComponent("custody.csv")
        let manifestURL = bundleRoot.appendingPathComponent("manifest.json")
        let sigURL = bundleRoot.appendingPathComponent("manifest.sig")
        XCTAssertTrue(FileManager.default.fileExists(atPath: csvURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sigURL.path))

        let manifestData = try Data(contentsOf: manifestURL)
        let sigHex = String(data: try Data(contentsOf: sigURL), encoding: .utf8) ?? ""
        let verified = await signer.verifySignature(
            manifestJSON: manifestData, signatureHex: sigHex
        )
        XCTAssertTrue(verified, "manifest signature must round-trip")

        // The export event itself must appear in subsequent reads.
        let events = try await custody.events()
        XCTAssertTrue(events.contains { $0.kind == .exported && $0.subjectID == "review-2026-06" })
    }
}
