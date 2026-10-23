import Foundation

/// Optional services available in a signed application, not an authentication policy.
///
/// The personal-device artifact omits paid-team extensions and uses the normal
/// email-code flow. Missing metadata preserves existing distribution behavior.
public struct MobileDistributionCapabilities: Sendable {
    /// Whether this artifact exposes third-party sign-in buttons.
    public let supportsOAuth: Bool
    /// Whether this artifact may request APNs registration or restore push state.
    public let supportsPush: Bool

    /// Resolves capabilities from the application's bundled metadata.
    /// - Parameter infoDictionary: The host application's Info.plist, injected
    ///   so tests do not depend on the process bundle.
    public init(infoDictionary: [String: Any]) {
        let personal = infoDictionary["CMUXPersonalBuild"] as? Bool == true
        supportsOAuth = !personal
        supportsPush = !personal
    }
}
