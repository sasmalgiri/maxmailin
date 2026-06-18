import Foundation

/// Streaming `.emlx` importer for Apple Mail archives.
///
/// EMLX layout (Apple Mail since ~2006):
///   <length>\n     <- 10-byte ASCII decimal byte count
///   <RFC 5322 message bytes of that length>
///   <optional plist metadata>
///
/// Some early EMLX files omit the length prefix entirely; we detect that
/// by checking whether the first line is a pure decimal number that
/// matches the remaining file size.
///
/// Streaming discipline matches the mbox importer: a directory of EMLX
/// files is walked lazily, each file is parsed alone, and the resulting
/// IngestMessage flows into `MailStore.bulkIngest` in batches. Memory is
/// bounded by `batchSize × per-message body size`; a 100 GB Apple Mail
/// archive doesn't blow up.
public final class EMLXImporter: @unchecked Sendable {

    public struct Progress: Sendable {
        public let filesScanned: Int
        public let filesIngested: Int
        public let filesFailed: Int
        public let secondsElapsed: TimeInterval
    }

    public struct Options: Sendable {
        public var batchSize: Int = 500
        public var folder: String = "Imported (EMLX)"
        public init() {}
        public init(batchSize: Int, folder: String) {
            self.batchSize = batchSize
            self.folder = folder
        }
    }

    private let store: MailStore
    private let accountID: Int64
    private let options: Options

    public init(store: MailStore, accountID: Int64, options: Options = Options()) {
        self.store = store
        self.accountID = accountID
        self.options = options
    }

    /// Import either a single `.emlx` file or every `.emlx` under a
    /// directory. Returns the (ingested, failed) counts.
    @discardableResult
    public func importPath(
        _ url: URL,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> (ingested: Int64, failed: Int64) {
        let started = Date()
        let urls = try resolveEMLXURLs(at: url)
        var batch: [IngestMessage] = []
        batch.reserveCapacity(options.batchSize)
        var ingested: Int64 = 0
        var failed: Int64 = 0
        var scanned = 0

        for fileURL in urls {
            scanned += 1
            do {
                let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
                let body = Self.stripLengthPrefix(data)
                let fallback = (try? FileManager.default
                    .attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date)
                    ?? Date()
                let parsed = RFC5322Parser.parse(body, fallbackDate: fallback)
                batch.append(IngestMessage(
                    accountID: accountID,
                    folder: options.folder,
                    messageID: parsed.messageID,
                    inReplyTo: parsed.inReplyTo,
                    references: parsed.references,
                    subject: parsed.subject,
                    fromAddress: parsed.fromAddress,
                    toAddresses: parsed.toAddresses,
                    ccAddresses: parsed.ccAddresses,
                    date: parsed.date,
                    sizeBytes: parsed.sizeBytes,
                    flags: parsed.attachments.isEmpty ? [] : .hasAttachment,
                    plainBody: parsed.plainBody,
                    htmlBody: parsed.htmlBody,
                    attachments: parsed.attachments
                ))
            } catch {
                failed += 1
            }

            if batch.count >= options.batchSize {
                ingested += Int64(try await store.bulkIngest(batch))
                batch.removeAll(keepingCapacity: true)
                onProgress?(Progress(
                    filesScanned: scanned,
                    filesIngested: Int(ingested),
                    filesFailed: Int(failed),
                    secondsElapsed: -started.timeIntervalSinceNow
                ))
            }
        }
        if !batch.isEmpty {
            ingested += Int64(try await store.bulkIngest(batch))
        }
        onProgress?(Progress(
            filesScanned: scanned,
            filesIngested: Int(ingested),
            filesFailed: Int(failed),
            secondsElapsed: -started.timeIntervalSinceNow
        ))
        return (ingested, failed)
    }

    // MARK: - File walking

    private func resolveEMLXURLs(at url: URL) throws -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return []
        }
        if !isDir.boolValue {
            // Single file: accept either `.emlx` or anything (caller asked
            // explicitly for this path).
            return [url]
        }
        // Walk the directory tree non-eagerly via enumerator.
        var out: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = fm.enumerator(at: url,
                                             includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles])
        else { return [] }
        for case let item as URL in enumerator {
            if item.pathExtension.lowercased() == "emlx" {
                out.append(item)
            }
        }
        return out
    }

    // MARK: - EMLX length-prefix handling

    /// Strip the optional EMLX length prefix. If the first line is a
    /// decimal length and the remaining file is at least that long, take
    /// exactly `length` bytes after the newline (which is the RFC 5322
    /// payload). Otherwise return the file unchanged.
    static func stripLengthPrefix(_ data: Data) -> Data {
        guard let nl = data.firstIndex(of: 0x0A) else { return data }
        let header = data.subdata(in: data.startIndex..<nl)
        guard let headerText = String(data: header, encoding: .ascii) else {
            return data
        }
        let trimmed = headerText.trimmingCharacters(in: .whitespaces)
        guard let length = Int(trimmed), length > 0 else {
            return data
        }
        let bodyStart = nl + 1
        let available = data.count - bodyStart
        guard length <= available else {
            // The "length" was bogus — treat as no prefix.
            return data
        }
        return data.subdata(in: bodyStart..<(bodyStart + length))
    }
}
