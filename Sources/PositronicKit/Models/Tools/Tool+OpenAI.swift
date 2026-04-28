import Foundation
import Logging
import OpenAI
import PKShared

public extension PKShared.Tool {
    func toOpenAIToolParam() -> ChatQuery.ChatCompletionToolParam {
        // parametersSchema is [String: AnyCodable] — use JSONEncoder (Codable-aware) not
        // JSONSerialization, which cannot handle the AnyCodable wrapper (__SwiftValue crash).
        let schema: JSONSchema
        if let data = try? JSONEncoder().encode(parametersSchema),
           let decoded = try? JSONDecoder().decode(JSONSchema.self, from: data) {
            schema = decoded
        } else {
            Logger(label: "com.positronickit.tools").warning(
                "Failed to decode parametersSchema for tool '\(id)' — using empty schema. Raw: \(parametersSchema)"
            )
            schema = .object([:])
        }

        return .init(
            function: .init(
                name: id,
                description: description,
                parameters: schema
            )
        )
    }
}
