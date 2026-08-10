import Foundation

/// Type-safe wrapper around tool parameter dictionaries.
///
/// Use `ToolParameters` in your `Tool.execute` implementation to decode and validate
/// arguments with precise error reporting. It handles safe numeric coercion (e.g. a small,
/// integral `Double` → `Int`)
/// and throws appropriate `ToolError` cases for missing or invalid arguments.
///
/// ```swift
/// func execute(parameters: [String: AnyCodable]) async throws -> ToolResult {
///     let params = ToolParameters(parameters)
///     let path = try params.require("path", as: String.self)
///     let limit = params.optional("limit", as: Int.self) ?? 10
///     // ...
/// }
/// ```
///
/// Prefer `ToolParameters` over ad-hoc `[String: AnyCodable]` dictionary access to get
/// consistent error messages and automatic type coercion.
public struct ToolParameters: Sendable {
    private let raw: [String: AnyCodable]

    public init(_ parameters: [String: AnyCodable]) {
        raw = parameters
    }

    public func require<T>(_ key: String, as _: T.Type = T.self) throws -> T {
        guard let parameter = raw[key] else {
            throw ToolError.missingArgument(key)
        }

        if T.self == Int.self {
            guard let intValue = Self.exactInt(from: parameter), let result = intValue as? T else {
                throw ToolError.invalidArgument(
                    key,
                    expected: String(describing: T.self),
                    got: Self.integerConversionDescription(for: parameter)
                )
            }
            return result
        }

        let value = parameter.value
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
        guard let parameter = raw[key] else { return nil }

        if T.self == Int.self {
            return Self.exactInt(from: parameter) as? T
        }

        return parameter.value as? T
    }

    private static func exactInt(from parameter: AnyCodable) -> Int? {
        switch parameter {
        case let .integer(value):
            return Int(exactly: value)
        case let .unsignedInteger(value):
            return Int(exactly: value)
        case let .number(value):
            // A Double cannot represent every integer at and above 2^53. JSON decoding now
            // preserves those values as integer cases, so accepting large legacy Doubles here
            // would reintroduce a silent precision loss at the tool boundary.
            guard value.isFinite,
                  abs(value) < 9_007_199_254_740_992,
                  let exactValue = Int(exactly: value)
            else {
                return nil
            }
            return exactValue
        case .string, .boolean, .dictionary, .array, .null:
            return nil
        }
    }

    private static func integerConversionDescription(for parameter: AnyCodable) -> String {
        switch parameter {
        case .integer, .unsignedInteger, .number:
            return parameter.description
        case .string, .boolean, .dictionary, .array, .null:
            return String(describing: Swift.type(of: parameter.value))
        }
    }
}
