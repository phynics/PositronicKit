import Logging

package extension Pipeline {
    /// Sets a `swift-log` Logger on the pipeline and returns a new pipeline instance.
    /// - Parameter logger: The logger to use.
    /// - Returns: A new pipeline instance that logs via the provided Logger.
    func withLogger(_ logger: Logger) -> Pipeline<Context, Event> {
        withLogHandler { level, message, metadata in
            var logMetadata = Logger.Metadata()
            for (key, value) in metadata {
                logMetadata[key] = .string(value)
            }

            switch level {
            case .trace:
                logger.trace("\(message)", metadata: logMetadata)
            case .debug:
                logger.debug("\(message)", metadata: logMetadata)
            case .info:
                logger.info("\(message)", metadata: logMetadata)
            case .notice:
                logger.notice("\(message)", metadata: logMetadata)
            case .warning:
                logger.warning("\(message)", metadata: logMetadata)
            case .error:
                logger.error("\(message)", metadata: logMetadata)
            case .critical:
                logger.critical("\(message)", metadata: logMetadata)
            }
        }
    }
}
