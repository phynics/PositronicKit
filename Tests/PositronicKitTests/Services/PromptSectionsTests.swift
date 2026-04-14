import Foundation
import PositronicKit
import PKShared
import Testing

// MARK: - Helpers

private func makeURI(_ path: String = "/projects/test", host: String = "test-host") -> WorkspaceURI {
    WorkspaceURI(host: host, path: path)
}

private func makeClientWS(
    tools: [ToolReference] = [],
    status: WorkspaceReference.WorkspaceStatus = .active,
    contextInjection: String? = nil,
    ownerId: UUID? = nil
) -> WorkspaceReference {
    WorkspaceReference(
        uri: makeURI(),
        hostType: .client,
        ownerId: ownerId,
        tools: tools,
        status: status,
        contextInjection: contextInjection
    )
}

private func makeServerWS(
    tools: [ToolReference] = [],
    contextInjection: String? = nil
) -> WorkspaceReference {
    WorkspaceReference(
        uri: makeURI("/agent/workspace", host: "server"),
        hostType: .server,
        tools: tools,
        contextInjection: contextInjection
    )
}

private func makeAgent(name: String = "TestAgent", description: String = "") -> AgentInstance {
    AgentInstance(name: name, description: description, privateTimelineId: UUID())
}

// MARK: - WorkspacesContext Tests

struct WorkspacesContextTests {
    // MARK: Empty / Nil cases

    @Test("renders nil when no workspaces and no client name")
    func nilWhenEmpty() async {
        let section = WorkspacesContext(workspaces: [], primaryWorkspace: nil, clientName: nil)
        let output = await section.render()
        #expect(output == nil)
    }

    @Test("renders client name only when workspaces list is empty")
    func clientNameOnlyWhenNoWorkspaces() async {
        let section = WorkspacesContext(workspaces: [], primaryWorkspace: nil, clientName: "Alice")
        let output = await section.render() ?? ""
        #expect(output.contains("Alice"))
        #expect(!output.contains("Available Workspaces"))
    }

    // MARK: Connection status (regression)

    @Test("active client workspace omits connection status")
    func activeClientOmitsStatus() async {
        let section = WorkspacesContext(
            workspaces: [makeClientWS(status: .active)],
            primaryWorkspace: nil,
            clientName: nil
        )
        let output = await section.render() ?? ""
        #expect(!output.contains("Connected"))
        #expect(!output.contains("Disconnected"))
    }

    @Test("missing client workspace omits connection status")
    func missingClientOmitsStatus() async {
        let section = WorkspacesContext(
            workspaces: [makeClientWS(status: .missing)],
            primaryWorkspace: nil,
            clientName: nil
        )
        let output = await section.render() ?? ""
        #expect(!output.contains("Connected"))
        #expect(!output.contains("Disconnected"))
    }

    @Test("unknown status workspace omits connection status")
    func unknownStatusOmitsStatus() async {
        let section = WorkspacesContext(
            workspaces: [makeClientWS(status: .unknown)],
            primaryWorkspace: nil,
            clientName: nil
        )
        let output = await section.render() ?? ""
        #expect(!output.contains("Connected"))
        #expect(!output.contains("Disconnected"))
    }

    // MARK: Environment labels

    @Test("non-primary workspace shows Client label")
    func nonPrimaryShowsClientLabel() async {
        let section = WorkspacesContext(
            workspaces: [makeClientWS()],
            primaryWorkspace: nil,
            clientName: nil
        )
        let output = await section.render() ?? ""
        #expect(output.contains("Environment: Client"))
    }

    @Test("primary workspace shows Server (Primary) label")
    func primaryShowsServerPrimaryLabel() async {
        let primary = makeServerWS()
        let section = WorkspacesContext(
            workspaces: [],
            primaryWorkspace: primary,
            clientName: nil
        )
        let output = await section.render() ?? ""
        #expect(output.contains("Server (Primary)"))
        #expect(!output.contains("Client"))
    }

    @Test("primary + attached: primary labeled Server (Primary), attached labeled Client")
    func primaryAndAttachedLabels() async {
        let primary = makeServerWS()
        let attached = makeClientWS()
        let section = WorkspacesContext(
            workspaces: [attached],
            primaryWorkspace: primary,
            clientName: nil
        )
        let output = await section.render() ?? ""
        #expect(output.contains("Server (Primary)"))
        #expect(output.contains("Environment: Client"))
    }

    // MARK: Deduplication

    @Test("primary not duplicated when also in workspaces list")
    func primaryNotDuplicated() async {
        let primary = makeServerWS()
        let section = WorkspacesContext(
            workspaces: [primary],
            primaryWorkspace: primary,
            clientName: nil
        )
        let output = await section.render() ?? ""
        // ID should appear exactly once in the output
        let count = output.components(separatedBy: primary.id.uuidString).count - 1
        #expect(count == 1, "Primary workspace ID should appear exactly once, found \(count)")
    }

    // MARK: Workspace metadata

    @Test("workspace ID and URI appear in output")
    func idAndURIPresent() async {
        let ws = makeClientWS()
        let section = WorkspacesContext(workspaces: [ws], primaryWorkspace: nil, clientName: nil)
        let output = await section.render() ?? ""
        #expect(output.contains(ws.id.uuidString))
        #expect(output.contains(ws.uri.description))
    }

    @Test("client name shown at top of output")
    func clientNameAtTop() async {
        let ws = makeClientWS()
        let section = WorkspacesContext(
            workspaces: [ws], primaryWorkspace: nil, clientName: "Bob"
        )
        let output = await section.render() ?? ""
        #expect(output.hasPrefix("User Query Origin: **Bob**"))
    }

    @Test("multiple attached workspaces all appear in output")
    func multipleAttachedWorkspaces() async {
        let ws1 = makeClientWS()
        let ws2 = WorkspaceReference(
            uri: makeURI("/other/project"), hostType: .client, status: .active
        )
        let section = WorkspacesContext(
            workspaces: [ws1, ws2], primaryWorkspace: nil, clientName: nil
        )
        let output = await section.render() ?? ""
        #expect(output.contains(ws1.id.uuidString))
        #expect(output.contains(ws2.id.uuidString))
    }

    // MARK: Tools

    @Test("workspace with no tools shows 'None specific to this workspace'")
    func noToolsMessage() async {
        let section = WorkspacesContext(
            workspaces: [makeClientWS(tools: [])],
            primaryWorkspace: nil,
            clientName: nil
        )
        let output = await section.render() ?? ""
        #expect(output.contains("None specific to this workspace"))
    }

    @Test("workspace with known tools lists tool IDs")
    func knownToolsListed() async {
        let tools: [ToolReference] = [.known(id: "cat"), .known(id: "ls"), .known(id: "grep")]
        let section = WorkspacesContext(
            workspaces: [makeClientWS(tools: tools)],
            primaryWorkspace: nil,
            clientName: nil
        )
        let output = await section.render() ?? ""
        #expect(output.contains("`cat`"))
        #expect(output.contains("`ls`"))
        #expect(output.contains("`grep`"))
        #expect(!output.contains("None specific to this workspace"))
    }

    @Test("custom tool with context injection shows instructions")
    func customToolContextInjection() async {
        let def = WorkspaceToolDefinition(
            id: "my_tool",
            name: "My Tool",
            description: "Does things",
            contextInjection: "Always call this first."
        )
        let tools: [ToolReference] = [.custom(def)]
        let section = WorkspacesContext(
            workspaces: [makeClientWS(tools: tools)],
            primaryWorkspace: nil,
            clientName: nil
        )
        let output = await section.render() ?? ""
        #expect(output.contains("`my_tool`"))
        #expect(output.contains("Always call this first."))
    }

    @Test("custom tool without context injection does not show Instructions line")
    func customToolNoContextInjection() async {
        let def = WorkspaceToolDefinition(
            id: "silent_tool", name: "Silent", description: "Quiet"
        )
        let section = WorkspacesContext(
            workspaces: [makeClientWS(tools: [.custom(def)])],
            primaryWorkspace: nil,
            clientName: nil
        )
        let output = await section.render() ?? ""
        #expect(output.contains("`silent_tool`"))
        #expect(!output.contains("Instructions:"))
    }

    // MARK: Workspace-level context injection

    @Test("workspace context injection appears in output")
    func workspaceContextInjection() async {
        let ws = makeClientWS(contextInjection: "This workspace is the main project repo.")
        let section = WorkspacesContext(workspaces: [ws], primaryWorkspace: nil, clientName: nil)
        let output = await section.render() ?? ""
        #expect(output.contains("Workspace Instructions: This workspace is the main project repo."))
    }

    @Test("workspace without context injection shows no Workspace Instructions line")
    func noWorkspaceContextInjection() async {
        let ws = makeClientWS(contextInjection: nil)
        let section = WorkspacesContext(workspaces: [ws], primaryWorkspace: nil, clientName: nil)
        let output = await section.render() ?? ""
        #expect(!output.contains("Workspace Instructions:"))
    }

    // MARK: Footer

    @Test("output ends with usage guidance footer")
    func footerPresent() async {
        let section = WorkspacesContext(
            workspaces: [makeClientWS()], primaryWorkspace: nil, clientName: nil
        )
        let output = await section.render() ?? ""
        #expect(output.hasSuffix("When a user asks you to operate on files or perform actions in these workspaces, you can use the appropriate tools with the workspace's URI or ID.\n"))
    }
}

// MARK: - SystemInstructions Tests

struct SystemInstructionsTests {
    @Test("empty instructions renders nil")
    func emptyRendersNil() async {
        let output = await SystemInstructions("").render()
        #expect(output == nil)
    }

    @Test("non-empty instructions wraps with header")
    func nonEmptyRendersWithHeader() async {
        let output = await SystemInstructions("Be helpful.").render() ?? ""
        #expect(output.contains("# System Instructions"))
        #expect(output.contains("Be helpful."))
    }

    @Test("multiline instructions preserved")
    func multilinePreserved() async {
        let instructions = "Line one.\nLine two.\nLine three."
        let output = await SystemInstructions(instructions).render() ?? ""
        #expect(output.contains("Line one."))
        #expect(output.contains("Line two."))
        #expect(output.contains("Line three."))
    }
}

// MARK: - AgentContext Tests

struct AgentContextTests {
    @Test("contains identity header and agent name")
    func headerAndName() async {
        let output = await AgentContext(makeAgent(name: "Aria")).render() ?? ""
        #expect(output.contains("## Your Identity"))
        #expect(output.contains("**Aria**"))
    }

    @Test("agent with description includes description line")
    func withDescription() async {
        let output = await AgentContext(makeAgent(description: "A code reviewer")).render() ?? ""
        #expect(output.contains("A code reviewer"))
    }

    @Test("agent without description omits description line")
    func withoutDescription() async {
        let output = await AgentContext(makeAgent(description: "")).render() ?? ""
        #expect(!output.contains("Description:"))
    }

    @Test("timeline title included when provided")
    func withTimelineTitle() async {
        let output = await AgentContext(makeAgent(), timelineTitle: "Sprint Planning").render() ?? ""
        #expect(output.contains("Sprint Planning"))
    }

    @Test("no timeline line when title is nil")
    func noTimelineTitle() async {
        let output = await AgentContext(makeAgent(), timelineTitle: nil).render() ?? ""
        #expect(!output.contains("operating on timeline"))
    }

    @Test("always mentions private workspace and Notes directory")
    func mentionsNotes() async {
        let output = await AgentContext(makeAgent()).render() ?? ""
        #expect(output.contains("Notes/"))
        #expect(output.contains("private workspace"))
    }
}

// MARK: - TimelineContext Tests

struct TimelineContextTests {
    @Test("contains timeline ID and title")
    func idAndTitle() async {
        let timeline = Timeline(title: "My Project")
        let output = await TimelineContext(timeline).render() ?? ""
        #expect(output.contains(timeline.id.uuidString))
        #expect(output.contains("My Project"))
    }

    @Test("default title used when no custom title")
    func defaultTitle() async {
        let timeline = Timeline()
        let output = await TimelineContext(timeline).render() ?? ""
        #expect(output.contains("New Conversation"))
    }

    @Test("contains Current Timeline header")
    func header() async {
        let output = await TimelineContext(Timeline()).render() ?? ""
        #expect(output.contains("## Current Timeline"))
    }
}
