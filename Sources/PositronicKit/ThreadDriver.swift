import Foundation
import PKContracts

/// A lightweight, stable handle for sending to and cancelling work on exactly one durable
/// ``Thread``.
///
/// `ThreadHandle` holds no mutable turn state, does not perform persistence lookups on
/// construction, and does not expose the underlying coordinator. Opening a handle via
/// `PositronicKit.openThread(_:)` is pure value construction — persistence happens lazily,
/// the first time `send(_:)` actually executes a turn, exactly as it always has for the
/// underlying turn-engine path.
public struct ThreadHandle: Identifiable, Sendable {
    /// The persisted Thread this handle sends to and cancels work for.
    public let threadID: UUID

    /// Stable identity; equal to `threadID`.
    public var id: UUID {
        threadID
    }

    private let kit: PositronicKit

    init(threadID: UUID, kit: PositronicKit) {
        self.threadID = threadID
        self.kit = kit
    }

    /// Sends a message through the Thread's managed execution path.
    ///
    /// The attached Agent identity is resolved from durable Thread state immediately before
    /// admission. Call ``sendDetached(_:tools:maxModelRounds:systemInstructions:)`` when the
    /// caller explicitly wants a direct, identity-free Thread turn.
    public func send(
        _ message: String,
        tools: [any Tool] = [],
        maxModelRounds: Int = 5,
        systemInstructions: String? = nil
    ) async throws -> AsyncThrowingStream<TurnEvent, Error> {
        return try await run(TurnRequest(
            threadID: threadID,
            message: message,
            tools: tools,
            systemInstructions: systemInstructions,
            maxModelRounds: maxModelRounds
        ))
    }

    /// Sends an identity-free direct turn on this Thread.
    public func sendDetached(
        _ message: String,
        tools: [any Tool] = [],
        maxModelRounds: Int = 5,
        systemInstructions: String? = nil
    ) async throws -> AsyncThrowingStream<TurnEvent, Error> {
        try await runDetached(TurnRequest(
            threadID: threadID,
            message: message,
            tools: tools,
            systemInstructions: systemInstructions,
            maxModelRounds: maxModelRounds
        ))
    }

    /// Runs an advanced managed request already addressed to this Thread.
    ///
    /// Most consumers should use ``send(_:tools:maxModelRounds:systemInstructions:)``. This
    /// request-shaped seam remains for sidecars and other explicit turn configuration; the
    /// request's `threadID` must identify this handle's Thread.
    public func run(_ request: TurnRequest) async throws -> AsyncThrowingStream<TurnEvent, Error> {
        guard request.threadID == threadID else {
            throw ThreadError.threadNotFound
        }
        guard request.agentID == nil else {
            throw AgentError.managedThreadAgentOverride(threadID)
        }
        guard let attachedAgentID = try await kit.threadManager.threadStore
            .fetchThread(id: threadID)?.attachedAgentID
        else {
            throw AgentError.managedThreadRequiresAttachedAgent(threadID)
        }
        let managedRequest = TurnRequest(
            threadID: threadID,
            requestID: request.requestID,
            content: request.messageContent,
            tools: request.tools,
            toolOutputs: request.toolOutputs,
            systemInstructions: request.systemInstructions,
            agentID: attachedAgentID,
            maxModelRounds: request.maxModelRounds,
            generationParameters: request.generationParameters,
            structuredOutput: request.structuredOutput,
            sidecars: request.sidecars,
            sidecarCommitPolicy: request.sidecarCommitPolicy,
            includeSidecarMechanismPreamble: request.includeSidecarMechanismPreamble,
            promptAssemblyLogger: request.promptAssemblyLogger,
            responseModalities: request.responseModalities,
            audioOutput: request.audioOutput
        )
        return try await kit.run(managedRequest)
    }

    /// Runs an explicitly detached request on this Thread without deriving Agent context.
    public func runDetached(_ request: TurnRequest) async throws -> AsyncThrowingStream<TurnEvent, Error> {
        guard request.threadID == threadID else {
            throw ThreadError.threadNotFound
        }
        guard request.agentID == nil else {
            throw AgentError.managedThreadAgentOverride(threadID)
        }
        return try await kit.run(request)
    }

    /// Cancels any in-flight generation for this handle's Thread.
    public func cancel() async {
        await kit.threadManager.cancelGeneration(for: threadID)
    }
}

public extension PositronicKit {
    /// Opens an **existing** thread for sending and cancellation.
    ///
    /// This is pure handle construction: it performs no persistence I/O. The Thread
    /// must have been created beforehand via ``ThreadCapability/create(title:)``.
    /// A missing (never-persisted) thread id is an error, not a silent creation —
    /// the first ``ThreadHandle/send(_:)`` call will throw
    /// ``ThreadError/threadNotFound`` before any message is persisted.
    func openThread(_ threadID: UUID) -> ThreadHandle {
        ThreadHandle(threadID: threadID, kit: self)
    }

}
