import Foundation
import Logging

extension Logger {
    private static var subsystem: String {
        Bundle.main.bundleIdentifier ?? "com.monad.core"
    }

    /// Logs for a specific module
    public static func module(named name: String) -> Logger {
        Logger(label: "\(subsystem).\(name)")
    }
}
