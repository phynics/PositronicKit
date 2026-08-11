import Foundation
import PKPrompt

private struct FixturePrompt: Prompt, Identifiable {
    let id: String

    var body: some Prompt {
        SystemPrompt("stable fixture content")
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

@main
struct PromptJournalProcessFixture {
    static func main() async throws {
        guard let mode = CommandLine.arguments.dropFirst().first else {
            throw FixtureError.missingMode
        }

        switch mode {
        case "create":
            let rendered = try await renderPrompt()
            var journal = PromptJournal()
            _ = try journal.observe(rendered)
            try writeJSON(JournalSnapshot(
                state: journal.state,
                path: try requirePath(from: rendered)
            ))

        case "restore":
            let snapshot = try JSONDecoder().decode(
                JournalSnapshot.self,
                from: FileHandle.standardInput.readDataToEndOfFile()
            )
            var journal = PromptJournal(state: snapshot.state)
            let rendered = try await renderPrompt()
            let plan = try journal.observe(rendered)
            try writeJSON(RestoreResult(
                path: try requirePath(from: rendered),
                requiresHardReset: plan.requiresHardReset
            ))

        default:
            throw FixtureError.unknownMode(mode)
        }
    }

    private static func renderPrompt() async throws -> RenderedPrompt {
        let assembled = try FixturePrompt(id: "same-id").assemblePrompt()
        return await assembled.render()
    }

    private static func requirePath(from prompt: RenderedPrompt) throws -> [String] {
        guard let path = prompt.sections.first?.path else {
            throw FixtureError.missingRenderedSection
        }
        return path
    }

    private static func writeJSON<T: Encodable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

private enum FixtureError: Error {
    case missingMode
    case unknownMode(String)
    case missingRenderedSection
}
