import Foundation

/// High-level mbox import driver. Streams messages out of an mbox file via
/// `MboxStream`, parses each one with `RFC5322Parser`, and batches them into
/// `MailStore.bulkIngest` so a 50 GB Gmail Takeout never blooms in RAM.
///
/// The importer is itself sync — it's intended to run on a background task /
/// `Task.detached` while progress updates flow back via the callback.
public final class MboxImporter: @unchecked Sendable {
    public struct Progress: Sendable {
        public let bytesRead: Int64
        public let totalBytes: Int64
        public let messagesIngested: Int64
        public let messagesSkipped: Int64       // duplicates collapsed by bulkIngest
        public let secondsElapsed: TimeInterval

        public var percentComplete: Double {
            guard totalBytes > 0 else { return 0 }
            return Double(bytesRead) / Double(totalBytes)
        }
    }

    public struct Options: Sendable {
        public var batchSize: Int = 1_000
        public var folder: String = "INBOX"
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

    /// Import an mbox at `url`. `onProgress` is called whenever a batch flushes
    /// — keep the closure cheap; it runs on the import task.
    @discardableResult
    public func importFile(
        at url: URL,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> (ingested: Int64, skipped: Int64) {
        let stream = try MboxStream(url: url)
        let fallback = try (FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
        let started = Date()

        var batch: [IngestMessage] = []
        batch.reserveCapacity(options.batchSize)

        var ingested: Int64 = 0
        var seen: Int64 = 0
        var lastReportedOffset: Int64 = 0

        try stream.iterate { raw, byteOffset in
            let parsed = RFC5322Parser.parse(raw, fallbackDate: fallback)
            seen += 1

            batch.append(IngestMessage(
                accountID: self.accountID,
                folder: self.options.folder,
                messageID: parsed.messageID,
                inReplyTo: parsed.inReplyTo,
                references: parsed.references,
                subject: parsed.subject,
                fromAddress: parsed.fromAddress,
                toAddresses: parsed.toAddresses,
                ccAddresses: parsed.ccAddresses,
                date: parsed.date,
                sizeBytes: parsed.sizeBytes,
                plainBody: parsed.plainBody,
                htmlBody: parsed.htmlBody,
                attachments: []   // Phase 2E: MIME multipart + attachments
            ))

            if batch.count >= self.options.batchSize {
                let toIngest = batch
                batch.removeAll(keepingCapacity: true)
                // Hop to the actor for the DB write.
                let inserted = try Self.flush(store: self.store, batch: toIngest)
                ingested += Int64(inserted)

                if let onProgress {
                    let offset = Int64(byteOffset)
                    if offset - lastReportedOffset > (stream.totalBytes / 100) {
                        lastReportedOffset = offset
                        let p = Progress(
                            bytesRead: offset,
                            totalBytes: stream.totalBytes,
                            messagesIngested: ingested,
                            messagesSkipped: seen - ingested,
                            secondsElapsed: -started.timeIntervalSinceNow
                        )
                        onProgress(p)
                    }
                }
            }
        }

        if !batch.isEmpty {
            let inserted = try Self.flush(store: store, batch: batch)
            ingested += Int64(inserted)
        }

        if let onProgress {
            let p = Progress(
                bytesRead: stream.totalBytes,
                totalBytes: stream.totalBytes,
                messagesIngested: ingested,
                messagesSkipped: seen - ingested,
                secondsElapsed: -started.timeIntervalSinceNow
            )
            onProgress(p)
        }

        return (ingested, seen - ingested)
    }

    /// Synchronously dispatch a batch to the actor. `MboxStream.iterate` is sync,
    /// so we wrap with a semaphore — the import task itself is async and the
    /// caller controls back-pressure via batch size.
    private static func flush(store: MailStore, batch: [IngestMessage]) throws -> Int {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Int, Error> = .success(0)
        Task.detached {
            do {
                let n = try await store.bulkIngest(batch)
                result = .success(n)
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }
}
