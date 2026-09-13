import Foundation
import struct JSONSchema.Schema
@testable import PKContracts
import Testing

/// Issue #160: exactly one erasure path (`AnyTool.init`) and exactly one
/// identity name (`identity`), with the LLM-facing text on `toolDescription`
/// so a tool can also conform to `CustomStringConvertible` without conflict.
struct ToolErasureTests {
    struct ErasureTool: PKContracts.PKTool, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
        let callName = "erasure_tool"
        let name = "Erasure Tool"
        let toolDescription = "A tool for testing erasure semantics"
        let requiresPermission = false
        var parametersSchema: Schema { ToolParameterSchema.object {}.schemaDefinition }

        func canExecute() async -> Bool { true }
        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult { .success("ok") }
    }

    /// A tool that is also `CustomStringConvertible`: this must compile without
    /// a naming workaround now that the LLM-facing text lives on `toolDescription`.
    struct DescribableTool: PKContracts.PKTool, CustomStringConvertible, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
        let callName = "describable_tool"
        let name = "Describable Tool"
        let toolDescription = "LLM-facing purpose"
        let requiresPermission = false
        var parametersSchema: Schema { ToolParameterSchema.object {}.schemaDefinition }

        var description: String { "debug: \(callName)" }

        func canExecute() async -> Bool { true }
        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult { .success("ok") }
    }

    @Test("re-erasing an AnyTool with global origin is a no-op preserving origin and identity")
    func reErasureIsNoOp() {
        let origin = ToolOrigin.workspace(id: UUID(), name: "NoOp")
        let erased = AnyTool(ErasureTool(), origin: origin)
        let reErased = AnyTool(erased)

        #expect(reErased.origin == origin)
        #expect(reErased.identity == erased.identity)
        #expect(reErased.callName == "erasure_tool")
    }

    @Test("re-erasing an AnyTool with an explicit origin applies the new origin")
    func reErasureWithExplicitOriginApplies() {
        let erased = AnyTool(ErasureTool())
        let reErased = AnyTool(erased, origin: .named("Override"))

        #expect(reErased.origin == .named("Override"))
        #expect(reErased.identity == erased.identity)
    }

    @Test("erasure captures identity once and exposes it as identity")
    func erasureCapturesIdentity() {
        let erased = AnyTool(ErasureTool())

        #expect(erased.identity == .known(id: "erasure_tool"))
    }

    @Test("toolDescription flows to prompt rendering, CustomStringConvertible stays separate")
    func toolDescriptionFlowsToPrompt() {
        let tool = DescribableTool()

        #expect(tool.promptString(origin: .global) == "- `describable_tool`: LLM-facing purpose")
        #expect(tool.description == "debug: describable_tool")
        #expect(String(describing: tool) == "debug: describable_tool")
    }
}
