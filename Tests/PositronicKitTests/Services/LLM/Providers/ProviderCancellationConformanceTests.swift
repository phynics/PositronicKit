import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
@testable import PKAnthropicProvider
@testable import PKFoundationModelsProvider
@testable import PKOllamaProvider
@testable import PKOpenRouterProvider
import PKContracts
import PKTestSupport
import Testing

private func cancellationResponse(url: String) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: url)!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "text/event-stream"]
    )!
}

private actor CancellationLatch {
    private var waiters: [CheckedContinuation<Void, Never>] = [] // swiftlint:disable:this concurrency_stored_continuation -- test latch resumes each waiter exactly once (see docs/Concurrency/exception-manifest.md)
    private var signaled = false

    func wait() async {
        if signaled {
            return
        }
        await withCheckedContinuation { continuation in
            if signaled {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func signal() {
        signaled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private struct CancellationFoundationModelsSession: FoundationModelsSessionProtocol {
    let started: CancellationLatch
    let terminated: CancellationLatch

    nonisolated func streamTurn(prompt _: String) -> AsyncThrowingStream<FoundationModelsSessionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await started.signal()
                continuation.yield(.textDelta("partial"))
                await withTaskCancellationHandler {
                    await terminated.wait()
                } onCancel: {
                    Task { await terminated.signal() }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await terminated.signal() }
            }
        }
    }
}

@Suite("Provider cancellation conformance")
struct ProviderCancellationConformanceTests {
    @Test("OpenRouter cancellation reaches the shared transport without a delay")
    func openRouterCancellationReachesTransport() async {
        let transport = ScriptedProviderHTTPTransport(responses: [
            .linesUntilCancelled(
                [#"data: {"id":"chunk-1","model":"fixture","choices":[{"index":0,"delta":{"content":"partial"}}]}"#],
                cancellationResponse(url: "https://openrouter.ai/api/v1/chat/completions")
            ),
        ])
        let client = OpenRouterClient(apiKey: "secret", maxRetries: 0, transport: transport)
        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "hello")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        )

        let consumer = Task {
            do {
                for try await _ in stream {}
            } catch {
                // Cancellation is the expected terminal path.
            }
        }
        await transport.waitForRequest()
        consumer.cancel()
        await transport.waitForTermination()
        _ = await consumer.value
    }

    @Test("Ollama cancellation reaches the shared transport without a delay")
    func ollamaCancellationReachesTransport() async {
        let transport = ScriptedProviderHTTPTransport(responses: [
            .linesUntilCancelled(
                [#"{"model":"fixture","message":{"role":"assistant","content":"partial"},"done":false}"#],
                cancellationResponse(url: "http://localhost:11434/api/chat")
            ),
        ])
        let client = OllamaClient(
            endpoint: "http://localhost:11434",
            modelName: "fixture",
            maxRetries: 0,
            transport: transport
        )
        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "hello")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        )

        let consumer = Task {
            do {
                for try await _ in stream {}
            } catch {
                // Cancellation is the expected terminal path.
            }
        }
        await transport.waitForRequest()
        consumer.cancel()
        await transport.waitForTermination()
        _ = await consumer.value
    }

    @Test("Anthropic cancellation reaches the shared transport without a delay")
    func anthropicCancellationReachesTransport() async {
        let transport = ScriptedProviderHTTPTransport(responses: [
            .linesUntilCancelled(
                [#"data: {"type":"message_start","message":{"id":"msg-1","model":"fixture"}}"#],
                cancellationResponse(url: "https://api.anthropic.com/v1/messages")
            ),
        ])
        let client = AnthropicClient(apiKey: "secret", maxRetries: 0, transport: transport)
        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "hello")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        )

        let consumer = Task {
            do {
                for try await _ in stream {}
            } catch {
                // Cancellation is the expected terminal path.
            }
        }
        await transport.waitForRequest()
        consumer.cancel()
        await transport.waitForTermination()
        _ = await consumer.value
    }

    @Test("Foundation Models cancellation reaches the scripted session without a delay")
    func foundationModelsCancellationReachesSession() async {
        let started = CancellationLatch()
        let terminated = CancellationLatch()
        let session = CancellationFoundationModelsSession(started: started, terminated: terminated)
        let client = FoundationModelsClient(makeSession: { _, _ in session })
        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "hello")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        )

        let consumer = Task {
            do {
                for try await _ in stream {}
            } catch {
                // Cancellation is the expected terminal path.
            }
        }
        await started.wait()
        consumer.cancel()
        await terminated.wait()
        _ = await consumer.value
    }
}
