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

    /// Whether this error represents a "blocked"/approval/disallowed condition — i.e. a
    /// failure that is *not* the model's or provider's fault but the result of a deliberate
    /// permission or access gate refusing execution. Consumers classify these as a `.blocked`
    /// timeline state rather than `.failed`. Default: `false`. Override on error cases that
    /// represent blocked conditions (e.g. `ToolError.permissionDenied`,
    /// `PathError.accessDenied`, `WorkspaceError.accessDenied`).
    var isBlocked: Bool { get }
}

public extension PKError {
    /// Default: no remediation guidance.
    var remediation: String? {
        nil
    }

    /// Default: not a blocked condition.
    var isBlocked: Bool {
        false
    }

    /// Default technical description that includes domain and code for better traceability.
    var errorDescription: String? {
        "[\(errorDomain):\(errorCode)] \(userFriendlyMessage)"
    }
}

/// An error that wraps one or more underlying causes, enabling
/// `ErrorIdentity` to traverse the causal chain and extract the root
/// ``PKError`` identity rather than the wrapper's (PKRR-014).
///
/// Conform wrapper types that carry an `underlyingError` to this protocol so
/// `ErrorIdentity.extracting(from:)` can see through the wrapper to the root
/// cause. Generic wrappers whose own `PKError` identity is orchestration context
/// rather than the root cause (e.g. `PipelineError`) should override
/// `usesOwnIdentityAsFallback` to `false`.
public protocol CausalError: Error {
    /// The underlying error(s) that this error wraps, ordered by significance
    /// (primary cause first). `ErrorIdentity.extracting` traverses these to find
    /// the root `PKError` identity.
    var underlyingCauses: [Error] { get }

    /// Whether `ErrorIdentity.extracting` should fall back to this error's own
    /// `PKError` identity when no `PKError` is found in the causal chain.
    ///
    /// Defaults to `true` — purpose-built wrappers like `LLMStreamError` provide
    /// a stable identity for the foreign errors they wrap, so their own identity
    /// IS the useful classification. Generic wrappers like `PipelineError` should
    /// override to `false` — their identity (stage failure code) is orchestration
    /// context, not the root cause.
    var usesOwnIdentityAsFallback: Bool { get }
}

public extension CausalError {
    var usesOwnIdentityAsFallback: Bool { true }
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
    public static let utilities = "com.positronickit.utilities"
}
