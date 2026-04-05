import Foundation

/// A type that can be formatted for inclusion in an LLM prompt.
public protocol PromptFormattable: Sendable {
    /// The formatted string representation of this object for a prompt.
    var promptString: String { get }
}
