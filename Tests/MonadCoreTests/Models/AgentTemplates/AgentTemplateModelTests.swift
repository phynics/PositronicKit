import Testing
@testable import MonadCore
@testable import MonadShared
import Foundation

@Suite final class AgentTemplateModelTests {
    private func assertCodable<T: Codable & Equatable>(_ value: T) throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(value)
        let decoded = try decoder.decode(T.self, from: data)
        #expect(value == decoded)
    }

    @Test

    func testAgentTemplateCodable() throws {
        // AgentTemplate initialization
        let agent = AgentTemplate(
            id: UUID(),
            name: "Worker",
            description: "Does tasks.",
            systemPrompt: "You follow instructions.",
            personaPrompt: "Be professional.",
            guardrailsPrompt: "Don't break things."
        )

        try assertCodable(agent)

        // Test composedInstructions
        #expect(agent.composedInstructions.contains("You follow instructions."))
        #expect(agent.composedInstructions.contains("## Persona"))
        #expect(agent.composedInstructions.contains("Be professional."))
        #expect(agent.composedInstructions.contains("## Guardrails"))
        #expect(agent.composedInstructions.contains("Don't break things."))
    }
}
