import Logging

public extension Pipeline {
    /// Sets a `swift-log` Logger on the pipeline and returns a new pipeline instance.
    /// - Parameter logger: The logger to use.
    /// - Returns: A new pipeline instance that logs via the provided Logger.
    func withLogger(_ logger: Logger) -> Pipeline<Context, Event> {
        withLogHandler { level, message in
            switch level {
            case .debug: logger.debug("\(message)")
            case .error: logger.error("\(message)")
            }
        }
    }
}
