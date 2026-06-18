import Foundation
import CryptoKit

/// Manifest entry for one file in an export bundle.
public struct ExportFileRecord: Codable, Sendable, Hashable {
    public let path: String      // relative to the bundle root
    public let sizeBytes: Int64
    public let sha256Hex: String

    public init(path: String, sizeBytes: Int64, sha256Hex: String) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.sha256Hex = sha256Hex
    }
}

/// Top-level manifest. Items + creator metadata; verified by a sibling
/// signature file.
public struct ExportManifest: Codable, Sendable {
    public let createdAt: Date
    public let actor: String
    public let bundleName: String
    public let items: [ExportFileRecord]

    public init(createdAt: Date, actor: String, bundleName: String,
                items: [ExportFileRecord]) {
        self.createdAt = createdAt
        self.actor = actor
        self.bundleName = bundleName
        self.items = items
    }
}

/// Produces a SHA-256/HMAC-signed manifest for an exported set of files.
///
/// The export bundle layout is:
///   <bundle>/
///     manifest.json       — JSON-encoded ExportManifest
///     manifest.sig        — hex HMAC-SHA256 of manifest.json bytes
///     <data files…>
///
/// Sealing a bundle: caller hands ExportSigner a list of file URLs +
/// their target relative paths. ExportSigner streams each file through
/// SHA-256 (no whole-file load — files of any size are fine), builds the
/// manifest, JSON-encodes it deterministically, then HMACs the encoded
/// bytes with the per-installation secret. Verification recomputes both
/// the per-file SHA-256s and the manifest HMAC.
public actor ExportSigner {

    private let secret: SymmetricKey

    public init(secret: Data) {
        self.secret = SymmetricKey(data: secret)
    }

    public struct InputFile: Sendable {
        public let relativePath: String
        public let url: URL
        public init(relativePath: String, url: URL) {
            self.relativePath = relativePath
            self.url = url
        }
    }

    public struct Result: Sendable {
        public let manifestJSON: Data
        public let signatureHex: String
    }

    public func seal(
        actor: String,
        bundleName: String,
        files: [InputFile],
        at date: Date = Date()
    ) async throws -> Result {
        var records: [ExportFileRecord] = []
        records.reserveCapacity(files.count)
        for input in files {
            let (size, hex) = try Self.hashFile(input.url)
            records.append(ExportFileRecord(
                path: input.relativePath, sizeBytes: size, sha256Hex: hex
            ))
        }
        let manifest = ExportManifest(
            createdAt: date, actor: actor,
            bundleName: bundleName, items: records
        )
        let encoder = Self.deterministicEncoder()
        let manifestJSON = try encoder.encode(manifest)
        let sig = HMAC<SHA256>.authenticationCode(for: manifestJSON, using: secret)
        let sigHex = sig.map { String(format: "%02x", $0) }.joined()
        return Result(manifestJSON: manifestJSON, signatureHex: sigHex)
    }

    /// Re-derive the signature from `manifestJSON` and compare. The path
    /// references on disk are *not* re-hashed here — that's a separate
    /// `verifyContents` step you can call before opening the bundle.
    public func verifySignature(manifestJSON: Data, signatureHex: String) -> Bool {
        let sig = HMAC<SHA256>.authenticationCode(for: manifestJSON, using: secret)
        let expected = sig.map { String(format: "%02x", $0) }.joined()
        return expected == signatureHex
    }

    /// Recompute each file's SHA-256 and compare to what the manifest
    /// recorded. Returns the list of paths whose contents have changed.
    public func verifyContents(
        manifest: ExportManifest,
        bundleRoot: URL
    ) async throws -> [String] {
        var drifted: [String] = []
        for item in manifest.items {
            let url = bundleRoot.appendingPathComponent(item.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                drifted.append(item.path)
                continue
            }
            let (_, hex) = try Self.hashFile(url)
            if hex != item.sha256Hex {
                drifted.append(item.path)
            }
        }
        return drifted
    }

    // MARK: - File hashing (streaming)

    /// Stream a file through SHA-256 — never holds more than 64 KB in
    /// memory, so a multi-GB attachment hashes without growing the heap.
    static func hashFile(_ url: URL) throws -> (size: Int64, sha256Hex: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            total += Int64(chunk.count)
        }
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return (total, hex)
    }

    /// JSONEncoder with stable key ordering + ISO-8601 dates. Without
    /// `sortedKeys`, JSONEncoder produces non-deterministic output and
    /// the manifest's signature would drift across runs.
    static func deterministicEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
