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

        let selected = try await client.select(folder: folder)
        let uids = try await client.uidSearch(since: since)
        let total = uids.count
        let fallback = Date()

        var batch: [(msg: IngestMessage, uid: Int64)] = []
        batch.reserveCapacity(batchSize)
        var ingestedCount = 0
        var skippedCount = 0
        var seen = 0

        let stream = client.streamMessages(uids: uids, chunkSize: chunkSize)
        for try await imapMessage in stream {
            let parsed = RFC5322Parser.parse(imapMessage.raw, fallbackDate: fallback)
            let ingest = buildIngest(
                from: parsed,
                folder: folder,
                rawSize: Int64(imapMessage.raw.count),
                flags: Self.flags(from: imapMessage.flags)
            )
            batch.append((ingest, imapMessage.uid))
            seen += 1
            onProgress?(seen, total)

            if batch.count >= batchSize {
                let result = try await flush(&batch, uidValidity: selected.uidValidity)
                ingestedCount += result.ingested
                skippedCount += result.skipped
            }
        }
        if !batch.isEmpty {
            let result = try await flush(&batch, uidValidity: selected.uidValidity)
            ingestedCount += result.ingested
            skippedCount += result.skipped
        }
        return PullResult(ingested: ingestedCount, skipped: skippedCount)
    }

    /// Push the batch into MailStore, then link each row to its IMAP UID
    /// so later flag writes can target it.
    private func flush(
        _ batch: inout [(msg: IngestMessage, uid: Int64)],
        uidValidity: Int64
    ) async throws -> (ingested: Int, skipped: Int) {
        let messages = batch.map(\.msg)
        let count = messages.count
        let inserted = try await store.bulkIngest(messages)

        // Link UIDs. We resolve folder_id once per batch and reuse.
        // (account_id, RFC5322 messageID) → local rowID via lookupMessageRowID.
        guard let firstFolder = messages.first?.folder,
              let folderID = try await store.folderIDLookup(
                accountID: localAccountID, folder: firstFolder
              )
        else {
            batch.removeAll(keepingCapacity: true)
            return (inserted, count - inserted)
        }
        for entry in batch {
            if let rowID = try await store.lookupMessageRowID(
                accountID: localAccountID, messageID: entry.msg.messageID
            ) {
                try await store.linkIMAP(
                    localRowID: rowID,
                    folderID: folderID,
                    uidValidity: uidValidity,
                    uid: entry.uid
                )
            }
        }
        batch.removeAll(keepingCapacity: true)
        return (inserted, count - inserted)
    }

    // MARK: - Flag writes

    public func setSeen(localRowID: Int64, _ seen: Bool) async throws {
        try await applyFlag(localRowID: localRowID, keyword: "\\Seen", add: seen, localFlag: .seen)
    }

    public func setFlagged(localRowID: Int64, _ flagged: Bool) async throws {
        try await applyFlag(localRowID: localRowID, keyword: "\\Flagged", add: flagged, localFlag: .flagged)
    }

    private func applyFlag(
        localRowID: Int64,
        keyword: String,
        add: Bool,
        localFlag: MessageFlags
    ) async throws {
        guard let mapping = try await store.imapMapping(forLocalRowID: localRowID) else {
            throw IMAPError.commandFailed("local row \(localRowID) has no IMAP mapping")
        }
        try await client.connect()
        try await client.login()
        defer { Task { await client.disconnect() } }
        _ = try await client.select(folder: mapping.folderPath)
        try await client.setFlag(uid: mapping.uid, keyword: keyword, add: add)

        // Reflect locally.
        if var current = try await store.messageFlags(messageRowID: localRowID) {
            if add { current.insert(localFlag) } else { current.remove(localFlag) }
            try await store.updateMessageFlags(messageRowID: localRowID, flags: current)
        }
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
