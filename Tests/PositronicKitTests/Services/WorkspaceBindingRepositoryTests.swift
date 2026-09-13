import Foundation
import PositronicKit
import XCTest

final class WorkspaceBindingRepositoryTests: XCTestCase {
    func testConcurrentClaimsAllowOnlyOneTimelineOwner() async throws {
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
        XCTAssertEqual(owners.count, 1)
        let owner = try await repository.timelineID(for: workspaceID)
        XCTAssertEqual(owner, owners.first)
    }

    func testTimelineCanClaimManyWorkspacesAndTransferIsAtomic() async throws {
        let repository = InMemoryWorkspaceBindingRepository()
        let source = UUID()
        let destination = UUID()
        let workspaceIDs = [UUID(), UUID(), UUID()]

        for workspaceID in workspaceIDs {
            _ = try await repository.claim(workspaceID: workspaceID, for: source)
        }
        let sourceBindings = try await repository.bindings(for: source).map(\.workspaceID)
        XCTAssertEqual(sourceBindings, workspaceIDs)

        _ = try await repository.transfer(
            workspaceID: workspaceIDs[0],
            from: source,
            to: destination
        )
        let transferredOwner = try await repository.timelineID(for: workspaceIDs[0])
        let remainingSourceCount = try await repository.bindings(for: source).count
        let destinationBindings = try await repository.bindings(for: destination).map(\.workspaceID)
        XCTAssertEqual(transferredOwner, destination)
        XCTAssertEqual(remainingSourceCount, 2)
        XCTAssertEqual(destinationBindings, [workspaceIDs[0]])
    }

    func testSameClaimIsIdempotentAndReleaseIsExplicit() async throws {
        let repository = InMemoryWorkspaceBindingRepository()
        let workspaceID = UUID()
        let timelineID = UUID()

        let first = try await repository.claim(workspaceID: workspaceID, for: timelineID)
        let retry = try await repository.claim(workspaceID: workspaceID, for: timelineID)
        XCTAssertEqual(first, retry)

        try await repository.release(workspaceID: workspaceID, from: timelineID)
        let owner = try await repository.timelineID(for: workspaceID)
        XCTAssertNil(owner)
    }

    func testAgentPrimaryWorkspaceIsNotAnOrdinaryTimelineBinding() async throws {
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
        let workspaceID = try XCTUnwrap(agent.primaryWorkspaceID)
        let privateTimeline = try await kit.timelines.get(agent.privateTimelineID)

        XCTAssertNotNil(privateTimeline)
        let owner = try await bindings.timelineID(for: workspaceID)
        XCTAssertNil(owner)
    }
}
