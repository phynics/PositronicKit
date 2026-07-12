import Foundation

package enum LimitedErrorBodyCollector {
    package static let defaultLimit = 8 * 1024

    package static func collect<Lines: AsyncSequence>(
        from lines: Lines,
        limit: Int = defaultLimit
    ) async throws -> String where Lines.Element == String {
        guard limit > 0 else { return "" }

        var body = ""
        body.reserveCapacity(limit)

        for try await line in lines {
            if Task.isCancelled { break }
            let remaining = limit - body.count
            guard remaining > 0 else { break }

            if line.count <= remaining {
                body += line
            } else {
                body += line.prefix(remaining)
                break
            }
        }

        return body
    }
}
