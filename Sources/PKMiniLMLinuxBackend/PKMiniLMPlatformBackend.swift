import Foundation
import PKFastEmbed
import PositronicKit

public actor PKMiniLMPlatformBackend: Sendable {
    private let model: MiniLMEmbedder

    public init(modelDirectory: URL) throws {
        do {
            self.model = try MiniLMEmbedder(modelDirectory: modelDirectory)
        } catch let error as PKFastEmbedError {
            throw Self.mapError(error)
        }
    }

    public func generateEmbedding(for text: String) async throws -> [Float] {
        do {
            return try model.embed(text)
        } catch let error as PKFastEmbedError {
            throw Self.mapError(error)
        }
    }

    public func generateEmbeddings(for texts: [String]) async throws -> [[Float]] {
        do {
            return try model.embed(texts)
        } catch let error as PKFastEmbedError {
            throw Self.mapError(error)
        }
    }

    private static func mapError(_ error: PKFastEmbedError) -> EmbeddingError {
        switch error {
        case .modelLoadFailed:
            return .nativeInitializationFailed
        case .bufferTooSmall, .inferenceFailed, .invalidUTF8, .invalidArgument, .nativeFailure:
            return .generationFailed
        case .abiMismatch:
            return .nativeInitializationFailed
        }
    }
}
