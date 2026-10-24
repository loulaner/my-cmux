import Foundation
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV

@Suite(.serialized)
struct PostHogAnalyticsPropertiesTests {
    @MainActor
    @Test("Every registered flag keeps its explicit per-build default")
    func localFlagDefaults() throws {
        let suite = "cmux.flags.defaults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #if DEBUG
        let changes = true
        #else
        let changes = false
        #endif
        let expected: [String: Bool] = [
            "sidebar-appkit-list-experiment": true,
            "mobile-workspace-changes-enabled-release": changes,
            "ios-artifact-chip-enabled-release": true,
            "simulator-enabled-release": true,
            "mobile-task-composer-enabled-release": true,
            "go-plan-enabled-release": false,
            "agent-inbox-quick-view-enabled-release": false,
            "conversation-sidebar-release": false,
            "mac-account-directory-release": true,
            "window-hints-release": false,
            "mobile-connect-button-enabled-release": false,
            "sidebar-account-button-enabled-release": true,
            "agent-chat-ui-enabled-release": false,
            "sidebar-workspace-agent-spinner-experiment": false,
            "computer-use-ux-enabled-release": true,
            "workspace-todo-controls-enabled-release": false
        ]
        let flags = CmuxFeatureFlags(defaults: defaults)
        #expect(Set(CmuxFeatureFlags.allFlags.map(\.key)) == Set(expected.keys))
        for flag in CmuxFeatureFlags.allFlags {
            #expect(flag.defaultWhenUnavailable == expected[flag.key])
            #expect(flags.effectiveValue(for: flag) == expected[flag.key])
            #expect(flags.resolution(for: flag).source == .default)
            #expect(flags.resolution(for: flag).allowsLocalOverride)
        }
        #expect(!CmuxFeatureFlags.allFlags.contains(CmuxFeatureFlags.cloudMachinesFlag))
        #expect(CmuxFeatureFlags.cloudMachinesFlag.defaultWhenUnavailable)
    }

    @MainActor
    @Test("Old remote values and install identity are ignored without mutation", arguments: [false, true])
    func historicalRemoteStateIsUntouched(remote: Bool) throws {
        let suite = "cmux.flags.history.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let idKey = "cmux.flags.releaseControlDistinctID"
        defaults.set("historical-install-not-a-current-uuid", forKey: idKey)
        for flag in CmuxFeatureFlags.allFlags {
            defaults.set(remote, forKey: "cmux.flags.remote.\(flag.key)")
        }
        let before = try #require(defaults.persistentDomain(forName: suite)) as NSDictionary
        let flags = CmuxFeatureFlags(defaults: defaults)
        for flag in CmuxFeatureFlags.allFlags {
            #expect(flags.effectiveValue(for: flag) == flag.defaultWhenUnavailable)
            flags.setOverride(!flag.defaultWhenUnavailable, for: flag)
            #expect(flags.effectiveValue(for: flag) == !flag.defaultWhenUnavailable)
        }
        flags.clearAllOverrides()
        #expect(NSDictionary(dictionary: defaults.persistentDomain(forName: suite) ?? [:]) == before)
    }

    @MainActor
    @Test("Local construction does not create a release-control identity")
    func localConstructionDoesNotCreateIdentity() throws {
        let suite = "cmux.flags.no-identity.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = CmuxFeatureFlags(defaults: defaults)
        #expect(defaults.object(forKey: "cmux.flags.releaseControlDistinctID") == nil)
        #expect((defaults.persistentDomain(forName: suite) ?? [:]).isEmpty)
    }

    @MainActor
    @Test("Permitted local values win; disabled overrides fall back without changing persisted values")
    func featureFlagResolutionPrecedence() {
        for fallback in [false, true] {
            for override: Bool? in [nil, false, true] {
                let allowed = CmuxFeatureFlagResolution(overrideValue: override, defaultValue: fallback)
                #expect(allowed.effectiveValue == (override ?? fallback))
                #expect(allowed.source == (override == nil ? .default : .override))
                #expect(allowed.allowsLocalOverride)
                let denied = CmuxFeatureFlagResolution(
                    overrideValue: override, defaultValue: fallback, overridePolicy: .disabled
                )
                #expect(denied.effectiveValue == fallback)
                #expect(denied.source == .default)
                #expect(!denied.allowsLocalOverride)
            }
        }
    }

    @MainActor
    @Test("AppKit sidebar feature flag defaults on")
    func appKitSidebarFeatureFlagDefaultsOn() throws {
        let suite = "cmux.flags.appkit.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(CmuxFeatureFlags(defaults: defaults).isAppKitSidebarListEnabled)
    }

    @MainActor
    @Test("Mobile Pairing button defaults hidden")
    func tailscalePairingButtonDefaultsHidden() throws {
        let suite = "cmux.flags.mobile-connect.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!CmuxFeatureFlags(defaults: defaults).isMobileConnectButtonEnabled)
    }

    @MainActor
    @Test("Overrides persist for every registered flag and explicit nil restores defaults")
    func featureFlagOverridePersistenceRoundTrip() throws {
        let suite = "cmux.flags.persistence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = CmuxFeatureFlags(defaults: defaults)
        for flag in CmuxFeatureFlags.allFlags { first.setOverride(!flag.defaultWhenUnavailable, for: flag) }
        let secondDefaults = try #require(UserDefaults(suiteName: suite))
        let second = CmuxFeatureFlags(defaults: secondDefaults)
        for flag in CmuxFeatureFlags.allFlags {
            #expect(second.overrideValue(for: flag) == !flag.defaultWhenUnavailable)
            #expect(second.effectiveValue(for: flag) == !flag.defaultWhenUnavailable)
            second.setOverride(nil, for: flag)
        }
        let third = CmuxFeatureFlags(defaults: secondDefaults)
        for flag in CmuxFeatureFlags.allFlags {
            #expect(third.overrideValue(for: flag) == nil)
            #expect(third.effectiveValue(for: flag) == flag.defaultWhenUnavailable)
        }
    }

    @MainActor
    @Test("Stored Bool and NSNumber overrides retain their decoding; strings remain invalid")
    func storedLocalBoolDecoding() throws {
        let suite = "cmux.flags.decode.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let flag = CmuxFeatureFlags.simulatorFlag
        for (stored, expected): (Any, Bool?) in [
            (true, true), (false, false), (NSNumber(value: 0), false),
            (NSNumber(value: 2), true), ("false", nil)
        ] {
            defaults.set(stored, forKey: "cmux.flags.override.\(flag.key)")
            #expect(CmuxFeatureFlags(defaults: defaults).overrideValue(for: flag) == expected)
        }
    }

    @MainActor
    @Test("Explicit clear removes registered and legacy overrides, not unrelated historical keys")
    func clearHasOriginalKeyScope() throws {
        let suite = "cmux.flags.clear.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "cmux.flags.override.unknown-future-flag")
        defaults.set(true, forKey: "cmux.flags.remote.unknown-future-flag")
        defaults.set("identity", forKey: "cmux.flags.releaseControlDistinctID")
        defaults.set(false, forKey: "cmux.flags.override.\(CmuxFeatureFlags.cloudMachinesFlag.key)")
        let flags = CmuxFeatureFlags(defaults: defaults)
        for flag in CmuxFeatureFlags.allFlags { flags.setOverride(true, for: flag) }
        flags.clearAllOverrides()
        for flag in CmuxFeatureFlags.allFlags + [CmuxFeatureFlags.cloudMachinesFlag] {
            #expect(defaults.object(forKey: "cmux.flags.override.\(flag.key)") == nil)
        }
        #expect(defaults.object(forKey: "cmux.flags.override.unknown-future-flag") as? Bool == false)
        #expect(defaults.object(forKey: "cmux.flags.remote.unknown-future-flag") as? Bool == true)
        #expect(defaults.string(forKey: "cmux.flags.releaseControlDistinctID") == "identity")
    }

    @MainActor
    @Test("Notifications follow resolution changes, including source-only changes, not repeated writes")
    func localMutationsPostChangeNotifications() async throws {
        let suite = "cmux.flags.notifications.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let flags = CmuxFeatureFlags(defaults: defaults)
        let flag = CmuxFeatureFlags.simulatorFlag
        await confirmation("resolution changed", expectedCount: 4) { changed in
            let observer = NotificationCenter.default.addObserver(
                forName: .cmuxFeatureFlagsDidChange, object: nil, queue: nil
            ) { notification in
                guard notification.object as? CmuxFeatureFlags === flags else { return }
                changed()
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            flags.setOverride(true, for: flag) // source default -> override
            flags.setOverride(true, for: flag) // unchanged
            flags.setOverride(false, for: flag)
            flags.setOverride(nil, for: flag)
            flags.setOverride(nil, for: flag) // unchanged
            flags.setOverride(false, for: flag)
        }
        await confirmation("clear changed", expectedCount: 1) { changed in
            let observer = NotificationCenter.default.addObserver(
                forName: .cmuxFeatureFlagsDidChange, object: nil, queue: nil
            ) { notification in
                guard notification.object as? CmuxFeatureFlags === flags else { return }
                changed()
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            flags.clearAllOverrides()
            flags.clearAllOverrides()
        }
    }

    @MainActor
    @Test("Cloud override grants use the current shipping identity, not legacy official names")
    func currentCloudIdentityGrants() throws {
        let debug = SocketPathMarkerFiles.defaultBaseDebugBundleIdentifier
        let nightly = SocketPathMarkerFiles.nightlyBundleIdentifier
        let cloud = CmuxFeatureFlags.cloudMachinesFlag
        let identities: [(String, Bool, Bool)] = [
            (nightly, false, true), (debug, true, true), (debug + ".m4a", true, true),
            (debug, false, false), (debug + ".m4a", false, false),
            (nightly + ".suffix", false, false), ("com.cmuxterm.app.nightly", false, false),
            ("com.cmuxterm.app.debug", true, false), ("unknown", true, false)
        ]
        for (identity, isDebug, allowed) in identities {
            let suite = "cmux.flags.identity.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let capability = CmuxFeatureFlagOverrideCapability(bundleIdentifier: identity, isDebugBuild: isDebug)
            #expect(capability.allowsCloudOverride == allowed)
            #expect(capability.policy(for: cloud) == (allowed ? .localFirst : .disabled))
            let flags = CmuxFeatureFlags(defaults: defaults, overrideCapability: capability)
            flags.setOverride(false, for: cloud)
            #expect(flags.overrideValue(for: cloud) == (allowed ? false : nil))
            #expect(flags.isCloudMachinesEnabled == !allowed)
            for flag in CmuxFeatureFlags.allFlags {
                #expect(capability.policy(for: flag) == .localFirst)
                flags.setOverride(false, for: flag)
                #expect(!flags.effectiveValue(for: flag))
            }
            flags.setOverride(nil, for: cloud)
            #expect(flags.overrideValue(for: cloud) == nil)
            #expect(flags.isCloudMachinesEnabled)
        }
    }

    @MainActor
    @Test("Tagged Cloud activation survives reload; only explicit dogfood can activate")
    func currentCloudDogfoodMarkers() throws {
        let debug = SocketPathMarkerFiles.defaultBaseDebugBundleIdentifier
        let markerKey = BetaFeaturesCatalogSection().cloudMachines.userDefaultsKey
        let overrideKey = "cmux.flags.override.\(CmuxFeatureFlags.cloudMachinesFlag.key)"
        for markerPresent in [false, true] {
            for request in [false, true] {
                let suite = "cmux.flags.dogfood.\(UUID().uuidString)"
                let defaults = try #require(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                defaults.set(false, forKey: markerKey)
                defaults.set(true, forKey: overrideKey)
                let capability = CmuxFeatureFlagOverrideCapability(
                    bundleIdentifier: debug + ".m4a", isDebugBuild: true,
                    cloudDogfoodRequested: request, cloudDogfoodMarkerPresent: markerPresent
                )
                _ = CmuxFeatureFlags(defaults: defaults, overrideCapability: capability)
                #expect(defaults.bool(forKey: markerKey) == request)
                #expect(defaults.object(forKey: overrideKey) as? Bool == (request ? true : (markerPresent ? false : nil)))
                defaults.set(true, forKey: markerKey)
                let reload = CmuxFeatureFlags(defaults: defaults, overrideCapability: capability)
                reload.clearAllOverrides()
                #expect(defaults.bool(forKey: markerKey))
                #expect(defaults.object(forKey: overrideKey) == nil)
            }
        }
    }

    @Test
    func reportedExceptionReadsCrashAndAppContextFromEnvelope() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-crash-exception-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let crashURL = directory.appendingPathComponent("sample.ghosttycrash")
        let event: [String: Any] = [
            "exception": [
                "values": [
                    [
                        "type": "EXC_BAD_ACCESS",
                        "value": "KERN_INVALID_ADDRESS at 0x0",
                        "mechanism": ["type": "mach"],
                    ],
                ],
            ],
            "contexts": [
                "app": [
                    "app_version": "0.64.22",
                    "app_build": "6422",
                    "app_identifier": "com.cmuxterm.app",
                ],
            ],
        ]
        let eventData = try JSONSerialization.data(withJSONObject: event)
        var envelope = Data(#"{"event_id":"00000000-0000-0000-0000-000000000000"}"#.utf8)
        envelope.append(0x0A)
        envelope.append(Data(#"{"type":"event","length":\#(eventData.count)}"#.utf8))
        envelope.append(0x0A)
        envelope.append(eventData)
        envelope.append(0x0A)
        try envelope.write(to: crashURL)

        let reported = try #require(GhosttyCrashReportMetadata.reportedException(in: crashURL))
        #expect(reported.type == "EXC_BAD_ACCESS")
        #expect(reported.value == "KERN_INVALID_ADDRESS at 0x0")
        #expect(reported.mechanismType == "mach")
        #expect(reported.appVersion == "0.64.22")
        #expect(reported.appBuild == "6422")
        #expect(reported.appNamespace == "com.cmuxterm.app")
    }

    @Test
    func reportedExceptionFallsBackWithoutExceptionPayload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-crash-exception-empty-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let crashURL = directory.appendingPathComponent("no-exception.ghosttycrash")
        let eventData = try JSONSerialization.data(withJSONObject: [
            "debug_meta": ["images": [["code_file": "/Applications/cmux.app/Contents/MacOS/cmux"]]],
        ])
        var envelope = Data(#"{"event_id":"00000000-0000-0000-0000-000000000000"}"#.utf8)
        envelope.append(0x0A)
        envelope.append(Data(#"{"type":"event","length":\#(eventData.count)}"#.utf8))
        envelope.append(0x0A)
        envelope.append(eventData)
        envelope.append(0x0A)
        try envelope.write(to: crashURL)

        #expect(GhosttyCrashReportMetadata.reportedException(in: crashURL)?.type == "UnknownCrash")
        #expect(GhosttyCrashReportMetadata.reportedException(
            in: directory.appendingPathComponent("missing.ghosttycrash")
        ) == nil)
    }
}
#endif
