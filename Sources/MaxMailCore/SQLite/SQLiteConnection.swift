import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteError: Error, CustomStringConvertible {
    case open(Int32, String)
    case prepare(Int32, String, String)
    case step(Int32, String)
    case bind(Int32, String)

    public var description: String {
        switch self {
        case .open(let code, let msg): return "sqlite open failed (\(code)): \(msg)"
        case .prepare(let code, let msg, let sql): return "sqlite prepare failed (\(code)): \(msg) — sql=\(sql)"
        case .step(let code, let msg): return "sqlite step failed (\(code)): \(msg)"
        case .bind(let code, let msg): return "sqlite bind failed (\(code)): \(msg)"
        }
    }
}

public final class SQLiteConnection {
    private var db: OpaquePointer?

    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, db != nil else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(db)
            throw SQLiteError.open(rc, msg)
        }
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous = NORMAL;")
        try exec("PRAGMA temp_store = MEMORY;")
        try exec("PRAGMA foreign_keys = ON;")
        try exec("PRAGMA mmap_size = 268435456;") // 256 MB mmap window
    }

    deinit { sqlite3_close_v2(db) }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw SQLiteError.step(rc, msg)
        }
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLiteError.prepare(rc, msg, sql)
        }
        return SQLiteStatement(stmt)
    }

    public func lastInsertRowID() -> Int64 { sqlite3_last_insert_rowid(db) }
    public func changes() -> Int32 { sqlite3_changes(db) }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try exec("COMMIT;")
            return result
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }
}

public final class SQLiteStatement {
    private var stmt: OpaquePointer?

    init(_ stmt: OpaquePointer) { self.stmt = stmt }
    deinit { sqlite3_finalize(stmt) }

    public func reset() { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }

    @discardableResult
    public func bind(_ index: Int32, _ value: String?) throws -> Self {
        let rc: Int32
        if let value { rc = sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT) }
        else { rc = sqlite3_bind_null(stmt, index) }
        if rc != SQLITE_OK { throw SQLiteError.bind(rc, "text idx=\(index)") }
        return self
    }

    @discardableResult
    public func bind(_ index: Int32, _ value: Int64) throws -> Self {
        let rc = sqlite3_bind_int64(stmt, index, value)
        if rc != SQLITE_OK { throw SQLiteError.bind(rc, "int64 idx=\(index)") }
        return self
    }

    @discardableResult
    public func bind(_ index: Int32, _ value: Int64?) throws -> Self {
        if let value { return try bind(index, value) }
        let rc = sqlite3_bind_null(stmt, index)
        if rc != SQLITE_OK { throw SQLiteError.bind(rc, "null int64 idx=\(index)") }
        return self
    }

    @discardableResult
    public func bind(_ index: Int32, _ value: Int?) throws -> Self {
        if let value { return try bind(index, Int64(value)) }
        let rc = sqlite3_bind_null(stmt, index)
        if rc != SQLITE_OK { throw SQLiteError.bind(rc, "null idx=\(index)") }
        return self
    }

    @discardableResult
    public func bind(_ index: Int32, _ value: Data?) throws -> Self {
        let rc: Int32
        if let value {
            rc = value.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(value.count), SQLITE_TRANSIENT)
            }
        } else {
            rc = sqlite3_bind_null(stmt, index)
        }
        if rc != SQLITE_OK { throw SQLiteError.bind(rc, "blob idx=\(index)") }
        return self
    }

    /// Executes a statement that returns no rows.
    public func run() throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError.step(rc, "run")
        }
    }

    /// Iterate rows. Body returns `true` to keep going, `false` to stop.
    /// The statement is reset on every exit path so the cursor never stays
    /// "in progress" — otherwise SQLite refuses to COMMIT an enclosing txn.
    public func forEachRow(_ body: (SQLiteRow) throws -> Bool) throws {
        defer { sqlite3_reset(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                let keepGoing = try body(SQLiteRow(stmt!))
                if !keepGoing { return }
            } else if rc == SQLITE_DONE {
                return
            } else {
                throw SQLiteError.step(rc, "forEachRow")
            }
        }
    }
}

public struct SQLiteRow {
    let stmt: OpaquePointer
    init(_ stmt: OpaquePointer) { self.stmt = stmt }

    public func int64(_ index: Int32) -> Int64 { sqlite3_column_int64(stmt, index) }
    public func int(_ index: Int32) -> Int { Int(sqlite3_column_int64(stmt, index)) }
    public func string(_ index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }
    public func data(_ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return Data(bytes: bytes, count: count)
    }
    public func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(stmt, index) == SQLITE_NULL
    }
}
