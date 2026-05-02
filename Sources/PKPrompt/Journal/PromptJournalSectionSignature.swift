import Foundation

package struct SectionSignature: Equatable {
    let id: String
    let contentHash: Int
    let path: [String]
    let parentID: String?
    let estimatedTokens: Int
    let type: PromptSectionType

    init(_ section: RenderedPrompt.Section) {
        self.id = section.id
        self.contentHash = SectionSignature.hashContent(section.content)
        self.path = section.path
        self.parentID = section.parentID
        self.estimatedTokens = section.estimatedTokens
        self.type = section.type
    }

    private static func hashContent(_ content: PromptSection.Content) -> Int {
        var hasher = Hasher()
        switch content {
        case let .text(text):
            hasher.combine(0)
            hasher.combine(text)
        case let .messages(messages):
            hasher.combine(1)
            for message in messages {
                hasher.combine(message.content)
                hasher.combine(String(describing: message.role))
                hasher.combine(message.think)
                hasher.combine(message.isSummary)
            }
        }
        return hasher.finalize()
    }
}
