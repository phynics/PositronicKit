import ErrorKit
import Foundation
import PKShared
import PKUtilities

/// Wraps a foreign provider transport error that reached the turn loop without a
/// `PKError` domain/code, so callers can classify turn failures by structured error
/// identity (`errorDomain` + `errorCode`) instead of sniffing message substrings or
/// `localizedDescription`.
///
/// This is the loop's single wrapping seam for *unannotated* provider failures: errors
/// that already conform to `PKError` (e.g. `ChatEngineError.streamTimedOut`,
/// `LLMServiceError`, `ToolError`) and `CancellationError` pass through
/// `wrapForeignError(_:)` unchanged, preserving their existing identity. Only fully
/// foreign errors (e.g. `URLError`, `NSError`, `DecodingError` thrown by a provider
/// stream) are wrapped here, carrying the original as the underlying cause per ErrorKit
/// conventions (mirroring `PipelineError`'s `underlyingError` pattern).
///
/// The wrapped error typically lands as the `underlyingError` of a
/// `PipelineError.stageFailed` (the pipeline re-wraps whatever a stage throws), so its
/// `userFriendlyMessage` is surfaced via `PipelineError.userFriendlyMessage` and its
/// domain/code is reachable for anyone digging into the pipeline error's cause.
enum LLMStreamError: PKError {
    /// A foreign (non-`PKError`, non-cancellation) error thrown by the LLM stream.
    case providerStreamFailed(underlying: Error)

    var errorDomain: String {
        PKErrorDomain.llm
    }

    var errorCode: Int {
        1005
    }

    var userFriendlyMessage: String {
        switch self {
        case let .providerStreamFailed(underlying):
            return "The model stream failed: \(ErrorKit.userFriendlyMessage(for: underlying)). Please try again."
        }
    }

    /// The original foreign error, preserved as the underlying cause.
    var underlyingError: Error {
        switch self {
        case let .providerStreamFailed(underlying):
            return underlying
        }
    }
}

extension LLMStreamError: CausalError {
    var underlyingCauses: [Error] {
        switch self {
        case let .providerStreamFailed(underlying):
            return [underlying]
        }
    }
}

/// Wraps a foreign error so it carries a `PKError` domain/code, without changing the
/// observable identity of errors that already conform to `PKError` or are a
/// `CancellationError`.
///
/// - Returns: `error` unchanged if it already conforms to `PKError` or is a
///   `CancellationError`; otherwise an `LLMStreamError.providerStreamFailed` carrying
///   the original as the underlying cause.
func wrapForeignError(_ error: Error) -> Error {
    if error is CancellationError { return error }
    if error is any PKError { return error }
    return LLMStreamError.providerStreamFailed(underlying: error)
}
