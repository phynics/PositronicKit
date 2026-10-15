import Foundation
import PKContracts
import PKSQLiteStorage
import PositronicKit
import Testing

/// Crash durability: a real child process commits a Turn transition and terminates without an
/// orderly close. The parent reopens the file and checks that the committed state — and only the
/// committed state — survived.
@Suite("PKSQLiteStorage crash durability")
struct PKSQLiteCrashDurabilityTests {
    @Test("an admitted Turn and its membership survive an abrupt process exit")
    func admittedTurnSurvivesAbruptExit() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("admit.sqlite")
        let output = try runFixture(database: database, mode: "admit")

        let storage = try await PKSQLiteStorage.open(at: database)
        let repository = storage.persistenceConfiguration.runtimeRepository

        let active = try #require(try await repository.fetchActiveTurn(for: output.timelineID))
        #expect(active.identity.turnID == output.turnID)
        #expect(active.identity.requestID == output.requestID)
        #expect(active.isTerminal == false)
        let membership = try #require(try await repository.fetchTurnMessages(turnID: output.turnID))
        #expect(membership.map(\.id) == [output.messageID])
        #expect(try await repository.fetchMessages(for: output.timelineID).map(\.id) == [output.messageID])

        try await storage.close()
    }

    @Test("a quarantined Turn survives an abrupt process exit and blocks admission")
    func quarantinedTurnSurvivesAbruptExit() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("quarantine.sqlite")
        let output = try runFixture(database: database, mode: "quarantine")

        let storage = try await PKSQLiteStorage.open(at: database)
        let repository = storage.persistenceConfiguration.runtimeRepository

        #expect(try await repository.fetchActiveTurn(for: output.timelineID) == nil)
        let turn = try #require(try await repository.fetchTurn(id: output.turnID))
        #expect(turn.isQuarantined)
        #expect(turn.quarantine?.reason == "Unresolved mutating tool intent call-1.")
        #expect(turn.outcome == .interrupted(reason: "fixture killed before the terminal commit"))
        #expect(try await repository.fetchToolIntents(turnID: output.turnID).count == 1)

        await #expect(throws: TimelineRuntimeRepositoryError.self) {
            _ = try await repository.admitTurn(
                timelineID: output.timelineID,
                requestID: UUID(),
                callerIntentFingerprint: "after-crash",
                inputMessage: nil,
                now: Date()
            )
        }

        let released = try await repository.releaseQuarantine(
            timelineID: output.timelineID,
            turnID: output.turnID,
            confirmation: QuarantineReleaseConfirmation(phrase: QuarantineReleaseConfirmation.requiredPhrase),
            now: Date()
        )
        #expect(!released.isQuarantined)
        try await storage.close()
    }

    // MARK: Fixture process

    private struct FixtureOutput: Codable {
        let timelineID: UUID
        let requestID: UUID
        let turnID: UUID
        let messageID: UUID
    }

    private func runFixture(database: URL, mode: String) throws -> FixtureOutput {
        let process = Process()
        process.executableURL = try fixtureExecutableURL()
        process.arguments = [database.path, mode]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw FixtureProcessError(
                status: process.terminationStatus,
                message: String(decoding: error, as: UTF8.self)
            )
        }
        return try JSONDecoder().decode(FixtureOutput.self, from: output)
    }

    /// `swift test` builds the fixture beside the test bundle. Walking up from the test binary
    /// avoids launching `swift run` from inside the test process, which can deadlock on SwiftPM's
    /// build-directory lock.
    private func fixtureExecutableURL() throws -> URL {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        var argvDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
            .deletingLastPathComponent()
        for _ in 0 ..< 6 {
            candidates.append(argvDirectory.appendingPathComponent("PKSQLiteCrashFixture"))
            argvDirectory.deleteLastPathComponent()
        }

        var bundleDirectory = Bundle(for: FixtureBundleMarker.self)
            .bundleURL
            .standardizedFileURL
            .deletingLastPathComponent()
        for _ in 0 ..< 6 {
            candidates.append(bundleDirectory.appendingPathComponent("PKSQLiteCrashFixture"))
            bundleDirectory.deleteLastPathComponent()
        }

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw FixtureProcessError(status: -1, message: "Could not locate PKSQLiteCrashFixture.")
    }

    private final class FixtureBundleMarker {}

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pk-sqlite-crash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct FixtureProcessError: Error, CustomStringConvertible {
    let status: Int32
    let message: String

    var description: String {
        "PKSQLiteCrashFixture exited with status \(status): \(message)"
    }
}
