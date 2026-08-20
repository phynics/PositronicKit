import Foundation
import OpenAI
@testable import PKOpenAIProvider
import PKContracts
import PKUtilities
import Testing

struct OpenAIMessageConversionValidationTests {
    @Test("Tool-role message with nil toolCallID throws a typed validation error")
    func toolMessageWithNilToolCallIDThrows() throws {
        let message = LLMMessage(role: .tool, content: "result", toolCallID: nil)
        do {
            _ = try message.toOpenAIMessageParam()
            Issue.record("Expected malformed tool history to be rejected")
        } catch let error as LLMMessageValidationError {
            #expect(error.errorDomain == PKErrorDomain.llm)
            #expect(error.errorCode == 1005)
            #expect(error.remediation != nil)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Tool-role message with a toolCallID preserves the OpenAI wire value")
    func toolMessageWithToolCallIDPreservesWireValue() throws {
        let message = LLMMessage(role: .tool, content: "result", toolCallID: "call_1")
        let param = try message.toOpenAIMessageParam()

        guard case let .tool(toolMessage) = param else {
            Issue.record("Expected a .tool message param")
            return
        }
        #expect(toolMessage.toolCallId == "call_1")
    }
}
