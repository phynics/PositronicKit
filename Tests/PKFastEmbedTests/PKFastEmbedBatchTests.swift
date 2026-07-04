#if MiniLMEmbeddings
    import CPKFastEmbed
    import Foundation
    @testable import PKFastEmbed
    import PKShared
    import Testing

    @Suite("PKFastEmbed batch acceptance")
    struct PKFastEmbedBatchTests {
        @Test("batch embeddings match repeated singles for mixed UTF-8 inputs")
        func batchMatchesSinglesForMixedUTF8Inputs() throws {
            let harness = BatchHarness(dimensions: 7)
            let model = try MiniLMEmbedder(
                modelDirectory: URL(fileURLWithPath: "/fake/model"),
                inputBudget: .init(maxTextCount: 256, maxBytesPerText: 4_096, maxTotalBytes: 1_000_000),
                nativeAPI: harness.nativeAPI
            )

            let longPrefix = String(repeating: "prefix-", count: 24)
            let fixtures = [
                "",
                "ASCII",
                "café",
                "cafe\u{301}",
                "🙂",
                "line\0break",
                longPrefix + "tail-a",
                longPrefix + "tail-b",
            ]
            let texts = (0 ..< 128).map { fixtures[$0 % fixtures.count] }

            let batch = try model.embed(texts)
            let singles = try texts.map { try model.embed($0) }

            #expect(harness.batchCallCount == 1)
            #expect(harness.singleCallCount == texts.count)
            #expect(harness.batchInputs == texts.map { Array($0.utf8) })
            #expect(harness.batchLengths == texts.map(\.utf8.count))
            #expect(batch.count == singles.count)

            for (lhs, rhs) in zip(batch, singles) {
                assertVectorsEqual(lhs, rhs, tolerance: 0.000_01)
            }
        }

        @Test("batch embeddings preserve ordering for repeated long strings")
        func batchPreservesOrderingForRepeatedLongStrings() throws {
            let harness = BatchHarness(dimensions: 5)
            let model = try MiniLMEmbedder(
                modelDirectory: URL(fileURLWithPath: "/fake/model"),
                inputBudget: .init(maxTextCount: 32, maxBytesPerText: 4_096, maxTotalBytes: 1_000_000),
                nativeAPI: harness.nativeAPI
            )

            let longPrefix = String(repeating: "segment-", count: 18)
            let texts = [
                "",
                longPrefix + "tail-a",
                longPrefix + "tail-b",
                "",
                longPrefix + "tail-a",
                "emoji🙂",
                "emoji🙂",
                "cafe\u{301}",
                "café",
            ]

            let batch = try model.embed(texts)
            let singles = try texts.map { try model.embed($0) }

            #expect(harness.batchInputs == texts.map { Array($0.utf8) })
            #expect(harness.batchLengths == texts.map(\.utf8.count))
            #expect(batch.count == singles.count)

            for (lhs, rhs) in zip(batch, singles) {
                assertVectorsEqual(lhs, rhs, tolerance: 0.000_01)
            }
        }

        @Test("empty batch returns empty embeddings without native inference")
        func emptyBatchReturnsEmptyWithoutNativeInference() throws {
            let harness = BatchHarness(dimensions: 3)
            let model = try MiniLMEmbedder(
                modelDirectory: URL(fileURLWithPath: "/fake/model"),
                nativeAPI: harness.nativeAPI
            )

            #expect(try model.embed([]).isEmpty)
            #expect(harness.batchCallCount == 0)
            #expect(harness.singleCallCount == 0)
        }

        private func assertVectorsEqual(_ lhs: [Float], _ rhs: [Float], tolerance: Float) {
            #expect(lhs.count == rhs.count)
            for (left, right) in zip(lhs, rhs) {
                #expect(abs(left - right) < tolerance)
            }
        }
    }

    private final class BatchHarness: @unchecked Sendable {
        let handle = OpaquePointer(bitPattern: 0x1)!
        let dimensions: Int

        var createCount = 0
        var dimensionsCount = 0
        var destroyCount = 0
        var singleCallCount = 0
        var batchCallCount = 0
        var singleInputs: [[UInt8]] = []
        var batchInputs: [[UInt8]] = []
        var batchLengths: [Int] = []

        init(dimensions: Int) {
            self.dimensions = dimensions
        }

        var nativeAPI: MiniLMEmbedder.NativeAPI {
            .init(
                abiVersion: { PKFASTEMBED_ABI_VERSION },
                modelCreate: { [unowned self] _, outModel, _ in
                    self.createCount += 1
                    outModel.pointee = self.handle
                    return PKFE_STATUS_OK
                },
                modelDimensions: { [unowned self] _, outDimensions, _ in
                    self.dimensionsCount += 1
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
            return (0 ..< dimensions).map { Float((seed + $0) % 1_000) }
        }
    }
#endif
