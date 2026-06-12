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
public actor BlobStore {
    public let root: URL
    private let fm = FileManager.default

    public init(root: URL) throws {
        self.root = root
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Write `data` if absent, return its hex SHA-256 either way.
    /// Idempotent — calling twice with the same bytes is a no-op.
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
            try? fm.removeItem(at: tmp)
            throw error
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
