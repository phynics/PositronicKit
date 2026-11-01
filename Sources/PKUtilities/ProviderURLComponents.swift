import Foundation

/// Applies the provider URL port rule consistently across network adapters.
package enum ProviderURLComponents {
    package static func setHost(_ host: String, on components: inout URLComponents) {
        let isBracketed = host.hasPrefix("[") && host.hasSuffix("]")
        components.host = host.contains(":") && !isBracketed ? "[\(host)]" : host
    }

    package static func setPort(_ port: Int, for scheme: String, on components: inout URLComponents) {
        let normalizedScheme = scheme.lowercased()
        let isDefaultPort = (normalizedScheme == "https" && port == 443)
            || (normalizedScheme == "http" && port == 80)
            || port == 0

        components.port = isDefaultPort ? nil : port
    }
}
