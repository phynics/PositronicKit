import MonadShared
import Foundation

public protocol ConfigurationServiceProtocol: Sendable {
    /// Loads the current configuration
    func load() async -> LLMConfiguration

    /// Saves the configuration
    func save(_ config: LLMConfiguration) async throws

    /// Clears the configuration
    func clear() async

    /// Perform any necessary migrations
    func migrateIfNeeded() async

    /// Export configuration as JSON data
    func exportConfiguration() async throws -> Data

    /// Import configuration from JSON data
    func importConfiguration(from data: Data) async throws

    /// Restore configuration from automatic backup
    func restoreFromBackup() async throws -> LLMConfiguration?
}
