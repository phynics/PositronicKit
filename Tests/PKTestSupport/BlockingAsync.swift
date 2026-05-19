import Foundation

final class BlockingAsyncBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?

    init() {}
}

enum BlockingAsync {
    static func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = BlockingAsyncBox<T>()

        Task {
            do {
                box.result = Result.success(try await operation())
            } catch {
                box.result = Result.failure(error)
            }
            semaphore.signal()
        }

        semaphore.wait()
        return try box.result!.get()
    }
}
