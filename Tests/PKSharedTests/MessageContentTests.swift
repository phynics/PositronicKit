import Foundation
@testable import PKShared
import Testing

final class MessageContentTests {
    @Test
    func legacyMessageEncodingDoesNotAddContentParts() throws {
        let message = Message(content: "hello", role: .user)
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any]
        )

        #expect(object["content"] as? String == "hello")
        #expect(object["contentParts"] == nil)
    }

    @Test
    func orderedContentRoundTripsThroughMessageAndLLMMessage() throws {
        let content = MessageContent(parts: [
            .text("look "),
            .image(ImageContent(data: Data([0x01, 0x02]), mediaType: "image/png", detail: .high)),
            .text("and listen "),
            .audio(AudioContent(data: Data([0x03, 0x04]), format: .wav, transcript: "hello")),
        ])

        let message = Message(content: content, role: .user)
        let decodedMessage = try JSONDecoder().decode(
            Message.self,
            from: JSONEncoder().encode(message)
        )
        #expect(decodedMessage.messageContent == content)
        #expect(decodedMessage.content == "look and listen ")

        let llmMessage = LLMMessage(role: .user, content: content)
        let decodedLLMMessage = try JSONDecoder().decode(
            LLMMessage.self,
            from: JSONEncoder().encode(llmMessage)
        )
        #expect(decodedLLMMessage.messageContent == content)
    }

    @Test
    func assigningLegacyContentReplacesMedia() {
        var message = Message(
            content: MessageContent(parts: [
                .image(ImageContent(data: Data([0x01]), mediaType: "image/png")),
            ]),
            role: .user
        )

        message.content = "replacement"

        #expect(message.messageContent == MessageContent("replacement"))
    }

    @Test
    func providerCapabilitiesDefaultWhenMissing() throws {
        let data = Data(#"{"endpoint":"x","apiKey":"","modelName":"m","utilityModel":"m","fastModel":"m","toolFormat":"openai"}"#.utf8)
        let decoded = try JSONDecoder().decode(ProviderConfiguration.self, from: data)
        #expect(decoded.capabilities.isEmpty)
    }
}
