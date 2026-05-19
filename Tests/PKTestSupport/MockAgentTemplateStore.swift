import PKShared
import PositronicKit
import Foundation

public final class MockAgentTemplateStore: AgentTemplateStoreProtocol, @unchecked Sendable {
    private let backing = InMemoryAgentTemplateStore()

    public var agentTemplates: [AgentTemplate] {
        get { (try? BlockingAsync.run { [self] in await self.backing.allTemplates() }) ?? [] }
        set { _ = try? BlockingAsync.run { [self] in await self.backing.replaceTemplates(newValue) } }
    }

    public init() {}

    public func saveAgentTemplate(_ agent: AgentTemplate) async throws {
        try await backing.saveAgentTemplate(agent)
    }

    public func fetchAgentTemplate(id: UUID) async throws -> AgentTemplate? {
        try await backing.fetchAgentTemplate(id: id)
    }

    public func fetchAgentTemplate(key: String) async throws -> AgentTemplate? {
        try await backing.fetchAgentTemplate(key: key)
    }

    public func fetchAllAgentTemplates() async throws -> [AgentTemplate] {
        try await backing.fetchAllAgentTemplates()
    }

    public func hasAgentTemplate(id: String) async -> Bool {
        await backing.hasAgentTemplate(id: id)
    }
}
