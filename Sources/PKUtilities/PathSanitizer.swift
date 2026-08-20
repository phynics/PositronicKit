import PKContracts
import Foundation
import ErrorKit

/// Utility to safely resolve paths within a jail directory
package enum PathSanitizer {
    /// Errors related to path sanitization
    package enum PathError: PKError {
        case accessDenied(String)
        case invalidPath(String)

        package var errorDomain: String { PKErrorDomain.filesystem }

        package var errorCode: Int {
            switch self {
            case .accessDenied: return 101
            case .invalidPath: return 102
            }
        }

        /// `accessDenied` represents a blocked/disallowed condition — the path is
        /// outside the allowed directory, so execution is refused by an access gate.
        package var isBlocked: Bool {
            switch self {
            case .accessDenied: return true
            case .invalidPath: return false
            }
        }

        package var userFriendlyMessage: String {
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
    package static func safelyResolve(
        path pathString: String,
        within currentDirectory: String,
        jailRoot: String
    ) throws -> URL {
        let rootURL = canonicalURL(forPath: jailRoot)
        let currentURL = canonicalURL(forPath: currentDirectory)

        guard isContained(currentURL, in: rootURL) else {
            throw PathError.accessDenied("Current directory '\(currentDirectory)' is outside jail root.")
        }

        let resolvedURL: URL
        if pathString.hasPrefix("/") {
            resolvedURL = URL(fileURLWithPath: pathString).standardized
        } else if pathString.hasPrefix("~") {
            resolvedURL = URL(fileURLWithPath: (pathString as NSString).expandingTildeInPath).standardized
        } else {
            resolvedURL = currentURL.appendingPathComponent(pathString).standardized
        }

        let canonicalResolvedURL = canonicalURL(forURL: resolvedURL)
        guard isContained(canonicalResolvedURL, in: rootURL) else {
            throw PathError.accessDenied(pathString)
        }

        return canonicalResolvedURL
    }

    /// Legacy alias for safelyResolve(path:within:jailRoot:) where currentDirectory == jailRoot
    package static func safelyResolve(path pathString: String, within root: String) throws -> URL {
        return try safelyResolve(path: pathString, within: root, jailRoot: root)
    }

    private static func canonicalURL(forPath path: String) -> URL {
        canonicalURL(forURL: URL(fileURLWithPath: path))
    }

    private static func canonicalURL(forURL url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents

        guard candidateComponents.count >= rootComponents.count else {
            return false
        }

        return zip(rootComponents, candidateComponents).allSatisfy(==)
    }
}
