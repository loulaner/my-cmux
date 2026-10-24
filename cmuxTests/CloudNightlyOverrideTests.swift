import CmuxCloud
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct CloudNightlyOverrideTests {
    private let cloud = CmuxFeatureFlags.cloudMachinesFlag
    private let nightly = CmuxFeatureFlagOverrideCapability(
        bundleIdentifier: SocketPathMarkerFiles.nightlyBundleIdentifier, isDebugBuild: false
    )

    @Test(arguments: [
        (SocketPathMarkerFiles.nightlyBundleIdentifier as String?, false, true),
        (SocketPathMarkerFiles.defaultBaseDebugBundleIdentifier, true, true),
        (SocketPathMarkerFiles.defaultBaseDebugBundleIdentifier + ".issue12705", true, true),
        (SocketPathMarkerFiles.stableBundleIdentifier, false, false),
        (SocketPathMarkerFiles.stableBundleIdentifier, true, false),
        (SocketPathMarkerFiles.stagingBundleIdentifier, false, false),
        (SocketPathMarkerFiles.defaultBaseDebugBundleIdentifier + ".issue12705", false, false),
        (SocketPathMarkerFiles.nightlyBundleIdentifier + "-lookalike", false, false),
        (SocketPathMarkerFiles.nightlyBundleIdentifier + ".suffix", false, false),
        ("unknown.NIGHTLY", false, false),
        ("", true, false),
        (nil, true, false),
        (nil, false, false),
        ("com.cmuxterm.app.nightly", false, false),
        ("com.cmuxterm.app.debug", true, false),
        ("com.cmuxterm.app.debug.issue12705", true, false)
    ])
    func capabilityUsesBuildIdentity(bundleID: String?, isDebug: Bool, allowed: Bool) {
        let capability = CmuxFeatureFlagOverrideCapability(
            bundleIdentifier: bundleID, isDebugBuild: isDebug
        )
        #expect(capability.allowsCloudOverride == allowed)
        #expect(capability.policy(for: cloud) == (allowed ? .localFirst : .disabled))
        #expect(capability.policy(for: CmuxFeatureFlags.simulatorFlag) == .localFirst)
    }

    @Test
    func taggedArtifactPreservesActivationButClearsDogfoodOverride() throws {
        let suite = "cmux.cloud.debug.marker.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: BetaFeaturesCatalogSection().cloudMachines.userDefaultsKey)
        defaults.set(true, forKey: "cmux.flags.override.\(cloud.key)")

        _ = CmuxFeatureFlags(
            defaults: defaults,
            overrideCapability: CmuxFeatureFlagOverrideCapability(
                bundleIdentifier: SocketPathMarkerFiles.defaultBaseDebugBundleIdentifier + ".old", isDebugBuild: true,
                cloudDogfoodRequested: false, cloudDogfoodMarkerPresent: true
            )
        )

        #expect(defaults.bool(forKey: BetaFeaturesCatalogSection().cloudMachines.userDefaultsKey))
        #expect(defaults.bool(forKey: "cmux.flags.override.\(cloud.key)") == false)
    }

    @Test
    func ordinaryDebugBuildKeepsPersistedCloudSettings() throws {
        let suite = "cmux.cloud.debug.stable.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let betaKey = BetaFeaturesCatalogSection().cloudMachines.userDefaultsKey
        let overrideKey = "cmux.flags.override.\(cloud.key)"
        defaults.set(true, forKey: betaKey)
        defaults.set(true, forKey: overrideKey)

        _ = CmuxFeatureFlags(
            defaults: defaults,
            overrideCapability: CmuxFeatureFlagOverrideCapability(
                bundleIdentifier: SocketPathMarkerFiles.defaultBaseDebugBundleIdentifier, isDebugBuild: true, cloudDogfoodRequested: false
            )
        )

        #expect(defaults.bool(forKey: betaKey))
        #expect(defaults.bool(forKey: overrideKey))
    }

    @Test
    func nightlyPickerControlsLegacyLocalOverride() throws {
        let suite = "cmux.cloud.nightly.picker.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let flags = CmuxFeatureFlags(
            defaults: defaults, overrideCapability: nightly
        )

        let initial = InternalFlagRowSnapshot(definition: cloud, flags: flags)
        #expect(initial.resolution.allowsLocalOverride)
        #expect(initial.resolution.source == .default)
        #expect(initial.overrideChoice == .noOverride)
        #expect(initial.overrideNote == String(
            localized: "featureFlags.override.cloudDogfoodNote",
            defaultValue: "Cloud overrides take priority in this Nightly or debug build."
        ))

        for choice in [InternalFlagOverrideChoice.on, .off] {
            flags.setOverride(choice.overrideValue, for: cloud)
            let row = InternalFlagRowSnapshot(definition: cloud, flags: flags)
            #expect(row.overrideChoice == choice)
            #expect(row.resolution.effectiveValue == choice.overrideValue)
            #expect(row.resolution.source == .override)
            #expect(row.sourceTitle == String(localized: "featureFlags.source.override", defaultValue: "Override"))
            #expect(row.resolution.allowsLocalOverride)

            #expect(flags.resolution(for: cloud) == row.resolution)
        }

        flags.setOverride(InternalFlagOverrideChoice.noOverride.overrideValue, for: cloud)
        let cleared = InternalFlagRowSnapshot(definition: cloud, flags: flags)
        #expect(cleared.overrideChoice == .noOverride)
        #expect(cleared.resolution.source == .default)
        #expect(cleared.resolution.effectiveValue == CmuxFeatureFlags.cloudMachinesDefault)
        #expect(cleared.resolution.allowsLocalOverride)
    }

    @Test
    func nightlyOverridesAndClearingPersistAcrossReconstruction() throws {
        let suite = "cmux.cloud.nightly.persistence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let flags = CmuxFeatureFlags(
            defaults: defaults, overrideCapability: nightly
        )

        flags.setOverride(true, for: cloud)

        let nextDefaults = try #require(UserDefaults(suiteName: suite))
        let relaunched = CmuxFeatureFlags(
            defaults: nextDefaults, overrideCapability: nightly
        )
        #expect(relaunched.overrideValue(for: cloud) == true)
        #expect(relaunched.isCloudMachinesEnabled)

        #expect(relaunched.isCloudMachinesEnabled)
        relaunched.setOverride(nil, for: cloud)

        let cleared = CmuxFeatureFlags(defaults: nextDefaults, overrideCapability: nightly)
        #expect(cleared.overrideValue(for: cloud) == nil)
        #expect(cleared.isCloudMachinesEnabled)
        cleared.setOverride(true, for: cloud)
        cleared.clearAllOverrides()
        #expect(cleared.overrideValue(for: cloud) == nil)
        #expect(cleared.isCloudMachinesEnabled)
        let afterClearAll = CmuxFeatureFlags(defaults: nextDefaults, overrideCapability: nightly)
        #expect(afterClearAll.overrideValue(for: cloud) == nil)
        #expect(afterClearAll.isCloudMachinesEnabled)
    }

    @Test
    func stableIgnoresPersistedOverrideAndRejectsWrites() throws {
        // A stable identity disables overrides and keeps the local definition's
        // fallback. The retired key is never loaded from a remote payload.
        let expectedValue = CmuxFeatureFlags.cloudMachinesDefault
        let persistedOverride = !expectedValue
        let suite = "cmux.cloud.stable.override.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dogfood = CmuxFeatureFlags(defaults: defaults, overrideCapability: nightly)
        dogfood.setOverride(persistedOverride, for: cloud)
        let stable = CmuxFeatureFlags(
            defaults: defaults,
            overrideCapability: .init(bundleIdentifier: SocketPathMarkerFiles.stableBundleIdentifier, isDebugBuild: false)
        )

        let row = InternalFlagRowSnapshot(definition: cloud, flags: stable)
        #expect(!row.resolution.allowsLocalOverride)
        #expect(row.resolution.effectiveValue == expectedValue)
        #expect(row.resolution.source == .default)
        #expect(row.overrideNote == String(
            localized: "featureFlags.override.buildDisallowedNote",
            defaultValue: "This build does not allow local overrides."
        ))
        stable.setOverride(!persistedOverride, for: cloud)
        #expect(stable.overrideValue(for: cloud) == persistedOverride)
        stable.clearAllOverrides()
        stable.setOverride(true, for: cloud)
        #expect(stable.overrideValue(for: cloud) == nil)
        #expect(stable.isCloudMachinesEnabled == expectedValue)
    }

    @Test
    func ordinaryLocalOverridesRemainAvailableInNightly() throws {
        let suite = "cmux.cloud.nightly.scope.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let flags = CmuxFeatureFlags(
            defaults: defaults, overrideCapability: nightly
        )

        for flag in CmuxFeatureFlags.allFlags where flag.key != cloud.key {
            flags.setOverride(true, for: flag)
            #expect(flags.overrideValue(for: flag) == true)
            #expect(flags.effectiveValue(for: flag))
            #expect(flags.resolution(for: flag).allowsLocalOverride)
        }
    }

    @Test(arguments: [
        (SocketPathMarkerFiles.stableBundleIdentifier, false),
        (SocketPathMarkerFiles.stagingBundleIdentifier, false),
        (SocketPathMarkerFiles.nightlyBundleIdentifier, false),
        (SocketPathMarkerFiles.defaultBaseDebugBundleIdentifier, false),
        (SocketPathMarkerFiles.defaultBaseDebugBundleIdentifier + ".cloud-dogfood", true),
        ("com.cmuxterm.app.nightly", false),
        ("com.cmuxterm.app.debug", false),
        ("com.cmuxterm.app.debug.cloud-dogfood", false)
    ])
    func reloadMarkerPreservesTaggedDebugActivation(bundleID: String, debugActivates: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Fixture.bundle/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleVersion": "1",
            "CMUXCloudDogfoodEnabled": true
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: contents.deletingLastPathComponent()))
        let suite = "cmux.cloud.reload.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let betaKey = BetaFeaturesCatalogSection().cloudMachines.userDefaultsKey
        defaults.set(false, forKey: betaKey)
        let flags = CmuxFeatureFlags(
            defaults: defaults,
            overrideCapability: .init(bundle: bundle)
        )

        #if DEBUG
        let expected = debugActivates
        #else
        let expected = false
        #endif
        #expect(defaults.bool(forKey: betaKey) == expected)
        #expect(flags.isCloudMachinesEnabled)
        let managedOff = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { _, _ in true })
        #expect(!CloudMachinesFeature.isEnabled(defaults: defaults, policy: managedOff))
    }

    @Test(arguments: ["com.cmuxterm.app", "com.cmuxterm.app.staging",
                      "com.cmuxterm.app.nightly", "com.cmuxterm.app.debug",
                      "com.cmuxterm.app.debug.cloud-dogfood"])
    func legacyIdentitiesCannotGrantOrActivateCloud(bundleID: String) throws {
        for isDebug in [false, true] {
            for wasActivated in [false, true] {
                let suite = "cmux.cloud.legacy-denied.\(UUID().uuidString)"
                let defaults = try #require(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let betaKey = BetaFeaturesCatalogSection().cloudMachines.userDefaultsKey
                defaults.set(wasActivated, forKey: betaKey)
                let capability = CmuxFeatureFlagOverrideCapability(
                    bundleIdentifier: bundleID, isDebugBuild: isDebug,
                    cloudDogfoodRequested: true, cloudDogfoodMarkerPresent: true
                )
                #expect(!capability.allowsCloudOverride)
                #expect(!capability.enablesCloudDogfood)
                #expect(!capability.isTaggedDebugArtifact)
                #expect(capability.policy(for: cloud) == .disabled)
                let flags = CmuxFeatureFlags(defaults: defaults, overrideCapability: capability)
                flags.setOverride(false, for: cloud)
                #expect(flags.overrideValue(for: cloud) == nil)
                #expect(defaults.object(forKey: "cmux.flags.override.\(cloud.key)") == nil)
                #expect(defaults.bool(forKey: betaKey) == wasActivated)
                let policy = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { _, _ in nil })
                #expect(CloudMachinesFeature.isEnabled(defaults: defaults, policy: policy) == wasActivated)
                flags.clearAllOverrides()
                #expect(defaults.bool(forKey: betaKey) == wasActivated)
            }
        }
    }

}
