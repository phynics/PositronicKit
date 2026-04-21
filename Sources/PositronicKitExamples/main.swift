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

    let assembled = try prompt.assembledPrompt()
    let renderedPrompt = await assembled.rendered().string
    let toolPrompt = await formatToolsForPrompt(PositronicKitUsageExamples.makeTools())
    let structuredOutput = PositronicKitUsageExamples.makeStructuredOutputSchema()

    _ = PositronicKitUsageExamples.makePrototypeRuntime()
    _ = PositronicKitUsageExamples.makeConfiguredRuntime()

    print("# PKPrompt Example\n")
    print(renderedPrompt)
    print("\nResolved sections: \(assembled.resolvedSections.map(\.id))")
    print("\n# PositronicKit Example\n")
        print("Prototype runtime and fully configured runtime both initialized successfully.")
        print(toolPrompt)
        print("\nStructured output schema: \(structuredOutput.name)")
        print("Generated from ExampleTagPayload via @Schemable.")
        print("\nRun this executable with `swift run PositronicKitExamples`.")
}

try await runExamples()
