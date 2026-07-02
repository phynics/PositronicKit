import Foundation

/// Type-safe wrapper around tool parameter dictionaries.
///
/// Use `ToolParameters` in your `Tool.execute` implementation to decode and validate
/// arguments with precise error reporting. It handles type coercion (e.g. Double → Int)
/// and throws appropriate `ToolError` cases for missing or invalid arguments.
///
/// ```swift
/// func execute(parameters: [String: Any]) async throws -> ToolResult {
///     let params = ToolParameters(parameters)
///     let path = try params.require("path", as: String.self)
///     let limit = params.optional("limit", as: Int.self) ?? 10
///     // ...
/// }
/// ```
///
/// Prefer `ToolParameters` over ad-hoc `[String: Any]` dictionary access to get
/// consistent error messages and automatic type coercion.
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
        if T.self == Int.self, let doubleVal = value as? Double {
            guard doubleVal.isFinite, let intValue = Int(exactly: doubleVal), let result = intValue as? T else {
                throw ToolError.invalidArgument(
                    key,
                    expected: String(describing: T.self),
                    got: String(describing: doubleVal)
                )
            }
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
            guard doubleVal.isFinite, let intValue = Int(exactly: doubleVal), let result = intValue as? T else {
                return nil
            }
            return result
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
