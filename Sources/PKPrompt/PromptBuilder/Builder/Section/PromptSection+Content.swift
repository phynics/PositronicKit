import Foundation
import PKShared
import PKUtilities


extension PromptSection {
    /// Rendered content carried by a prompt section.
    public enum Content: Sendable, Equatable {
        /// Plain text content for standard prompt sections.
        case text(String)
        
        /// Structured chat history content preserved as message values.
        case messages([Message])
        
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
    }
}
