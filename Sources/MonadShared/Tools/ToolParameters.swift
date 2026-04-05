import Foundation

/// Type-safe wrapper around tool parameter dictionaries
public struct ToolParameters: Sendable {
    private let raw: [String: AnySendable]

    public init(_ parameters: [String: Any]) {
        raw = parameters.mapValues { AnySendable($0) }
    }

    public func require<T>(_ key: String, as _: T.Type = T.self) throws -> T {
        guard let value = raw[key]?.base else {
            throw ToolError.missingArgument(key)
        }

        // Handle numeric conversions if needed (e.g. Double from JSON into Int)
        if T.self == Int.self, let doubleVal = value as? Double, let result = Int(doubleVal) as? T {
            return result
        }

        guard let typed = value as? T else {
            throw ToolError.invalidArgument(
                key,
                expected: String(describing: T.self),
                got: String(describing: Swift.type(of: value))
            )
        }
        return typed
    }

    public func optional<T>(_ key: String, as _: T.Type = T.self) -> T? {
        guard let value = raw[key]?.base else { return nil }

        if let typed = value as? T {
            return typed
        }

        // Fallback for numeric conversion
        if T.self == Int.self, let doubleVal = value as? Double {
            return Int(doubleVal) as? T
        }

        return nil
    }
}

/// Simple wrapper to satisfy Sendable for Any in parameters
private struct AnySendable: @unchecked Sendable {
    let base: Any
    init(_ base: Any) {
        self.base = base
    }
}
