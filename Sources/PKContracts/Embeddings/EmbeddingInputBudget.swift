import Foundation

/// Limits an embedding client places on one request.
///
/// Clients declare their budget so callers can reject oversized input before any network or
/// inference work. ``EmbeddingClientProtocol/embedDocuments(_:)`` also uses the budget to split a
/// large document set into admitted batches.
public struct EmbeddingInputBudget: Sendable, Equatable {
    /// Maximum number of texts allowed in a single request.
    public let maxTextCount: Int

    /// Maximum UTF-8 byte count allowed for a single text.
    public let maxBytesPerText: Int

    /// Maximum UTF-8 byte count allowed across one request.
    public let maxTotalBytes: Int

    /// Default budget: 64 texts, 64 KiB per text, 256 KiB total per request.
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

    /// Validates a single text against the budget.
    public func validate(_ text: String) throws {
        try validate([text])
    }

    /// Validates a request's inputs against all three limits.
    ///
    /// - Throws: ``EmbeddingError/batchTextCountLimitExceeded(max:actual:)``,
    ///   ``EmbeddingError/perTextByteLimitExceeded(max:actual:)``, or
    ///   ``EmbeddingError/totalBatchByteLimitExceeded(max:actual:)``.
    public func validate(_ texts: [String]) throws {
        guard texts.count <= maxTextCount else {
            throw EmbeddingError.batchTextCountLimitExceeded(max: maxTextCount, actual: texts.count)
        }

        var totalBytes = 0
        for text in texts {
            let byteCount = text.lengthOfBytes(using: .utf8)
            guard byteCount <= maxBytesPerText else {
                throw EmbeddingError.perTextByteLimitExceeded(max: maxBytesPerText, actual: byteCount)
            }

            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(byteCount)
            guard !overflow else {
                throw EmbeddingError.totalBatchByteLimitExceeded(max: maxTotalBytes, actual: Int.max)
            }
            totalBytes = nextTotal

            guard totalBytes <= maxTotalBytes else {
                throw EmbeddingError.totalBatchByteLimitExceeded(max: maxTotalBytes, actual: totalBytes)
            }
        }
    }

    /// Splits `texts` into budget-sized batches, preserving order.
    ///
    /// Each returned batch fits the text-count and total-byte limits, and every text fits the
    /// per-text byte limit. An empty input yields no batches.
    ///
    /// - Throws: ``EmbeddingError/perTextByteLimitExceeded(max:actual:)`` when one text is too
    ///   large, or ``EmbeddingError/totalBatchByteLimitExceeded(max:actual:)`` when one text
    ///   cannot fit a batch by itself.
    public func batches(_ texts: [String]) throws -> [[String]] {
        var batches: [[String]] = []
        var current: [String] = []
        var currentBytes = 0

        for text in texts {
            let byteCount = text.lengthOfBytes(using: .utf8)
            guard byteCount <= maxBytesPerText else {
                throw EmbeddingError.perTextByteLimitExceeded(max: maxBytesPerText, actual: byteCount)
            }

            if current.isEmpty {
                guard byteCount <= maxTotalBytes, maxTextCount >= 1 else {
                    throw EmbeddingError.totalBatchByteLimitExceeded(max: maxTotalBytes, actual: byteCount)
                }
            }

            let exceedsCount = current.count + 1 > maxTextCount
            let exceedsBytes = currentBytes + byteCount > maxTotalBytes
            if !current.isEmpty, exceedsCount || exceedsBytes {
                batches.append(current)
                current = []
                currentBytes = 0
            }

            current.append(text)
            currentBytes += byteCount
        }

        if !current.isEmpty {
            batches.append(current)
        }
        return batches
    }
}
