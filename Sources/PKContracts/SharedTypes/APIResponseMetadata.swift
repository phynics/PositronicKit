import Foundation

/// OpenAI API response metadata
public struct APIResponseMetadata: Equatable, Sendable, Codable {
    public var model: String?
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?
    public var cachedTokens: Int?
    public var finishReason: String?
    public var systemFingerprint: String?
    public var duration: TimeInterval?
    public var tokensPerSecond: Double?
    public var turnSnapshotData: Data?

    public init(
        model: String? = nil, promptTokens: Int? = nil, completionTokens: Int? = nil,
        totalTokens: Int? = nil, cachedTokens: Int? = nil, finishReason: String? = nil,
        systemFingerprint: String? = nil, duration: TimeInterval? = nil,
        tokensPerSecond: Double? = nil, turnSnapshotData: Data? = nil
    ) {
        self.model = model
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.cachedTokens = cachedTokens
        self.finishReason = finishReason
        self.systemFingerprint = systemFingerprint
        self.duration = duration
        self.tokensPerSecond = tokensPerSecond
        self.turnSnapshotData = turnSnapshotData
    }
}
