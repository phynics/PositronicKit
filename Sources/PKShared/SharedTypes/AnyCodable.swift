import Foundation

/// A wrapper for Any that is Codable
public enum AnyCodable: Codable, Sendable, Equatable, Hashable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case dictionary([String: AnyCodable])
    case array([AnyCodable])
    case null

    public var value: Any {
        switch self {
        case let .string(str): return str
        case let .number(num): return num
        case let .boolean(bool): return bool
        case let .dictionary(dict): return dict.mapValues { $0.value }
        case let .array(arr): return arr.map { $0.value }
        case .null: return NSNull()
        }
    }

    public var description: String {
        switch self {
        case let .string(str): return str
        case let .number(num): return String(num)
        case let .boolean(bool): return String(bool)
        case let .dictionary(dict): return String(describing: dict)
        case let .array(arr): return String(describing: arr)
        case .null: return "null"
        }
    }

    public func toAny() -> Any {
        value
    }

    public var asString: String? {
        if case let .string(str) = self { return str }
        return nil
    }

    public var asDictionary: [String: AnyCodable]? {
        if case let .dictionary(dict) = self { return dict }
        return nil
    }

    public var asArray: [AnyCodable]? {
        if case let .array(arr) = self { return arr }
        return nil
    }

    public init(_ value: Any?) {
        if let anyCodable = value as? AnyCodable {
            self = anyCodable
            return
        }
        if let value = value as? String {
            self = .string(value)
        } else if let value = value as? Double {
            self = .number(value)
        } else if let value = value as? Int {
            self = .number(Double(value))
        } else if let value = value as? Bool {
            self = .boolean(value)
        } else if let value = value as? [String: Any] {
            self = .dictionary(value.mapValues { AnyCodable($0) })
        } else if let value = value as? [Any] {
            self = .array(value.map { AnyCodable($0) })
        } else {
            self = .null
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode([String: AnyCodable].self) {
            self = .dictionary(value)
        } else if let value = try? container.decode([AnyCodable].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .boolean(value): try container.encode(value)
        case let .dictionary(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - ExpressibleByLiteral

// Conforming `AnyCodable` to the scalar literal protocols lets `[String: AnyCodable]` be
// written as naturally as `[String: Any]` at call sites (tool `execute` arguments, test
// fixtures, etc.), so adopting the Sendable `[String: AnyCodable]` argument type does not
// impose per-value `AnyCodable(...)` wrapping for literal values. Collection literals
// (`ExpressibleByArrayLiteral`/`ExpressibleByDictionaryLiteral`) are intentionally omitted to
// avoid inference ambiguity with `[String: AnyCodable]` dictionary literals; nested values use
// the explicit `.array`/`.dictionary` cases.
extension AnyCodable: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension AnyCodable: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .number(Double(value))
    }
}

extension AnyCodable: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .number(value)
    }
}

extension AnyCodable: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .boolean(value)
    }
}

// MARK: - JSON Utilities

public func toJsonString(_ dict: [String: AnyCodable]) throws -> String {
    let anyDict = dict.mapValues { $0.value }
    let data = try JSONSerialization.data(withJSONObject: anyDict, options: [.sortedKeys])
    return String(bytes: data, encoding: .utf8) ?? "{}"
}

public extension Dictionary where Key == String, Value == AnyCodable {
    func toJsonString() throws -> String {
        return try PKShared.toJsonString(self)
    }

    /// Converts a `[String: AnyCodable]` dictionary to `[String: Any]` by unwrapping each value.
    var toAnyDictionary: [String: Any] {
        mapValues { $0.value }
    }
}
