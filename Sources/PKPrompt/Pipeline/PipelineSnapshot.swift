import Foundation

// MARK: - Protocols

public protocol PipelineSnapshotEntry: Sendable {
    associatedtype Content: Hashable & Sendable
    var entryId: String { get }
    var content: Content { get }
    var contentHash: UInt64 { get }
}

public extension PipelineSnapshotEntry {
    var contentHash: UInt64 {
        var hasher = Hasher()
        content.hash(into: &hasher)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }
}

public protocol PipelineSnapshot: Sendable {
    associatedtype Entry: PipelineSnapshotEntry
    var entries: [Entry] { get }
}
