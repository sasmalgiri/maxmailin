import Foundation
import CryptoKit

/// Content-addressed blob store. Every blob (attachment, large body) is keyed
/// by the hex SHA-256 of its bytes. Identical content is stored once, no
/// matter how many messages reference it — mailing-list duplicates and
/// repeated attachments are deduplicated for free.
///
/// Files live two directories deep so we never have more than 256 entries per
/// directory, which keeps APFS happy at scale:
///
///     <root>/<ab>/<cd>/<ab cd ef 01 02 ...>
///
/// All operations are synchronous on top of FileManager (which is thread-safe
/// on Apple platforms when using `.default`). Marked `@unchecked Sendable`
/// because the store has no Swift-side mutable state — concurrency safety is
/// delegated to the file system. This lets the `MailStore` actor call into the
/// blob store from inside its sync SQLite transaction without an `await`.
public final class BlobStore: @unchecked Sendable {
    public let root: URL
    private let fm = FileManager.default

    public init(root: URL) throws {
        self.root = root
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Write `data` if absent, return its hex SHA-256 either way.
    /// Idempotent — duplicate puts collapse, races are tolerated.
    @discardableResult
    public func put(_ data: Data) throws -> String {
        let hex = Self.sha256Hex(data)
        let url = path(for: hex)
        if fm.fileExists(atPath: url.path) { return hex }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Write to a temp file in the same directory and atomically rename
        // so a partial write can never leave a corrupt blob under its hex.
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        do {
            try fm.moveItem(at: tmp, to: url)
        } catch {
            // Another writer may have just placed an identical blob. Clean up
            // our temp; if the destination now exists with the same hash, that's
            // a successful idempotent put.
            try? fm.removeItem(at: tmp)
            if !fm.fileExists(atPath: url.path) { throw error }
        }
        return hex
    }

    public func get(_ sha256Hex: String) -> Data? {
        try? Data(contentsOf: path(for: sha256Hex))
    }

    public func exists(_ sha256Hex: String) -> Bool {
        fm.fileExists(atPath: path(for: sha256Hex).path)
    }

    public func delete(_ sha256Hex: String) throws {
        let url = path(for: sha256Hex)
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    /// Walk every blob and total up bytes + count. O(n) over the directory
    /// tree — fine for stats and GC, not for hot paths.
    public func stats() throws -> (count: Int, bytes: Int64) {
        var count = 0
        var bytes: Int64 = 0
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return (0, 0)
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            if url.lastPathComponent.hasPrefix(".tmp-") { continue }
            count += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return (count, bytes)
    }

    // MARK: - Helpers

    private func path(for hex: String) -> URL {
        let a = hex.prefix(2)
        let b = hex.dropFirst(2).prefix(2)
        return root
            .appendingPathComponent(String(a), isDirectory: true)
            .appendingPathComponent(String(b), isDirectory: true)
            .appendingPathComponent(hex)
    }

    public static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
