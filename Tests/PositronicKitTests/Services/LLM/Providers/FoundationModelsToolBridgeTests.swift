import Foundation
@testable import PKFoundationModelsProvider
import JSONSchemaBuilder
import PKShared
import Testing

#if canImport(FoundationModels)
    import FoundationModels

    /// Fixture tool mirroring the shape PositronicKit's built-in tools declare: a flat object of
    /// primitive-typed properties (`ToolParameterSchema.object { ... }`), described via
    /// `parametersSchema` — no framework dependency of its own.
    private struct FixtureWeatherTool: PKShared.Tool, @unchecked Sendable {
        let id = "lookup_weather"
        let name = "Lookup Weather"
        let description = "Look up the current weather for a city"
        let requiresPermission = false
        var usageExample: String? {
            nil
        }

        let parametersSchema = ToolParameterSchema.object {
                JSONProperty(key: "city") {
                    JSONString().description("City name")
                }
                .required()
                JSONProperty(key: "days") {
                    JSONInteger().description("Forecast horizon in days")
                }
            }.schemaDefinition

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters: [String: AnyCodable]) async throws -> ToolResult {
            let params = ToolParameters(parameters)
            let city = params.optional("city", as: String.self) ?? "?"
            let days = params.optional("days", as: Int.self)
            return .success("weather for \(city) days=\(days.map(String.init) ?? "nil")")
        }
    }

    private struct FixtureFailingTool: PKShared.Tool, @unchecked Sendable {
        let id = "always_fails"
        let name = "Always Fails"
        let description = "A tool that always fails"
        let requiresPermission = false
        var usageExample: String? {
            nil
        }

        let parametersSchema = makeEmptyObjectSchema()

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            .failure("boom")
        }
    }

    /// `PKBridgedFMTool`/`FoundationModelsSchemaBridge` tests (PKPOST-003): bridging a
    /// PositronicKit `Tool`'s runtime JSON-Schema-shaped `parametersSchema` to the framework's
    /// `GenerationSchema`/`GeneratedContent`, and back again for argument decoding.
    @Suite("FoundationModels tool bridge")
    struct FoundationModelsToolBridgeTests {
        @Test("Bridged tool exposes the wrapped tool's id and description")
        func bridgedToolExposesIdentity() {
            guard #available(macOS 26.0, *) else { return }
            let bridged = PKBridgedFMTool(wrapped: FixtureWeatherTool().toAnyTool())
            #expect(bridged.name == "lookup_weather")
            #expect(bridged.description == "Look up the current weather for a city")
        }

        @Test("Bridged tool's parameters schema builds without throwing")
        func bridgedToolBuildsSchema() {
            guard #available(macOS 26.0, *) else { return }
            let bridged = PKBridgedFMTool(wrapped: FixtureWeatherTool().toAnyTool())
            // Accessing `.parameters` exercises `GenerationSchema(root:dependencies:)`; a bad
            // bridge would either throw (caught, falls back to empty-object) or crash. Reaching
            // this line with a schema in hand confirms it did not crash.
            _ = bridged.parameters
        }

        @Test("call(arguments:) decodes typed properties and executes the wrapped tool")
        func callDecodesArgumentsAndExecutes() async throws {
            guard #available(macOS 26.0, *) else { return }
            let bridged = PKBridgedFMTool(wrapped: FixtureWeatherTool().toAnyTool())
            let arguments = GeneratedContent(
                properties: ["city": "Berlin", "days": 3]
            )

            let output = try await bridged.call(arguments: arguments)
            #expect(output == "weather for Berlin days=3")
        }

        @Test("call(arguments:) with only the required property omits the optional one")
        func callDecodesOnlyProvidedProperties() async throws {
            guard #available(macOS 26.0, *) else { return }
            let bridged = PKBridgedFMTool(wrapped: FixtureWeatherTool().toAnyTool())
            let arguments = GeneratedContent(properties: ["city": "Paris"])

            let output = try await bridged.call(arguments: arguments)
            #expect(output == "weather for Paris days=nil")
        }

        @Test("A failing tool's error is returned as text, not thrown (model can see and adjust)")
        func failingToolReturnsErrorAsText() async throws {
            guard #available(macOS 26.0, *) else { return }
            let bridged = PKBridgedFMTool(wrapped: FixtureFailingTool().toAnyTool())
            let arguments = GeneratedContent(properties: [:] as KeyValuePairs<String, any ConvertibleToGeneratedContent>)

            let output = try await bridged.call(arguments: arguments)
            #expect(output == "Error: boom")
        }
    }
#endif
