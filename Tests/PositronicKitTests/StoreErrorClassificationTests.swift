import ErrorKit
import Foundation
import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

/// PKRR-008: Store outages and corruption must surface as typed `ThreadError`s, not
/// collapse into `threadNotFound` or silent `nil`/empty results. These tests prove
/// the fix by driving each error site with a failing store mock and asserting the
/// typed error (or degradation) that surfaces.
@Suite("Store error classification (PKRR-008)")
struct StoreErrorClassificationTests {

    // MARK: - updateThreadTitle: store outage must not surface as threadNotFound

    @Test("updateThreadTitle throws unavailable when the store fails, not threadNotFound")
    func updateTitleStoreFailureThrowsUnavailable() async throws {
        let failingStore = FailingThreadPersistence(fetchFails: true)
        let workspace = TestWorkspace()
        let manager = ThreadManager(
            stores: .init(
                threadStore: failingStore,
                messageStore: MockPersistenceService(),
                workspaceStore: MockPersistenceService(),
                toolPersistence: MockPersistenceService()
            ),
            workspaceRoot: workspace.root
        )

        let id = UUID()

        do {
            try await manager.updateThreadTitle(id, title: "new title")
            Issue.record("Expected ThreadError.unavailable, but no error was thrown")
        } catch ThreadError.unavailable {
            // Correct — store outage is distinguished from not-found.
        } catch ThreadError.threadNotFound {
            Issue.record("Store outage was collapsed into threadNotFound (the bug)")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(failingStore.fetchAttemptCount >= 1, "The store must have been queried")
    }

    @Test("updateThreadTitle throws threadNotFound when the thread genuinely does not exist")
    func updateTitleMissingThrowsNotFound() async throws {
        let workspace = TestWorkspace()
        let manager = ThreadManager(workspaceRoot: workspace.root)

        do {
            try await manager.updateThreadTitle(UUID(), title: "x")
            Issue.record("Expected threadNotFound")
        } catch ThreadError.threadNotFound {
            // Correct — a genuine not-found is still a not-found.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - attachWorkspace: store outage must not surface as threadNotFound

    @Test("attachWorkspace throws unavailable when the store fails, not timelineNotFound")
    func attachWorkspaceStoreFailureThrowsUnavailable() async throws {
        let failingStore = FailingThreadPersistence(fetchFails: true)
        let workspace = TestWorkspace()
        let manager = ThreadManager(
            stores: .init(
                threadStore: failingStore,
                messageStore: MockPersistenceService(),
                workspaceStore: MockPersistenceService(),
                toolPersistence: MockPersistenceService()
            ),
            workspaceRoot: workspace.root
        )

        let id = UUID()
        let workspaceId = UUID()

        do {
            try await manager.attachWorkspace(workspaceId, to: id)
            Issue.record("Expected ThreadError.unavailable")
        } catch ThreadError.unavailable {
            // Correct.
        } catch ThreadError.threadNotFound {
            Issue.record("Store outage was collapsed into threadNotFound (the bug)")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(failingStore.fetchAttemptCount >= 1)
    }

    // MARK: - detachWorkspace: store outage must not surface as threadNotFound

    @Test("detachWorkspace throws unavailable when the store fails, not timelineNotFound")
    func detachWorkspaceStoreFailureThrowsUnavailable() async throws {
        let failingStore = FailingThreadPersistence(fetchFails: true)
        let workspace = TestWorkspace()
        let manager = ThreadManager(
            stores: .init(
                threadStore: failingStore,
                messageStore: MockPersistenceService(),
                workspaceStore: MockPersistenceService(),
                toolPersistence: MockPersistenceService()
            ),
            workspaceRoot: workspace.root
        )

        let id = UUID()
        let workspaceId = UUID()

        do {
            try await manager.detachWorkspace(workspaceId, from: id)
            Issue.record("Expected ThreadError.unavailable")
        } catch ThreadError.unavailable {
            // Correct.
        } catch ThreadError.threadNotFound {
            Issue.record("Store outage was collapsed into threadNotFound (the bug)")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(failingStore.fetchAttemptCount >= 1)
    }

    // MARK: - getWorkspaces: store outage must throw, not return nil

    @Test("getWorkspaces throws unavailable when the store fails, not nil")
    func getWorkspacesStoreFailureThrowsUnavailable() async throws {
        let failingStore = FailingThreadPersistence(fetchFails: true)
        let workspace = TestWorkspace()
        let manager = ThreadManager(
            stores: .init(
                threadStore: failingStore,
                messageStore: MockPersistenceService(),
                workspaceStore: MockPersistenceService(),
                toolPersistence: MockPersistenceService()
            ),
            workspaceRoot: workspace.root
        )

        let id = UUID()

        do {
            _ = try await manager.getWorkspaces(for: id)
            Issue.record("Expected TimelineError.unavailable")
        } catch ThreadError.unavailable {
            // Correct — store outage throws rather than returning nil.
        } catch ThreadError.threadNotFound {
            Issue.record("Store outage was collapsed into timelineNotFound (the bug)")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(failingStore.fetchAttemptCount >= 1)
    }

    @Test("getWorkspaces throws timelineNotFound when the timeline genuinely does not exist")
    func getWorkspacesMissingThrowsNotFound() async throws {
        let workspace = TestWorkspace()
        let manager = ThreadManager(workspaceRoot: workspace.root)

        do {
            _ = try await manager.getWorkspaces(for: UUID())
            Issue.record("Expected timelineNotFound")
        } catch ThreadError.threadNotFound {
            // Correct.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - getWorkspaces: individual workspace fetch failure returns degradation

    @Test("getWorkspaces returns degradation when individual workspace fetch fails")
    func getWorkspacesIndividualFetchFailureReturnsDegradation() async throws {
        let persistence = MockPersistenceService()
        let failingWorkspaceStore = FailingWorkspaceStore(fetchFails: false)
        let workspace = TestWorkspace()
        let manager = ThreadManager(
            stores: .init(
                threadStore: persistence,
                messageStore: persistence,
                workspaceStore: failingWorkspaceStore,
                toolPersistence: persistence
            ),
            workspaceRoot: workspace.root
        )

        let thread = try await manager.createThread()
        let attachedWS = WorkspaceReference(
            uri: WorkspaceURI(host: "user-mac", path: "/projects/app"),
            location: .attached
        )
        try await failingWorkspaceStore.saveWorkspace(attachedWS)
        try await manager.attachWorkspace(attachedWS.id, to: thread.id)

        failingWorkspaceStore.fetchFails = true

        let result = try await manager.getWorkspaces(for: thread.id)

        #expect(!result.attached.contains { $0.id == attachedWS.id },
               "The failing workspace should not appear in the result")
        #expect(result.degradations.contains { deg in
            deg.operation == "getWorkspaces.fetchWorkspace"
                && deg.entityID.contains(attachedWS.id.uuidString.prefix(8))
        }, "A degradation should be recorded for the failed workspace fetch")
        #expect(failingWorkspaceStore.fetchAttemptCount >= 1)
    }

    // MARK: - getToolSource: store outage must throw, not return nil

    @Test("getToolSource throws unavailable when the store fails, not nil")
    func getToolSourceStoreFailureThrowsUnavailable() async throws {
        let failingToolPersistence = FailingToolPersistence(fetchSourceFails: true)
        let persistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let manager = ThreadManager(
            stores: .init(
                threadStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                toolPersistence: failingToolPersistence
            ),
            workspaceRoot: workspace.root
        )

        let thread = try await manager.createThread()

        do {
            _ = try await manager.getToolSource(toolId: "some_tool", for: thread.id)
            Issue.record("Expected TimelineError.unavailable")
        } catch ThreadError.unavailable {
            // Correct — store outage throws rather than returning nil.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(failingToolPersistence.fetchSourceAttemptCount >= 1)
    }

    @Test("getToolSource returns nil (not throws) when the tool genuinely has no source")
    func getToolSourceUnknownReturnsNil() async throws {
        let persistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let manager = ThreadManager(
            stores: .init(
                threadStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                toolPersistence: persistence
            ),
            workspaceRoot: workspace.root
        )

        let thread = try await manager.createThread()

        let source = try await manager.getToolSource(toolId: "nonexistent_tool", for: thread.id)
        #expect(source == nil, "A genuinely unknown tool should return nil, not throw")
    }

    // MARK: - setupThreadComponents: workspace resolution failure is survivable

    @Test("createTimeline succeeds even when workspace resolver fails for attached workspaces")
    func createThreadSurvivesWorkspaceResolverFailure() async throws {
        let persistence = MockPersistenceService()
        let failingWorkspaceStore = FailingWorkspaceStore(fetchFails: true)
        let workspace = TestWorkspace()
        let manager = ThreadManager(
            stores: .init(
                threadStore: persistence,
                messageStore: persistence,
                workspaceStore: failingWorkspaceStore,
                toolPersistence: persistence
            ),
            workspaceRoot: workspace.root
        )

        // createThread should succeed even if workspace resolution fails internally —
        // the thread itself is created and persisted.
        let thread = try await manager.createThread(title: "Resilient Timeline")

        #expect(thread.title == "Resilient Timeline")
        #expect(await manager.thread(id: thread.id) != nil,
               "Timeline should be in memory even if workspace resolution degraded")
    }

    // MARK: - ThreadError taxonomy contract

    @Suite("TimelineError taxonomy")
    struct ThreadErrorTaxonomyTests {
        @Test("Every case maps to a unique non-zero error code in the timeline domain")
        func uniqueErrorCodes() {
            let cases: [ThreadError] = [
                .threadNotFound,
                .unavailable,
                .corrupt("desc"),
                .permissionDenied,
                .invalidState("desc"),
            ]
            let codes = cases.map(\.errorCode)
            #expect(Set(codes).count == codes.count, "Error codes must be unique")
            #expect(codes.allSatisfy { $0 != 0 }, "Error codes must be non-zero")
            #expect(codes == [6001, 6002, 6003, 6004, 6005])
            #expect(cases.allSatisfy { $0.errorDomain == PKErrorDomain.thread })
        }

        @Test("corrupt includes context in userFriendlyMessage")
        func corruptMessage() {
            let error = ThreadError.corrupt("timeline:\(UUID())")
            #expect(error.userFriendlyMessage.contains("corrupted"))
        }

        @Test("permissionDenied message references permission")
        func permissionDeniedMessage() {
            let error = ThreadError.permissionDenied
            #expect(error.userFriendlyMessage.contains("Permission"))
        }

        @Test("invalidState message references invalid state")
        func invalidStateMessage() {
            let error = ThreadError.invalidState("timeline not hydrated")
            #expect(error.userFriendlyMessage.contains("invalid state"))
        }

        @Test("unavailable has remediation guidance")
        func unavailableRemediation() {
            #expect(ThreadError.unavailable.remediation != nil)
            #expect(ThreadError.unavailable.remediation?.contains("retry") == true)
        }

        @Test("corrupt has remediation guidance")
        func corruptRemediation() {
            #expect(ThreadError.corrupt("x").remediation != nil)
        }

        @Test("permissionDenied has remediation guidance")
        func permissionDeniedRemediation() {
            #expect(ThreadError.permissionDenied.remediation != nil)
        }

        @Test("timelineNotFound and invalidState have no remediation")
        func noRemediationForNotFoundAndInvalidState() {
            #expect(ThreadError.threadNotFound.remediation == nil)
            #expect(ThreadError.invalidState("x").remediation == nil)
        }

        @Test("errorDescription includes domain and code for traceability")
        func errorDescriptionFormat() {
            let error = ThreadError.unavailable
            #expect(error.errorDescription?.contains("6002") == true)
            #expect(error.errorDescription?.contains(PKErrorDomain.thread) == true)
        }
    }

    // MARK: - StoreDegradation contracts

    @Suite("StoreDegradation")
    struct StoreDegradationTests {
        @Test("init captures operation, entityId, and error identity")
        func initCapturesFields() {
            let degradation = StoreDegradation(
                operation: "getWorkspaces.fetchWorkspace",
                entityID: "workspace:abc12345",
                error: FailingStoreError.fetchFailed
            )

            #expect(degradation.operation == "getWorkspaces.fetchWorkspace")
            #expect(degradation.entityID == "workspace:abc12345")
            // FailingStoreError does not conform to PKError, so identity is nil.
            #expect(degradation.errorIdentity == nil)
            #expect(!degradation.message.isEmpty)
        }

        @Test("init extracts error identity from PKError-conforming errors")
        func initExtractsPKErrorIdentity() {
            let error = ThreadError.unavailable
            let degradation = StoreDegradation(
                operation: "test",
                entityID: "timeline:abc",
                error: error
            )

            #expect(degradation.errorIdentity?.domain == PKErrorDomain.thread)
            #expect(degradation.errorIdentity?.code == 6002)
        }
    }
}
