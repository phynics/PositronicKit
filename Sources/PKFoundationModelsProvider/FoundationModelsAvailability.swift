import Foundation
import PKContracts
import PKUtilities

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Typed, user-friendly surfacing of `SystemLanguageModel.availability` (PKPOST-003).
///
/// Apple Intelligence can be unavailable for several distinct reasons (device ineligible,
/// feature disabled by the user, or the model assets not yet downloaded). Each is mapped to
/// its own case so callers/UI can give reason-specific guidance rather than a single generic
/// "unavailable" message — and so this never surfaces as a crash or a silently empty stream.
public enum FoundationModelsAvailabilityError: PKError, Equatable {
    /// The current device does not support Apple Intelligence (e.g. no Apple Silicon /
    /// insufficient RAM tier).
    case deviceNotEligible
    /// Apple Intelligence is supported by the device but has not been turned on by the user.
    case appleIntelligenceNotEnabled
    /// Apple Intelligence is enabled but the on-device model assets are still downloading /
    /// otherwise not ready yet.
    case modelNotReady
    /// The framework reported an unavailable reason this adapter does not yet recognize.
    /// Preserves the raw description rather than losing the information.
    case unknown(String)

    public var errorDomain: String {
        PKErrorDomain.llm
    }

    public var errorCode: Int {
        switch self {
        case .deviceNotEligible: return 2001
        case .appleIntelligenceNotEnabled: return 2002
        case .modelNotReady: return 2003
        case .unknown: return 2004
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case .deviceNotEligible:
            return "This device does not support Apple Intelligence, so the on-device model is unavailable."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is turned off. Enable it in System Settings > Apple Intelligence & Siri to use the on-device model."
        case .modelNotReady:
            return "The on-device model is still preparing (downloading assets or otherwise not ready). Try again shortly."
        case let .unknown(reason):
            return "The on-device model is unavailable: \(reason)"
        }
    }

    public var remediation: String? {
        switch self {
        case .deviceNotEligible:
            return "Use a different provider on this device; on-device Apple Intelligence is not supported here."
        case .appleIntelligenceNotEnabled:
            return "Open System Settings > Apple Intelligence & Siri and enable Apple Intelligence, then retry."
        case .modelNotReady:
            return "Wait for the on-device model to finish preparing and retry."
        case .unknown:
            return nil
        }
    }
}

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    extension FoundationModelsAvailabilityError {
        /// Maps `SystemLanguageModel.Availability` onto the typed error vocabulary above.
        /// Returns `nil` when the model is available (no error to surface).
        init?(availability: SystemLanguageModel.Availability) {
            switch availability {
            case .available:
                return nil
            case let .unavailable(reason):
                switch reason {
                case .deviceNotEligible:
                    self = .deviceNotEligible
                case .appleIntelligenceNotEnabled:
                    self = .appleIntelligenceNotEnabled
                case .modelNotReady:
                    self = .modelNotReady
                @unknown default:
                    self = .unknown(String(describing: reason))
                }
            }
        }
    }
#endif
