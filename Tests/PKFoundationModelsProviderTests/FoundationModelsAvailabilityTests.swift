import Foundation
@testable import PKFoundationModelsProvider
import PKShared
import Testing

#if canImport(FoundationModels)
    import FoundationModels

    /// `FoundationModelsAvailabilityError` mapping tests (PKPOST-003): every
    /// `SystemLanguageModel.Availability.UnavailableReason` case must map to a distinct, typed,
    /// user-friendly error — never a crash or silent fallback. Framework-gated since it exercises
    /// the real `SystemLanguageModel.Availability` enum, but does not require Apple Intelligence
    /// to actually be enabled (the enum cases are constructed directly, not observed at runtime).
    /// Each test guards on `#available(macOS 26.0, *)` at runtime (rather than annotating the
    /// suite/tests with `@available`, which Swift Testing's macros reject) since the package's
    /// deployment target floor (`.macOS(.v15)`) is below the framework's minimum.
    @Suite("FoundationModels availability mapping")
    struct FoundationModelsAvailabilityTests {
        @Test(".available maps to no error")
        func availableMapsToNoError() {
            guard #available(macOS 26.0, *) else { return }
            #expect(FoundationModelsAvailabilityError(availability: .available) == nil)
        }

        @Test("deviceNotEligible maps to .deviceNotEligible with actionable guidance")
        func deviceNotEligibleMapsCorrectly() throws {
            guard #available(macOS 26.0, *) else { return }
            let error = try #require(
                FoundationModelsAvailabilityError(availability: .unavailable(.deviceNotEligible))
            )
            #expect(error == .deviceNotEligible)
            #expect(error.userFriendlyMessage.contains("does not support Apple Intelligence"))
            #expect(error.remediation != nil)
        }

        @Test("appleIntelligenceNotEnabled maps with System Settings guidance")
        func appleIntelligenceNotEnabledMapsCorrectly() throws {
            guard #available(macOS 26.0, *) else { return }
            let error = try #require(
                FoundationModelsAvailabilityError(availability: .unavailable(.appleIntelligenceNotEnabled))
            )
            #expect(error == .appleIntelligenceNotEnabled)
            #expect(error.userFriendlyMessage.contains("System Settings"))
        }

        @Test("modelNotReady maps to a retry-oriented message")
        func modelNotReadyMapsCorrectly() throws {
            guard #available(macOS 26.0, *) else { return }
            let error = try #require(
                FoundationModelsAvailabilityError(availability: .unavailable(.modelNotReady))
            )
            #expect(error == .modelNotReady)
            #expect(error.userFriendlyMessage.contains("preparing") || error.userFriendlyMessage.contains("ready"))
        }

        @Test("Distinct unavailable reasons produce distinct error codes")
        func distinctReasonsProduceDistinctCodes() throws {
            guard #available(macOS 26.0, *) else { return }
            let device = try #require(FoundationModelsAvailabilityError(availability: .unavailable(.deviceNotEligible)))
            let notEnabled = try #require(FoundationModelsAvailabilityError(availability: .unavailable(.appleIntelligenceNotEnabled)))
            let notReady = try #require(FoundationModelsAvailabilityError(availability: .unavailable(.modelNotReady)))

            let codes = Set([device.errorCode, notEnabled.errorCode, notReady.errorCode])
            #expect(codes.count == 3)
        }
    }
#endif
