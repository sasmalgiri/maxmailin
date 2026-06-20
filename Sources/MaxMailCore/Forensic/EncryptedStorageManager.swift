import Foundation
import CryptoKit

/// AES-GCM at-rest encryption for blob payloads. Owns a 32-byte symmetric
/// key and a concrete `BlobEncrypter` that BlobStore can be wired with.
///
/// Scope and honest caveats:
/// - This encrypts every file inside the BlobStore (attachments + large
///   bodies + every signed export bundle we write through the same
///   store). Each file's bytes are an AES-GCM sealed box; tampering on
///   disk shows up as a decryption failure on read.
/// - It does NOT encrypt the SQLite database itself. Subject lines,
///   from/to, plain_body, html_body, audit log entries, Bates rows
///   still live in cleartext SQLite. Full DB-at-rest encryption needs
///   SQLCipher or an Apple Encrypted Disk Image — both add link-time
///   dependencies and ship-side complexity that the Core layer
///   shouldn't take on by default.
/// - The key lifecycle is the caller's responsibility: persist it in
///   the Keychain at the app layer, rotate via `makeKey()`, encrypt the
///   key with the user's passphrase before storage if you need
///   protection against an attacker with macOS user access.
///
/// Filename addressing is unchanged: BlobStore still names files by
/// SHA-256 of the *plaintext*, so two messages that reference the same
/// attachment still dedupe even when the on-disk bytes are different
/// sealed-box instances (different nonces).
public struct EncryptedStorageManager: Sendable {

    public let key: SymmetricKey

    public init(key: SymmetricKey) {
        self.key = key
    }

    /// Build a manager from raw key bytes (32-byte). Returns nil when
    /// the input is the wrong length so callers can fail fast rather
    /// than instantiate a key that will produce silent decrypt errors.
    public init?(rawKey: Data) {
        guard rawKey.count == 32 else { return nil }
        self.key = SymmetricKey(data: rawKey)
    }

    /// Generate a fresh 256-bit key. Caller persists it (Keychain or
    /// passphrase-wrapped on disk). Used for first-time setup and for
    /// the rotate flow.
    public static func makeKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    /// Concrete BlobEncrypter that BlobStore plugs into. Each call to
    /// encrypt produces a fresh nonce — the same plaintext encrypted
    /// twice yields different ciphertexts, but BlobStore deduplicates
    /// by *plaintext* SHA-256, so identical content collapses to one
    /// file before encryption is ever invoked twice.
    public func encrypter() -> BlobEncrypter {
        Encrypter(key: key)
    }

    /// Direct encrypt / decrypt helpers. Same semantics as the
    /// BlobEncrypter conformance but exposed for callers that want to
    /// seal one-off blobs (e.g., a future "encrypted export bundle"
    /// pathway) without going through BlobStore.
    public func encrypt(_ data: Data) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else {
            throw EncryptedStorageError.sealReturnedNoCombinedForm
        }
        return combined
    }

    public func decrypt(_ data: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: key)
    }

    private struct Encrypter: BlobEncrypter {
        let key: SymmetricKey
        func encrypt(_ data: Data) throws -> Data {
            let sealed = try AES.GCM.seal(data, using: key)
            guard let combined = sealed.combined else {
                throw EncryptedStorageError.sealReturnedNoCombinedForm
            }
            return combined
        }
        func decrypt(_ data: Data) throws -> Data {
            let box = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(box, using: key)
        }
    }
}

public enum EncryptedStorageError: Error, Equatable {
    /// AES.GCM.seal returned a SealedBox without a `combined`
    /// representation — only happens with non-standard nonce sizes.
    /// We never opt into non-default nonces, so this signals a
    /// CryptoKit-side surprise that the caller should report.
    case sealReturnedNoCombinedForm
}
