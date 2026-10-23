import Foundation

/// A supported exact MyCMUX pairing scheme, classified before account preflight.
public struct CmxPairingURLScheme {
    public let rawValue: String

    public init?(iOSBundleIdentifier: String?) {
        guard let namespace = MobileIOSAppNamespace(bundleIdentifier: iOSBundleIdentifier) else { return nil }
        self.init(rawValue: namespace.pairingURLScheme)
    }

    /// Rejects old product schemes and malformed or unclassified namespaces.
    public init?(rawValue: String?) {
        guard let normalized = rawValue?.lowercased(),
              normalized == Self.release || normalized == Self.development
                || Self.validTaggedScheme(normalized) else { return nil }
        self.rawValue = normalized
    }

    public init?(urlString: String) {
        guard urlString.contains("://"),
              let components = URLComponents(string: urlString) else { return nil }
        self.init(rawValue: components.scheme)
    }

    public var isDevelopment: Bool {
        rawValue == Self.development || Self.validTaggedScheme(rawValue)
    }

    public var isRelease: Bool { rawValue == Self.release }

    /// Supported exact release and untagged development defaults.
    public static let release = "cmux-ios-com.loulaner.mycmux.ios"
    public static let development = "cmux-ios-com.loulaner.mycmux.ios.debug"
    public static let all: [String] = [release, development]

    private static func validTaggedScheme(_ value: String) -> Bool {
        let prefix = development + "."
        guard value.hasPrefix(prefix) else { return false }
        let suffix = String(value.dropFirst(prefix.count))
        return suffix.count <= 64 && suffix != "default"
            && suffix.range(of: #"^[a-z0-9]+(?:[.-][a-z0-9]+)*$"#, options: .regularExpression) != nil
    }
}

extension CmxPairingURLScheme: Equatable, Sendable {}
