import ErrorKit
import Foundation
@testable import PKShared
import Testing

struct MonadErrorTests {
    struct MockError: MonadError {
        let errorDomain: String
        let errorCode: Int
        let userFriendlyMessage: String
        let remediation: String? = nil
    }

    @Test("MonadError formatting includes domain and code")
    func monadErrorFormatting() {
        let error = MockError(
            errorDomain: MonadErrorDomain.shared,
            errorCode: 123,
            userFriendlyMessage: "Something failed"
        )

        #expect(error.errorDomain == MonadErrorDomain.shared)
        #expect(error.errorCode == 123)
        #expect(error.userFriendlyMessage == "Something failed")
    }

    @Test("MonadErrorDomain constants are correct")
    func monadErrorDomains() {
        #expect(MonadErrorDomain.shared == "com.monad.shared")
        #expect(MonadErrorDomain.client == "com.monad.client")
        #expect(MonadErrorDomain.server == "com.monad.server")
        #expect(MonadErrorDomain.llm == "com.monad.core.llm")
        #expect(MonadErrorDomain.context == "com.monad.core.context")
    }
}
