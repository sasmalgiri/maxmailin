import XCTest
@testable import MaxMailCore

final class EMLXImporterTests: XCTestCase {

    // MARK: - stripLengthPrefix

    func testPrefixStrippedWhenLengthMatchesPayload() {
        let body = Data("From: a@x\r\nSubject: hello\r\n\r\nbody".utf8)
        var prefixed = Data("\(body.count)\n".utf8)
        prefixed.append(body)
        prefixed.append(Data("trailing plist".utf8))
        XCTAssertEqual(EMLXImporter.stripLengthPrefix(prefixed), body)
    }

    func testNoPrefixWhenFirstLineIsNotNumeric() {
        let raw = Data("From: a@x\r\nSubject: t\r\n\r\nbody".utf8)
        XCTAssertEqual(EMLXImporter.stripLengthPrefix(raw), raw)
    }

    func testNoPrefixWhenAdvertisedLengthOverrunsFile() {
        var bogus = Data("99999\n".utf8)
        bogus.append(Data("short body".utf8))
        // We can't honour the bogus 99999 — return data unchanged so the
        // RFC 5322 parser can still try its best.
        XCTAssertEqual(EMLXImporter.stripLengthPrefix(bogus), bogus)
    }

    // MARK: - End-to-end against a temp directory

    func testImporterIngestsEMLXDirectory() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("emlx-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Two EMLX files: one with prefix, one without.
        let one = Data("""
        From: alice@example.com
        Subject: First
        Message-ID: <e1@x>
        Date: Mon, 1 Jan 2024 12:00:00 +0000

        Hello first message.
        """.utf8)
        let oneWithPrefix: Data = {
            var p = Data("\(one.count)\n".utf8)
            p.append(one)
            p.append(Data("<plist/>".utf8))
            return p
        }()
        try oneWithPrefix.write(to: dir.appendingPathComponent("a.emlx"))

        let two = Data("""
        From: bob@example.com
        Subject: Second
        Message-ID: <e2@x>
        Date: Tue, 2 Jan 2024 12:00:00 +0000

        Hello second.
        """.utf8)
        try two.write(to: dir.appendingPathComponent("b.emlx"))

        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("emlx-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let store = try MailStore(url: storeDir.appendingPathComponent("mail.sqlite"))
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "import")
        let importer = EMLXImporter(store: store, accountID: acc)
        let (ingested, failed) = try await importer.importPath(dir)
        XCTAssertEqual(ingested, 2)
        XCTAssertEqual(failed, 0)

        let headers = try await store.headers(in: "Imported (EMLX)", accountID: acc, limit: 5)
        XCTAssertEqual(headers.count, 2)
        XCTAssertEqual(
            Set(headers.map(\.subject)),
            Set(["First", "Second"])
        )
    }

    func testImporterIsIdempotentOnReimport() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("emlx-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = Data("""
        From: a@x
        Subject: dup
        Message-ID: <dup@x>
        Date: Mon, 1 Jan 2024 12:00:00 +0000

        body
        """.utf8)
        try data.write(to: dir.appendingPathComponent("x.emlx"))

        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("emlx-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let store = try MailStore(url: storeDir.appendingPathComponent("mail.sqlite"))
        let acc = try await store.upsertAccount(name: "T", address: "t@x", kind: "import")
        let importer = EMLXImporter(store: store, accountID: acc)
        let first = try await importer.importPath(dir)
        XCTAssertEqual(first.ingested, 1)
        // Re-import the same dir — bulkIngest's (account, message_id)
        // dedupe means zero new rows.
        let second = try await importer.importPath(dir)
        XCTAssertEqual(second.ingested, 0)
        let stats = try await store.stats()
        XCTAssertEqual(stats.messageCount, 1)
    }
}
