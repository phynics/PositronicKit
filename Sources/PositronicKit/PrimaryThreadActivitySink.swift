import Foundation
import Logging
import PKContracts
import PKUtilities

struct AgentActivityFanout: AgentActivitySink {
    let sinks: [any AgentActivitySink]

    func record(_ activity: AgentActivity) async throws {
        for sink in sinks {
            try await sink.record(activity)
        }
    }
}

enum PrimaryThreadActivityOutcome: Codable, Sendable, Equatable, Hashable {
    case succeeded(output: String)
    case failed(output: String, error: String)
    case persistenceFailed(error: String)

    private enum CodingKeys: String, CodingKey { case kind, output, error }
    private enum Kind: String, Codable { case succeeded, failed, persistenceFailed }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .succeeded(output):
            try container.encode(Kind.succeeded, forKey: .kind)
            try container.encode(output, forKey: .output)
        case let .failed(output, error):
            try container.encode(Kind.failed, forKey: .kind)
            try container.encode(output, forKey: .output)
            try container.encode(error, forKey: .error)
        case let .persistenceFailed(error):
            try container.encode(Kind.persistenceFailed, forKey: .kind)
            try container.encode(error, forKey: .error)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .succeeded:
            self = .succeeded(output: try container.decode(String.self, forKey: .output))
        case .failed:
            self = .failed(
                output: try container.decode(String.self, forKey: .output),
                error: try container.decode(String.self, forKey: .error)
            )
        case .persistenceFailed:
            self = .persistenceFailed(error: try container.decode(String.self, forKey: .error))
        }
    }
}

protocol PrimaryThreadPairAppending: Sendable {
    /// Appends the assistant/tool projection as one idempotent transition. Implementations must
    /// leave both rows unchanged when validation or persistence fails.
    func appendPrimaryThreadPair(assistant: ThreadMessage, tool: ThreadMessage) async throws
}

struct PrimaryThreadActivity: Sendable {
    let callID: String
    let name: String
    let argumentsJSON: String
    let sourceThreadID: UUID
    let privateThreadID: UUID
    let turnID: UUID
    let requestID: UUID
    let agentID: UUID
    let modelRoundIndex: Int
    let workspaceID: UUID
    let routing: WorkspaceToolRouting
    let outcome: PrimaryThreadActivityOutcome
}

protocol PrimaryThreadActivityRecording: Sendable {
    func record(_ activity: PrimaryThreadActivity) async
}

/// Internal evaluation sink for mirroring resolved primary-Workspace activity into an Agent's
/// private Thread. It is not part of the public customization surface.
actor PrimaryThreadActivitySink: PrimaryThreadActivityRecording {
    private static let maximumQueuedActivitiesPerThread = 256
    private static let maximumProjectedTextCharacters = 16_384
    private static let pollNanoseconds: UInt64 = 10_000_000

    private let agentStore: any AgentStoreProtocol
    private let pairStore: any PrimaryThreadPairAppending
    private let runtimeRepository: any ThreadRuntimeRepository
    private let threadAuthorityCoordinator: ThreadAuthorityCoordinator
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let logger: Logger

    private var pending: [UUID: [PrimaryThreadActivity]] = [:]
    private var queuedKeys: Set<String> = []
    private var completedKeys: [String: Date] = [:]
    private var drainingThreads: Set<UUID> = []
    private var drainTasks: [UUID: Task<Void, Never>] = [:] // swiftlint:disable:this concurrency_stored_task -- actor-owned drain cancellation (see docs/Concurrency/exception-manifest.md)
    private static let maximumCompletedKeys = 2_048
    private static let maximumIdlePolls = 6_000

    init(
        agentStore: any AgentStoreProtocol,
        pairStore: any PrimaryThreadPairAppending,
        runtimeRepository: any ThreadRuntimeRepository,
        threadAuthorityCoordinator: ThreadAuthorityCoordinator,
        loggingConfiguration: LoggingConfiguration,
        sleep: (@Sendable (UInt64) async throws -> Void)? = nil
    ) {
        self.agentStore = agentStore
        self.pairStore = pairStore
        self.runtimeRepository = runtimeRepository
        self.threadAuthorityCoordinator = threadAuthorityCoordinator
        self.sleep = sleep ?? { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
        logger = loggingConfiguration.logger(named: "primary-thread-activity")
    }

    /// Enqueues and returns immediately. The projector's queue and persistence failures are
    /// intentionally isolated from the originating Turn.
    func record(_ activity: PrimaryThreadActivity) async {
        guard activity.sourceThreadID != activity.privateThreadID else {
            // The private Thread is the projection target and never mirrors its own activity.
            return
        }

        let key = projectionKey(for: activity)
        guard !queuedKeys.contains(key), completedKeys[key] == nil else { return }

        var activities = pending[activity.privateThreadID, default: []]
        guard activities.count < Self.maximumQueuedActivitiesPerThread else {
            logger.warning("Primary Thread activity queue is full; dropping projection")
            return
        }
        activities.append(activity)
        pending[activity.privateThreadID] = activities
        queuedKeys.insert(key)

        if drainingThreads.insert(activity.privateThreadID).inserted {
            let task = Task { [weak self] in
                guard let self else { return }
                await self.drain(threadID: activity.privateThreadID)
            }
            drainTasks[activity.privateThreadID] = task
        }
    }

    private func drain(threadID: UUID) async {
        while true {
            guard var activities = pending[threadID], !activities.isEmpty else {
                pending[threadID] = nil
                drainingThreads.remove(threadID)
                drainTasks.removeValue(forKey: threadID)
                return
            }
            let activity = activities.removeFirst()
            pending[threadID] = activities
            let key = projectionKey(for: activity)

            do {
                guard let agent = try? await agentStore.fetchAgent(id: activity.agentID),
                      agent.privateThreadID == threadID,
                      agent.primaryWorkspaceID == activity.workspaceID
                else {
                    queuedKeys.remove(key)
                    continue
                }
                try await projectWhenIdle(activity, into: threadID)
                completedKeys[key] = Date()
                trimCompletedKeys()
            } catch is CancellationError {
                // A cancelled projector task is best-effort; discard only this queued item.
            } catch {
                logger.error("Primary Thread activity projection failed")
            }
            queuedKeys.remove(key)
        }
    }

    private func projectWhenIdle(_ activity: PrimaryThreadActivity, into threadID: UUID) async throws {
        var polls = 0
        while true {
            try Task.checkCancellation()
            guard polls < Self.maximumIdlePolls else { throw CancellationError() }
            if try await runtimeRepository.fetchActiveTurn(for: threadID) == nil {
                let committed = try await threadAuthorityCoordinator.withThread(threadID) {
                    guard try await self.runtimeRepository.fetchActiveTurn(for: threadID) == nil else {
                        return false
                    }
                    try await self.project(activity, into: threadID)
                    return true
                }
                if committed { return }
            }
            polls += 1
            try await sleep(Self.pollNanoseconds)
        }
    }

    private func project(_ activity: PrimaryThreadActivity, into threadID: UUID) async throws {
        let payload = activity
        let arguments = (try? JSONDecoder().decode(
            [String: AnyCodable].self,
            from: Data(payload.argumentsJSON.utf8)
        )) ?? [:]
        let toolCall = ToolCall(id: payload.callID, name: payload.name, arguments: arguments)
        let toolCalls = try JSONEncoder().encode([toolCall])
        let provenance = PrimaryThreadProjectionProvenance(
            key: projectionKey(for: activity),
            phase: .assistant,
            sourceThreadID: payload.sourceThreadID,
            sourceTurnID: payload.turnID,
            sourceRequestID: payload.requestID,
            agentID: payload.agentID,
            modelRoundIndex: payload.modelRoundIndex,
            workspaceID: payload.workspaceID,
            routing: payload.routing,
            callID: payload.callID,
            name: payload.name,
            outcome: payload.outcome
        )
        let assistantID = deterministicMessageID(for: projectionKey(for: activity) + ":assistant")
        let toolID = deterministicMessageID(for: projectionKey(for: activity) + ":tool")
        var assistant = ThreadMessage(
            id: assistantID,
            threadID: threadID,
            role: .assistant,
            content: "",
            parentID: nil,
            toolCalls: String(decoding: toolCalls, as: UTF8.self),
            agentID: payload.agentID,
            executionKind: .agentManaged,
            snapshotData: try JSONEncoder().encode(provenance)
        )
        assistant.status = .complete

        let toolProvenance = provenance.withPhase(.tool)
        let tool = ThreadMessage(
            id: toolID,
            threadID: threadID,
            role: .tool,
            content: projectedOutput(for: payload.outcome),
            parentID: assistantID,
            toolCallID: payload.callID,
            agentID: payload.agentID,
            executionKind: .agentManaged,
            snapshotData: try JSONEncoder().encode(toolProvenance)
        )

        try await appendPairWithRetry(assistant: assistant, tool: tool)
    }

    private func projectionKey(for activity: PrimaryThreadActivity) -> String {
        return "\(activity.turnID.uuidString):\(activity.modelRoundIndex):\(activity.callID)"
    }

    private func projectedOutput(for outcome: PrimaryThreadActivityOutcome) -> String {
        let output: String
        switch outcome {
        case let .succeeded(value): output = value
        case let .failed(value, error): output = value.isEmpty ? "Error: \(error)" : value
        case let .persistenceFailed(error): output = "Projection source persistence failed: \(error)"
        }
        return bounded(output)
    }

    private func appendPairWithRetry(assistant: ThreadMessage, tool: ThreadMessage) async throws {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                try await pairStore.appendPrimaryThreadPair(assistant: assistant, tool: tool)
                return
            } catch {
                attempt += 1
                guard attempt < 3 else { throw error }
                try await sleep(Self.pollNanoseconds * UInt64(attempt * 10))
            }
        }
    }

    private func trimCompletedKeys() {
        guard completedKeys.count > Self.maximumCompletedKeys else { return }
        let overflow = completedKeys.count - Self.maximumCompletedKeys
        for key in completedKeys.sorted(by: { $0.value < $1.value }).prefix(overflow).map(\.key) {
            completedKeys.removeValue(forKey: key)
        }
    }

    private func bounded(_ value: String) -> String {
        guard value.count > Self.maximumProjectedTextCharacters else { return value }
        let end = value.index(value.startIndex, offsetBy: Self.maximumProjectedTextCharacters)
        return String(value[..<end]) + "\n[primary-Thread projection truncated]"
    }

    private func deterministicMessageID(for key: String) -> UUID {
        var high: UInt64 = 0xcbf29ce484222325
        var low: UInt64 = 0x84222325cbf29ce4
        for byte in key.utf8 {
            high ^= UInt64(byte)
            high &*= 0x100000001b3
            low ^= UInt64(byte) &+ high
            low &*= 0x100000001b3
        }
        let bytes: [UInt8] = [
            UInt8(high >> 56), UInt8(high >> 48), UInt8(high >> 40), UInt8(high >> 32),
            UInt8(high >> 24), UInt8(high >> 16), UInt8(high >> 8), UInt8(high),
            UInt8(low >> 56), UInt8(low >> 48), UInt8(low >> 40), UInt8(low >> 32),
            UInt8(low >> 24), UInt8(low >> 16), UInt8(low >> 8), UInt8(low),
        ]
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    deinit {
        for task in drainTasks.values { task.cancel() }
    }
}

private struct PrimaryThreadProjectionProvenance: Codable, Equatable, Hashable, Sendable {
    enum Phase: String, Codable, Hashable, Sendable { case assistant, tool }

    let key: String
    let phase: Phase
    let sourceThreadID: UUID
    let sourceTurnID: UUID
    let sourceRequestID: UUID
    let agentID: UUID
    let modelRoundIndex: Int
    let workspaceID: UUID
    let routing: WorkspaceToolRouting
    let callID: String
    let name: String
    let outcome: PrimaryThreadActivityOutcome

    func withPhase(_ phase: Phase) -> PrimaryThreadProjectionProvenance {
        PrimaryThreadProjectionProvenance(
            key: key,
            phase: phase,
            sourceThreadID: sourceThreadID,
            sourceTurnID: sourceTurnID,
            sourceRequestID: sourceRequestID,
            agentID: agentID,
            modelRoundIndex: modelRoundIndex,
            workspaceID: workspaceID,
            routing: routing,
            callID: callID,
            name: name,
            outcome: outcome
        )
    }
}
