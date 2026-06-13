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

    private static let schemaVersion: Int64 = 2

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

    private func lookupMessageRowID(accountID: Int64, messageID: String) throws -> Int64? {
        let stmt = try conn.prepare("SELECT id FROM messages WHERE account_id = ? AND message_id = ?;")
        try stmt.bind(1, accountID)
        try stmt.bind(2, messageID)
        var id: Int64 = 0
        try stmt.forEachRow { row in id = row.int64(0); return false }
        return id == 0 ? nil : id
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

    private func makeSnippet(plain: String?, html: String?) -> String? {
        let raw = plain ?? html
        guard let raw, !raw.isEmpty else { return nil }
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if collapsed.count <= 180 { return collapsed }
        return String(collapsed.prefix(180)) + "…"
    }
}
