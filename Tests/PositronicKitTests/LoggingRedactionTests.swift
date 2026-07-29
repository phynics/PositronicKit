import Foundation
import Logging
import PKShared
import PKUtilities
import Testing
@testable import PositronicKit

@Suite("Logging redaction")
struct LoggingRedactionTests {
    @Test("ChatRunRequest description does not include the user message")
    func requestDescriptionDoesNotLeakMessage() {
        let secret = "user-secret-prompt-7f3c"
        let request = ChatRunRequest(timelineId: UUID(), message: secret)

        #expect(!request.description.contains(secret))
        #expect(request.description.contains("message: <redacted>"))
    }

    @Test("default logging configuration disables payloads and sanitizes structured text")
    func defaultLoggingPolicy() {
        let configuration = LoggingConfiguration.default

        #expect(!configuration.redactionPolicy.logsPayloads)
        #expect(configuration.redactionPolicy.sanitize("failed \u{1B}[31m🛠️\u{1B}[0m") == "failed [redacted]")
        #expect(configuration.redactionPolicy.payload("secret") == "[redacted]")
    }

    @Test("logged errors expose stable identity and correlation metadata")
    func errorMetadata() {
        let metadata = LoggingMetadata.forError(
            ToolError.executionFailed("secret response"),
            correlationID: "corr-123"
        )

        #expect(metadata[LogKeys.errorDomain]?.description == PKErrorDomain.tool)
        #expect(metadata[LogKeys.errorCode]?.description == "203")
        #expect(metadata[LogKeys.correlationID]?.description == "corr-123")
    }
}
