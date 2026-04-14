import Foundation

// MARK: - Protocols

public enum PipelineSnapshotSectionKind: String, Sendable, Codable, Hashable {
    case section
    case group
    case synthetic
}

public protocol PipelineSnapshotEntry: Sendable {
    associatedtype Content: Hashable & Sendable
    var entryId: String { get }
    var content: Content { get }
    var contentHash: UInt64 { get }
    var path: [String] { get }
    var parentEntryId: String? { get }
    var order: Int? { get }
    var sectionKind: PipelineSnapshotSectionKind? { get }
}

public extension PipelineSnapshotEntry {
    var contentHash: UInt64 {
        var hasher = Hasher()
        content.hash(into: &hasher)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    var path: [String] {
        [entryId]
    }

    var parentEntryId: String? {
        nil
    }

    var order: Int? {
        nil
    }

    var sectionKind: PipelineSnapshotSectionKind? {
        nil
    }
}

public protocol PipelineSnapshot: Sendable {
    associatedtype Entry: PipelineSnapshotEntry
    var entries: [Entry] { get }
}
