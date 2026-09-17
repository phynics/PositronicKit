import Foundation
@testable import PKFoundationModelsProvider
import PKContracts
import PKUtilities
import Testing

#if canImport(FoundationModels)
    import FoundationModels

    /// `FoundationModelsAvailabilityError` mapping tests (PKPOST-003): every
    /// `SystemLanguageModel.Availability.UnavailableReason` case must map to a distinct, typed,
    /// user-friendly error — never a crash or silent fallback. Framework-gated since it exercises
    /// the real `SystemLanguageModel.Availability` enum, but does not require Apple Intelligence
    /// to actually be enabled (the enum cases are constructed directly, not observed at runtime).
    /// Each test is annotated `@available(anyAppleOS 26.0, *)` since the package's deployment
    /// target floor (`.macOS(.v15)`) is below the framework's minimum; Swift Testing reports such
    /// a test as skipped rather than passed below OS 26. The attribute sits on each test function
    /// because Swift Testing requires a suite type to always be available.
    @Suite("FoundationModels availability mapping")
    struct FoundationModelsAvailabilityTests {
        @available(anyAppleOS 26.0, *)
        @Test(".available maps to no error")
        func availableMapsToNoError() {
            #expect(FoundationModelsAvailabilityError(availability: .available) == nil)
        }

        @available(anyAppleOS 26.0, *)
        @Test("deviceNotEligible maps to .deviceNotEligible with actionable guidance")
        func deviceNotEligibleMapsCorrectly() throws {
            let error = try #require(
                FoundationModelsAvailabilityError(availability: .unavailable(.deviceNotEligible))
            )
            #expect(error == .deviceNotEligible)
            #expect(error.userFriendlyMessage.contains("does not support Apple Intelligence"))
            #expect(error.remediation != nil)
        }

        @available(anyAppleOS 26.0, *)
        @Test("appleIntelligenceNotEnabled maps with System Settings guidance")
        func appleIntelligenceNotEnabledMapsCorrectly() throws {
            let error = try #require(
                FoundationModelsAvailabilityError(availability: .unavailable(.appleIntelligenceNotEnabled))
            )
            #expect(error == .appleIntelligenceNotEnabled)
            #expect(error.userFriendlyMessage.contains("System Settings"))
        }

        @available(anyAppleOS 26.0, *)
        @Test("modelNotReady maps to a retry-oriented message")
        func modelNotReadyMapsCorrectly() throws {
            let error = try #require(
                FoundationModelsAvailabilityError(availability: .unavailable(.modelNotReady))
            )
            #expect(error == .modelNotReady)
            #expect(error.userFriendlyMessage.contains("preparing") || error.userFriendlyMessage.contains("ready"))
        }

        @available(anyAppleOS 26.0, *)
        @Test("Distinct unavailable reasons produce distinct error codes")
        func distinctReasonsProduceDistinctCodes() throws {
            let device = try #require(FoundationModelsAvailabilityError(availability: .unavailable(.deviceNotEligible)))
            let notEnabled = try #require(FoundationModelsAvailabilityError(availability: .unavailable(.appleIntelligenceNotEnabled)))
            let notReady = try #require(FoundationModelsAvailabilityError(availability: .unavailable(.modelNotReady)))

            let codes = Set([device.errorCode, notEnabled.errorCode, notReady.errorCode])
            #expect(codes.count == 3)
        }
    }
#endif
