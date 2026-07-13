import PKShared
import Foundation

struct FilesystemSearchLimits: Sendable {
    var wallClockSeconds: TimeInterval = 2
    var maxFiles: Int = 5_000
    var maxFileBytes: Int = 1_048_576
    var maxTotalBytes: Int = 8_388_608
    var maxOutputBytes: Int = 262_144
    var maxMatches: Int = 100
}

struct FilesystemSearchBudget {
    enum Failure: Error, Equatable {
        case timedOut
        case fileCountExceeded
        case fileTooLarge(String)
        case totalBytesExceeded
        case outputBytesExceeded
        case cancelled

        var message: String {
            switch self {
            case .timedOut:
                "Search timed out"
            case .fileCountExceeded:
                "Search exceeded file-count limit"
            case .fileTooLarge(let path):
                "Search rejected '\(path)' because it exceeds the per-file byte limit"
            case .totalBytesExceeded:
                "Search exceeded total byte limit"
            case .outputBytesExceeded:
                "Search exceeded output byte limit"
            case .cancelled:
                "Search was cancelled"
            }
        }
    }

    private let limits: FilesystemSearchLimits
    private let startedAt: Date
    private var fileCount = 0
    private var matchCount = 0
    private var totalBytes = 0
    private var outputBytes = 0

    init(limits: FilesystemSearchLimits, startedAt: Date = Date()) {
        self.limits = limits
        self.startedAt = startedAt
    }

    mutating func checkProgress() throws {
        if Task.isCancelled {
            throw Failure.cancelled
        }
        if Date().timeIntervalSince(startedAt) > limits.wallClockSeconds {
            throw Failure.timedOut
        }
    }

    mutating func reserveFile(_ url: URL, relativePath: String) throws -> Int {
        try checkProgress()
        fileCount += 1
        guard fileCount <= limits.maxFiles else {
            throw Failure.fileCountExceeded
        }

        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
        let fileBytes = resourceValues.fileSize ?? 0
        guard fileBytes <= limits.maxFileBytes else {
            throw Failure.fileTooLarge(relativePath)
        }

        totalBytes += fileBytes
        guard totalBytes <= limits.maxTotalBytes else {
            throw Failure.totalBytesExceeded
        }

        return fileBytes
    }

    mutating func reserveOutput(_ line: String) throws {
        try checkProgress()
        matchCount += 1
        outputBytes += line.utf8.count + 1
        guard outputBytes <= limits.maxOutputBytes else {
            throw Failure.outputBytesExceeded
        }
    }

    var hasMatchCapacity: Bool {
        matchCount < limits.maxMatches
    }
}
