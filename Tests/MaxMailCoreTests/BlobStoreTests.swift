import XCTest
@testable import MaxMailCore

final class BlobStoreTests: XCTestCase {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("maxmailin-blob-tests-\(UUID().uuidString)", isDirectory: true)
    }

    func testPutGetRoundTrip() async throws {
        let store = try BlobStore(root: tempRoot())
        let data = Data("hello world".utf8)
        let hex = try await store.put(data)
        XCTAssertEqual(hex.count, 64)
        let exists = await store.exists(hex)
        XCTAssertTrue(exists)
        let got = await store.get(hex)
        XCTAssertEqual(got, data)
    }

    func testIdenticalContentDeduplicates() async throws {
        let root = tempRoot()
        let store = try BlobStore(root: root)
        let data = Data(repeating: 0x41, count: 1024)
        let hex1 = try await store.put(data)
        let hex2 = try await store.put(data)
        XCTAssertEqual(hex1, hex2)
        let stats = try await store.stats()
        XCTAssertEqual(stats.count, 1, "second put with identical bytes must not create a second blob")
        XCTAssertEqual(stats.bytes, 1024)
    }

    func testTwoLevelDirectoryShape() async throws {
        let root = tempRoot()
        let store = try BlobStore(root: root)
        let hex = try await store.put(Data("anything".utf8))
        // Expect path: <root>/<ab>/<cd>/<hex>
        let a = String(hex.prefix(2))
        let b = String(hex.dropFirst(2).prefix(2))
        let expected = root
            .appendingPathComponent(a)
            .appendingPathComponent(b)
            .appendingPathComponent(hex)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path),
                      "blob must live at <root>/<aa>/<bb>/<hex>")
    }

    func testDeleteRemovesBlob() async throws {
        let store = try BlobStore(root: tempRoot())
        let hex = try await store.put(Data("delete me".utf8))
        let existedBefore = await store.exists(hex)
        XCTAssertTrue(existedBefore)
        try await store.delete(hex)
        let existsAfter = await store.exists(hex)
        XCTAssertFalse(existsAfter)
        let got = await store.get(hex)
        XCTAssertNil(got)
    }

    func testKnownVector() {
        // SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        let hex = BlobStore.sha256Hex(Data("abc".utf8))
        XCTAssertEqual(hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
