import Foundation
import PKContracts
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("Turn admission captures provider and workspace authority once", .tags(.integration))
struct TurnAdmissionSnapshotTests {
    @Test("provider configuration captured at admission survives replacement during preparation")
    func providerConfigurationCapturedAtAdmission() async throws {
        let source = GatedTurnContextSource()
        let llm = MockLLMService()
        llm.mockConfig = configuration(modelName: "captured-model")
        llm.mockClient.nextResponse = "reply"
        let runtime = TestRuntime(
            workspaceRoot: TestRuntime.uniqueWorkspaceRoot(),
            llm: llm,
            runtime: .init(customization: RuntimeCustomization(turnContextSource: source))
        )
        let timeline = try await runtime.timelines.create(title: "Provider capture")

        let turnTask = Task {
            try await timeline.startDirectTurn(
                "hello",
                context: DirectTurnContext(systemInstructions: "")
            )
        }
        await source.waitUntilEntered()

        try await llm.updateConfiguration(configuration(modelName: "replacement-model"))
        await source.release()

        let turn = try await turnTask.value
        let events = await turn.events().collect()
        let completedModel = events.compactMap { event -> String? in
            guard case let .completion(.generationCompleted(_, metadata)) = event else {
                return nil
            }
            return metadata.model
        }.last

        #expect(completedModel == "captured-model")
        #expect(await llm.configuration.activeProviderConfiguration.modelName == "replacement-model")
    }

    @Test("workspace authority captured at admission survives a binding change during preparation")
    func workspaceAuthorityCapturedAtAdmission() async throws {
        let source = GatedTurnContextSource()
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "reply"
        let repository = InMemoryTimelineRuntimeRepository()
        let runtime = TestRuntime(
            workspaceRoot: TestRuntime.uniqueWorkspaceRoot(),
            llm: llm,
            persistenceConfiguration: .init(
                runtimeRepository: repository,
                workspaceBindingRepository: repository
            ),
            runtime: .init(customization: RuntimeCustomization(turnContextSource: source))
        )
        let timeline = try await runtime.timelines.create(title: "Workspace capture")
        let firstWorkspace = try await runtime.workspaces.create(
            uri: WorkspaceURI(parsing: "workspace://admission-first")!,
            location: .runtime
        )
        let secondWorkspace = try await runtime.workspaces.create(
            uri: WorkspaceURI(parsing: "workspace://admission-second")!,
            location: .runtime
        )
        _ = try await repository.claim(
            workspaceID: firstWorkspace.id,
            for: timeline.id,
            now: Date()
        )

        let turnTask = Task {
            try await timeline.startDirectTurn(
                "hello",
                context: DirectTurnContext(systemInstructions: "")
            )
        }
        await source.waitUntilEntered()

        _ = try await repository.release(
            workspaceID: firstWorkspace.id,
            from: timeline.id,
            now: Date()
        )
        _ = try await repository.claim(
            workspaceID: secondWorkspace.id,
            for: timeline.id,
            now: Date()
        )
        await source.release()

        let firstTurn = try await turnTask.value
        _ = await firstTurn.events().collect()
        let firstPrompt = try #require(llm.mockClient.messageHistory.first)
            .map(\.content)
            .joined(separator: "\n")
        #expect(firstPrompt.contains(firstWorkspace.uri.description))
        #expect(!firstPrompt.contains(secondWorkspace.uri.description))

        let secondTurn = try await timeline.startDirectTurn(
            "again",
            context: DirectTurnContext(systemInstructions: "")
        )
        _ = await secondTurn.events().collect()
        let secondPrompt = try #require(llm.mockClient.messageHistory.last)
            .map(\.content)
            .joined(separator: "\n")
        #expect(secondPrompt.contains(secondWorkspace.uri.description))
        #expect(!secondPrompt.contains(firstWorkspace.uri.description))
    }

    private func configuration(modelName: String) -> LLMConfiguration {
        var configuration = LLMConfiguration(activeProvider: .openAI)
        var provider = configuration.activeProviderConfiguration
        provider.modelName = modelName
        configuration.activeProviderConfiguration = provider
        return configuration
    }
}

private actor GatedTurnContextSource: TurnContextSource {
    private var entered = false
    private var released = false

    func contributions(for _: TurnContextRequest) async throws -> [TurnContextContribution] {
        entered = true
        while !released {
            await Task.yield()
        }
        return []
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        released = true
    }
}
