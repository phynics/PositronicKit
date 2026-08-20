import Foundation

/// Type-safe wrapper around tool parameter dictionaries.
///
/// Use `ToolParameters` in your `Tool.execute` implementation to decode and validate
/// arguments with precise error reporting. It handles safe numeric coercion (e.g. a small,
/// integral `Double` → `Int`, or an exactly representable integer → `Double`/`Float`)
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

        if T.self == Double.self {
            guard let doubleValue = Self.exactDouble(from: parameter), let result = doubleValue as? T else {
                throw ToolError.invalidArgument(
                    key,
                    expected: String(describing: T.self),
                    got: Self.integerConversionDescription(for: parameter)
                )
            }
            return result
        }

        if T.self == Float.self {
            guard let floatValue = Self.exactFloat(from: parameter), let result = floatValue as? T else {
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

        if T.self == Double.self {
            return Self.exactDouble(from: parameter) as? T
        }

        if T.self == Float.self {
            return Self.exactFloat(from: parameter) as? T
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

    /// Converts numeric values without rounding. Integral values that cannot be represented
    /// exactly by binary64 are rejected rather than silently changing the tool argument.
    private static func exactDouble(from parameter: AnyCodable) -> Double? {
        switch parameter {
        case let .integer(value):
            return Double(exactly: value)
        case let .unsignedInteger(value):
            return Double(exactly: value)
        case let .number(value):
            return value
        case .string, .boolean, .dictionary, .array, .null:
            return nil
        }
    }

    /// Converts numeric values without rounding. Existing floating values are accepted only
    /// when binary32 can represent them exactly, matching the integer conversion policy.
    private static func exactFloat(from parameter: AnyCodable) -> Float? {
        switch parameter {
        case let .integer(value):
            return Float(exactly: value)
        case let .unsignedInteger(value):
            return Float(exactly: value)
        case let .number(value):
            return Float(exactly: value)
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
