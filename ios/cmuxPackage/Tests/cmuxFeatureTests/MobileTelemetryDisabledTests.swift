import CMUXMobileCore
import Foundation
import Testing

/// Exercises the existing no-op boundary, not live app/network behavior.
@Suite(.serialized) struct MobileTelemetryDisabledTests {
    private final class RequestProbe: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        private nonisolated(unsafe) static var count = 0

        static var requests: Int { lock.withLock { count } }
        static func reset() { lock.withLock { count = 0 } }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.withLock { Self.count += 1 }
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        }
        override func stopLoading() {}
    }

    @Test(arguments: [false, true])
    func noopDoesNotUploadOrAlterStoredConsentAndCache(oldValue: Bool) async throws {
        let suite = "MobileTelemetryDisabledTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let oldValues: [String: Any] = [
            "sendAnonymousTelemetry": oldValue,
            "cmux.mobile.flags.remote.ios-artifact-chip-enabled-release": oldValue,
            "cmux.mobile.flags.remote.ios-keyboard-dock-rebuild-revert": oldValue,
            "dev.cmux.mobile.clientID": "9F91B8E2-2A61-493E-9843-EFBA79D2AA55",
        ]
        defaults.setPersistentDomain(oldValues, forName: suite)
        let before = try #require(defaults.persistentDomain(forName: suite))
        #expect(URLProtocol.registerClass(RequestProbe.self))
        defer { URLProtocol.unregisterClass(RequestProbe.self) }

        // Prove the probe intercepts without contacting any external host.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RequestProbe.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        _ = try? await session.data(from: URL(string: "https://telemetry.invalid/probe")!)
        #expect(RequestProbe.requests == 1)
        RequestProbe.reset()

        let analytics: any AnalyticsEmitting = NoopAnalytics()
        analytics.capture("ios_test", ["count": .int(1)])
        analytics.identify(userId: "test", alias: "test-alias", properties: [:])
        analytics.setSuperProperties(["platform": .string("ios")])
        await analytics.flush()
        #expect(RequestProbe.requests == 0)
        let after = try #require(defaults.persistentDomain(forName: suite))
        #expect(NSDictionary(dictionary: before).isEqual(to: after))
    }
}
