import Foundation
import PKContracts

/// The normalized input for one Turn execution.
///
/// The public request remains intact. The facade adds only the values it resolves before the
/// runtime admits the Turn, so execution and idempotency share one representation of caller intent.
struct TurnExecutionRequest: Sendable {
    struct Context: Sendable {
        let agentID: UUID?
        let kind: TurnExecutionKind
        let contributors: [TurnContributor]
    }

    let request: TurnRequest
    let requestID: UUID
    let generationParameters: GenerationParameters?
    let context: Context

    init(
        _ request: TurnRequest,
        defaultGenerationParameters: GenerationParameters? = nil,
        agentID: UUID? = nil,
        executionKind: TurnExecutionKind = .agentManaged,
        contributors: [TurnContributor] = []
    ) {
        self.request = request
        requestID = request.requestID ?? UUID()
        generationParameters = request.generationParameters ?? defaultGenerationParameters
        context = Context(
            agentID: agentID,
            kind: executionKind,
            contributors: contributors
        )
    }

    /// A stable representation of the effective caller intent used for Request-ID idempotency.
    var callerIntentFingerprint: String {
        let toolIntent = request.tools.map { tool in
            [
                tool.callName,
                tool.name,
                tool.description,
                tool.usageExample ?? "",
                String(tool.requiresPermission),
                String(describing: tool.sideEffects),
                canonicalFingerprint(tool.toolReference),
                canonicalFingerprint(tool.origin),
                canonicalFingerprint(tool.parametersSchema),
            ].joined(separator: "\u{1E}")
        }.joined(separator: "\u{1F}")
        return [
            canonicalFingerprint(request.messageContent),
            toolIntent,
            canonicalFingerprint(request.toolOutputs),
            request.systemInstructions ?? "",
            context.kind.rawValue,
            canonicalFingerprint(context.contributors),
            "\(request.maxModelRounds)",
            canonicalFingerprint(generationParameters),
            canonicalFingerprint(request.structuredOutput),
            canonicalFingerprint(request.sidecars),
            canonicalFingerprint(request.sidecarCommitPolicy),
            String(request.includeSidecarMechanismPreamble),
            canonicalFingerprint(request.responseModalities.map(\.rawValue).sorted()),
            canonicalFingerprint(request.audioOutput),
        ].joined(separator: "\u{1F}")
    }

    private func canonicalFingerprint<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return String(describing: value) }
        return data.base64EncodedString()
    }
}
