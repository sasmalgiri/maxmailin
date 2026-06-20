import XCTest
import CryptoKit
@testable import MaxMailCore

final class EncryptedStorageTests: XCTestCase {

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("enc-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: - Direct encrypt/decrypt

    func testEncryptDecryptRoundTrip() throws {
        let mgr = EncryptedStorageManager(key: EncryptedStorageManager.makeKey())
        let payload = Data("the quick brown fox jumps over the lazy dog".utf8)
        let cipher = try mgr.encrypt(payload)
        XCTAssertNotEqual(cipher, payload)
        XCTAssertEqual(try mgr.decrypt(cipher), payload)
    }

    func testDecryptWithWrongKeyThrows() throws {
        let a = EncryptedStorageManager(key: EncryptedStorageManager.makeKey())
        let b = EncryptedStorageManager(key: EncryptedStorageManager.makeKey())
        let payload = Data("secrets".utf8)
        let cipher = try a.encrypt(payload)
        XCTAssertThrowsError(try b.decrypt(cipher))
    }

    func testInitFromRawKeyRequires32Bytes() {
        XCTAssertNil(EncryptedStorageManager(rawKey: Data(repeating: 0, count: 16)))
        XCTAssertNotNil(EncryptedStorageManager(rawKey: Data(repeating: 0, count: 32)))
    }

    // MARK: - BlobStore wiring

    func testBlobStoreReadsBackPlaintextThroughEncrypter() throws {
        let dir = tempDir()
        let mgr = EncryptedStorageManager(key: EncryptedStorageManager.makeKey())
        let store = try BlobStore(root: dir, encrypter: mgr.encrypter())

        let payload = Data("important attachment".utf8)
        let hex = try store.put(payload)
        // Filename is SHA-256 of plaintext.
        XCTAssertEqual(hex, BlobStore.sha256Hex(payload))

        // get() returns the original plaintext.
        XCTAssertEqual(store.get(hex), payload)
    }

    func testBlobStoreEncryptedFileIsNotPlaintextOnDisk() throws {
        let dir = tempDir()
        let mgr = EncryptedStorageManager(key: EncryptedStorageManager.makeKey())
        let store = try BlobStore(root: dir, encrypter: mgr.encrypter())
        let payload = Data("super secret".utf8)
        let hex = try store.put(payload)

        // Walk the dir to find the file.
        let url = try findFile(in: dir, named: hex)
        let bytes = try Data(contentsOf: url)
        XCTAssertNotEqual(bytes, payload, "on-disk bytes must be ciphertext")
        XCTAssertGreaterThan(bytes.count, payload.count,
                             "AES-GCM seal adds nonce + tag overhead")
    }

    func testBlobStoreDedupesByPlaintextEvenWhenEncrypted() throws {
        let dir = tempDir()
        let mgr = EncryptedStorageManager(key: EncryptedStorageManager.makeKey())
        let store = try BlobStore(root: dir, encrypter: mgr.encrypter())
        let payload = Data("dup".utf8)
        let h1 = try store.put(payload)
        let h2 = try store.put(payload)
        XCTAssertEqual(h1, h2, "same plaintext must produce the same hex")
        let stats = try store.stats()
        XCTAssertEqual(stats.count, 1, "second put is a no-op")
    }

    func testBlobStoreWithoutEncrypterRemainsBackwardsCompatible() throws {
        // The encrypter is opt-in; existing clients that construct
        // BlobStore the old way must continue working unchanged.
        let dir = tempDir()
        let store = try BlobStore(root: dir)
        let payload = Data("plaintext".utf8)
        let hex = try store.put(payload)
        let url = try findFile(in: dir, named: hex)
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(store.get(hex), payload)
    }

    // MARK: - Helpers

    private func findFile(in root: URL, named: String) throws -> URL {
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: root,
                                       includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in enumerator
            where url.lastPathComponent == named { return url }
        XCTFail("blob \(named) not found under \(root.path)")
        throw CocoaError(.fileReadNoSuchFile)
    }
}
