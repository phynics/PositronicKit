import Foundation
import Logging
import PKShared

/// Transport-neutral configuration for a single chat turn.
public struct ChatRunRequest: Sendable, CustomStringConvertible {
    public let timelineId: UUID
    public let sendId: UUID?
    public let message: String
    public let tools: [AnyTool]
    public let toolOutputs: [ToolOutputSubmission]?
    public let systemInstructions: String?
    public let agentInstanceId: UUID?
    public let maxTurns: Int
    public let generationParameters: GenerationParameters?
    public let structuredOutput: StructuredOutputRequest?
    public let sidecars: [SidecarDirective]
    public let includeSidecarMechanismPreamble: Bool
    public let promptAssemblyLogger: Logger?

    public init(
        timelineId: UUID,
        sendId: UUID? = nil,
        message: String,
        tools: [any Tool] = [],
        toolOutputs: [ToolOutputSubmission]? = nil,
        systemInstructions: String? = nil,
        agentInstanceId: UUID? = nil,
        maxTurns: Int = 5,
        generationParameters: GenerationParameters? = nil,
        structuredOutput: StructuredOutputRequest? = nil,
        sidecars: [SidecarDirective] = [],
        includeSidecarMechanismPreamble: Bool = false,
        promptAssemblyLogger: Logger? = nil
    ) {
        self.timelineId = timelineId
        self.sendId = sendId
        self.message = message
        self.tools = tools.map { $0.toAnyTool() }
        self.toolOutputs = toolOutputs
        self.systemInstructions = systemInstructions
        self.agentInstanceId = agentInstanceId
        self.maxTurns = maxTurns
        self.generationParameters = generationParameters
        self.structuredOutput = structuredOutput
        self.sidecars = sidecars
        self.includeSidecarMechanismPreamble = includeSidecarMechanismPreamble
        self.promptAssemblyLogger = promptAssemblyLogger
    }

    public var description: String {
        let messageSummary = message.debugDescription
        let toolOutputCount = toolOutputs?.count ?? 0
        let sendIdDescription = sendId?.uuidString ?? "nil"
        let systemInstructionsDescription = systemInstructions.map { "set(\($0.count) chars)" } ?? "nil"
        let generationParametersDescription = generationParameters.map { String(describing: $0) } ?? "nil"
        let structuredOutputDescription = structuredOutput.map { String(describing: $0) } ?? "nil"
        let promptAssemblyLoggerDescription = promptAssemblyLogger.map { $0.label } ?? "nil"
        return "ChatRunRequest(timelineId: \(timelineId), sendId: \(sendIdDescription), message: \(messageSummary), tools: \(tools.count), toolOutputs: \(toolOutputCount), systemInstructions: \(systemInstructionsDescription), agentInstanceId: \(agentInstanceId?.uuidString ?? "nil"), maxTurns: \(maxTurns), generationParameters: \(generationParametersDescription), structuredOutput: \(structuredOutputDescription), sidecars: \(sidecars.count), includeSidecarMechanismPreamble: \(includeSidecarMechanismPreamble), promptAssemblyLogger: \(promptAssemblyLoggerDescription))"
    }
}
