import Foundation

public struct UserPrompt: Prompt {
    public let id: String
    public let text: String
    public let priority: Int
    public let estimatedTokens: Int?

    public init(
        _ text: String,
        id: String = "user_query",
        priority: Int = 10,
        estimatedTokens: Int? = nil
    ) {
        self.id = id
        self.text = text
        self.priority = priority
        self.estimatedTokens = estimatedTokens
    }

    public var body: some Prompt {
        TextSection(
            id: id,
            text: text,
            role: .userQuery,
            priority: priority,
            compression: .keep,
            cachePolicy: .volatile,
            estimatedTokens: estimatedTokens
        )
    }
}
