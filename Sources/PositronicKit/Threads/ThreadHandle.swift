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

    /// Starts a managed Turn whose Agent is captured from this Thread at admission.
    private func admitManagedTurn(_ request: TurnRequest) async throws -> TurnHandle {
        guard request.threadID == threadID else {
            throw ThreadError.threadNotFound
        }
        guard let thread = try await kit.threadManager.threadStore.fetchThread(id: threadID) else {
            throw ThreadError.threadNotFound
        }
        guard let attachedAgentID = thread.attachedAgentID else {
            throw TurnError.managedExecutionRequiresAttachedAgent(threadID)
        }
        return try await kit.startTurnHandle(
            request,
            agentID: attachedAgentID,
            executionKind: .agentManaged
        )
    }

    /// Starts a managed Turn from the common message-shaped call site.
    ///
    /// - Parameters:
    ///   - message: The user message to admit.
    ///   - options: Per-Turn configuration that does not repeat this handle's Thread identity.
    public func startTurn(
        _ message: String,
        options: TurnOptions = .init()
    ) async throws -> TurnHandle {
        try await startTurn(MessageContent(message), options: options)
    }

    /// Starts a managed Turn with ordered text and media content.
    ///
    /// - Parameters:
    ///   - content: The ordered text and media content to admit.
    ///   - options: Per-Turn configuration that does not repeat this handle's Thread identity.
    public func startTurn(
        _ content: MessageContent,
        options: TurnOptions = .init()
    ) async throws -> TurnHandle {
        try await admitManagedTurn(options.makeRequest(threadID: threadID, content: content))
    }

    /// Starts a managed Turn with explicit system instructions.
    public func startTurn(
        _ message: String,
        systemInstructions: String,
        options: TurnOptions = .init()
    ) async throws -> TurnHandle {
        try await startTurn(
            MessageContent(message),
            systemInstructions: systemInstructions,
            options: options
        )
    }

    /// Starts a managed Turn with ordered text and media content and explicit system instructions.
    ///
    /// - Parameters:
    ///   - content: The ordered text and media content to admit.
    ///   - systemInstructions: Instructions included in the managed Agent prompt.
    ///   - options: Per-Turn configuration that does not repeat this handle's Thread identity.
    public func startTurn(
        _ content: MessageContent,
        systemInstructions: String,
        options: TurnOptions = .init()
    ) async throws -> TurnHandle {
        try await admitManagedTurn(options.makeRequest(
            threadID: threadID,
            content: content,
            systemInstructions: systemInstructions
        ))
    }

    /// Starts an explicit direct Turn. Direct execution is valid only while this Thread has no
    /// attached Agent; the caller supplies the complete system prompt and contributor selection.
    ///
    /// - Parameters:
    ///   - message: The user message to admit.
    ///   - context: Explicit direct-execution authority and system instructions.
    ///   - options: Per-Turn configuration that does not repeat this handle's Thread identity.
    public func startDirectTurn(
        _ message: String,
        context: DirectTurnContext,
        options: TurnOptions = .init()
    ) async throws -> TurnHandle {
        try await startDirectTurn(MessageContent(message), context: context, options: options)
    }

    /// Starts an explicit direct Turn with ordered text and media content.
    ///
    /// - Parameters:
    ///   - content: The ordered text and media content to admit.
    ///   - context: Explicit direct-execution authority and system instructions.
    ///   - options: Per-Turn configuration that does not repeat this handle's Thread identity.
    public func startDirectTurn(
        _ content: MessageContent,
        context: DirectTurnContext,
        options: TurnOptions = .init()
    ) async throws -> TurnHandle {
        guard let thread = try await kit.threadManager.threadStore.fetchThread(id: threadID) else {
            throw ThreadError.threadNotFound
        }
        guard thread.attachedAgentID == nil else {
            throw TurnError.directExecutionRequiresDetachedThread(threadID)
        }
        return try await kit.startTurnHandle(
            options.makeRequest(
                threadID: threadID,
                content: content,
                systemInstructions: context.systemInstructions
            ),
            agentID: nil,
            executionKind: .direct,
            contributors: context.contributors
        )
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
    /// the first managed Turn call will throw
    /// ``ThreadError/threadNotFound`` before any message is persisted.
    func openThread(_ threadID: UUID) -> ThreadHandle {
        ThreadHandle(threadID: threadID, kit: self)
    }

}
