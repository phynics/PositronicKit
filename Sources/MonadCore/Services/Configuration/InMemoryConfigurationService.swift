import Foundation
import MonadShared

/// A thread-safe, in-memory configuration service for transient state.
/// Useful for prototyping and cases where persistence is not required.
public actor InMemoryConfigurationService: ConfigurationServiceProtocol {
    private var configuration: LLMConfiguration

    public init(config: LLMConfiguration = .openAI) {
        self.configuration = config
    }

    public func load() async -> LLMConfiguration {
        return configuration
    }

    public func save(_ config: LLMConfiguration) async throws {
        self.configuration = config
    }

    public func clear() async {
        self.configuration = .openAI
    }

    public func migrateIfNeeded() async {
        // No migration needed for in-memory storage
    }

    public func exportConfiguration() async throws -> Data {
        return try JSONEncoder().encode(configuration)
    }

    public func importConfiguration(from data: Data) async throws {
        let decoded = try JSONDecoder().decode(LLMConfiguration.self, from: data)
        self.configuration = decoded
    }

    public func restoreFromBackup() async throws -> LLMConfiguration? {
        // No backup support for in-memory storage
        return nil
    }
}
