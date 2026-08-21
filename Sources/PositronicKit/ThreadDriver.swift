import Foundation
import PKContracts

/// A lightweight, stable handle for starting managed or direct work on exactly one durable
/// ``Thread``.
///
/// `ThreadHandle` holds no mutable turn state, does not perform persistence lookups on
/// construction, and does not expose the underlying coordinator. Opening a handle via
/// `PositronicKit.openThread(_:)` is pure value construction — persistence happens lazily,
/// when `startTurn` or `startDirectTurn` admits a Turn.
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
    /// admission. Call ``startDirectTurn(message:context:tools:requestID:maxModelRounds:)`` when
    /// the caller explicitly wants a direct, identity-free Thread turn.
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

    /// Starts a managed Turn whose Agent is captured from this Thread at admission.
    public func startTurn(_ request: TurnRequest) async throws -> TurnHandle {
        guard request.threadID == threadID else {
            throw ThreadError.threadNotFound
        }
        guard let thread = try await kit.threadManager.threadStore.fetchThread(id: threadID) else {
            throw ThreadError.threadNotFound
        }
        guard let attachedAgentID = thread.attachedAgentID else {
            throw AgentError.managedThreadRequiresAttachedAgent(threadID)
        }
        return try await kit.startTurnHandle(
            request,
            agentID: attachedAgentID,
            executionKind: .agentManaged
        )
    }

    /// Starts a managed Turn from the common message-shaped call site.
    public func startTurn(
        message: String,
        tools: [any Tool] = [],
        maxModelRounds: Int = 5,
        systemInstructions: String? = nil
    ) async throws -> TurnHandle {
        try await startTurn(TurnRequest(
            threadID: threadID,
            message: message,
            tools: tools,
            systemInstructions: systemInstructions,
            maxModelRounds: maxModelRounds
        ))
    }

    /// Starts an explicit direct Turn. Direct execution is valid only while this Thread has no
    /// attached Agent; the caller supplies the complete system prompt and contributor selection.
    public func startDirectTurn(
        message: String,
        context: DirectTurnContext,
        tools: [any Tool] = [],
        requestID: UUID? = nil,
        maxModelRounds: Int = 5
    ) async throws -> TurnHandle {
        guard let thread = try await kit.threadManager.threadStore.fetchThread(id: threadID) else {
            throw ThreadError.threadNotFound
        }
        guard thread.attachedAgentID == nil else {
            throw AgentError.directTurnRequiresDetachedThread(threadID)
        }
        return try await kit.startTurnHandle(
            TurnRequest(
                threadID: threadID,
                requestID: requestID,
                message: message,
                tools: tools,
                systemInstructions: context.systemInstructions,
                maxModelRounds: maxModelRounds
            ),
            agentID: nil,
            executionKind: .direct,
            contributors: context.contributors
        )
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
        guard let thread = try await kit.threadManager.threadStore.fetchThread(id: threadID) else {
            throw ThreadError.threadNotFound
        }
        guard let attachedAgentID = thread.attachedAgentID else {
            throw AgentError.managedThreadRequiresAttachedAgent(threadID)
        }
        let managedRequest = TurnRequest(
            threadID: threadID,
            requestID: request.requestID,
            content: request.messageContent,
            tools: request.tools,
            toolOutputs: request.toolOutputs,
            systemInstructions: request.systemInstructions,
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
        return try await kit.run(managedRequest, agentID: attachedAgentID, executionKind: .agentManaged)
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
