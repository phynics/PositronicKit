import Foundation
import PKContracts


extension PromptSection {
    /// Rendered content carried by a prompt section.
    public enum Content: Sendable, Equatable, Codable {
        /// Plain text content for standard prompt sections.
        case text(String)
        
        /// Structured chat history content preserved as message values.
        case messages([Message])

        /// Ordered text and binary media content.
        case multimodal(MessageContent)
        
        /// Returns the text payload when the content is plain text.
        public var text: String? {
            if case let .text(content) = self { return content }
            return nil
        }
        
        /// Returns the message payload when the content is chat history.
        public var messages: [Message]? {
            if case let .messages(messages) = self { return messages }
            return nil
        }

        /// Returns the ordered content when the section is multimodal.
        public var multimodal: MessageContent? {
            if case let .multimodal(content) = self { return content }
            return nil
        }
    }
}
