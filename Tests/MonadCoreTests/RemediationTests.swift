import Foundation
@testable import MonadCore
@testable import MonadShared
import Testing

struct RemediationTests {
    @Test("ToolError provides remediation hints")
    func toolErrorRemediation() {
        let missingArg = ToolError.missingArgument("path")
        #expect(missingArg == .missingArgument("path"))
        #expect(missingArg.remediation != nil)

        let invalidArg = ToolError.invalidArgument("count", expected: "Int", got: "String")
        #expect(invalidArg == .invalidArgument("count", expected: "Int", got: "String"))
        #expect(invalidArg.remediation != nil)
    }

    @Test("Configuration validation identifies missing API keys")
    func configurationValidation() {
        var config = LLMConfiguration.default
        config.providers[.openAI] = ProviderConfiguration(
            endpoint: "test",
            apiKey: "",
            modelName: "gpt-4",
            utilityModel: "gpt-4",
            fastModel: "gpt-4",
            toolFormat: .openAI
        )

        #expect(throws: ConfigurationError.self) {
            try config.validate()
        }
    }
}
