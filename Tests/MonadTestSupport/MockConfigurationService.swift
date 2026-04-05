import MonadShared
import MonadCore
import Foundation

public actor MockConfigurationService: ConfigurationServiceProtocol {
    public var config: LLMConfiguration = .openAI
    public var backupConfig: LLMConfiguration?

    public init() {}

    public func load() async -> LLMConfiguration {
        return config
    }

    public func save(_ config: LLMConfiguration) async throws {
        self.config = config
    }

    public func clear() async {
        self.config = .openAI
    }

    public func migrateIfNeeded() async {}

    public func restoreFromBackup() async throws -> LLMConfiguration? {
        if let backup = backupConfig {
            self.config = backup
            return backup
        }
        return nil
    }

    public func exportConfiguration() async throws -> Data {
        return try JSONEncoder().encode(config)
    }

    public func importConfiguration(from data: Data) async throws {
        let decoded = try JSONDecoder().decode(LLMConfiguration.self, from: data)
        self.config = decoded
    }
}
