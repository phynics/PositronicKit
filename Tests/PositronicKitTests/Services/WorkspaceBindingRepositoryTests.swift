import Foundation
import PositronicKit
import XCTest

final class WorkspaceBindingRepositoryTests: XCTestCase {
    func testConcurrentClaimsAllowOnlyOneThreadOwner() async throws {
        let repository = InMemoryWorkspaceBindingRepository()
        let workspaceID = UUID()
        let firstThreadID = UUID()
        let secondThreadID = UUID()

        let results = await withTaskGroup(of: Result<WorkspaceBinding, Error>.self, returning: [Result<WorkspaceBinding, Error>].self) { group in
            for threadID in [firstThreadID, secondThreadID] {
                group.addTask {
                    do {
                        return .success(try await repository.claim(workspaceID: workspaceID, for: threadID))
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
            return binding.threadID
        }
        XCTAssertEqual(owners.count, 1)
        let owner = try await repository.threadID(for: workspaceID)
        XCTAssertEqual(owner, owners.first)
    }

    func testThreadCanClaimManyWorkspacesAndTransferIsAtomic() async throws {
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
        let transferredOwner = try await repository.threadID(for: workspaceIDs[0])
        let remainingSourceCount = try await repository.bindings(for: source).count
        let destinationBindings = try await repository.bindings(for: destination).map(\.workspaceID)
        XCTAssertEqual(transferredOwner, destination)
        XCTAssertEqual(remainingSourceCount, 2)
        XCTAssertEqual(destinationBindings, [workspaceIDs[0]])
    }

    func testSameClaimIsIdempotentAndReleaseIsExplicit() async throws {
        let repository = InMemoryWorkspaceBindingRepository()
        let workspaceID = UUID()
        let threadID = UUID()

        let first = try await repository.claim(workspaceID: workspaceID, for: threadID)
        let retry = try await repository.claim(workspaceID: workspaceID, for: threadID)
        XCTAssertEqual(first, retry)

        try await repository.release(workspaceID: workspaceID, from: threadID)
        let owner = try await repository.threadID(for: workspaceID)
        XCTAssertNil(owner)
    }

    func testAgentPrimaryWorkspaceIsNotAnOrdinaryThreadBinding() async throws {
        let bindings = InMemoryWorkspaceBindingRepository()
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: UnconfiguredLLMService()),
            persistence: .init(
                runtimeRepository: InMemoryThreadRuntimeRepository(),
                workspaceBindingRepository: bindings
            )
        ))
        let agent = try await kit.agents.create(
            name: "Binding Agent",
            description: "Primary workspace ownership test"
        )
        let workspaceID = try XCTUnwrap(agent.primaryWorkspaceID)
        let privateThread = try await kit.threads.get(agent.privateThreadID)

        XCTAssertNotNil(privateThread)
        let owner = try await bindings.threadID(for: workspaceID)
        XCTAssertNil(owner)
    }
}
