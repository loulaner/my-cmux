import CmuxCloud
import CMUXMobileCore
import Foundation

/// Persists the iOS app used when rendering an exact MyCMUX pairing URL.
@MainActor
struct MobileIOSPairingTargetStore {
    static let defaultsKey = "mobile.pairing.targetIOSBundleIdentifier"

    private let defaults: UserDefaults
    private let macInstanceTag: String
    private let macBundleIdentifier: String?

    init(
        defaults: UserDefaults = .standard,
        macInstanceTag: String = MobileHostIdentity.instanceTag(),
        macBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        self.defaults = defaults
        self.macInstanceTag = macInstanceTag
        self.macBundleIdentifier = macBundleIdentifier
    }

    var availableNamespaces: [MobileIOSAppNamespace] {
        guard let scheme = CmxPairingURLSchemeResolver(
            currentIOSBundleIdentifier: macBundleIdentifier,
            targetIOSBundleIdentifier: nil,
            macInstanceTag: macInstanceTag,
            isDevelopmentBuild: false
        ).resolved,
        let namespace = MobileIOSAppNamespace(
            bundleIdentifier: String(scheme.rawValue.dropFirst("cmux-ios-".count))
        ) else { return [] }
        return [namespace]
    }

    var selectedNamespace: MobileIOSAppNamespace? {
        let available = availableNamespaces
        return storedNamespace(in: available) ?? available.first
    }

    var selectedPairingURLScheme: CmxPairingURLScheme? {
        guard let selectedNamespace else { return nil }
        return CmxPairingURLScheme(
            iOSBundleIdentifier: selectedNamespace.bundleIdentifier
        )
    }

    @discardableResult
    func select(_ namespace: MobileIOSAppNamespace) -> Bool {
        guard availableNamespaces.contains(namespace) else { return false }
        defaults.set(namespace.bundleIdentifier, forKey: Self.defaultsKey)
        return true
    }

    private func storedNamespace(
        in available: [MobileIOSAppNamespace]
    ) -> MobileIOSAppNamespace? {
        guard let stored = defaults.string(forKey: Self.defaultsKey),
              let namespace = MobileIOSAppNamespace(
                  bundleIdentifier: stored
              ),
              available.contains(namespace) else {
            return nil
        }
        return namespace
    }
}
