import Foundation
import PKShared
import PKUtilities

package extension PromptSection {
    /// Returns a constrained copy that never renders beyond the supplied token limit.
    func constrained(to tokens: Int, compressionOutcome: CompressionNodeReport? = nil) -> PromptSection {
        PromptSection(
            id: id,
            role: role,
            priority: priority,
            estimatedTokens: min(estimatedTokens, tokens),
            compression: compression,
            type: type,
            cachePolicy: cachePolicy,
            path: path,
            parentID: parentID,
            compressionOutcome: compressionOutcome ?? self.compressionOutcome,
            render: { limit in
                await renderClosure(min(limit ?? tokens, tokens))
            }
        )
    }

    /// Returns a summarized text copy of this section.
    func summarized(
        _ summary: String,
        estimatedTokens: Int,
        compressionOutcome: CompressionNodeReport? = nil
    ) -> PromptSection {
        PromptSection(
            id: id,
            role: role,
            priority: priority,
            estimatedTokens: estimatedTokens,
            compression: compression,
            type: .text,
            cachePolicy: cachePolicy,
            path: path,
            parentID: parentID,
            compressionOutcome: compressionOutcome ?? self.compressionOutcome,
            render: { _ in .text(summary) }
        )
    }

    /// Returns a dropped copy of this section that renders no content.
    func dropped(compressionOutcome: CompressionNodeReport? = nil) -> PromptSection {
        PromptSection(
            id: id,
            role: role,
            priority: priority,
            estimatedTokens: 0,
            compression: compression,
            type: type,
            cachePolicy: cachePolicy,
            path: path,
            parentID: parentID,
            compressionOutcome: compressionOutcome ?? self.compressionOutcome,
            render: { _ in nil }
        )
    }

    /// Returns a copy with updated compression metadata.
    func withCompressionOutcome(_ compressionOutcome: CompressionNodeReport?) -> PromptSection {
        PromptSection(
            id: id,
            role: role,
            priority: priority,
            estimatedTokens: estimatedTokens,
            compression: compression,
            type: type,
            cachePolicy: cachePolicy,
            path: path,
            parentID: parentID,
            compressionOutcome: compressionOutcome,
            render: renderClosure
        )
    }
}
