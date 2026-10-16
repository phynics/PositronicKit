import Foundation
import PKContracts

/// A lightweight, stable handle for starting managed or direct work on exactly one durable
/// ``TimelineRecord``.
///
/// `TimelineHandle` holds no mutable turn state, does not perform persistence lookups on
/// construction, and does not expose the underlying coordinator. Opening a handle via
/// ``TimelineCapability/open(_:)`` is pure value construction — persistence happens lazily,
/// when `startTurn` or `startDirectTurn` admits a Turn.
///
/// A handle captures the provider configuration of the view it was opened from, so
/// ``PKRuntime/replacingLanguageModel(_:generationParameters:)`` affects only handles opened
/// from the replacement view. A handle opened earlier keeps sending through its original model.
public struct TimelineHandle: Identifiable, Sendable {
    /// The persisted TimelineRecord this handle sends to and cancels work for.
    public let timelineID: UUID

    /// Stable identity; equal to `timelineID`.
    public var id: UUID {
        timelineID
    }

    private let engine: TurnEngine
    /// Holds the ephemeral Timeline's lifetime for as long as this handle is alive. `nil` for an
    /// ordinary durable Timeline. Never read; it exists so releasing the last handle releases the
    /// Timeline.
    private let ephemeralToken: EphemeralTimelineToken?

    init(
        timelineID: UUID,
        engine: TurnEngine,
        ephemeralToken: EphemeralTimelineToken? = nil
    ) {
        self.timelineID = timelineID
        self.engine = engine
        self.ephemeralToken = ephemeralToken
    }

    /// Starts a managed Turn whose Agent is captured from this TimelineRecord at admission.
    private func admitManagedTurn(_ request: TurnRequest) async throws -> TurnHandle {
        guard request.timelineID == timelineID else {
            throw TimelineError.timelineNotFound
        }
        guard let timeline = try await engine.dependencies.timelineManager.timelineStore.fetchTimeline(id: timelineID) else {
            throw TimelineError.timelineNotFound
        }
        guard let attachedAgentID = timeline.attachedAgentID else {
            throw TurnError.managedExecutionRequiresAttachedAgent(timelineID)
        }
        return try await engine.startTurnHandle(
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
        guard let timeline = try await engine.dependencies.timelineManager.timelineStore.fetchTimeline(id: timelineID) else {
            throw TimelineError.timelineNotFound
        }
        guard timeline.attachedAgentID == nil else {
            throw TurnError.directExecutionRequiresDetachedTimeline(timelineID)
        }
        return try await engine.startTurnHandle(
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
        await engine.dependencies.timelineManager.cancelGeneration(for: timelineID)
    }

    /// Returns the Turn currently blocking admission on this handle's Timeline, if any.
    ///
    /// A quarantined Turn is not the active Turn, so it is not visible through the engine's
    /// active-Turn pointer. The record carries the ``TurnQuarantine`` a host shows in a recovery
    /// prompt; `nil` means the Timeline accepts new work.
    public func quarantinedTurn() async throws -> TurnRecord? {
        try await engine.dependencies.runtimeRepository.fetchQuarantinedTurn(for: timelineID)
    }

    /// Returns a value snapshot of this Timeline's provider-facing prompt layout state.
    ///
    /// The snapshot exposes layout segment IDs and tiers, per-tier content fingerprints, the
    /// last request's cache breakpoints, and the last reset reasons. It is a pure value: the
    /// runtime's prompt actors stay internal. A Timeline that has not prepared a prompt yet
    /// returns ``PromptStateSnapshot/empty``.
    public func promptState() async -> PromptStateSnapshot {
        let history = await engine.dependencies.promptHistoryRegistry.history(for: timelineID)
        return await history.promptStateSnapshot()
    }

    /// Releases a quarantined Turn on this handle's Timeline after an operator confirms the side
    /// effect is reconciled. The release runs under the same per-Timeline authority lane as
    /// admission, so it cannot race a concurrent admission.
    ///
    /// - Parameters:
    ///   - turnID: The quarantined Turn to release.
    ///   - confirmation: The operator confirmation carrying the required phrase.
    /// - Returns: The released, still-interrupted Turn record.
    /// - Throws: ``TimelineRuntimeRepositoryError/turnNotFound(_:)`` when the Turn does not
    ///   exist, ``TimelineRuntimeRepositoryError/confirmationRequired`` when the phrase is wrong,
    ///   or ``TimelineRuntimeRepositoryError/quarantineNotFound(timelineID:turnID:)`` when the
    ///   Turn is on another Timeline or is not quarantined.
    public func releaseQuarantine(
        turnID: UUID,
        confirmation: QuarantineReleaseConfirmation
    ) async throws -> TurnRecord {
        let dependencies = engine.dependencies
        guard let turn = try await dependencies.runtimeRepository.fetchTurn(id: turnID) else {
            throw TimelineRuntimeRepositoryError.turnNotFound(turnID)
        }
        guard turn.timelineID == timelineID else {
            throw TimelineRuntimeRepositoryError.quarantineNotFound(
                timelineID: timelineID,
                turnID: turnID
            )
        }
        return try await dependencies.timelineManager.withTimelineAuthority(timelineID) {
            try await dependencies.runtimeRepository.releaseQuarantine(
                timelineID: timelineID,
                turnID: turnID,
                confirmation: confirmation,
                now: Date()
            )
        }
    }
}

// MARK: - Cache-exact sibling requests (#281)

@_spi(Experimental)
public extension TimelineHandle {
    /// Issues an auxiliary model request that shares the retained final round's provider-facing
    /// prefix, so post-Turn analysis (critics, titles, curation) can hit the provider cache.
    ///
    /// The call replays the retained messages and tools byte for byte, appends `messages` after
    /// the retained prefix, and reuses the retained cache directive (`routingKey`, retention, and
    /// breakpoints). It writes nothing to the transcript, Turn ledger, or journal, and it does not
    /// take the Timeline authority lane, so it never blocks or reorders Turn admission.
    ///
    /// Retention must be enabled through ``PKRuntime/RuntimeConfiguration/retainsSiblingPrefix``.
    ///
    /// - Parameters:
    ///   - messages: The host messages to append after the retained prefix.
    ///   - responseFormat: The response shape to request. When `nil`, the retained round's shape is
    ///     reused.
    ///   - generationParameters: Sampling overrides. When `nil`, the retained round's effective
    ///     parameters are reused.
    /// - Returns: The assembled response, including provider usage and any cached-token counts.
    /// - Throws: ``TimelineError/timelineNotFound`` when the Timeline does not exist, or
    ///   ``TimelineError/siblingPrefixUnavailable(_:)`` when no cache-exact prefix can be served.
    func siblingRequest(
        appending messages: [LLMMessage],
        responseFormat: LLMResponseFormat? = nil,
        generationParameters: GenerationParameters? = nil
    ) async throws -> LLMResponse {
        let retained = try await retainedSiblingRequest()
        let chunk = try await engine.dependencies.llmService.generationCompletion(
            messages: retained.messages + messages,
            tools: retained.tools,
            toolChoice: retained.toolChoice,
            responseFormat: responseFormat ?? retained.responseFormat,
            generationParameters: generationParameters ?? retained.generationParameters,
            modelTier: retained.modelTier,
            responseModalities: [.text],
            audioOutput: nil,
            promptCache: retained.promptCache
        )
        return LLMResponse(
            content: chunk.choices.first?.delta.content,
            id: chunk.id,
            model: chunk.model,
            usage: chunk.usage,
            finishReason: chunk.choices.first?.finishReason
        )
    }

    /// Streams an auxiliary model request over the retained final round's provider-facing prefix.
    ///
    /// The streaming variant of
    /// ``siblingRequest(appending:responseFormat:generationParameters:)``: it applies the same
    /// prefix, directive, and read-only isolation, but returns the provider's raw chunk stream so
    /// the host can render the auxiliary response incrementally. Cancelling the consuming task
    /// cancels the underlying provider request.
    ///
    /// - Parameters:
    ///   - messages: The host messages to append after the retained prefix.
    ///   - responseFormat: The response shape to request. When `nil`, the retained round's shape is
    ///     reused.
    ///   - generationParameters: Sampling overrides. When `nil`, the retained round's effective
    ///     parameters are reused.
    /// - Returns: The provider's chunk stream.
    /// - Throws: ``TimelineError/timelineNotFound`` when the Timeline does not exist, or
    ///   ``TimelineError/siblingPrefixUnavailable(_:)`` when no cache-exact prefix can be served.
    func siblingRequestStream(
        appending messages: [LLMMessage],
        responseFormat: LLMResponseFormat? = nil,
        generationParameters: GenerationParameters? = nil
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let retained = try await retainedSiblingRequest()
        return await engine.dependencies.llmService.generation(
            transport: retained.transport,
            messages: retained.messages + messages,
            tools: retained.tools,
            toolChoice: retained.toolChoice,
            responseFormat: responseFormat ?? retained.responseFormat,
            generationParameters: generationParameters ?? retained.generationParameters,
            modelTier: retained.modelTier,
            responseModalities: [.text],
            audioOutput: nil,
            promptCache: retained.promptCache
        )
    }

    /// Resolves the retained final-round request, rejecting an in-flight Turn so the sibling
    /// request never mixes model rounds.
    private func retainedSiblingRequest() async throws -> RetainedSiblingRequest {
        let dependencies = engine.dependencies
        guard dependencies.policy.retainsSiblingPrefix else {
            throw TimelineError.siblingPrefixUnavailable(.retentionDisabled)
        }
        guard try await dependencies.timelineManager.timelineStore.fetchTimeline(id: timelineID) != nil else {
            throw TimelineError.timelineNotFound
        }
        if try await dependencies.runtimeRepository.fetchActiveTurn(for: timelineID) != nil {
            throw TimelineError.siblingPrefixUnavailable(.turnInFlight)
        }
        let history = await dependencies.promptHistoryRegistry.history(for: timelineID)
        guard let retained = await history.siblingRequest() else {
            throw TimelineError.siblingPrefixUnavailable(.noRetainedRound)
        }
        return retained
    }
}
