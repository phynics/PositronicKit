import Foundation
import PKPrompt
import PKShared

func runExamples() async throws {
    let prompt = PKPromptExamples.makeToolingPrompt(
        tools: ["swift build", "swift test", "swift package dump-package"],
        history: [
            Message(content: "How should I validate my package changes?", role: .user),
            Message(content: "Start with swift build, then run swift test.", role: .assistant),
        ],
        userQuery: "What should I run before opening a pull request?"
    )

    let assembled = try prompt.assemblePrompt()
    let renderedPrompt = await assembled.render().string
    let toolPrompt = await formatToolsForPrompt(PositronicKitUsageExamples.makeTools())
    let structuredOutput = PositronicKitUsageExamples.makeStructuredOutputSchema()
    let structuredOutputRequest = PositronicKitUsageExamples.makeStructuredOutputRequest()

    // README "Choosing A Layer" examples — kept compile-checked here.
    let layer1 = try await PKPromptExamples.renderLayer1ToString()
    let (layer2Assembled, layer2Rendered) = try await PKPromptExamples.assembleLayer2()
    let (initialPlan, updatedPlan, autoCompactedPlan, compactedPlan) = try await PKPromptExamples.journalLayer3()

    _ = PositronicKitUsageExamples.makePrototypeRuntime()
    _ = PositronicKitUsageExamples.makeConfiguredRuntime()

    print("# PKPrompt Example\n")
    print(renderedPrompt)
    print("\nPrompt sections: \(assembled.sections.map(\.id))")
    print("\n# PositronicKit Example\n")
    print("Prototype runtime and fully configured runtime both initialized successfully.")
    print(toolPrompt)
    print("\nStructured output schema: \(structuredOutput.name)")
    print("Structured output request: \(structuredOutputRequest)")
    print("Generated from ExampleTagPayload via @Schemable.")

    print("\n# PKPrompt Layer Examples\n")
    print("Layer 1 (Prompt → String):")
    print(layer1 ?? "")
    print("\nLayer 2 (Prompt → AssembledPrompt → RenderedPrompt):")
    print("  assembled sections: \(layer2Assembled.sections.map(\.id))")
    print("  rendered sections:  \(layer2Rendered.sections.map(\.id))")
    print("\nLayer 3 (RenderedPrompt → PromptJournal):")
    print("  base section paths:    \(initialPlan.baseSections.map(\.journalPath))")
    print("  overlay section paths: \(updatedPlan.overlaySections.map(\.journalPath))")
    print("  overlays empty after auto-compact: \(autoCompactedPlan.overlaySections.isEmpty)")
    print("  overlays empty after compact: \(compactedPlan?.overlaySections.isEmpty ?? false)")

    print("\nRun this executable with `swift run PositronicKitExamples`.")
}

try await runExamples()
