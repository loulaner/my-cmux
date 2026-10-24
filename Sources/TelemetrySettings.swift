import CmuxSettings
import Foundation

enum TelemetrySettings {
    // Legacy launch-frozen, policy-resolved preference retained for compatibility.
    // This value describes the stored preference, not whether an uploader runs.
    // The key, default and read logic remain owned by CmuxSettings.
    static let enabledForCurrentLaunch = resolveEnabled(
        userOptIn: AppCatalogSection().sendAnonymousTelemetry.value(in: .standard),
        policy: ManagedDevicePolicy()
    )

    /// Preserves the legacy policy precedence for the launch snapshot.
    /// Official diagnostic uploaders are not composed in this build. The
    /// separate managed-policy gate for local-flag prewarming is unchanged.
    static func resolveEnabled(userOptIn: Bool, policy: ManagedDevicePolicy) -> Bool {
        userOptIn && !policy.isEnforced(.disableTelemetry)
    }
}
