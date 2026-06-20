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
            "Sources/PositronicKit/Services/LLM/ProviderHTTPTransport.swift",
            "Sources/PositronicKit/Services/LLM/ProviderHTTPFailure.swift",
            "Sources/PKOpenRouterProvider/OpenRouterClient.swift",
            "Sources/PKOllamaProvider/OllamaClient.swift",
            "Sources/PKOpenAIProvider/OpenAIClient.swift",
        ]

        for file in files {
            let path = root.appendingPathComponent(file)
            let contents = try String(contentsOf: path, encoding: .utf8)
            #expect(
                contents.contains(
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
