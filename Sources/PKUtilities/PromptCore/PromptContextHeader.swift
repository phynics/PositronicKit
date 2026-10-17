import Foundation

/// Canonical prompt labels shared by the runtime layout and the optional `PKPrompt` product.
///
/// The context-origin header is a single documented constant so the runtime and `PKPrompt`
/// never drift on the exact bytes they put in front of injected context. The header keeps
/// retrieved context visually distinct from host system instructions, so it cannot silently
/// elevate to the same authority (#288).
package enum PromptContextHeader {
    /// The explicit context-origin header placed before retrieved `.context` sections.
    package static let retrievedContext = "=== Retrieved Context ==="
}
