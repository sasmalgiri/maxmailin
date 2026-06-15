import Foundation

/// The single source of truth for messages. SQLite + per-year FTS5 shards,
/// content-addressed attachments, paged reads. Designed so a 1 TB mailbox
/// lives on disk and never in RAM.
///
/// Schema v2:
/// - One `messages_fts_<year>` virtual table per year present in the data.
///   Splitting by year keeps each FTS table small so BM25 ranking stays fast
///   even when the corpus crosses 10 M messages. Windowed searches (the
///   default user experience) skip irrelevant shards entirely.
/// - `attachments` carries `mime_type`, `size_bytes`, and `sha256`. The bytes
///   themselves live in a separate `BlobStore` keyed by SHA-256, so identical
///   files referenced by multiple messages (mailing-list traffic, forwarded
///   threads, repeated inline images) are stored exactly once.
///
/// All mutation goes through the actor; reads are also actor-isolated to keep
/// the single C-API connection serialized. A future revision can split read /
/// write pools, but correctness first.
public actor MailStore {
    private let conn: SQLiteConnection
    private let dbPath: String
    private let blobs: BlobStore
    private var knownShards: Set<Int> = []

    public init(url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dbPath = url.path
        self.conn = try SQLiteConnection(path: url.path)
        self.blobs = try BlobStore(root: dir.appendingPathComponent("blobs", isDirectory: true))
        try Self.migrate(conn)
        self.knownShards = try Self.loadKnownShards(conn)
    }

    /// Exposed so callers can `put` blobs directly when ingesting through
    /// custom paths (e.g., re-using a previously hashed file).
    public var blobStore: BlobStore { blobs }

    // MARK: - Schema

    private static let schemaVersion: Int64 = 5

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
                try conn.exec("""
                CREATE TABLE IF NOT EXISTS message_bodies (
                    message_id   INTEGER PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
                    plain_body   TEXT,
                    html_body    TEXT
                );
                """)
                try conn.exec("""
                CREATE TABLE IF NOT EXISTS attachments (
                    id           INTEGER PRIMARY KEY AUTOINCREMENT,
                    message_id   INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                    filename     TEXT NOT NULL,
                    sha256       TEXT
                );
                """)
                try conn.exec("CREATE INDEX IF NOT EXISTS idx_attachments_message ON attachments(message_id);")

                try conn.exec("""
                INSERT INTO schema_meta(key, value) VALUES('version', '1')
                  ON CONFLICT(key) DO UPDATE SET value=excluded.value;
                """)
            }
        }

        if current < 2 {
            try conn.transaction {
                try conn.exec("CREATE TABLE IF NOT EXISTS fts_shards (year INTEGER PRIMARY KEY);")
                // ALTER if columns aren't already present. SQLite has no
                // IF NOT EXISTS for ADD COLUMN, so probe pragma_table_info.
                let cols = try Self.columnsOf("attachments", in: conn)
                if !cols.contains("mime_type") {
                    try conn.exec("ALTER TABLE attachments ADD COLUMN mime_type TEXT;")
                }
                if !cols.contains("size_bytes") {
                    try conn.exec("ALTER TABLE attachments ADD COLUMN size_bytes INTEGER;")
                }

                // Drop the v1 unsharded FTS table if present. Reindex existing
                // messages into per-year shards below.
                try conn.exec("DROP TABLE IF EXISTS messages_fts;")

                // Discover years present in messages and reindex.
                let yearStmt = try conn.prepare("""
                SELECT DISTINCT CAST(strftime('%Y', date_unix, 'unixepoch') AS INTEGER) AS y
                  FROM messages
                 WHERE date_unix IS NOT NULL
                 ORDER BY y;
                """)
                var years: [Int] = []
                try yearStmt.forEachRow { row in years.append(row.int(0)); return true }

                for year in years {
                    try Self.createShardSQL(year: year, in: conn)
                    try conn.exec("INSERT OR IGNORE INTO fts_shards(year) VALUES(\(year));")
                    let reidx = try conn.prepare("""
                    INSERT INTO messages_fts_\(year)(rowid, subject, from_addr, to_addrs, body)
                    SELECT m.id, m.subject, m.from_addr, m.to_addrs, COALESCE(b.plain_body, '')
                      FROM messages m
                      LEFT JOIN message_bodies b ON b.message_id = m.id
                     WHERE CAST(strftime('%Y', m.date_unix, 'unixepoch') AS INTEGER) = ?;
                    """)
                    try reidx.bind(1, Int64(year))
                    try reidx.run()
                }

                try conn.exec("INSERT OR REPLACE INTO schema_meta(key, value) VALUES('version', '2');")
            }
        }

        if current < 3 {
            try conn.transaction {
                // Per-message on-device NLP cache. Sentiment / language /
                // entities / keywords for the body. Lazily filled by
                // ensureNLP(messageRowID:) on first access.
                try conn.exec("""
                CREATE TABLE IF NOT EXISTS message_nlp (
                    message_id     INTEGER PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
                    sentiment      REAL NOT NULL,
                    language       TEXT,
                    entities_json  TEXT,
                    keywords_json  TEXT,
                    analyzed_at    INTEGER NOT NULL
                );
                """)
                try conn.exec("INSERT OR REPLACE INTO schema_meta(key, value) VALUES('version', '3');")
            }
        }

        if current < 4 {
            try conn.transaction {
                // Per-message forensic cache: phishing risk + PII findings.
                // Lazily filled by ensureForensics(messageRowID:).
                try conn.exec("""
                CREATE TABLE IF NOT EXISTS message_forensics (
                    message_id            INTEGER PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
                    phishing_score        INTEGER NOT NULL,
                    phishing_level        TEXT NOT NULL,
                    phishing_reasons_json TEXT,
                    pii_json              TEXT,
                    analyzed_at           INTEGER NOT NULL
                );
                """)
                try conn.exec("CREATE INDEX IF NOT EXISTS idx_forensics_phishing_level ON message_forensics(phishing_level);")
                try conn.exec("INSERT OR REPLACE INTO schema_meta(key, value) VALUES('version', '4');")
            }
        }

        if current < 5 {
            try conn.transaction {
                // Maps a local message row to the corresponding JMAP id so
                // we can issue Email/set / Email/changes / Email/get calls
                // by the JMAP id. Required for flag writes and incremental
                // sync once we know an account is a JMAP one.
                try conn.exec("""
                CREATE TABLE IF NOT EXISTS jmap_message_map (
                    local_id        INTEGER PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
                    jmap_account_id TEXT NOT NULL,
                    jmap_email_id   TEXT NOT NULL,
                    UNIQUE(jmap_account_id, jmap_email_id)
                );
                """)
                try conn.exec("CREATE INDEX IF NOT EXISTS idx_jmap_map_email_id ON jmap_message_map(jmap_email_id);")
                // Per-account JMAP sync cursors. `scope` is "email" /
                // "mailbox" so we can advance them independently after each
                // Email/changes / Mailbox/changes round-trip.
                try conn.exec("""
                CREATE TABLE IF NOT EXISTS jmap_sync_state (
                    local_account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    scope            TEXT NOT NULL,
                    state            TEXT NOT NULL,
                    updated_at       INTEGER NOT NULL,
                    PRIMARY KEY(local_account_id, scope)
                );
                """)
                try conn.exec("INSERT OR REPLACE INTO schema_meta(key, value) VALUES('version', '5');")
            }
        }
    }

    private static func columnsOf(_ table: String, in conn: SQLiteConnection) throws -> Set<String> {
        var names = Set<String>()
        let stmt = try conn.prepare("SELECT name FROM pragma_table_info(?);")
        try stmt.bind(1, table)
        try stmt.forEachRow { row in
            if let s = row.string(0) { names.insert(s) }
            return true
        }
        return names
    }

    private static func createShardSQL(year: Int, in conn: SQLiteConnection) throws {
        try conn.exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts_\(year) USING fts5(
            subject, from_addr, to_addrs, body,
            tokenize='porter unicode61'
        );
        """)
    }

    private static func loadKnownShards(_ conn: SQLiteConnection) throws -> Set<Int> {
        var out = Set<Int>()
        let stmt = try conn.prepare("SELECT year FROM fts_shards;")
        try stmt.forEachRow { row in out.insert(row.int(0)); return true }
        return out
    }

    private func ensureShard(forYear year: Int) throws -> String {
        let name = "messages_fts_\(year)"
        if knownShards.contains(year) { return name }
        try Self.createShardSQL(year: year, in: conn)
        try conn.exec("INSERT OR IGNORE INTO fts_shards(year) VALUES(\(year));")
        knownShards.insert(year)
        return name
    }

    private func relevantShards(since: Date?) -> [Int] {
        let sorted = knownShards.sorted()
        guard let since else { return sorted }
        let lowerYear = Calendar(identifier: .gregorian).component(.year, from: since)
        return sorted.filter { $0 >= lowerYear }
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

    // MARK: - Ingest

    /// Single-message convenience that delegates to bulkIngest.
    @discardableResult
    public func ingest(_ m: IngestMessage) throws -> Int64 {
        let countBefore = try countMessages(accountID: m.accountID, messageID: m.messageID)
        try bulkIngest([m])
        return try lookupMessageRowID(accountID: m.accountID, messageID: m.messageID)
            ?? countBefore // fallback; bulkIngest will have created it
    }

    /// Bulk-ingest a batch of messages under one transaction with reused
    /// prepared statements, blob-storing attachment bytes, routing FTS writes
    /// to the per-year shard. Returns the number of new rows inserted
    /// (duplicates skipped).
    @discardableResult
    public func bulkIngest(_ messages: [IngestMessage]) throws -> Int {
        guard !messages.isEmpty else { return 0 }

        // 1. Pre-write attachment blobs outside the SQL transaction. Each blob
        //    is content-addressed and idempotent, so dupes across messages and
        //    across batches collapse automatically. Compute per-attachment
        //    sha256/size in parallel arrays for the txn loop.
        var attHashes: [[String?]] = Array(repeating: [], count: messages.count)
        var attSizes:  [[Int64?]]  = Array(repeating: [], count: messages.count)
        for (i, m) in messages.enumerated() {
            for att in m.attachments {
                if let data = att.data {
                    let hex = try blobs.put(data)
                    attHashes[i].append(hex)
                    attSizes[i].append(Int64(data.count))
                } else {
                    attHashes[i].append(nil)
                    attSizes[i].append(nil)
                }
            }
        }

        // 2. Ensure FTS shards for every year present in this batch. Doing
        //    this once up front avoids a per-row ALTER inside the hot loop.
        let calendar = Calendar(identifier: .gregorian)
        var yearForMsg: [Int] = []
        yearForMsg.reserveCapacity(messages.count)
        var distinctYears = Set<Int>()
        for m in messages {
            let y = calendar.component(.year, from: m.date)
            yearForMsg.append(y)
            distinctYears.insert(y)
        }
        for y in distinctYears { _ = try ensureShard(forYear: y) }

        // 3. Prepare every per-shard FTS insert statement once, keyed by year.
        var ftsInserts: [Int: SQLiteStatement] = [:]
        for y in distinctYears {
            ftsInserts[y] = try conn.prepare("""
            INSERT INTO messages_fts_\(y)(rowid, subject, from_addr, to_addrs, body)
            VALUES(?, ?, ?, ?, ?);
            """)
        }

        let stmts = try BulkStatements(conn: conn, ftsInserts: ftsInserts)
        var folderCache: [Int64: [String: Int64]] = [:]
        var inserted = 0

        try conn.transaction {
            inserted = try self.runBulkInsertLoop(
                messages: messages,
                yearForMsg: yearForMsg,
                attHashes: attHashes,
                attSizes: attSizes,
                stmts: stmts,
                folderCache: &folderCache
            )
        }
        return inserted
    }

    private struct BulkStatements {
        let selExisting: SQLiteStatement
        let insMsg: SQLiteStatement
        let insBody: SQLiteStatement
        let insAtt: SQLiteStatement
        let selFolderID: SQLiteStatement
        let insFolder: SQLiteStatement
        let ftsInserts: [Int: SQLiteStatement]

        init(conn: SQLiteConnection, ftsInserts: [Int: SQLiteStatement]) throws {
            self.selExisting = try conn.prepare("SELECT id FROM messages WHERE account_id = ? AND message_id = ?;")
            self.insMsg = try conn.prepare("""
            INSERT INTO messages(
                account_id, folder_id, message_id, in_reply_to, references_,
                subject, from_addr, to_addrs, cc_addrs,
                date_unix, size_bytes, flags, snippet, has_body
            ) VALUES (?,?,?,?,?, ?,?,?,?, ?,?,?,?,?)
            RETURNING id;
            """)
            self.insBody = try conn.prepare("INSERT INTO message_bodies(message_id, plain_body, html_body) VALUES(?, ?, ?);")
            self.insAtt = try conn.prepare("""
            INSERT INTO attachments(message_id, filename, mime_type, size_bytes, sha256)
            VALUES(?, ?, ?, ?, ?);
            """)
            self.selFolderID = try conn.prepare("SELECT id FROM folders WHERE account_id = ? AND path = ?;")
            self.insFolder = try conn.prepare("INSERT INTO folders(account_id, path) VALUES(?, ?) RETURNING id;")
            self.ftsInserts = ftsInserts
        }
    }

    private func runBulkInsertLoop(
        messages: [IngestMessage],
        yearForMsg: [Int],
        attHashes: [[String?]],
        attSizes: [[Int64?]],
        stmts: BulkStatements,
        folderCache: inout [Int64: [String: Int64]]
    ) throws -> Int {
        var inserted = 0
        for (i, m) in messages.enumerated() {
            let fid = try folderID(
                accountID: m.accountID, folder: m.folder,
                selFolderID: stmts.selFolderID, insFolder: stmts.insFolder,
                cache: &folderCache
            )

            stmts.selExisting.reset()
            try stmts.selExisting.bind(1, m.accountID)
            try stmts.selExisting.bind(2, m.messageID)
            var existing: Int64 = 0
            try stmts.selExisting.forEachRow { row in existing = row.int64(0); return false }
            if existing != 0 { continue }

            let snippet = makeSnippet(plain: m.plainBody, html: m.htmlBody)
            let hasBody: Int64 = (m.plainBody != nil || m.htmlBody != nil) ? 1 : 0

            stmts.insMsg.reset()
            try stmts.insMsg.bind(1, m.accountID)
            try stmts.insMsg.bind(2, fid)
            try stmts.insMsg.bind(3, m.messageID)
            try stmts.insMsg.bind(4, m.inReplyTo)
            try stmts.insMsg.bind(5, m.references.isEmpty ? nil : m.references.joined(separator: " "))
            try stmts.insMsg.bind(6, m.subject)
            try stmts.insMsg.bind(7, m.fromAddress)
            try stmts.insMsg.bind(8, m.toAddresses.joined(separator: ", "))
            try stmts.insMsg.bind(9, m.ccAddresses.joined(separator: ", "))
            try stmts.insMsg.bind(10, Int64(m.date.timeIntervalSince1970))
            try stmts.insMsg.bind(11, m.sizeBytes)
            try stmts.insMsg.bind(12, Int64(m.flags.rawValue))
            try stmts.insMsg.bind(13, snippet)
            try stmts.insMsg.bind(14, hasBody)
            var newID: Int64 = 0
            try stmts.insMsg.forEachRow { row in newID = row.int64(0); return false }

            if hasBody == 1 {
                stmts.insBody.reset()
                try stmts.insBody.bind(1, newID)
                try stmts.insBody.bind(2, m.plainBody)
                try stmts.insBody.bind(3, m.htmlBody)
                try stmts.insBody.run()
            }

            for (j, att) in m.attachments.enumerated() {
                stmts.insAtt.reset()
                try stmts.insAtt.bind(1, newID)
                try stmts.insAtt.bind(2, att.filename)
                try stmts.insAtt.bind(3, att.mimeType)
                try stmts.insAtt.bind(4, attSizes[i][j])
                try stmts.insAtt.bind(5, attHashes[i][j])
                try stmts.insAtt.run()
            }

            let fts = stmts.ftsInserts[yearForMsg[i]]!
            fts.reset()
            try fts.bind(1, newID)
            try fts.bind(2, m.subject)
            try fts.bind(3, m.fromAddress)
            try fts.bind(4, m.toAddresses.joined(separator: " "))
            try fts.bind(5, m.plainBody ?? "")
            try fts.run()

            inserted += 1
        }
        return inserted
    }

    private func folderID(
        accountID: Int64,
        folder: String,
        selFolderID: SQLiteStatement,
        insFolder: SQLiteStatement,
        cache: inout [Int64: [String: Int64]]
    ) throws -> Int64 {
        if let cached = cache[accountID]?[folder] { return cached }
        selFolderID.reset()
        try selFolderID.bind(1, accountID)
        try selFolderID.bind(2, folder)
        var found: Int64 = 0
        try selFolderID.forEachRow { row in found = row.int64(0); return false }
        if found == 0 {
            insFolder.reset()
            try insFolder.bind(1, accountID)
            try insFolder.bind(2, folder)
            try insFolder.forEachRow { row in found = row.int64(0); return false }
        }
        cache[accountID, default: [:]][folder] = found
        return found
    }

    private func countMessages(accountID: Int64, messageID: String) throws -> Int64 {
        let stmt = try conn.prepare("SELECT COUNT(*) FROM messages WHERE account_id = ? AND message_id = ?;")
        try stmt.bind(1, accountID)
        try stmt.bind(2, messageID)
        var n: Int64 = 0
        try stmt.forEachRow { row in n = row.int64(0); return false }
        return n
    }

    public func lookupMessageRowID(accountID: Int64, messageID: String) throws -> Int64? {
        let stmt = try conn.prepare("SELECT id FROM messages WHERE account_id = ? AND message_id = ?;")
        try stmt.bind(1, accountID)
        try stmt.bind(2, messageID)
        var id: Int64 = 0
        try stmt.forEachRow { row in id = row.int64(0); return false }
        return id == 0 ? nil : id
    }

    // MARK: - JMAP id mapping + sync state

    public func linkJMAP(localRowID: Int64, jmapAccountID: String, jmapEmailID: String) throws {
        let stmt = try conn.prepare("""
        INSERT INTO jmap_message_map(local_id, jmap_account_id, jmap_email_id)
        VALUES(?, ?, ?)
        ON CONFLICT(local_id) DO UPDATE SET
            jmap_account_id = excluded.jmap_account_id,
            jmap_email_id   = excluded.jmap_email_id;
        """)
        try stmt.bind(1, localRowID)
        try stmt.bind(2, jmapAccountID)
        try stmt.bind(3, jmapEmailID)
        try stmt.run()
    }

    public func localRowID(forJMAPEmailID jmapEmailID: String) throws -> Int64? {
        let stmt = try conn.prepare("SELECT local_id FROM jmap_message_map WHERE jmap_email_id = ?;")
        try stmt.bind(1, jmapEmailID)
        var id: Int64 = 0
        try stmt.forEachRow { row in id = row.int64(0); return false }
        return id == 0 ? nil : id
    }

    public func jmapEmailID(forLocalRowID localRowID: Int64) throws -> (jmapAccountID: String, jmapEmailID: String)? {
        let stmt = try conn.prepare("SELECT jmap_account_id, jmap_email_id FROM jmap_message_map WHERE local_id = ?;")
        try stmt.bind(1, localRowID)
        var result: (String, String)?
        try stmt.forEachRow { row in
            result = (row.string(0) ?? "", row.string(1) ?? "")
            return false
        }
        return result
    }

    public func syncState(accountID: Int64, scope: String) throws -> String? {
        let stmt = try conn.prepare("""
        SELECT state FROM jmap_sync_state WHERE local_account_id = ? AND scope = ?;
        """)
        try stmt.bind(1, accountID)
        try stmt.bind(2, scope)
        var s: String?
        try stmt.forEachRow { row in s = row.string(0); return false }
        return s
    }

    public func setSyncState(accountID: Int64, scope: String, state: String) throws {
        let stmt = try conn.prepare("""
        INSERT INTO jmap_sync_state(local_account_id, scope, state, updated_at)
        VALUES(?, ?, ?, ?)
        ON CONFLICT(local_account_id, scope) DO UPDATE SET
            state      = excluded.state,
            updated_at = excluded.updated_at;
        """)
        try stmt.bind(1, accountID)
        try stmt.bind(2, scope)
        try stmt.bind(3, state)
        try stmt.bind(4, Int64(Date().timeIntervalSince1970))
        try stmt.run()
    }

    // MARK: - Flag mutation + delete

    public func messageFlags(messageRowID: Int64) throws -> MessageFlags? {
        let stmt = try conn.prepare("SELECT flags FROM messages WHERE id = ?;")
        try stmt.bind(1, messageRowID)
        var flags: MessageFlags?
        try stmt.forEachRow { row in
            flags = MessageFlags(rawValue: row.int(0))
            return false
        }
        return flags
    }

    public func updateMessageFlags(messageRowID: Int64, flags: MessageFlags) throws {
        let stmt = try conn.prepare("UPDATE messages SET flags = ? WHERE id = ?;")
        try stmt.bind(1, Int64(flags.rawValue))
        try stmt.bind(2, messageRowID)
        try stmt.run()
    }

    /// Delete a message and let cascading clean up bodies / attachments /
    /// NLP / forensics / JMAP map rows. FTS rows are cleared by hand because
    /// SQLite doesn't trigger external FTS5 deletes from foreign keys.
    public func deleteMessage(messageRowID: Int64) throws {
        try conn.transaction {
            let yearStmt = try conn.prepare("""
            SELECT CAST(strftime('%Y', date_unix, 'unixepoch') AS INTEGER) FROM messages WHERE id = ?;
            """)
            try yearStmt.bind(1, messageRowID)
            var year: Int = 0
            try yearStmt.forEachRow { row in year = row.int(0); return false }
            if year > 0 {
                try conn.exec("DELETE FROM messages_fts_\(year) WHERE rowid = \(messageRowID);")
            }
            let del = try conn.prepare("DELETE FROM messages WHERE id = ?;")
            try del.bind(1, messageRowID)
            try del.run()
        }
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

    /// Attachment metadata for a message — does not load blob bytes.
    public func attachments(messageRowID: Int64) throws -> [AttachmentRef] {
        let stmt = try conn.prepare("""
        SELECT id, message_id, filename, mime_type, size_bytes, sha256
          FROM attachments
         WHERE message_id = ?
         ORDER BY id ASC;
        """)
        try stmt.bind(1, messageRowID)
        var out: [AttachmentRef] = []
        try stmt.forEachRow { row in
            out.append(AttachmentRef(
                id: row.int64(0),
                messageRowID: row.int64(1),
                filename: row.string(2) ?? "",
                mimeType: row.string(3),
                sizeBytes: row.isNull(4) ? nil : row.int64(4),
                sha256Hex: row.string(5)
            ))
            return true
        }
        return out
    }

    /// Load attachment bytes by its SHA-256 reference.
    public func loadAttachmentData(sha256Hex: String) -> Data? {
        blobs.get(sha256Hex)
    }

    // MARK: - Search

    /// Full-text search across year shards. Returns BM25-ranked hits with
    /// highlighted snippets, merged in Swift across the relevant shards.
    ///
    /// - `since`: only consider messages newer than this date. We use it both
    ///   to skip shards entirely and to apply a per-shard `date_unix >` filter.
    /// - BM25 column weights (10, 5, 2, 1) bias ranking toward subject and
    ///   sender matches.
    public func search(
        _ query: String,
        accountID: Int64? = nil,
        since: Date? = nil,
        limit: Int = 50
    ) throws -> [SearchHit] {
        let shards = relevantShards(since: since)
        if shards.isEmpty { return [] }

        var allHits: [SearchHit] = []
        allHits.reserveCapacity(shards.count * limit)

        for year in shards {
            let table = "messages_fts_\(year)"
            var clauses = ["\(table) MATCH ?"]
            if accountID != nil { clauses.append("m.account_id = ?") }
            if since != nil { clauses.append("m.date_unix > ?") }
            let sql = """
            SELECT m.id, m.message_id, m.subject, m.from_addr, m.date_unix,
                   snippet(\(table), 3, '⟦', '⟧', '…', 12) AS snip,
                   bm25(\(table), 10.0, 5.0, 2.0, 1.0) AS score
              FROM \(table)
              JOIN messages m ON m.id = \(table).rowid
             WHERE \(clauses.joined(separator: " AND "))
             ORDER BY score
             LIMIT ?;
            """
            let stmt = try conn.prepare(sql)
            var idx: Int32 = 1
            try stmt.bind(idx, query); idx += 1
            if let accountID { try stmt.bind(idx, accountID); idx += 1 }
            if let since { try stmt.bind(idx, Int64(since.timeIntervalSince1970)); idx += 1 }
            try stmt.bind(idx, Int64(limit))

            try stmt.forEachRow { row in
                allHits.append(SearchHit(
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
        }

        // BM25 lower = better. Sort and trim across shards.
        allHits.sort { $0.score < $1.score }
        if allHits.count > limit { allHits = Array(allHits.prefix(limit)) }
        return allHits
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

    public func shardYears() -> [Int] { knownShards.sorted() }

    public func accountsList() throws -> [(id: Int64, name: String, address: String)] {
        let stmt = try conn.prepare("SELECT id, name, address FROM accounts ORDER BY name;")
        var out: [(Int64, String, String)] = []
        try stmt.forEachRow { row in
            out.append((row.int64(0), row.string(1) ?? "", row.string(2) ?? ""))
            return true
        }
        return out
    }

    public func folders(accountID: Int64) throws -> [String] {
        let stmt = try conn.prepare("SELECT path FROM folders WHERE account_id = ? ORDER BY path;")
        try stmt.bind(1, accountID)
        var out: [String] = []
        try stmt.forEachRow { row in
            if let p = row.string(0) { out.append(p) }
            return true
        }
        return out
    }

    public func messageCount(accountID: Int64, folder: String) throws -> Int64 {
        let stmt = try conn.prepare("""
        SELECT COUNT(*) FROM messages m JOIN folders f ON f.id = m.folder_id
         WHERE f.account_id = ? AND f.path = ?;
        """)
        try stmt.bind(1, accountID)
        try stmt.bind(2, folder)
        var n: Int64 = 0
        try stmt.forEachRow { row in n = row.int64(0); return false }
        return n
    }

    public func checkpoint() throws {
        try conn.exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    // MARK: - Helpers

    // MARK: - NLP

    /// Lazy on-device NLP. Returns the cached result if present, otherwise
    /// runs sentiment / language / entity / keyword extraction over the
    /// message body and stores it for next time. Identity bodies (mailing-
    /// list duplicates) don't dedupe at this layer yet — each message gets
    /// its own analysis row.
    @discardableResult
    public func ensureNLP(messageRowID: Int64) throws -> EmailNLP {
        if let cached = try loadNLP(messageRowID: messageRowID) { return cached }
        guard let body = try loadBody(messageRowID: messageRowID),
              let text = body.plain ?? stripHTML(body.html),
              !text.isEmpty
        else {
            let empty = EmailNLP.empty
            try persistNLP(messageRowID: messageRowID, nlp: empty)
            return empty
        }
        let nlp = EmailNLPAnalyzer.analyze(text: text)
        try persistNLP(messageRowID: messageRowID, nlp: nlp)
        return nlp
    }

    /// IDs of messages that don't yet have an NLP row. Newest first so the
    /// user-visible mail gets analyzed first; perfect for incremental
    /// background runs.
    public func unanalyzedMessageIDs(accountID: Int64, limit: Int = 200) throws -> [Int64] {
        let stmt = try conn.prepare("""
        SELECT m.id FROM messages m
          LEFT JOIN message_nlp n ON n.message_id = m.id
         WHERE m.account_id = ? AND n.message_id IS NULL
         ORDER BY m.date_unix DESC, m.id DESC
         LIMIT ?;
        """)
        try stmt.bind(1, accountID)
        try stmt.bind(2, Int64(limit))
        var out: [Int64] = []
        try stmt.forEachRow { row in out.append(row.int64(0)); return true }
        return out
    }

    public func analysisProgress(accountID: Int64) throws -> AnalysisProgress {
        let total = try messageCountFor(accountID: accountID)
        let analyzedStmt = try conn.prepare("""
        SELECT COUNT(*) FROM message_nlp n
          JOIN messages m ON m.id = n.message_id
         WHERE m.account_id = ?;
        """)
        try analyzedStmt.bind(1, accountID)
        var analyzed: Int64 = 0
        try analyzedStmt.forEachRow { row in analyzed = row.int64(0); return false }
        return AnalysisProgress(analyzed: analyzed, total: total)
    }

    private func messageCountFor(accountID: Int64) throws -> Int64 {
        let stmt = try conn.prepare("SELECT COUNT(*) FROM messages WHERE account_id = ?;")
        try stmt.bind(1, accountID)
        var n: Int64 = 0
        try stmt.forEachRow { row in n = row.int64(0); return false }
        return n
    }

    /// Run NLP for up to `batchSize` unanalyzed messages. Caller drives the
    /// outer loop and yields the actor between batches so search / paging
    /// stay responsive during a long catch-up.
    @discardableResult
    public func analyzeBatch(accountID: Int64, batchSize: Int = 100) throws -> Int {
        let ids = try unanalyzedMessageIDs(accountID: accountID, limit: batchSize)
        for id in ids {
            _ = try ensureNLP(messageRowID: id)
        }
        return ids.count
    }

    /// Process a batch end-to-end: NLP + forensics. Used by the BackgroundAnalyzer
    /// so we walk each unprocessed message exactly once and share the body load.
    @discardableResult
    public func processBatch(accountID: Int64, batchSize: Int = 100) throws -> Int {
        let ids = try unprocessedMessageIDs(accountID: accountID, limit: batchSize)
        for id in ids {
            _ = try ensureNLP(messageRowID: id)
            _ = try ensureForensics(messageRowID: id)
        }
        return ids.count
    }

    /// Messages missing NLP *or* forensics. Newest first.
    public func unprocessedMessageIDs(accountID: Int64, limit: Int = 200) throws -> [Int64] {
        let stmt = try conn.prepare("""
        SELECT m.id FROM messages m
          LEFT JOIN message_nlp       n ON n.message_id = m.id
          LEFT JOIN message_forensics f ON f.message_id = m.id
         WHERE m.account_id = ? AND (n.message_id IS NULL OR f.message_id IS NULL)
         ORDER BY m.date_unix DESC, m.id DESC
         LIMIT ?;
        """)
        try stmt.bind(1, accountID)
        try stmt.bind(2, Int64(limit))
        var out: [Int64] = []
        try stmt.forEachRow { row in out.append(row.int64(0)); return true }
        return out
    }

    public func processingProgress(accountID: Int64) throws -> AnalysisProgress {
        let total = try messageCountFor(accountID: accountID)
        let stmt = try conn.prepare("""
        SELECT COUNT(*) FROM messages m
          JOIN message_nlp       n ON n.message_id = m.id
          JOIN message_forensics f ON f.message_id = m.id
         WHERE m.account_id = ?;
        """)
        try stmt.bind(1, accountID)
        var done: Int64 = 0
        try stmt.forEachRow { row in done = row.int64(0); return false }
        return AnalysisProgress(analyzed: done, total: total)
    }

    // MARK: - NLP aggregates (analytics)

    public func sentimentDistribution(accountID: Int64) throws -> SentimentDistribution {
        let stmt = try conn.prepare("""
        SELECT
            SUM(CASE WHEN sentiment < -0.6 THEN 1 ELSE 0 END),
            SUM(CASE WHEN sentiment >= -0.6 AND sentiment < -0.2 THEN 1 ELSE 0 END),
            SUM(CASE WHEN sentiment >= -0.2 AND sentiment <  0.2 THEN 1 ELSE 0 END),
            SUM(CASE WHEN sentiment >=  0.2 AND sentiment <  0.6 THEN 1 ELSE 0 END),
            SUM(CASE WHEN sentiment >= 0.6 THEN 1 ELSE 0 END)
          FROM message_nlp n
          JOIN messages m ON m.id = n.message_id
         WHERE m.account_id = ?;
        """)
        try stmt.bind(1, accountID)
        var vn = 0, n = 0, ne = 0, po = 0, vp = 0
        try stmt.forEachRow { row in
            vn = row.int(0); n = row.int(1); ne = row.int(2); po = row.int(3); vp = row.int(4)
            return false
        }
        return SentimentDistribution(
            veryNegative: vn, negative: n, neutral: ne, positive: po, veryPositive: vp
        )
    }

    public func topKeywords(accountID: Int64, limit: Int = 30) throws -> [KeywordCount] {
        // SQLite's built-in json1 extension lets us explode each
        // keywords_json array row into one row per keyword.
        let stmt = try conn.prepare("""
        SELECT je.value AS keyword, COUNT(*) AS n
          FROM message_nlp mn
          JOIN messages m ON m.id = mn.message_id
          JOIN json_each(mn.keywords_json) je
         WHERE m.account_id = ?
         GROUP BY keyword
         ORDER BY n DESC, keyword ASC
         LIMIT ?;
        """)
        try stmt.bind(1, accountID)
        try stmt.bind(2, Int64(limit))
        var out: [KeywordCount] = []
        try stmt.forEachRow { row in
            if let kw = row.string(0) {
                out.append(KeywordCount(keyword: kw, count: row.int(1)))
            }
            return true
        }
        return out
    }

    public func topEntities(accountID: Int64, kind: EmailEntity.Kind? = nil, limit: Int = 30) throws -> [EntityCount] {
        let kindFilter: String
        if let kind { kindFilter = "AND json_extract(je.value, '$.kind') = '\(kind.rawValue)'" }
        else        { kindFilter = "" }
        let sql = """
        SELECT json_extract(je.value, '$.kind') AS kind,
               json_extract(je.value, '$.text') AS text,
               COUNT(*) AS n
          FROM message_nlp mn
          JOIN messages m ON m.id = mn.message_id
          JOIN json_each(mn.entities_json) je
         WHERE m.account_id = ? \(kindFilter)
         GROUP BY kind, text
         ORDER BY n DESC, text ASC
         LIMIT ?;
        """
        let stmt = try conn.prepare(sql)
        try stmt.bind(1, accountID)
        try stmt.bind(2, Int64(limit))
        var out: [EntityCount] = []
        try stmt.forEachRow { row in
            let kindStr = row.string(0) ?? "other"
            let text = row.string(1) ?? ""
            let entityKind = EmailEntity.Kind(rawValue: kindStr) ?? .other
            out.append(EntityCount(
                entity: EmailEntity(kind: entityKind, text: text),
                count: row.int(2)
            ))
            return true
        }
        return out
    }

    public func sentimentTimeline(accountID: Int64) throws -> [SentimentMonth] {
        let stmt = try conn.prepare("""
        SELECT strftime('%Y-%m', m.date_unix, 'unixepoch') AS month,
               AVG(n.sentiment) AS mean,
               COUNT(*) AS c
          FROM message_nlp n
          JOIN messages m ON m.id = n.message_id
         WHERE m.account_id = ?
         GROUP BY month
         ORDER BY month ASC;
        """)
        try stmt.bind(1, accountID)
        var out: [SentimentMonth] = []
        try stmt.forEachRow { row in
            if let m = row.string(0) {
                let mean = Double(row.string(1) ?? "0") ?? 0
                out.append(SentimentMonth(month: m, meanSentiment: mean, messageCount: row.int(2)))
            }
            return true
        }
        return out
    }

    public func loadNLP(messageRowID: Int64) throws -> EmailNLP? {
        let stmt = try conn.prepare("""
        SELECT sentiment, language, entities_json, keywords_json
          FROM message_nlp WHERE message_id = ?;
        """)
        try stmt.bind(1, messageRowID)
        var found: EmailNLP?
        try stmt.forEachRow { row in
            let sentiment = Double(row.string(0) ?? "0") ?? 0
            let language = row.isNull(1) ? nil : row.string(1)
            let entities: [EmailEntity] = decodeJSON(row.string(2)) ?? []
            let keywords: [String]     = decodeJSON(row.string(3)) ?? []
            found = EmailNLP(sentiment: sentiment, language: language,
                             entities: entities, keywords: keywords)
            return false
        }
        return found
    }

    private func persistNLP(messageRowID: Int64, nlp: EmailNLP) throws {
        let enc = JSONEncoder()
        let entJSON = (try? String(data: enc.encode(nlp.entities), encoding: .utf8)) ?? "[]"
        let kwJSON  = (try? String(data: enc.encode(nlp.keywords), encoding: .utf8)) ?? "[]"
        let stmt = try conn.prepare("""
        INSERT INTO message_nlp(message_id, sentiment, language, entities_json, keywords_json, analyzed_at)
        VALUES(?, ?, ?, ?, ?, ?)
        ON CONFLICT(message_id) DO UPDATE SET
            sentiment     = excluded.sentiment,
            language      = excluded.language,
            entities_json = excluded.entities_json,
            keywords_json = excluded.keywords_json,
            analyzed_at   = excluded.analyzed_at;
        """)
        try stmt.bind(1, messageRowID)
        try stmt.bind(2, String(nlp.sentiment))
        try stmt.bind(3, nlp.language)
        try stmt.bind(4, entJSON)
        try stmt.bind(5, kwJSON)
        try stmt.bind(6, Int64(Date().timeIntervalSince1970))
        try stmt.run()
    }

    // MARK: - Forensics

    @discardableResult
    public func ensureForensics(messageRowID: Int64) throws -> ForensicResult {
        if let cached = try loadForensics(messageRowID: messageRowID) { return cached }
        let meta = try fetchMessageMeta(messageRowID: messageRowID)
        let body = try loadBody(messageRowID: messageRowID)
        let result = EmailForensicAnalyzer.analyze(
            subject: meta?.subject ?? "",
            fromAddress: meta?.fromAddr ?? "",
            plainBody: body?.plain,
            htmlBody: body?.html
        )
        try persistForensics(messageRowID: messageRowID, result: result)
        return result
    }

    public func loadForensics(messageRowID: Int64) throws -> ForensicResult? {
        let stmt = try conn.prepare("""
        SELECT phishing_score, phishing_level, phishing_reasons_json, pii_json
          FROM message_forensics WHERE message_id = ?;
        """)
        try stmt.bind(1, messageRowID)
        var result: ForensicResult?
        try stmt.forEachRow { row in
            let score = row.int(0)
            let levelRaw = row.string(1) ?? "none"
            let level = PhishingFinding.RiskLevel(rawValue: levelRaw) ?? .none
            let reasons: [PhishingReason] = self.decodeJSON(row.string(2)) ?? []
            let pii: [PIIFinding] = self.decodeJSON(row.string(3)) ?? []
            result = ForensicResult(
                phishing: PhishingFinding(level: level, score: score, reasons: reasons),
                pii: pii
            )
            return false
        }
        return result
    }

    private func persistForensics(messageRowID: Int64, result: ForensicResult) throws {
        let enc = JSONEncoder()
        let reasonsJSON = (try? String(data: enc.encode(result.phishing.reasons), encoding: .utf8)) ?? "[]"
        let piiJSON     = (try? String(data: enc.encode(result.pii), encoding: .utf8)) ?? "[]"
        let stmt = try conn.prepare("""
        INSERT INTO message_forensics(message_id, phishing_score, phishing_level, phishing_reasons_json, pii_json, analyzed_at)
        VALUES(?, ?, ?, ?, ?, ?)
        ON CONFLICT(message_id) DO UPDATE SET
            phishing_score        = excluded.phishing_score,
            phishing_level        = excluded.phishing_level,
            phishing_reasons_json = excluded.phishing_reasons_json,
            pii_json              = excluded.pii_json,
            analyzed_at           = excluded.analyzed_at;
        """)
        try stmt.bind(1, messageRowID)
        try stmt.bind(2, Int64(result.phishing.score))
        try stmt.bind(3, result.phishing.level.rawValue)
        try stmt.bind(4, reasonsJSON)
        try stmt.bind(5, piiJSON)
        try stmt.bind(6, Int64(Date().timeIntervalSince1970))
        try stmt.run()
    }

    private func fetchMessageMeta(messageRowID: Int64) throws -> (subject: String, fromAddr: String)? {
        let stmt = try conn.prepare("SELECT subject, from_addr FROM messages WHERE id = ?;")
        try stmt.bind(1, messageRowID)
        var meta: (String, String)?
        try stmt.forEachRow { row in
            meta = (row.string(0) ?? "", row.string(1) ?? "")
            return false
        }
        return meta
    }

    private func decodeJSON<T: Decodable>(_ s: String?) -> T? {
        guard let s, let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func stripHTML(_ html: String?) -> String? {
        guard let html else { return nil }
        // Very cheap tag strip — enough for keyword/entity work. Detail view
        // still renders the real HTML via WKWebView; this is only the text
        // feed for the NLP pass.
        var out = ""
        var inTag = false
        for ch in html {
            if inTag {
                if ch == ">" { inTag = false }
            } else {
                if ch == "<" { inTag = true } else { out.append(ch) }
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeSnippet(plain: String?, html: String?) -> String? {
        let raw = plain ?? html
        guard let raw, !raw.isEmpty else { return nil }
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if collapsed.count <= 180 { return collapsed }
        return String(collapsed.prefix(180)) + "…"
    }
}
