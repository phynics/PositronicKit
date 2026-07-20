import Foundation
@testable import PKShared
import PKUtilities
@testable import PositronicKit
import Testing

/// Coverage for `LLMService.parseEndpoint(_:)` — the URL-to-`EndpointComponents` parser
/// used by provider clients to configure HTTP transport.
///
/// The parser handles explicit ports, scheme defaults (https->443, http->80), and falls
/// back to the OpenAI defaults for malformed input. It was previously untested.
@Suite("LLMService.parseEndpoint")
struct LLMServiceParseEndpointTests {

    @Test("Parses a standard HTTPS endpoint with no explicit port")
    func parsesHTTPSNoPort() {
        let components = LLMService.parseEndpoint("https://api.openai.com")
        #expect(components.host == "api.openai.com")
        #expect(components.port == 443)
        #expect(components.scheme == "https")
    }

    @Test("Parses an HTTP endpoint with no explicit port")
    func parsesHTTPNoPort() {
        let components = LLMService.parseEndpoint("http://localhost")
        #expect(components.host == "localhost")
        #expect(components.port == 80)
        #expect(components.scheme == "http")
    }

    @Test("Parses an explicit port")
    func parsesExplicitPort() {
        let components = LLMService.parseEndpoint("http://localhost:11434")
        #expect(components.host == "localhost")
        #expect(components.port == 11434)
        #expect(components.scheme == "http")
    }

    @Test("Parses an HTTPS endpoint with an explicit port")
    func parsesHTTPSExplicitPort() {
        let components = LLMService.parseEndpoint("https://api.example.com:8443")
        #expect(components.host == "api.example.com")
        #expect(components.port == 8443)
        #expect(components.scheme == "https")
    }

    @Test("Trims surrounding whitespace before parsing")
    func trimsWhitespace() {
        let components = LLMService.parseEndpoint("  https://api.openai.com  ")
        #expect(components.host == "api.openai.com")
        #expect(components.port == 443)
    }

    @Test("Falls back to OpenAI defaults for an invalid URL")
    func fallsBackForInvalidURL() {
        let components = LLMService.parseEndpoint("not-a-url")
        #expect(components.host == "api.openai.com")
        #expect(components.port == 443)
        #expect(components.scheme == "https")
    }

    @Test("Falls back to OpenAI defaults for an empty string")
    func fallsBackForEmpty() {
        let components = LLMService.parseEndpoint("")
        #expect(components.host == "api.openai.com")
        #expect(components.port == 443)
        #expect(components.scheme == "https")
    }

    @Test("Falls back to OpenAI defaults for an unsupported scheme")
    func fallsBackForUnsupportedScheme() {
        let components = LLMService.parseEndpoint("ftp://files.example.com")
        #expect(components.host == "api.openai.com")
        #expect(components.port == 443)
        #expect(components.scheme == "https")
    }

    @Test("Falls back when the URL has no host")
    func fallsBackForNoHost() {
        let components = LLMService.parseEndpoint("https:///path-only")
        #expect(components.host == "api.openai.com")
        #expect(components.port == 443)
    }

    @Test("Uppercase scheme is accepted but port logic is case-sensitive (known quirk)")
    func uppercaseSchemeAccepted() {
        // Foundation preserves the scheme case as-written ("HTTPS"), and parseEndpoint's
        // port selection compares against the lowercase literal "https". The scheme
        // validation itself is case-insensitive, so the endpoint is accepted, but the
        // port falls through to the http default (80) rather than 443.
        let components = LLMService.parseEndpoint("HTTPS://api.openai.com")
        #expect(components.host == "api.openai.com")
        #expect(components.scheme == "HTTPS")
        #expect(components.port == 80)
    }
}
