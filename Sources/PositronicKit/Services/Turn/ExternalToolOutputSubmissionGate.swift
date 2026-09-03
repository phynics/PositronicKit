import Foundation
import PKContracts

// MARK: - External Tool Output Submission Gate

/// Runtime-scoped guard against duplicate external tool-output submission.
///
/// Reservations are keyed by `(threadID, toolCallId)` only, so this type must never be shared
/// across independent runtime instances — two `PositronicKit` instances constructed in one
/// process are documented to start independent histories, and a process-global gate would let
/// them contend over identical keys. `PositronicKit` owns exactly one instance per runtime
/// identity (see `PositronicKit.RuntimeState`) and threads it through
/// `TurnEngine.Dependencies`, the same way `TurnEventHub` is threaded through.
actor ExternalToolOutputSubmissionGate {
    private var reservedToolOutputs: Set<ReservedToolOutput> = []

    init() {}

    /// Validates that each tool output matches a pending assistant tool call and reserves the
    /// call ID — **without persisting**. Already-persisted outputs are skipped so a partially
    /// failed batch can be safely retried (resumable batch support).
    ///
    /// Self-cleaning: if a later output in `toolOutputs` fails validation, any earlier output in
    /// the same call already reserved is released before this throws, so a partially invalid
    /// batch never leaves phantom reservations the caller has no way to release (it never
    /// received them back).
    ///
    /// - Returns: The subset of `toolOutputs` that are validated and still need persistence.
    func validate(
        _ toolOutputs: [ToolOutputSubmission],
        threadID: UUID,
        inputMessageID: UUID? = nil,
        runtimeRepository: any ThreadRuntimeRepository
    ) async throws -> [ToolOutputSubmission] {
        guard !toolOutputs.isEmpty else { return [] }

        let existingMessages = try await runtimeRepository.fetchMessages(for: threadID)
        var pendingToolCallIds = Set<String>()

        // Only the latest uninterrupted assistant tool-call set is externally resumable.
        for message in existingMessages.sorted(by: { $0.timestamp < $1.timestamp }) {
            // Admission durably appends the current user input before preparation. That input is
            // part of the same request as these tool outputs and must not clear the pending call
            // set that precedes it; unrelated user messages still clear pending calls below.
            if message.id == inputMessageID { continue }
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
        do {
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
        } catch {
            for output in validated {
                reservedToolOutputs.remove(ReservedToolOutput(threadID: threadID, toolCallId: output.toolCallID))
            }
            throw error
        }

        return validated
    }

    /// Reserves `toolOutputs` via ``validate(_:threadID:inputMessageID:runtimeRepository:)`` and
    /// guarantees the reservation is released on every exit from `operation` — including a throw
    /// and cancellation — so the caller cannot strand it by abandoning the work between
    /// reservation and commit. `operation` remains responsible for calling
    /// ``commit(_:threadID:runtimeRepository:)`` itself on success; this only guards the failure
    /// and cancellation paths `operation` does not clean up on its own.
    ///
    /// This is the scope-bound alternative to a bare `validate` + `commit` pair. It fits call
    /// sites that can wrap their post-validation work in a single closure; a caller whose
    /// post-validation work spans multiple early-return branches (as `TurnEngine.prepareSession`
    /// does) instead keeps its own `do`/`catch` and reserve/release symmetry, since flattening
    /// that control flow into one closure would be a much larger, riskier change than this fix.
    func withReservation<T: Sendable>(
        _ toolOutputs: [ToolOutputSubmission],
        threadID: UUID,
        inputMessageID: UUID? = nil,
        runtimeRepository: any ThreadRuntimeRepository,
        operation: @Sendable (_ validated: [ToolOutputSubmission]) async throws -> T
    ) async throws -> T {
        let validated = try await validate(
            toolOutputs,
            threadID: threadID,
            inputMessageID: inputMessageID,
            runtimeRepository: runtimeRepository
        )
        // `operation` is not required to check cancellation itself, so a plain do/catch around it
        // would miss a cancellation that `operation` silently absorbs. The cancellation handler
        // releases synchronously with the calling task's cancellation instead of depending on
        // `operation` to notice and rethrow — the same pattern `TurnEventHub.awaitTerminal` uses
        // to resume a waiter from `onCancel` without an unstructured cleanup task owning the
        // resource itself. `releaseReservations` is idempotent, so a release from `onCancel`
        // racing a release already performed by `operation` (e.g. via `commit`) is harmless.
        return try await withTaskCancellationHandler {
            do {
                return try await operation(validated)
            } catch {
                releaseReservations(threadID: threadID, toolCallIds: validated.map(\.toolCallID))
                throw error
            }
        } onCancel: {
            Task { await self.releaseReservations(threadID: threadID, toolCallIds: validated.map(\.toolCallID)) }
        }
    }

    /// Persists validated tool output messages. Already-persisted outputs are skipped so a
    /// partially failed batch can be retried without duplication (resumable batch support).
    ///
    /// External output is intentionally message-only. The source Turn has already become terminal
    /// after external deferral, and `ToolOutputSubmission` does not carry its originating Turn ID;
    /// recording a `RuntimeToolResult` here would either attach it to the wrong Turn or reopen the
    /// terminal lifecycle. Runtime-local results use `ThreadRuntimeRepository`'s atomic result plus
    /// message boundary in `ToolRouter` instead.
    func commit(
        _ validatedOutputs: [ToolOutputSubmission],
        threadID: UUID,
        runtimeRepository: any ThreadRuntimeRepository
    ) async throws {
        guard !validatedOutputs.isEmpty else { return }

        // Re-check for already-persisted outputs — a prior partial batch may have persisted
        // some messages before failing.
        let existingMessages = try await runtimeRepository.fetchMessages(for: threadID)
        let persistedToolCallIds = Set(
            existingMessages
                .filter { $0.messageRole == .tool }
                .compactMap { $0.toolCallID }
        )

        for output in validatedOutputs {
            if persistedToolCallIds.contains(output.toolCallID) { continue }
            let msg = ThreadMessage(
                threadID: threadID,
                role: .tool,
                content: output.output,
                toolCallID: output.toolCallID
            )
            try await runtimeRepository.saveMessage(msg)
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
