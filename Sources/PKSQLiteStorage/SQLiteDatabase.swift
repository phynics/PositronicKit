import CPKSQLite
import Foundation
import PKContracts
import PositronicKit

/// Owns one SQLite connection handle.
///
/// The class only exists so the handle closes when the owning ``SQLiteDatabase`` actor is
/// released, including the crash-recovery path where `close()` never runs. It never escapes the
/// actor, so it is not `Sendable` and needs no lock.
final class PKSQLiteConnection {
    private var handle: OpaquePointer?

    init(handle: OpaquePointer?) {
        self.handle = handle
    }

    var raw: OpaquePointer? {
        handle
    }

    func close() {
        guard let handle else { return }
        self.handle = nil
        pk_sqlite3_close_v2(handle)
    }

    deinit {
        if let handle {
            pk_sqlite3_close_v2(handle)
        }
    }
}

/// The single serialization point for every store in one ``PKSQLiteStorage``.
///
/// One actor owns one connection, so a repository requirement that reads a ledger snapshot,
/// decides a commit, and applies it runs without any suspension in between. WAL mode lets
/// external readers observe committed data while the actor keeps writing.
actor SQLiteDatabase: TimelineRuntimeRepository, WorkspaceBindingRepository, WorkspaceStore, AgentStoreProtocol, RequestOriginStoreProtocol {
    /// Whether the backing database survives process restart.
    nonisolated let isDurable: Bool

    private let connection: PKSQLiteConnection

    private init(connection: PKSQLiteConnection, isDurable: Bool) {
        self.connection = connection
        self.isDurable = isDurable
    }

    // MARK: Opening

    static func open(at url: URL, options _: PKSQLiteStorage.Options) throws -> SQLiteDatabase {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = pk_sqlite3_open_v2(url.path, &handle, flags, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: pk_sqlite3_errmsg($0)) } ?? "unable to open database"
            pk_sqlite3_close_v2(handle)
            throw PKSQLiteStorageError.openFailed(path: url.path, message: message)
        }
        return SQLiteDatabase(connection: PKSQLiteConnection(handle: handle), isDurable: true)
    }

    static func inMemory(options _: PKSQLiteStorage.Options) throws -> SQLiteDatabase {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_MEMORY | SQLITE_OPEN_FULLMUTEX
        let code = pk_sqlite3_open_v2(":memory:", &handle, flags, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: pk_sqlite3_errmsg($0)) } ?? "unable to open in-memory database"
            pk_sqlite3_close_v2(handle)
            throw PKSQLiteStorageError.openFailed(path: ":memory:", message: message)
        }
        return SQLiteDatabase(connection: PKSQLiteConnection(handle: handle), isDurable: false)
    }

    func configure(options: PKSQLiteStorage.Options) throws {
        _ = pk_sqlite3_busy_timeout(handle, Int32(max(0, options.busyTimeout) * 1000))
        try execute("PRAGMA journal_mode=\(options.journalMode.rawValue)")
        try execute("PRAGMA foreign_keys=\(options.foreignKeys ? "ON" : "OFF")")
        try migrate()
    }

    func close() {
        connection.close()
    }

    // MARK: Schema migrations

    private func migrate() throws {
        let current = try userVersion()
        guard current <= schemaVersion else {
            throw PKSQLiteStorageError.migrationFailed(
                from: current,
                to: schemaVersion,
                message: "database schema \(current) is newer than this build supports"
            )
        }
        if current < 1 {
            do {
                for statement in Schema.v1 {
                    try execute(statement)
                }
                try setUserVersion(1)
            } catch {
                throw PKSQLiteStorageError.migrationFailed(
                    from: current,
                    to: 1,
                    message: String(describing: error)
                )
            }
        }
    }

    private var schemaVersion: Int {
        1
    }

    private func userVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version")
        defer { finalize(statement) }
        guard pk_sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(pk_sqlite3_column_int(statement, 0))
    }

    private func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version=\(version)")
    }

    // MARK: Transactions

    /// Runs `body` inside a `BEGIN IMMEDIATE … COMMIT` transaction. Because the actor never
    /// suspends inside the closure, the snapshot the caller read and the commit it derived are
    /// one storage transition.
    func withTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: Low-level statement helpers

    var handle: OpaquePointer? {
        connection.raw
    }

    func execute(_ sql: String) throws {
        guard let handle else { throw PKSQLiteStorageError.closed }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let code = pk_sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        if code != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? String(cString: pk_sqlite3_errmsg(handle))
            pk_sqlite3_free(errorPointer)
            if code == SQLITE_CONSTRAINT {
                throw PKSQLiteStorageError.constraint(message: message)
            }
            throw PKSQLiteStorageError.database(code: Int(code), message: message, context: sql)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        guard let handle else { throw PKSQLiteStorageError.closed }
        var statement: OpaquePointer?
        let code = pk_sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            let message = String(cString: pk_sqlite3_errmsg(handle))
            throw PKSQLiteStorageError.database(code: Int(code), message: message, context: sql)
        }
        return statement
    }

    func finalize(_ statement: OpaquePointer?) {
        pk_sqlite3_finalize(statement)
    }

    func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String?) throws {
        guard let handle else { throw PKSQLiteStorageError.closed }
        let code: Int32
        if let value {
            code = pk_bind_text_transient(statement, index, value)
        } else {
            code = pk_sqlite3_bind_null(statement, index)
        }
        guard code == SQLITE_OK else {
            let message = String(cString: pk_sqlite3_errmsg(handle))
            throw PKSQLiteStorageError.database(code: Int(code), message: message, context: "bind")
        }
    }

    func bindInt64(_ statement: OpaquePointer, _ index: Int32, _ value: Int64) throws {
        let code = pk_sqlite3_bind_int64(statement, index, value)
        try checkBind(code)
    }

    func bindDouble(_ statement: OpaquePointer, _ index: Int32, _ value: Double) throws {
        let code = pk_sqlite3_bind_double(statement, index, value)
        try checkBind(code)
    }

    private func checkBind(_ code: Int32) throws {
        guard code == SQLITE_OK else {
            let message = handle.map { String(cString: pk_sqlite3_errmsg($0)) } ?? "closed"
            throw PKSQLiteStorageError.database(code: Int(code), message: message, context: "bind")
        }
    }

    func step(_ statement: OpaquePointer) throws -> Bool {
        let code = pk_sqlite3_step(statement)
        if code == SQLITE_ROW { return true }
        if code == SQLITE_DONE { return false }
        let message = handle.map { String(cString: pk_sqlite3_errmsg($0)) } ?? "closed"
        if code == SQLITE_CONSTRAINT {
            throw PKSQLiteStorageError.constraint(message: message)
        }
        throw PKSQLiteStorageError.database(code: Int(code), message: message, context: "step")
    }

    func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let pointer = pk_sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    func int64(_ statement: OpaquePointer, _ index: Int32) -> Int64 {
        pk_sqlite3_column_int64(statement, index)
    }

    func double(_ statement: OpaquePointer, _ index: Int32) -> Double {
        pk_sqlite3_column_double(statement, index)
    }

    func isNull(_ statement: OpaquePointer, _ index: Int32) -> Bool {
        pk_sqlite3_column_type(statement, index) == SQLITE_NULL
    }

    /// Runs a single-row, single-column `SELECT` and returns the text result.
    func queryText(_ sql: String, bind: (OpaquePointer) throws -> Void = { _ in }) throws -> String? {
        let statement = try prepare(sql)
        defer { finalize(statement) }
        try bind(statement)
        guard try step(statement) else { return nil }
        return text(statement, 0)
    }

    func executeUpdate(_ sql: String, bind: (OpaquePointer) throws -> Void = { _ in }) throws {
        let statement = try prepare(sql)
        defer { finalize(statement) }
        try bind(statement)
        _ = try step(statement)
    }
}

/// The forward-only schema. `PRAGMA user_version` records the version. Version 1 is
/// principal-ready: owner columns carry `principal_id` + `principal_kind` (`'agent'` in 7.0) so
/// 8.0 does not need a SQL migration.
enum Schema {
    static let v1: [String] = [
        """
        CREATE TABLE IF NOT EXISTS timelines (
            id TEXT PRIMARY KEY,
            body TEXT NOT NULL,
            is_archived INTEGER NOT NULL DEFAULT 0,
            is_ephemeral INTEGER NOT NULL DEFAULT 0,
            is_private INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            principal_id TEXT,
            principal_kind TEXT
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS messages (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            timeline_id TEXT NOT NULL,
            id TEXT NOT NULL,
            created_at REAL NOT NULL,
            principal_id TEXT,
            principal_kind TEXT,
            body TEXT NOT NULL,
            UNIQUE(timeline_id, id)
        )
        """,
        "CREATE INDEX IF NOT EXISTS messages_timeline ON messages(timeline_id, created_at, seq)",
        """
        CREATE TABLE IF NOT EXISTS turns (
            turn_id TEXT PRIMARY KEY,
            timeline_id TEXT NOT NULL,
            request_id TEXT NOT NULL,
            fingerprint TEXT NOT NULL,
            created_at REAL NOT NULL,
            is_terminal INTEGER NOT NULL DEFAULT 0,
            is_quarantined INTEGER NOT NULL DEFAULT 0,
            principal_id TEXT,
            principal_kind TEXT,
            body TEXT NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS turns_timeline ON turns(timeline_id, created_at)",
        "CREATE INDEX IF NOT EXISTS turns_request ON turns(request_id)",
        "CREATE INDEX IF NOT EXISTS turns_active ON turns(timeline_id) WHERE is_terminal = 0",
        """
        CREATE TABLE IF NOT EXISTS timeline_pointers (
            timeline_id TEXT PRIMARY KEY,
            active_turn_id TEXT,
            quarantined_turn_id TEXT
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS turn_members (
            turn_id TEXT NOT NULL,
            ord INTEGER NOT NULL,
            message_id TEXT NOT NULL,
            PRIMARY KEY (turn_id, ord)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS tool_intents (
            turn_id TEXT NOT NULL,
            tool_call_id TEXT NOT NULL,
            timeline_id TEXT NOT NULL,
            created_at REAL NOT NULL,
            principal_id TEXT,
            principal_kind TEXT,
            body TEXT NOT NULL,
            PRIMARY KEY (turn_id, tool_call_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS tool_results (
            turn_id TEXT NOT NULL,
            tool_call_id TEXT NOT NULL,
            timeline_id TEXT NOT NULL,
            created_at REAL NOT NULL,
            principal_id TEXT,
            principal_kind TEXT,
            body TEXT NOT NULL,
            PRIMARY KEY (turn_id, tool_call_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS agents (
            id TEXT PRIMARY KEY,
            body TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS workspaces (
            id TEXT PRIMARY KEY,
            body TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS workspace_bindings (
            workspace_id TEXT PRIMARY KEY,
            timeline_id TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            principal_id TEXT,
            principal_kind TEXT
        )
        """,
        "CREATE INDEX IF NOT EXISTS workspace_bindings_timeline ON workspace_bindings(timeline_id, created_at)",
        """
        CREATE TABLE IF NOT EXISTS request_origins (
            id TEXT PRIMARY KEY,
            body TEXT NOT NULL
        )
        """,
    ]
}
