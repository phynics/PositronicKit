import Foundation
import PKUtilities

/// Text-only content fingerprint shared by `SectionSignature` (PKPrompt journal differ) and
/// `PromptSectionEntry.contentHash` (runtime timeline history).
///
/// Per PKDEEP2-003 decision (b): the fingerprint answers "did this section change in a way the
/// provider will notice?" The provider only ever sees rendered text/messages — never our
/// `estimatedTokens` (internal bookkeeping, derived from the text) or our `type` enum. A
/// token-estimate delta with identical text is an estimator artifact, not real cache-prefix
/// invalidation, so it is excluded from the hash.
///
/// For `.messages` content, `role`/`think`/`isSummary` are folded into the hash inputs.
/// `role` and `think` are reflected in rendered text, but `isSummary` is a display flag with no
/// rendered-text footprint (a message with `role: .user` renders identically regardless of
/// `isSummary`), so it must be hashed explicitly to avoid losing a content-bearing change.
/// The fingerprint is deterministic so restored journal state compares identically in another
/// process.
package func sectionContentHash(_ content: PromptSection.Content) -> UInt64 {
    var components: [String] = []
    switch content {
    case let .text(text):
        components = ["text", text]
    case let .messages(messages):
        components = ["messages"]
        for message in messages {
            components.append(contentsOf: [
                "content", message.content,
                "role", String(describing: message.role),
                "reasoning", String(reflecting: message.reasoning),
                "isSummary", String(message.isSummary),
            ])
        }
    }
    return StableHash.hash(components: components)
}
