import Foundation
import PKPrompt
import PKShared
import PKUtilities

/// Events emitted during the context gathering process
enum ContextGatheringEvent: Sendable {
    /// Indicates progress in the gathering process.
    case progress(Message.ContextGatheringProgress)
    /// Indicates the gathering process is complete with the final context data.
    case complete(ContextData)
}
