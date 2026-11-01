import PositronicKit

func describe(_ outcome: TurnOutcome) -> String {
    switch outcome {
    case .completed:
        "completed"
    case .failed(let message):
        message
    case .cancelled(let reason):
        reason ?? "cancelled"
    case .interrupted(let reason):
        reason
    #if TURN_OUTCOME_UNKNOWN_DEFAULT
    @unknown default:
        "future outcome"
    #endif
    }
}

print(describe(.completed))
