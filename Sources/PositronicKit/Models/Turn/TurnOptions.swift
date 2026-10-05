import Foundation
import Logging
import PKContracts

/// Configuration for admitting one Turn through a ``TimelineHandle``.
///
/// A ``TimelineHandle`` already identifies the destination TimelineRecord, so this type contains only
/// per-Turn options. Use it with `TimelineHandle.startTurn` or
/// `TimelineHandle.startDirectTurn`.
public struct TurnOptions: Sendable {
    /// An optional idempotency key for joining or replaying a submission.
    public let requestID: UUID?

    /// Tools available to the model during this Turn.
    public let tools: [AnyTool]

    /// PKTool results submitted as the next model input.
    public let toolOutputs: [ToolOutputSubmission]?

    /// Maximum number of model/tool rounds allowed for this Turn.
    public let maxModelRounds: Int

    /// Per-Turn generation parameter overrides.
    public let generationParameters: GenerationParameters?

    /// Optional structured-output contract for the model response.
    public let structuredOutput: StructuredOutputRequest?

    /// Auxiliary structured values to extract alongside the primary response.
    public let sidecars: [SidecarDirective]

    /// Controls when sidecar results are committed to the event stream.
    public let sidecarCommitPolicy: SidecarCommitPolicy

    /// Whether to include the sidecar mechanism instructions in the assembled prompt.
    public let includeSidecarMechanismPreamble: Bool

    /// Optional logger for prompt assembly diagnostics.
    public let promptAssemblyLogger: Logger?

    /// Response modalities requested from the provider.
    public let responseModalities: Set<ResponseModality>

    /// Optional audio output configuration.
    public let audioOutput: AudioOutputOptions?

    /// The provider transport this Turn uses. Streaming remains the default; `.requestResponse`
    /// asks the provider for one complete response and delivers it as a single terminal chunk.
    public let transport: GenerationTransport

    /// Creates per-Turn options without repeating the destination TimelineRecord identity.
    public init(
        requestID: UUID? = nil,
        tools: [any PKTool] = [],
        toolOutputs: [ToolOutputSubmission]? = nil,
        maxModelRounds: Int = 5,
        generationParameters: GenerationParameters? = nil,
        structuredOutput: StructuredOutputRequest? = nil,
        sidecars: [SidecarDirective] = [],
        sidecarCommitPolicy: SidecarCommitPolicy = .everyModelRound,
        includeSidecarMechanismPreamble: Bool = false,
        promptAssemblyLogger: Logger? = nil,
        responseModalities: Set<ResponseModality> = [.text],
        audioOutput: AudioOutputOptions? = nil,
        transport: GenerationTransport = .streaming
    ) {
        self.requestID = requestID
        self.tools = tools.map { AnyTool($0) }
        self.toolOutputs = toolOutputs
        self.maxModelRounds = maxModelRounds
        self.generationParameters = generationParameters
        self.structuredOutput = structuredOutput
        self.sidecars = sidecars
        self.sidecarCommitPolicy = sidecarCommitPolicy
        self.includeSidecarMechanismPreamble = includeSidecarMechanismPreamble
        self.promptAssemblyLogger = promptAssemblyLogger
        self.responseModalities = responseModalities
        self.audioOutput = audioOutput
        self.transport = transport
    }

    func makeRequest(
        timelineID: UUID,
        content: MessageContent,
        systemInstructions: String? = nil
    ) -> TurnRequest {
        TurnRequest(
            timelineID: timelineID,
            requestID: requestID,
            content: content,
            tools: tools,
            toolOutputs: toolOutputs,
            systemInstructions: systemInstructions,
            maxModelRounds: maxModelRounds,
            generationParameters: generationParameters,
            structuredOutput: structuredOutput,
            sidecars: sidecars,
            sidecarCommitPolicy: sidecarCommitPolicy,
            includeSidecarMechanismPreamble: includeSidecarMechanismPreamble,
            promptAssemblyLogger: promptAssemblyLogger,
            responseModalities: responseModalities,
            audioOutput: audioOutput,
            transport: transport
        )
    }
}

extension TurnOptions {
    /// Returns a copy with `extra` tools prepended to this Turn's tools.
    ///
    /// A session fork always offers its own read-only tools first, ahead of any tools the caller
    /// added. The copy initializer is private to this file so the stored properties stay the only
    /// source of truth for ``TurnOptions``.
    func prependingTools(_ extra: [AnyTool]) -> TurnOptions {
        TurnOptions(copying: self, tools: extra + tools)
    }

    private init(copying options: TurnOptions, tools: [AnyTool]) {
        requestID = options.requestID
        self.tools = tools
        toolOutputs = options.toolOutputs
        maxModelRounds = options.maxModelRounds
        generationParameters = options.generationParameters
        structuredOutput = options.structuredOutput
        sidecars = options.sidecars
        sidecarCommitPolicy = options.sidecarCommitPolicy
        includeSidecarMechanismPreamble = options.includeSidecarMechanismPreamble
        promptAssemblyLogger = options.promptAssemblyLogger
        responseModalities = options.responseModalities
        audioOutput = options.audioOutput
        transport = options.transport
    }
}
