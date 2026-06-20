import CPKFastEmbed
import Foundation

public enum PKFastEmbedError: Error, Equatable, Sendable {
    case abiMismatch
    case invalidArgument(String)
    case invalidUTF8(String)
    case modelLoadFailed(String)
    case inferenceFailed(String)
    case bufferTooSmall(String)
    case nativeFailure(Int32, String)
}

public final class MiniLMEmbedder: @unchecked Sendable {
    private let handle: OpaquePointer
    public let dimensions: Int

    public init(modelDirectory: URL) throws {
        guard pkfe_abi_version() == PKFASTEMBED_ABI_VERSION else {
            throw PKFastEmbedError.abiMismatch
        }

        var rawHandle: OpaquePointer?
        try Self.withNativeErrorMessage { errorPointer in
            let status = pkfe_model_create(modelDirectory.path, &rawHandle, errorPointer)
            try Self.throwIfNeeded(status, errorPointer: errorPointer)
        }

        guard let rawHandle else {
            throw PKFastEmbedError.modelLoadFailed("Native initialization returned no model handle.")
        }

        self.handle = rawHandle

        var nativeDimensions: Int = 0
        try Self.withNativeErrorMessage { errorPointer in
            let status = pkfe_model_dimensions(rawHandle, &nativeDimensions, errorPointer)
            try Self.throwIfNeeded(status, errorPointer: errorPointer)
        }
        self.dimensions = nativeDimensions
    }

    deinit {
        pkfe_model_destroy(handle)
    }

    public func embed(_ text: String) throws -> [Float] {
        var output = Array(repeating: Float.zero, count: dimensions)
        try output.withUnsafeMutableBufferPointer { buffer in
            try text.utf8CString.withUnsafeBufferPointer { utf8Buffer in
                let count = utf8Buffer.count > 0 ? utf8Buffer.count - 1 : 0
                let pointer = utf8Buffer.baseAddress.map {
                    UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self)
                }
                try Self.withNativeErrorMessage { errorPointer in
                    let status = pkfe_model_embed(
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

        let utf8Storage: [ContiguousArray<CChar>] = texts.map(\.utf8CString)
        var utf8Pointers: [UnsafePointer<UInt8>?] = utf8Storage.map { buffer in
            buffer.withUnsafeBufferPointer { rawBuffer in
                rawBuffer.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self) }
            }
        }
        let lengths = utf8Storage.map { max($0.count - 1, 0) }
        var output = Array(repeating: Float.zero, count: texts.count * dimensions)

        try output.withUnsafeMutableBufferPointer { outputBuffer in
            try utf8Pointers.withUnsafeMutableBufferPointer { pointerBuffer in
                try lengths.withUnsafeBufferPointer { lengthBuffer in
                    try Self.withNativeErrorMessage { errorPointer in
                        let status = pkfe_model_embed_batch(
                            handle,
                            pointerBuffer.baseAddress,
                            lengthBuffer.baseAddress,
                            pointerBuffer.count,
                            outputBuffer.baseAddress,
                            outputBuffer.count,
                            errorPointer
                        )
                        try Self.throwIfNeeded(status, errorPointer: errorPointer)
                    }
                }
            }
        }

        return stride(from: 0, to: output.count, by: dimensions).map { start in
            Array(output[start..<(start + dimensions)])
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
