"""Static producer-retirement boundaries, not evidence of runtime zero traffic."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class MacSentryStartupRemovedTests(unittest.TestCase):
    def test_app_has_no_sentry_start_or_upload_bridge(self):
        source = (ROOT / 'Sources/AppDelegate.swift').read_text()
        for token in ('import Sentry\n', 'import CmuxSentryReporting\n', 'SentrySDK.',
                      'transportSentryReporter', 'TransportSentryReporter(',
                      'sentryStartupPolicy', 'CMUX_TEST_SENTRY_ENABLED',
                      'appDelegate.didFinish.sentry.', 'setEventTap'):
            self.assertNotIn(token, source)
        for path in (ROOT / 'Sources').rglob('*.swift'):
            self.assertNotIn('SentrySDK.start', path.read_text(), str(path))

    def test_original_xctest_detection_and_launch_fields_remain(self):
        source = (ROOT / 'Sources/AppDelegate.swift').read_text()
        self.assertIn('let isRunningUnderXCTest = MacSentryStartupPolicy.isRunningUnderXCTest(environment: env)', source)
        self.assertIn('private static let cachedIsRunningUnderXCTest = MacSentryStartupPolicy.isRunningUnderXCTest(', source)
        for token in ('let env = ProcessInfo.processInfo.environment',
                      'let telemetryEnabled = TelemetrySettings.enabledForCurrentLaunch',
                      '"xctest": isRunningUnderXCTest ? "1" : "0"',
                      '"telemetry": telemetryEnabled ? "1" : "0"'):
            self.assertIn(token, source)

    def test_only_crash_test_menu_action_is_retired(self):
        app = (ROOT / 'Sources/cmuxApp.swift').read_text()
        delegate = (ROOT / 'Sources/AppDelegate.swift').read_text()
        self.assertNotIn('triggerSentryTestCrash', delegate + app)
        self.assertNotIn('Trigger Sentry Test Crash', app)
        self.assertIn('appDelegate.copyFocusLogs(nil)', app)
        self.assertIn('menu.updateLogs.copyFocusLogs', app)

    def test_local_diagnostics_and_other_telemetry_owners_remain(self):
        source = (ROOT / 'Sources/AppDelegate.swift').read_text()
        for token in ('CmuxMainRunLoopStallMonitor.shared.installIfNeeded()',
                      'CmuxMainThreadTurnProfiler.shared.installIfNeeded()',
                      'uiTestDiagnosticsWriter.write(stage: "didFinishLaunching")',
                      'PostHogAnalytics.shared.recordLaunchIdentity()',
                      'if telemetryEnabled && !isRunningUnderXCTest {',
                      'PostHogAnalytics.shared.startIfNeeded()', 'startProductAnalytics()',
                      'CmuxFeatureFlags.shared.start()', 'GhosttyCrashBreadcrumb.markCleanExit()'):
            self.assertIn(token, source)
        ring = (ROOT / 'Sources/Mobile/MobileHostDiagnostics.swift').read_text()
        self.assertIn('nonisolated static let log = DiagnosticLog(', ring)
        self.assertIn('role: .macHost', ring)

    def test_shared_policy_and_host_isolation_tests_remain(self):
        for path in ('Sources/App/MacSentryStartupPolicy.swift', 'Sources/AppDelegate+TestRuntime.swift',
                     'Sources/SentryHelper.swift', 'Sources/GhosttyCrashBreadcrumb.swift',
                     'Sources/AppDelegate+CrashSessionSnapshotRemoval.swift',
                     'Packages/Shared/CmuxSentryTelemetry/Package.swift'):
            self.assertTrue((ROOT / path).is_file(), path)
        tests = (ROOT / 'cmuxTests/MacSentryStartupPolicyTests.swift').read_text()
        for token in ('CMUX_APP_HOST_ISOLATION_REQUIRED', 'CFFIXED_USER_HOME',
                      'FileManager.default.homeDirectoryForCurrentUser.path'):
            self.assertIn(token, tests)


if __name__ == '__main__':
    unittest.main()
