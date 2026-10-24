"""Local flag control-plane boundary; not proof of app-wide zero network."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MacLocalFeatureFlagsTests(unittest.TestCase):
    def test_remote_control_plane_is_absent(self):
        source = (ROOT / 'Sources/FeatureFlags.swift').read_text()
        for token in ('import PostHog', 'PostHogSDK', 'URLSession', 'URLRequest',
                      'remoteFlagValueProvider', 'remoteFlagLoader', 'remoteValuesByKey',
                      'cmux.flags.remote.', 'releaseControlDistinctID', 'refreshTask',
                      'Timer', 'applyLoadedFlags', 'applyRemoteFlagValues',
                      'pinsFlagsToLocalValues', 'func start('):
            self.assertNotIn(token, source, token)

    def test_real_local_initialization_keeps_original_gate_without_posthog(self):
        source = (ROOT / 'Sources/AppDelegate.swift').read_text()
        self.assertIn('if !isRunningUnderXCTest, !ManagedDevicePolicy().isEnforced(.disableTelemetry) {\n            _ = CmuxFeatureFlags.shared\n        }', source)
        for token in ('PostHogAnalytics.shared.startIfNeeded()', 'startProductAnalytics()',
                      'PostHogAnalytics.shared.recordLaunchIdentity()'):
            self.assertNotIn(token, source)
        self.assertFalse((ROOT / 'Sources/PostHogAnalytics.swift').exists())

    def test_local_snapshot_and_cloud_markers_remain_real(self):
        source = (ROOT / 'Sources/FeatureFlags.swift').read_text()
        for token in ('CmuxFeatureFlags(publishesOffMainSnapshot: true)',
                      'if overrideCapability.enablesCloudDogfood {',
                      'defaults.set(true, forKey: BetaFeaturesCatalogSection().cloudMachines.userDefaultsKey)',
                      'if publishesOffMainSnapshot {', 'Self.offMainEffectiveValues.withLock',
                      'NotificationCenter.default.post(name: .cmuxFeatureFlagsDidChange, object: self)',
                      'private static func storedBoolValue'):
            self.assertIn(token, source)
        self.assertNotIn('case remote', (ROOT / 'Sources/CmuxFeatureFlagSource.swift').read_text())
        self.assertNotIn('remoteFirst', (ROOT / 'Sources/CmuxFeatureFlagOverridePolicy.swift').read_text())

    def test_inspector_still_presents_and_mutates_local_owner(self):
        source = (ROOT / 'Sources/InternalFlagsWindow.swift').read_text()
        for token in ('InternalFlagsWindowController.shared.show()', 'ForEach(rows)',
                      'flags.setOverride(value, for: row.definition)', 'flags.clearAllOverrides()'):
            self.assertIn(token, source)
        self.assertNotIn('Inspect remote feature flag state', source)
        self.assertNotIn('Controlled remotely', (ROOT / 'Sources/InternalFlagRowSnapshot.swift').read_text())


if __name__ == '__main__':
    unittest.main()
