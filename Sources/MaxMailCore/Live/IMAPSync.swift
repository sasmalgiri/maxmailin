import Foundation

/// IMAP → MailStore sync coordinator. Same shape as JMAPSync — `pullRecent`
/// returns counts, ingest goes through MailStore so all the year/month
/// shards, NLP, forensics, anomaly pipelines light up the same way.
///
/// Streaming discipline is enforced here: we never collect the IMAP stream
/// into a `[Message]` array. Each fetched message is parsed via
/// RFC5322Parser + MIMEParser and batched into `MailStore.bulkIngest`. The
/// in-flight batch is bounded by `batchSize`; nothing else is retained.
public actor IMAPSync {
    public struct PullResult: Sendable {
        public let ingested: Int
        public let skipped: Int
    }

    private let client: IMAPClient
    private let store: MailStore
    private let localAccountID: Int64

    public init(client: IMAPClient, store: MailStore, localAccountID: Int64) {
        self.client = client
        self.store = store
        self.localAccountID = localAccountID
    }

    /// Open the IMAP connection, log in, walk a folder's recent messages,
    /// and ingest them into the local store. Memory stays bounded by
    /// `batchSize` × per-message body size.
    @discardableResult
    public func pullRecent(
        folder: String = "INBOX",
        since: Date? = nil,
        batchSize: Int = 200,
        chunkSize: Int = 500,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> PullResult {
        try await client.connect()
        try await client.login()
        defer { Task { await client.disconnect() } }

        _ = try await client.select(folder: folder)
        let uids = try await client.uidSearch(since: since)
        let total = uids.count
        let fallback = Date()

        var batch: [IngestMessage] = []
        batch.reserveCapacity(batchSize)
        var ingestedCount = 0
        var skippedCount = 0
        var seen = 0

        let stream = client.streamMessages(uids: uids, chunkSize: chunkSize)
        for try await imapMessage in stream {
            let parsed = RFC5322Parser.parse(imapMessage.raw, fallbackDate: fallback)
            batch.append(buildIngest(
                from: parsed,
                folder: folder,
                rawSize: Int64(imapMessage.raw.count),
                flags: Self.flags(from: imapMessage.flags)
            ))
            seen += 1
            onProgress?(seen, total)

            if batch.count >= batchSize {
                let result = try await flush(&batch)
                ingestedCount += result.ingested
                skippedCount += result.skipped
            }
        }
        if !batch.isEmpty {
            let result = try await flush(&batch)
            ingestedCount += result.ingested
            skippedCount += result.skipped
        }
        return PullResult(ingested: ingestedCount, skipped: skippedCount)
    }

    private func flush(_ batch: inout [IngestMessage]) async throws -> (ingested: Int, skipped: Int) {
        // bulkIngest is idempotent on (account_id, message_id); count
        // inserted vs. pre-existing by checking each row's prior lookup
        // would be O(N) extra queries, so we just trust bulkIngest's
        // returned count for ingested and treat the remainder as skipped.
        let count = batch.count
        let inserted = try await store.bulkIngest(batch)
        batch.removeAll(keepingCapacity: true)
        return (inserted, count - inserted)
    }

    private func buildIngest(
        from parsed: ParsedMessage,
        folder: String,
        rawSize: Int64,
        flags: MessageFlags
    ) -> IngestMessage {
        IngestMessage(
            accountID: localAccountID,
            folder: folder,
            messageID: parsed.messageID,
            inReplyTo: parsed.inReplyTo,
            references: parsed.references,
            subject: parsed.subject,
            fromAddress: parsed.fromAddress,
            toAddresses: parsed.toAddresses,
            ccAddresses: parsed.ccAddresses,
            date: parsed.date,
            sizeBytes: rawSize,
            flags: flags,
            plainBody: parsed.plainBody,
            htmlBody: parsed.htmlBody,
            attachments: parsed.attachments
        )
    }

    /// Map IMAP flag strings (case-insensitive backslash-prefixed) to
    /// MessageFlags. IMAP's `\Seen` ↔ `.seen`, `\Flagged` ↔ `.flagged`,
    /// `\Answered` ↔ `.answered`, `\Draft` ↔ `.draft`.
    static func flags(from imapFlags: [String]) -> MessageFlags {
        var out: MessageFlags = []
        for flag in imapFlags {
            switch flag.lowercased() {
            case "\\seen":     out.insert(.seen)
            case "\\flagged":  out.insert(.flagged)
            case "\\answered": out.insert(.answered)
            case "\\draft":    out.insert(.draft)
            default:           break
            }
        }
        return out
    }
}
