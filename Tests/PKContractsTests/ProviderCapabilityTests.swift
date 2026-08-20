import PKContracts
import Testing

@Suite("Provider capability observability")
struct ProviderCapabilityTests {
    @Test("unsupported provider options produce payload-free warnings")
    func warnsForUnsupportedOptions() {
        let warnings = ProviderCapabilityObservability.warnings(
            provider: .anthropic,
            model: "claude-test",
            hasTools: true,
            hasResponseFormat: true,
            generationParameters: .init(seed: 42)
        )

        #expect(warnings.map(\.category) == [.responseFormat, .generationParameters])
        #expect(warnings.allSatisfy { $0.model == "claude-test" })
        #expect(warnings.allSatisfy { !$0.reason.contains("prompt") })
    }
}
