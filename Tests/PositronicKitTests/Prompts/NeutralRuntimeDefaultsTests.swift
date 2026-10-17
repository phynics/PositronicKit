import Foundation
import PKContracts
import PKUtilities
@testable import PositronicKit
import Testing

/// Snapshots the runtime's neutral default prompt content (#288): the runtime contributes no
/// persona or guidance text of its own.
@Suite("Neutral runtime defaults", .tags(.unit))
struct NeutralRuntimeDefaultsTests {
    private func request(systemInstructions: String?) -> LLMPromptRequest {
        LLMPromptRequest(
            userQuery: "hello",
            chatHistory: [],
            tools: [],
            workspaces: [],
            primaryWorkspace: nil,
            requestOriginName: nil,
            systemInstructions: systemInstructions
        )
    }

    @Test("No host instructions leaves no runtime-authored stable system text")
    func emptyHostInstructionsLeaveStableTierEmpty() async throws {
        let rendered = try await PromptAssembler.assemble(request(systemInstructions: nil))

        #expect(rendered.sectionsByID["system"] == nil)
        #expect(!rendered.string.contains("PKRuntime"))
        #expect(!rendered.string.contains("intelligent developer assistant"))
        #expect(!rendered.string.contains("Core Directives"))
        #expect(!rendered.string.contains("## Core Directives"))
    }

    @Test("Host instructions are the only stable system text")
    func hostInstructionsAreTheOnlyStableSystemText() async throws {
        let rendered = try await PromptAssembler.assemble(request(systemInstructions: "Host rules"))

        let system = try #require(rendered.sectionsByID["system"])
        #expect(system.contains("Host rules"))
        #expect(!system.contains("PKRuntime"))
    }

    @Test("The layout omits the stable system message when the host provides no instructions")
    func layoutOmitsStableMessageWithoutHostInstructions() async throws {
        let rendered = try await PromptAssembler.assemble(request(systemInstructions: nil))
        let layout = PromptLayoutBuilder.build(from: rendered)

        #expect(layout.segments.allSatisfy { $0.id != "system" })
        #expect(layout.wireLayout().messages.first?.role != .system)
    }
}
