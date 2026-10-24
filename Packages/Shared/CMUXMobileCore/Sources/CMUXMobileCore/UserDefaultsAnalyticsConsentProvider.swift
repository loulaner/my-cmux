public import Foundation

/// A compatibility reader for the legacy telemetry preference in `UserDefaults`.
///
/// A missing value defaults to true. Each access reads the injected store
/// again; reading this preference does not create or enable an uploader.
public struct UserDefaultsAnalyticsConsentProvider: AnalyticsConsentProviding {
    /// The retained `UserDefaults` key for the legacy telemetry preference.
    public static let telemetryKey = "sendAnonymousTelemetry"

    // UserDefaults is Apple-documented thread-safe; OK to hold nonisolated.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// Creates a consent provider over the given defaults store.
    ///
    /// - Parameter defaults: The store holding the opt-out flag. Inject a
    ///   suite-scoped store in tests.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The legacy preference value, not the running state of an uploader.
    public var isTelemetryEnabled: Bool {
        defaults.object(forKey: Self.telemetryKey) as? Bool ?? true
    }
}
