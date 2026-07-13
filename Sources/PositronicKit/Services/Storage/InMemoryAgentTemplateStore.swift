import Foundation
import PKShared
import PKUtilities

/// Thread-safe in-memory agent template store for prototyping and development.
public actor InMemoryAgentTemplateStore: AgentTemplateStoreProtocol {
    private var templates: [AgentTemplate] = []

    public init() {}

    public func saveAgentTemplate(_ template: AgentTemplate) async throws {
        if let index = templates.firstIndex(where: { $0.id == template.id }) {
            templates[index] = template
        } else {
            templates.append(template)
        }
    }

    public func fetchAgentTemplate(id: UUID) async throws -> AgentTemplate? {
        templates.first { $0.id == id }
    }

    public func fetchAgentTemplate(key: String) async throws -> AgentTemplate? {
        if key == "default" {
            return templates.first
        }
        if let uuid = UUID(uuidString: key) {
            return templates.first { $0.id == uuid }
        }
        return nil
    }

    public func fetchAllAgentTemplates() async throws -> [AgentTemplate] {
        templates
    }

    public func hasAgentTemplate(id: String) async -> Bool {
        if let uuid = UUID(uuidString: id) {
            return templates.contains { $0.id == uuid }
        }
        return false
    }

    package func allTemplates() -> [AgentTemplate] {
        templates
    }

    package func replaceTemplates(_ templates: [AgentTemplate]) {
        self.templates = templates
    }
}
