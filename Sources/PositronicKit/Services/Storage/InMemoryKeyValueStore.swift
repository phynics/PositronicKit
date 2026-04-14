import Foundation

/// An in-memory implementation of `KeyValueStoreProtocol`, suitable for tests and default live values.
public actor InMemoryKeyValueStore: KeyValueStoreProtocol {
    private var storage: [String: Data] = [:]

    public init() {}

    public func value(forKey key: String) async throws -> Data? {
        storage[key]
    }

    public func setValue(_ value: Data?, forKey key: String) async throws {
        if let value {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
    }

    public func allKeys() async throws -> [String] {
        Array(storage.keys)
    }
}
