import Foundation
import CSQLite3

// SQLITE_TRANSIENT is a C macro (-1 cast to a destructor function pointer) and
// is therefore not imported by the Swift C module. SQLite copies the bytes
// when this value is passed, so the caller's buffer may go away afterwards.
private let sqliteTransient = unsafeBitCast(
    -1,
    to: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?.self
)

/// Minimal, read-only SQLite wrapper around the system SQLite3 C API.
/// Every resource is finalized/closed in `deinit`, so a thrown error cannot
/// leave a prepared statement or a database handle behind.
public final class SQLiteDatabase {
    private var handle: OpaquePointer?

    /// Opens the database read-only. This is important: OpenCode keeps the DB
    /// in WAL mode and the monitor must never modify it.
    public init(path: String) throws {
        var opened: OpaquePointer?
        let status = path.withCString { sqlite3_open_v2($0, &opened, SQLITE_OPEN_READONLY, nil) }
        guard status == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "неизвестная ошибка"
            if let opened { sqlite3_close(opened) }
            throw UsageError.database("Не удалось открыть \(path): \(message)")
        }
        self.handle = opened
        // A writer may hold the WAL lock for a moment; wait briefly instead of
        // failing a poll with SQLITE_BUSY.
        sqlite3_busy_timeout(opened, 1_000)
    }

    deinit { close() }

    public var isOpen: Bool { handle != nil }

    public var lastErrorMessage: String {
        guard let handle else { return "база данных закрыта" }
        return String(cString: sqlite3_errmsg(handle))
    }

    public func close() {
        guard let handle else { return }
        sqlite3_close(handle)
        self.handle = nil
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let handle else { throw UsageError.database("База данных закрыта") }
        var statement: OpaquePointer?
        let status = sql.withCString { sqlite3_prepare_v2(handle, $0, -1, &statement, nil) }
        guard status == SQLITE_OK, let statement else {
            throw UsageError.database("Ошибка подготовки SQL: \(lastErrorMessage)")
        }
        return SQLiteStatement(database: handle, statement: statement)
    }

    /// Convenience for a single statement that does not return rows.
    public func execute(_ sql: String) throws {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        if try statement.step() {
            throw UsageError.database("Ожидался запрос без возврата строк")
        }
    }
}

/// A prepared read-only statement.
public final class SQLiteStatement {
    private let database: OpaquePointer
    private let statement: OpaquePointer
    private var isFinalized = false

    init(database: OpaquePointer, statement: OpaquePointer) {
        self.database = database
        self.statement = statement
    }

    deinit { finalize() }

    public func finalize() {
        guard !isFinalized else { return }
        sqlite3_finalize(statement)
        isFinalized = true
    }

    private var errorMessage: String { String(cString: sqlite3_errmsg(database)) }

    /// - Returns: `true` while a row is available, `false` on SQLITE_DONE.
    public func step() throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw UsageError.database("Ошибка выполнения SQL: \(errorMessage)")
        }
    }

    public func bind(_ value: Int64, at index: Int32) throws {
        let status = sqlite3_bind_int64(statement, index, value)
        guard status == SQLITE_OK else { throw UsageError.database("Ошибка привязки параметра: \(errorMessage)") }
    }

    public func bind(_ value: Int, at index: Int32) throws {
        try bind(Int64(value), at: index)
    }

    public func bind(_ value: String, at index: Int32) throws {
        let status = value.withCString { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) }
        guard status == SQLITE_OK else { throw UsageError.database("Ошибка привязки параметра: \(errorMessage)") }
    }

    public func bindNull(at index: Int32) throws {
        let status = sqlite3_bind_null(statement, index)
        guard status == SQLITE_OK else { throw UsageError.database("Ошибка привязки параметра: \(errorMessage)") }
    }

    public func reset() throws {
        let status = sqlite3_reset(statement)
        guard status == SQLITE_OK else { throw UsageError.database("Ошибка сброса запроса: \(errorMessage)") }
    }

    public func int(at index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    public func double(at index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    /// Reads a TEXT column as UTF-8 without touching any message content in
    /// the callers (they only request metadata columns).
    public func string(at index: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, index) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, index))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
    }
}
