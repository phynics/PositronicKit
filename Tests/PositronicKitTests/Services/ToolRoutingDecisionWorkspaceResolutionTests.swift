import Foundation
import Logging
@testable import PKShared
@testable import PositronicKit
import Testing

/// Isolation tests for `ToolRoutingDecision.resolveWorkspace` (PKARCH-002 AC #3): workspace
/// lookup, explicit `workspaceID` argument validation, dynamic-tool fallback, and the no-
/// workspace-at-all case — all without bringing up a `TimelineManager`.
@Suite("ToolRoutingDecision.resolveWorkspace isolation")
struct ToolRoutingDecisionWorkspaceResolutionTests {
    private actor FakeProvider: WorkspaceResolutionProvider {
        let primary: WorkspaceReference?
        let attached: [WorkspaceReference]
        let registeredToolIdsByWorkspace: [UUID: Set<String>]
        let isPrivateById: [UUID: Bool]
        let toolManagersByTimeline: [UUID: TimelineToolManager]

        init(
            primary: WorkspaceReference?,
            attached: [WorkspaceReference],
            registeredToolIdsByWorkspace: [UUID: Set<String>] = [:],
            isPrivateById: [UUID: Bool] = [:],
            toolManagersByTimeline: [UUID: TimelineToolManager] = [:]
        ) {
            self.primary = primary
            self.attached = attached
            self.registeredToolIdsByWorkspace = registeredToolIdsByWorkspace
            self.isPrivateById = isPrivateById
            self.toolManagersByTimeline = toolManagersByTimeline
        }

        func workspaces(for timelineId: UUID) async throws -> (
            primary: WorkspaceReference?,
            attached: [WorkspaceReference]
        )? { (primary, attached) }

        func findWorkspaceForTool(_ tool: ToolReference, in candidates: [UUID]) async throws -> UUID? {
            for id in candidates {
                if let ids = registeredToolIdsByWorkspace[id], ids.contains(tool.toolId) {
                    return id
                }
            }
            return nil
        }

        func timelineIsPrivate(id: UUID) async -> Bool? { isPrivateById[id] }
        func toolManager(for timelineId: UUID) async -> TimelineToolManager? {
            toolManagersByTimeline[timelineId]
        }
        func getWorkspace(_ id: UUID) async throws -> WorkspaceReference? {
            if primary?.id == id { return primary }
            return attached.first { $0.id == id }
        }
    }

    private let logger = Logger(label: "test.routing-decision")
    private let timelineId = UUID()

    @Test("Returns the workspace that registers the tool, searching primary then attached in order")
    func resolvesRegisteredWorkspace() async throws {
        let primary = WorkspaceReference(
            uri: try #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtime,
            rootPath: nil
        )
        let attached = WorkspaceReference(
            uri: WorkspaceURI(host: "remote", path: "/x"),
            location: .attached
        )
        let provider = FakeProvider(
            primary: primary,
            attached: [attached],
            registeredToolIdsByWorkspace: [attached.id: ["search_files"]]
        )

        let resolved = try await ToolRoutingDecision.resolveWorkspace(
            for: .known("search_files"),
            in: timelineId,
            arguments: [:],
            provider: provider,
            logger: logger
        )
        #expect(resolved == attached.id)
    }

    @Test("Returns nil when no candidate workspace registers the tool")
    func noWorkspaceRegistersTool() async throws {
        let primary = WorkspaceReference(
            uri: try #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtime,
            rootPath: nil
        )
        let provider = FakeProvider(primary: primary, attached: [], registeredToolIdsByWorkspace: [:])

        let resolved = try await ToolRoutingDecision.resolveWorkspace(
            for: .known("missing_tool"),
            in: timelineId,
            arguments: [:],
            provider: provider,
            logger: logger
        )
        #expect(resolved == nil)
    }

    @Test("Returns nil when the provider has no workspaces for the timeline at all")
    func noWorkspacesAtAll() async throws {
        let provider = FakeProvider(primary: nil, attached: [])

        let resolved = try await ToolRoutingDecision.resolveWorkspace(
            for: .known("any"),
            in: timelineId,
            arguments: [:],
            provider: provider,
            logger: logger
        )
        #expect(resolved == nil)
    }

    @Test("Explicit valid workspaceID argument overrides default lookup")
    func explicitValidWorkspaceID() async throws {
        let primary = WorkspaceReference(
            uri: try #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtime,
            rootPath: nil
        )
        let attached = WorkspaceReference(
            uri: WorkspaceURI(host: "remote", path: "/x"),
            location: .attached
        )
        // attach registers `cat`; explicit asks for attached anyway — should short-circuit to
        // the requested id without consulting findWorkspaceForTool.
        let provider = FakeProvider(
            primary: primary,
            attached: [attached],
            registeredToolIdsByWorkspace: [primary.id: ["cat"]]
        )

        let resolved = try await ToolRoutingDecision.resolveWorkspace(
            for: .known("cat"),
            in: timelineId,
            arguments: ["workspaceID": AnyCodable(attached.id.uuidString)],
            provider: provider,
            logger: logger
        )
        #expect(resolved == attached.id)
    }

    @Test("Explicit invalid workspaceID (not a candidate) fails closed with workspaceNotFound (YAK-33)")
    func explicitInvalidWorkspaceID() async throws {
        let primary = WorkspaceReference(
            uri: try #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtime,
            rootPath: nil
        )
        let provider = FakeProvider(primary: primary, attached: [])
        let bogus = UUID()

        do {
            _ = try await ToolRoutingDecision.resolveWorkspace(
                for: .known("cat"),
                in: timelineId,
                arguments: ["workspaceID": AnyCodable(bogus.uuidString)],
                provider: provider,
                logger: logger
            )
            Issue.record("Expected workspaceNotFound")
        } catch let ToolError.workspaceNotFound(thrownId) {
            #expect(thrownId == bogus)
        }
    }

    @Test("Explicit well-formed but unattached workspaceID fails closed (YAK-33)")
    func explicitWellFormedUnattachedWorkspaceID() async throws {
        let primary = WorkspaceReference(
            uri: try #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtime,
            rootPath: nil
        )
        let provider = FakeProvider(primary: primary, attached: [])
        let unattached = UUID()

        do {
            _ = try await ToolRoutingDecision.resolveWorkspace(
                for: .known("cat"),
                in: timelineId,
                arguments: ["workspaceID": AnyCodable(unattached.uuidString)],
                provider: provider,
                logger: logger
            )
            Issue.record("Expected workspaceNotFound")
        } catch let ToolError.workspaceNotFound(thrownId) {
            #expect(thrownId == unattached)
        }
    }

    @Test("Malformed workspaceID string (not a UUID) falls back to default resolution, not throw")
    func malformedWorkspaceIDFallsBack() async throws {
        let primary = WorkspaceReference(
            uri: try #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtime,
            rootPath: nil
        )
        let provider = FakeProvider(
            primary: primary,
            attached: [],
            registeredToolIdsByWorkspace: [primary.id: ["cat"]]
        )

        let resolved = try await ToolRoutingDecision.resolveWorkspace(
            for: .known("cat"),
            in: timelineId,
            arguments: ["workspaceID": AnyCodable("not-a-uuid")],
            provider: provider,
            logger: logger
        )
        #expect(resolved == primary.id)
    }

    @Test("resolveToolReference prefers a dynamic tool's custom reference over .known fallback")
    func resolveToolReferencePrefersDynamic() {
        let customRef = ToolReference.custom(definition: .init(
            id: "dynamic_tool",
            name: "dynamic_tool",
            description: "dynamic"
        ))
        struct CustomRefTool: PKShared.Tool, ToolReferenceProviding, @unchecked Sendable {
            let id = "dynamic_tool"
            let name = "dynamic_tool"
            let description = "dynamic"
            let requiresPermission = false
            let toolReference: ToolReference
            var parametersSchema: [String: AnyCodable] { [:] }
            func canExecute() async -> Bool { true }
            func execute(parameters _: [String: Any]) async throws -> ToolResult { .success("ok") }
        }
        let tool = AnyTool(CustomRefTool(toolReference: customRef))
        let call = ParsedToolCall(callId: "1", name: "dynamic_tool", argumentsJSON: "{}")
        let resolved = ToolRoutingDecision.resolveToolReference(for: call, availableTools: [tool])
        #expect(resolved == customRef)
    }

    @Test("outcomeForWorkspace defers attached and disallows attached on private timelines")
    func outcomePolicy() throws {
        #expect(try ToolRoutingDecision.outcomeForWorkspace(location: .attached, timelineIsPrivate: false) == .deferExternally)
        #expect(try ToolRoutingDecision.outcomeForWorkspace(location: .runtime, timelineIsPrivate: true) == .executeLocally)
        #expect(try ToolRoutingDecision.outcomeForWorkspace(location: .runtimeTimeline, timelineIsPrivate: true) == .executeLocally)
        do {
            _ = try ToolRoutingDecision.outcomeForWorkspace(location: .attached, timelineIsPrivate: true)
            Issue.record("Expected attached-tools private-timeline error")
        } catch ToolError.attachedToolsDisallowedOnPrivateTimeline {
            // expected
        }
    }
}