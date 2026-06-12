import XCTest
@testable import MaxMailCore

final class MIMEParserTests: XCTestCase {

    // MARK: - Plain single-part

    func testSinglePartPlainText() {
        let raw = Data("""
        From: a@x
        Subject: Plain
        Content-Type: text/plain; charset="UTF-8"

        Hello world.
        """.utf8)
        let p = RFC5322Parser.parse(raw, fallbackDate: Date())
        XCTAssertEqual(p.plainBody, "Hello world.")
        XCTAssertNil(p.htmlBody)
        XCTAssertTrue(p.attachments.isEmpty)
    }

    func testQuotedPrintableTextBody() {
        let raw = Data("""
        From: a@x
        Subject: QP
        Content-Type: text/plain; charset="ISO-8859-1"
        Content-Transfer-Encoding: quoted-printable

        Caf=E9 break is the most important meeting of the day.
        """.utf8)
        let p = RFC5322Parser.parse(raw, fallbackDate: Date())
        XCTAssertEqual(p.plainBody?.contains("Café break"), true,
                       "expected QP decode → 'Café break', got \(p.plainBody ?? "nil")")
    }

    func testBase64EncodedBody() {
        let body = "SGVsbG8sIHdvcmxk"   // "Hello, world"
        let raw = Data("""
        From: a@x
        Subject: B64
        Content-Type: text/plain
        Content-Transfer-Encoding: base64

        \(body)
        """.utf8)
        let p = RFC5322Parser.parse(raw, fallbackDate: Date())
        XCTAssertEqual(p.plainBody?.trimmingCharacters(in: .whitespacesAndNewlines),
                       "Hello, world")
    }

    // MARK: - Multipart

    func testMultipartAlternativePrefersPlainAndKeepsHTML() {
        let raw = Data("""
        From: a@x
        Subject: Alt
        Content-Type: multipart/alternative; boundary="BOUND"

        --BOUND
        Content-Type: text/plain; charset=UTF-8

        Plain text version.
        --BOUND
        Content-Type: text/html; charset=UTF-8

        <html><body><p>HTML version.</p></body></html>
        --BOUND--
        """.utf8)
        let p = RFC5322Parser.parse(raw, fallbackDate: Date())
        XCTAssertEqual(p.plainBody, "Plain text version.")
        XCTAssertEqual(p.htmlBody?.contains("<p>HTML version.</p>"), true)
        XCTAssertTrue(p.attachments.isEmpty)
    }

    func testMultipartMixedExtractsAttachments() {
        // 4 bytes "PDF!" base64-encoded
        let pdfB64 = Data("PDF!".utf8).base64EncodedString()
        let raw = Data("""
        From: a@x
        Subject: With attachment
        Content-Type: multipart/mixed; boundary="MIX"

        --MIX
        Content-Type: text/plain

        See attached report.
        --MIX
        Content-Type: application/pdf; name="report.pdf"
        Content-Disposition: attachment; filename="report.pdf"
        Content-Transfer-Encoding: base64

        \(pdfB64)
        --MIX--
        """.utf8)
        let p = RFC5322Parser.parse(raw, fallbackDate: Date())
        XCTAssertEqual(p.plainBody, "See attached report.")
        XCTAssertEqual(p.attachments.count, 1)
        XCTAssertEqual(p.attachments.first?.filename, "report.pdf")
        XCTAssertEqual(p.attachments.first?.mimeType, "application/pdf")
        XCTAssertEqual(p.attachments.first?.data, Data("PDF!".utf8))
    }

    func testNestedMultipart() {
        // multipart/mixed wrapping a multipart/alternative + one attachment.
        let raw = Data("""
        From: a@x
        Subject: Nested
        Content-Type: multipart/mixed; boundary="OUTER"

        --OUTER
        Content-Type: multipart/alternative; boundary="INNER"

        --INNER
        Content-Type: text/plain

        Inner plain.
        --INNER
        Content-Type: text/html

        <p>Inner HTML.</p>
        --INNER--
        --OUTER
        Content-Type: image/png; name="logo.png"
        Content-Disposition: attachment; filename="logo.png"
        Content-Transfer-Encoding: base64

        \(Data("PNGDATA".utf8).base64EncodedString())
        --OUTER--
        """.utf8)
        let p = RFC5322Parser.parse(raw, fallbackDate: Date())
        XCTAssertEqual(p.plainBody, "Inner plain.")
        XCTAssertEqual(p.htmlBody?.contains("Inner HTML."), true)
        XCTAssertEqual(p.attachments.count, 1)
        XCTAssertEqual(p.attachments.first?.filename, "logo.png")
        XCTAssertEqual(p.attachments.first?.data, Data("PNGDATA".utf8))
    }

    // MARK: - Helpers

    func testExtractParamHandlesQuotedAndUnquoted() {
        XCTAssertEqual(MIMEParser.extractParam("text/plain; charset=\"UTF-8\"", "charset"), "UTF-8")
        XCTAssertEqual(MIMEParser.extractParam("text/plain; charset=utf-8", "charset"), "utf-8")
        XCTAssertEqual(MIMEParser.extractParam("Multipart/Mixed; Boundary=\"--xyz\"", "boundary"), "--xyz")
        XCTAssertNil(MIMEParser.extractParam("text/plain", "charset"))
    }

    // MARK: - End-to-end through MailStore + BlobStore

    func testMboxImportStoresAttachmentInBlobStore() async throws {
        let pdfB64 = Data("PDF-content-here".utf8).base64EncodedString()
        let mbox = """
        From envelope@x Mon Jan 01 12:00:00 2024
        From: alice@x.com
        Subject: With attachment
        Date: Mon, 1 Jan 2024 12:00:00 +0000
        Message-ID: <att1@x>
        Content-Type: multipart/mixed; boundary="MIX"

        --MIX
        Content-Type: text/plain

        Body of the message.
        --MIX
        Content-Type: application/pdf; name="report.pdf"
        Content-Disposition: attachment; filename="report.pdf"
        Content-Transfer-Encoding: base64

        \(pdfB64)
        --MIX--
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mime-mbox-\(UUID().uuidString).mbox")
        try mbox.data(using: .utf8)!.write(to: url)

        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mime-mbox-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let store = try MailStore(url: dbDir.appendingPathComponent("mail.sqlite"))
        let acc = try await store.upsertAccount(name: "t", address: "t@x", kind: "import")

        let importer = MboxImporter(store: store, accountID: acc,
                                    options: .init(batchSize: 50, folder: "INBOX"))
        let (n, _) = try await importer.importFile(at: url)
        XCTAssertEqual(n, 1)

        let headers = try await store.headers(in: "INBOX", accountID: acc, limit: 5)
        XCTAssertEqual(headers.count, 1)
        let refs = try await store.attachments(messageRowID: headers[0].id)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs.first?.filename, "report.pdf")
        XCTAssertEqual(refs.first?.mimeType, "application/pdf")
        XCTAssertEqual(refs.first?.sizeBytes, Int64("PDF-content-here".utf8.count))

        let bytes = await store.loadAttachmentData(sha256Hex: refs.first!.sha256Hex!)
        XCTAssertEqual(bytes, Data("PDF-content-here".utf8))

        // BlobStore should have exactly one file.
        let blobStats = try await store.blobStore.stats()
        XCTAssertEqual(blobStats.count, 1)
    }
}
