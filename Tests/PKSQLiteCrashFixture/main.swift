import Foundation
import PKSQLiteStorage
import PositronicKit

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A process fixture that commits a durable Turn transition and then terminates without closing
/// the database. The test reopens the file and checks that the committed state survived and that
/// the exit did not expose a half-written Turn membership.
///
/// Usage: `PKSQLiteCrashFixture <database> <admit|quarantine>`
@main
struct PKSQLiteCrashFixture {
    struct FixtureOutput: Codable {
        let timelineID: UUID
        let requestID: UUID
        let turnID: UUID
        let messageID: UUID
    }

    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2 else {
            throw FixtureError.usage
        }
        let databaseURL = URL(fileURLWithPath: arguments[0])
        let mode = arguments[1]

        let storage = try await PKSQLiteStorage.open(at: databaseURL)
        let repository = storage.persistenceConfiguration.runtimeRepository

        let timelineID = UUID()
        let requestID = UUID()
        let turnID = UUID()
        let messageID = UUID()
        let input = TimelineMessage(id: messageID, timelineID: timelineID, role: .user, content: "crash input")

        try await repository.saveTimeline(TimelineRecord(id: timelineID, title: "crash fixture"))
        switch mode {
        case "admit":
            _ = try await repository.admitTurn(
                timelineID: timelineID,
                requestID: requestID,
                callerIntentFingerprint: "crash",
                inputMessage: input,
                executionKind: .agentManaged,
                capturedAgentID: nil,
                turnID: turnID,
                now: Date(timeIntervalSince1970: 10)
            )
        case "quarantine":
            _ = try await repository.admitTurn(
                timelineID: timelineID,
                requestID: requestID,
                callerIntentFingerprint: "crash-quarantine",
                inputMessage: input,
                executionKind: .agentManaged,
                capturedAgentID: nil,
                turnID: turnID,
                now: Date(timeIntervalSince1970: 10)
            )
            try await repository.recordToolIntent(RuntimeToolIntent(
                turnID: turnID,
                timelineID: timelineID,
                toolCallID: "call-1",
                name: "write-file",
                arguments: "{}",
                modelRoundIndex: 0,
                sideEffects: .mutating,
                createdAt: Date(timeIntervalSince1970: 10)
            ))
            _ = try await repository.interruptTurn(
                turnID: turnID,
                reason: "fixture killed before the terminal commit",
                disposition: .quarantined("Unresolved mutating tool intent call-1."),
                now: Date(timeIntervalSince1970: 11)
            )
        default:
            throw FixtureError.unknownMode(mode)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var output = try encoder.encode(FixtureOutput(
            timelineID: timelineID,
            requestID: requestID,
            turnID: turnID,
            messageID: messageID
        ))
        output.append(0x0A)
        try FileHandle.standardOutput.write(contentsOf: output)

        // Terminate without an orderly close so the parent observes the durable state alone.
        _exit(0)
    }

    enum FixtureError: Error, CustomStringConvertible {
        case usage
        case unknownMode(String)

        var description: String {
            switch self {
            case .usage:
                return "usage: PKSQLiteCrashFixture <database> <admit|quarantine>"
            case let .unknownMode(mode):
                return "unknown mode: \(mode)"
            }
        }
    }
}
