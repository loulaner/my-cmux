"""Architecture boundary guards, not a live zero-traffic assertion."""
import plistlib
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class TelemetryRemovalTests(unittest.TestCase):
    def test_dedicated_producers_and_consumers_are_removed(self):
        for name in ('CmuxMobileAnalytics', 'CmuxMobileCrashReporting'):
            self.assertFalse((ROOT / 'Packages/iOS' / name).exists())
            for path in [*ROOT.glob('Packages/*/*/Package.swift'),
                         ROOT / 'ios/cmuxPackage/Package.swift',
                         ROOT / 'cmux.xcworkspace/contents.xcworkspacedata',
                         ROOT / 'ios/cmux-ios.xcodeproj/project.pbxproj']:
                self.assertNotIn(name, path.read_text(), str(path))
        for name in ('MobileAnalyticsComposition', 'AnalyticsTokenProviderBridge',
                     'MobileSessionReplayMasking', 'MobileFeatureFlags'):
            self.assertFalse((ROOT / f'ios/cmuxPackage/Sources/cmuxFeature/{name}.swift').exists())

    def test_app_composition_only_observes_locally(self):
        source = (ROOT / 'ios/cmux/AppCompositionRoot.swift').read_text()
        self.assertRegex(source, r'analytics: any AnalyticsEmitting = NoopAnalytics\(\)')
        self.assertNotRegex(source, r'MobileCrashReporter|SentryReporter|AnalyticsEmitter|HTTPClientConfigLoader|resolveClientID|sessionStore|featureFlags|sendAnonymousTelemetry')
        for retained in ('appLog.ingest(event)', 'MobileAppLifecycleDiagnostics(',
                         'MobileDebugLog.shared', '.appLaunched', '.appForegrounded',
                         '.appBecameInactive', '.appBackgrounded',
                         'irx.didBecomeActive()', 'irx.didEnterBackground()'):
            self.assertIn(retained, source)

    def test_shipping_values_have_no_remote_cache_input(self):
        source = (ROOT / 'ios/cmuxPackage/Sources/cmuxFeature/CMUXMobileRootScene.swift').read_text()
        self.assertIn('.terminalFilesChipEnabled(true)', source)
        self.assertIn('.keyboardDockRebuildRevertEnabled(false)', source)
        self.assertNotRegex(source, r'MobileFeatureFlags|featureFlags|cmux\.mobile\.flags\.remote')
        self.assertIn('analytics: any AnalyticsEmitting = NoopAnalytics()', source)
        self.assertIn('analyticsClientID: String? = nil', source)
        self.assertIn('terminalLatencyObserver: any MobileTerminalLatencyObserving = NoopMobileTerminalLatencyObserver()', source)
        self.assertIn('feedPerformanceObserver: (any MobileFeedPerformanceObserving)? = nil', source)

    def test_consent_and_crash_selectors_are_not_read_or_written(self):
        source = (ROOT / 'Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/MobileSettingsView.swift').read_text()
        self.assertNotRegex(source, r'sendAnonymousTelemetry|crashReportingEnabled|MobileSettingsTelemetryToggle')
        self.assertIn('MobileSettingsDiagnosticsSection()', source)
        for path in (ROOT / 'ios/Config').glob('*.plist'):
            self.assertNotIn('CMUXCrashReportingEnabled', plistlib.loads(path.read_bytes()))
        for path in (ROOT / 'ios/Config').glob('*.xcconfig'):
            self.assertNotIn('CMUX_CRASH_REPORTING_ENABLED', path.read_text())


if __name__ == '__main__':
    unittest.main()
