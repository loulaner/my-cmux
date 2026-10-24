"""App producer retirement, not evidence of app-wide runtime zero traffic."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]


class MacPostHogProducerRemovedTests(unittest.TestCase):
    def test_sdk_and_app_composition_are_absent(self):
        for path in (ROOT / 'Sources').rglob('*.swift'):
            text = '\n'.join(line for line in path.read_text().splitlines() if not line.lstrip().startswith('//'))
            for token in ('import PostHog', 'PostHogSDK.', 'PostHogAnalytics.',
                          'ProductAnalytics.app', 'analytics: ProductAnalytics',
                          'PostHogIdentityObserver', 'startProductAnalytics()',
                          'refreshProductAnalyticsActivityContext()'):
                self.assertNotIn(token, text, str(path))
        for file in ('PostHogAnalytics.swift', 'PostHogContextCalls.swift',
                     'PostHogProductAnalyticsSink.swift', 'ProductAnalytics+App.swift',
                     'AppDelegate+ProductAnalytics.swift'):
            self.assertFalse((ROOT / 'Sources' / file).exists())

    def test_only_sdk_product_edges_are_retired(self):
        pbx = (ROOT / 'cmux.xcodeproj/project.pbxproj').read_text()
        for token in ('PostHog in Frameworks', 'productName = PostHog;'):
            self.assertNotIn(token, pbx)
        for token in ('https://github.com/PostHog/posthog-ios.git', 'CmuxProductAnalytics in Frameworks'):
            self.assertIn(token, pbx)
        self.assertTrue((ROOT / 'Packages/macOS/CmuxProductAnalytics/Package.swift').exists())

    def test_real_crash_auth_and_cloud_owners_remain(self):
        app = (ROOT / 'Sources/AppDelegate.swift').read_text()
        for token in ('GhosttyCrashBreadcrumb.pendingCrashFromDefaultStorage',
                      'return pendingCrash', '_ = CmuxFeatureFlags.shared',
                      'telemetry: VMClientTelemetry()',
                      'let telemetryEnabled = TelemetrySettings.enabledForCurrentLaunch'):
            self.assertIn(token, app)
        self.assertNotIn('CloudTelemetryUploader(', app)
        auth = (ROOT / 'Sources/Auth/MacAuthComposition.swift').read_text()
        self.assertIn('coordinator.start()', auth)
        self.assertIn('teamScopeRecoveryTriggers.start()', auth)
        create = (ROOT / 'Sources/Cloud/MachineCreateCoordinator.swift').read_text()
        self.assertIn('CloudMachineCreateCoordinator(output: Self.outputParser, now: now)', create)
        self.assertTrue((ROOT / 'Sources/GhosttyCrashReportMetadata.swift').exists())


if __name__ == '__main__':
    unittest.main()
