import Foundation

/// Encodes a stored value as canonical JSON (sorted keys, so equal values produce equal bytes).
func pkEncodeJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    return String(decoding: data, as: UTF8.self)
}

/// Decodes a stored value, reporting a corrupt body as ``PKSQLiteStorageError/corrupt(message:)``.
func pkDecodeJSON<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
    do {
        return try JSONDecoder().decode(type, from: Data(string.utf8))
    } catch {
        throw PKSQLiteStorageError.corrupt(message: "could not decode \(T.self): \(error)")
    }
}
