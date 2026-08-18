import Foundation
import PKShared

/// Value-type wrapper around the persistence boundary for an LLM service's configuration.
///
/// Deliberately not an actor: `ConfigurationServiceProtocol` already owns its state and
/// serialization. The repository exists so the `LLMService` actor does not duplicate the
/// persistence surface, and so preparation tasks capture the repository rather than `self`.
struct LLMConfigurationRepository: Sendable {
    let storage: any ConfigurationServiceProtocol

    func migrateAndLoad() async -> LLMConfiguration {
        await storage.migrateIfNeeded()
        return await storage.load()
    }

    func load() async -> LLMConfiguration {
        await storage.load()
    }

    func save(_ configuration: LLMConfiguration) async throws {
        try await storage.save(configuration)
    }

    func clear() async {
        await storage.clear()
    }

    func exportConfiguration() async throws -> Data {
        try await storage.exportConfiguration()
    }

    func importConfiguration(from data: Data) async throws {
        try await storage.importConfiguration(from: data)
    }

    func restoreFromBackup() async throws -> LLMConfiguration? {
        try await storage.restoreFromBackup()
    }
}
