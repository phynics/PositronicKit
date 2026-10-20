import Foundation
import JSONSchema
import PKContracts
import PKUtilities
@testable import PositronicKit
import Testing

/// A minimal executable tool for prompt-cache report fixtures.
private struct CacheReportTool: PKTool {
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
struct PromptCacheReportTests {
    private let agent = Agent(name: "Cache Report Agent", description: "", privateTimelineID: UUID())
    private let timeline = TimelineRecord(title: "Report Timeline")

    private func rendered(
        turn: Int,
        history: [Message],
        tools: [AnyTool],
        timelineTitle: String = "Report Timeline",
        systemInstructions: String = "Stable system rules"
    ) async throws -> RenderedPrompt {
        let request = LLMPromptRequest(
            userContent: MessageContent("turn \(turn) question"),
            contextContributions: [
                try TurnContextContribution(namespace: "host", key: "volatile", text: "dynamic-\(turn)"),
            ],
            chatHistory: history,
            tools: tools,
            workspaces: [],
            primaryWorkspace: nil,
            requestOriginName: nil,
            systemInstructions: systemInstructions
        )
        return try await PromptAssembler.assemble(
            request,
            agentContext: AgentContextSnapshot(agent: agent),
            timeline: TimelineRecord(id: timeline.id, title: timelineTitle)
        )
    }

    private func fingerprint(
        turn: Int,
        history: [Message],
        tools: [AnyTool]
    ) async throws -> TierFingerprint {
        TierFingerprint(prompt: try await rendered(turn: turn, history: history, tools: tools))
    }

    @Test("the first round reports firstRound and no reusable prefix")
    func firstRoundReportsFirstRound() async throws {
        let current = try await fingerprint(turn: 1, history: [], tools: [])
        let accounting = PromptCacheResetDetector.account(
            previous: nil,
            current: current,
            historyTrimmed: false,
            cachingEnabled: true
        )
        #expect(accounting.resets == [.firstRound])
        #expect(accounting.expectedReusableTokens == 0)
    }

    @Test("an unchanged prefix reports no reset and counts the identical prefix")
    func unchangedPrefixReportsNoReset() async throws {
        let history: [Message] = [
            Message(content: "older question", role: .user),
            Message(content: "older answer", role: .assistant),
        ]
        let tools = [AnyTool(CacheReportTool(callName: "alpha", name: "Alpha"))]
        // The volatile contribution changes every turn, but it renders after history.
        let previous = try await fingerprint(turn: 1, history: history, tools: tools)
        let current = try await fingerprint(turn: 2, history: history, tools: tools)

        let accounting = PromptCacheResetDetector.account(
            previous: previous,
            current: current,
            historyTrimmed: false,
            cachingEnabled: true
        )
        #expect(accounting.resets.isEmpty)
        #expect(accounting.expectedReusableTokens > 0)
    }

    @Test("a changed tool catalog reports toolsChanged")
    func toolsChangedReportsReset() async throws {
        let previous = try await fingerprint(
            turn: 1,
            history: [],
            tools: [AnyTool(CacheReportTool(callName: "alpha", name: "Alpha"))]
        )
        let current = try await fingerprint(
            turn: 1,
            history: [],
            tools: [AnyTool(CacheReportTool(callName: "beta", name: "Beta"))]
        )

        let accounting = PromptCacheResetDetector.account(
            previous: previous,
            current: current,
            historyTrimmed: false,
            cachingEnabled: true
        )
        #expect(accounting.resets.contains(.toolsChanged))
    }

    @Test("a trim reports historyTrim")
    func trimReportsHistoryTrim() async throws {
        let previous = try await fingerprint(turn: 1, history: [], tools: [])
        let current = try await fingerprint(turn: 1, history: [], tools: [])

        let accounting = PromptCacheResetDetector.account(
            previous: previous,
            current: current,
            historyTrimmed: true,
            cachingEnabled: true
        )
        #expect(accounting.resets == [.historyTrim])
    }

    @Test("a disabled policy reports cachingDisabled with no reusable prefix")
    func disabledReportsCachingDisabled() async throws {
        let current = try await fingerprint(turn: 1, history: [], tools: [])
        let accounting = PromptCacheResetDetector.account(
            previous: current,
            current: current,
            historyTrimmed: false,
            cachingEnabled: false
        )
        #expect(accounting.resets == [.cachingDisabled])
        #expect(accounting.expectedReusableTokens == 0)
    }

    @Test("a report round-trips through Codable")
    func reportRoundTrips() throws {
        let report = PromptCacheReport(
            turnID: UUID(),
            modelRoundIndex: 2,
            policy: .automatic(retention: .extended),
            breakpoints: [
                PromptCacheBreakpoint(messageIndex: 0, tier: .stableSystem, estimatedPrefixTokens: 10),
            ],
            expectedReusableTokens: 42,
            reportedCachedTokens: 30,
            reportedCacheWriteTokens: 12,
            resets: [.toolsChanged]
        )
        let data = try SerializationUtils.jsonEncoder.encode(report)
        let decoded = try SerializationUtils.jsonDecoder.decode(PromptCacheReport.self, from: data)
        #expect(decoded == report)
    }

    @Test("a prompt state snapshot exposes segments, tiers, and breakpoints")
    func promptStateSnapshotShape() async throws {
        let history: [Message] = [Message(content: "hi", role: .user)]
        let tools = [AnyTool(CacheReportTool(callName: "alpha", name: "Alpha"))]
        let prompt = try await rendered(turn: 1, history: history, tools: tools)
        let fingerprint = TierFingerprint(prompt: prompt)
        let breakpoints = PromptLayoutBuilder.build(from: prompt).cacheBreakpoints()

        let snapshot = PromptStateSnapshot(
            turnID: UUID(),
            modelRoundIndex: 1,
            fingerprint: fingerprint,
            breakpoints: breakpoints,
            resets: [.firstRound]
        )

        #expect(!snapshot.segments.isEmpty)
        #expect(snapshot.tiers.count == PromptCacheTier.allCases.count)
        #expect(snapshot.breakpoints == breakpoints)
        #expect(snapshot.resets == [.firstRound])
        // Stable segments fingerprint identically across a Timeline rename.
        let renamed = try await rendered(turn: 1, history: history, tools: tools, timelineTitle: "Renamed")
        let renamedFingerprint = TierFingerprint(prompt: renamed)
        #expect(
            fingerprint.fingerprint(for: .stable) == renamedFingerprint.fingerprint(for: .stable)
        )
    }
}
