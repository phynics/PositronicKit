#if canImport(SwiftUI) && canImport(FoundationModels)
import SwiftUI
import FoundationModels
import PKPrompt
import PKContracts

/// macOS-only import coverage for the deliberately overlapping DSL names in SwiftUI,
/// Foundation Models, and PKPrompt. This file is compiled as part of the ordinary consumer
/// target; it does not run any framework code.
@available(macOS 26.0, *)
private struct WeatherTool: PKTool {
    let callName = "weather"
    let name = "Weather"
    let toolDescription = "Look up weather"
    let requiresPermission = false
    let parametersSchema = makeEmptyObjectSchema()

    func canExecute() async -> Bool { true }

    func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
        .success("ok")
    }
}

@available(macOS 26.0, *)
private struct SwiftUIForEachConsumer: View {
    let values = ["one", "two"]

    var body: some View {
        VStack {
            ForEach(values, id: \.self) { value in
                Text(value)
            }
        }
    }
}

@available(macOS 26.0, *)
private let promptForEachConsumer: any PKPrompt.Prompt = PKPrompt.AnyPrompt.build {
    // The result-builder context resolves this unqualified ForEach to PKPrompt.ForEach.
    ForEach(["one", "two"]) { value in
        PKPrompt.TextPrompt(value, id: value)
    }
}

@available(macOS 26.0, *)
private let qualifiedPromptBuilder: PKPrompt.PromptBuilder.Type = PKPrompt.PromptBuilder.self

@available(macOS 26.0, *)
private let qualifiedPromptType: any PKPrompt.Prompt.Type = PKPrompt.TextPrompt.self

@available(macOS 26.0, *)
private let pkToolType: any PKTool.Type = WeatherTool.self

@available(macOS 26.0, *)
// Swift 6 requires an explicit existential when naming the Foundation Models protocol type.
private let foundationModelsToolType: Any.Type = (any FoundationModels.Tool).self

@available(macOS 26.0, *)
@MainActor private let collisionViewType: any View.Type = SwiftUIForEachConsumer.self

#endif
