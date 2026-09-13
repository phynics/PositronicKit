import Foundation
import PKContracts

/// A lightweight, stable handle for starting managed or direct work on exactly one durable
/// ``TimelineRecord``.
///
/// `TimelineHandle` holds no mutable turn state, does not perform persistence lookups on
/// construction, and does not expose the underlying coordinator. Opening a handle via
/// ``TimelineCapability/open(_:)`` is pure value construction — persistence happens lazily,
/// when `startTurn` or `startDirectTurn` admits a Turn.
public struct TimelineHandle: Identifiable, Sendable {
    /// The persisted TimelineRecord this handle sends to and cancels work for.
    public let timelineID: UUID

    /// Stable identity; equal to `timelineID`.
    public var id: UUID {
        timelineID
    }

    private let kit: PKRuntime

    init(timelineID: UUID, kit: PKRuntime) {
        self.timelineID = timelineID
        self.kit = kit
    }

    /// Starts a managed Turn whose Agent is captured from this TimelineRecord at admission.
    private func admitManagedTurn(_ request: TurnRequest) async throws -> TurnHandle {
        guard request.timelineID == timelineID else {
            throw TimelineError.timelineNotFound
        }
        guard let timeline = try await kit.timelineManager.timelineStore.fetchTimeline(id: timelineID) else {
            throw TimelineError.timelineNotFound
        }
        guard let attachedAgentID = timeline.attachedAgentID else {
            throw TurnError.managedExecutionRequiresAttachedAgent(timelineID)
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
    ///   - systemInstructions: Instructions included in the managed Agent prompt, if any.
    ///   - options: Per-Turn configuration that does not repeat this handle's TimelineRecord identity.
    public func startTurn(
        _ message: String,
        systemInstructions: String? = nil,
        options: TurnOptions = .init()
    ) async throws -> TurnHandle {
        try await startTurn(
            MessageContent(message),
            systemInstructions: systemInstructions,
            options: options
        )
    }

    /// Starts a managed Turn with ordered text and media content.
    ///
    /// - Parameters:
    ///   - content: The ordered text and media content to admit.
    ///   - systemInstructions: Instructions included in the managed Agent prompt, if any.
    ///   - options: Per-Turn configuration that does not repeat this handle's TimelineRecord identity.
    public func startTurn(
        _ content: MessageContent,
        systemInstructions: String? = nil,
        options: TurnOptions = .init()
    ) async throws -> TurnHandle {
        try await admitManagedTurn(options.makeRequest(
            timelineID: timelineID,
            content: content,
            systemInstructions: systemInstructions
        ))
    }

    /// Starts an explicit direct Turn. Direct execution is valid only while this TimelineRecord has no
    /// attached Agent; the caller supplies the complete system prompt and contributor selection.
    ///
    /// - Parameters:
    ///   - message: The user message to admit.
    ///   - context: Explicit direct-execution authority and system instructions.
    ///   - options: Per-Turn configuration that does not repeat this handle's TimelineRecord identity.
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
    ///   - options: Per-Turn configuration that does not repeat this handle's TimelineRecord identity.
    public func startDirectTurn(
        _ content: MessageContent,
        context: DirectTurnContext,
        options: TurnOptions = .init()
    ) async throws -> TurnHandle {
        guard let timeline = try await kit.timelineManager.timelineStore.fetchTimeline(id: timelineID) else {
            throw TimelineError.timelineNotFound
        }
        guard timeline.attachedAgentID == nil else {
            throw TurnError.directExecutionRequiresDetachedTimeline(timelineID)
        }
        return try await kit.startTurnHandle(
            options.makeRequest(
                timelineID: timelineID,
                content: content,
                systemInstructions: context.systemInstructions
            ),
            agentID: nil,
            executionKind: .direct,
            contributors: context.contributors
        )
    }

    /// Cancels any in-flight generation for this handle's TimelineRecord.
    public func cancel() async {
        await kit.timelineManager.cancelGeneration(for: timelineID)
    }
}
