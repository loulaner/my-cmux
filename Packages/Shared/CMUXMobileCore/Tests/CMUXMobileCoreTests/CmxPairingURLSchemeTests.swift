import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct CmxPairingURLSchemeTests {
    @Test func exactNewIdentitiesHaveExclusiveClassification() throws {
        for id in ["com.loulaner.mycmux.ios", "com.loulaner.mycmux.ios.debug", "com.loulaner.mycmux.ios.debug.dev", "com.loulaner.mycmux.ios.debug.feature-a"] {
            let value = try #require(CmxPairingURLScheme(iOSBundleIdentifier: id))
            #expect(value.rawValue == "cmux-ios-\(id)")
            #expect(value.isRelease == (id == "com.loulaner.mycmux.ios"))
            #expect(value.isRelease != value.isDevelopment)
            #expect(CmxPairingURLScheme(urlString: value.rawValue + "://attach?v=2") == value)
        }
    }

    @Test func allOldAndUnknownSchemesFailClosed() {
        for value in ["cmux-ios",
            "cmux-ios-dev",
            "cmux-ios-com.cmux.app",
            "cmux-ios-dev.cmux.app.beta",
            "cmux-ios-dev.cmux.app.internal",
            "cmux-ios-dev.cmux.app.demo",
            "cmux-ios-dev.cmux.ios",
            "cmux-ios-dev.cmux.ios.dev",
            "cmux-ios-com.loulaner.mycmux.ios.beta",
            "cmux-ios-com.loulaner.mycmux.ios.debug.",
            "cmux-ios-com.loulaner.mycmux.ios.debug..tag",
            "cmux-ios-com.loulaner.mycmux.ios.debug.-tag",
            "cmux-ios-com.loulaner.mycmux.ios.debug.tag-",
            "cmux-ios-com.loulaner.mycmux.ios.debug.tag_1", "https", ""] {
            #expect(CmxPairingURLScheme(rawValue: value) == nil)
            #expect(CmxPairingURLScheme(urlString: value + "://attach?v=2") == nil)
        }
    }

    #if !os(iOS)
    @Test func completeMacIdentityDistinguishesUntaggedFromDevTag() {
        for (mac, tag, ios) in [
            ("com.loulaner.mycmux", "default", "com.loulaner.mycmux.ios"),
            ("com.loulaner.mycmux.nightly", "nightly", "com.loulaner.mycmux.ios"),
            ("com.loulaner.mycmux.rc", "rc", "com.loulaner.mycmux.ios"),
            ("com.loulaner.mycmux.staging", "staging", "com.loulaner.mycmux.ios"),
            ("com.loulaner.mycmux.debug", "dev", "com.loulaner.mycmux.ios.debug"),
            ("com.loulaner.mycmux.debug.dev", "dev", "com.loulaner.mycmux.ios.debug.dev"),
            ("com.loulaner.mycmux.debug.feature.a", "feature-a", "com.loulaner.mycmux.ios.debug.feature-a")
        ] {
            #expect(CmxPairingURLSchemeResolver(currentIOSBundleIdentifier: mac,
                targetIOSBundleIdentifier: nil,
                macInstanceTag: tag,
                isDevelopmentBuild: true).resolved?.rawValue == "cmux-ios-\(ios)")
        }
    }

    @Test func unknownMacAndMismatchedLaunchTagsNeverFallback() {
        for mac in ["com.cmuxterm.app", "com.cmuxterm.app.debug", "unknown.product", "com.loulaner.mycmux.fake"] {
            #expect(CmxPairingURLSchemeResolver(currentIOSBundleIdentifier: mac,
                targetIOSBundleIdentifier: nil,
                macInstanceTag: nil,
                isDevelopmentBuild: true).resolved == nil)
        }
        #expect(CmxPairingURLSchemeResolver(currentIOSBundleIdentifier: "com.loulaner.mycmux.debug.one",
                targetIOSBundleIdentifier: nil,
                macInstanceTag: "two",
                isDevelopmentBuild: true).resolved == nil)
    }

    @Test func missingIdentityFallbackAndExplicitTargetRemainStrict() {
        for dev in [false, true] {
            #expect(CmxPairingURLSchemeResolver(currentIOSBundleIdentifier: nil,
                targetIOSBundleIdentifier: nil,
                macInstanceTag: nil,
                isDevelopmentBuild: dev).resolved?.rawValue == (dev ? CmxPairingURLScheme.development : CmxPairingURLScheme.release))
        }
        for id in ["com.cmux.app", "dev.cmux.ios.one", "com.loulaner.mycmux.ios.unknown"] {
            #expect(CmxPairingURLSchemeResolver(currentIOSBundleIdentifier: nil,
                targetIOSBundleIdentifier: id,
                macInstanceTag: nil,
                isDevelopmentBuild: true).resolved == nil)
        }
        #expect(CmxPairingURLSchemeResolver(currentIOSBundleIdentifier: nil,
                targetIOSBundleIdentifier: "com.loulaner.mycmux.ios",
                macInstanceTag: nil,
                isDevelopmentBuild: true).resolved?.isRelease == true)
    }
    #endif
}
