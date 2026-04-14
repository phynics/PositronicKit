import Foundation

/// Strategy for ensuring the prompt fits within a token limit
public struct TokenBudget: Sendable {
    public let maxTokens: Int
    public let reserveForResponse: Int

    public init(maxTokens: Int, reserveForResponse: Int) {
        self.maxTokens = maxTokens
        self.reserveForResponse = reserveForResponse
    }

    /// Apply the budget to a list of sections, returning a potentially modified list
    /// - Parameters:
    ///   - sections: The sections to process
    ///   - compressor: Optional compressor for .summarize strategy
    /// - Returns: A new list of sections that fits within the budget (best effort)
    public func apply(to sections: [ContextSection], compressor _: SectionCompressor? = nil) async -> [ContextSection] {
        let available = maxTokens - reserveForResponse
        let currentTotal = sections.reduce(0) { $0 + $1.estimatedTokens }

        // If we fit, return as is
        if currentTotal <= available {
            return sections
        }

        let indexedSections = sections.enumerated().map { (index: $0.offset, section: $0.element) }
        let sortedByPriority = indexedSections.sorted { $0.section.priority > $1.section.priority }

        let decisions = allocateBudget(sortedByPriority: sortedByPriority, available: available)

        return reconstructSections(indexedSections: indexedSections, decisions: decisions)
    }

    // MARK: - Budget Allocation

    /// Allocate budget to sections sorted by priority, returning a decision per original index
    private func allocateBudget(
        sortedByPriority: [(index: Int, section: ContextSection)],
        available: Int
    ) -> [Int: SectionDecision] {
        var decisions: [Int: SectionDecision] = [:]
        var remainingBudget = available

        for (index, section) in sortedByPriority {
            let size = section.estimatedTokens

            if size <= remainingBudget {
                decisions[index] = .keepOriginal
                remainingBudget -= size
            } else {
                decisions[index] = decideOverBudgetSection(section, remainingBudget: &remainingBudget)
            }
        }

        return decisions
    }

    /// Decide what to do with a section that does not fully fit in the remaining budget
    private func decideOverBudgetSection(
        _ section: ContextSection,
        remainingBudget: inout Int
    ) -> SectionDecision {
        switch section.strategy {
        case .keep:
            // Must keep — go into debt if needed
            remainingBudget -= section.estimatedTokens
            return .keepOriginal

        case .truncate:
            if remainingBudget > 0 {
                let limit = remainingBudget
                remainingBudget = 0
                return .constrain(limit: limit)
            }
            return .drop

        case .summarize, .drop:
            return .drop
        }
    }

    /// Reconstruct sections in original order based on allocation decisions
    private func reconstructSections(
        indexedSections: [(index: Int, section: ContextSection)],
        decisions: [Int: SectionDecision]
    ) -> [ContextSection] {
        var result: [ContextSection] = []
        for (index, section) in indexedSections {
            guard let decision = decisions[index] else { continue }

            switch decision {
            case .keepOriginal:
                result.append(section)
            case let .constrain(limit):
                result.append(section.constrained(to: limit))
            case .drop:
                break
            }
        }
        return result
    }

    private enum SectionDecision {
        case keepOriginal
        case constrain(limit: Int)
        case drop
    }
}
