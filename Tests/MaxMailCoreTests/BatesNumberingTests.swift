import XCTest
import CryptoKit
@testable import MaxMailCore

final class BatesNumberingTests: XCTestCase {

    private func tempDB() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bates-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mail.sqlite")
    }

    private func freshSecret() -> Data {
        Data(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    /// Seed `n` messages with monotonically increasing dates so the
    /// chronological-order assignment contract is testable.
    private func seedMessages(
        in store: MailStore, accountID: Int64, count: Int,
        startDate: Date = Date(timeIntervalSinceReferenceDate: 0)
    ) async throws -> [Int64] {
        var ids: [Int64] = []
        for i in 0..<count {
            let id = try await store.ingest(IngestMessage(
                accountID: accountID,
                folder: "INBOX",
                messageID: "<m-\(i)@x>",
                subject: "Hello \(i)",
                fromAddress: "alice@x",
                toAddresses: ["bob@x"],
                date: startDate.addingTimeInterval(Double(i)),
                sizeBytes: 100,
                plainBody: "Body \(i)"
            ))
            ids.append(id)
        }
        return ids
    }

    // MARK: - Format

    func testFormatNumberZeroPadsAndPrefixes() {
        let cfg = BatesConfig(prefix: "ACME", startNumber: 1, zeroPadding: 6)
        XCTAssertEqual(BatesNumberingManager.format(1, config: cfg), "ACME000001")
        XCTAssertEqual(BatesNumberingManager.format(999_999, config: cfg), "ACME999999")
        XCTAssertEqual(BatesNumberingManager.format(1_000_000, config: cfg), "ACME1000000")
    }

    func testFormatHandlesZeroPaddingFloorOfOne() {
        let cfg = BatesConfig(prefix: "X", startNumber: 1, zeroPadding: 0)
        // Padding floor of 1 keeps single digits looking like Bates numbers.
        XCTAssertEqual(BatesNumberingManager.format(7, config: cfg), "X7")
    }

    // MARK: - Assignment ordering

    func testAssignNumbersInChronologicalOrder() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        // Insert messages out of date order to verify sort is by date_unix.
        let later = try await store.ingest(IngestMessage(
            accountID: acc, folder: "INBOX", messageID: "<late@x>",
            subject: "Late", fromAddress: "a@x",
            date: Date(timeIntervalSinceReferenceDate: 100),
            sizeBytes: 1, plainBody: "L"
        ))
        let early = try await store.ingest(IngestMessage(
            accountID: acc, folder: "INBOX", messageID: "<early@x>",
            subject: "Early", fromAddress: "a@x",
            date: Date(timeIntervalSinceReferenceDate: 1),
            sizeBytes: 1, plainBody: "E"
        ))

        let audit = AuditLog(store: store, secret: freshSecret())
        let bates = BatesNumberingManager(store: store, auditLog: audit)
        let report = try await bates.assignNumbers(actor: "examiner")
        XCTAssertEqual(report.newlyAssignedCount, 2)
        XCTAssertEqual(report.firstBatesNumber, "MAILIN000001")
        XCTAssertEqual(report.lastBatesNumber,  "MAILIN000002")

        let earlyNum = try await bates.batesNumber(messageRowID: early)
        let lateNum  = try await bates.batesNumber(messageRowID: later)
        XCTAssertEqual(earlyNum, "MAILIN000001")
        XCTAssertEqual(lateNum,  "MAILIN000002")
    }

    // MARK: - Idempotency

    func testReAssignDoesNotChangeExistingNumbers() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        let ids = try await seedMessages(in: store, accountID: acc, count: 3)
        let audit = AuditLog(store: store, secret: freshSecret())
        let bates = BatesNumberingManager(store: store, auditLog: audit)
        _ = try await bates.assignNumbers(actor: "examiner")
        let firstPass = try await bates.batesNumber(messageRowID: ids[0])

        // Second pass with the same corpus is a no-op.
        let report = try await bates.assignNumbers(actor: "examiner")
        XCTAssertEqual(report.newlyAssignedCount, 0)
        XCTAssertEqual(report.alreadyAssignedCount, 3)

        let stillFirst = try await bates.batesNumber(messageRowID: ids[0])
        XCTAssertEqual(firstPass, stillFirst)
    }

    func testNewMessagesAppendToExistingSequence() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        _ = try await seedMessages(in: store, accountID: acc, count: 2)
        let audit = AuditLog(store: store, secret: freshSecret())
        let bates = BatesNumberingManager(store: store, auditLog: audit)
        _ = try await bates.assignNumbers(actor: "examiner")

        // Ingest a fresh message that postdates the previous batch.
        let fresh = try await store.ingest(IngestMessage(
            accountID: acc, folder: "INBOX", messageID: "<fresh@x>",
            subject: "Fresh", fromAddress: "a@x",
            date: Date(timeIntervalSinceReferenceDate: 999),
            sizeBytes: 1, plainBody: "F"
        ))
        let report = try await bates.assignNumbers(actor: "examiner")
        XCTAssertEqual(report.newlyAssignedCount, 1)
        XCTAssertEqual(report.firstBatesNumber, "MAILIN000003")

        let freshNum = try await bates.batesNumber(messageRowID: fresh)
        XCTAssertEqual(freshNum, "MAILIN000003")
    }

    func testLoweringStartAfterAssignmentDoesNotRollSequenceBackwards() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        _ = try await seedMessages(in: store, accountID: acc, count: 2)
        let audit = AuditLog(store: store, secret: freshSecret())
        let bates = BatesNumberingManager(store: store, auditLog: audit)
        // First batch lands at the default 1..2.
        _ = try await bates.assignNumbers(actor: "examiner")

        // Operator drops start back to 1 and reruns after seeding a new
        // message. The new message must NOT collide with the existing
        // MAILIN000001 — high-water-mark + 1 always wins over start.
        try await bates.setConfig(.init(prefix: "MAILIN", startNumber: 1, zeroPadding: 6))
        _ = try await store.ingest(IngestMessage(
            accountID: acc, folder: "INBOX", messageID: "<late@x>",
            subject: "Late", fromAddress: "a@x",
            date: Date(timeIntervalSinceReferenceDate: 999),
            sizeBytes: 1, plainBody: "L"
        ))
        let report = try await bates.assignNumbers(actor: "examiner")
        XCTAssertEqual(report.newlyAssignedCount, 1)
        XCTAssertEqual(report.firstBatesNumber, "MAILIN000003")
    }

    // MARK: - Config persistence

    func testConfigRoundTripsThroughStore() async throws {
        let store = try MailStore(url: tempDB())
        let audit = AuditLog(store: store, secret: freshSecret())
        let bates = BatesNumberingManager(store: store, auditLog: audit)
        try await bates.setConfig(.init(prefix: "ACME", startNumber: 100, zeroPadding: 4))
        let cfg = try await bates.config()
        XCTAssertEqual(cfg.prefix, "ACME")
        XCTAssertEqual(cfg.startNumber, 100)
        XCTAssertEqual(cfg.zeroPadding, 4)
    }

    // MARK: - Removal

    func testRemoveAllAssignmentsClearsAndLogs() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        _ = try await seedMessages(in: store, accountID: acc, count: 4)
        let audit = AuditLog(store: store, secret: freshSecret())
        let bates = BatesNumberingManager(store: store, auditLog: audit)
        _ = try await bates.assignNumbers(actor: "examiner")
        let removed = try await bates.removeAllAssignments(actor: "examiner",
                                                          reason: "tests")
        XCTAssertEqual(removed, 4)
        let after = try await bates.count()
        XCTAssertEqual(after, 0)

        // Audit chain still verifies even with two batches recorded.
        let v = try await audit.verify()
        XCTAssertTrue(v.isIntact)
    }

    // MARK: - Export

    func testExportBatesIndexSealsBundle() async throws {
        let store = try MailStore(url: tempDB())
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")
        _ = try await seedMessages(in: store, accountID: acc, count: 2)
        let secret = freshSecret()
        let audit = AuditLog(store: store, secret: secret)
        let signer = ExportSigner(secret: secret)
        let bates = BatesNumberingManager(store: store, auditLog: audit)
        _ = try await bates.assignNumbers(actor: "examiner")

        let bundleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bates-export-\(UUID().uuidString)", isDirectory: true)
        _ = try await bates.exportBatesIndex(
            actor: "examiner",
            bundleName: "production-001",
            bundleRoot: bundleRoot,
            signer: signer
        )

        let csvURL      = bundleRoot.appendingPathComponent("BatesIndex.csv")
        let manifestURL = bundleRoot.appendingPathComponent("manifest.json")
        let sigURL      = bundleRoot.appendingPathComponent("manifest.sig")
        XCTAssertTrue(FileManager.default.fileExists(atPath: csvURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sigURL.path))

        let csv = try String(contentsOf: csvURL)
        XCTAssertTrue(csv.contains("MAILIN000001"))
        XCTAssertTrue(csv.contains("MAILIN000002"))
        // Header row must be intact and quoting must not eat the prefix.
        XCTAssertTrue(csv.hasPrefix("BatesNumber,"))

        let manifestData = try Data(contentsOf: manifestURL)
        let sigHex = String(data: try Data(contentsOf: sigURL), encoding: .utf8) ?? ""
        let verified = await signer.verifySignature(
            manifestJSON: manifestData, signatureHex: sigHex
        )
        XCTAssertTrue(verified)
    }
}
