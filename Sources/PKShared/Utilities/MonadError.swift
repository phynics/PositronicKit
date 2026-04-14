import ErrorKit
import Foundation

/// A standardized error protocol for MonadCore that extends ErrorKit.Throwable.
/// Provides machine-readable identifiers (domain and code) for consistent error handling.
public protocol MonadError: Throwable {
    /// The error domain identifying the module where the error originated.
    var errorDomain: String { get }

    /// A unique integer code for the specific error case within the domain.
    var errorCode: Int { get }
}

public extension MonadError {
    /// Default technical description that includes domain and code for better traceability.
    var errorDescription: String? {
        "[\(errorDomain):\(errorCode)] \(userFriendlyMessage)"
    }
}

/// Common error domains for MonadCore modules.
public enum MonadErrorDomain {
    public static let shared = "com.monad.shared"
    public static let client = "com.monad.client"
    public static let server = "com.monad.server"
    public static let llm = "com.monad.core.llm"
    public static let context = "com.monad.core.context"
    public static let workspace = "com.monad.core.workspace"
    public static let pipeline = "com.monad.core.pipeline"
    public static let agent = "com.monad.core.agent"
    public static let timeline = "com.monad.core.timeline"
    public static let vector = "com.monad.core.vector"
    public static let embedding = "com.monad.core.embedding"
    public static let chat = "com.monad.core.chat"
    public static let tool = "com.monad.core.tool"
    public static let persistence = "com.monad.core.persistence"
    public static let rpc = "com.monad.core.rpc"
    public static let filesystem = "com.monad.core.filesystem"
}
