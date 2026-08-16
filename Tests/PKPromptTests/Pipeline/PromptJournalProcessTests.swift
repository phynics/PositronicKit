import Foundation
import PKPrompt
import Testing

@Suite("PromptJournal process stability")
struct PromptJournalProcessTests {
    @Test("Stable prompt identity survives launches and journal restoration")
    func stableIdentitySurvivesProcessRestart() throws {
        let snapshotData = try runFixture(mode: "create")
        let snapshot = try JSONDecoder().decode(JournalSnapshot.self, from: snapshotData)

        let restoredData = try runFixture(mode: "restore", input: snapshotData)
        let restored = try JSONDecoder().decode(RestoreResult.self, from: restoredData)

        #expect(restored.path == snapshot.path)
        #expect(restored.requiresHardReset == false)
    }

    private func runFixture(mode: String, input: Data? = nil) throws -> Data {
        let process = Process()
        process.executableURL = try fixtureExecutableURL()
        process.arguments = [mode]
        process.currentDirectoryURL = packageRoot

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe

        try process.run()
        if let input {
            inputPipe.fileHandleForWriting.write(input)
        }
        inputPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw FixtureProcessError(
                status: process.terminationStatus,
                message: String(decoding: error, as: UTF8.self)
            )
        }

        guard let jsonLine = String(decoding: output, as: UTF8.self)
            .split(separator: "\n")
            .last
        else {
            throw FixtureProcessError(status: process.terminationStatus, message: "Fixture produced no output.")
        }
        return Data(jsonLine.utf8)
    }

    /// `swift test` has already built the fixture beside the package test bundle.
    /// Launching `swift run` from inside the test process can deadlock on SwiftPM's
    /// build-directory lock because the parent `swift test` is still active.
    private func fixtureExecutableURL() throws -> URL {
        let fileManager = FileManager.default

        // The fixture lands beside the test bundle (`.build/.../debug`), so walk up
        // from the test binary. Newer SwiftPM toolchains launch test bundles through
        // `swiftpm-testing-helper`, which repoints `argv[0]` at the toolchain — so also
        // anchor on the test bundle itself before giving up.
        var candidates: [URL] = []

        var argvDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
            .deletingLastPathComponent()
        for _ in 0 ..< 6 {
            candidates.append(argvDirectory.appendingPathComponent("PKPromptJournalProcessFixture"))
            argvDirectory.deleteLastPathComponent()
        }

        var bundleDirectory = Bundle(for: FixtureBundleMarker.self)
            .bundleURL
            .standardizedFileURL
            .deletingLastPathComponent()
        for _ in 0 ..< 6 {
            candidates.append(bundleDirectory.appendingPathComponent("PKPromptJournalProcessFixture"))
            bundleDirectory.deleteLastPathComponent()
        }

        for candidate in candidates {
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        throw FixtureProcessError(
            status: -1,
            message: "Could not locate the built PKPromptJournalProcessFixture executable."
        )
    }

    private final class FixtureBundleMarker {}

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct JournalSnapshot: Codable {
    let state: PromptJournal.State
    let path: [String]
}

private struct RestoreResult: Codable {
    let path: [String]
    let requiresHardReset: Bool
}

private struct FixtureProcessError: Error, CustomStringConvertible {
    let status: Int32
    let message: String

    var description: String {
        "Prompt journal fixture exited with status \(status): \(message)"
    }
}
