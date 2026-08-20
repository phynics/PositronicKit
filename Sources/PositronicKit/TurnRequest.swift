import Foundation
import Logging
import PKContracts
import PKUtilities

/// Controls when parsed sidecar results become committed completion events.
public enum SidecarCommitPolicy: Sendable, Codable, Equatable {
    case everyModelRound
    case terminalModelRound
}

/// Transport-neutral configuration for a single turn.
public struct TurnRequest: Sendable, CustomStringConvertible {
    public let threadID: UUID
    public let requestID: UUID?
    public let messageContent: MessageContent
    public var message: String { messageContent.text }
    public let tools: [AnyTool]
    public let toolOutputs: [ToolOutputSubmission]?
    public let systemInstructions: String?
    public let agentID: UUID?
    public let maxModelRounds: Int
    public let generationParameters: GenerationParameters?
    public let structuredOutput: StructuredOutputRequest?
    public let sidecars: [SidecarDirective]
    public let sidecarCommitPolicy: SidecarCommitPolicy
    public let includeSidecarMechanismPreamble: Bool
    public let promptAssemblyLogger: Logger?
    public let responseModalities: Set<ResponseModality>
    public let audioOutput: AudioOutputOptions?

    public init(
        threadID: UUID,
        requestID: UUID? = nil,
        message: String,
        tools: [any Tool] = [],
        toolOutputs: [ToolOutputSubmission]? = nil,
        systemInstructions: String? = nil,
        agentID: UUID? = nil,
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
        self.threadID = threadID
        self.requestID = requestID
        messageContent = MessageContent(message)
        self.tools = tools.map { $0.toAnyTool() }
        self.toolOutputs = toolOutputs
        self.systemInstructions = systemInstructions
        self.agentID = agentID
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

    /// Creates a turn with ordered multimodal user content.
    public init(
        threadID: UUID,
        requestID: UUID? = nil,
        content: MessageContent,
        tools: [any Tool] = [],
        toolOutputs: [ToolOutputSubmission]? = nil,
        systemInstructions: String? = nil,
        agentID: UUID? = nil,
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
        self.threadID = threadID
        self.requestID = requestID
        messageContent = content
        self.tools = tools.map { $0.toAnyTool() }
        self.toolOutputs = toolOutputs
        self.systemInstructions = systemInstructions
        self.agentID = agentID
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

    public var description: String {
        let toolOutputCount = toolOutputs?.count ?? 0
        let requestIDDescription = requestID?.uuidString ?? "nil"
        let systemInstructionsDescription = systemInstructions.map { "set(\($0.count) chars)" } ?? "nil"
        let generationParametersDescription = generationParameters.map { String(describing: $0) } ?? "nil"
        let structuredOutputDescription = structuredOutput.map { String(describing: $0) } ?? "nil"
        let promptAssemblyLoggerDescription = promptAssemblyLogger.map { $0.label } ?? "nil"
        return "TurnRequest(threadID: \(threadID), requestID: \(requestIDDescription), message: <redacted>, mediaParts: \(messageContent.parts.count), tools: \(tools.count), toolOutputs: \(toolOutputCount), systemInstructions: \(systemInstructionsDescription), agentID: \(agentID?.uuidString ?? "nil"), maxModelRounds: \(maxModelRounds), generationParameters: \(generationParametersDescription), structuredOutput: \(structuredOutputDescription), sidecars: \(sidecars.count), sidecarCommitPolicy: \(sidecarCommitPolicy), includeSidecarMechanismPreamble: \(includeSidecarMechanismPreamble), promptAssemblyLogger: \(promptAssemblyLoggerDescription))"
    }
}
