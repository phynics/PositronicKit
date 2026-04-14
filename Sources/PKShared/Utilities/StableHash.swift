import Foundation

public enum StableHash {
    private static let fnvOffsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let fnvPrime: UInt64 = 1_099_511_628_211

    public static func hash(_ text: String) -> UInt64 {
        hash(bytes: Array(text.utf8))
    }

    public static func hash(components: [String]) -> UInt64 {
        var state = fnvOffsetBasis
        for component in components {
            state = update(state: state, bytes: Array(component.utf8))
            state = update(state: state, bytes: [0xFF])
        }
        return state
    }

    public static func hash(bytes: [UInt8]) -> UInt64 {
        update(state: fnvOffsetBasis, bytes: bytes)
    }

    private static func update(state: UInt64, bytes: [UInt8]) -> UInt64 {
        var current = state
        for byte in bytes {
            current ^= UInt64(byte)
            current = current &* fnvPrime
        }
        return current
    }
}
