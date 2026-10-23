import Foundation

/// Resolves the pairing target for the current process without global state.
public struct CmxPairingURLSchemeResolver: Sendable {
    private let currentIOSBundleIdentifier: String?
    private let targetIOSBundleIdentifier: String?
    private let macInstanceTag: String?
    private let isDevelopmentBuild: Bool

    /// Captures the current app identity and any explicit Mac pairing target.
    ///
    /// A Mac may set `CMUX_IOS_PAIRING_BUNDLE_IDENTIFIER` to any authoritative
    /// release-lane bundle id. Tagged Mac builds otherwise target their exact
    /// same-tag iOS bundle.
    public init(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        currentIOSBundleIdentifier = bundle.bundleIdentifier
        targetIOSBundleIdentifier =
            environment["CMUX_IOS_PAIRING_BUNDLE_IDENTIFIER"]
        macInstanceTag = environment["CMUX_TAG"]
        #if DEBUG
        isDevelopmentBuild = true
        #else
        isDevelopmentBuild = false
        #endif
    }

    /// Creates a resolver with explicit identity inputs for composition roots and tests.
    public init(
        currentIOSBundleIdentifier: String?,
        targetIOSBundleIdentifier: String?,
        macInstanceTag: String?,
        isDevelopmentBuild: Bool
    ) {
        self.currentIOSBundleIdentifier = currentIOSBundleIdentifier
        self.targetIOSBundleIdentifier = targetIOSBundleIdentifier
        self.macInstanceTag = macInstanceTag
        self.isDevelopmentBuild = isDevelopmentBuild
    }

    /// The exact scheme this process should emit, or `nil` on invalid identity.
    public var resolved: CmxPairingURLScheme? {
        #if os(iOS)
        return CmxPairingURLScheme(
            iOSBundleIdentifier: currentIOSBundleIdentifier
        )
        #else
        if let targetIOSBundleIdentifier {
            return CmxPairingURLScheme(
                iOSBundleIdentifier: targetIOSBundleIdentifier
            )
        }
        let releaseID = "com.loulaner.mycmux.ios"
        let debugID = releaseID + ".debug"
        let macBase = "com.loulaner.mycmux"
        guard let macID = currentIOSBundleIdentifier else {
            if let tag = macInstanceTag, !tag.isEmpty {
                guard let namespace = MobileIOSAppNamespace(pairedMacInstanceTag: tag) else { return nil }
                return CmxPairingURLScheme(iOSBundleIdentifier: namespace.bundleIdentifier)
            }
            return CmxPairingURLScheme(iOSBundleIdentifier: isDevelopmentBuild ? debugID : releaseID)
        }
        if macID == macBase + ".debug" {
            return CmxPairingURLScheme(iOSBundleIdentifier: debugID)
        }
        for channel in ["", ".nightly", ".rc", ".staging"] {
            if macID == macBase + channel || (!channel.isEmpty && macID.hasPrefix(macBase + channel + ".")) {
                return CmxPairingURLScheme(iOSBundleIdentifier: releaseID)
            }
        }
        let prefix = macBase + ".debug."
        guard macID.hasPrefix(prefix) else { return nil }
        let suffix = String(macID.dropFirst(prefix.count))
        guard suffix.range(of: #"^[a-z0-9]+(?:\.[a-z0-9]+)*$"#, options: .regularExpression) != nil else { return nil }
        let launchTag = macInstanceTag ?? suffix
        let canonical = launchTag.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: ".", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard canonical == suffix else { return nil }
        let slug = canonical.replacingOccurrences(of: ".", with: "-")
        return CmxPairingURLScheme(iOSBundleIdentifier: debugID + "." + slug)
        #endif
    }
}
