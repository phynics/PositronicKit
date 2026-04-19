import Foundation
import PKPrompt
import PKShared

/// Advanced options for prompt assembly.
///
/// Most callers should use ``PromptAssembler/assemble(_:agentInstance:timeline:extensionSections:)``
/// or ``PromptAssembler/prepare(_:)``. Use this type when you need to override the default
/// assembly pipeline or apply compression and structured diff configuration.
public struct PromptAssemblyOptions: Sendable {
    public var overridePipeline: PromptAssemblyPipeline?
    public var tokenBudget: TokenBudget?
    public var compressor: SectionCompressor?
    public var structuredDiff: StructuredDiffHint?
    public var structuredExecutor: StructuredCompressionExecutor

    public init(
        overridePipeline: PromptAssemblyPipeline? = nil,
        tokenBudget: TokenBudget? = nil,
        compressor: SectionCompressor? = nil,
        structuredDiff: StructuredDiffHint? = nil,
        structuredExecutor: StructuredCompressionExecutor = StructuredCompressionExecutor()
    ) {
        self.overridePipeline = overridePipeline
        self.tokenBudget = tokenBudget
        self.compressor = compressor
        self.structuredDiff = structuredDiff
        self.structuredExecutor = structuredExecutor
    }
}
