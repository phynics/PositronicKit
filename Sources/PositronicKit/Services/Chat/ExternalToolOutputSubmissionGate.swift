import Foundation
import PKShared

// MARK: - External Tool Output Submission Gate

actor ExternalToolOutputSubmissionGate {
    static let shared = ExternalToolOutputSubmissionGate()

    private var reservedToolOutputs: Set<ReservedToolOutput> = []

    private init() {}

    /// Validates that each tool output matches a pending assistant tool call and reserves the
    /// call ID — **without persisting**. Already-persisted outputs are skipped so a partially
    /// failed batch can be safely retried (resumable batch support).
    ///
    /// - Returns: The subset of `toolOutputs` that are validated and still need persistence.
    func validate(
        _ toolOutputs: [ToolOutputSubmission],
        threadID: UUID,
        messageStore: any MessageStoreProtocol
    ) async throws -> [ToolOutputSubmission] {
        guard !toolOutputs.isEmpty else { return [] }

        let existingMessages = try await messageStore.fetchMessages(for: threadID)
        var pendingToolCallIds = Set<String>()

        // Only the latest uninterrupted assistant tool-call set is externally resumable.
        for message in existingMessages.sorted(by: { $0.timestamp < $1.timestamp }) {
            switch message.messageRole {
            case .assistant:
                pendingToolCallIds = Set(Self.decodeToolCalls(from: message.toolCalls).map(\.id))
            case .tool:
                if let toolCallID = message.toolCallID {
                    pendingToolCallIds.remove(toolCallID)
                }
            case .user, .system, .summary:
                pendingToolCallIds.removeAll()
            }
        }

        // Remove call IDs already reserved by concurrent submissions.
        for reservation in reservedToolOutputs where reservation.threadID == threadID {
            pendingToolCallIds.remove(reservation.toolCallId)
        }

        // Track already-persisted tool call IDs for resumable batch support.
        let persistedToolCallIds = Set(
            existingMessages
                .filter { $0.messageRole == .tool }
                .compactMap { $0.toolCallID }
        )

        var validated: [ToolOutputSubmission] = []
        for output in toolOutputs {
            // Skip outputs already persisted by a previous (partial) batch.
            if persistedToolCallIds.contains(output.toolCallID) {
                continue
            }
            guard pendingToolCallIds.remove(output.toolCallID) != nil else {
                throw ToolError.unmatchedToolOutput(output.toolCallID)
            }
            let reservation = ReservedToolOutput(threadID: threadID, toolCallId: output.toolCallID)
            reservedToolOutputs.insert(reservation)
            validated.append(output)
        }

        return validated
    }

    /// Persists validated tool output messages. Already-persisted outputs are skipped so a
    /// partially failed batch can be retried without duplication (resumable batch support).
    func commit(
        _ validatedOutputs: [ToolOutputSubmission],
        threadID: UUID,
        messageStore: any MessageStoreProtocol
    ) async throws {
        guard !validatedOutputs.isEmpty else { return }

        // Re-check for already-persisted outputs — a prior partial batch may have persisted
        // some messages before failing.
        let existingMessages = try await messageStore.fetchMessages(for: threadID)
        let persistedToolCallIds = Set(
            existingMessages
                .filter { $0.messageRole == .tool }
                .compactMap { $0.toolCallID }
        )

        for output in validatedOutputs {
            if persistedToolCallIds.contains(output.toolCallID) { continue }
            let msg = ConversationMessage(
                threadID: threadID,
                role: .tool,
                content: output.output,
                toolCallID: output.toolCallID
            )
            try await messageStore.saveMessage(msg)
        }

        // Release reservations for all validated outputs (persisted or already-present).
        for output in validatedOutputs {
            reservedToolOutputs.remove(ReservedToolOutput(threadID: threadID, toolCallId: output.toolCallID))
        }
    }

    /// Releases reservations for the specified tool call IDs (on preparation failure).
    func releaseReservations(threadID: UUID, toolCallIds: [String]) {
        for toolCallId in toolCallIds {
            reservedToolOutputs.remove(ReservedToolOutput(threadID: threadID, toolCallId: toolCallId))
        }
    }

    private static func decodeToolCalls(from json: String) -> [ToolCall] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? SerializationUtils.jsonDecoder.decode([ToolCall].self, from: data)) ?? []
    }
}

private struct ReservedToolOutput: Hashable {
    let threadID: UUID
    let toolCallId: String
}
