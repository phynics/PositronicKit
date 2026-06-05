import Foundation

package enum CancellableAsyncThrowingStream {
    package static func make<Element: Sendable>(
        of _: Element.Type = Element.self,
        _ operation: @escaping @Sendable (AsyncThrowingStream<Element, Error>.Continuation) async -> Void
    ) -> AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream<Element, Error> { continuation in
            let task = Task {
                await operation(continuation)
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
