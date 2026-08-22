import Foundation
import PKPrompt
import PKContracts
import PKUtilities
@testable import PositronicKit
import Testing

@MainActor
struct PromptIntegrationTests {
    @Test("testEmptyUserQueryDoesNotAppendMessage")
    func emptyUserQueryDoesNotAppendMessage() async throws {
        let history = [Message(content: "Hello", role: .user)]

        let prompt = try await PromptAssembler.assemble(
            LLMPromptRequest(
                userQuery: "",
                chatHistory: history,
                tools: [],
                workspaces: [],
                primaryWorkspace: nil,
                requestOriginName: nil,
                systemInstructions: nil
            )
        )
        let messages = prompt.buildMessages()

        let userMessages = messages.filter { $0.role == .user }

        // Should only contain the one from history (mapped as user)
        #expect(userMessages.count == 1)

        if let first = userMessages.first {
            let content = first.content
            #expect(content == "Hello")
        }
    }

    @Test("testNonEmptyUserQueryAppendsMessage")
    func nonEmptyUserQueryAppendsMessage() async throws {
        let history = [Message(content: "Hello", role: .user)]

        let prompt = try await PromptAssembler.assemble(
            LLMPromptRequest(
                userQuery: "World",
                chatHistory: history,
                tools: [],
                workspaces: [],
                primaryWorkspace: nil,
                requestOriginName: nil,
                systemInstructions: nil
            )
        )
        let messages = prompt.buildMessages()

        let userMessages = messages.filter { $0.role == .user }

        #expect(userMessages.count == 2)
    }

    // MARK: - Workspace Section

    @Test("workspaceSectionOmitsConnectionStatus")
    func workspaceSectionOmitsConnectionStatus() async throws {
        let uri = WorkspaceURI(host: "test-host", path: "/projects/test")
        let activeWS = WorkspaceReference(uri: uri, location: .attached, status: .active)
        let missingWS = WorkspaceReference(uri: uri, location: .attached, status: .missing)

        let sectionActive = WorkspacesContext(
            workspaces: [activeWS], primaryWorkspace: nil, requestOriginName: nil
        )
        let sectionMissing = WorkspacesContext(
            workspaces: [missingWS], primaryWorkspace: nil, requestOriginName: nil
        )

        let outputActive = try await sectionActive.renderToString() ?? ""
        let outputMissing = try await sectionMissing.renderToString() ?? ""

        #expect(!outputActive.contains("Connected"), "Active workspace should not show connection status")
        #expect(!outputActive.contains("Disconnected"), "Active workspace should not show connection status")
        #expect(!outputMissing.contains("Connected"), "Missing workspace should not show connection status")
        #expect(!outputMissing.contains("Disconnected"), "Missing workspace should not show connection status")
        #expect(outputActive.contains("Available Workspaces"), "Workspace section should still render")
    }

    @Test("userQueryPreventsLeakageIntoSystem")
    func userQueryPreventsLeakageIntoSystem() async throws {
        let history = [Message(content: "Hi", role: .user)]
        let query = "UNIQUE_QUERY_STRING"

        let prompt = try await PromptAssembler.assemble(
            LLMPromptRequest(
                userQuery: query,
                chatHistory: history,
                tools: [],
                workspaces: [],
                primaryWorkspace: nil,
                requestOriginName: nil,
                systemInstructions: nil
            )
        )
        let messages = prompt.buildMessages()

        guard let firstMsg = messages.first, firstMsg.role == .system else {
            // If no system message (empty instructions), then leakage is impossible in system message
            return
        }
        let systemContent = firstMsg.content

        #expect(!systemContent.contains(query), "User query content leaked into system prompt")
    }

}
