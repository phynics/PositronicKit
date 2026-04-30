import Foundation
import PositronicKit
import PKPrompt
import PKShared
import OpenAI
import Testing

@MainActor
struct PromptIntegrationTests {
    @Test("testEmptyUserQueryDoesNotAppendMessage")
    func emptyUserQueryDoesNotAppendMessage() async throws {
        let history = [Message(content: "Hello", role: .user)]

        let prompt = try await PromptAssembler.assemble(
            LLMPromptRequest(
                userQuery: "",
                contextNotes: [],
                memories: [],
                chatHistory: history,
                tools: [],
                workspaces: [],
                primaryWorkspace: nil,
                requestOriginName: nil,
                systemInstructions: nil
            )
        )
        let messages = prompt.buildMessages()

        let userMessages = messages.filter {
            if case .user = $0 { return true }
            return false
        }

        // Should only contain the one from history (mapped as user)
        #expect(userMessages.count == 1)

        if let first = userMessages.first, case let .user(params) = first,
           case let .string(content) = params.content
        {
            #expect(content == "Hello")
        }
    }

    @Test("testNonEmptyUserQueryAppendsMessage")
    func nonEmptyUserQueryAppendsMessage() async throws {
        let history = [Message(content: "Hello", role: .user)]

        let prompt = try await PromptAssembler.assemble(
            LLMPromptRequest(
                userQuery: "World",
                contextNotes: [],
                memories: [],
                chatHistory: history,
                tools: [],
                workspaces: [],
                primaryWorkspace: nil,
                requestOriginName: nil,
                systemInstructions: nil
            )
        )
        let messages = prompt.buildMessages()

        let userMessages = messages.filter {
            if case .user = $0 { return true }
            return false
        }

        #expect(userMessages.count == 2)
    }

    // MARK: - Workspace Section

    @Test("workspaceSectionOmitsConnectionStatus")
    func workspaceSectionOmitsConnectionStatus() async {
        let uri = WorkspaceURI(host: "test-host", path: "/projects/test")
        let activeWS = WorkspaceReference(uri: uri, location: .attached, status: .active)
        let missingWS = WorkspaceReference(uri: uri, location: .attached, status: .missing)

        let sectionActive = WorkspacesContext(
            workspaces: [activeWS], primaryWorkspace: nil, requestOriginName: nil
        )
        let sectionMissing = WorkspacesContext(
            workspaces: [missingWS], primaryWorkspace: nil, requestOriginName: nil
        )

        let outputActive = await sectionActive.renderToString() ?? ""
        let outputMissing = await sectionMissing.renderToString() ?? ""

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
                contextNotes: [],
                memories: [],
                chatHistory: history,
                tools: [],
                workspaces: [],
                primaryWorkspace: nil,
                requestOriginName: nil,
                systemInstructions: nil
            )
        )
        let messages = prompt.buildMessages()

        guard let firstMsg = messages.first,
              case let .system(systemParam) = firstMsg,
              case let .textContent(systemContent) = systemParam.content
        else {
            // If no system message (empty instructions), then leakage is impossible in system message
            return
        }

        #expect(!systemContent.contains(query), "User query content leaked into system prompt")
    }

    @Test("partial preRendered content still produces system and user messages")
    func partialPreRenderedContentStillBuildsMessages() async throws {
        let prompt = try await PromptAssembler.assemble(
            LLMPromptRequest(
                userQuery: "Current question",
                contextNotes: [ContextFile(name: "Note", content: "Context note", source: "note")],
                memories: [],
                chatHistory: [],
                tools: [],
                workspaces: [],
                primaryWorkspace: nil,
                requestOriginName: nil,
                systemInstructions: "System rules"
            )
        )

        let messages = prompt.buildMessages()

        #expect(messages.count == 2)

        if let first = messages.first,
           case let .system(systemParam) = first,
           case let .textContent(systemContent) = systemParam.content
        {
            #expect(systemContent.contains("System rules"))
            #expect(systemContent.contains("Context note"))
        } else {
            #expect(Bool(false), "First message should be a system message")
        }

        if let last = messages.last,
           case let .user(userParam) = last,
           case let .string(userContent) = userParam.content
        {
            #expect(userContent == "Current question")
        } else {
            #expect(Bool(false), "Last message should be a user query")
        }
    }
}
