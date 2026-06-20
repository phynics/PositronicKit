import CPKFastEmbed
import Foundation
import PKFastEmbed
import Testing
import XCTest

@Suite("PKFastEmbed wrapper")
struct PKFastEmbedTests {
    @Test("missing model directory surfaces a model load failure")
    func missingModelDirectory() async throws {
        await #expect(throws: PKFastEmbedError.self) {
            _ = try MiniLMEmbedder(modelDirectory: URL(fileURLWithPath: "/definitely/missing"))
        }
    }

    @Test("real pinned MiniLM model embeds to 384 dimensions")
    func embedsPinnedModel() throws {
        let model = try makeModel()
        let vector = try model.embed("The cat sits on the mat.")

        #expect(vector.count == 384)
        #expect(abs(l2Norm(vector) - 1) < 0.000_01)
    }

    @Test("native batch embeddings match repeated single embeddings")
    func batchMatchesSingles() throws {
        let model = try makeModel()
        let texts = ["alpha", "beta", "gamma"]

        let batch = try model.embed(texts)
        let singles = try texts.map { try model.embed($0) }

        #expect(batch.count == singles.count)
        for (lhs, rhs) in zip(batch, singles) {
            #expect(lhs.count == rhs.count)
            for (left, right) in zip(lhs, rhs) {
                #expect(abs(left - right) < 0.000_01)
            }
        }
    }

    @Test("empty batch returns no embeddings")
    func emptyBatch() throws {
        let model = try makeModel()
        #expect(try model.embed([]).isEmpty)
    }

    @Test("raw C API rejects malformed UTF-8")
    func rawAPIRejectsInvalidUTF8() throws {
        let model = try makeRawModel()
        defer { pkfe_model_destroy(model) }

        let invalidBytes = [UInt8](arrayLiteral: 0xFF, 0xFE)
        var output = Array(repeating: Float.zero, count: 384)
        var errorPointer: UnsafeMutablePointer<CChar>?

        let status = invalidBytes.withUnsafeBufferPointer { bytes in
            output.withUnsafeMutableBufferPointer { buffer in
                pkfe_model_embed(
                    model,
                    bytes.baseAddress,
                    bytes.count,
                    buffer.baseAddress,
                    buffer.count,
                    &errorPointer
                )
            }
        }
        defer {
            if let errorPointer {
                pkfe_string_destroy(errorPointer)
            }
        }

        #expect(status == PKFE_STATUS_INVALID_UTF8)
        #expect(errorPointer != nil)
    }

    @Test("raw C API rejects undersized output buffers")
    func rawAPIRejectsSmallBuffers() throws {
        let model = try makeRawModel()
        defer { pkfe_model_destroy(model) }

        let text = Array("hello".utf8)
        var output = Array(repeating: Float.zero, count: 32)
        var errorPointer: UnsafeMutablePointer<CChar>?

        let status = text.withUnsafeBufferPointer { bytes in
            output.withUnsafeMutableBufferPointer { buffer in
                pkfe_model_embed(
                    model,
                    bytes.baseAddress,
                    bytes.count,
                    buffer.baseAddress,
                    buffer.count,
                    &errorPointer
                )
            }
        }
        defer {
            if let errorPointer {
                pkfe_string_destroy(errorPointer)
            }
        }

        #expect(status == PKFE_STATUS_BUFFER_TOO_SMALL)
        #expect(errorPointer != nil)
    }

    private func makeModel() throws -> MiniLMEmbedder {
        try MiniLMEmbedder(modelDirectory: try modelDirectory())
    }

    private func makeRawModel() throws -> OpaquePointer {
        guard pkfe_abi_version() == PKFASTEMBED_ABI_VERSION else {
            throw PKFastEmbedError.abiMismatch
        }

        var model: OpaquePointer?
        var errorPointer: UnsafeMutablePointer<CChar>?
        let path = try modelDirectory().path
        let status = path.withCString { cPath in
            pkfe_model_create(cPath, &model, &errorPointer)
        }
        defer {
            if let errorPointer {
                pkfe_string_destroy(errorPointer)
            }
        }

        guard status == PKFE_STATUS_OK, let model else {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown"
            throw PKFastEmbedError.modelLoadFailed(message)
        }
        return model
    }

    private func modelDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["PK_MINILM_MODEL_DIR"], !path.isEmpty else {
            throw XCTSkip("Set PK_MINILM_MODEL_DIR to run the real model tests.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func l2Norm(_ vector: [Float]) -> Float {
        sqrt(vector.reduce(0) { $0 + ($1 * $1) })
    }
}
