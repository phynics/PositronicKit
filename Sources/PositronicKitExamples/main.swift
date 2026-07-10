import Foundation
import PKPrompt
import PKShared
import PositronicKit

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
    let toolPrompt = await PositronicKitUsageExamples.makeTools().formattedForPrompt()
    let structuredOutput = PositronicKitUsageExamples.makeStructuredOutputSchema()
    let structuredOutputRequest = PositronicKitUsageExamples.makeStructuredOutputRequest()
    let decodedStructuredOutput = try PositronicKitUsageExamples.decodeStructuredOutputExample(
        from: #"{"tags":["swift","structured-output"]}"#
    )
    let sidecarDirectives = PositronicKitUsageExamples.makeSidecarDirectives()
    let cadenceDirectives = PositronicKitUsageExamples.makeCadencedSidecarDirectives(
        turnIndex: 5,
        hasConversationTitle: true
    )
    let oneShotTitleRequest = PositronicKitUsageExamples.makeOneShotTitleStructuredOutputRequest()
    let oneShotTitle = try PositronicKitUsageExamples.decodeOneShotTitlePayload(
        from: #"{"title":"Planning Session"}"#
    )

    // README "Choosing A Layer" examples — kept compile-checked here.
    let layer1 = try await PKPromptExamples.renderLayer1ToString()
    let (layer2Assembled, layer2Rendered) = try await PKPromptExamples.assembleLayer2()
    let (initialPlan, updatedPlan, autoCompactedPlan, compactedPlan) = try await PKPromptExamples.journalLayer3()

    _ = PositronicKitUsageExamples.makePrototypeRuntime()
    _ = PositronicKitUsageExamples.makeConfiguredRuntime()

    let oneShotRuntime = PositronicKitUsageExamples.makeOneShotRuntime()
    let oneShot = try await oneShotRuntime.complete("Say hello in one word.")
    let conversation = try await PositronicKitUsageExamples.makeConversationExample()
    let timelineManager = PositronicKitUsageExamples.makeTimelineManagerExample()
    let agenticRuntime = PositronicKitUsageExamples.makeAgenticRuntimeExample()

    print("# PKPrompt Example\n")
    print(renderedPrompt)
    print("\nPrompt sections: \(assembled.sections.map(\.id))")
    print("\n# PositronicKit Example\n")
    print("Prototype runtime and fully configured runtime both initialized successfully.")
    print("One-shot response: \(oneShot)")
    print("Operation ladder examples: conversation \(conversation.id), timeline manager \(timelineManager), agent \(agenticRuntime.agentInstanceId)")
    print(toolPrompt)
    print("\nStructured output schema: \(structuredOutput.name)")
    print("Structured output request: \(structuredOutputRequest)")
    print("Generated from ExampleTagPayload via @Schemable.")
    print("Decoded structured output sample: \(decodedStructuredOutput.tags)")

    print("\nSidecar directives (piggy-backed requests): \(sidecarDirectives.map(\.name))")
    for directive in sidecarDirectives {
        print("  - \(directive.name): \(directive.instruction)")
    }
    print("  Consume via PositronicKit.run(_:) — see makeSidecarDirectives() doc comment.")
    print("Cadence example at turn 5 with an existing title: \(cadenceDirectives.map(\.name))")
    print("One-shot title request: \(oneShotTitleRequest)")
    print("Decoded one-shot title payload: \(oneShotTitle.title ?? "nil")")

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
