import MonadShared
import Testing
import OpenAI
import Foundation

@Suite final class APIRequestsTests {
    private func assertCodable<T: Codable & Equatable>(_ value: T) throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(value)
        let decoded = try decoder.decode(T.self, from: data)
        #expect(value == decoded)
    }

    @Test

    func testChatQueryCodable() throws {
        let message = ChatQuery.ChatCompletionMessageParam(role: .user, content: "Hello")!
        let query = ChatQuery(messages: [message], model: "test-model")
        try assertCodable(query)
    }

    @Test

    func testChatQueryWithToolsCodable() throws {
        let message = ChatQuery.ChatCompletionMessageParam(role: .user, content: "What's the weather?")!
        let tool = ChatQuery.ChatCompletionToolParam(
            function: .init(
                name: "get_weather",
                description: "Gets the weather"
                // omitting parameters to bypass initializer complexity since we're just testing codability round trips
            )
        )
        let query = ChatQuery(messages: [message], model: "test-model", tools: [tool])
        try assertCodable(query)
    }
}
