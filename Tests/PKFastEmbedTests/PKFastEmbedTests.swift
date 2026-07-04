#if MiniLMEmbeddings
    import CPKFastEmbed
    import Foundation
    @testable import PKFastEmbed
    import PKShared
    import Testing
    import XCTest

    @Suite("PKFastEmbed wrapper")
    struct PKFastEmbedTests {
        @Test("missing model directory surfaces a model load failure")
        func missingModelDirectory() throws {
            #expect(throws: PKFastEmbedError.self) {
                _ = try MiniLMEmbedder(modelDirectory: URL(fileURLWithPath: "/definitely/missing"))
            }
        }

        @Test("real pinned MiniLM model embeds to 384 dimensions")
        func embedsPinnedModel() throws {
            guard let model = try makeModel() else {
                return
            }
            let vector = try model.embed("The cat sits on the mat.")

            #expect(vector.count == 384)
            #expect(abs(l2Norm(vector) - 1) < 0.000_01)
        }

        @Test("native batch embeddings match repeated single embeddings")
        func batchMatchesSingles() throws {
            guard let model = try makeModel() else {
                return
            }
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
            guard let model = try makeModel() else {
                return
            }
            #expect(try model.embed([]).isEmpty)
        }

        @Test("native batch call preserves UTF-8 bytes for a large mixed batch")
        func batchPreservesUTF8Bytes() throws {
            let harness = NativeAPIHarness(dimensions: 6)
            let model = try MiniLMEmbedder(
                modelDirectory: URL(fileURLWithPath: "/fake/model"),
                nativeAPI: harness.nativeAPI
            )

            let fixtures = [
                "",
                "a",
                "café",
                "cafe\u{301}",
                "🙂",
                "line\0break",
                String(repeating: "prefix-", count: 20) + "tail-a",
                String(repeating: "prefix-", count: 20) + "tail-b",
            ]
            let texts = (0 ..< EmbeddingBudgetFixture.maxTextCount).map { fixtures[$0 % fixtures.count] }

            let batch = try model.embed(texts)
            let singles = try texts.map { try model.embed($0) }

            #expect(harness.batchCallCount == 1)
            #expect(harness.singleCallCount == texts.count)
            #expect(harness.batchInputs == texts.map { Array($0.utf8) })
            #expect(harness.batchLengths == texts.map(\.utf8.count))
            #expect(batch.count == texts.count)
            #expect(batch == singles)
        }

        @Test("batch output allocation overflow is rejected before native inference")
        func batchOutputOverflowIsRejected() throws {
            let harness = NativeAPIHarness(dimensions: Int.max)
            let model = try MiniLMEmbedder(
                modelDirectory: URL(fileURLWithPath: "/fake/model"),
                nativeAPI: harness.nativeAPI
            )

            XCTAssertThrowsError(try model.embed(["one", "two"])) { error in
                guard let error = error as? PKFastEmbedError else {
                    return XCTFail("Expected PKFastEmbedError, got \(error)")
                }
                if case .invalidArgument = error {
                    return
                } else {
                    XCTFail("Expected invalidArgument, got \(error)")
                }
            }

            #expect(harness.batchCallCount == 0)
        }

        @Test("single embeddings over the default byte limit are rejected before native inference")
        func singleTextOverDefaultByteLimitIsRejected() throws {
            let harness = NativeAPIHarness(dimensions: 6)
            let model = try MiniLMEmbedder(
                modelDirectory: URL(fileURLWithPath: "/fake/model"),
                nativeAPI: harness.nativeAPI
            )
            let text = String(repeating: "a", count: EmbeddingBudgetFixture.maxBytesPerText + 1)

            XCTAssertThrowsError(try model.embed(text)) { error in
                guard case let PKFastEmbedError.budgetExceeded(validationError) = error else {
                    return XCTFail("Expected budgetExceeded, got \(error)")
                }
                guard case let .perTextByteLimitExceeded(max, actual) = validationError else {
                    return XCTFail("Expected perTextByteLimitExceeded, got \(validationError)")
                }
                XCTAssertEqual(max, EmbeddingBudgetFixture.maxBytesPerText)
                XCTAssertEqual(actual, EmbeddingBudgetFixture.maxBytesPerText + 1)
            }

            #expect(harness.singleCallCount == 0)
        }

        @Test("single embeddings over a custom total-byte limit are rejected before native inference")
        func singleTextOverCustomTotalByteLimitIsRejected() throws {
            let harness = NativeAPIHarness(dimensions: 6)
            let model = try MiniLMEmbedder(
                modelDirectory: URL(fileURLWithPath: "/fake/model"),
                inputBudget: EmbeddingInputBudget(maxTextCount: 4, maxBytesPerText: 10, maxTotalBytes: 5),
                nativeAPI: harness.nativeAPI
            )

            XCTAssertThrowsError(try model.embed("123456")) { error in
                guard case let PKFastEmbedError.budgetExceeded(validationError) = error else {
                    return XCTFail("Expected budgetExceeded, got \(error)")
                }
                guard case let .totalBatchByteLimitExceeded(max, actual) = validationError else {
                    return XCTFail("Expected totalBatchByteLimitExceeded, got \(validationError)")
                }
                XCTAssertEqual(max, 5)
                XCTAssertEqual(actual, 6)
            }

            #expect(harness.singleCallCount == 0)
        }

        @Test("batches over the default text-count limit are rejected before native inference")
        func batchOverDefaultTextCountLimitIsRejected() throws {
            let harness = NativeAPIHarness(dimensions: 6)
            let model = try MiniLMEmbedder(
                modelDirectory: URL(fileURLWithPath: "/fake/model"),
                nativeAPI: harness.nativeAPI
            )
            let texts = Array(repeating: "a", count: EmbeddingBudgetFixture.maxTextCount + 1)

            XCTAssertThrowsError(try model.embed(texts)) { error in
                guard case let PKFastEmbedError.budgetExceeded(validationError) = error else {
                    return XCTFail("Expected budgetExceeded, got \(error)")
                }
                guard case let .batchTextCountLimitExceeded(max, actual) = validationError else {
                    return XCTFail("Expected batchTextCountLimitExceeded, got \(validationError)")
                }
                XCTAssertEqual(max, EmbeddingBudgetFixture.maxTextCount)
                XCTAssertEqual(actual, EmbeddingBudgetFixture.maxTextCount + 1)
            }

            #expect(harness.batchCallCount == 0)
        }

        @Test("batches over the default total-byte limit are rejected before native inference")
        func batchOverDefaultTotalByteLimitIsRejected() throws {
            let harness = NativeAPIHarness(dimensions: 6)
            let model = try MiniLMEmbedder(
                modelDirectory: URL(fileURLWithPath: "/fake/model"),
                nativeAPI: harness.nativeAPI
            )
            let text = String(repeating: "a", count: EmbeddingBudgetFixture.maxBytesPerText)
            let texts = Array(repeating: text, count: (EmbeddingBudgetFixture.maxTotalBytes / EmbeddingBudgetFixture.maxBytesPerText) + 1)

            XCTAssertThrowsError(try model.embed(texts)) { error in
                guard case let PKFastEmbedError.budgetExceeded(validationError) = error else {
                    return XCTFail("Expected budgetExceeded, got \(error)")
                }
                guard case let .totalBatchByteLimitExceeded(max, actual) = validationError else {
                    return XCTFail("Expected totalBatchByteLimitExceeded, got \(validationError)")
                }
                XCTAssertEqual(max, EmbeddingBudgetFixture.maxTotalBytes)
                XCTAssertEqual(
                    actual,
                    EmbeddingBudgetFixture.maxBytesPerText
                        * ((EmbeddingBudgetFixture.maxTotalBytes / EmbeddingBudgetFixture.maxBytesPerText) + 1)
                )
            }

            #expect(harness.batchCallCount == 0)
        }

        @Test("successful initialization destroys the native handle once when released")
        func successfulInitializationDestroysHandleOnce() throws {
            let harness = NativeAPIHarness(dimensions: 4)
            var model: MiniLMEmbedder? = try MiniLMEmbedder(
                modelDirectory: URL(fileURLWithPath: "/fake/model"),
                nativeAPI: harness.nativeAPI
            )

            #expect(model?.dimensions == 4)
            #expect(harness.createCount == 1)
            #expect(harness.dimensionsCount == 1)
            #expect(harness.destroyCount == 0)

            model = nil
            #expect(harness.destroyCount == 1)
        }

        @Test("a failing dimensions query releases the created handle")
        func failingDimensionsQueryReleasesHandle() throws {
            let harness = NativeAPIHarness(
                dimensions: 4,
                dimensionsStatus: PKFE_STATUS_MODEL_LOAD_FAILED
            )

            XCTAssertThrowsError(
                try MiniLMEmbedder(
                    modelDirectory: URL(fileURLWithPath: "/fake/model"),
                    nativeAPI: harness.nativeAPI
                )
            )

            #expect(harness.createCount == 1)
            #expect(harness.dimensionsCount == 1)
            #expect(harness.destroyCount == 1)
        }

        @Test("zero native dimensions are rejected and release the handle")
        func zeroNativeDimensionsReleaseHandle() throws {
            let harness = NativeAPIHarness(dimensions: 0)

            XCTAssertThrowsError(
                try MiniLMEmbedder(
                    modelDirectory: URL(fileURLWithPath: "/fake/model"),
                    nativeAPI: harness.nativeAPI
                )
            )

            #expect(harness.createCount == 1)
            #expect(harness.dimensionsCount == 1)
            #expect(harness.destroyCount == 1)
        }

        @Test("model create failure does not destroy a null handle")
        func createFailureDoesNotDestroyHandle() throws {
            let harness = NativeAPIHarness(
                dimensions: 4,
                createStatus: PKFE_STATUS_MODEL_LOAD_FAILED
            )

            XCTAssertThrowsError(
                try MiniLMEmbedder(
                    modelDirectory: URL(fileURLWithPath: "/fake/model"),
                    nativeAPI: harness.nativeAPI
                )
            )

            #expect(harness.createCount == 1)
            #expect(harness.dimensionsCount == 0)
            #expect(harness.destroyCount == 0)
        }

        @Test("repeated failed initialization destroys every created handle")
        func repeatedFailedInitializationDestroysEveryHandle() throws {
            let harness = NativeAPIHarness(
                dimensions: 4,
                dimensionsStatus: PKFE_STATUS_MODEL_LOAD_FAILED
            )

            for _ in 0 ..< 32 {
                XCTAssertThrowsError(
                    try MiniLMEmbedder(
                        modelDirectory: URL(fileURLWithPath: "/fake/model"),
                        nativeAPI: harness.nativeAPI
                    )
                )
            }

            #expect(harness.createCount == 32)
            #expect(harness.dimensionsCount == 32)
            #expect(harness.destroyCount == 32)
        }

        @Test("raw C API rejects malformed UTF-8")
        func rawAPIRejectsInvalidUTF8() throws {
            guard let model = try makeRawModel() else {
                return
            }
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
            guard let model = try makeRawModel() else {
                return
            }
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

        private func makeModel() throws -> MiniLMEmbedder? {
            guard let modelDirectory = modelDirectory() else {
                return nil
            }
            return try MiniLMEmbedder(modelDirectory: modelDirectory)
        }

        private func makeRawModel() throws -> OpaquePointer? {
            guard pkfe_abi_version() == PKFASTEMBED_ABI_VERSION else {
                throw PKFastEmbedError.abiMismatch
            }

            var model: OpaquePointer?
            var errorPointer: UnsafeMutablePointer<CChar>?
            guard let path = modelDirectory()?.path else {
                return nil
            }
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

        private func modelDirectory() -> URL? {
            guard let path = ProcessInfo.processInfo.environment["PK_MINILM_MODEL_DIR"], !path.isEmpty else {
                return nil
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        private func l2Norm(_ vector: [Float]) -> Float {
            sqrt(vector.reduce(0) { $0 + ($1 * $1) })
        }
    }

    private enum EmbeddingBudgetFixture {
        static let maxTextCount = 64
        static let maxBytesPerText = 65536
        static let maxTotalBytes = 262_144
    }

    private final class NativeAPIHarness: @unchecked Sendable {
        let handle = OpaquePointer(bitPattern: 0x1)!
        let dimensions: Int

        var createStatus: pkfe_status_t
        var dimensionsStatus: pkfe_status_t
        var createCount = 0
        var dimensionsCount = 0
        var destroyCount = 0
        var singleCallCount = 0
        var batchCallCount = 0
        var singleInputs: [[UInt8]] = []
        var batchInputs: [[UInt8]] = []
        var batchLengths: [Int] = []

        init(
            dimensions: Int,
            createStatus: pkfe_status_t = PKFE_STATUS_OK,
            dimensionsStatus: pkfe_status_t = PKFE_STATUS_OK
        ) {
            self.dimensions = dimensions
            self.createStatus = createStatus
            self.dimensionsStatus = dimensionsStatus
        }

        var nativeAPI: MiniLMEmbedder.NativeAPI {
            .init(
                abiVersion: { PKFASTEMBED_ABI_VERSION },
                modelCreate: { [unowned self] _, outModel, _ in
                    self.createCount += 1
                    guard self.createStatus == PKFE_STATUS_OK else {
                        return self.createStatus
                    }

                    outModel.pointee = self.handle
                    return PKFE_STATUS_OK
                },
                modelDimensions: { [unowned self] _, outDimensions, _ in
                    self.dimensionsCount += 1
                    guard self.dimensionsStatus == PKFE_STATUS_OK else {
                        return self.dimensionsStatus
                    }

                    outDimensions.pointee = self.dimensions
                    return PKFE_STATUS_OK
                },
                modelEmbed: { [unowned self] _, utf8Bytes, utf8Length, outBuffer, outCount, _ in
                    self.singleCallCount += 1
                    guard let outBuffer else {
                        return PKFE_STATUS_INVALID_ARGUMENT
                    }

                    let bytes = Self.captureBytes(from: utf8Bytes, length: utf8Length)
                    self.singleInputs.append(bytes)
                    let vector = self.embedding(for: bytes)
                    guard outCount >= vector.count else {
                        return PKFE_STATUS_BUFFER_TOO_SMALL
                    }

                    let output = UnsafeMutableBufferPointer(start: outBuffer, count: outCount)
                    for (index, value) in vector.enumerated() {
                        output[index] = value
                    }
                    return PKFE_STATUS_OK
                },
                modelEmbedBatch: { [unowned self] _, utf8Bytes, utf8Lengths, textCount, outBuffer, outCount, _ in
                    self.batchCallCount += 1
                    guard let utf8Bytes, let utf8Lengths, let outBuffer else {
                        return PKFE_STATUS_INVALID_ARGUMENT
                    }

                    let inputPointers = UnsafeBufferPointer(start: utf8Bytes, count: textCount)
                    let inputLengths = UnsafeBufferPointer(start: utf8Lengths, count: textCount)
                    let inputs = (0 ..< textCount).map { index in
                        Self.captureBytes(from: inputPointers[index], length: inputLengths[index])
                    }
                    self.batchInputs = inputs
                    self.batchLengths = inputs.map(\.count)

                    let expectedCount = self.dimensions * textCount
                    guard outCount >= expectedCount else {
                        return PKFE_STATUS_BUFFER_TOO_SMALL
                    }

                    let output = UnsafeMutableBufferPointer(start: outBuffer, count: outCount)
                    for (row, bytes) in inputs.enumerated() {
                        let vector = self.embedding(for: bytes)
                        let start = row * self.dimensions
                        for (offset, value) in vector.enumerated() {
                            output[start + offset] = value
                        }
                    }
                    return PKFE_STATUS_OK
                },
                modelDestroy: { [unowned self] _ in
                    self.destroyCount += 1
                }
            )
        }

        private static func captureBytes(from pointer: UnsafePointer<UInt8>?, length: Int) -> [UInt8] {
            guard length > 0 else {
                return []
            }

            guard let pointer else {
                return []
            }

            return Array(UnsafeBufferPointer(start: pointer, count: length))
        }

        private func embedding(for bytes: [UInt8]) -> [Float] {
            let seed = bytes.reduce(into: 0) { result, byte in
                result = result &* 31 &+ Int(byte)
            }
            return (0 ..< dimensions).map { Float((seed + $0) % 1000) }
        }
    }
#endif
