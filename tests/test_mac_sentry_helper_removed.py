"""App producer/link boundaries; does not claim runtime zero network traffic."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class MacSentryHelperRemovedTests(unittest.TestCase):
    def test_app_and_cli_have_no_sdk_producers(self):
        self.assertFalse((ROOT / 'Sources/SentryHelper.swift').exists())
        for folder in ('Sources', 'CLI'):
            for path in (ROOT / folder).rglob('*.swift'):
                for token in ('import Sentry\n', 'import CmuxSentryReporting', 'SentrySDK.',
                              'sentryBreadcrumb(', 'sentryCaptureWarning(', 'sentryCaptureError(',
                              'sentryStartMemoryContextRefresh(', 'sentryStopMemoryContextRefresh('):
                    self.assertNotIn(token, path.read_text(), str(path))

    def test_app_product_edges_are_disconnected_not_package_erased(self):
        project = (ROOT / 'cmux.xcodeproj/project.pbxproj').read_text()
        for token in ('SentryHelper.swift', 'CmuxSentryReporting in Frameworks',
                      'CmuxSentryScrubbing in Frameworks', 'productName = CmuxSentryReporting;',
                      'productName = CmuxSentryScrubbing;'):
            self.assertNotIn(token, project)
        self.assertIn('repositoryURL = "https://github.com/getsentry/sentry-cocoa.git"', project)
        self.assertTrue((ROOT / 'Packages/Shared/CmuxSentryTelemetry/Package.swift').is_file())

    def test_real_diagnostics_and_runtime_owners_remain(self):
        for file in ('MemoryResourceSample.swift', 'MemoryResourceViewCounts.swift',
                     'App/MemoryPressureMonitor.swift', 'TerminalController+MemoryDiagnostics.swift',
                     'GhosttyCrashBreadcrumb.swift'):
            self.assertTrue((ROOT / 'Sources' / file).is_file(), file)
        ghostty = (ROOT / 'Sources/GhosttyTerminalView.swift').read_text()
        for token in ('initializationLogger.error', 'ghostty_app_tick(app)',
                      'NotificationCenter.default.post(name: .ghosttyDidTick', 'scrollEndTimer'):
            self.assertIn(token, ghostty)
        cloud = (ROOT / 'Sources/Cloud/VMClientTelemetry+Live.swift').read_text()
        self.assertIn('capturePostHog:', cloud)
        self.assertIn('observeRecord:', cloud)
        self.assertNotIn('captureSentry:', cloud)
        self.assertNotIn('addBreadcrumb:', cloud)

    def test_socket_observation_is_optional_not_authentication(self):
        server = ROOT / 'Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Server'
        seam = (server / 'SocketControlServerEvents.swift').read_text()
        self.assertIn('breadcrumb: (@Sendable (String, [String: any Sendable]) -> Void)? = nil', seam)
        self.assertIn('failure: (@Sendable (String, String, Int32?, [String: any Sendable]) -> Void)? = nil', seam)
        for path in server.glob('*.swift'):
            self.assertNotIn('events.breadcrumb(', path.read_text(), str(path))
            self.assertNotIn('events.failure(', path.read_text(), str(path))
        app = (ROOT / 'Sources/TerminalController+SocketServerEvents.swift').read_text()
        self.assertNotIn('failureCaptureGate', app)
        for token in ('listenerDidStart:', 'recordLastSocketPath:', 'cleanupDiscoveryState:',
                      'pathMissingDetected:', 'rearmRequested:', 'connectionDropped:'):
            self.assertIn(token, app)


if __name__ == '__main__':
    unittest.main()
