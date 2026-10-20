import Foundation
import JSONSchema
import PKContracts
import PKUtilities
@testable import PositronicKit
import Testing

/// A minimal executable tool for layout fixtures.
private struct CacheTestTool: PKTool {
    let callName: String
    let name: String
    var toolDescription: String { "Tool \(callName)" }
    let requiresPermission = false
    let parametersSchema = makeEmptyObjectSchema()

    func canExecute() async -> Bool { true }

    func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
        .success("ok")
    }
}

@Suite(.tags(.unit))
struct PromptCacheLayoutTests {
    private let agent = Agent(name: "Cache Agent", description: "", privateTimelineID: UUID())
    private let timeline = TimelineRecord(title: "Stable Timeline")

    private func assembled(
        turn: Int,
        history: [Message],
        tools: [AnyTool],
        timelineTitle: String = "Stable Timeline",
        userContent: MessageContent? = nil
    ) async throws -> PromptWireLayout {
        let request = LLMPromptRequest(
            userContent: userContent ?? MessageContent("turn \(turn) question"),
            contextContributions: [
                try TurnContextContribution(namespace: "host", key: "volatile", text: "dynamic-\(turn)"),
            ],
            chatHistory: history,
            tools: tools,
            workspaces: [],
            primaryWorkspace: nil,
            requestOriginName: nil,
            systemInstructions: "Stable system rules"
        )
        let rendered = try await PromptAssembler.assemble(
            request,
            agentContext: AgentContextSnapshot(agent: agent),
            timeline: TimelineRecord(id: timeline.id, title: timelineTitle)
        )
        return PromptLayoutBuilder.build(from: rendered).wireLayout()
    }

    @Test("volatile context renders after history and before the query")
    func volatileAfterHistory() async throws {
        let wire = try await assembled(
            turn: 1,
            history: [
                Message(content: "older question", role: .user),
                Message(content: "older answer", role: .assistant),
            ],
            tools: [AnyTool(CacheTestTool(callName: "alpha", name: "Alpha"))]
        )

        // sys[0] stable, sys[1] semi-stable, history, sys[2] volatile, query
        #expect(wire.messages.map(\.role) == [.system, .system, .user, .assistant, .system, .user])
        #expect(wire.messages[0].content.contains("# System Instructions"))
        #expect(!wire.messages[0].content.contains("dynamic-1"))
        #expect(wire.messages[1].content.contains("Available tools"))
        #expect(!wire.messages[1].content.contains("dynamic-1"))
        #expect(wire.messages[4].content.contains("dynamic-1"))
        #expect(wire.messages[5].content == "turn 1 question")
    }

    @Test("an image-only query survives layout with its parts")
    func imageOnlyQuerySurvivesLayout() async throws {
        let image = ImageContent(data: Data([0x01, 0x02]), mediaType: "image/png", detail: .high, estimatedTokens: 42)
        let content = MessageContent(parts: [.image(image)])
        let wire = try await assembled(turn: 1, history: [], tools: [], userContent: content)

        #expect(wire.messages.last?.role == .user)
        #expect(wire.messages.last?.messageContent == content)
        #expect(wire.messages.last?.content.isEmpty == true)
    }

    @Test("an audio-only query survives layout with its parts")
    func audioOnlyQuerySurvivesLayout() async throws {
        let audio = AudioContent(data: Data([0x03, 0x04]), format: .wav)
        let content = MessageContent(parts: [.audio(audio)])
        let wire = try await assembled(turn: 1, history: [], tools: [], userContent: content)

        #expect(wire.messages.last?.role == .user)
        #expect(wire.messages.last?.messageContent == content)
    }

    @Test("a mixed query keeps text and media parts in order")
    func mixedQueryPreservesPartOrder() async throws {
        let image = ImageContent(data: Data([0x05]), mediaType: "image/png")
        let content = MessageContent(parts: [.text("look "), .image(image), .text("now")])
        let wire = try await assembled(turn: 1, history: [], tools: [], userContent: content)

        #expect(wire.messages.last?.messageContent.parts == content.parts)
        #expect(wire.messages.last?.content == "look now")
    }

    @Test("empty text-only and empty-part query segments stay dropped")
    func emptyQuerySegmentsAreDropped() {
        func layout(_ content: MessageContent) -> PromptLayout {
            PromptLayout(
                segments: [
                    LayoutSegment(
                        id: "user_query",
                        role: .userQuery,
                        tier: .query,
                        content: .text(content),
                        estimatedTokens: content.estimatedTokens
                    ),
                ],
                string: "",
                sectionsByID: [:]
            )
        }

        #expect(layout(MessageContent(parts: [.text("")])).renderMessages().isEmpty)
        #expect(layout(MessageContent(parts: [])).renderMessages().isEmpty)
        #expect(layout(MessageContent(parts: [.text("")])).renderTimelineMessages().isEmpty)
    }

    @Test("breakpoints land on tier boundaries and never exceed four")
    func breakpointsLandOnTiers() async throws {
        let wire = try await assembled(
            turn: 1,
            history: [
                Message(content: "older question", role: .user),
                Message(content: "older answer", role: .assistant),
            ],
            tools: [AnyTool(CacheTestTool(callName: "alpha", name: "Alpha"))]
        )

        #expect(wire.breakpoints.map(\.tier) == [.stableSystem, .semiStableSystem, .history])
        #expect(wire.breakpoints.count <= 4)
        #expect(wire.breakpoints[0].messageIndex == 0)
        #expect(wire.breakpoints[1].messageIndex == 1)
        #expect(wire.breakpoints[2].messageIndex == 3)
        // Prefix estimates increase as the tier grows.
        #expect(wire.breakpoints[0].estimatedPrefixTokens < wire.breakpoints[1].estimatedPrefixTokens)
        #expect(wire.breakpoints[1].estimatedPrefixTokens < wire.breakpoints[2].estimatedPrefixTokens)
    }

    @Test("the golden five-turn fixture keeps a byte-identical prefix through the prior history")
    func goldenWirePrefixIsStable() async throws {
        let tools = [AnyTool(CacheTestTool(callName: "alpha", name: "Alpha"))]
        var history: [Message] = [
            Message(content: "seed question", role: .user),
            Message(content: "seed answer", role: .assistant),
        ]
        var priorMessages: [LLMMessage] = []
        var priorHistoryBreakpoint: Int?

        for turn in 1 ... 5 {
            let wire = try await assembled(turn: turn, history: history, tools: tools)
            let historyBreakpoint = wire.breakpoints.first(where: { $0.tier == .history })?.messageIndex

            if turn > 1, let priorHistoryBreakpoint {
                let sharedPrefixLength = priorHistoryBreakpoint + 1
                #expect(Array(wire.messages.prefix(sharedPrefixLength)) == Array(priorMessages.prefix(sharedPrefixLength)))
                // The volatile contribution changes every Turn, yet the stable tier never does.
                if let priorFirst = priorMessages.first {
                    #expect(wire.messages[0] == priorFirst)
                }
            }

            priorMessages = wire.messages
            priorHistoryBreakpoint = historyBreakpoint

            // Advance the durable history with this Turn's query and a deterministic reply.
            history.append(Message(content: "turn \(turn) question", role: .user))
            history.append(Message(content: "answer \(turn)", role: .assistant))
        }
    }

    @Test("renaming a Timeline leaves the stable system message byte-identical")
    func renameKeepsStableTier() async throws {
        let before = try await assembled(turn: 1, history: [], tools: [], timelineTitle: "Original Title")
        let after = try await assembled(turn: 1, history: [], tools: [], timelineTitle: "Renamed Title")

        #expect(before.messages.first == after.messages.first)
        // The title still appears, but only in the semi-stable Timeline context.
        #expect(after.messages.contains { $0.role == .system && $0.content.contains("Renamed Title") })
    }

    @Test("the tool-loop breakpoint is added on round two and points at the last message")
    func toolLoopBreakpoint() async throws {
        let breakpoints = [
            PromptCacheBreakpoint(messageIndex: 0, tier: .stableSystem, estimatedPrefixTokens: 10),
            PromptCacheBreakpoint(messageIndex: 1, tier: .semiStableSystem, estimatedPrefixTokens: 20),
            PromptCacheBreakpoint(messageIndex: 2, tier: .history, estimatedPrefixTokens: 30),
        ]
        let messages = [
            LLMMessage(role: .system, content: "stable"),
            LLMMessage(role: .system, content: "semi"),
            LLMMessage(role: .user, content: "query"),
            LLMMessage(role: .assistant, content: "call"),
            LLMMessage(role: .tool, content: "result"),
        ]

        func context(round: Int) -> TurnContext {
            TurnContext(
                timelineID: UUID(),
                agentId: nil,
                modelName: "test-model",
                maxModelRounds: 5,
                systemInstructions: nil,
                availableTools: [],
                remoteDepth: 0,
                currentMessages: messages,
                modelRoundIndex: round,
                promptCacheBreakpoints: breakpoints,
                promptCaching: .automatic()
            )
        }

        let roundOne = try #require(LLMStreamingStage.promptCacheDirective(for: context(round: 1)))
        #expect(roundOne.breakpoints.map(\.tier) == [.stableSystem, .semiStableSystem, .history])

        let roundTwo = try #require(LLMStreamingStage.promptCacheDirective(for: context(round: 2)))
        #expect(roundTwo.breakpoints.count <= 4)
        #expect(roundTwo.breakpoints.last?.tier == .toolLoop)
        #expect(roundTwo.breakpoints.last?.messageIndex == messages.count - 1)
    }

    @Test("WorkspacesContext renders tools and workspaces in deterministic order")
    func workspacesContextDeterministic() async throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let first = WorkspaceReference(
            id: firstID,
            uri: WorkspaceURI(host: "test", path: "/b"),
            location: .attached,
            tools: [.known(id: "zebra"), .known(id: "alpha")]
        )
        let second = WorkspaceReference(
            id: secondID,
            uri: WorkspaceURI(host: "test", path: "/a"),
            location: .attached,
            tools: [.known(id: "beta")]
        )

        let forward = try await WorkspacesContext(workspaces: [first, second], primaryWorkspace: nil, requestOriginName: nil).renderToString()
        let reverse = try await WorkspacesContext(workspaces: [second, first], primaryWorkspace: nil, requestOriginName: nil).renderToString()
        #expect(forward == reverse)
        let output = try #require(forward)
        let alpha = try #require(output.range(of: "`alpha`"))
        let zebra = try #require(output.range(of: "`zebra`"))
        #expect(alpha.lowerBound < zebra.lowerBound)
    }

    @Test("reloaded tool history keeps assistant calls adjacent to their paired results")
    func reloadedToolHistoryKeepsCallResultPairing() async throws {
        let history: [Message] = [
            Message(content: "first question", role: .user),
            Message(
                content: "working",
                role: .assistant,
                toolCalls: [
                    ToolCall(id: "call_a", name: "alpha", arguments: [:]),
                    ToolCall(id: "call_b", name: "alpha", arguments: [:]),
                ]
            ),
            Message(content: "result a", role: .tool, toolCallID: "call_a"),
            Message(content: "result b", role: .tool, toolCallID: "call_b"),
            Message(content: "done", role: .assistant),
            Message(content: "follow-up question", role: .user),
        ]
        let wire = try await assembled(
            turn: 2,
            history: history,
            tools: [AnyTool(CacheTestTool(callName: "alpha", name: "Alpha"))]
        )

        let messages = wire.messages
        let assistantIndex = try #require(messages.firstIndex(where: {
            $0.role == .assistant && !($0.toolCalls ?? []).isEmpty
        }))
        // Multiple-call ordering is preserved on the assistant message.
        #expect(messages[assistantIndex].toolCalls?.map(\.id) == ["call_a", "call_b"])
        // Each tool result stays adjacent to its call with the matching call ID.
        #expect(messages[assistantIndex + 1].role == .tool)
        #expect(messages[assistantIndex + 1].toolCallID == "call_a")
        #expect(messages[assistantIndex + 1].content == "result a")
        #expect(messages[assistantIndex + 2].role == .tool)
        #expect(messages[assistantIndex + 2].toolCallID == "call_b")
        #expect(messages[assistantIndex + 2].content == "result b")
        // Genuine user messages keep the user role, and no tool result falls back to the
        // legacy wrapper.
        #expect(messages.contains(where: { $0.role == .user && $0.content == "follow-up question" }))
        #expect(!messages.contains(where: { $0.content.contains("<tool_response>") }))
        // The provider-facing history is protocol-valid: every tool message carries its ID.
        try validateLLMMessageHistory(messages)
    }

    @Test("crossing the history budget trims once and the next three Turns keep the new prefix")
    func stepwiseTrimKeepsPrefix() {
        let base = (0 ..< 5).map { index in
            Message(content: "message-\(index) " + String(repeating: "x", count: 800), role: .user)
        }
        let budget = 200

        let first = PromptHistoryOptimizer.stepwise(base, availableTokens: budget, state: HistoryTrimState())
        #expect(first.didTrim)
        #expect(PromptHistoryOptimizer.estimatedTokens(first.messages) <= Int(Double(budget) * 0.75))

        var state = first.state
        let trimmedPrefix = first.messages.map(\.content)
        for turn in 0 ..< 3 {
            let grown = base + [Message(content: "appended-\(turn)", role: .user)]
            let next = PromptHistoryOptimizer.stepwise(grown, availableTokens: budget, state: state)
            #expect(!next.didTrim)
            #expect(Array(next.messages.map(\.content).prefix(trimmedPrefix.count)) == trimmedPrefix)
            state = next.state
        }
    }
}
