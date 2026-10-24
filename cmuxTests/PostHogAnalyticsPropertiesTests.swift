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
    func dailyActivePropertiesIncludeVersionAndBuild() {
        let properties = PostHogAnalytics.dailyActiveProperties(
            dayUTC: "2026-02-21",
            reason: "didBecomeActive",
            infoDictionary: [
                "CFBundleShortVersionString": "0.31.0",
                "CFBundleVersion": "230",
            ]
        )

        #expect(properties["day_utc"] as? String == "2026-02-21")
        #expect(properties["reason"] as? String == "didBecomeActive")
        #expect(properties["app_version"] as? String == "0.31.0")
        #expect(properties["app_build"] as? String == "230")
    }

    @Test
    func superPropertiesIncludePlatformVersionAndBuild() {
        let properties = PostHogAnalytics.superProperties(
            infoDictionary: [
                "CFBundleShortVersionString": "0.31.0",
                "CFBundleVersion": "230",
            ]
        )

        #expect(properties["platform"] as? String == "cmuxterm")
        #expect(properties["app_version"] as? String == "0.31.0")
        #expect(properties["app_build"] as? String == "230")
    }

    @Test
    func hourlyActivePropertiesIncludeVersionAndBuild() {
        let properties = PostHogAnalytics.hourlyActiveProperties(
            hourUTC: "2026-02-21T14",
            reason: "didBecomeActive",
            infoDictionary: [
                "CFBundleShortVersionString": "0.31.0",
                "CFBundleVersion": "230",
            ]
        )

        #expect(properties["hour_utc"] as? String == "2026-02-21T14")
        #expect(properties["reason"] as? String == "didBecomeActive")
        #expect(properties["app_version"] as? String == "0.31.0")
        #expect(properties["app_build"] as? String == "230")
    }

    @Test
    func hourlyPropertiesOmitVersionFieldsWhenUnavailable() {
        let properties = PostHogAnalytics.hourlyActiveProperties(
            hourUTC: "2026-02-21T14",
            reason: "activeTimer",
            infoDictionary: [:]
        )

        #expect(properties["hour_utc"] as? String == "2026-02-21T14")
        #expect(properties["reason"] as? String == "activeTimer")
        #expect(properties["app_version"] == nil)
        #expect(properties["app_build"] == nil)
    }

    @Test
    func propertiesOmitVersionFieldsWhenUnavailable() {
        let superProperties = PostHogAnalytics.superProperties(infoDictionary: [:])
        #expect(superProperties["platform"] as? String == "cmuxterm")
        #expect(superProperties["app_version"] == nil)
        #expect(superProperties["app_build"] == nil)

        let dailyProperties = PostHogAnalytics.dailyActiveProperties(
            dayUTC: "2026-02-21",
            reason: "activeTimer",
            infoDictionary: [:]
        )
        #expect(dailyProperties["day_utc"] as? String == "2026-02-21")
        #expect(dailyProperties["reason"] as? String == "activeTimer")
        #expect(dailyProperties["app_version"] == nil)
        #expect(dailyProperties["app_build"] == nil)
    }

    @Test
    func flushPolicyIncludesDailyAndHourlyActiveEvents() {
        #expect(PostHogAnalytics.shouldFlushAfterCapture(event: "cmux_daily_active"))
        #expect(PostHogAnalytics.shouldFlushAfterCapture(event: "cmux_hourly_active"))
        #expect(!PostHogAnalytics.shouldFlushAfterCapture(event: "cmux_other_event"))
    }

    @Test
    func activeEventCaptureFlushesBeforeShutdown() throws {
        let suiteName = "cmux.posthog.analytics.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let fixedDate = try #require(Calendar(identifier: .iso8601).date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 2,
            day: 21,
            hour: 14
        )))
        let capturedQueue = DispatchQueue(label: "com.cmux.tests.posthog.capture")
        var capturedEvents: [(event: String, properties: [String: Any])] = []
        let eventsCaptured = DispatchSemaphore(value: 0)
        let flushCalled = DispatchSemaphore(value: 0)
        let analytics = PostHogAnalytics(
            workQueue: DispatchQueue(label: "com.cmux.tests.posthog.analytics"),
            didStart: true,
            userDefaults: defaults,
            now: { fixedDate },
            capturePostHog: { event, properties in
                capturedQueue.sync {
                    capturedEvents.append((event: event, properties: properties))
                    if capturedEvents.count == 2 {
                        eventsCaptured.signal()
                    }
                }
            },
            flushPostHog: {
                flushCalled.signal()
            }
        )

        analytics.trackActive(reason: "didBecomeActive")
        #expect(eventsCaptured.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(flushCalled.wait(timeout: .now() + .seconds(1)) == .success)
        let events = capturedQueue.sync { capturedEvents }
        #expect(events.map(\.event) == ["cmux_daily_active", "cmux_hourly_active"])
        let dailyEvent = try #require(events.first)
        let hourlyEvent = try #require(events.dropFirst().first)
        #expect(dailyEvent.properties["day_utc"] as? String == "2026-02-21")
        #expect(dailyEvent.properties["reason"] as? String == "didBecomeActive")
        #expect(hourlyEvent.properties["hour_utc"] as? String == "2026-02-21T14")
        #expect(hourlyEvent.properties["reason"] as? String == "didBecomeActive")
    }

    @Test
    func activeFlushDoesNotBlockMainThreadWhenSDKFlushBlocks() throws {
        let suiteName = "cmux.posthog.analytics.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let fixedDate = try #require(Calendar(identifier: .iso8601).date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 2,
            day: 21,
            hour: 14
        )))
        let flushStarted = DispatchSemaphore(value: 0)
        let flushCanReturn = DispatchSemaphore(value: 0)
        let flushReturned = DispatchSemaphore(value: 0)
        let flushRanOnMainThread = DispatchSemaphore(value: 0)
        let flushRanOffMainThread = DispatchSemaphore(value: 0)
        let callerReturned = DispatchSemaphore(value: 0)
        let analytics = PostHogAnalytics(
            workQueue: DispatchQueue(label: "com.cmux.tests.posthog.analytics"),
            didStart: true,
            userDefaults: defaults,
            now: { fixedDate },
            capturePostHog: { _, _ in },
            flushPostHog: {
                if Thread.isMainThread {
                    flushRanOnMainThread.signal()
                } else {
                    flushRanOffMainThread.signal()
                }
                flushStarted.signal()
                _ = flushCanReturn.wait(timeout: .now() + .seconds(5))
                flushReturned.signal()
            }
        )

        let trackActiveOnMainThread = {
            analytics.trackActive(reason: "didBecomeActive")
            callerReturned.signal()
        }

        if Thread.isMainThread {
            trackActiveOnMainThread()
        } else {
            DispatchQueue.main.async(execute: trackActiveOnMainThread)
        }

        #expect(callerReturned.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(flushStarted.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(flushRanOffMainThread.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(flushRanOnMainThread.wait(timeout: .now() + .milliseconds(50)) == .timedOut)
        #expect(flushReturned.wait(timeout: .now() + .milliseconds(50)) == .timedOut)
        flushCanReturn.signal()
        #expect(flushReturned.wait(timeout: .now() + .seconds(1)) == .success)
    }

    @Test
    func crashExceptionPropertiesIncludeCrashAndLaunchVersions() throws {
        let reported = GhosttyCrashReportMetadata.ReportedException(
            type: "EXC_BAD_ACCESS",
            value: "KERN_INVALID_ADDRESS at 0x0000000000000000",
            mechanismType: "mach",
            appVersion: "0.64.22",
            appBuild: "6422",
            appNamespace: "com.cmuxterm.app"
        )
        let properties = PostHogAnalytics.crashExceptionProperties(
            reported: reported,
            infoDictionary: [
                "CFBundleShortVersionString": "0.64.23",
                "CFBundleVersion": "6423",
            ]
        )

        #expect(properties["$exception_level"] as? String == "error")
        #expect(properties["$exception_fingerprint"] as? String == "cmux-mac-crash:EXC_BAD_ACCESS")
        let list = try #require(properties["$exception_list"] as? [[String: Any]])
        let entry = try #require(list.first)
        #expect(entry["type"] as? String == "EXC_BAD_ACCESS")
        #expect(entry["value"] as? String == "Previous launch crashed")
        let mechanism = try #require(entry["mechanism"] as? [String: Any])
        #expect(mechanism["handled"] as? Bool == false)
        #expect(mechanism["type"] as? String == "mach")
        // The crashed build and the reporting launch are identified separately.
        #expect(properties["crash_app_version"] as? String == "0.64.22")
        #expect(properties["crash_app_build"] as? String == "6422")
        #expect(properties["crash_app_namespace"] as? String == "com.cmuxterm.app")
        #expect(properties["app_version"] as? String == "0.64.23")
        #expect(properties["app_build"] as? String == "6423")
        #expect((properties["channel"] as? String)?.isEmpty == false)
    }

    @Test
    func crashExceptionPropertiesTolerateMissingReport() {
        let properties = PostHogAnalytics.crashExceptionProperties(
            reported: nil,
            infoDictionary: [:]
        )

        #expect(properties["$exception_level"] as? String == "error")
        #expect(properties["$exception_fingerprint"] as? String == "cmux-mac-crash:UnknownCrash")
        let entry = (properties["$exception_list"] as? [[String: Any]])?.first
        #expect(entry?["type"] as? String == "UnknownCrash")
        let mechanism = entry?["mechanism"] as? [String: Any]
        #expect(mechanism?["handled"] as? Bool == false)
        #expect(mechanism?["type"] as? String == "ghostty_crash_report")
        #expect(properties["crash_app_version"] == nil)
        #expect(properties["crash_app_build"] == nil)
        #expect(properties["crash_app_namespace"] == nil)
        #expect(properties["app_version"] == nil)
        #expect(properties["app_build"] == nil)
    }

    @Test
    func crashExceptionPropertiesSanitizeTokensAndScrubValues() {
        #expect(PostHogAnalytics.sanitizedExceptionToken("EXC_CRASH") == "EXC_CRASH")
        #expect(PostHogAnalytics.sanitizedExceptionToken("NSInternalInconsistencyException") == "NSInternalInconsistencyException")
        #expect(PostHogAnalytics.sanitizedExceptionToken("bad type /Users/dev") == nil)
        #expect(PostHogAnalytics.sanitizedExceptionToken("   ") == nil)
        #expect(PostHogAnalytics.sanitizedExceptionToken(nil) == nil)

    }

    @Test(arguments: [
        "Crash at /Users/Jane Doe/Private Project.swift",
        "Opening /tmp/Customer Contract.pdf failed",
        "password=hunter2 token=private-token alice@example.com",
        "Server returned confidential customer content",
    ])
    func crashExceptionDoesNotTransmitRawReason(reason: String) throws {
        let reported = GhosttyCrashReportMetadata.ReportedException(
            type: "EXC_CRASH",
            value: reason,
            mechanismType: "signal",
            appVersion: "0.64.22",
            appBuild: "6422",
            appNamespace: "com.cmuxterm.app"
        )
        let properties = PostHogAnalytics.crashExceptionProperties(reported: reported, infoDictionary: [:])
        let entry = try #require((properties["$exception_list"] as? [[String: Any]])?.first)
        #expect(entry["value"] as? String == "Previous launch crashed")
        let serialized = String(decoding: try JSONSerialization.data(withJSONObject: properties), as: UTF8.self)
        #expect(!serialized.contains(reason))
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

    @Test
    func captureCrashExceptionCapturesOncePerCrashArtifact() throws {
        let suiteName = "cmux.posthog.crash.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let crashURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-crash-capture-\(UUID().uuidString).ghosttycrash")
        defer { try? FileManager.default.removeItem(at: crashURL) }
        try Data("not an envelope".utf8).write(to: crashURL)
        let crashDate = Date(timeIntervalSince1970: 1_000)

        let workQueue = DispatchQueue(label: "com.cmux.tests.posthog.crash.analytics")
        let capturedQueue = DispatchQueue(label: "com.cmux.tests.posthog.crash.capture")
        var capturedEvents: [(event: String, properties: [String: Any])] = []
        let analytics = PostHogAnalytics(
            workQueue: workQueue,
            didStart: true,
            userDefaults: defaults,
            now: { Date(timeIntervalSince1970: 2_000) },
            capturePostHog: { event, properties in
                capturedQueue.sync {
                    capturedEvents.append((event: event, properties: properties))
                }
            },
            flushPostHog: {}
        )
        let pendingCrash = GhosttyCrashBreadcrumb.PendingCrash(fileURL: crashURL, modifiedAt: crashDate)

        analytics.captureCrashException(pendingCrash: pendingCrash)
        workQueue.sync {}
        #expect(capturedQueue.sync { capturedEvents }.count == 1)

        // The same crash artifact is never reported twice.
        analytics.captureCrashException(pendingCrash: pendingCrash)
        workQueue.sync {}
        #expect(capturedQueue.sync { capturedEvents }.count == 1)

        // A newer crash artifact reports again.
        let newerCrash = GhosttyCrashBreadcrumb.PendingCrash(
            fileURL: crashURL,
            modifiedAt: crashDate.addingTimeInterval(60)
        )
        analytics.captureCrashException(pendingCrash: newerCrash)
        workQueue.sync {}
        let events = capturedQueue.sync { capturedEvents }
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.event == "$exception" })
        let properties = try #require(events.first?.properties)
        #expect(properties["$exception_level"] as? String == "error")
        #expect(properties["$exception_fingerprint"] as? String == "cmux-mac-crash:UnknownCrash")
    }

    @Test(arguments: [false, true])
    func nativeCrashWithoutAppContextUsesPreviousLaunchIdentity(olderArtifact: Bool) throws {
        let suiteName = "cmux.posthog.native.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([
            "started_at": Date(timeIntervalSince1970: 900),
            "app_version": "0.64.22",
            "app_build": "6422",
            "app_namespace": "com.cmuxterm.app",
        ], forKey: "posthog.previousLaunchIdentity")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).ghosttycrash")
        defer { try? FileManager.default.removeItem(at: url) }
        // Real sentry.native envelopes have a Ghostty release, OS context and
        // a minidump attachment, with no JSON exception list or app context.
        let event: [String: Any] = ["platform": "native", "release": "1.3.2-HEAD-ghostty",
                                    "contexts": ["os": ["name": "macOS"]]]
        let payload = try JSONSerialization.data(withJSONObject: event)
        var envelope = Data("{}\n".utf8)
        envelope.append(try JSONSerialization.data(withJSONObject: ["type": "event", "length": payload.count]))
        envelope.append(Data("\n".utf8))
        envelope.append(payload)
        envelope.append(Data("\n".utf8))
        try envelope.write(to: url)
        let workQueue = DispatchQueue(label: "com.cmux.tests.posthog.native")
        let capturedQueue = DispatchQueue(label: "com.cmux.tests.posthog.native.captures")
        var captured: [String: Any] = [:]
        let analytics = PostHogAnalytics(
            workQueue: workQueue, didStart: true, userDefaults: defaults,
            now: { Date(timeIntervalSince1970: 2_000) },
            capturePostHog: { _, properties in capturedQueue.sync { captured = properties } },
            flushPostHog: {}, environment: [:], telemetryEnabled: { true }
        )
        analytics.recordLaunchIdentity()
        workQueue.sync {}
        #expect(defaults.dictionary(forKey: "posthog.previousLaunchIdentity")?["started_at"] as? Date == Date(timeIntervalSince1970: 2_000))
        analytics.captureCrashException(pendingCrash: .init(fileURL: url, modifiedAt: Date(timeIntervalSince1970: olderArtifact ? 800 : 1_000)))
        workQueue.sync {}
        let properties = capturedQueue.sync { captured }
        #expect(properties["crash_app_version"] as? String == (olderArtifact ? nil : "0.64.22"))
        #expect(properties["crash_app_build"] as? String == (olderArtifact ? nil : "6422"))
        #expect(properties["crash_app_namespace"] as? String == (olderArtifact ? nil : "com.cmuxterm.app"))
        #expect(properties["$exception_fingerprint"] as? String == "cmux-mac-crash:UnknownCrash")
    }

    @Test
    func captureCrashExceptionSkipsUnderXCTestEvenWhenTelemetryIsEnabled() throws {
        let suiteName = "cmux.posthog.crash.xctest.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let crashURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-crash-capture-xctest-\(UUID().uuidString).ghosttycrash")
        defer { try? FileManager.default.removeItem(at: crashURL) }
        try Data("not an envelope".utf8).write(to: crashURL)

        let workQueue = DispatchQueue(label: "com.cmux.tests.posthog.crash.xctest.analytics")
        let capturedQueue = DispatchQueue(label: "com.cmux.tests.posthog.crash.xctest.capture")
        var capturedEvents: [String] = []
        let analytics = PostHogAnalytics(
            workQueue: workQueue,
            didStart: false,
            userDefaults: defaults,
            now: { Date(timeIntervalSince1970: 2_000) },
            capturePostHog: { event, _ in
                capturedQueue.sync { capturedEvents.append(event) }
            },
            flushPostHog: {},
            environment: ["CMUX_TEST_PROCESS": "1", "CMUX_POSTHOG_ENABLE": "1"],
            telemetryEnabled: { true }
        )

        analytics.captureCrashException(pendingCrash: GhosttyCrashBreadcrumb.PendingCrash(
            fileURL: crashURL,
            modifiedAt: Date(timeIntervalSince1970: 1_000)
        ))
        workQueue.sync {}

        #expect(capturedQueue.sync { capturedEvents }.isEmpty)
        #expect(defaults.object(forKey: "posthog.lastReportedCrashAt") == nil)
    }

    @Test
    func captureCrashExceptionSkipsWhenTelemetryNeverStarted() throws {
        let suiteName = "cmux.posthog.crash.disabled.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let crashURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-crash-capture-disabled-\(UUID().uuidString).ghosttycrash")
        defer { try? FileManager.default.removeItem(at: crashURL) }
        try Data("not an envelope".utf8).write(to: crashURL)

        let workQueue = DispatchQueue(label: "com.cmux.tests.posthog.crash.disabled.analytics")
        let capturedQueue = DispatchQueue(label: "com.cmux.tests.posthog.crash.disabled.capture")
        var capturedEvents: [String] = []
        let analytics = PostHogAnalytics(
            workQueue: workQueue,
            didStart: false,
            userDefaults: defaults,
            now: { Date(timeIntervalSince1970: 2_000) },
            capturePostHog: { event, _ in
                capturedQueue.sync { capturedEvents.append(event) }
            },
            flushPostHog: {}
        )

        analytics.captureCrashException(pendingCrash: GhosttyCrashBreadcrumb.PendingCrash(
            fileURL: crashURL,
            modifiedAt: Date(timeIntervalSince1970: 1_000)
        ))
        workQueue.sync {}

        #expect(capturedQueue.sync { capturedEvents }.isEmpty)
        #expect(defaults.object(forKey: "posthog.lastReportedCrashAt") == nil)
    }
}
#endif
