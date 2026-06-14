import XCTest
@testable import MaxMailCore

final class ForensicAnalyzerTests: XCTestCase {

    // MARK: - Phishing

    func testCleanMessageReturnsNone() {
        let r = EmailForensicAnalyzer.analyze(
            subject: "Project update",
            fromAddress: "alice@example.com",
            plainBody: "Hi, attached is the project plan for next quarter.",
            htmlBody: nil
        )
        XCTAssertEqual(r.phishing.level, .none)
        XCTAssertTrue(r.pii.isEmpty)
    }

    func testUrgencyAndCredentialPhrasesEscalate() {
        let r = EmailForensicAnalyzer.analyze(
            subject: "URGENT: account suspended",
            fromAddress: "noreply@bank-secure.example",
            plainBody: """
            Your account will be suspended unless you click here to verify
            your details immediately. Please confirm your details and enter
            your password within 24 hours.
            """,
            htmlBody: nil
        )
        XCTAssertNotEqual(r.phishing.level, .none, "got \(r.phishing)")
        XCTAssertGreaterThanOrEqual(r.phishing.score, 7)
        XCTAssertTrue(r.phishing.reasons.contains { $0.kind == .urgency })
        XCTAssertTrue(r.phishing.reasons.contains { $0.kind == .credentialHarvest })
    }

    func testBrandImpersonationFlagsWrongDomain() {
        let r = EmailForensicAnalyzer.analyze(
            subject: "PayPal: action required on your account",
            fromAddress: "support@xyz-unrelated.com",
            plainBody: "Please log in to resolve the issue.",
            htmlBody: nil
        )
        XCTAssertTrue(r.phishing.reasons.contains { $0.kind == .brandImpersonation },
                      "got \(r.phishing.reasons)")
    }

    func testBrandImpersonationDoesNotFlagLegitimateDomain() {
        let r = EmailForensicAnalyzer.analyze(
            subject: "PayPal: receipt for your purchase",
            fromAddress: "noreply@paypal.com",
            plainBody: "Thanks for your payment.",
            htmlBody: nil
        )
        XCTAssertFalse(r.phishing.reasons.contains { $0.kind == .brandImpersonation })
    }

    func testSuspiciousURLs() {
        let raw = EmailForensicAnalyzer.detectPhishing(
            subject: "Login",
            fromAddress: "x@x.com",
            plainBody: "Sign in at https://203.0.113.45/login or https://bit.ly/abcd or http://example.com@bad.example",
            htmlBody: ""
        )
        XCTAssertTrue(raw.reasons.contains { $0.kind == .urlRawIP })
        XCTAssertTrue(raw.reasons.contains { $0.kind == .urlShortener })
        XCTAssertTrue(raw.reasons.contains { $0.kind == .urlAtSymbol })
    }

    func testLinkTextMismatch() {
        let html = """
        <html><body><p>Click here:
        <a href="https://evil.example/login">https://paypal.com/login</a>
        </p></body></html>
        """
        let r = EmailForensicAnalyzer.detectPhishing(
            subject: "Verify your account",
            fromAddress: "support@nobody.example",
            plainBody: "",
            htmlBody: html
        )
        XCTAssertTrue(r.reasons.contains { $0.kind == .linkTextMismatch }, "got \(r.reasons)")
    }

    // MARK: - PII

    func testPIIDetectsCommonTypesWithLuhn() {
        let body = """
        My SSN is 123-45-6789, please call me at (415) 555-2671. Send to
        alice@example.com. My visa is 4111 1111 1111 1111. IBAN GB82 WEST
        1234 5698 7654 32. Server is at 8.8.8.8.
        """
        let findings = EmailForensicAnalyzer.detectPII(plainBody: body, htmlBody: "")
        let kinds = Set(findings.map(\.kind))
        XCTAssertTrue(kinds.contains(.ssn))
        XCTAssertTrue(kinds.contains(.phone))
        XCTAssertTrue(kinds.contains(.email))
        XCTAssertTrue(kinds.contains(.creditCard), "Luhn-valid PAN should be detected")
        XCTAssertTrue(kinds.contains(.iban))
        XCTAssertTrue(kinds.contains(.ipAddress))
    }

    func testInvalidLuhnCreditCardIsIgnored() {
        // Sequential digits — fails the Luhn checksum.
        let body = "Card 1234 5678 9012 3456 should be ignored."
        let findings = EmailForensicAnalyzer.detectPII(plainBody: body, htmlBody: "")
        XCTAssertFalse(findings.contains { $0.kind == .creditCard })
    }

    func testPrivateIPRangesAreIgnored() {
        let body = "Hit the gateway at 192.168.1.1 or 10.0.0.1 or 127.0.0.1"
        let findings = EmailForensicAnalyzer.detectPII(plainBody: body, htmlBody: "")
        XCTAssertFalse(findings.contains { $0.kind == .ipAddress },
                       "RFC 1918 and loopback should be filtered out")
    }

    // MARK: - End-to-end via MailStore

    func testEnsureForensicsCachesAndProcessBatchHandlesBoth() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("forensic-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try MailStore(url: dir.appendingPathComponent("mail.sqlite"))
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "local")

        let phishingID = try await store.ingest(IngestMessage(
            accountID: acc, folder: "INBOX", messageID: "<phish@x>",
            subject: "URGENT verify your account",
            fromAddress: "noreply@xyz-unrelated.example",
            date: Date(), sizeBytes: 100,
            plainBody: """
            Your PayPal account is suspended. Click here to verify your
            password immediately at https://203.0.113.10/verify or
            we will close it within 24 hours.
            """
        ))
        let cleanID = try await store.ingest(IngestMessage(
            accountID: acc, folder: "INBOX", messageID: "<clean@x>",
            subject: "Lunch?",
            fromAddress: "carol@example.com",
            date: Date(), sizeBytes: 100,
            plainBody: "Pizza later this week?"
        ))

        // First call computes; second returns cached identical result.
        let f1 = try await store.ensureForensics(messageRowID: phishingID)
        let f2 = try await store.ensureForensics(messageRowID: phishingID)
        XCTAssertEqual(f1, f2)
        XCTAssertNotEqual(f1.phishing.level, .none)

        let clean = try await store.ensureForensics(messageRowID: cleanID)
        XCTAssertEqual(clean.phishing.level, .none)
        XCTAssertTrue(clean.pii.isEmpty)

        // processBatch handles both NLP and forensics in one walk.
        // Fresh DB to test the combined batch path.
        let dir2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("forensic-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        let store2 = try MailStore(url: dir2.appendingPathComponent("mail.sqlite"))
        let acc2 = try await store2.upsertAccount(name: "T", address: "t@x", kind: "local")
        for i in 0..<6 {
            _ = try await store2.ingest(IngestMessage(
                accountID: acc2, folder: "INBOX", messageID: "<m\(i)@x>",
                subject: "Note \(i)", fromAddress: "alice@example.com",
                date: Date(), sizeBytes: 100,
                plainBody: "Project status looks great with steady progress."
            ))
        }
        let processed = try await store2.processBatch(accountID: acc2, batchSize: 10)
        XCTAssertEqual(processed, 6)
        let p = try await store2.processingProgress(accountID: acc2)
        XCTAssertEqual(p.analyzed, 6)
        XCTAssertEqual(p.total, 6)
    }
}
