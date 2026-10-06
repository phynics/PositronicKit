import Foundation
import PKContracts

/// Validates a host-provided ``TurnHistoryProjection`` against the durable history and derives
/// the provider-facing replacement plus retained tail.
///
/// Validation is structural: the runtime rejects coverage it cannot apply without changing the
/// meaning of the Turn rather than silently dropping, reordering, or splitting history.
enum TurnHistoryProjectionValidator {
    struct Applied: Equatable {
        let replacement: String
        let retainedHistory: [Message]
    }

    static func apply(
        _ projection: TurnHistoryProjection,
        to history: [Message],
        currentInputID: UUID?
    ) throws -> Applied {
        guard !projection.coveredMessageIDs.isEmpty else {
            throw TurnHistoryProjectionError.emptyCoverage
        }
        guard projection.replacement.count <= TurnHistoryProjection.maximumReplacementCharacters else {
            throw TurnHistoryProjectionError.replacementTooLarge(
                limit: TurnHistoryProjection.maximumReplacementCharacters
            )
        }

        let indexByID = Dictionary(
            uniqueKeysWithValues: history.enumerated().map { ($0.element.id, $0.offset) }
        )

        for id in projection.coveredMessageIDs {
            if id == currentInputID {
                throw TurnHistoryProjectionError.coversCurrentInput(id)
            }
            guard indexByID[id] != nil else {
                throw TurnHistoryProjectionError.unknownMessageID(id)
            }
        }

        let coveredCount = projection.coveredMessageIDs.count
        guard coveredCount <= history.count else {
            throw TurnHistoryProjectionError.nonContiguousCoverage(
                expected: history.last?.id ?? projection.coveredMessageIDs[history.count],
                actual: projection.coveredMessageIDs[history.count]
            )
        }

        // Coverage must be the contiguous prefix of the offered history.
        for offset in 0..<coveredCount {
            let expected = history[offset].id
            let actual = projection.coveredMessageIDs[offset]
            guard actual == expected else {
                throw TurnHistoryProjectionError.nonContiguousCoverage(expected: expected, actual: actual)
            }
        }

        let expectedFirstRetained = coveredCount < history.count ? history[coveredCount].id : nil
        guard projection.firstRetainedMessageID == expectedFirstRetained else {
            throw TurnHistoryProjectionError.firstRetainedMismatch(
                expected: expectedFirstRetained,
                actual: projection.firstRetainedMessageID
            )
        }

        // Coverage must end at a tool-transaction boundary: no assistant tool call may lose its
        // result, and no tool result may lose its call.
        if let dangling = danglingToolMessageID(in: Array(history.prefix(coveredCount))) {
            throw TurnHistoryProjectionError.splitToolTransaction(messageID: dangling)
        }

        return Applied(
            replacement: projection.replacement,
            retainedHistory: Array(history.dropFirst(coveredCount))
        )
    }

    /// Returns the ID of a message that leaves a tool transaction open at the end of `messages`,
    /// or `nil` when the prefix ends on a transaction boundary.
    private static func danglingToolMessageID(in messages: [Message]) -> UUID? {
        var pending: [String: UUID] = [:]
        for message in messages {
            switch message.role {
            case .assistant:
                if let open = pending.values.min(by: { $0.uuidString < $1.uuidString }) {
                    return open
                }
                for call in message.toolCalls ?? [] {
                    pending[call.id] = message.id
                }
            case .tool:
                guard let toolCallID = message.toolCallID, pending.removeValue(forKey: toolCallID) != nil else {
                    return message.id
                }
            case .user, .system, .summary:
                if let open = pending.values.min(by: { $0.uuidString < $1.uuidString }) {
                    return open
                }
            }
        }
        return pending.values.min(by: { $0.uuidString < $1.uuidString })
    }
}
