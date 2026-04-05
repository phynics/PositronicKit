import Foundation
import OpenAI
import MonadShared

extension ToolReference {
    public func toToolParam() -> ChatQuery.ChatCompletionToolParam? {
        switch self {
        case .known:
            // This usually needs resolving against a registry to get the schema
            // but for simple cases we might have a placeholder
            return nil
        case .custom(let definition):
            // definition.parametersSchema is [String: AnyCodable]
            // Convert to [String: Any] first
            let anyDict = definition.parametersSchema.mapValues { $0.value }

            // Map to OpenAI compatible structure
            let schemaDict = mapToAnyJSONDocument(anyDict)
            let schema = JSONSchema.object(schemaDict)

            return .init(
                function: .init(
                    name: definition.name,
                    description: definition.description,
                    parameters: schema
                )
            )
        }
    }
}

private func mapToAnyJSONDocument(_ value: Any) -> AnyJSONDocument {
    if let str = value as? String { return .init(str) }
    if let num = value as? Double { return .init(num) }
    if let num = value as? Int { return .init(Double(num)) }
    if let bool = value as? Bool { return .init(bool) }
    if let dict = value as? [String: Any] {
        return .init(dict.mapValues { mapToAnyJSONDocument($0) })
    }
    if let arr = value as? [Any] {
        return .init(arr.map { mapToAnyJSONDocument($0) })
    }
    // Fallback for null or unknown types
    return .init("")
}

private func mapToAnyJSONDocument(_ dict: [String: Any]) -> [String: AnyJSONDocument] {
    return dict.mapValues { mapToAnyJSONDocument($0) }
}
