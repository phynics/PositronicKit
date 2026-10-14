import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif

/// Returns the stable, opaque prompt-cache routing key for a Timeline identity.
///
/// The key is `hex(SHA-256("pk.timeline." + timelineID.uuidString)).prefix(32)`. It is safe to
/// log at the redaction level applied to routing keys because the raw Timeline identity cannot
/// be recovered from it, and it deliberately differs per Timeline: sibling Timelines must not
/// share a provider cache.
package func promptCacheRoutingKey(timelineID: UUID) -> String {
    let digest = SHA256.hash(data: Data("pk.timeline.\(timelineID.uuidString)".utf8))
    return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
}
