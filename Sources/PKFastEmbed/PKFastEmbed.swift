import CPKFastEmbed
import Foundation
import PKShared

public enum PKFastEmbedError: Error, Equatable, Sendable {
    case abiMismatch
    case invalidArgument(String)
    case invalidUTF8(String)
    case modelLoadFailed(String)
    case inferenceFailed(String)
    case bufferTooSmall(String)
    case nativeFailure(Int32, String)
    /// An `EmbeddingInputBudget` validation failure, carried as its typed value so callers
    /// never need to re-derive it by parsing `invalidArgument`'s formatted message string.
    case budgetExceeded(EmbeddingInputBudget.ValidationError)
}

public final class MiniLMEmbedder: @unchecked Sendable {
    package struct NativeAPI {
        var abiVersion: @Sendable () -> UInt32
        var modelCreate: @Sendable (
            String,
            UnsafeMutablePointer<OpaquePointer?>,
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        ) -> pkfe_status_t
        var modelDimensions: @Sendable (
            OpaquePointer,
            UnsafeMutablePointer<Int>,
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        ) -> pkfe_status_t
        var modelEmbed: @Sendable (
            OpaquePointer,
            UnsafePointer<UInt8>?,
            Int,
            UnsafeMutablePointer<Float>?,
            Int,
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        ) -> pkfe_status_t
        var modelEmbedBatch: @Sendable (
            OpaquePointer,
            UnsafePointer<UnsafePointer<UInt8>?>?,
            UnsafePointer<Int>?,
            Int,
            UnsafeMutablePointer<Float>?,
            Int,
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        ) -> pkfe_status_t
        var modelDestroy: @Sendable (OpaquePointer) -> Void

        package static let live = Self(
            abiVersion: pkfe_abi_version,
            modelCreate: { modelDirectory, outModel, outErrorMessage in
                modelDirectory.withCString { cPath in
                    pkfe_model_create(cPath, outModel, outErrorMessage)
                }
            },
            modelDimensions: pkfe_model_dimensions,
            modelEmbed: pkfe_model_embed,
            modelEmbedBatch: pkfe_model_embed_batch,
            modelDestroy: pkfe_model_destroy
        )
    }

    private let handle: OpaquePointer
    public let dimensions: Int
    public let inputBudget: EmbeddingInputBudget
    private let nativeAPI: NativeAPI

    public convenience init(
        modelDirectory: URL,
        inputBudget: EmbeddingInputBudget = .default
    ) throws {
        try self.init(modelDirectory: modelDirectory, inputBudget: inputBudget, nativeAPI: .live)
    }

    package init(
        modelDirectory: URL,
        inputBudget: EmbeddingInputBudget = .default,
        nativeAPI: NativeAPI
    ) throws {
        guard nativeAPI.abiVersion() == PKFASTEMBED_ABI_VERSION else {
            throw PKFastEmbedError.abiMismatch
        }

        var rawHandle: OpaquePointer?
        defer {
            if let rawHandle {
                nativeAPI.modelDestroy(rawHandle)
            }
        }

        try Self.withNativeErrorMessage { errorPointer in
            let status = nativeAPI.modelCreate(modelDirectory.path, &rawHandle, errorPointer)
            try Self.throwIfNeeded(status, errorPointer: errorPointer)
        }

        guard let handle = rawHandle else {
            throw PKFastEmbedError.modelLoadFailed("Native initialization returned no model handle.")
        }

        var nativeDimensions = 0
        try Self.withNativeErrorMessage { errorPointer in
            let status = nativeAPI.modelDimensions(handle, &nativeDimensions, errorPointer)
            try Self.throwIfNeeded(status, errorPointer: errorPointer)
        }

        guard nativeDimensions > 0 else {
            throw PKFastEmbedError.modelLoadFailed("Native model reported invalid dimensions \(nativeDimensions).")
        }

        self.nativeAPI = nativeAPI
        self.handle = handle
        dimensions = nativeDimensions
        self.inputBudget = inputBudget
        rawHandle = nil
    }

    deinit {
        nativeAPI.modelDestroy(handle)
    }

    public func embed(_ text: String) throws -> [Float] {
        try validate(text)
        var output = Array(repeating: Float.zero, count: dimensions)
        try output.withUnsafeMutableBufferPointer { buffer in
            try text.utf8CString.withUnsafeBufferPointer { utf8Buffer in
                let count = utf8Buffer.count > 0 ? utf8Buffer.count - 1 : 0
                let pointer = utf8Buffer.baseAddress.map {
                    UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self)
                }
                try Self.withNativeErrorMessage { errorPointer in
                    let status = nativeAPI.modelEmbed(
                        handle,
                        pointer,
                        count,
                        buffer.baseAddress,
                        buffer.count,
                        errorPointer
                    )
                    try Self.throwIfNeeded(status, errorPointer: errorPointer)
                }
            }
        }
        return output
    }

    public func embed(_ texts: [String]) throws -> [[Float]] {
        guard !texts.isEmpty else {
            return []
        }

        try validate(texts)
        let outputCount = try Self.checkedOutputCount(textCount: texts.count, dimensions: dimensions)
        var output = Array(repeating: Float.zero, count: outputCount)

        try Self.withBatchUTF8Storage(for: texts) { utf8Pointers, lengths in
            try output.withUnsafeMutableBufferPointer { outputBuffer in
                try Self.withNativeErrorMessage { errorPointer in
                    let status = nativeAPI.modelEmbedBatch(
                        handle,
                        utf8Pointers,
                        lengths,
                        texts.count,
                        outputBuffer.baseAddress,
                        outputBuffer.count,
                        errorPointer
                    )
                    try Self.throwIfNeeded(status, errorPointer: errorPointer)
                }
            }
        }

        return stride(from: 0, to: output.count, by: dimensions).map { start in
            Array(output[start ..< (start + dimensions)])
        }
    }

    private func validate(_ text: String) throws {
        do {
            try inputBudget.validate(text)
        } catch let error as EmbeddingInputBudget.ValidationError {
            throw PKFastEmbedError.budgetExceeded(error)
        }
    }

    private func validate(_ texts: [String]) throws {
        do {
            try inputBudget.validate(texts)
        } catch let error as EmbeddingInputBudget.ValidationError {
            throw PKFastEmbedError.budgetExceeded(error)
        }
    }

    private static func withNativeErrorMessage<T>(
        _ operation: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T
    ) throws -> T {
        var errorPointer: UnsafeMutablePointer<CChar>?
        defer {
            if let errorPointer {
                pkfe_string_destroy(errorPointer)
            }
        }
        return try operation(&errorPointer)
    }

    private static func checkedOutputCount(textCount: Int, dimensions: Int) throws -> Int {
        let (count, overflow) = textCount.multipliedReportingOverflow(by: dimensions)
        guard !overflow else {
            throw PKFastEmbedError.invalidArgument("Batch output size overflowed the available integer range.")
        }
        return count
    }

    private static func withBatchUTF8Storage<T>(
        for texts: [String],
        _ body: (_ utf8Pointers: UnsafePointer<UnsafePointer<UInt8>?>?, _ lengths: UnsafePointer<Int>?) throws -> T
    ) throws -> T {
        let totalBytes = try texts.reduce(into: 0) { result, text in
            let (next, overflow) = result.addingReportingOverflow(text.utf8.count)
            guard !overflow else {
                throw PKFastEmbedError.invalidArgument("Batch UTF-8 input size overflowed the available integer range.")
            }
            result = next
        }

        return try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: max(totalBytes, 1)) { byteStorage in
            var utf8Pointers: [UnsafePointer<UInt8>?] = Array(repeating: nil, count: texts.count)
            var lengths: [Int] = Array(repeating: 0, count: texts.count)
            var byteOffset = 0

            for (index, text) in texts.enumerated() {
                let bytes = Array(text.utf8)
                lengths[index] = bytes.count

                guard !bytes.isEmpty else {
                    continue
                }

                let destination = byteStorage.baseAddress!.advanced(by: byteOffset)
                destination.initialize(from: bytes, count: bytes.count)
                utf8Pointers[index] = UnsafePointer(destination)
                byteOffset += bytes.count
            }

            return try utf8Pointers.withUnsafeBufferPointer { utf8Buffer in
                try lengths.withUnsafeBufferPointer { lengthBuffer in
                    try body(utf8Buffer.baseAddress, lengthBuffer.baseAddress)
                }
            }
        }
    }

    private static func throwIfNeeded(
        _ status: pkfe_status_t,
        errorPointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    ) throws {
        guard status != PKFE_STATUS_OK else {
            return
        }

        let message = errorPointer.pointee.map { String(cString: $0) }
            ?? "Native bridge returned status \(status.rawValue)."
        switch status {
        case PKFE_STATUS_ABI_MISMATCH:
            throw PKFastEmbedError.abiMismatch
        case PKFE_STATUS_INVALID_ARGUMENT:
            throw PKFastEmbedError.invalidArgument(message)
        case PKFE_STATUS_INVALID_UTF8:
            throw PKFastEmbedError.invalidUTF8(message)
        case PKFE_STATUS_MODEL_LOAD_FAILED:
            throw PKFastEmbedError.modelLoadFailed(message)
        case PKFE_STATUS_INFERENCE_FAILED:
            throw PKFastEmbedError.inferenceFailed(message)
        case PKFE_STATUS_BUFFER_TOO_SMALL:
            throw PKFastEmbedError.bufferTooSmall(message)
        default:
            throw PKFastEmbedError.nativeFailure(Int32(status.rawValue), message)
        }
    }
}
