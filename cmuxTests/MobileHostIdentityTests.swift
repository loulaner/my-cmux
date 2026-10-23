import CmuxCloud
import CMUXMobileCore
import CmuxSettings
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct MobileHostIdentityTests {
    @Test func appInstanceTagDistinguishesReleaseChannelsAndTaggedDevBuilds() {
        #expect(MobileHostIdentity.instanceTag(
            environment: [:],
            bundleIdentifier: "com.loulaner.mycmux"
        ) == "default")
        #expect(MobileHostIdentity.instanceTag(
            environment: [:],
            bundleIdentifier: "com.loulaner.mycmux.nightly"
        ) == "nightly")
        #expect(MobileHostIdentity.instanceTag(
            environment: [:],
            bundleIdentifier: "com.loulaner.mycmux.staging"
        ) == "staging")
        #expect(MobileHostIdentity.instanceTag(
            environment: ["CMUX_TAG": "future-one"],
            bundleIdentifier: "com.loulaner.mycmux.debug.future-one"
        ) == "future-one")
    }

    @Test func targetSelectionUsesExactNewIdentityAndNeverDeletesOldSavedTarget() throws {
        for (mac, tag, expected) in [
            ("com.loulaner.mycmux", "default", "com.loulaner.mycmux.ios"),
            ("com.loulaner.mycmux.nightly", "nightly", "com.loulaner.mycmux.ios"),
            ("com.loulaner.mycmux.rc", "rc", "com.loulaner.mycmux.ios"),
            ("com.loulaner.mycmux.staging", "staging", "com.loulaner.mycmux.ios"),
            ("com.loulaner.mycmux.debug", "dev", "com.loulaner.mycmux.ios.debug"),
            ("com.loulaner.mycmux.debug.dev", "dev", "com.loulaner.mycmux.ios.debug.dev"),
            ("com.loulaner.mycmux.debug.future.one", "future-one", "com.loulaner.mycmux.ios.debug.future-one")
        ] {
            let suite = "mycmux-target-test-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let key = MobileIOSPairingTargetStore.defaultsKey
            defaults.set("dev.cmux.app.demo", forKey: key)
            let store = MobileIOSPairingTargetStore(defaults: defaults, macInstanceTag: tag, macBundleIdentifier: mac)
            #expect(store.availableNamespaces.map(\.bundleIdentifier) == [expected])
            #expect(store.selectedNamespace?.bundleIdentifier == expected)
            #expect(store.selectedPairingURLScheme?.rawValue == "cmux-ios-\(expected)")
            #expect(defaults.string(forKey: key) == "dev.cmux.app.demo")
            for id in ["dev.cmux.app.demo", "com.loulaner.mycmux.ios.debug.other"] {
                #expect(!store.select(try #require(MobileIOSAppNamespace(bundleIdentifier: id))))
                #expect(defaults.string(forKey: key) == "dev.cmux.app.demo")
            }
            #expect(store.select(try #require(MobileIOSAppNamespace(bundleIdentifier: expected))))
            #expect(defaults.string(forKey: key) == expected)
        }
    }

    @Test func taggedBuildIdentityUsesBundleScopeWithoutLaunchMetadata() {
        #expect(MobileHostIdentity.instanceTag(
            environment: [:],
            bundleIdentifier: "com.loulaner.mycmux.debug.future-one"
        ) == "future-one")
        #expect(MobileHostIdentity.instanceTag(
            environment: [:],
            bundleIdentifier: "com.loulaner.mycmux.debug.future-two"
        ) == "future-two")
    }

    @Test func authenticatedStatusIncludesAuthoritativeInstanceTag() {
        let previousTag = ProcessInfo.processInfo.environment["CMUX_TAG"]
        setenv("CMUX_TAG", "future-one", 1)
        defer {
            if let previousTag {
                setenv("CMUX_TAG", previousTag, 1)
            } else {
                unsetenv("CMUX_TAG")
            }
        }

        let payload = MobileHostService.identityStatusPayload(routes: [], deviceID: "v2-mac-fixture")
        #expect(payload["mac_instance_tag"] as? String == "future-one")
        #expect((payload["mac_client_namespace"] as? String)?.hasPrefix("mac:") == true)
        #expect(!(payload["terminal_theme_revision_epoch"] as? String ?? "").isEmpty)
        #expect(payload["mac_compatible_mac_tags"] as? [String] != nil)
    }

    @Test func authenticatedStatusAdvertisesGrantedCompatibleMacTags() throws {
        let suiteName = "mobile-host-compatible-tags-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Reserved release lanes and duplicates never make it into the grant
        // set; what is stored is exactly what authenticated status advertises.
        let stored = MobileCompatibleMacTags.set(
            [" IRPLY ", "hello", "irply", "default", "nightly", "rc", "staging", ""],
            in: defaults
        )
        #expect(stored == ["hello", "irply"])
        #expect(MobileCompatibleMacTags.tags(in: defaults) == ["hello", "irply"])
        #expect(MobileCompatibleMacTags.rejectedTags(
            from: ["default", "hello", "RC"]
        ) == ["default", "rc"])

        let payload = MobileHostService.identityStatusPayload(
            routes: [],
            deviceID: "v2-mac-fixture",
            defaults: defaults
        )
        #expect(payload["mac_compatible_mac_tags"] as? [String] == ["hello", "irply"])
    }

    @Test func publicStatusOmitsInstanceTag() {
        let payload = MobileHostService.publicStatusPayload(routes: [])
        #expect(payload["mac_instance_tag"] == nil)
        #expect(payload["terminal_theme_revision_epoch"] == nil)
        #expect(payload["mac_compatible_mac_tags"] == nil)
    }

    @Test(arguments: ["unset", "true", "false"])
    func retiredPhonePushDoesNotChangeLegacyPreferencesOrIdentity(legacyValue: String) throws {
        let suiteName = "retired-phone-push-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        if legacyValue != "unset" {
            defaults.set(legacyValue == "true", forKey: "forwardNotificationsToPhone")
        }
        defaults.set("onlyWhenAway", forKey: "forwardNotificationsToPhoneMode")
        defaults.set(true, forKey: "forwardNotificationsHideContent")
        _ = MobileCompatibleMacTags.set(["personal-peer"], in: defaults)
        let before = defaults.persistentDomain(forName: suiteName) ?? [:]
        let payload = MobileHostService.identityStatusPayload(
            routes: [], deviceID: "personal-mac", defaults: defaults
        )
        #expect(payload["phone_push"] == nil)
        #expect(payload["mac_device_id"] as? String == "personal-mac")
        #expect(payload["mac_compatible_mac_tags"] as? [String] == ["personal-peer"])
        #expect(payload["theme"] != nil)
        let capabilities = try #require(payload["capabilities"] as? [String])
        #expect(!capabilities.contains { $0.hasPrefix("phone_push.") })
        #expect(NSDictionary(dictionary: before).isEqual(to: defaults.persistentDomain(forName: suiteName) ?? [:]))
    }

    @Test(arguments: ["phone_push.settings.update", "phone_push.status.get", "phone_push.test", "phone_push.keys.exchange"])
    func retiredPhoneMethodsUseUnknownMethodAfterAuthorization(method: String) async {
        let request = MobileHostRPCRequest(id: "retired-phone", method: method, params: [:], auth: nil)
        let denied = await MobileHostService.connectionAuthorizationError(
            for: request, authorization: .stackBearer, stackAuthorization: { _ in nil }
        )
        #expect(denied == nil)
        let result = await TerminalController.shared.mobileHostHandleRPC(request)
        guard case let .failure(error) = result else {
            Issue.record("Retired phone RPC must not execute")
            return
        }
        #expect(error.code == "method_not_found")
    }

    @Test func publicStatusNeverDisclosesPhoneForwardingState() {
        let payload = MobileHostService.publicStatusPayload(routes: [])
        #expect(payload["phone_push"] == nil)
        #expect(!String(describing: payload).contains("api_origin"))
    }

    @Test func phoneSettingsMutationUsesTheSameAccountAuthorizationGate() async {
        let request = MobileHostRPCRequest(
            id: "push-settings",
            method: "phone_push.settings.update",
            params: ["forwarding_enabled": true],
            auth: nil
        )
        let denied = await MobileHostService.connectionAuthorizationError(
            for: request,
            authorization: .stackBearer,
            stackAuthorization: { _ in
                .failure(MobileHostRPCError(
                    code: "unauthorized",
                    message: "Mobile sync authorization failed."
                ))
            }
        )

        guard case let .failure(error) = denied else {
            Issue.record("Expected unauthenticated mutation to fail")
            return
        }
        #expect(error.code == "unauthorized")
    }

    @Test func phoneStatusReadUsesTheSameAccountAuthorizationGate() async {
        let request = MobileHostRPCRequest(
            id: "push-status",
            method: "phone_push.status.get",
            params: [:],
            auth: nil
        )
        let denied = await MobileHostService.connectionAuthorizationError(
            for: request,
            authorization: .stackBearer,
            stackAuthorization: { _ in
                .failure(MobileHostRPCError(
                    code: "unauthorized",
                    message: "Mobile sync authorization failed."
                ))
            }
        )

        guard case let .failure(error) = denied else {
            Issue.record("Expected unauthenticated status read to fail")
            return
        }
        #expect(error.code == "unauthorized")
    }

    @Test func taggedDebugBuildSuffixesPairingDisplayName() throws {
        let suiteName = "mobile-host-display-name-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = SettingCatalog().mobile.iOSPairingDisplayName.userDefaultsKey
        defaults.set("Desk Mac", forKey: key)

        let previousTag = ProcessInfo.processInfo.environment["CMUX_TAG"]
        setenv("CMUX_TAG", "future-one", 1)
        defer {
            if let previousTag {
                setenv("CMUX_TAG", previousTag, 1)
            } else {
                unsetenv("CMUX_TAG")
            }
        }

        #expect(MobileHostIdentity.baseDisplayName(defaults: defaults) == "Desk Mac")
        #if DEBUG
        #expect(MobileHostIdentity.instanceDisplayName(defaults: defaults) == "Desk Mac (future-one)")
        #else
        #expect(MobileHostIdentity.instanceDisplayName(defaults: defaults) == "Desk Mac")
        #endif
    }

    @Test func taggedDisplayNameUsesOverrideWithoutDuplicatingSuffix() throws {
        let suiteName = "mobile-host-display-name-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = SettingCatalog().mobile.iOSPairingDisplayName.userDefaultsKey
        defaults.set("Desk Mac (future-one)", forKey: key)

        #expect(MobileHostIdentity.instanceDisplayName(
            defaults: defaults,
            hostName: "System Mac",
            buildTag: " future-one "
        ) == "Desk Mac (future-one)")
    }

    @Test func untaggedDisplayNameFallsBackToSystemName() throws {
        let suiteName = "mobile-host-display-name-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(MobileHostIdentity.instanceDisplayName(
            defaults: defaults,
            hostName: " System Mac ",
            buildTag: "default"
        ) == "System Mac")
    }

    @Test func taggedDisplayNamePreservesSuffixWithinCloudLimit() throws {
        let suiteName = "mobile-host-display-name-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = SettingCatalog().mobile.iOSPairingDisplayName.userDefaultsKey
        defaults.set(String(repeating: "A", count: 128), forKey: key)

        let displayName = try #require(MobileHostIdentity.instanceDisplayName(
            defaults: defaults,
            hostName: nil,
            buildTag: "future-one"
        ))

        #expect(displayName.utf16.count == 128)
        #expect(displayName.hasSuffix(" (future-one)"))
    }

    @Test func taggedDisplayNameDoesNotSplitExtendedCharactersAtCloudLimit() throws {
        let suiteName = "mobile-host-display-name-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = SettingCatalog().mobile.iOSPairingDisplayName.userDefaultsKey
        defaults.set(String(repeating: "👩🏽‍💻", count: 40), forKey: key)

        let displayName = try #require(MobileHostIdentity.instanceDisplayName(
            defaults: defaults,
            hostName: nil,
            buildTag: "future-one"
        ))

        #expect(displayName.utf16.count <= 128)
        #expect(displayName.hasSuffix(" (future-one)"))
        #expect(displayName.hasPrefix("👩🏽‍💻"))
    }

    @Test func prefersSharedIDAcrossBundleDefaults() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedIDURL = directory.appendingPathComponent("mobile-host-device-id")
        let sharedID = "3D56C547-271C-47D8-84F6-5C79C9394A37"
        try sharedID.lowercased().write(to: sharedIDURL, atomically: true, encoding: .utf8)

        let suiteName = "mobile-host-identity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("175dff61-cabe-4076-b5ac-f5c1c04b62fa", forKey: "mobileHost.deviceID")

        #expect(MobileHostIdentity.deviceID(defaults: defaults, sharedIDURL: sharedIDURL) == sharedID.lowercased())
        #expect(defaults.string(forKey: "mobileHost.deviceID") == sharedID.lowercased())
    }

    @Test func canonicalEquivalentSharedDeviceIDDoesNotRewriteDefaults() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedIDURL = directory.appendingPathComponent("mobile-host-device-id")
        let sharedID = "3D56C547-271C-47D8-84F6-5C79C9394A37".lowercased()
        try sharedID.write(to: sharedIDURL, atomically: true, encoding: .utf8)

        let suiteName = "mobile-host-identity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyStoredID = "  \(sharedID.uppercased())\n"
        defaults.set(legacyStoredID, forKey: "mobileHost.deviceID")

        #expect(MobileHostIdentity.deviceID(
            defaults: defaults,
            sharedIDURL: sharedIDURL
        ) == sharedID)
        #expect(defaults.string(forKey: "mobileHost.deviceID") == legacyStoredID)
    }

    @Test func migratesExistingBundleIDToSharedFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedIDURL = directory.appendingPathComponent("mobile-host-device-id")

        let suiteName = "mobile-host-identity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let defaultID = "C2FD4C2D-E0AF-447D-A8A4-D37BF67751EF"
        defaults.set(defaultID.lowercased(), forKey: "mobileHost.deviceID")

        #expect(MobileHostIdentity.deviceID(defaults: defaults, sharedIDURL: sharedIDURL) == defaultID.lowercased())
        let persisted = try String(contentsOf: sharedIDURL, encoding: .utf8)
        #expect(persisted == defaultID.lowercased())
    }

    @Test func taggedBuildMigratesStableBundleIDBeforeOwnBundleID() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedIDURL = directory.appendingPathComponent("mobile-host-device-id")

        let taggedSuiteName = "mobile-host-identity-tagged-\(UUID().uuidString)"
        let taggedDefaults = try #require(UserDefaults(suiteName: taggedSuiteName))
        defer { taggedDefaults.removePersistentDomain(forName: taggedSuiteName) }
        let taggedID = "91FD1481-336E-4230-BE5F-2EE6800B6E1A"
        taggedDefaults.set(taggedID, forKey: "mobileHost.deviceID")

        let stableSuiteName = "mobile-host-identity-stable-\(UUID().uuidString)"
        let stableDefaults = try #require(UserDefaults(suiteName: stableSuiteName))
        defer { stableDefaults.removePersistentDomain(forName: stableSuiteName) }
        let stableID = "0BF0E843-17CA-44AF-8B65-FC5C67D1D084"
        stableDefaults.set(stableID.lowercased(), forKey: "mobileHost.deviceID")

        #expect(MobileHostIdentity.deviceID(
            defaults: taggedDefaults,
            sharedIDURL: sharedIDURL,
            stableDefaults: stableDefaults,
            bundleIdentifier: "com.loulaner.mycmux.debug.mpick"
        ) == stableID.lowercased())
        #expect(taggedDefaults.string(forKey: "mobileHost.deviceID") == stableID.lowercased())
        #expect(try String(contentsOf: sharedIDURL, encoding: .utf8) == stableID.lowercased())
    }

    @Test func readsExistingSharedIDWithoutDefaults() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedIDURL = directory.appendingPathComponent("mobile-host-device-id")
        let sharedID = "4BF9566D-5D67-4C79-8974-B42D5CF39DE9"
        try sharedID.write(to: sharedIDURL, atomically: true, encoding: .utf8)

        let suiteName = "mobile-host-identity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(MobileHostIdentity.deviceID(defaults: defaults, sharedIDURL: sharedIDURL) == sharedID.lowercased())
        #expect(defaults.string(forKey: "mobileHost.deviceID") == sharedID.lowercased())
    }

    @Test func repairsInvalidSharedIDFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedIDURL = directory.appendingPathComponent("mobile-host-device-id")
        try "not-a-uuid".write(to: sharedIDURL, atomically: true, encoding: .utf8)

        let suiteName = "mobile-host-identity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fallbackID = "08E3578B-195D-486F-B874-023CDA2B647D"
        defaults.set(fallbackID, forKey: "mobileHost.deviceID")

        #expect(MobileHostIdentity.deviceID(defaults: defaults, sharedIDURL: sharedIDURL) == fallbackID.lowercased())
        // Repair the shared file without rewriting an equivalent defaults ID.
        // Avoiding that write also avoids reentrant defaults notifications.
        #expect(defaults.string(forKey: "mobileHost.deviceID") == fallbackID)
        #expect(try String(contentsOf: sharedIDURL, encoding: .utf8) == fallbackID.lowercased())
    }

    @Test func testMobileHostRouteDisclosureSeparatesAuthenticatedAndPublicHints() throws {
        let now = Date()
        let privateAddress = "100.64.1.2:49152"
        let endpointID = String(repeating: "a", count: 64)
        let iroh = try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(
                    endpointID: endpointID
                ),
                pathHints: [
                    try CmxIrohPathHint(
                        kind: .directAddress,
                        value: privateAddress,
                        source: .tailscale,
                        privacyScope: .privateNetwork,
                        observedAt: now,
                        expiresAt: now.addingTimeInterval(300),
                        networkProfile: CmxIrohNetworkProfileKey(
                            source: .tailscale,
                            profileID: String(repeating: "a", count: 64)
                        )
                    ),
                    try CmxIrohPathHint(
                        kind: .relayURL,
                        value: "https://relay.example.test/",
                        source: .native,
                        privacyScope: .publicInternet
                    ),
                ]
            )
        )
        let tailscale = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.1.2", port: 49152)
        )
        let websocketURL = "wss://private.example.test/connect?token=secret"
        let websocket = try CmxAttachRoute(
            id: "websocket",
            kind: .websocket,
            endpoint: .url(websocketURL)
        )

        let authenticatedPayload = MobileHostService.identityStatusPayload(
            routes: [iroh, tailscale, websocket],
            deviceID: "v2-mac-fixture",
            now: now
        )
        let authenticated = try #require(authenticatedPayload["routes"] as? [[String: Any]])
        #expect(authenticated.count == 3)
        let authenticatedEndpoint = try #require(
            authenticated.first?["endpoint"] as? [String: Any]
        )
        let authenticatedHints = try #require(
            authenticatedEndpoint["path_hints"] as? [[String: Any]]
        )
        #expect(authenticatedHints.count == 2)
        #expect(authenticatedHints.contains { $0["value"] as? String == privateAddress })
        #expect(authenticatedHints.contains { $0["network_profile"] != nil })

        let publicPayload = MobileHostService.publicStatusPayload(
            routes: [iroh, tailscale, websocket],
            now: now
        )
        let publicRoutes = try #require(publicPayload["routes"] as? [[String: Any]])
        #expect(publicRoutes.isEmpty)
        #expect(!String(describing: publicPayload).contains(endpointID))
        #expect(!String(describing: publicRoutes).contains(privateAddress))
        #expect(!String(describing: publicRoutes).contains(websocketURL))
    }
}
