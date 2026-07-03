import Foundation
import PKPrompt
import PKShared
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

        guard let firstMsg = messages.first, firstMsg.role == .system else {
            // If no system message (empty instructions), then leakage is impossible in system message
            return
        }
        let systemContent = firstMsg.content

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

        if let first = messages.first, first.role == .system {
            let systemContent = first.content
            #expect(systemContent.contains("System rules"))
            #expect(systemContent.contains("Context note"))
            // Context sections must be below system instructions and labeled.
            #expect(systemContent.contains("=== Retrieved Context ==="))
            let systemRulesOffset = systemContent.range(of: "System rules")?.lowerBound
            let contextHeaderOffset = systemContent.range(of: "=== Retrieved Context ===")?.lowerBound
            if let sys = systemRulesOffset, let ctx = contextHeaderOffset {
                #expect(sys < ctx, "System rules must appear before Retrieved Context header")
            }
        } else {
            #expect(Bool(false), "First message should be a system message")
        }

        if let last = messages.last, last.role == .user {
            let userContent = last.content
            #expect(userContent == "Current question")
        } else {
            #expect(Bool(false), "Last message should be a user query")
        }
    }

    @Test("context sections are labeled and placed after system instructions")
    func contextSectionsAreLabeledBelowSystemInstructions() async throws {
        let prompt = try await PromptAssembler.assemble(
            LLMPromptRequest(
                userQuery: "Hello",
                contextNotes: [ContextFile(name: "Memory", content: "Retrieved note", source: "memory")],
                memories: [],
                chatHistory: [],
                tools: [],
                workspaces: [],
                primaryWorkspace: nil,
                requestOriginName: nil,
                systemInstructions: "Root instructions"
            )
        )
        let messages = prompt.buildMessages()
        let systemMessage = messages.first { $0.role == .system }
        let content = try #require(systemMessage?.content)

        // Context must be labeled, not silently elevated to system authority.
        #expect(content.contains("=== Retrieved Context ==="))
        #expect(content.contains("Retrieved note"))
        // System instructions come first.
        let instructionsOffset = content.range(of: "Root instructions")?.lowerBound
        let contextOffset = content.range(of: "=== Retrieved Context ===")?.lowerBound
        if let i = instructionsOffset, let c = contextOffset {
            #expect(i < c)
        }
    }

    @Test("context-only prompt (no system instructions) still labels retrieved content")
    func contextOnlyPromptLabelsRetrievedContent() async throws {
        let prompt = try await PromptAssembler.assemble(
            LLMPromptRequest(
                userQuery: "Hello",
                contextNotes: [ContextFile(name: "Note", content: "Only context", source: "note")],
                memories: [],
                chatHistory: [],
                tools: [],
                workspaces: [],
                primaryWorkspace: nil,
                requestOriginName: nil,
                systemInstructions: nil
            )
        )
        let messages = prompt.buildMessages()
        let systemMessage = messages.first { $0.role == .system }
        let content = try #require(systemMessage?.content)
        #expect(content.contains("=== Retrieved Context ==="))
        #expect(content.contains("Only context"))
    }
}
