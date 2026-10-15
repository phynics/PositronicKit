import CPKSQLite
import Foundation
import PKSQLiteStorage
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Proves the vendored SQLite is symbol-isolated from the system `libsqlite3` that Apple
/// frameworks and other libraries load at runtime.
///
/// The vendored copy is compiled from `SQLiteDatabase`'s `CPKSQLite` target with every public
/// `sqlite3_*` symbol renamed to `pk_sqlite3_*`. This test confirms the prefixed symbol links and
/// reports the vendored version, and, when a system library is present, that it can be loaded and
/// called independently in the same process.
@Suite("PKSQLiteStorage symbol isolation")
struct PKSQLiteSymbolIsolationTests {
    @Test("vendored symbols are prefixed and coexist with the system SQLite")
    func vendoredSymbolsCoexistWithSystem() throws {
        let vendoredVersion = String(cString: pk_sqlite3_libversion())
        #expect(vendoredVersion.hasPrefix("3.54"), "expected the pinned 3.54.x amalgamation")

        // The system library is absent on minimal Linux images; that is not a failure, because
        // the isolation guarantee is that the vendored symbols never collided in the first place.
        for candidate in ["libsqlite3.so.0", "libsqlite3.so", "libsqlite3.dylib"] {
            guard let handle = dlopen(candidate, RTLD_NOW) else { continue }
            defer { dlclose(handle) }

            if let symbol = dlsym(handle, "sqlite3_libversion") {
                typealias LibVersion = @convention(c) () -> UnsafePointer<CChar>
                let systemVersion = String(cString: unsafeBitCast(symbol, to: LibVersion.self)())
                #expect(!systemVersion.isEmpty)
            }
            return
        }
    }
}
