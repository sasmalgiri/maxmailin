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
    /// Per-month FTS shard keys in "YYYY-MM" form. v6 used "YYYY" year
    /// keys; v7 introduces month granularity to keep each shard under
    /// ~100 k documents at 20 M corpus scale.
    private var knownShards: Set<String> = []

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

    private static let schemaVersion: Int64 = 12

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

        if current < 6 {
            try conn.transaction {
                let cols = try Self.columnsOf("attachments", in: conn)
                if !cols.contains("external_id") {
                    try conn.exec("ALTER TABLE attachments ADD COLUMN external_id TEXT;")
                }
                try conn.exec("CREATE INDEX IF NOT EXISTS idx_attachments_external_id ON attachments(external_id);")
                try conn.exec("INSERT OR REPLACE INTO schema_meta(key, value) VALUES('version', '6');")
            }
        }

        if current < 7 {
            // v7: month-grained FTS shards + denormalized date / message-id
            // into the FTS table so search no longer pays the JOIN cost.
            // Year shards collapsed search performance once each shard
            // crossed ~500 k docs (measured: 25 s p50 at 5 M corpus).
            try conn.transaction {
                // Drop the v6 year-shard tables and registry.
                let oldYears = try Self.findOldYearShards(in: conn)
                for year in oldYears {
                    try conn.exec("DROP TABLE IF EXISTS messages_fts_\(year);")
                }
                try conn.exec("DROP TABLE IF EXISTS fts_shards;")
                try conn.exec("""
                CREATE TABLE fts_shards (
                    month TEXT PRIMARY KEY    -- "YYYY-MM"
                );
                """)

                // Reindex every message into the new month shards. Group
                // by month so we create + populate each shard once.
                let months = try Self.distinctMessageMonths(in: conn)
                for month in months {
                    try Self.createMonthShardSQL(month: month, in: conn)
                    try conn.exec("INSERT OR IGNORE INTO fts_shards(month) VALUES('\(month)');")
                    let table = Self.monthTableName(month: month)
                    let reidx = try conn.prepare("""
                    INSERT INTO \(table)(rowid, subject, from_addr, to_addrs, body, date_unix, message_id)
                    SELECT m.id, m.subject, m.from_addr, m.to_addrs, COALESCE(b.plain_body, ''),
                           m.date_unix, m.message_id
                      FROM messages m
                      LEFT JOIN message_bodies b ON b.message_id = m.id
                     WHERE strftime('%Y-%m', m.date_unix, 'unixepoch') = ?;
                    """)
                    try reidx.bind(1, month)
                    try reidx.run()
                }

                try conn.exec("INSERT OR REPLACE INTO schema_meta(key, value) VALUES('version', '7');")
            }
        }

        if current < 8 {
            // IMAP local row ↔ (folder, UIDVALIDITY, UID) map. UIDs are
            // only meaningful within a (folder, UIDVALIDITY) scope per
            // RFC 3501 §2.3.1.1, so the unique key carries both.
            try conn.transaction {
                try conn.exec("""
                CREATE TABLE IF NOT EXISTS imap_message_map (
                    local_id     INTEGER PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
                    folder_id    INTEGER NOT NULL REFERENCES folders(id)  ON DELETE CASCADE,
                    uid_validity INTEGER NOT NULL,
                    uid          INTEGER NOT NULL,
                    UNIQUE(folder_id, uid_validity, uid)
                );
                """)
                try conn.exec("INSERT OR REPLACE INTO schema_meta(key, value) VALUES('version', '8');")
            }
        }

        if current < 9 {
            // Automation rules: per-account ordered list of
            // condition→action sets that the RulesEngine evaluates against
            // each newly ingested message. Conditions and actions are
            // serialised as JSON so the storage layer doesn't need to know
            // their shape.
            try conn.transaction {
                try conn.exec("""
                CREATE TABLE IF NOT EXISTS automation_rules (
                    id              INTEGER PRIMARY KEY AUTOINCREMENT,
                    account_id      INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    name            TEXT NOT NULL,
                    enabled         INTEGER NOT NULL DEFAULT 1,
                    priority        INTEGER NOT NULL DEFAULT 0,
                    conditions_json TEXT NOT NULL,
                    actions_json    TEXT NOT NULL,
                    created_at      INTEGER NOT NULL
                );
                """)
                try conn.exec("CREATE INDEX IF NOT EXISTS idx_rules_account ON automation_rules(account_id, enabled, priority DESC);")
                // Tracks rule applications so re-running the engine is
                // idempotent — we skip messages whose rule was already
                // applied.
                try conn.exec("""
                CREATE TABLE IF NOT EXISTS rule_applications (
                    message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                    rule_id    INTEGER NOT NULL REFERENCES automation_rules(id) ON DELETE CASCADE,
                    applied_at INTEGER NOT NULL,
                    PRIMARY KEY(message_id, rule_id)
                );
                """)
                try conn.exec("INSERT OR REPLACE INTO schema_meta(key, value) VALUES('version', '9');")
            }
        }

        if current < 10 {
            // HMAC-chained audit log. Each entry's hash is HMAC(payload ||
            // previous_entry_hash) keyed by a per-installation secret; the
            // chain makes silent tampering detectable across the whole log.
            try conn.transaction {
                try conn.exec("""
                CREATE TABLE IF NOT EXISTS audit_log (
                    id            INTEGER PRIMARY KEY AUTOINCREMENT,
                    occurred_at   INTEGER NOT NULL,
                    actor         TEXT NOT NULL,
                    action        TEXT NOT NULL,
                    subject_kind  TEXT NOT NULL,
                    subject_id    TEXT NOT NULL,
                    details_json  TEXT NOT NULL,
                    prev_hash     TEXT NOT NULL,
                    entry_hash    TEXT NOT NULL
                );
                """)
                try conn.exec("CREATE INDEX IF NOT EXISTS idx_audit_subject ON audit_log(subject_kind, subject_id);")
                try conn.exec("INSERT OR REPLACE INTO schema_meta(key, value) VALUES('version', '10');")
            }
        }

        if current < 11 {
            // Per-message integrity seals. content_sha256 is a SHA-256 over
            // the canonical projection of the message row (header fields,
            // bodies, sorted attachment hashes). Verification recomputes the
            // same projection from the current row and compares. Drift means
            // either deliberate tampering or a corrupted row.
            try conn.transaction {
                try conn.exec("""
                CREATE TABLE IF NOT EXISTS message_seals (
                    message_id      INTEGER PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
                    sealed_at       INTEGER NOT NULL,
                    content_sha256  TEXT NOT NULL
                );
                """)
                try conn.exec("INSERT OR REPLACE INTO schema_meta(key, value) VALUES('version', '11');")
            }
        }

        if current < 12 {
            // Bates numbering for legal production. Each message that's been
            // produced gets a permanent sequential identifier under a fixed
            // prefix; once assigned a number cannot change without breaking
            // citations in court filings. The sequence column is the raw
            // integer (assigned in chronological order); bates_number is the
            // pre-formatted "PREFIX000123" string we render.
            try conn.transaction {
                try conn.exec("""
                CREATE TABLE IF NOT EXISTS bates_config (
                    key    TEXT PRIMARY KEY,
                    value  TEXT NOT NULL
                );
                """)
                try conn.exec("""
                CREATE TABLE IF NOT EXISTS bates_assignments (
                    message_id    INTEGER PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
                    sequence      INTEGER NOT NULL UNIQUE,
                    bates_number  TEXT    NOT NULL UNIQUE,
                    assigned_at   INTEGER NOT NULL
                );
                """)
                try conn.exec("CREATE INDEX IF NOT EXISTS idx_bates_sequence ON bates_assignments(sequence);")
                try conn.exec("INSERT OR REPLACE INTO schema_meta(key, value) VALUES('version', '12');")
            }
        }
    }

    /// Discover any old year-grained shard tables that need to be dropped
    /// during the v7 migration. Returns the list of integer years.
    private static func findOldYearShards(in conn: SQLiteConnection) throws -> [Int] {
        let stmt = try conn.prepare("""
        SELECT name FROM sqlite_master
         WHERE type='table' AND name LIKE 'messages_fts_%'
           AND length(name) = length('messages_fts_') + 4;
        """)
        var out: [Int] = []
        try stmt.forEachRow { row in
            if let n = row.string(0),
               let y = Int(n.dropFirst("messages_fts_".count)) {
                out.append(y)
            }
            return true
        }
        return out
    }

    private static func distinctMessageMonths(in conn: SQLiteConnection) throws -> [String] {
        let stmt = try conn.prepare("""
        SELECT DISTINCT strftime('%Y-%m', date_unix, 'unixepoch') AS m
          FROM messages
         WHERE date_unix IS NOT NULL
         ORDER BY m;
        """)
        var out: [String] = []
        try stmt.forEachRow { row in
            if let s = row.string(0) { out.append(s) }
            return true
        }
        return out
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

    /// Legacy year-shard creator kept only so the v2 migration step in
    /// `migrate(_:)` compiles. v7 drops every messages_fts_<year> table
    /// these create and replaces them with messages_fts_<YYYY_MM>.
    private static func createShardSQL(year: Int, in conn: SQLiteConnection) throws {
        try conn.exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts_\(year) USING fts5(
            subject, from_addr, to_addrs, body,
            tokenize='porter unicode61'
        );
        """)
    }

    /// Build the FTS5 table for one month. Denormalised UNINDEXED columns —
    /// date_unix + message_id — let the search SQL return result rows
    /// directly from the FTS table; the JOIN to messages that dominated
    /// year-shard search at 5 M corpus is gone.
    static func createMonthShardSQL(month: String, in conn: SQLiteConnection) throws {
        let table = monthTableName(month: month)
        try conn.exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS \(table) USING fts5(
            subject, from_addr, to_addrs, body,
            date_unix UNINDEXED,
            message_id UNINDEXED,
            tokenize='porter unicode61'
        );
        """)
    }

    /// "YYYY_MM" — underscored so it's a legal SQL identifier without
    /// quoting. The fts_shards table stores the dash form ("YYYY-MM") for
    /// readability; everywhere else we round-trip through these helpers.
    static func monthTableName(month: String) -> String {
        "messages_fts_\(month.replacingOccurrences(of: "-", with: "_"))"
    }

    /// Day-keyed cache so the per-message monthKey lookup on the bulkIngest
    /// hot path collapses to a hash lookup after the first hit for each day.
    /// Bounded by the date span of the inserted data — at 10 years that's
    /// only 3,650 entries max.
    nonisolated(unsafe) private static var monthKeyCache: [Int64: String] = [:]
    nonisolated(unsafe) private static let monthKeyCacheLock = NSLock()

    /// Compute "YYYY-MM" for a Date in UTC without going through Calendar.
    /// Pure integer arithmetic — measured ~150 ns/call vs Calendar's
    /// ~10–30 µs, and the cache below collapses repeats on the same day.
    static func monthKey(for date: Date) -> String {
        let secondsSinceRef = date.timeIntervalSinceReferenceDate
        let dayKey = Int64(floor(secondsSinceRef / 86400))

        monthKeyCacheLock.lock()
        if let cached = monthKeyCache[dayKey] {
            monthKeyCacheLock.unlock()
            return cached
        }
        monthKeyCacheLock.unlock()

        let s = computeMonthKey(dayKey: Int(dayKey))

        monthKeyCacheLock.lock()
        monthKeyCache[dayKey] = s
        monthKeyCacheLock.unlock()
        return s
    }

    /// Reference date is 2001-01-01 UTC, a Monday. Day 0 → 2001-01.
    private static func computeMonthKey(dayKey: Int) -> String {
        var dayOfYear = dayKey
        var year = 2001

        // Walk forward / backward year by year. Tight loop; even at +50
        // years (2051), it's ≤50 iterations.
        if dayOfYear >= 0 {
            while true {
                let yearDays = isLeapYear(year) ? 366 : 365
                if dayOfYear < yearDays { break }
                dayOfYear -= yearDays
                year += 1
            }
        } else {
            while dayOfYear < 0 {
                year -= 1
                dayOfYear += isLeapYear(year) ? 366 : 365
            }
        }

        // Walk months.
        let monthLengths: [Int] = isLeapYear(year)
            ? [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            : [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        var month = 1
        var dayInMonth = dayOfYear
        for days in monthLengths {
            if dayInMonth < days { break }
            dayInMonth -= days
            month += 1
        }

        return formatYearMonth(year: year, month: month)
    }

    @inline(__always)
    private static func isLeapYear(_ y: Int) -> Bool {
        (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0)
    }

    @inline(__always)
    private static func formatYearMonth(year: Int, month: Int) -> String {
        // Two simple digit-by-digit fills, no String(format:) overhead.
        var s = ""
        s.reserveCapacity(7)
        let y = year
        s.append(Character(Unicode.Scalar(48 + ((y / 1000) % 10))!))
        s.append(Character(Unicode.Scalar(48 + ((y / 100)  % 10))!))
        s.append(Character(Unicode.Scalar(48 + ((y / 10)   % 10))!))
        s.append(Character(Unicode.Scalar(48 + ( y         % 10))!))
        s.append("-")
        s.append(Character(Unicode.Scalar(48 + ((month / 10) % 10))!))
        s.append(Character(Unicode.Scalar(48 + ( month        % 10))!))
        return s
    }

    private static func loadKnownShards(_ conn: SQLiteConnection) throws -> Set<String> {
        var out = Set<String>()
        let stmt = try conn.prepare("SELECT month FROM fts_shards;")
        try stmt.forEachRow { row in
            if let m = row.string(0) { out.insert(m) }
            return true
        }
        return out
    }

    private func ensureShard(forMonth month: String) throws -> String {
        let table = Self.monthTableName(month: month)
        if knownShards.contains(month) { return table }
        try Self.createMonthShardSQL(month: month, in: conn)
        let stmt = try conn.prepare("INSERT OR IGNORE INTO fts_shards(month) VALUES(?);")
        try stmt.bind(1, month)
        try stmt.run()
        knownShards.insert(month)
        return table
    }

    private func relevantShards(since: Date?) -> [String] {
        let sorted = knownShards.sorted()
        guard let since else { return sorted }
        let lowerKey = Self.monthKey(for: since)
        return sorted.filter { $0 >= lowerKey }
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

        // 2. Ensure FTS shards for every month present in this batch.
        var monthForMsg: [String] = []
        monthForMsg.reserveCapacity(messages.count)
        var distinctMonths = Set<String>()
        for m in messages {
            let k = Self.monthKey(for: m.date)
            monthForMsg.append(k)
            distinctMonths.insert(k)
        }
        for m in distinctMonths { _ = try ensureShard(forMonth: m) }

        // 3. Prepare every per-shard FTS insert statement once, keyed by month.
        var ftsInserts: [String: SQLiteStatement] = [:]
        for m in distinctMonths {
            let table = Self.monthTableName(month: m)
            ftsInserts[m] = try conn.prepare("""
            INSERT INTO \(table)(rowid, subject, from_addr, to_addrs, body, date_unix, message_id)
            VALUES(?, ?, ?, ?, ?, ?, ?);
            """)
        }

        let stmts = try BulkStatements(conn: conn, ftsInserts: ftsInserts)
        var folderCache: [Int64: [String: Int64]] = [:]
        var inserted = 0

        try conn.transaction {
            inserted = try self.runBulkInsertLoop(
                messages: messages,
                monthForMsg: monthForMsg,
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
        let ftsInserts: [String: SQLiteStatement]

        init(conn: SQLiteConnection, ftsInserts: [String: SQLiteStatement]) throws {
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
            INSERT INTO attachments(message_id, filename, mime_type, size_bytes, sha256, external_id)
            VALUES(?, ?, ?, ?, ?, ?);
            """)
            self.selFolderID = try conn.prepare("SELECT id FROM folders WHERE account_id = ? AND path = ?;")
            self.insFolder = try conn.prepare("INSERT INTO folders(account_id, path) VALUES(?, ?) RETURNING id;")
            self.ftsInserts = ftsInserts
        }
    }

    private func runBulkInsertLoop(
        messages: [IngestMessage],
        monthForMsg: [String],
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
                // Prefer the size of the actual blob bytes we wrote; fall
                // back to the caller-supplied hint (e.g., JMAP's reported size)
                // so attachment list rows still show size without bytes.
                try stmts.insAtt.bind(4, attSizes[i][j] ?? att.sizeHint)
                try stmts.insAtt.bind(5, attHashes[i][j])
                try stmts.insAtt.bind(6, att.externalID)
                try stmts.insAtt.run()
            }

            let fts = stmts.ftsInserts[monthForMsg[i]]!
            fts.reset()
            try fts.bind(1, newID)
            try fts.bind(2, m.subject)
            try fts.bind(3, m.fromAddress)
            try fts.bind(4, m.toAddresses.joined(separator: " "))
            try fts.bind(5, m.plainBody ?? "")
            try fts.bind(6, Int64(m.date.timeIntervalSince1970))
            try fts.bind(7, m.messageID)
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

    // MARK: - IMAP id mapping

    /// Record (localRowID ↔ folder UID) for an IMAP-fetched message so
    /// later flag writes can target it via UID STORE. uidValidity guards
    /// against the server reshuffling its UID space.
    public func linkIMAP(
        localRowID: Int64,
        folderID: Int64,
        uidValidity: Int64,
        uid: Int64
    ) throws {
        let stmt = try conn.prepare("""
        INSERT INTO imap_message_map(local_id, folder_id, uid_validity, uid)
        VALUES(?, ?, ?, ?)
        ON CONFLICT(local_id) DO UPDATE SET
            folder_id    = excluded.folder_id,
            uid_validity = excluded.uid_validity,
            uid          = excluded.uid;
        """)
        try stmt.bind(1, localRowID)
        try stmt.bind(2, folderID)
        try stmt.bind(3, uidValidity)
        try stmt.bind(4, uid)
        try stmt.run()
    }

    public struct IMAPMapping: Sendable {
        public let folderPath: String
        public let uidValidity: Int64
        public let uid: Int64
    }

    public func imapMapping(forLocalRowID localRowID: Int64) throws -> IMAPMapping? {
        let stmt = try conn.prepare("""
        SELECT f.path, m.uid_validity, m.uid
          FROM imap_message_map m
          JOIN folders f ON f.id = m.folder_id
         WHERE m.local_id = ?;
        """)
        try stmt.bind(1, localRowID)
        var result: IMAPMapping?
        try stmt.forEachRow { row in
            result = IMAPMapping(
                folderPath: row.string(0) ?? "",
                uidValidity: row.int64(1),
                uid: row.int64(2)
            )
            return false
        }
        return result
    }

    public func folderIDLookup(accountID: Int64, folder: String) throws -> Int64? {
        let stmt = try conn.prepare("SELECT id FROM folders WHERE account_id = ? AND path = ?;")
        try stmt.bind(1, accountID)
        try stmt.bind(2, folder)
        var id: Int64 = 0
        try stmt.forEachRow { row in id = row.int64(0); return false }
        return id == 0 ? nil : id
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

    /// Pull the RFC 5322 Message-ID + the parsed references chain for one
    /// message. Used by Reply / Forward to set threading headers on the new
    /// outbound message so the conversation stitches together server-side.
    public func messageThreading(rowID: Int64) throws -> (messageID: String, references: [String])? {
        let stmt = try conn.prepare("""
        SELECT message_id, references_ FROM messages WHERE id = ?;
        """)
        try stmt.bind(1, rowID)
        var result: (String, [String])?
        try stmt.forEachRow { row in
            let mid = row.string(0) ?? ""
            let refs = (row.string(1) ?? "")
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .filter { !$0.isEmpty }
            result = (mid, refs)
            return false
        }
        return result
    }

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
            let monthStmt = try conn.prepare("""
            SELECT strftime('%Y-%m', date_unix, 'unixepoch') FROM messages WHERE id = ?;
            """)
            try monthStmt.bind(1, messageRowID)
            var month: String?
            try monthStmt.forEachRow { row in month = row.string(0); return false }
            if let month {
                let table = Self.monthTableName(month: month)
                try conn.exec("DELETE FROM \(table) WHERE rowid = \(messageRowID);")
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
        SELECT id, message_id, filename, mime_type, size_bytes, sha256, external_id
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
                sha256Hex: row.string(5),
                externalID: row.string(6)
            ))
            return true
        }
        return out
    }

    /// Find an attachment row by its id. Used by JMAP attachment download
    /// to look up the externalID + filename for the fetch.
    public func attachment(id attachmentID: Int64) throws -> AttachmentRef? {
        let stmt = try conn.prepare("""
        SELECT id, message_id, filename, mime_type, size_bytes, sha256, external_id
          FROM attachments WHERE id = ?;
        """)
        try stmt.bind(1, attachmentID)
        var result: AttachmentRef?
        try stmt.forEachRow { row in
            result = AttachmentRef(
                id: row.int64(0),
                messageRowID: row.int64(1),
                filename: row.string(2) ?? "",
                mimeType: row.string(3),
                sizeBytes: row.isNull(4) ? nil : row.int64(4),
                sha256Hex: row.string(5),
                externalID: row.string(6)
            )
            return false
        }
        return result
    }

    /// Fill in the sha256 + size on an existing attachment row once the bytes
    /// have been downloaded and persisted to the BlobStore.
    public func setAttachmentBlob(attachmentID: Int64, sha256Hex: String, sizeBytes: Int64) throws {
        let stmt = try conn.prepare("""
        UPDATE attachments SET sha256 = ?, size_bytes = ? WHERE id = ?;
        """)
        try stmt.bind(1, sha256Hex)
        try stmt.bind(2, sizeBytes)
        try stmt.bind(3, attachmentID)
        try stmt.run()
    }

    /// Load attachment bytes by its SHA-256 reference.
    public func loadAttachmentData(sha256Hex: String) -> Data? {
        blobs.get(sha256Hex)
    }

    // MARK: - Search

    /// Full-text search across month shards. Returns BM25-ranked hits with
    /// highlighted snippets, merged in Swift across the relevant shards.
    ///
    /// Phase 2F: per-month shards + denormalised UNINDEXED columns
    /// (date_unix, message_id) mean we never JOIN to `messages` — the
    /// JOIN cost dominated search at 5 M+ corpus under the old year shards
    /// (measured 25 s p50 for a 30-day window). All display fields are
    /// pulled straight from the FTS table.
    ///
    /// `accountID` is intentionally ignored here because the FTS table no
    /// longer carries account_id; if you need account-scoping at search
    /// time we'd add it as another UNINDEXED column. For single-account use
    /// (the typical maxmailin user) this is a no-op.
    public func search(
        _ query: String,
        accountID: Int64? = nil,
        since: Date? = nil,
        limit: Int = 50
    ) throws -> [SearchHit] {
        _ = accountID  // see doc comment
        let shards = relevantShards(since: since)
        if shards.isEmpty { return [] }

        var allHits: [SearchHit] = []
        allHits.reserveCapacity(shards.count * limit)

        for monthKey in shards {
            let table = Self.monthTableName(month: monthKey)
            // No per-row date filter — month-shard pruning already constrains
            // the result set to the right time window. Filtering on the
            // UNINDEXED date_unix column would force a post-MATCH scan and
            // wreck FTS5's early-termination.
            let sql = """
            SELECT rowid AS id,
                   message_id, subject, from_addr, date_unix,
                   snippet(\(table), 3, '⟦', '⟧', '…', 12) AS snip,
                   bm25(\(table), 10.0, 5.0, 2.0, 1.0) AS score
              FROM \(table)
             WHERE \(table) MATCH ?
             ORDER BY score
             LIMIT ?;
            """
            let stmt = try conn.prepare(sql)
            try stmt.bind(1, query)
            try stmt.bind(2, Int64(limit))

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

    // MARK: - Anomaly detection (on-demand)

    /// Heuristic flags for a single message. Cheap to evaluate — three
    /// indexed lookups per call — so it's fine to call as messages are
    /// opened. See EmailAnomaly for definitions.
    public func anomalies(forMessageRowID id: Int64) throws -> [EmailAnomaly] {
        guard let meta = try fetchMessageContext(messageRowID: id) else { return [] }
        var out: [EmailAnomaly] = []

        // First-time contact: no earlier message from this sender on this account.
        let priorStmt = try conn.prepare("""
        SELECT date_unix FROM messages
         WHERE account_id = ? AND from_addr = ? AND date_unix < ?
         ORDER BY date_unix DESC LIMIT 1;
        """)
        try priorStmt.bind(1, meta.accountID)
        try priorStmt.bind(2, meta.fromAddr)
        try priorStmt.bind(3, meta.dateUnix)
        var priorDate: Int64?
        try priorStmt.forEachRow { row in priorDate = row.int64(0); return false }

        if priorDate == nil {
            out.append(EmailAnomaly(
                kind: .firstTimeContact,
                messageRowID: id,
                detail: "First message from \(meta.fromAddr)",
                severity: .notable
            ))
        } else if let last = priorDate {
            let gap = meta.dateUnix - last
            let dormantThreshold: Int64 = 90 * 86_400
            if gap >= dormantThreshold {
                let days = Int(gap / 86_400)
                out.append(EmailAnomaly(
                    kind: .dormantSenderRevival,
                    messageRowID: id,
                    detail: "Resurfaced after \(days) days of silence",
                    severity: gap >= 365 * 86_400 ? .high : .notable
                ))
            }
        }

        // Off-hours arrival: 01:00–04:59 in the user's local time zone.
        let date = Date(timeIntervalSince1970: TimeInterval(meta.dateUnix))
        let hour = Calendar.current.component(.hour, from: date)
        if hour >= 1 && hour < 5 {
            out.append(EmailAnomaly(
                kind: .offHoursArrival,
                messageRowID: id,
                detail: String(format: "Arrived at %02d:%02d local time", hour,
                               Calendar.current.component(.minute, from: date)),
                severity: .info
            ))
        }

        return out
    }

    private struct MessageContext {
        let accountID: Int64
        let fromAddr: String
        let dateUnix: Int64
    }

    private func fetchMessageContext(messageRowID: Int64) throws -> MessageContext? {
        let stmt = try conn.prepare("""
        SELECT account_id, from_addr, date_unix FROM messages WHERE id = ?;
        """)
        try stmt.bind(1, messageRowID)
        var ctx: MessageContext?
        try stmt.forEachRow { row in
            ctx = MessageContext(
                accountID: row.int64(0),
                fromAddr: row.string(1) ?? "",
                dateUnix: row.int64(2)
            )
            return false
        }
        return ctx
    }

    /// Batch view: every first-time-contact + dormant-revival anomaly raised
    /// for messages newer than `since` on this account, newest first. Used
    /// by the Insights dashboard's "Unusual activity" section.
    public func recentAnomalies(accountID: Int64, since: Date, limit: Int = 50) throws -> [EmailAnomaly] {
        let cutoff = Int64(since.timeIntervalSince1970)
        let stmt = try conn.prepare("""
        SELECT m.id, m.from_addr, m.date_unix,
               (SELECT MAX(m2.date_unix) FROM messages m2
                 WHERE m2.account_id = m.account_id
                   AND m2.from_addr  = m.from_addr
                   AND m2.date_unix  < m.date_unix) AS prev_date
          FROM messages m
         WHERE m.account_id = ? AND m.date_unix > ?
         ORDER BY m.date_unix DESC
         LIMIT ?;
        """)
        try stmt.bind(1, accountID)
        try stmt.bind(2, cutoff)
        try stmt.bind(3, Int64(limit * 2))   // over-fetch so the trim below has room

        var out: [EmailAnomaly] = []
        try stmt.forEachRow { row in
            let id = row.int64(0)
            let from = row.string(1) ?? ""
            let date = row.int64(2)
            let prev: Int64? = row.isNull(3) ? nil : row.int64(3)
            if prev == nil {
                out.append(EmailAnomaly(
                    kind: .firstTimeContact,
                    messageRowID: id,
                    detail: "First message from \(from)",
                    severity: .notable
                ))
            } else if let p = prev, date - p >= 90 * 86_400 {
                let days = Int((date - p) / 86_400)
                out.append(EmailAnomaly(
                    kind: .dormantSenderRevival,
                    messageRowID: id,
                    detail: "Resurfaced after \(days) days of silence",
                    severity: (date - p) >= 365 * 86_400 ? .high : .notable
                ))
            }
            return out.count < limit
        }
        return out
    }

    // MARK: - Automation rules

    public func rules(accountID: Int64) throws -> [AutomationRule] {
        let stmt = try conn.prepare("""
        SELECT id, account_id, name, enabled, priority,
               conditions_json, actions_json, created_at
          FROM automation_rules
         WHERE account_id = ?
         ORDER BY priority DESC, id ASC;
        """)
        try stmt.bind(1, accountID)
        var out: [AutomationRule] = []
        try stmt.forEachRow { row in
            guard let condJSON = row.string(5),
                  let actJSON = row.string(6),
                  let cond: RuleConditions = self.decodeJSON(condJSON),
                  let act:  RuleActions    = self.decodeJSON(actJSON) else {
                return true
            }
            out.append(AutomationRule(
                id: row.int64(0),
                accountID: row.int64(1),
                name: row.string(2) ?? "",
                enabled: row.int(3) == 1,
                priority: row.int(4),
                conditions: cond,
                actions: act,
                createdAt: Date(timeIntervalSince1970: TimeInterval(row.int64(7)))
            ))
            return true
        }
        return out
    }

    @discardableResult
    public func addRule(_ rule: AutomationRule) throws -> Int64 {
        let enc = JSONEncoder()
        let condJSON = (try? String(data: enc.encode(rule.conditions), encoding: .utf8)) ?? "{}"
        let actJSON  = (try? String(data: enc.encode(rule.actions),    encoding: .utf8)) ?? "{}"
        let stmt = try conn.prepare("""
        INSERT INTO automation_rules(
            account_id, name, enabled, priority,
            conditions_json, actions_json, created_at
        ) VALUES(?, ?, ?, ?, ?, ?, ?)
        RETURNING id;
        """)
        try stmt.bind(1, rule.accountID)
        try stmt.bind(2, rule.name)
        try stmt.bind(3, Int64(rule.enabled ? 1 : 0))
        try stmt.bind(4, Int64(rule.priority))
        try stmt.bind(5, condJSON)
        try stmt.bind(6, actJSON)
        try stmt.bind(7, Int64(rule.createdAt.timeIntervalSince1970))
        var newID: Int64 = 0
        try stmt.forEachRow { row in newID = row.int64(0); return false }
        return newID
    }

    public func updateRule(_ rule: AutomationRule) throws {
        let enc = JSONEncoder()
        let condJSON = (try? String(data: enc.encode(rule.conditions), encoding: .utf8)) ?? "{}"
        let actJSON  = (try? String(data: enc.encode(rule.actions),    encoding: .utf8)) ?? "{}"
        let stmt = try conn.prepare("""
        UPDATE automation_rules
           SET name=?, enabled=?, priority=?, conditions_json=?, actions_json=?
         WHERE id=?;
        """)
        try stmt.bind(1, rule.name)
        try stmt.bind(2, Int64(rule.enabled ? 1 : 0))
        try stmt.bind(3, Int64(rule.priority))
        try stmt.bind(4, condJSON)
        try stmt.bind(5, actJSON)
        try stmt.bind(6, rule.id)
        try stmt.run()
    }

    public func deleteRule(ruleID: Int64) throws {
        let stmt = try conn.prepare("DELETE FROM automation_rules WHERE id = ?;")
        try stmt.bind(1, ruleID)
        try stmt.run()
    }

    /// Run every enabled rule for `accountID` against the next `batchSize`
    /// messages that haven't been processed yet (no rule_applications row).
    /// Returns the number of (message, rule) applications performed.
    ///
    /// Streaming discipline: we pull message ids in pages of `batchSize`,
    /// load each message's snapshot lazily (header + body + attachment
    /// flag), evaluate rules, and write the application log row to skip it
    /// next time. Memory is bounded to one batchSize × snapshot size.
    @discardableResult
    public func applyRulesBatch(accountID: Int64, batchSize: Int = 200) throws -> Int {
        let rules = try self.rules(accountID: accountID).filter { $0.enabled }
        guard !rules.isEmpty else { return 0 }

        // Messages without a rule_applications row for any of these rules
        // (newest first — feels like rules ran on the inbox at delivery).
        let ids = try unappliedMessageIDs(accountID: accountID, limit: batchSize)
        if ids.isEmpty { return 0 }

        var applied = 0
        for rowID in ids {
            guard let snapshot = try messageSnapshot(messageRowID: rowID) else { continue }
            for rule in rules {
                if RuleMatcher.matches(rule, snapshot) {
                    try applyRule(rule, toMessageRowID: rowID, accountID: accountID)
                    applied += 1
                }
                // Always log that we've seen this message for this rule
                // so re-sweeps are idempotent.
                try logRuleApplication(ruleID: rule.id, messageRowID: rowID)
            }
        }
        return applied
    }

    private func unappliedMessageIDs(accountID: Int64, limit: Int) throws -> [Int64] {
        let stmt = try conn.prepare("""
        SELECT m.id FROM messages m
         WHERE m.account_id = ?
           AND NOT EXISTS (
                 SELECT 1 FROM rule_applications a
                  WHERE a.message_id = m.id
                  LIMIT 1
               )
         ORDER BY m.date_unix DESC, m.id DESC
         LIMIT ?;
        """)
        try stmt.bind(1, accountID)
        try stmt.bind(2, Int64(limit))
        var out: [Int64] = []
        try stmt.forEachRow { row in out.append(row.int64(0)); return true }
        return out
    }

    private func messageSnapshot(messageRowID: Int64) throws -> RuleMatcher.MessageSnapshot? {
        let stmt = try conn.prepare("""
        SELECT m.subject, m.from_addr, m.flags,
               COALESCE(b.plain_body, '')
          FROM messages m
          LEFT JOIN message_bodies b ON b.message_id = m.id
         WHERE m.id = ?;
        """)
        try stmt.bind(1, messageRowID)
        var result: RuleMatcher.MessageSnapshot?
        try stmt.forEachRow { row in
            let flags = MessageFlags(rawValue: row.int(2))
            result = RuleMatcher.MessageSnapshot(
                subject: row.string(0) ?? "",
                fromAddress: row.string(1) ?? "",
                plainBody: row.string(3) ?? "",
                hasAttachment: flags.contains(.hasAttachment)
            )
            return false
        }
        return result
    }

    private func applyRule(
        _ rule: AutomationRule,
        toMessageRowID rowID: Int64,
        accountID: Int64
    ) throws {
        // Flag mutations.
        if rule.actions.markSeen || rule.actions.markFlagged {
            var flags = (try messageFlags(messageRowID: rowID)) ?? []
            if rule.actions.markSeen    { flags.insert(.seen) }
            if rule.actions.markFlagged { flags.insert(.flagged) }
            try updateMessageFlags(messageRowID: rowID, flags: flags)
        }
        // Folder move.
        if let target = rule.actions.moveToFolder, !target.isEmpty {
            try moveMessage(messageRowID: rowID, accountID: accountID, toFolder: target)
        }
    }

    private func logRuleApplication(ruleID: Int64, messageRowID: Int64) throws {
        let stmt = try conn.prepare("""
        INSERT INTO rule_applications(message_id, rule_id, applied_at)
        VALUES(?, ?, ?)
        ON CONFLICT(message_id, rule_id) DO NOTHING;
        """)
        try stmt.bind(1, messageRowID)
        try stmt.bind(2, ruleID)
        try stmt.bind(3, Int64(Date().timeIntervalSince1970))
        try stmt.run()
    }

    /// Move a message to a different folder by reassigning its folder_id.
    /// Creates the destination folder lazily if it doesn't exist yet so
    /// rules can target user-defined labels without a separate setup step.
    public func moveMessage(messageRowID: Int64, accountID: Int64, toFolder folder: String) throws {
        let fid: Int64
        if let existing = try folderIDLookup(accountID: accountID, folder: folder) {
            fid = existing
        } else {
            let ins = try conn.prepare("INSERT INTO folders(account_id, path) VALUES(?, ?) RETURNING id;")
            try ins.bind(1, accountID)
            try ins.bind(2, folder)
            var newID: Int64 = 0
            try ins.forEachRow { row in newID = row.int64(0); return false }
            fid = newID
        }
        let upd = try conn.prepare("UPDATE messages SET folder_id = ? WHERE id = ?;")
        try upd.bind(1, fid)
        try upd.bind(2, messageRowID)
        try upd.run()
    }

    // MARK: - Audit log

    public func lastAuditEntryHash() throws -> String? {
        let stmt = try conn.prepare("""
        SELECT entry_hash FROM audit_log ORDER BY id DESC LIMIT 1;
        """)
        var out: String?
        try stmt.forEachRow { row in out = row.string(0); return false }
        return out
    }

    @discardableResult
    public func appendAuditEntry(
        occurredAt: Int64, actor: String, action: String,
        subjectKind: String, subjectID: String, detailsJSON: String,
        prevHash: String, entryHash: String
    ) throws -> Int64 {
        let stmt = try conn.prepare("""
        INSERT INTO audit_log(
            occurred_at, actor, action,
            subject_kind, subject_id, details_json,
            prev_hash, entry_hash
        ) VALUES (?,?,?, ?,?,?, ?,?)
        RETURNING id;
        """)
        try stmt.bind(1, occurredAt)
        try stmt.bind(2, actor)
        try stmt.bind(3, action)
        try stmt.bind(4, subjectKind)
        try stmt.bind(5, subjectID)
        try stmt.bind(6, detailsJSON)
        try stmt.bind(7, prevHash)
        try stmt.bind(8, entryHash)
        var newID: Int64 = 0
        try stmt.forEachRow { row in newID = row.int64(0); return false }
        return newID
    }

    public func auditEntries(limit: Int) throws -> [AuditEntry] {
        let stmt = try conn.prepare("""
        SELECT id, occurred_at, actor, action,
               subject_kind, subject_id, details_json, prev_hash, entry_hash
          FROM audit_log
         ORDER BY id DESC
         LIMIT ?;
        """)
        try stmt.bind(1, Int64(limit))
        return try collectAuditRows(stmt)
    }

    public func auditEntriesInOrder() throws -> [AuditEntry] {
        let stmt = try conn.prepare("""
        SELECT id, occurred_at, actor, action,
               subject_kind, subject_id, details_json, prev_hash, entry_hash
          FROM audit_log
         ORDER BY id ASC;
        """)
        return try collectAuditRows(stmt)
    }

    private func collectAuditRows(_ stmt: SQLiteStatement) throws -> [AuditEntry] {
        var out: [AuditEntry] = []
        try stmt.forEachRow { row in
            let detailsJSON = row.string(6) ?? ""
            // Reverse the canonical "k1=v1;k2=v2" format used by the
            // audit log so verify() sees the same input on read-back.
            var details: [String: String] = [:]
            for pair in detailsJSON.split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    details[String(kv[0])] = String(kv[1])
                } else if kv.count == 1 {
                    details[String(kv[0])] = ""
                }
            }
            out.append(AuditEntry(
                id: row.int64(0),
                occurredAt: Date(timeIntervalSince1970: TimeInterval(row.int64(1))),
                actor: row.string(2) ?? "",
                action: row.string(3) ?? "",
                subjectKind: row.string(4) ?? "",
                subjectID: row.string(5) ?? "",
                details: details,
                prevHash: row.string(7) ?? "",
                entryHash: row.string(8) ?? ""
            ))
            return true
        }
        return out
    }

    /// Test-only helper that overwrites the `actor` column of an existing
    /// audit row without recomputing its hash. Used to simulate external
    /// tampering for chain-verification tests. Not part of any user flow.
    public func _testOverwriteAuditActor(rowID: Int64, newActor: String) throws {
        let stmt = try conn.prepare("UPDATE audit_log SET actor = ? WHERE id = ?;")
        try stmt.bind(1, newActor)
        try stmt.bind(2, rowID)
        try stmt.run()
    }

    // MARK: - Message seals (chain-of-custody integrity baselines)

    /// Computes the canonical SHA-256 over the *currently stored* projection
    /// of a message: identifying headers, both bodies, and the sorted list of
    /// attachment hashes. The canonical form is line-delimited `key:value`
    /// pairs in fixed order; same field order in seal and verify means the
    /// digest is reproducible across runs and platforms.
    ///
    /// Returns nil when the message row does not exist.
    public func canonicalMessageHash(messageRowID: Int64) throws -> String? {
        let head = try conn.prepare("""
        SELECT message_id, in_reply_to, references_,
               subject, from_addr, to_addrs, cc_addrs,
               date_unix, size_bytes
          FROM messages WHERE id = ?;
        """)
        try head.bind(1, messageRowID)
        var fields: [(String, String)] = []
        var found = false
        try head.forEachRow { row in
            found = true
            fields.append(("message_id", row.string(0) ?? ""))
            fields.append(("in_reply_to", row.string(1) ?? ""))
            fields.append(("references", row.string(2) ?? ""))
            fields.append(("subject", row.string(3) ?? ""))
            fields.append(("from", row.string(4) ?? ""))
            fields.append(("to", row.string(5) ?? ""))
            fields.append(("cc", row.string(6) ?? ""))
            fields.append(("date_unix", String(row.int64(7))))
            fields.append(("size_bytes", String(row.int64(8))))
            return false
        }
        guard found else { return nil }

        let body = try conn.prepare("""
        SELECT plain_body, html_body FROM message_bodies WHERE message_id = ?;
        """)
        try body.bind(1, messageRowID)
        var plain = "", html = ""
        try body.forEachRow { row in
            plain = row.string(0) ?? ""
            html = row.string(1) ?? ""
            return false
        }
        fields.append(("plain_body", plain))
        fields.append(("html_body", html))

        let att = try conn.prepare("""
        SELECT COALESCE(sha256, '') FROM attachments
         WHERE message_id = ?
         ORDER BY id ASC;
        """)
        try att.bind(1, messageRowID)
        var atts: [String] = []
        try att.forEachRow { row in
            atts.append(row.string(0) ?? "")
            return true
        }
        fields.append(("attachments", atts.joined(separator: ",")))

        // Canonicalisation: each pair becomes "key:length:value\n" so a value
        // containing a colon or newline cannot collide with the field
        // separator and produce the same digest as a different message.
        var canon = ""
        for (k, v) in fields {
            canon += "\(k):\(v.utf8.count):\(v)\n"
        }
        return BlobStore.sha256Hex(Data(canon.utf8))
    }

    /// Persist (or replace) the integrity seal for a message.
    public func recordMessageSeal(
        messageRowID: Int64, sealedAt: Date, contentSHA256Hex: String
    ) throws {
        let stmt = try conn.prepare("""
        INSERT INTO message_seals(message_id, sealed_at, content_sha256)
        VALUES (?, ?, ?)
        ON CONFLICT(message_id) DO UPDATE SET
            sealed_at = excluded.sealed_at,
            content_sha256 = excluded.content_sha256;
        """)
        try stmt.bind(1, messageRowID)
        try stmt.bind(2, Int64(sealedAt.timeIntervalSince1970))
        try stmt.bind(3, contentSHA256Hex)
        try stmt.run()
    }

    public func messageSeal(messageRowID: Int64) throws -> (sealedAt: Date, sha256Hex: String)? {
        let stmt = try conn.prepare("""
        SELECT sealed_at, content_sha256 FROM message_seals WHERE message_id = ?;
        """)
        try stmt.bind(1, messageRowID)
        var out: (Date, String)?
        try stmt.forEachRow { row in
            out = (Date(timeIntervalSince1970: TimeInterval(row.int64(0))),
                   row.string(1) ?? "")
            return false
        }
        return out
    }

    // MARK: - Bates numbering

    public struct BatesAssignmentRow: Sendable {
        public let messageRowID: Int64
        public let sequence: Int64
        public let batesNumber: String
        public let assignedAt: Date
    }

    /// Read a Bates config value. Caller decides defaults; keeping the
    /// table value-keyed lets the schema stay stable across config drift.
    public func batesConfigValue(forKey key: String) throws -> String? {
        let stmt = try conn.prepare("SELECT value FROM bates_config WHERE key = ?;")
        try stmt.bind(1, key)
        var out: String?
        try stmt.forEachRow { row in out = row.string(0); return false }
        return out
    }

    public func setBatesConfigValue(_ value: String, forKey key: String) throws {
        let stmt = try conn.prepare("""
        INSERT INTO bates_config(key, value) VALUES(?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        """)
        try stmt.bind(1, key)
        try stmt.bind(2, value)
        try stmt.run()
    }

    /// All messages in chronological order (oldest first), only including
    /// rows that don't yet carry a Bates number. Used for assignment passes:
    /// re-running assignment only stamps new arrivals and never re-stamps
    /// already-numbered exhibits.
    public func unnumberedMessageRowIDsInChronologicalOrder(
        accountID: Int64? = nil, limit: Int = 100_000
    ) throws -> [Int64] {
        let sql: String
        if accountID != nil {
            sql = """
            SELECT m.id FROM messages m
             LEFT JOIN bates_assignments b ON b.message_id = m.id
             WHERE b.message_id IS NULL AND m.account_id = ?
             ORDER BY m.date_unix ASC, m.id ASC
             LIMIT ?;
            """
        } else {
            sql = """
            SELECT m.id FROM messages m
             LEFT JOIN bates_assignments b ON b.message_id = m.id
             WHERE b.message_id IS NULL
             ORDER BY m.date_unix ASC, m.id ASC
             LIMIT ?;
            """
        }
        let stmt = try conn.prepare(sql)
        if let accountID {
            try stmt.bind(1, accountID)
            try stmt.bind(2, Int64(limit))
        } else {
            try stmt.bind(1, Int64(limit))
        }
        var out: [Int64] = []
        try stmt.forEachRow { row in
            out.append(row.int64(0))
            return true
        }
        return out
    }

    public func batesAssignment(messageRowID: Int64) throws -> BatesAssignmentRow? {
        let stmt = try conn.prepare("""
        SELECT message_id, sequence, bates_number, assigned_at
          FROM bates_assignments WHERE message_id = ?;
        """)
        try stmt.bind(1, messageRowID)
        var out: BatesAssignmentRow?
        try stmt.forEachRow { row in
            out = BatesAssignmentRow(
                messageRowID: row.int64(0),
                sequence: row.int64(1),
                batesNumber: row.string(2) ?? "",
                assignedAt: Date(timeIntervalSince1970: TimeInterval(row.int64(3)))
            )
            return false
        }
        return out
    }

    /// Highest assigned sequence number, or 0 when no Bates numbers exist.
    /// New batches append starting from `maxAssignedBatesSequence + 1`.
    public func maxAssignedBatesSequence() throws -> Int64 {
        let stmt = try conn.prepare("SELECT COALESCE(MAX(sequence), 0) FROM bates_assignments;")
        var out: Int64 = 0
        try stmt.forEachRow { row in out = row.int64(0); return false }
        return out
    }

    /// Bulk-insert Bates rows under one transaction. Sequence and bates
    /// number are caller-supplied so the manager controls formatting and
    /// numbering policy; the store just persists. Throws on duplicate
    /// sequence or duplicate bates_number — both are unique by design.
    public func bulkInsertBatesAssignments(_ rows: [BatesAssignmentRow]) throws {
        guard !rows.isEmpty else { return }
        try conn.transaction {
            let stmt = try conn.prepare("""
            INSERT INTO bates_assignments(message_id, sequence, bates_number, assigned_at)
            VALUES (?, ?, ?, ?);
            """)
            for r in rows {
                stmt.reset()
                try stmt.bind(1, r.messageRowID)
                try stmt.bind(2, r.sequence)
                try stmt.bind(3, r.batesNumber)
                try stmt.bind(4, Int64(r.assignedAt.timeIntervalSince1970))
                try stmt.run()
            }
        }
    }

    public func batesAssignmentCount() throws -> Int64 {
        let stmt = try conn.prepare("SELECT COUNT(*) FROM bates_assignments;")
        var n: Int64 = 0
        try stmt.forEachRow { row in n = row.int64(0); return false }
        return n
    }

    /// All Bates rows ordered by sequence ascending, joined with the
    /// minimal message header projection needed for the CSV index export.
    public struct BatesIndexRow: Sendable {
        public let batesNumber: String
        public let sequence: Int64
        public let messageID: String
        public let fromAddress: String
        public let toAddresses: String
        public let subject: String
        public let date: Date
        public let assignedAt: Date
    }

    public func batesIndexRows(limit: Int = 100_000) throws -> [BatesIndexRow] {
        let stmt = try conn.prepare("""
        SELECT b.bates_number, b.sequence, b.assigned_at,
               m.message_id, m.from_addr, m.to_addrs, m.subject, m.date_unix
          FROM bates_assignments b
          JOIN messages m ON m.id = b.message_id
         ORDER BY b.sequence ASC
         LIMIT ?;
        """)
        try stmt.bind(1, Int64(limit))
        var out: [BatesIndexRow] = []
        try stmt.forEachRow { row in
            out.append(BatesIndexRow(
                batesNumber: row.string(0) ?? "",
                sequence: row.int64(1),
                messageID: row.string(3) ?? "",
                fromAddress: row.string(4) ?? "",
                toAddresses: row.string(5) ?? "",
                subject: row.string(6) ?? "",
                date: Date(timeIntervalSince1970: TimeInterval(row.int64(7))),
                assignedAt: Date(timeIntervalSince1970: TimeInterval(row.int64(2)))
            ))
            return true
        }
        return out
    }

    /// Wipe every Bates assignment. Manager records an audit entry before
    /// calling so the rationale is captured even though the rows are gone.
    @discardableResult
    public func removeAllBatesAssignments() throws -> Int64 {
        let count = try batesAssignmentCount()
        try conn.exec("DELETE FROM bates_assignments;")
        return count
    }

    // MARK: - GDPR data-subject queries

    public struct GDPRMessageRef: Sendable {
        public let messageRowID: Int64
        public let messageID: String
        public let subject: String
        public let fromAddress: String
        public let toAddresses: String
        public let ccAddresses: String
        public let date: Date
        public let folder: String
        public let hasAttachments: Bool
    }

    /// Every message that has `emailAddress` in its `from`, `to`, or `cc`
    /// columns. The LIKE wildcard is intentional: address columns are stored
    /// as either bare addresses or display-name + angle-bracketed addresses,
    /// so substring matching catches both shapes. Body / Bcc are *not*
    /// scanned here — that's a separate slower scan via FTS the caller can
    /// run if they need it. Returns the rows newest-first.
    public func findMessagesInvolving(
        emailAddress: String,
        accountID: Int64? = nil,
        limit: Int = 100_000
    ) throws -> [GDPRMessageRef] {
        let needle = "%\(emailAddress)%"
        let whereAccount = accountID == nil ? "" : "AND m.account_id = ? "
        let sql = """
        SELECT m.id, m.message_id, m.subject,
               m.from_addr, m.to_addrs, m.cc_addrs,
               m.date_unix, f.path,
               EXISTS(SELECT 1 FROM attachments a WHERE a.message_id = m.id)
          FROM messages m
          JOIN folders  f ON f.id = m.folder_id
         WHERE (m.from_addr LIKE ?
             OR m.to_addrs LIKE ?
             OR m.cc_addrs LIKE ?)
           \(whereAccount)
         ORDER BY m.date_unix DESC, m.id DESC
         LIMIT ?;
        """
        let stmt = try conn.prepare(sql)
        try stmt.bind(1, needle)
        try stmt.bind(2, needle)
        try stmt.bind(3, needle)
        if let accountID {
            try stmt.bind(4, accountID)
            try stmt.bind(5, Int64(limit))
        } else {
            try stmt.bind(4, Int64(limit))
        }

        var out: [GDPRMessageRef] = []
        try stmt.forEachRow { row in
            out.append(GDPRMessageRef(
                messageRowID: row.int64(0),
                messageID: row.string(1) ?? "",
                subject: row.string(2) ?? "",
                fromAddress: row.string(3) ?? "",
                toAddresses: row.string(4) ?? "",
                ccAddresses: row.string(5) ?? "",
                date: Date(timeIntervalSince1970: TimeInterval(row.int64(6))),
                folder: row.string(7) ?? "",
                hasAttachments: row.int(8) != 0
            ))
            return true
        }
        return out
    }

    /// Sum every `PIIFinding.count` across every `message_forensics` row in
    /// `messageRowIDs`, grouped by PII kind. Used by the GDPR report to roll
    /// the per-message forensic results up into a subject-level inventory.
    /// Skips rows that don't have forensics yet — the report should call
    /// `ensureForensics` for missing ones upstream.
    public func aggregatePIICounts(forMessageRowIDs ids: [Int64]) throws -> [PIIFinding.Kind: Int] {
        guard !ids.isEmpty else { return [:] }
        var totals: [PIIFinding.Kind: Int] = [:]
        let chunkSize = 500
        for start in stride(from: 0, to: ids.count, by: chunkSize) {
            let end = min(start + chunkSize, ids.count)
            let chunk = Array(ids[start..<end])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let stmt = try conn.prepare("""
            SELECT pii_json FROM message_forensics
             WHERE message_id IN (\(placeholders));
            """)
            for (i, id) in chunk.enumerated() { try stmt.bind(Int32(i + 1), id) }
            try stmt.forEachRow { row in
                let pii: [PIIFinding] = self.decodeJSON(row.string(0)) ?? []
                for finding in pii {
                    totals[finding.kind, default: 0] += finding.count
                }
                return true
            }
        }
        return totals
    }

    /// Returns message rowIDs in `candidates` that don't yet have a seal.
    /// Used by `ChainOfCustodyManager.sealMessages` to skip already-sealed
    /// rows without forcing the caller to round-trip per id.
    public func unsealedMessageRowIDs(_ candidates: [Int64]) throws -> [Int64] {
        guard !candidates.isEmpty else { return [] }
        var sealed = Set<Int64>()
        let chunkSize = 500
        for start in stride(from: 0, to: candidates.count, by: chunkSize) {
            let end = min(start + chunkSize, candidates.count)
            let chunk = Array(candidates[start..<end])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let stmt = try conn.prepare(
                "SELECT message_id FROM message_seals WHERE message_id IN (\(placeholders));"
            )
            for (i, id) in chunk.enumerated() { try stmt.bind(Int32(i + 1), id) }
            try stmt.forEachRow { row in
                sealed.insert(row.int64(0))
                return true
            }
        }
        return candidates.filter { !sealed.contains($0) }
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

    /// Sorted list of all month-shard keys in "YYYY-MM" form.
    public func shardMonths() -> [String] { knownShards.sorted() }

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

    /// Counts of total and unread messages for one folder in one shot.
    /// `unread` = messages whose flags DO NOT include MessageFlags.seen (1<<0).
    public func folderCounts(accountID: Int64, folder: String) throws -> (total: Int64, unread: Int64) {
        let stmt = try conn.prepare("""
        SELECT COUNT(*),
               SUM(CASE WHEN (m.flags & 1) = 0 THEN 1 ELSE 0 END)
          FROM messages m JOIN folders f ON f.id = m.folder_id
         WHERE f.account_id = ? AND f.path = ?;
        """)
        try stmt.bind(1, accountID)
        try stmt.bind(2, folder)
        var total: Int64 = 0
        var unread: Int64 = 0
        try stmt.forEachRow { row in
            total  = row.int64(0)
            unread = row.isNull(1) ? 0 : row.int64(1)
            return false
        }
        return (total, unread)
    }

    // MARK: - Cross-cutting case-report aggregations

    /// Total + by-level distribution of phishing findings across an
    /// account. Aggregates the indexed `phishing_level` column on
    /// `message_forensics` so cost stays O(matching rows) regardless of
    /// total corpus size. Returns counts keyed by raw level string
    /// ("none"/"low"/"medium"/"high"); callers decode into
    /// `PhishingFinding.RiskLevel`. Messages without forensics rows are
    /// not counted — caller is expected to drive `ensureForensics`
    /// upstream if comprehensive numbers are needed.
    public func phishingDistribution(accountID: Int64) throws -> [String: Int64] {
        let stmt = try conn.prepare("""
        SELECT mf.phishing_level, COUNT(*)
          FROM message_forensics mf
          JOIN messages m ON m.id = mf.message_id
         WHERE m.account_id = ?
         GROUP BY mf.phishing_level;
        """)
        try stmt.bind(1, accountID)
        var out: [String: Int64] = [:]
        try stmt.forEachRow { row in
            let level = row.string(0) ?? "none"
            out[level] = row.int64(1)
            return true
        }
        return out
    }

    /// Monthly message volume across an account. Keys are "YYYY-MM";
    /// counts are messages dated in that month. Cheap because the
    /// month grouping uses the same date_unix index that backs the
    /// pagination queries, and the result set is bounded by the
    /// account's date range (~tens of rows for typical inboxes).
    public func monthlyMessageVolume(accountID: Int64) throws -> [(month: String, count: Int64)] {
        let stmt = try conn.prepare("""
        SELECT strftime('%Y-%m', date_unix, 'unixepoch') AS m, COUNT(*)
          FROM messages
         WHERE account_id = ?
         GROUP BY m
         ORDER BY m ASC;
        """)
        try stmt.bind(1, accountID)
        var out: [(String, Int64)] = []
        try stmt.forEachRow { row in
            let m = row.string(0) ?? ""
            if !m.isEmpty {
                out.append((m, row.int64(1)))
            }
            return true
        }
        return out
    }

    /// First / last assigned Bates numbers + count. Returns nil when
    /// no assignments exist. Used by the InvestigationReportGenerator
    /// to put the production range on the case header. Ordering is by
    /// `sequence` rather than lexical compare on bates_number — if a
    /// padding change ever lands mid-corpus, lexical MIN/MAX would
    /// disagree with the actual issue order.
    public func batesAssignmentRange() throws -> (first: String, last: String, count: Int64)? {
        let cnt = try batesAssignmentCount()
        guard cnt > 0 else { return nil }
        var first = "", last = ""
        let firstStmt = try conn.prepare(
            "SELECT bates_number FROM bates_assignments ORDER BY sequence ASC LIMIT 1;"
        )
        try firstStmt.forEachRow { row in first = row.string(0) ?? ""; return false }
        let lastStmt = try conn.prepare(
            "SELECT bates_number FROM bates_assignments ORDER BY sequence DESC LIMIT 1;"
        )
        try lastStmt.forEachRow { row in last = row.string(0) ?? ""; return false }
        return (first, last, cnt)
    }

    // MARK: - Correspondents (entity-resolution input)

    public struct CorrespondentRow: Sendable {
        public let rawHeaderValue: String   // e.g. "Alice <alex@acme.com>"
        public let messageCount: Int64
        public init(rawHeaderValue: String, messageCount: Int64) {
            self.rawHeaderValue = rawHeaderValue
            self.messageCount = messageCount
        }
    }

    /// Enumerate distinct sender values across an account, descending by
    /// occurrence count. The shape returned here is intentionally
    /// pre-normalisation — EntityResolver runs *over* these rows, so
    /// the store layer doesn't lock in any one resolution policy.
    /// Recipients are not included; from_addr is the only column that
    /// carries the canonical sender identity per row.
    public func distinctCorrespondents(
        accountID: Int64, limit: Int = 5_000
    ) throws -> [CorrespondentRow] {
        let stmt = try conn.prepare("""
        SELECT from_addr, COUNT(*) AS c
          FROM messages
         WHERE account_id = ? AND from_addr != ''
         GROUP BY from_addr
         ORDER BY c DESC, from_addr ASC
         LIMIT ?;
        """)
        try stmt.bind(1, accountID)
        try stmt.bind(2, Int64(limit))
        var out: [CorrespondentRow] = []
        try stmt.forEachRow { row in
            out.append(CorrespondentRow(
                rawHeaderValue: row.string(0) ?? "",
                messageCount: row.int64(1)
            ))
            return true
        }
        return out
    }

    // MARK: - Duplicate detection

    /// One cluster of (subject, from) duplicates plus the affected rows.
    /// Rows are date-ascending so callers can pick the oldest as the
    /// canonical and delete the rest.
    public struct DuplicateCluster: Sendable, Hashable {
        public let subject: String
        public let fromAddress: String
        public let messageRowIDs: [Int64]
        public init(subject: String, fromAddress: String, messageRowIDs: [Int64]) {
            self.subject = subject
            self.fromAddress = fromAddress
            self.messageRowIDs = messageRowIDs
        }
        public var count: Int { messageRowIDs.count }
    }

    /// Find duplicate clusters across an account by (subject, from)
    /// pair. SQL-driven so it stays cheap at 10M-message scale —
    /// GROUP BY runs on the existing (account_id, date) covering
    /// scan and lazily emits only clusters with > 1 row. The result
    /// excludes empty subjects to avoid one giant "no subject"
    /// cluster swamping the UI.
    ///
    /// `limit` caps the number of clusters returned; rowsPerCluster
    /// caps the per-cluster row enumeration. Both default to bounded
    /// values so an absurdly-duplicated account doesn't OOM the
    /// caller before they can pick a strategy.
    public func duplicateClusters(
        accountID: Int64,
        limit: Int = 200,
        rowsPerCluster: Int = 50
    ) throws -> [DuplicateCluster] {
        // 1. Find candidate (subject, from) pairs with > 1 row.
        let pairStmt = try conn.prepare("""
        SELECT subject, from_addr, COUNT(*) AS c
          FROM messages
         WHERE account_id = ? AND subject != ''
         GROUP BY subject, from_addr
        HAVING c > 1
         ORDER BY c DESC, subject ASC
         LIMIT ?;
        """)
        try pairStmt.bind(1, accountID)
        try pairStmt.bind(2, Int64(limit))
        var pairs: [(String, String)] = []
        try pairStmt.forEachRow { row in
            pairs.append((row.string(0) ?? "", row.string(1) ?? ""))
            return true
        }

        // 2. For each pair, enumerate the row ids oldest-first.
        var out: [DuplicateCluster] = []
        out.reserveCapacity(pairs.count)
        let detailStmt = try conn.prepare("""
        SELECT id FROM messages
         WHERE account_id = ? AND subject = ? AND from_addr = ?
         ORDER BY date_unix ASC, id ASC
         LIMIT ?;
        """)
        for (subject, from) in pairs {
            detailStmt.reset()
            try detailStmt.bind(1, accountID)
            try detailStmt.bind(2, subject)
            try detailStmt.bind(3, from)
            try detailStmt.bind(4, Int64(rowsPerCluster))
            var rowIDs: [Int64] = []
            try detailStmt.forEachRow { row in
                rowIDs.append(row.int64(0))
                return true
            }
            if rowIDs.count > 1 {
                out.append(DuplicateCluster(
                    subject: subject, fromAddress: from, messageRowIDs: rowIDs
                ))
            }
        }
        return out
    }

    /// Every message rowID for an account, chronological (oldest
    /// first), capped at `limit`. Used by case-report and analytics
    /// aggregators that need to enumerate over messages without loading
    /// headers. Strictly read-only; the result is a flat [Int64] so the
    /// caller can pass it into chunked IN-list aggregators.
    public func messageRowIDs(accountID: Int64, limit: Int = 500_000) throws -> [Int64] {
        let stmt = try conn.prepare("""
        SELECT id FROM messages
         WHERE account_id = ?
         ORDER BY date_unix ASC, id ASC
         LIMIT ?;
        """)
        try stmt.bind(1, accountID)
        try stmt.bind(2, Int64(limit))
        var out: [Int64] = []
        try stmt.forEachRow { row in
            out.append(row.int64(0))
            return true
        }
        return out
    }

    public func isJMAPLinked(messageRowID: Int64) throws -> Bool {
        return try jmapEmailID(forLocalRowID: messageRowID) != nil
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

    /// Top senders by message count. Joins the NLP cache for mean sentiment
    /// per sender (NULL when none of their messages have been analyzed yet).
    /// The hasAttachment flag is at bit 5 (1 << 5 == 32).
    public func topSenders(accountID: Int64, limit: Int = 25, since: Date? = nil) throws -> [SenderStat] {
        var clauses = ["m.account_id = ?"]
        if since != nil { clauses.append("m.date_unix > ?") }
        let sql = """
        SELECT m.from_addr,
               COUNT(*) AS n,
               MIN(m.date_unix) AS first_seen,
               MAX(m.date_unix) AS last_seen,
               AVG(n.sentiment) AS mean_sent,
               SUM(CASE WHEN (m.flags & 32) = 32 THEN 1 ELSE 0 END) AS att_n
          FROM messages m
          LEFT JOIN message_nlp n ON n.message_id = m.id
         WHERE \(clauses.joined(separator: " AND "))
         GROUP BY m.from_addr
         ORDER BY n DESC, m.from_addr ASC
         LIMIT ?;
        """
        let stmt = try conn.prepare(sql)
        var idx: Int32 = 1
        try stmt.bind(idx, accountID); idx += 1
        if let since {
            try stmt.bind(idx, Int64(since.timeIntervalSince1970)); idx += 1
        }
        try stmt.bind(idx, Int64(limit))
        var out: [SenderStat] = []
        try stmt.forEachRow { row in
            guard let addr = row.string(0), !addr.isEmpty else { return true }
            let mean: Double? = row.isNull(4) ? nil : Double(row.string(4) ?? "0")
            out.append(SenderStat(
                address: addr,
                messageCount: row.int(1),
                firstSeen: Date(timeIntervalSince1970: TimeInterval(row.int64(2))),
                lastSeen: Date(timeIntervalSince1970: TimeInterval(row.int64(3))),
                meanSentiment: mean,
                attachmentMessageCount: row.int(5)
            ))
            return true
        }
        return out
    }

    public func senderStat(accountID: Int64, address: String) throws -> SenderStat? {
        let stmt = try conn.prepare("""
        SELECT COUNT(*) AS n,
               MIN(m.date_unix) AS first_seen,
               MAX(m.date_unix) AS last_seen,
               AVG(n.sentiment) AS mean_sent,
               SUM(CASE WHEN (m.flags & 32) = 32 THEN 1 ELSE 0 END) AS att_n
          FROM messages m
          LEFT JOIN message_nlp n ON n.message_id = m.id
         WHERE m.account_id = ? AND m.from_addr = ?;
        """)
        try stmt.bind(1, accountID)
        try stmt.bind(2, address)
        var stat: SenderStat?
        try stmt.forEachRow { row in
            let count = row.int(0)
            if count == 0 { return false }
            let mean: Double? = row.isNull(3) ? nil : Double(row.string(3) ?? "0")
            stat = SenderStat(
                address: address,
                messageCount: count,
                firstSeen: Date(timeIntervalSince1970: TimeInterval(row.int64(1))),
                lastSeen: Date(timeIntervalSince1970: TimeInterval(row.int64(2))),
                meanSentiment: mean,
                attachmentMessageCount: row.int(4)
            )
            return false
        }
        return stat
    }

    /// Recent message headers from one sender, newest first.
    public func messagesFromSender(accountID: Int64, address: String, limit: Int = 50) throws -> [MessageHeader] {
        let stmt = try conn.prepare("""
        SELECT m.id, m.message_id, f.path, m.subject, m.from_addr, m.date_unix,
               m.size_bytes, m.flags, m.snippet
          FROM messages m JOIN folders f ON f.id = m.folder_id
         WHERE m.account_id = ? AND m.from_addr = ?
         ORDER BY m.date_unix DESC, m.id DESC
         LIMIT ?;
        """)
        try stmt.bind(1, accountID)
        try stmt.bind(2, address)
        try stmt.bind(3, Int64(limit))
        var out: [MessageHeader] = []
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
