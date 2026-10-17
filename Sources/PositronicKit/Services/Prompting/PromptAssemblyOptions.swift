import Foundation
import Logging
import PKContracts
import PKUtilities

/// Advanced options for prompt assembly.
///
/// Runtime-owned assembly options used by the turn pipeline and focused tests. Consumer prompt
/// ownership belongs on the direct Turn request surface.
///
/// The runtime does not compress or summarize prompt content. Prompt assembly only resolves the
/// runtime-owned sections and renders them; overflow is handled by projection, stepwise history
/// trimming, or a structured preparation failure before assembly.
struct PromptAssemblyOptions: Sendable {
    var customSections: (@Sendable () async -> [PromptSection])? = nil
    var logger: Logger?
    /// Optional bounded replacement for a covered historical prefix. When present, prompt
    /// assembly renders it as a semi-stable section ahead of the retained `chat_history` tail.
    var historyProjectionReplacement: String?

    init(
        customSections: (@Sendable () async -> [PromptSection])? = nil,
        logger: Logger? = nil,
        historyProjectionReplacement: String? = nil
    ) {
        self.customSections = customSections
        self.logger = logger
        self.historyProjectionReplacement = historyProjectionReplacement
    }
}
