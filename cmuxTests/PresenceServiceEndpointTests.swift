import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct PresenceServiceEndpointTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "presence-endpoint-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test func debugDevelopmentUsesDefault() throws {
        try withDefaults { defaults in
            let url = PresenceServiceEndpoint().resolvedServiceURL(
                environment: [:], defaults: defaults, isDebugBuild: true
            )
            #expect(url?.absoluteString == PresenceSettings.debugDefaultServiceURL)
        }
    }

    @Test func environmentWinsOverDefaults() throws {
        try withDefaults { defaults in
            defaults.set("https://defaults.example", forKey: PresenceSettings.serviceURLKey)
            let url = PresenceServiceEndpoint().resolvedServiceURL(
                environment: [PresenceSettings.serviceURLEnvKey: " \nhttps://env.example\n "],
                defaults: defaults, isDebugBuild: true
            )
            #expect(url?.absoluteString == "https://env.example")
        }
    }

    @Test func absentEnvironmentUsesTrimmedDefaults() throws {
        try withDefaults { defaults in
            defaults.set(" \nhttps://defaults.example\n ", forKey: PresenceSettings.serviceURLKey)
            #expect(PresenceServiceEndpoint().resolvedServiceURL(
                environment: [:], defaults: defaults, isDebugBuild: true
            )?.absoluteString == "https://defaults.example")
        }
    }

    @Test func blankEnvironmentDoesNotFallBackToDefaults() throws {
        try withDefaults { defaults in
            defaults.set("https://defaults.example", forKey: PresenceSettings.serviceURLKey)
            #expect(PresenceServiceEndpoint().resolvedServiceURL(
                environment: [PresenceSettings.serviceURLEnvKey: " \n "],
                defaults: defaults, isDebugBuild: true
            )?.absoluteString == PresenceSettings.debugDefaultServiceURL)
        }
    }

    @Test func blankDefaultsUsesDebugDefault() throws {
        try withDefaults { defaults in
            defaults.set(" \n ", forKey: PresenceSettings.serviceURLKey)
            #expect(PresenceServiceEndpoint().resolvedServiceURL(
                environment: [:], defaults: defaults, isDebugBuild: true
            )?.absoluteString == PresenceSettings.debugDefaultServiceURL)
        }
    }

    @Test(arguments: ["production", " PRODUCTION\n"])
    func productionAuthIgnoresOverrides(authEnvironment: String) throws {
        try withDefaults { defaults in
            defaults.set("https://defaults.example", forKey: PresenceSettings.serviceURLKey)
            #expect(PresenceServiceEndpoint().resolvedServiceURL(
                environment: ["CMUX_AUTH_ENVIRONMENT": authEnvironment,
                              PresenceSettings.serviceURLEnvKey: "https://staging.example"],
                defaults: defaults, isDebugBuild: true
            )?.absoluteString == PresenceSettings.productionServiceURL)
        }
    }

    @Test(arguments: ["development", "production", "invalid"])
    func releaseAlwaysPinsProduction(authEnvironment: String) throws {
        try withDefaults { defaults in
            defaults.set("https://defaults.example", forKey: PresenceSettings.serviceURLKey)
            #expect(PresenceServiceEndpoint().resolvedServiceURL(
                environment: ["CMUX_AUTH_ENVIRONMENT": authEnvironment,
                              PresenceSettings.serviceURLEnvKey: "https://staging.example"],
                defaults: defaults, isDebugBuild: false
            )?.absoluteString == PresenceSettings.productionServiceURL)
        }
    }

    @Test(arguments: ["relative/path", "http://[", "custom:opaque", "https://example.test/a b"])
    func preservesFoundationURLParsing(raw: String) throws {
        try withDefaults { defaults in
            let expected = URL(string: raw)
            #expect(PresenceServiceEndpoint().resolvedServiceURL(
                environment: ["CMUX_AUTH_ENVIRONMENT": "development",
                              PresenceSettings.serviceURLEnvKey: raw],
                defaults: defaults, isDebugBuild: true
            ) == expected)
        }
    }

    @Test(arguments: [false, true])
    func historicalHeartbeatPreferenceDoesNotAffectRouting(enabled: Bool) throws {
        try withDefaults { defaults in
            defaults.set(enabled, forKey: PresenceSettings.enabledKey)
            #expect(PresenceServiceEndpoint().resolvedServiceURL(
                environment: [:], defaults: defaults, isDebugBuild: true
            )?.absoluteString == PresenceSettings.debugDefaultServiceURL)
            #expect(defaults.bool(forKey: PresenceSettings.enabledKey) == enabled)
        }
    }
}
