import Foundation
@testable import PKContracts
import Testing

/// PKRR-004: `ToolSideEffects` is a public type on `PKContracts` with a `.mutating` default.
/// Tools that do not declare `sideEffects` inherit the conservative `.mutating` assumption
/// so the timeout enforcer reports `timedOutButMayStillBeRunning` rather than a clean
/// timeout. `AnyTool` forwards the declared value so type erasure preserves the
/// side-effect class captured at erasure time.
@Suite("ToolSideEffects")
struct ToolSideEffectsTests {
    /// A tool that does not declare `sideEffects` — must default to `.mutating`.
    private struct UndeclaredTool: PKContracts.Tool {
        let callName = "undeclared"
        let name = "undeclared"
        let description = "does not declare sideEffects"
        let requiresPermission = false
        let parametersSchema = makeEmptyObjectSchema()

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            .success("ok")
        }
    }

    private struct NoneTool: PKContracts.Tool {
        let callName = "none_tool"
        let name = "none_tool"
        let description = "declares .none"
        let requiresPermission = false
        let sideEffects: ToolSideEffects = .none
        let parametersSchema = makeEmptyObjectSchema()

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            .success("ok")
        }
    }

    private struct ExternalProcessTool: PKContracts.Tool {
        let callName = "external_tool"
        let name = "external_tool"
        let description = "declares .externalProcess"
        let requiresPermission = false
        let sideEffects: ToolSideEffects = .externalProcess
        let parametersSchema = makeEmptyObjectSchema()

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            .success("ok")
        }
    }

    @Test
    func undeclaredToolDefaultsToMutating() {
        // AC: `ToolSideEffects` is a public type on `PKContracts` with a `.mutating` default.
        let tool = UndeclaredTool()
        #expect(tool.sideEffects == .mutating)
    }

    @Test
    func declaredSideEffectsArePreserved() {
        #expect(NoneTool().sideEffects == .none)
        #expect(ExternalProcessTool().sideEffects == .externalProcess)
    }

    @Test
    func anyToolForwardsSideEffects() {
        // `AnyTool` must capture and forward `sideEffects` so type erasure does not erase
        // the side-effect class — the timeout enforcer reads it from the `AnyTool` it is
        // handed by `ToolRouter`.
        #expect(AnyTool(UndeclaredTool()).sideEffects == .mutating)
        #expect(AnyTool(NoneTool()).sideEffects == .none)
        #expect(AnyTool(ExternalProcessTool()).sideEffects == .externalProcess)
    }

    @Test
    func sideEffectsIsSendableAndEquatable() {
        // AC: typed case on the public surface — `ToolSideEffects` must be `Sendable` and
        // `Equatable` so it can be stored on `Sendable` tool types and compared in tests.
        let none: ToolSideEffects = .none
        let mutating: ToolSideEffects = .mutating
        let external: ToolSideEffects = .externalProcess
        #expect(none == .none)
        #expect(mutating == .mutating)
        #expect(external == .externalProcess)
        #expect(none != mutating)
        #expect(mutating != external)
    }
}
