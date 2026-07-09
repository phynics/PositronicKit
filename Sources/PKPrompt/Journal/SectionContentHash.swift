import Foundation
import PKShared

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
package func sectionContentHash(_ content: PromptSection.Content) -> UInt64 {
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
            hasher.combine(message.reasoning)
            hasher.combine(message.isSummary)
        }
    }
    return UInt64(bitPattern: Int64(hasher.finalize()))
}
