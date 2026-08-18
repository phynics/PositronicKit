import Foundation
import PKShared
import PKUtilities
import PositronicKit

/// In-memory `ConfigurationServiceProtocol` test double.
///
/// Configurable: `config` (current stored configuration, defaults to `.openAI`) and
/// `backupConfig` (the value `restoreFromBackup()` restores from, if set; `nil` makes
/// restore a no-op that returns `nil`). `clear()` resets `config` back to `.openAI` rather
/// than clearing it to an empty/unconfigured state.
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

    /// Test helper: replaces the stored configuration (avoids cross-actor property writes).
    public func setBackupConfig(_ config: LLMConfiguration?) {
        backupConfig = config
    }

    public func clear() async {
        config = .openAI
    }

    public func migrateIfNeeded() async {}

    public func restoreFromBackup() async throws -> LLMConfiguration? {
        if let backup = backupConfig {
            config = backup
            return backup
        }
        return nil
    }

    public func exportConfiguration() async throws -> Data {
        return try JSONEncoder().encode(config)
    }

    public func importConfiguration(from data: Data) async throws {
        let decoded = try JSONDecoder().decode(LLMConfiguration.self, from: data)
        config = decoded
    }
}
