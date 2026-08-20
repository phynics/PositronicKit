import ErrorKit
import Foundation
@testable import PKContracts
import Testing

struct PKErrorTests {
    struct MockError: PKError {
        let errorDomain: String
        let errorCode: Int
        let userFriendlyMessage: String
        let remediation: String? = nil
    }

    @Test("PKError formatting includes domain and code")
    func pkErrorFormatting() {
        let error = MockError(
            errorDomain: PKErrorDomain.shared,
            errorCode: 123,
            userFriendlyMessage: "Something failed"
        )

        #expect(error.errorDomain == PKErrorDomain.shared)
        #expect(error.errorCode == 123)
        #expect(error.userFriendlyMessage == "Something failed")
    }

    @Test("PKErrorDomain constants are correct")
    func pkErrorDomains() {
        #expect(PKErrorDomain.shared == "com.positronickit.shared")
        #expect(PKErrorDomain.prompt == "com.positronickit.core.prompt")
        #expect(PKErrorDomain.client == "com.positronickit.client")
        #expect(PKErrorDomain.runtime == "com.positronickit.runtime")
        #expect(PKErrorDomain.llm == "com.positronickit.core.llm")
        #expect(PKErrorDomain.context == "com.positronickit.core.context")
    }
}
