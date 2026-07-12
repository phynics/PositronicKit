import Foundation
import Testing

@Suite("FoundationNetworking import audit")
struct FoundationNetworkingImportAuditTests {
    @Test("Networking sources include conditional FoundationNetworking imports")
    func networkingSourcesIncludeConditionalImports() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let files = [
            "Sources/PKUtilities/ProviderHTTPTransport.swift",
            "Sources/PKUtilities/ProviderHTTPFailure.swift",
            "Sources/PKOpenRouterProvider/OpenRouterClient.swift",
            "Sources/PKOllamaProvider/OllamaClient.swift",
            "Sources/PKOpenAIProvider/OpenAIClient.swift",
        ]

        for file in files {
            let path = root.appendingPathComponent(file)
            let contents = try String(contentsOf: path, encoding: .utf8)
            // Match the canonical block irrespective of indentation: `swift-format`
            // (indentConditionalCompilationBlocks) may indent the inner import, so
            // assert on the structure rather than exact leading whitespace.
            let normalized = contents
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
            #expect(
                normalized.contains(
                    """
                    #if canImport(FoundationNetworking)
                    import FoundationNetworking
                    #endif
                    """
                ),
                "\(file) is missing the required conditional FoundationNetworking import"
            )
        }
    }
}
