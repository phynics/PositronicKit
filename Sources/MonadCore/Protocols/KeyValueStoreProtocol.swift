import Foundation

// MARK: - KeyValueStoreProtocol

/// A simple key-value persistence abstraction for lightweight storage needs.
public protocol KeyValueStoreProtocol: Sendable {
    func value(forKey key: String) async throws -> Data?
    func setValue(_ value: Data?, forKey key: String) async throws
    func allKeys() async throws -> [String]
}

// MARK: - Convenience Extensions

public extension KeyValueStoreProtocol {
    func string(forKey key: String) async throws -> String? {
        guard let data = try await value(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setString(_ value: String?, forKey key: String) async throws {
        let data = value.flatMap { $0.data(using: .utf8) }
        try await setValue(data, forKey: key)
    }

    func codable<T: Decodable>(_ type: T.Type, forKey key: String) async throws -> T? {
        guard let data = try await value(forKey: key) else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    func setCodable<T: Encodable>(_ value: T?, forKey key: String) async throws {
        guard let value else {
            try await setValue(nil, forKey: key)
            return
        }
        let data = try JSONEncoder().encode(value)
        try await setValue(data, forKey: key)
    }
}
