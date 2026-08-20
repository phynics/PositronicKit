import Foundation

/// Public contract for limiting local embedding inputs before allocation or inference.
public struct EmbeddingInputBudget: Sendable, Equatable {
    public enum ValidationError: Error, Equatable, Sendable {
        case batchTextCountLimitExceeded(max: Int, actual: Int)
        case perTextByteLimitExceeded(max: Int, actual: Int)
        case totalBatchByteLimitExceeded(max: Int, actual: Int)

        public var message: String {
            switch self {
            case let .batchTextCountLimitExceeded(max, actual):
                return "Embedding input exceeded the batch text-count limit of \(max) item(s) (\(actual) provided)."
            case let .perTextByteLimitExceeded(max, actual):
                return "Embedding input exceeded the per-text byte limit of \(max) bytes (\(actual) bytes provided)."
            case let .totalBatchByteLimitExceeded(max, actual):
                return "Embedding input exceeded the total batch byte limit of \(max) bytes (\(actual) bytes provided)."
            }
        }

        public init?(message: String) {
            if let parsed = Self.parse(
                message: message,
                prefix: "Embedding input exceeded the batch text-count limit of ",
                infix: " item(s) (",
                suffix: " provided)."
            ) {
                self = .batchTextCountLimitExceeded(max: parsed.max, actual: parsed.actual)
                return
            }

            if let parsed = Self.parse(
                message: message,
                prefix: "Embedding input exceeded the per-text byte limit of ",
                infix: " bytes (",
                suffix: " bytes provided)."
            ) {
                self = .perTextByteLimitExceeded(max: parsed.max, actual: parsed.actual)
                return
            }

            if let parsed = Self.parse(
                message: message,
                prefix: "Embedding input exceeded the total batch byte limit of ",
                infix: " bytes (",
                suffix: " bytes provided)."
            ) {
                self = .totalBatchByteLimitExceeded(max: parsed.max, actual: parsed.actual)
                return
            }

            return nil
        }

        private static func parse(
            message: String,
            prefix: String,
            infix: String,
            suffix: String
        ) -> (max: Int, actual: Int)? {
            guard
                message.hasPrefix(prefix),
                message.hasSuffix(suffix)
            else {
                return nil
            }

            let content = String(message.dropFirst(prefix.count).dropLast(suffix.count))
            let parts = content.components(separatedBy: infix)
            guard
                parts.count == 2,
                let max = Int(parts[0]),
                let actual = Int(parts[1])
            else {
                return nil
            }

            return (max, actual)
        }
    }

    /// Maximum number of texts allowed in a single embedding request.
    public let maxTextCount: Int

    /// Maximum UTF-8 byte count allowed for a single text.
    public let maxBytesPerText: Int

    /// Maximum UTF-8 byte count allowed across a batch.
    public let maxTotalBytes: Int

    /// Default local-embedding budget: 64 texts, 64 KiB per text, 256 KiB total per batch.
    public static let `default` = Self(
        maxTextCount: 64,
        maxBytesPerText: 65_536,
        maxTotalBytes: 262_144
    )

    public init(maxTextCount: Int, maxBytesPerText: Int, maxTotalBytes: Int) {
        self.maxTextCount = maxTextCount
        self.maxBytesPerText = maxBytesPerText
        self.maxTotalBytes = maxTotalBytes
    }

    public func validate(_ text: String) throws {
        try validate([text])
    }

    public func validate(_ texts: [String]) throws {
        guard texts.count <= maxTextCount else {
            throw ValidationError.batchTextCountLimitExceeded(max: maxTextCount, actual: texts.count)
        }

        var totalBytes = 0
        for text in texts {
            let byteCount = text.lengthOfBytes(using: .utf8)
            guard byteCount <= maxBytesPerText else {
                throw ValidationError.perTextByteLimitExceeded(max: maxBytesPerText, actual: byteCount)
            }

            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(byteCount)
            guard !overflow else {
                throw ValidationError.totalBatchByteLimitExceeded(max: maxTotalBytes, actual: Int.max)
            }
            totalBytes = nextTotal

            guard totalBytes <= maxTotalBytes else {
                throw ValidationError.totalBatchByteLimitExceeded(max: maxTotalBytes, actual: totalBytes)
            }
        }
    }
}
