import Foundation
import PKContracts
@testable import PositronicKit
import Testing

/// A minimal client that declares only a prompt-caching capability, so tests can exercise the
/// runtime's capability gate without a provider transport.
private struct CapabilityOnlyClient: LLMClientProtocol {
    let promptCachingCapability: PromptCachingCapability

    func chatStream(
        messages _: [LLMMessage],
        tools _: [LLMToolDefinition]?,
        toolChoice _: LLMToolChoice?,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

@Suite("Prompt caching policy")
struct PromptCachingPolicyTests {
    @Test("a per-Turn override wins over the runtime default")
    func overrideWins() {
        #expect(PromptCachingPolicy.resolved(override: .disabled, default: .automatic()) == .disabled)
        #expect(
            PromptCachingPolicy.resolved(
                override: nil,
                default: .automatic(retention: .extended)
            ) == .automatic(retention: .extended)
        )
    }

    @Test("a disabled policy produces no directive")
    func disabledProducesNoDirective() {
        #expect(PromptCachingPolicy.disabled.directive(for: UUID()) == nil)
        #expect(PromptCachingPolicy.disabled.keylessDirective == nil)
    }

    @Test("an automatic policy attaches the Timeline routing key and retention")
    func automaticAttachesKey() {
        let timelineID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let directive = PromptCachingPolicy.automatic(retention: .extended).directive(for: timelineID)

        #expect(directive?.routingKey == "cc43fc6e7b6aaa5bfed4715c60e8dd7f")
        #expect(directive?.retention == .extended)
        #expect(directive?.breakpoints.isEmpty == true)
    }

    @Test("a Timeline-free policy carries no routing key")
    func oneShotHasNoKey() {
        let directive = PromptCachingPolicy.automatic().keylessDirective

        #expect(directive?.routingKey == nil)
        #expect(directive?.retention == .short)
    }

    @Test("the runtime drops directives for a client with no caching capability")
    func capabilityGate() {
        let directive = PromptCacheDirective(routingKey: "key", retention: .short)

        #expect(
            LLMService.honoredPromptCache(directive, for: CapabilityOnlyClient(promptCachingCapability: .none))
                == nil
        )
        #expect(
            LLMService.honoredPromptCache(directive, for: CapabilityOnlyClient(promptCachingCapability: .automatic))
                == directive
        )
        #expect(
            LLMService.honoredPromptCache(
                directive,
                for: CapabilityOnlyClient(promptCachingCapability: .explicit(maxBreakpoints: 2))
            ) == directive
        )
    }
}
