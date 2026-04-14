import Foundation
import ErrorKit

/// Utility to safely resolve paths within a jail directory
public enum PathSanitizer {
    /// Errors related to path sanitization
    public enum PathError: MonadError {
        case accessDenied(String)
        case invalidPath(String)

        public var errorDomain: String { MonadErrorDomain.filesystem }

        public var errorCode: Int {
            switch self {
            case .accessDenied: return 101
            case .invalidPath: return 102
            }
        }

        public var userFriendlyMessage: String {
            switch self {
            case .accessDenied:
                return "Access denied. The requested path is outside the allowed directory."
            case .invalidPath(let path):
                return "The path '\(path)' is invalid."
            }
        }
    }

    /// Safely resolves a path string relative to a current directory, ensuring it remains within a jail root.
    /// - Parameters:
    ///   - pathString: The path provided by the user/tool (can be absolute or relative)
    ///   - currentDirectory: The absolute path to the current working directory
    ///   - jailRoot: The absolute path to the jail root
    /// - Returns: A standardized URL within the jail root
    /// - Throws: PathError if the resolved path is outside the jail root
    public static func safelyResolve(
        path pathString: String,
        within currentDirectory: String,
        jailRoot: String
    ) throws -> URL {
        let rootURL = URL(fileURLWithPath: jailRoot).standardized
        let currentURL = URL(fileURLWithPath: currentDirectory).standardized

        // Sanity check: currentDirectory must be within jailRoot
        guard currentURL.path.hasPrefix(rootURL.path) else {
            throw PathError.accessDenied("Current directory '\(currentDirectory)' is outside jail root.")
        }

        let resolvedURL: URL
        if pathString.hasPrefix("/") {
            // Treat absolute paths as relative to jail root if they don't start with jail root?
            // Actually, if a tool provides an absolute path, it MUST start with jail root.
            resolvedURL = URL(fileURLWithPath: pathString).standardized
        } else if pathString.hasPrefix("~") {
            // Tilde expansion usually goes to home, which is likely outside jail.
            // For now, let's treat ~ as jail root? Or just disallow.
            // Let's resolve it then check.
            resolvedURL = URL(fileURLWithPath: (pathString as NSString).expandingTildeInPath).standardized
        } else {
            resolvedURL = currentURL.appendingPathComponent(pathString).standardized
        }

        // Ensure the resolved path starts with the root path
        guard resolvedURL.path.hasPrefix(rootURL.path) else {
            throw PathError.accessDenied(pathString)
        }

        return resolvedURL
    }

    /// Legacy alias for safelyResolve(path:within:jailRoot:) where currentDirectory == jailRoot
    public static func safelyResolve(path pathString: String, within root: String) throws -> URL {
        return try safelyResolve(path: pathString, within: root, jailRoot: root)
    }
}
