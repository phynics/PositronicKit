import Foundation
import Logging
import PKContracts

/// Configuration for admitting one Turn through a ``ThreadHandle``.
///
/// A ``ThreadHandle`` already identifies the destination Thread, so this type contains only
/// per-Turn options. Use it with ``ThreadHandle/startTurn(_:options:)`` or
/// ``ThreadHandle/startDirectTurn(_:context:options:)``.
public struct TurnOptions: Sendable {
    /// An optional idempotency key for joining or replaying a submission.
    public let requestID: UUID?

    /// Tools available to the model during this Turn.
    public let tools: [AnyTool]

    /// Tool results submitted as the next model input.
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

    /// Creates per-Turn options without repeating the destination Thread identity.
    public init(
        requestID: UUID? = nil,
        tools: [any Tool] = [],
        toolOutputs: [ToolOutputSubmission]? = nil,
        maxModelRounds: Int = 5,
        generationParameters: GenerationParameters? = nil,
        structuredOutput: StructuredOutputRequest? = nil,
        sidecars: [SidecarDirective] = [],
        sidecarCommitPolicy: SidecarCommitPolicy = .everyModelRound,
        includeSidecarMechanismPreamble: Bool = false,
        promptAssemblyLogger: Logger? = nil,
        responseModalities: Set<ResponseModality> = [.text],
        audioOutput: AudioOutputOptions? = nil
    ) {
        self.requestID = requestID
        self.tools = tools.map { $0.toAnyTool() }
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
    }

    func makeRequest(
        threadID: UUID,
        content: MessageContent,
        systemInstructions: String? = nil
    ) -> TurnRequest {
        TurnRequest(
            threadID: threadID,
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
            audioOutput: audioOutput
        )
    }
}
