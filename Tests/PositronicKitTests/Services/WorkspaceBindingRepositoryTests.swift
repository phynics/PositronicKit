import Foundation
import PositronicKit
import Testing

@Suite("Workspace binding repository", .tags(.integration))
struct WorkspaceBindingRepositoryTests {
    @Test("Concurrent claims allow only one Timeline owner")
    func concurrentClaimsAllowOnlyOneTimelineOwner() async throws {
        let repository = InMemoryWorkspaceBindingRepository()
        let workspaceID = UUID()
        let firstTimelineID = UUID()
        let secondTimelineID = UUID()

        let results = await withTaskGroup(of: Result<WorkspaceBinding, Error>.self, returning: [Result<WorkspaceBinding, Error>].self) { group in
            for timelineID in [firstTimelineID, secondTimelineID] {
                group.addTask {
                    do {
                        return .success(try await repository.claim(workspaceID: workspaceID, for: timelineID))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var collected: [Result<WorkspaceBinding, Error>] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        let owners = results.compactMap { result -> UUID? in
            guard case let .success(binding) = result else { return nil }
            return binding.timelineID
        }
        #expect(owners.count == 1)
        let owner = try await repository.timelineID(for: workspaceID)
        #expect(owner == owners.first)
    }

    @Test("Timeline can claim many workspaces and transfer is atomic")
    func timelineCanClaimManyWorkspacesAndTransferIsAtomic() async throws {
        let repository = InMemoryWorkspaceBindingRepository()
        let source = UUID()
        let destination = UUID()
        let workspaceIDs = [UUID(), UUID(), UUID()]

        for workspaceID in workspaceIDs {
            _ = try await repository.claim(workspaceID: workspaceID, for: source)
        }
        let sourceBindings = try await repository.bindings(for: source).map(\.workspaceID)
        #expect(sourceBindings == workspaceIDs)

        _ = try await repository.transfer(
            workspaceID: workspaceIDs[0],
            from: source,
            to: destination
        )
        let transferredOwner = try await repository.timelineID(for: workspaceIDs[0])
        let remainingSourceCount = try await repository.bindings(for: source).count
        let destinationBindings = try await repository.bindings(for: destination).map(\.workspaceID)
        #expect(transferredOwner == destination)
        #expect(remainingSourceCount == 2)
        #expect(destinationBindings == [workspaceIDs[0]])
    }

    @Test("Same claim is idempotent and release is explicit")
    func sameClaimIsIdempotentAndReleaseIsExplicit() async throws {
        let repository = InMemoryWorkspaceBindingRepository()
        let workspaceID = UUID()
        let timelineID = UUID()

        let first = try await repository.claim(workspaceID: workspaceID, for: timelineID)
        let retry = try await repository.claim(workspaceID: workspaceID, for: timelineID)
        #expect(first == retry)

        try await repository.release(workspaceID: workspaceID, from: timelineID)
        let owner = try await repository.timelineID(for: workspaceID)
        #expect(owner == nil)
    }

    @Test("Agent primary workspace is not an ordinary Timeline binding")
    func agentPrimaryWorkspaceIsNotAnOrdinaryTimelineBinding() async throws {
        let bindings = InMemoryWorkspaceBindingRepository()
        let kit = PKRuntime(configuration: .init(
            languageModel: UnconfiguredLLMService(),
            persistence: .init(
                runtimeRepository: InMemoryTimelineRuntimeRepository(),
                workspaceBindingRepository: bindings
            )
        ))
        let agent = try await kit.agents.create(
            name: "Binding Agent",
            description: "Primary workspace ownership test"
        )
        let workspaceID = try #require(agent.primaryWorkspaceID)
        let privateTimeline = try await kit.timelines.get(agent.privateTimelineID)

        #expect(privateTimeline != nil)
        let owner = try await bindings.timelineID(for: workspaceID)
        #expect(owner == nil)
    }
}
