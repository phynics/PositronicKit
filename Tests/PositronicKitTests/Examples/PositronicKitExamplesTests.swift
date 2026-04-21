import Foundation
import Testing
import PKShared
import PositronicKitExamples

struct PositronicKitExamplesTests {
    @Test
    func promptExampleAssemblesReusableSections() async {
        let prompt = PKPromptExamples.makeToolingPrompt(
            tools: ["build", "test", "lint"],
            history: [
                Message(content: "Summarize the package layout.", role: .user),
                Message(content: "The package is split into three main targets.", role: .assistant),
            ],
            userQuery: "Which step should I run next?"
        )

        let assembled = try! prompt.assemblePrompt()
        let sections = assembled.sections

        #expect(sections.map(\.id) == ["system", "available_tools", "chat_history", "user_query"])
        #expect(sections.map(\.role) == [.system, .context, .chatHistory, .userQuery])

        let rendered = await assembled.render().string
        #expect(rendered.contains("You are helping with PositronicKit setup."))
        #expect(rendered.contains("- build"))
        #expect(rendered.contains("Which step should I run next?"))
    }

    @Test
    func toolExampleFormatsForPrompt() async throws {
        let tools = PositronicKitUsageExamples.makeTools()
        let formatted = await formatToolsForPrompt(tools)

        #expect(formatted.contains("`example_greet`"))
        #expect(formatted.contains("Greet a user by name"))

        let schema = tools[0].parametersSchema
        #expect(schema["type"]?.asString == "object")
        #expect(schema["properties"]?.asDictionary?["name"]?.asDictionary?["type"]?.asString == "string")

        let result = try await tools[0].execute(parameters: ["name": "Taylor"])
        #expect(result.success)
        #expect(result.output == "Hello, Taylor!")
    }

    @Test
    func structuredOutputExampleUsesSchemableGeneratedSchema() throws {
        let structuredOutput = PositronicKitUsageExamples.makeStructuredOutputSchema()
        let encoded = try JSONEncoder().encode(structuredOutput.schema)
        let encodedString = String(decoding: encoded, as: UTF8.self)

        #expect(structuredOutput.name == "tag_payload")
        #expect(encodedString.contains("\"type\":\"object\""))
        #expect(encodedString.contains("\"tags\""))
    }

    @Test
    func runtimeExamplesBuildPrototypeAndConfiguredCores() {
        let prototype = PositronicKitUsageExamples.makePrototypeRuntime()
        let configured = PositronicKitUsageExamples.makeConfiguredRuntime()

        _ = prototype
        _ = configured
    }
}
