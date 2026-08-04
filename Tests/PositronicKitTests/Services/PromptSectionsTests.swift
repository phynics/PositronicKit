import Foundation
import PKShared
import PKUtilities
@testable import PositronicKit
import Testing

// MARK: - Helpers

private func makeURI(_ path: String = "/projects/test", host: String = "test-host") -> WorkspaceURI {
    WorkspaceURI(host: host, path: path)
}

private func makeAttachedWS(
    tools: [ToolReference] = [],
    status: WorkspaceReference.WorkspaceStatus = .active,
    contextInjection: String? = nil,
    originId: UUID? = nil
) -> WorkspaceReference {
    WorkspaceReference(
        uri: makeURI(),
        location: .attached,
        originId: originId,
        tools: tools,
        status: status,
        contextInjection: contextInjection
    )
}

private func makeRuntimeWS(
    tools: [ToolReference] = [],
    contextInjection: String? = nil
) -> WorkspaceReference {
    WorkspaceReference(
        uri: makeURI("/agent/workspace", host: "runtime"),
        location: .runtime,
        tools: tools,
        contextInjection: contextInjection
    )
}

private func makeAgent(name: String = "TestAgent", description: String = "") -> AgentInstance {
    AgentInstance(name: name, description: description, privateTimelineID: UUID())
}

// MARK: - WorkspacesContext Tests

struct WorkspacesContextTests {
    // MARK: Empty / Nil cases

    @Test("renders nil when no workspaces and no request origin name")
    func nilWhenEmpty() async throws {
        let section = WorkspacesContext(workspaces: [], primaryWorkspace: nil, requestOriginName: nil)
        let output = try await section.renderToString()
        #expect(output == nil)
    }

    @Test("renders request origin name only when workspaces list is empty")
    func requestOriginNameOnlyWhenNoWorkspaces() async throws {
        let section = WorkspacesContext(workspaces: [], primaryWorkspace: nil, requestOriginName: "Alice")
        let output = try await section.renderToString() ?? ""
        #expect(output.contains("Alice"))
        #expect(!output.contains("Available Workspaces"))
    }

    // MARK: Connection status (regression)

    @Test("active attached workspace omits connection status")
    func activeClientOmitsStatus() async throws {
        let section = WorkspacesContext(
            workspaces: [makeAttachedWS(status: .active)],
            primaryWorkspace: nil,
            requestOriginName: nil
        )
        let output = try await section.renderToString() ?? ""
        #expect(!output.contains("Connected"))
        #expect(!output.contains("Disconnected"))
    }

    @Test("missing attached workspace omits connection status")
    func missingClientOmitsStatus() async throws {
        let section = WorkspacesContext(
            workspaces: [makeAttachedWS(status: .missing)],
            primaryWorkspace: nil,
            requestOriginName: nil
        )
        let output = try await section.renderToString() ?? ""
        #expect(!output.contains("Connected"))
        #expect(!output.contains("Disconnected"))
    }

    @Test("unknown status workspace omits connection status")
    func unknownStatusOmitsStatus() async throws {
        let section = WorkspacesContext(
            workspaces: [makeAttachedWS(status: .unknown)],
            primaryWorkspace: nil,
            requestOriginName: nil
        )
        let output = try await section.renderToString() ?? ""
        #expect(!output.contains("Connected"))
        #expect(!output.contains("Disconnected"))
    }

    // MARK: Environment labels

    @Test("workspace section uses neutral workspace wording")
    func workspaceSectionUsesNeutralWording() async throws {
        let section = WorkspacesContext(
            workspaces: [makeAttachedWS()],
            primaryWorkspace: nil,
            requestOriginName: nil
        )
        let output = try await section.renderToString() ?? ""
        #expect(output.contains("## Available Workspaces"))
        #expect(!output.contains("attached workspaces"))
        #expect(!output.contains("Environment: Attached"))
        #expect(!output.contains("Environment: Primary"))
    }

    // MARK: Deduplication

    @Test("primary not duplicated when also in workspaces list")
    func primaryNotDuplicated() async throws {
        let primary = makeRuntimeWS()
        let section = WorkspacesContext(
            workspaces: [primary],
            primaryWorkspace: primary,
            requestOriginName: nil
        )
        let output = try await section.renderToString() ?? ""
        // ID should appear exactly once in the output
        let count = output.components(separatedBy: primary.id.uuidString).count - 1
        #expect(count == 1, "Primary workspace ID should appear exactly once, found \(count)")
    }

    // MARK: Workspace metadata

    @Test("workspace ID and URI appear in output")
    func idAndURIPresent() async throws {
        let ws = makeAttachedWS()
        let section = WorkspacesContext(workspaces: [ws], primaryWorkspace: nil, requestOriginName: nil)
        let output = try await section.renderToString() ?? ""
        #expect(output.contains(ws.id.uuidString))
        #expect(output.contains(ws.uri.description))
    }

    @Test("request origin name shown at top of output")
    func requestOriginNameAtTop() async throws {
        let ws = makeAttachedWS()
        let section = WorkspacesContext(
            workspaces: [ws], primaryWorkspace: nil, requestOriginName: "Bob"
        )
        let output = try await section.renderToString() ?? ""
        #expect(output.hasPrefix("User Query Origin: **Bob**"))
    }

    @Test("multiple attached workspaces all appear in output")
    func multipleAttachedWorkspaces() async throws {
        let ws1 = makeAttachedWS()
        let ws2 = WorkspaceReference(
            uri: makeURI("/other/project"), location: .attached, status: .active
        )
        let section = WorkspacesContext(
            workspaces: [ws1, ws2], primaryWorkspace: nil, requestOriginName: nil
        )
        let output = try await section.renderToString() ?? ""
        #expect(output.contains(ws1.id.uuidString))
        #expect(output.contains(ws2.id.uuidString))
    }

    // MARK: Tools

    @Test("workspace with no tools shows 'None specific to this workspace'")
    func noToolsMessage() async throws {
        let section = WorkspacesContext(
            workspaces: [makeAttachedWS(tools: [])],
            primaryWorkspace: nil,
            requestOriginName: nil
        )
        let output = try await section.renderToString() ?? ""
        #expect(output.contains("None specific to this workspace"))
    }

    @Test("workspace with known tools lists tool IDs")
    func knownToolsListed() async throws {
        let tools: [ToolReference] = [.known(id: "cat"), .known(id: "ls"), .known(id: "grep")]
        let section = WorkspacesContext(
            workspaces: [makeAttachedWS(tools: tools)],
            primaryWorkspace: nil,
            requestOriginName: nil
        )
        let output = try await section.renderToString() ?? ""
        #expect(output.contains("`cat`"))
        #expect(output.contains("`ls`"))
        #expect(output.contains("`grep`"))
        #expect(!output.contains("None specific to this workspace"))
    }

    @Test("custom tool with context injection shows instructions")
    func customToolContextInjection() async throws {
        let def = WorkspaceToolDefinition(
            id: "my_tool",
            name: "My Tool",
            description: "Does things",
            contextInjection: "Always call this first."
        )
        let tools: [ToolReference] = [.custom(def)]
        let section = WorkspacesContext(
            workspaces: [makeAttachedWS(tools: tools)],
            primaryWorkspace: nil,
            requestOriginName: nil
        )
        let output = try await section.renderToString() ?? ""
        #expect(output.contains("`my_tool`"))
        #expect(output.contains("Always call this first."))
    }

    @Test("custom tool without context injection does not show Instructions line")
    func customToolNoContextInjection() async throws {
        let def = WorkspaceToolDefinition(
            id: "silent_tool", name: "Silent", description: "Quiet"
        )
        let section = WorkspacesContext(
            workspaces: [makeAttachedWS(tools: [.custom(def)])],
            primaryWorkspace: nil,
            requestOriginName: nil
        )
        let output = try await section.renderToString() ?? ""
        #expect(output.contains("`silent_tool`"))
        #expect(!output.contains("Instructions:"))
    }

    // MARK: Workspace-level context injection

    @Test("workspace context injection appears in output")
    func workspaceContextInjection() async throws {
        let ws = makeAttachedWS(contextInjection: "This workspace is the main project repo.")
        let section = WorkspacesContext(workspaces: [ws], primaryWorkspace: nil, requestOriginName: nil)
        let output = try await section.renderToString() ?? ""
        #expect(output.contains("Workspace Instructions: This workspace is the main project repo."))
    }

    @Test("workspace without context injection shows no Workspace Instructions line")
    func noWorkspaceContextInjection() async throws {
        let ws = makeAttachedWS(contextInjection: nil)
        let section = WorkspacesContext(workspaces: [ws], primaryWorkspace: nil, requestOriginName: nil)
        let output = try await section.renderToString() ?? ""
        #expect(!output.contains("Workspace Instructions:"))
    }

    // MARK: Footer

    @Test("output ends with the lean workspace routing rules")
    func footerPresent() async throws {
        let section = WorkspacesContext(
            workspaces: [makeAttachedWS()], primaryWorkspace: nil, requestOriginName: nil
        )
        let output = try await section.renderToString() ?? ""
        #expect(output.hasSuffix(
            "2. Treat workspace-tagged tools as already bound to their labeled workspace; do not add workspace ids to tool arguments.\n"
        ))
    }
}

// MARK: - SystemInstructions Tests

struct SystemInstructionsTests {
    @Test("empty instructions renders nil")
    func emptyRendersNil() async throws {
        let output = try await SystemInstructions("").renderToString()
        #expect(output == nil)
    }

    @Test("non-empty instructions wraps with header")
    func nonEmptyRendersWithHeader() async throws {
        let output = try await SystemInstructions("Be helpful.").renderToString() ?? ""
        #expect(output.contains("# System Instructions"))
        #expect(output.contains("Be helpful."))
    }

    @Test("multiline instructions preserved")
    func multilinePreserved() async throws {
        let instructions = "Line one.\nLine two.\nLine three."
        let output = try await SystemInstructions(instructions).renderToString() ?? ""
        #expect(output.contains("Line one."))
        #expect(output.contains("Line two."))
        #expect(output.contains("Line three."))
    }
}

// MARK: - AgentContext Tests

struct AgentContextTests {
    @Test("contains identity header and agent name")
    func headerAndName() async throws {
        let output = try await AgentContext(makeAgent(name: "Aria")).renderToString() ?? ""
        #expect(output.contains("## Your Identity"))
        #expect(output.contains("**Aria**"))
    }

    @Test("agent with description includes description line")
    func withDescription() async throws {
        let output = try await AgentContext(makeAgent(description: "A code reviewer")).renderToString() ?? ""
        #expect(output.contains("A code reviewer"))
    }

    @Test("agent without description omits description line")
    func withoutDescription() async throws {
        let output = try await AgentContext(makeAgent(description: "")).renderToString() ?? ""
        #expect(!output.contains("Description:"))
    }

    @Test("timeline title included when provided")
    func withTimelineTitle() async throws {
        let output = try await AgentContext(makeAgent(), timelineTitle: "Sprint Planning").renderToString() ?? ""
        #expect(output.contains("Sprint Planning"))
    }

    @Test("no timeline line when title is nil")
    func noTimelineTitle() async throws {
        let output = try await AgentContext(makeAgent(), timelineTitle: nil).renderToString() ?? ""
        #expect(!output.contains("operating on timeline"))
    }

    @Test("always mentions private workspace and Notes directory")
    func mentionsNotes() async throws {
        let output = try await AgentContext(makeAgent()).renderToString() ?? ""
        #expect(output.contains("Notes/"))
        #expect(output.contains("private workspace"))
    }
}

// MARK: - TimelineContext Tests

struct TimelineContextTests {
    @Test("contains timeline ID and title")
    func idAndTitle() async throws {
        let timeline = Timeline(title: "My Project")
        let output = try await TimelineContext(timeline).renderToString() ?? ""
        #expect(output.contains(timeline.id.uuidString))
        #expect(output.contains("My Project"))
    }

    @Test("default title used when no custom title")
    func defaultTitle() async throws {
        let timeline = Timeline()
        let output = try await TimelineContext(timeline).renderToString() ?? ""
        #expect(output.contains("New Conversation"))
    }

    @Test("contains Current Timeline header")
    func header() async throws {
        let output = try await TimelineContext(Timeline()).renderToString() ?? ""
        #expect(output.contains("## Current Timeline"))
    }
}
