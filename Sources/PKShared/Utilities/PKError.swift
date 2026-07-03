import ErrorKit
import Foundation

/// A standardized error protocol for PositronicKit that extends ErrorKit.Throwable.
/// Provides machine-readable identifiers (domain and code) for consistent error handling.
public protocol PKError: Throwable {
    /// The error domain identifying the module where the error originated.
    var errorDomain: String { get }

    /// A unique integer code for the specific error case within the domain.
    var errorCode: Int { get }

    /// An optional, model/user-facing suggested action to resolve the error. Surfaced back to
    /// the LLM alongside `userFriendlyMessage` when a tool call fails, so keep it actionable and
    /// second-person (what the caller should do next), not developer-facing. Default: `nil`.
    var remediation: String? { get }
}

public extension PKError {
    /// Default: no remediation guidance.
    var remediation: String? {
        nil
    }

    /// Default technical description that includes domain and code for better traceability.
    var errorDescription: String? {
        "[\(errorDomain):\(errorCode)] \(userFriendlyMessage)"
    }
}

/// Common error domains for PositronicKit modules.
public enum PKErrorDomain {
    public static let shared = "com.positronickit.shared"
    public static let prompt = "com.positronickit.core.prompt"
    public static let client = "com.positronickit.client"
    public static let runtime = "com.positronickit.runtime"
    public static let llm = "com.positronickit.core.llm"
    public static let context = "com.positronickit.core.context"
    public static let workspace = "com.positronickit.core.workspace"
    public static let pipeline = "com.positronickit.core.pipeline"
    public static let agent = "com.positronickit.core.agent"
    public static let timeline = "com.positronickit.core.timeline"
    public static let vector = "com.positronickit.core.vector"
    public static let embedding = "com.positronickit.core.embedding"
    public static let chat = "com.positronickit.core.chat"
    public static let tool = "com.positronickit.core.tool"
    public static let persistence = "com.positronickit.core.persistence"
    public static let rpc = "com.positronickit.core.rpc"
    public static let filesystem = "com.positronickit.core.filesystem"
}
