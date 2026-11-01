import Foundation
@testable import PKContracts
import PKTestSupport
@testable import PositronicKit
import Testing

/// Regression coverage for catalog capture no longer swallowing resolver and `listTools`
/// failures. The attach path already records a `.workspace` degradation for the same class of
/// failure; admission catalog capture must do the same so the failure is observable through the
/// Turn degradation lane instead of silently yielding an empty tool set.
@Suite("Workspace tool catalog capture degradations", .tags(.unit))
struct WorkspaceToolCatalogDegradationTests {
    private struct FixedResolver: WorkspaceResolver {
        let provider: any WorkspaceProvider

        func workspace(id _: UUID) async throws -> any WorkspaceProvider? { provider }
    }

    private struct ThrowingResolver: WorkspaceResolver {
        func workspace(id _: UUID) async throws -> any WorkspaceProvider? {
            throw FailingStoreError.fetchFailed
        }
    }

    private struct MissingResolver: WorkspaceResolver {
        func workspace(id _: UUID) async throws -> any WorkspaceProvider? { nil }
    }

    private actor ToggleResolver: WorkspaceResolver {
        let provider: any WorkspaceProvider
        private var shouldFail = false

        init(provider: any WorkspaceProvider) {
            self.provider = provider
        }

        func failResolutions() {
            shouldFail = true
        }

        func workspace(id _: UUID) async throws -> any WorkspaceProvider? {
            if shouldFail { throw FailingStoreError.fetchFailed }
            return provider
        }
    }

    private actor ResolutionStartSignal {
        private var started = false

        func markStarted() {
            started = true
        }

        func waitUntilStarted() async {
            while !started { await Task.yield() }
        }
    }

    private struct CancellationAwareResolver: WorkspaceResolver {
        let signal: ResolutionStartSignal

        func workspace(id _: UUID) async throws -> any WorkspaceProvider? {
            await signal.markStarted()
            while true {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
    }

    private struct ThrowingToolProvider: WorkspaceToolProvider {
        let reference: WorkspaceReference

        var isHealthy: Bool { get async { true } }

        func listTools() async throws -> [ToolReference] {
            throw FailingStoreError.fetchFailed
        }

        func executeTool(id _: String, parameters _: [String: AnyCodable]) async throws -> ToolResult {
            throw WorkspaceError.toolExecutionNotSupported
        }
    }

    private actor RecoverableToolProvider: WorkspaceToolProvider {
        nonisolated let reference: WorkspaceReference
        private var listingFails = false

        init(reference: WorkspaceReference) {
            self.reference = reference
        }

        var isHealthy: Bool { get async { true } }

        func failListings() {
            listingFails = true
        }

        func listTools() async throws -> [ToolReference] {
            if listingFails { throw FailingStoreError.fetchFailed }
            return reference.tools
        }

        func executeTool(id _: String, parameters _: [String: AnyCodable]) async throws -> ToolResult {
            throw WorkspaceError.toolExecutionNotSupported
        }
    }

    private func makeManager(
        persistence: MockPersistenceService,
        resolver: any WorkspaceResolver
    ) -> TimelineManager {
        TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                workspaceBindingRepository: InMemoryWorkspaceBindingRepository(),
                runtimeRepository: persistence
            ),
            workspaceProfile: .noWorkspace,
            resolver: resolver
        )
    }

    @Test("listTools failure during catalog capture records a degradation")
    func listToolsFailureRecordsDegradation() async throws {
        let persistence = MockPersistenceService()
        let workspace = WorkspaceReference(
            uri: WorkspaceURI(host: "degrade", path: "/tools"),
            location: .runtime,
            rootPath: "/tmp"
        )
        let manager = makeManager(
            persistence: persistence,
            resolver: FixedResolver(provider: ThrowingToolProvider(reference: workspace))
        )
        let timeline = try await manager.createTimeline(title: "catalog degradation")
        try await persistence.saveWorkspace(workspace)
        try await manager.attachWorkspace(workspace.id, to: timeline.id)

        _ = try await manager.captureWorkspaceToolCatalog(for: timeline.id, primaryWorkspaceID: nil)

        let degradations = await manager.consumeDegradations(for: timeline.id)
        #expect(degradations.contains {
            $0.operation == "captureWorkspaceCatalog.listTools"
                && $0.entityID == "workspace:\(workspace.id.uuidString.prefix(8))"
        }, "A listTools failure must be recorded, not silently collapsed to an empty tool set")
    }

    @Test("a failed catalog listing does not reuse previously registered Workspace tools")
    func failedListingDoesNotReuseRegisteredTools() async throws {
        let persistence = MockPersistenceService()
        let definition = ToolDefinition(
            id: "previously-listed",
            name: "Previously listed",
            description: "A tool that was listed before the provider failed",
            parametersSchema: [:]
        )
        let workspace = WorkspaceReference(
            uri: WorkspaceURI(host: "degrade", path: "/cached-tools"),
            location: .runtime,
            tools: [.custom(definition)],
            rootPath: "/tmp"
        )
        let provider = RecoverableToolProvider(reference: workspace)
        let manager = makeManager(persistence: persistence, resolver: FixedResolver(provider: provider))
        let timeline = try await manager.createTimeline(title: "catalog fail closed")
        try await persistence.saveWorkspace(workspace)
        try await manager.attachWorkspace(workspace.id, to: timeline.id)

        await provider.failListings()
        let catalog = try await manager.captureWorkspaceToolCatalog(
            for: timeline.id,
            primaryWorkspaceID: nil
        )

        #expect(catalog.entries.first?.tools.isEmpty == true)
        #expect(catalog.advertisedToolIDs.isEmpty)
        #expect(catalog.callTool.parametersSchema.asDictionary["properties"]?.asDictionary?["tool"]?.asDictionary?["enum"]?.asArray?.isEmpty == true)
        #expect(await manager.consumeDegradations(for: timeline.id).contains {
            $0.operation == "captureWorkspaceCatalog.listTools"
        })
    }

    @Test("duplicate identifiers in one Workspace are not collapsed during catalog capture")
    func duplicateIdentifiersWithinWorkspaceStayAmbiguous() async throws {
        let persistence = MockPersistenceService()
        let first = ToolDefinition(
            id: "duplicate",
            name: "First definition",
            description: "First duplicate",
            parametersSchema: [:]
        )
        let second = ToolDefinition(
            id: "duplicate",
            name: "Second definition",
            description: "Second duplicate",
            parametersSchema: [:]
        )
        let workspace = WorkspaceReference(
            uri: WorkspaceURI(host: "degrade", path: "/duplicate-tools"),
            location: .runtime,
            tools: [.custom(first), .custom(second)],
            rootPath: "/tmp"
        )
        let provider = RecoverableToolProvider(reference: workspace)
        let manager = makeManager(persistence: persistence, resolver: FixedResolver(provider: provider))
        let timeline = try await manager.createTimeline(title: "duplicate identifiers")
        try await persistence.saveWorkspace(workspace)
        try await manager.attachWorkspace(workspace.id, to: timeline.id)

        let catalog = try await manager.captureWorkspaceToolCatalog(
            for: timeline.id,
            primaryWorkspaceID: nil
        )
        let call = ParsedToolCall(
            callId: "call-duplicate",
            name: WorkspaceToolDispatcher.callName,
            argumentsJSON: #"{"tool":"duplicate","arguments":{}}"#
        )
        let dispatcher = WorkspaceToolDispatcher(timelineManager: manager)

        #expect(catalog.entries.first?.tools.count == 2)
        #expect(catalog.advertisedToolIDs.isEmpty)
        do {
            _ = try dispatcher.prepare(call: call, catalog: catalog)
            Issue.record("Duplicate declarations in one Workspace must not be resolved by list order")
        } catch let ToolError.ambiguousWorkspaceTool(tool, candidates) {
            #expect(tool == "duplicate")
            #expect(candidates.map(\.toolName) == ["First definition", "Second definition"])
        } catch {
            Issue.record("Expected duplicate declarations to be rejected as ambiguous, got \(error)")
        }
    }

    @Test("resolver failure during attachment is thrown before binding")
    func resolverFailureThrowsBeforeBinding() async throws {
        let persistence = MockPersistenceService()
        let workspace = WorkspaceReference(
            uri: WorkspaceURI(host: "degrade", path: "/resolve"),
            location: .runtime,
            rootPath: "/tmp"
        )
        let manager = makeManager(persistence: persistence, resolver: ThrowingResolver())
        let timeline = try await manager.createTimeline(title: "catalog degradation")
        try await persistence.saveWorkspace(workspace)
        do {
            try await manager.attachWorkspace(workspace.id, to: timeline.id)
            Issue.record("A resolver failure must be reported to the attach caller")
        } catch is FailingStoreError {
            let workspaces = try await manager.getWorkspaces(for: timeline.id)
            #expect(workspaces.primary == nil && workspaces.attached.isEmpty)
        }
    }

    @Test("missing provider during attachment throws before binding")
    func missingProviderThrowsBeforeBinding() async throws {
        let persistence = MockPersistenceService()
        let workspace = WorkspaceReference(
            uri: WorkspaceURI(host: "degrade", path: "/missing-provider"),
            location: .runtime,
            rootPath: "/tmp"
        )
        let manager = makeManager(persistence: persistence, resolver: MissingResolver())
        let timeline = try await manager.createTimeline(title: "missing provider")
        try await persistence.saveWorkspace(workspace)

        await #expect(throws: WorkspaceError.workspaceNotFound) {
            try await manager.attachWorkspace(workspace.id, to: timeline.id)
        }
        let workspaces = try await manager.getWorkspaces(for: timeline.id)
        #expect(workspaces.primary == nil && workspaces.attached.isEmpty)
    }

    @Test("resolver failure leaves an existing binding unchanged")
    func resolverFailureLeavesExistingBindingUnchanged() async throws {
        let persistence = MockPersistenceService()
        let workspace = WorkspaceReference(
            uri: WorkspaceURI(host: "degrade", path: "/existing-binding"),
            location: .runtime,
            rootPath: "/tmp"
        )
        let resolver = ToggleResolver(provider: RecoverableToolProvider(reference: workspace))
        let manager = makeManager(persistence: persistence, resolver: resolver)
        let timeline = try await manager.createTimeline(title: "existing binding")
        try await persistence.saveWorkspace(workspace)
        try await manager.attachWorkspace(workspace.id, to: timeline.id)

        await resolver.failResolutions()
        do {
            try await manager.attachWorkspace(workspace.id, to: timeline.id)
            Issue.record("A resolver failure must be reported to the attach caller")
        } catch is FailingStoreError {
            let workspaces = try await manager.getWorkspaces(for: timeline.id)
            #expect(workspaces.primary?.id == workspace.id)
        }
    }

    @Test("cancelling provider resolution leaves the Workspace unbound")
    func cancellationDuringResolutionLeavesWorkspaceUnbound() async throws {
        let persistence = MockPersistenceService()
        let workspace = WorkspaceReference(
            uri: WorkspaceURI(host: "degrade", path: "/cancelled-resolution"),
            location: .runtime,
            rootPath: "/tmp"
        )
        let signal = ResolutionStartSignal()
        let manager = makeManager(
            persistence: persistence,
            resolver: CancellationAwareResolver(signal: signal)
        )
        let timeline = try await manager.createTimeline(title: "cancelled resolution")
        try await persistence.saveWorkspace(workspace)

        let attachTask = Task {
            try await manager.attachWorkspace(workspace.id, to: timeline.id)
        }
        await signal.waitUntilStarted()
        attachTask.cancel()

        do {
            try await attachTask.value
            Issue.record("A cancelled provider resolution must not report a successful attach")
        } catch is CancellationError {
            let workspaces = try await manager.getWorkspaces(for: timeline.id)
            #expect(workspaces.primary == nil && workspaces.attached.isEmpty)
        }
    }
}
