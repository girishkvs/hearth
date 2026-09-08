import Foundation
import HearthCore

public final class SystemScreenSaverController: ScreenSaverControlling, @unchecked Sendable {
    private let lock = NSLock()
    private let preferences: any ScreenSaverPreferencesAccessing
    private let policy: any IdleLockPolicyReading
    private var writeCompletionUnknown = false

    public convenience init() {
        self.init(preferences: NativeScreenSaverPreferences(), policy: SystemIdleLockPolicyReader())
    }

    init(preferences: any ScreenSaverPreferencesAccessing, policy: any IdleLockPolicyReading) {
        self.preferences = preferences
        self.policy = policy
    }

    public func observe() throws -> ScreenSaverObservation {
        try lock.withLock {
            let assessment = policyAssessment()
            let image = try readImage()
            var availability = assessment.availability
            var message = assessment.message
            if writeCompletionUnknown {
                availability = .unavailable
                message = "A timer preference write has unconfirmed completion. Current configuration is diagnostic only; retained ownership must not be cleared by matching reads."
            } else if availability == .ready {
                if image.configuration.effectiveSeconds != 0,
                   try !image.preservesOtherEffectiveValues(whenWriting: .integer(0)) {
                    availability = .unavailable
                    message = "Changing this timer would also change inherited screen-saver preferences. No preference was written; the existing configuration is retained."
                } else {
                    message = "Idle timer configuration is readable. macOS may adopt changes and restoration later; configuration is not an immediate runtime-state observation."
                }
            }
            return ScreenSaverObservation(
                delaySeconds: image.configuration.effectiveSeconds, availability: availability,
                message: message, configuration: image.configuration
            )
        }
    }

    public func apply(value: ScreenSaverStoredValue, expected: ScreenSaverConfiguration) throws {
        try lock.withLock {
            guard !writeCompletionUnknown else {
                throw ScreenSaverError.completionUnknown("A previous timer write has unconfirmed completion. No further preference write is allowed.")
            }
            try ScreenSaverPreferenceResolver().validate(value)
            let before: ScreenSaverPreferenceImage
            do {
                let assessment = policyAssessment()
                guard assessment.availability == .ready else { throw ScreenSaverError.rejected(assessment.message) }
                before = try readImage()
                guard before.configuration == expected else {
                    throw ScreenSaverError.rejected("Timer presence, value, fallback or default context changed externally. No preference was written.")
                }
                guard try before.preservesOtherEffectiveValues(whenWriting: value) else {
                    throw ScreenSaverError.rejected("This write would change other inherited screen-saver preferences. No preference was written.")
                }
                let latest = try readImage()
                guard latest.configuration == before.configuration else {
                    throw ScreenSaverError.rejected("Timer configuration changed during the write preflight. No preference was written.")
                }
            } catch {
                throw ScreenSaverError.rejected(error.localizedDescription)
            }
            guard value != before.configuration.storedValue else { return }
            let predicted = try before.replacingCurrentHostTimer(value)
            do {
                // CFPreferences has no atomic compare-and-set. Recheck the complete
                // scoped context above; never write any companion key or domain.
                try preferences.setCurrentHostTimer(value)
                guard preferences.synchronizeCurrentHost() else {
                    throw ScreenSaverError.completionUnknown("Timer preference synchronization returned false; completion is unconfirmed, not cancellation or no change.")
                }
                let after = try readImage()
                guard after.configuration == predicted.configuration else {
                    throw ScreenSaverError.completionUnknown("Timer synchronization returned true, but exact stored configuration was not confirmed. No automatic retry or reversal is allowed.")
                }
            } catch ScreenSaverError.rejected(let message) {
                throw ScreenSaverError.rejected(message)
            } catch {
                writeCompletionUnknown = true
                throw ScreenSaverError.completionUnknown(error.localizedDescription)
            }
        }
    }

    private func readImage() throws -> ScreenSaverPreferenceImage {
        var domains: [ScreenSaverReadScope: [String: Any]] = [:]
        for scope in ScreenSaverReadScope.allCases {
            domains[scope] = try preferences.copyValues(in: scope)
        }
        let exact = try ScreenSaverPreferenceResolver().storedValue(preferences.copyCurrentHostTimer())
        let resource = try preferences.engineDefaults()
        return try ScreenSaverPreferenceImage(domains: domains, exactTimer: exact, resource: resource)
    }

    private func policyAssessment() -> IdleLockPolicyAssessment {
        do {
            return try policy.assess()
        } catch {
            return IdleLockPolicyAssessment(
                availability: .unavailable,
                message: "Effective idle-timer policy is unavailable: \(error.localizedDescription)"
            )
        }
    }
}
