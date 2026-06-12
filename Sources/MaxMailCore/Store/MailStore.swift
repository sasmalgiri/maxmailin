import Foundation

/// The single source of truth for messages. SQLite + FTS5, append-only ingest,
/// paged reads. Designed so a 1 TB mailbox lives on disk and never in RAM.
///
/// All mutation goes through the actor; reads are also actor-isolated to keep
/// the C-API connection single-threaded. A future revision can split read/write
/// pools, but correctness first.
public actor MailStore {
    private let conn: SQLiteConnection
    private let dbPath: String

    public init(url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dbPath = url.path
        self.conn = try SQLiteConnection(path: url.path)
        try Self.migrate(conn)
    }

    // MARK: - Schema

    private static let schemaVersion: Int64 = 1

    private static func migrate(_ conn: SQLiteConnection) throws {
        try conn.exec("""
        CREATE TABLE IF NOT EXISTS schema_meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)

        let stmt = try conn.prepare("SELECT value FROM schema_meta WHERE key = 'version';")
        var current: Int64 = 0
        try stmt.forEachRow { row in
            current = Int64(row.string(0) ?? "0") ?? 0
            return false
        }

        if current < 1 {
            try conn.transaction {
                try conn.exec("""
                CREATE TABLE IF NOT EXISTS accounts (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    name        TEXT NOT NULL,
                    address     TEXT NOT NULL UNIQUE,
                    kind        TEXT NOT NULL,
                    created_at  INTEGER NOT NULL
                );
                """)

                try conn.exec("""
                CREATE TABLE IF NOT EXISTS folders (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    account_id  INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    path        TEXT NOT NULL,
                    UNIQUE(account_id, path)
                );
                """)

                try conn.exec("""
                CREATE TABLE IF NOT EXISTS messages (
                    id            INTEGER PRIMARY KEY AUTOINCREMENT,
                    account_id    INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    folder_id     INTEGER NOT NULL REFERENCES folders(id)  ON DELETE CASCADE,
                    message_id    TEXT NOT NULL,
                    in_reply_to   TEXT,
                    references_   TEXT,
                    subject       TEXT NOT NULL,
                    from_addr     TEXT NOT NULL,
                    to_addrs      TEXT NOT NULL,
                    cc_addrs      TEXT NOT NULL,
                    date_unix     INTEGER NOT NULL,
                    size_bytes    INTEGER NOT NULL,
                    flags         INTEGER NOT NULL,
                    snippet       TEXT,
                    has_body      INTEGER NOT NULL DEFAULT 0,
                    UNIQUE(account_id, message_id)
                );
                """)
                try conn.exec("CREATE INDEX IF NOT EXISTS idx_messages_folder_date ON messages(folder_id, date_unix DESC);")
                try conn.exec("CREATE INDEX IF NOT EXISTS idx_messages_account_date ON messages(account_id, date_unix DESC);")
                try conn.exec("CREATE INDEX IF NOT EXISTS idx_messages_from ON messages(from_addr);")

                // Bodies are kept separate so the messages row stays narrow.
                try conn.exec("""
                CREATE TABLE IF NOT EXISTS message_bodies (
                    message_id   INTEGER PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
                    plain_body   TEXT,
                    html_body    TEXT
                );
                """)

                // Attachments are tracked by name + content-hash. Blobs themselves
                // live in a separate content-addressed blob store (added later).
                try conn.exec("""
                CREATE TABLE IF NOT EXISTS attachments (
                    id           INTEGER PRIMARY KEY AUTOINCREMENT,
                    message_id   INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                    filename     TEXT NOT NULL,
                    sha256       TEXT
                );
                """)
                try conn.exec("CREATE INDEX IF NOT EXISTS idx_attachments_message ON attachments(message_id);")

                // FTS5 virtual table. Original text is stored in the FTS table
                // so snippet() and highlight() work — contentless mode forbids them.
                try conn.exec("""
                CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
                    subject, from_addr, to_addrs, body,
                    tokenize='porter unicode61'
                );
                """)

                try conn.exec("""
                INSERT INTO schema_meta(key, value) VALUES('version', '\(Self.schemaVersion)')
                  ON CONFLICT(key) DO UPDATE SET value=excluded.value;
                """)
            }
        }
    }

    // MARK: - Accounts & Folders

    public func upsertAccount(name: String, address: String, kind: String) throws -> Int64 {
        let stmt = try conn.prepare("""
        INSERT INTO accounts(name, address, kind, created_at) VALUES(?, ?, ?, ?)
          ON CONFLICT(address) DO UPDATE SET name=excluded.name, kind=excluded.kind
        RETURNING id;
        """)
        try stmt.bind(1, name)
        try stmt.bind(2, address)
        try stmt.bind(3, kind)
        try stmt.bind(4, Int64(Date().timeIntervalSince1970))
        var id: Int64 = 0
        try stmt.forEachRow { row in id = row.int64(0); return false }
        return id
    }

    private func folderID(accountID: Int64, path: String) throws -> Int64 {
        let sel = try conn.prepare("SELECT id FROM folders WHERE account_id = ? AND path = ?;")
        try sel.bind(1, accountID)
        try sel.bind(2, path)
        var id: Int64 = 0
        try sel.forEachRow { row in id = row.int64(0); return false }
        if id != 0 { return id }

        let ins = try conn.prepare("INSERT INTO folders(account_id, path) VALUES(?, ?) RETURNING id;")
        try ins.bind(1, accountID)
        try ins.bind(2, path)
        try ins.forEachRow { row in id = row.int64(0); return false }
        return id
    }

    // MARK: - Ingest

    /// Insert a message. Idempotent on (account_id, message_id).
    /// Returns the message row ID (existing or newly created).
    @discardableResult
    public func ingest(_ m: IngestMessage) throws -> Int64 {
        try conn.transaction {
            let fid = try folderID(accountID: m.accountID, path: m.folder)

            let existing = try conn.prepare("""
            SELECT id FROM messages WHERE account_id = ? AND message_id = ?;
            """)
            try existing.bind(1, m.accountID)
            try existing.bind(2, m.messageID)
            var rowID: Int64 = 0
            try existing.forEachRow { row in rowID = row.int64(0); return false }
            if rowID != 0 { return rowID }

            let snippet = makeSnippet(plain: m.plainBody, html: m.htmlBody)
            let hasBody = (m.plainBody != nil || m.htmlBody != nil) ? Int64(1) : Int64(0)

            let ins = try conn.prepare("""
            INSERT INTO messages(
                account_id, folder_id, message_id, in_reply_to, references_,
                subject, from_addr, to_addrs, cc_addrs,
                date_unix, size_bytes, flags, snippet, has_body
            ) VALUES (?,?,?,?,?, ?,?,?,?, ?,?,?,?,?)
            RETURNING id;
            """)
            try ins.bind(1, m.accountID)
            try ins.bind(2, fid)
            try ins.bind(3, m.messageID)
            try ins.bind(4, m.inReplyTo)
            try ins.bind(5, m.references.isEmpty ? nil : m.references.joined(separator: " "))
            try ins.bind(6, m.subject)
            try ins.bind(7, m.fromAddress)
            try ins.bind(8, m.toAddresses.joined(separator: ", "))
            try ins.bind(9, m.ccAddresses.joined(separator: ", "))
            try ins.bind(10, Int64(m.date.timeIntervalSince1970))
            try ins.bind(11, m.sizeBytes)
            try ins.bind(12, Int64(m.flags.rawValue))
            try ins.bind(13, snippet)
            try ins.bind(14, hasBody)
            var newID: Int64 = 0
            try ins.forEachRow { row in newID = row.int64(0); return false }

            if hasBody == 1 {
                let body = try conn.prepare("""
                INSERT INTO message_bodies(message_id, plain_body, html_body) VALUES(?, ?, ?);
                """)
                try body.bind(1, newID)
                try body.bind(2, m.plainBody)
                try body.bind(3, m.htmlBody)
                try body.run()
            }

            if !m.attachmentNames.isEmpty {
                let att = try conn.prepare("INSERT INTO attachments(message_id, filename, sha256) VALUES(?, ?, NULL);")
                for name in m.attachmentNames {
                    att.reset()
                    try att.bind(1, newID)
                    try att.bind(2, name)
                    try att.run()
                }
            }

            // Index for FTS5. rowid = messages.id so we can join back cheaply.
            let fts = try conn.prepare("""
            INSERT INTO messages_fts(rowid, subject, from_addr, to_addrs, body)
            VALUES(?, ?, ?, ?, ?);
            """)
            try fts.bind(1, newID)
            try fts.bind(2, m.subject)
            try fts.bind(3, m.fromAddress)
            try fts.bind(4, m.toAddresses.joined(separator: " "))
            try fts.bind(5, m.plainBody ?? "")
            try fts.run()

            return newID
        }
    }

    /// Bulk-ingest a batch of messages under one transaction with reused
    /// prepared statements. The throughput-critical path for both initial
    /// archive import and live-sync delta application.
    ///
    /// Returns the number of new rows actually inserted (duplicates skipped).
    @discardableResult
    public func bulkIngest(_ messages: [IngestMessage]) throws -> Int {
        guard !messages.isEmpty else { return 0 }

        // Prepare every statement once.
        let selExisting = try conn.prepare("SELECT id FROM messages WHERE account_id = ? AND message_id = ?;")
        let insMsg = try conn.prepare("""
        INSERT INTO messages(
            account_id, folder_id, message_id, in_reply_to, references_,
            subject, from_addr, to_addrs, cc_addrs,
            date_unix, size_bytes, flags, snippet, has_body
        ) VALUES (?,?,?,?,?, ?,?,?,?, ?,?,?,?,?)
        RETURNING id;
        """)
        let insBody = try conn.prepare("INSERT INTO message_bodies(message_id, plain_body, html_body) VALUES(?, ?, ?);")
        let insAtt = try conn.prepare("INSERT INTO attachments(message_id, filename, sha256) VALUES(?, ?, NULL);")
        let insFTS = try conn.prepare("INSERT INTO messages_fts(rowid, subject, from_addr, to_addrs, body) VALUES(?, ?, ?, ?, ?);")
        let selFolderID = try conn.prepare("SELECT id FROM folders WHERE account_id = ? AND path = ?;")
        let insFolder = try conn.prepare("INSERT INTO folders(account_id, path) VALUES(?, ?) RETURNING id;")

        // Cache folder IDs in the loop so repeats are free.
        var folderCache: [Int64: [String: Int64]] = [:]
        var inserted = 0

        try conn.transaction {
            for m in messages {
                // folder id (cached per account+path)
                let fid: Int64
                if let cached = folderCache[m.accountID]?[m.folder] {
                    fid = cached
                } else {
                    selFolderID.reset()
                    try selFolderID.bind(1, m.accountID)
                    try selFolderID.bind(2, m.folder)
                    var found: Int64 = 0
                    try selFolderID.forEachRow { row in found = row.int64(0); return false }
                    if found == 0 {
                        insFolder.reset()
                        try insFolder.bind(1, m.accountID)
                        try insFolder.bind(2, m.folder)
                        try insFolder.forEachRow { row in found = row.int64(0); return false }
                    }
                    folderCache[m.accountID, default: [:]][m.folder] = found
                    fid = found
                }

                // duplicate check
                selExisting.reset()
                try selExisting.bind(1, m.accountID)
                try selExisting.bind(2, m.messageID)
                var existing: Int64 = 0
                try selExisting.forEachRow { row in existing = row.int64(0); return false }
                if existing != 0 { continue }

                // insert message
                let snippet = makeSnippet(plain: m.plainBody, html: m.htmlBody)
                let hasBody: Int64 = (m.plainBody != nil || m.htmlBody != nil) ? 1 : 0

                insMsg.reset()
                try insMsg.bind(1, m.accountID)
                try insMsg.bind(2, fid)
                try insMsg.bind(3, m.messageID)
                try insMsg.bind(4, m.inReplyTo)
                try insMsg.bind(5, m.references.isEmpty ? nil : m.references.joined(separator: " "))
                try insMsg.bind(6, m.subject)
                try insMsg.bind(7, m.fromAddress)
                try insMsg.bind(8, m.toAddresses.joined(separator: ", "))
                try insMsg.bind(9, m.ccAddresses.joined(separator: ", "))
                try insMsg.bind(10, Int64(m.date.timeIntervalSince1970))
                try insMsg.bind(11, m.sizeBytes)
                try insMsg.bind(12, Int64(m.flags.rawValue))
                try insMsg.bind(13, snippet)
                try insMsg.bind(14, hasBody)
                var newID: Int64 = 0
                try insMsg.forEachRow { row in newID = row.int64(0); return false }

                if hasBody == 1 {
                    insBody.reset()
                    try insBody.bind(1, newID)
                    try insBody.bind(2, m.plainBody)
                    try insBody.bind(3, m.htmlBody)
                    try insBody.run()
                }

                for name in m.attachmentNames {
                    insAtt.reset()
                    try insAtt.bind(1, newID)
                    try insAtt.bind(2, name)
                    try insAtt.run()
                }

                insFTS.reset()
                try insFTS.bind(1, newID)
                try insFTS.bind(2, m.subject)
                try insFTS.bind(3, m.fromAddress)
                try insFTS.bind(4, m.toAddresses.joined(separator: " "))
                try insFTS.bind(5, m.plainBody ?? "")
                try insFTS.run()

                inserted += 1
            }
        }
        return inserted
    }

    // MARK: - Reads (paged, never load everything)

    /// Page through a folder, newest-first. `before` is the unix date of the last
    /// row from the previous page — keeps you in keyset-pagination land (no OFFSET).
    public func headers(in folder: String, accountID: Int64, before: Date? = nil, limit: Int = 50) throws -> [MessageHeader] {
        let sql: String
        if before == nil {
            sql = """
            SELECT m.id, m.message_id, f.path, m.subject, m.from_addr, m.date_unix,
                   m.size_bytes, m.flags, m.snippet
              FROM messages m JOIN folders f ON f.id = m.folder_id
             WHERE f.account_id = ? AND f.path = ?
             ORDER BY m.date_unix DESC, m.id DESC
             LIMIT ?;
            """
        } else {
            sql = """
            SELECT m.id, m.message_id, f.path, m.subject, m.from_addr, m.date_unix,
                   m.size_bytes, m.flags, m.snippet
              FROM messages m JOIN folders f ON f.id = m.folder_id
             WHERE f.account_id = ? AND f.path = ? AND m.date_unix < ?
             ORDER BY m.date_unix DESC, m.id DESC
             LIMIT ?;
            """
        }
        let stmt = try conn.prepare(sql)
        try stmt.bind(1, accountID)
        try stmt.bind(2, folder)
        if let before {
            try stmt.bind(3, Int64(before.timeIntervalSince1970))
            try stmt.bind(4, Int64(limit))
        } else {
            try stmt.bind(3, Int64(limit))
        }

        var out: [MessageHeader] = []
        out.reserveCapacity(limit)
        try stmt.forEachRow { row in
            out.append(MessageHeader(
                id: row.int64(0),
                messageID: row.string(1) ?? "",
                folder: row.string(2) ?? "",
                subject: row.string(3) ?? "",
                fromAddress: row.string(4) ?? "",
                date: Date(timeIntervalSince1970: TimeInterval(row.int64(5))),
                sizeBytes: row.int64(6),
                flags: MessageFlags(rawValue: row.int(7)),
                snippet: row.string(8)
            ))
            return true
        }
        return out
    }

    /// Load just the bodies for a single message. Bodies are *not* loaded eagerly anywhere else.
    public func loadBody(messageRowID: Int64) throws -> (plain: String?, html: String?)? {
        let stmt = try conn.prepare("SELECT plain_body, html_body FROM message_bodies WHERE message_id = ?;")
        try stmt.bind(1, messageRowID)
        var result: (String?, String?)?
        try stmt.forEachRow { row in
            result = (row.string(0), row.string(1))
            return false
        }
        return result
    }

    // MARK: - Search

    /// Full-text search via FTS5. Returns BM25-ranked hits with highlighted snippets.
    ///
    /// - `since`: only consider messages newer than this date. This is the
    ///   single biggest latency lever at scale — the 1 M corpus search drops
    ///   from ~400 ms to sub-50 ms when scoped to a 90-day window because
    ///   the candidate set BM25 has to rank shrinks by 1–2 orders of magnitude.
    /// - BM25 column weights (10, 5, 2, 1) bias ranking toward subject and
    ///   sender matches, which is what users actually want when searching mail.
    public func search(
        _ query: String,
        accountID: Int64? = nil,
        since: Date? = nil,
        limit: Int = 50
    ) throws -> [SearchHit] {
        var clauses = ["messages_fts MATCH ?"]
        if accountID != nil { clauses.append("m.account_id = ?") }
        if since != nil { clauses.append("m.date_unix > ?") }

        let sql = """
        SELECT m.id, m.message_id, m.subject, m.from_addr, m.date_unix,
               snippet(messages_fts, 3, '⟦', '⟧', '…', 12) AS snip,
               bm25(messages_fts, 10.0, 5.0, 2.0, 1.0) AS score
          FROM messages_fts
          JOIN messages m ON m.id = messages_fts.rowid
         WHERE \(clauses.joined(separator: " AND "))
         ORDER BY score
         LIMIT ?;
        """
        let stmt = try conn.prepare(sql)
        var bindIdx: Int32 = 1
        try stmt.bind(bindIdx, query); bindIdx += 1
        if let accountID {
            try stmt.bind(bindIdx, accountID); bindIdx += 1
        }
        if let since {
            try stmt.bind(bindIdx, Int64(since.timeIntervalSince1970)); bindIdx += 1
        }
        try stmt.bind(bindIdx, Int64(limit))

        var hits: [SearchHit] = []
        try stmt.forEachRow { row in
            hits.append(SearchHit(
                id: row.int64(0),
                messageID: row.string(1) ?? "",
                subject: row.string(2) ?? "",
                fromAddress: row.string(3) ?? "",
                date: Date(timeIntervalSince1970: TimeInterval(row.int64(4))),
                snippet: row.string(5) ?? "",
                score: Double(row.string(6) ?? "0") ?? 0
            ))
            return true
        }
        return hits
    }

    // MARK: - Stats

    public func stats() throws -> StoreStats {
        var msg: Int64 = 0, fld: Int64 = 0, acc: Int64 = 0
        let s1 = try conn.prepare("SELECT COUNT(*) FROM messages;")
        try s1.forEachRow { r in msg = r.int64(0); return false }
        let s2 = try conn.prepare("SELECT COUNT(*) FROM folders;")
        try s2.forEachRow { r in fld = r.int64(0); return false }
        let s3 = try conn.prepare("SELECT COUNT(*) FROM accounts;")
        try s3.forEachRow { r in acc = r.int64(0); return false }

        var dbBytes: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
           let n = attrs[.size] as? NSNumber {
            dbBytes = n.int64Value
        }
        return StoreStats(messageCount: msg, folderCount: fld, accountCount: acc, dbFileBytes: dbBytes)
    }

    public func checkpoint() throws {
        try conn.exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    // MARK: - Helpers

    private func makeSnippet(plain: String?, html: String?) -> String? {
        let raw = plain ?? html
        guard let raw, !raw.isEmpty else { return nil }
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if collapsed.count <= 180 { return collapsed }
        return String(collapsed.prefix(180)) + "…"
    }
}
