import XCTest
import CryptoKit
@testable import MaxMailCore

final class AuditLogTests: XCTestCase {

    private func makeStore() throws -> MailStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try MailStore(url: dir.appendingPathComponent("mail.sqlite"))
    }

    private func freshSecret() -> Data {
        Data(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    // MARK: - Chain integrity

    func testRecordAndVerifyChain() async throws {
        let store = try makeStore()
        let log = AuditLog(store: store, secret: freshSecret())

        let first = try await log.record(
            actor: "alice",
            action: "tag",
            subjectKind: "message",
            subjectID: "<m1@x>",
            details: ["tag": "privileged"]
        )
        XCTAssertEqual(first.prevHash, AuditLog.genesisHash)
        XCTAssertEqual(first.entryHash.count, 64)

        let second = try await log.record(
            actor: "alice", action: "annotate",
            subjectKind: "message", subjectID: "<m1@x>",
            details: ["note": "exhibit A"]
        )
        XCTAssertEqual(second.prevHash, first.entryHash)
        XCTAssertNotEqual(second.entryHash, first.entryHash)

        let verification = try await log.verify()
        XCTAssertTrue(verification.isIntact)
        XCTAssertEqual(verification.totalEntries, 2)
        XCTAssertNil(verification.firstTamperedID)
    }

    func testTamperingABreaksTheChain() async throws {
        let secret = freshSecret()
        let store = try makeStore()
        let log = AuditLog(store: store, secret: secret)

        for i in 0..<5 {
            _ = try await log.record(
                actor: "examiner",
                action: "tag",
                subjectKind: "message",
                subjectID: "<m\(i)@x>",
                details: [:]
            )
        }
        // Sanity: clean chain.
        var verify = try await log.verify()
        XCTAssertTrue(verify.isIntact, "clean chain should verify")

        // Tamper directly with the SQL — flip an actor on entry 3.
        try await store._testOverwriteAuditActor(rowID: 3, newActor: "mallory")

        verify = try await log.verify()
        XCTAssertFalse(verify.isIntact)
        XCTAssertEqual(verify.firstTamperedID, 3,
                       "first detected mismatch should be entry 3")
    }

    func testWrongSecretFailsVerification() async throws {
        let store = try makeStore()
        let goodLog = AuditLog(store: store, secret: freshSecret())
        _ = try await goodLog.record(
            actor: "a", action: "x", subjectKind: "m", subjectID: "1"
        )
        let attacker = AuditLog(store: store, secret: freshSecret())
        let v = try await attacker.verify()
        XCTAssertFalse(v.isIntact)
        XCTAssertEqual(v.firstTamperedID, 1)
    }
}

