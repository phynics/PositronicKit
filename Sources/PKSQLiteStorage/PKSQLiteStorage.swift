import Foundation
import PKContracts
import PositronicKit

/// Optional durable storage for every runtime store, backed by a vendored SQLite
/// amalgamation.
///
/// One `PKSQLiteStorage` owns one database file (or one in-memory database) and exposes a
/// ``persistenceConfiguration`` whose stores all read and write through it:
///
/// ```swift
/// import PKSQLiteStorage
///
/// let storage = try await PKSQLiteStorage.open(at: appSupportURL.appending(path: "positronic.sqlite"))
/// let kit = PKRuntime(configuration: .init(
///     provider: provider,
///     persistence: storage.persistenceConfiguration
/// ))
/// ```
///
/// The database is accessed through a single actor-isolated write connection, so every
/// repository requirement runs as one `BEGIN IMMEDIATE` transaction. A host keeps the
/// `PKSQLiteStorage` value alive for as long as it needs the stores; call ``close()`` to
/// release the file handle.
public struct PKSQLiteStorage: DurabilityAware {
    /// The runtime persistence configuration backed by this database.
    public let persistenceConfiguration: PKRuntime.PersistenceConfiguration

    /// Whether this database survives process restart. `false` for ``inMemory()``.
    public let isDurable: Bool

    /// The shared database actor, kept so ``close()`` can release the handle.
    private let database: SQLiteDatabase

    private init(
        database: SQLiteDatabase,
        persistenceConfiguration: PKRuntime.PersistenceConfiguration,
        isDurable: Bool
    ) {
        self.database = database
        self.persistenceConfiguration = persistenceConfiguration
        self.isDurable = isDurable
    }

    /// Opens (or creates) a durable database file at `url` and migrates it to the current
    /// schema version.
    ///
    /// - Parameters:
    ///   - url: The database file. Parent directories are not created.
    ///   - options: Connection and journal tuning. See ``Options``.
    public static func open(
        at url: URL,
        options: Options = Options()
    ) async throws -> PKSQLiteStorage {
        let database = try SQLiteDatabase.open(at: url, options: options)
        try await database.configure(options: options)
        return make(database: database, isDurable: true)
    }

    /// Opens an in-memory database. Every call returns an isolated database, so this is the
    /// factory for tests. The resulting stores report ``isDurable`` as `false`.
    public static func inMemory(options: Options = Options()) async throws -> PKSQLiteStorage {
        let database = try SQLiteDatabase.inMemory(options: options)
        try await database.configure(options: options)
        return make(database: database, isDurable: false)
    }

    /// Releases the database handle. Calling a store method after `close()` throws
    /// ``PKSQLiteStorageError/closed``. `close()` is idempotent.
    public func close() async throws {
        await database.close()
    }

    private static func make(database: SQLiteDatabase, isDurable: Bool) -> PKSQLiteStorage {
        let configuration = PKRuntime.PersistenceConfiguration(
            runtimeRepository: database,
            workspacePersistence: database,
            agentStore: database,
            requestOriginStore: database,
            workspaceBindingRepository: database
        )
        return PKSQLiteStorage(
            database: database,
            persistenceConfiguration: configuration,
            isDurable: isDurable
        )
    }
}

public extension PKSQLiteStorage {
    /// Connection and journal tuning for a database.
    struct Options: Sendable {
        /// How long SQLite waits for a competing writer before returning `SQLITE_BUSY`.
        public var busyTimeout: TimeInterval

        /// The SQLite journal mode. WAL (the default) lets external readers observe committed
        /// data while the runtime keeps writing.
        public var journalMode: JournalMode

        /// Whether to run `PRAGMA foreign_keys`, which enforces the declared cascades.
        public var foreignKeys: Bool

        /// Creates options with the production defaults.
        public init(
            busyTimeout: TimeInterval = 5,
            journalMode: JournalMode = .wal,
            foreignKeys: Bool = true
        ) {
            self.busyTimeout = busyTimeout
            self.journalMode = journalMode
            self.foreignKeys = foreignKeys
        }
    }

    /// The SQLite journal modes this adapter supports.
    enum JournalMode: String, Sendable, CaseIterable {
        case wal = "WAL"
        case delete = "DELETE"
        case truncate = "TRUNCATE"
        case memory = "MEMORY"
    }
}

/// Errors raised while opening, migrating, or using a ``PKSQLiteStorage`` database.
public enum PKSQLiteStorageError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The database file could not be opened.
    case openFailed(path: String, message: String)
    /// SQLite returned a failure for a statement or transaction.
    case database(code: Int, message: String, context: String)
    /// A migration step failed.
    case migrationFailed(from: Int, to: Int, message: String)
    /// The database file is not a valid SQLite database, or a stored body could not be decoded.
    case corrupt(message: String)
    /// A uniqueness or foreign-key constraint rejected a write.
    case constraint(message: String)
    /// A store method was called after ``PKSQLiteStorage/close()``.
    case closed

    public var description: String {
        switch self {
        case let .openFailed(path, message):
            return "Could not open SQLite database at \(path): \(message)"
        case let .database(code, message, context):
            return "SQLite error \(code) while \(context): \(message)"
        case let .migrationFailed(from, to, message):
            return "SQLite migration from schema \(from) to \(to) failed: \(message)"
        case let .corrupt(message):
            return "SQLite database is corrupt: \(message)"
        case let .constraint(message):
            return "SQLite constraint violation: \(message)"
        case .closed:
            return "The SQLite database is closed."
        }
    }
}

extension PKSQLiteStorageError: PKError {
    public var errorDomain: String {
        PKErrorDomain.persistence
    }

    public var errorCode: Int {
        switch self {
        case .openFailed: return 7001
        case .database: return 7002
        case .migrationFailed: return 7003
        case .corrupt: return 7004
        case .constraint: return 7005
        case .closed: return 7006
        }
    }

    public var userFriendlyMessage: String {
        description
    }
}
