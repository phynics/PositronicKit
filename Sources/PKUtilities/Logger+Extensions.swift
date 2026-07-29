import PKShared
import Foundation
import Logging

/// Standard PositronicKit logging subsystem for all host-independent loggers.
public enum PKLogSubsystem {
    public static let value = "com.positronickit"
}

public extension Logger {
    /// Returns a Logger with a stable, host-independent label in the `com.positronickit` subsystem.
    /// - Parameter name: The category name (e.g., "chat-engine", "retry-policy"). Use lowercase-dash format.
    /// - Returns: A Logger with label `com.positronickit.<name>`
    static func module(named name: String) -> Logger {
        Logger(label: "\(PKLogSubsystem.value).\(name)")
    }

    /// Creates a logger through an injected host policy.
    static func module(named name: String, configuration: LoggingConfiguration) -> Logger {
        configuration.logger(named: name)
    }
}
