import Foundation
import struct JSONSchema.Schema
import JSONSchemaBuilder
@testable import PKContracts
import PKUtilities
import Testing

/// Coverage for `LLMConfiguration.validate()` and `ConfigurationError` — the validation
/// path that checks provider config, model names, API keys, and endpoint URLs.
@Suite("LLMConfiguration validation")
struct LLMConfigurationValidationTests {

    @Test("validate succeeds for a fully valid OpenAI config")
    func validateSucceedsForValidOpenAI() throws {
        let config = LLMConfiguration(
            activeProvider: .openAI,
            providers: [.openAI: ProviderConfiguration(
                endpoint: "https://api.openai.com",
                apiKey: "sk-test",
                modelName: "gpt-4o",
                utilityModel: "gpt-4o",
                fastModel: "gpt-4o",
                toolFormat: .openAI
            )]
        )
        #expect(throws: Never.self) { try config.validate() }
        #expect(config.isValid == true)
    }

    @Test("validate throws when active provider has no configuration")
    func validateThrowsWhenProviderMissing() {
        // Build a config where the active provider's entry is removed.
        var config = LLMConfiguration.openAI
        config.providers[.openAI] = nil
        #expect(config.isValid == false)
        #expect(throws: ConfigurationError.self) {
            try config.validate()
        }
    }

    @Test("validate throws when model name is empty")
    func validateThrowsWhenModelNameEmpty() {
        var config = LLMConfiguration.openAI
        config.providers[.openAI]?.modelName = ""
        #expect(throws: ConfigurationError.self) {
            try config.validate()
        }
    }

    @Test("validate throws when API key is empty for non-Ollama provider")
    func validateThrowsWhenAPIKeyEmpty() {
        var config = LLMConfiguration.openAI
        config.providers[.openAI]?.apiKey = ""
        #expect(throws: ConfigurationError.self) {
            try config.validate()
        }
    }

    @Test("validate allows empty API key for Ollama")
    func validateAllowsEmptyKeyForOllama() throws {
        let config = LLMConfiguration(
            activeProvider: .ollama,
            providers: [.ollama: ProviderConfiguration(
                endpoint: "http://localhost:11434",
                apiKey: "",
                modelName: "llama3",
                utilityModel: "llama3",
                fastModel: "llama3",
                toolFormat: .openAI
            )]
        )
        #expect(throws: Never.self) { try config.validate() }
    }

    @Test("validate throws for invalid endpoint (not a URL)")
    func validateThrowsForInvalidEndpoint() {
        var config = LLMConfiguration.openAI
        config.providers[.openAI]?.apiKey = "sk-test"
        config.providers[.openAI]?.modelName = "gpt-4o"
        config.providers[.openAI]?.endpoint = "not-a-url"
        #expect(throws: ConfigurationError.self) {
            try config.validate()
        }
    }

    @Test("validate throws for endpoint with unsupported scheme")
    func validateThrowsForUnsupportedScheme() {
        var config = LLMConfiguration.openAI
        config.providers[.openAI]?.apiKey = "sk-test"
        config.providers[.openAI]?.modelName = "gpt-4o"
        config.providers[.openAI]?.endpoint = "ftp://files.example.com"
        #expect(throws: ConfigurationError.self) {
            try config.validate()
        }
    }

    @Test("validate throws for HTTP(S) endpoints without a host")
    func validateThrowsForHostlessEndpoint() {
        for endpoint in ["https:", "https:api.example.com", "http:///api/v1"] {
            var config = LLMConfiguration.openAI
            config.providers[.openAI]?.apiKey = "sk-test"
            config.providers[.openAI]?.modelName = "gpt-4o"
            config.providers[.openAI]?.endpoint = endpoint

            do {
                try config.validate()
                Issue.record("Expected hostless endpoint to be rejected: \(endpoint)")
            } catch let error as ConfigurationError {
                guard case let .invalidEndpoint(invalidEndpoint) = error else {
                    Issue.record("Expected invalidEndpoint for \(endpoint), got: \(error)")
                    continue
                }
                #expect(invalidEndpoint == endpoint)
            } catch {
                Issue.record("Expected ConfigurationError for \(endpoint), got: \(error)")
            }
        }
    }

    @Test("validate preserves HTTP(S) endpoints with host, port, and path")
    func validateSucceedsForEndpointAuthority() throws {
        for endpoint in [
            "https://api.example.com",
            "https://api.example.com:8443/v1",
            "http://localhost:11434/api",
        ] {
            var config = LLMConfiguration.openAI
            config.providers[.openAI]?.apiKey = "sk-test"
            config.providers[.openAI]?.modelName = "gpt-4o"
            config.providers[.openAI]?.endpoint = endpoint
            #expect(throws: Never.self) { try config.validate() }
        }
    }

    @Test("activeProviderConfiguration falls back to defaults when provider is missing")
    func activeProviderConfigurationFallback() {
        var config = LLMConfiguration.openAI
        config.providers[.openAI] = nil
        // Should fall back to ProviderConfiguration.defaultFor(.openAI), not crash.
        let providerConfig = config.activeProviderConfiguration
        #expect(!providerConfig.modelName.isEmpty)
    }

    @Test("ConfigurationError messages are descriptive")
    func configurationErrorMessages() {
        #expect(ConfigurationError.invalidConfiguration(reason: "test").errorDescription?.contains("test") == true)
        #expect(ConfigurationError.missingAPIKey(.openAI).errorDescription?.contains("OpenAI") == true)
        #expect(ConfigurationError.invalidEndpoint("bad").errorDescription?.contains("bad") == true)
        #expect(ConfigurationError.noBackupFound.errorDescription?.contains("backup") == true)
        #expect(ConfigurationError.importFailed.errorDescription?.contains("format") == true)
    }

    @Test("ConfigurationError userFriendlyMessage is user-facing")
    func configurationErrorUserMessages() {
        #expect(ConfigurationError.invalidConfiguration(reason: "x").userFriendlyMessage.contains("invalid") == true)
        #expect(ConfigurationError.missingAPIKey(.openAI).userFriendlyMessage.contains("API key") == true)
        #expect(ConfigurationError.invalidEndpoint("x").userFriendlyMessage.contains("endpoint") == true)
        #expect(ConfigurationError.noBackupFound.userFriendlyMessage.contains("backup") == true)
        #expect(ConfigurationError.importFailed.userFriendlyMessage.contains("format") == true)
    }
}

/// Coverage for `ToolCall` Codable and equality semantics.
@Suite("ToolCall")
struct ToolCallCodableTests {

    @Test("ToolCall decodes with an explicit id")
    func decodesWithExplicitId() throws {
        let json = #"{"id":"call_abc","name":"search","arguments":{"q":"test"}}"#
        let call = try JSONDecoder().decode(ToolCall.self, from: Data(json.utf8))
        #expect(call.id == "call_abc")
        #expect(call.name == "search")
    }

    @Test("ToolCall decodes with a missing id, generating a UUID")
    func decodesWithMissingId() throws {
        let json = #"{"name":"search","arguments":{}}"#
        let call = try JSONDecoder().decode(ToolCall.self, from: Data(json.utf8))
        #expect(!call.id.isEmpty)
        #expect(call.name == "search")
    }

    @Test("ToolCall equality ignores the id (name + arguments only)")
    func equalityIgnoresId() {
        let a = ToolCall(id: "call_1", name: "search", arguments: ["q": .string("test")])
        let b = ToolCall(id: "call_2", name: "search", arguments: ["q": .string("test")])
        #expect(a == b)
    }

    @Test("ToolCall inequality on different name")
    func inequalityOnName() {
        let a = ToolCall(name: "search", arguments: [:])
        let b = ToolCall(name: "read", arguments: [:])
        #expect(a != b)
    }

    @Test("ToolCall hash is stable for same name + arguments")
    func hashStability() {
        let a = ToolCall(id: "1", name: "search", arguments: ["q": .string("x")])
        let b = ToolCall(id: "2", name: "search", arguments: ["q": .string("x")])
        #expect(a.hashValue == b.hashValue)
    }
}

/// Coverage for `ToolCallFormat` lenient decoding.
@Suite("ToolCallFormat")
struct ToolCallFormatTests {

    @Test("decodes the canonical raw value")
    func decodesCanonical() throws {
        let format = try JSONDecoder().decode(ToolCallFormat.self, from: Data("\"Native (OpenAI)\"".utf8))
        #expect(format == .openAI)
    }

    @Test("decodes stale legacy values to .openAI")
    func decodesLegacyToOpenAI() throws {
        let json = Data("\"JSON\"".utf8)
        let format = try JSONDecoder().decode(ToolCallFormat.self, from: json)
        #expect(format == .openAI)

        let xmlJson = Data("\"XML\"".utf8)
        let xmlFormat = try JSONDecoder().decode(ToolCallFormat.self, from: xmlJson)
        #expect(xmlFormat == .openAI)
    }

    @Test("encodes to the canonical raw value")
    func encodesCanonical() throws {
        let data = try JSONEncoder().encode(ToolCallFormat.openAI)
        let str = try #require(String(data: data, encoding: .utf8))
        #expect(str.contains("Native (OpenAI)"))
    }

    @Test("id returns the raw value")
    func idReturnsRawValue() {
        #expect(ToolCallFormat.openAI.id == "Native (OpenAI)")
    }

    @Test("CaseIterable contains only openAI")
    func caseIterable() {
        #expect(ToolCallFormat.allCases == [.openAI])
    }
}

/// Coverage for `WorkspaceReference` helpers and Codable edge cases.
@Suite("WorkspaceReference helpers")
struct WorkspaceReferenceHelperTests {

    @Test("withTools returns a copy with new tools, preserving other fields")
    func withToolsPreservesFields() {
        let original = WorkspaceReference(
            uri: .threadWorkspace(UUID()),
            location: .runtime,
            rootPath: "/tmp",
            trustLevel: .full
        )
        let tools: [ToolReference] = [.known("read_file"), .known("list_dir")]
        let copy = original.withTools(tools)

        #expect(copy.id == original.id)
        #expect(copy.uri == original.uri)
        #expect(copy.location == original.location)
        #expect(copy.rootPath == original.rootPath)
        #expect(copy.tools.count == 2)
        #expect(copy.tools.map(\.toolID) == ["read_file", "list_dir"])
    }

    @Test("primaryForThread creates a runtime workspace with full trust")
    func primaryForThread() {
        let threadID = UUID()
        let ws = WorkspaceReference.makePrimary(forThread: threadID, rootPath: "/projects/x")

        #expect(ws.uri == .threadWorkspace(threadID))
        #expect(ws.location == .runtime)
        #expect(ws.rootPath == "/projects/x")
        #expect(ws.trustLevel == .full)
    }

    @Test("WorkspaceLocation decodes all known cases")
    func locationDecodes() throws {
        for raw in ["runtime", "runtimeThread", "attached"] {
            let json = "\"\(raw)\""
            let loc = try JSONDecoder().decode(WorkspaceReference.WorkspaceLocation.self, from: Data(json.utf8))
            #expect(loc.rawValue == raw)
        }
    }

    @Test("WorkspaceLocation throws for unknown raw value")
    func locationThrowsForUnknown() {
        let json = Data("\"unknown_location\"".utf8)
        do {
            _ = try JSONDecoder().decode(WorkspaceReference.WorkspaceLocation.self, from: json)
            Issue.record("Expected decoding to throw")
        } catch {
            // expected
        }
    }

    @Test("WorkspaceStatus decodes all cases")
    func statusDecodes() throws {
        for raw in ["active", "missing", "unknown"] {
            let json = "\"\(raw)\""
            let status = try JSONDecoder().decode(WorkspaceReference.WorkspaceStatus.self, from: Data(json.utf8))
            #expect(status.rawValue == raw)
        }
    }
}

/// Coverage for `ToolApprovalPolicy` concrete implementations.
@Suite("ToolApprovalPolicy")
struct ToolApprovalPolicyTests {

    @Test("DenyAllToolApprovalPolicy denies every call")
    func denyAllDenies() async {
        let policy = DenyAllToolApprovalPolicy()
        let tool = AnyTool(EchoTool())
        let decision = await policy.requestApproval(tool: tool, arguments: [:])
        #expect(decision == .deny)
    }

    @Test("AllowAllToolApprovalPolicy approves every call")
    func allowAllApproves() async {
        let policy = AllowAllToolApprovalPolicy()
        let tool = AnyTool(EchoTool())
        let decision = await policy.requestApproval(tool: tool, arguments: [:])
        #expect(decision == .approve)
    }
}

/// Coverage for `ToolParameterSchema` and `Schema.asDictionary` / `Schema(_:)`.
@Suite("ToolParameterSchema and Schema extensions")
struct ToolParameterSchemaExtensionTests {

    @Test("Schema.asDictionary round-trips a simple object schema")
    func asDictionaryRoundTrip() throws {
        let schema = ToolParameterSchema.object {
            JSONProperty(key: "name") {
                JSONString().description("A name")
            }
            .required()
        }.schemaDefinition

        let dict = schema.asDictionary
        #expect(dict["type"]?.asString == "object")
        #expect(dict["properties"]?.asDictionary?["name"]?.asDictionary?["type"]?.asString == "string")
    }

    @Test("Schema(_:) constructs from a dictionary")
    func schemaFromDictionary() throws {
        let dict: [String: AnyCodable] = [
            "type": .string("object"),
            "properties": .dictionary([:]),
        ]
        let schema = Schema(dict)
        let modelRoundIndexped = schema.asDictionary
        #expect(modelRoundIndexped["type"]?.asString == "object")
    }

    @Test("Schema(_:) falls back to empty object for invalid input")
    func schemaFromInvalidDictionary() {
        let dict: [String: AnyCodable] = [
            "type": .number(42),  // invalid type value
        ]
        let schema = Schema(dict)
        // Should not crash; falls back to a constructible schema.
        let result = schema.asDictionary
        #expect(!result.isEmpty)
    }
}

// MARK: - Test helpers

private struct EchoTool: Tool, Sendable {
    let callName = "echo"
    let name = "Echo"
    let description = "Echoes input"
    let requiresPermission = true
    var parametersSchema: Schema { ToolParameterSchema.object {}.schemaDefinition }
    func canExecute() async -> Bool { true }
    func execute(parameters: [String: AnyCodable]) async throws -> ToolResult {
        .success("ok")
    }
}
