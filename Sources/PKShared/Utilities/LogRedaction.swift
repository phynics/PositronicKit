import CryptoKit
import Foundation

/// Returns a short stable fingerprint of a string for log correlation — safe to log.
package func redactedHash(_ string: String) -> String {
    let digest = SHA256.hash(data: Data(string.utf8))
    return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
}
