import Foundation
import PKShared

/// The current user query section in the ``PromptBuilder`` DSL.
///
/// Renders with `role: .userQuery` and `cachePolicy: .volatile` (the query changes every
/// turn) and `compression: .keep`, so it is never truncated/summarized by the compressor.
public struct UserPrompt: Prompt {
    public let id: String
    public let content: MessageContent
    public var text: String { content.text }
    public let priority: Int
    public let estimatedTokens: Int?

    public init(
        _ text: String,
        id: String = "user_query",
        priority: Int = 10,
        estimatedTokens: Int? = nil
    ) {
        self.id = id
        content = MessageContent(text)
        self.priority = priority
        self.estimatedTokens = estimatedTokens
    }

    /// Creates a current-user section with ordered multimodal content.
    public init(
        _ content: MessageContent,
        id: String = "user_query",
        priority: Int = 10,
        estimatedTokens: Int? = nil
    ) {
        self.id = id
        self.content = content
        self.priority = priority
        self.estimatedTokens = estimatedTokens
    }

    public var body: some Prompt {
        MultimodalPromptPrimitive(
            id: id,
            content: content,
            role: .userQuery,
            priority: priority,
            estimatedTokens: estimatedTokens,
            compression: .keep,
            cachePolicy: .volatile
        )
    }
}

/// A current-user prompt containing one encoded image.
public struct ImagePrompt: Prompt {
    public let image: ImageContent
    public let id: String

    public init(_ image: ImageContent, id: String = "user_query") {
        self.image = image
        self.id = id
    }

    public var body: some Prompt {
        UserPrompt(MessageContent(parts: [.image(image)]), id: id)
    }
}

/// A current-user prompt containing one encoded audio clip.
public struct AudioPrompt: Prompt {
    public let audio: AudioContent
    public let id: String

    public init(_ audio: AudioContent, id: String = "user_query") {
        self.audio = audio
        self.id = id
    }

    public var body: some Prompt {
        UserPrompt(MessageContent(parts: [.audio(audio)]), id: id)
    }
}
