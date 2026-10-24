"""CLI producer/linkage boundaries; not proof of runtime zero network traffic."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class CLISentryRemovedTests(unittest.TestCase):
    def test_no_cli_sdk_or_collector(self):
        for path in (ROOT / 'CLI').glob('*.swift'):
            source = path.read_text()
            for token in ('import Sentry\n', 'import CmuxSentryReporting', 'SentrySDK.',
                          'PrivateSentrySDKOnly', 'CLISocketSentryTelemetry',
                          'CLISocketOperationTelemetry', 'CMUX_CLI_SENTRY_CAPTURE_PROBE_PATH',
                          'CMUX_CLI_SENTRY_STORE_PROBE_PATH'):
                self.assertNotIn(token, source, str(path))

    def test_cli_link_edges_removed_but_app_products_remain(self):
        project = (ROOT / 'cmux.xcodeproj/project.pbxproj').read_text()
        for identifier in ('CE57E10000000000000000B4', 'CE57E10000000000000000A4'):
            self.assertNotIn(identifier, project)
        for identifier in ('CE57E10000000000000000B3', 'CE57E10000000000000000A3',
                           'CE57E10000000000000000B2', 'CE57E10000000000000000A2'):
            self.assertIn(identifier, project)
        cli = project.split('name = "cmux-cli";', 1)[1].split('productName', 1)[0]
        self.assertNotIn('CmuxSentry', cli)

    def test_compatibility_context_is_not_a_reporting_service(self):
        source = (ROOT / 'CLI/AgentHookFailureClassificationContext.swift').read_text()
        for token in ('let filtersExpectedFailures: Bool', 'let allowsSandboxPolicyDenial: Bool',
                      'CMUX_CLI_SENTRY_DISABLED', 'CMUX_CLAUDE_HOOK_SENTRY_DISABLED',
                      'SocketPathMarkerFiles.stableBundleIdentifier'):
            self.assertIn(token, source)
        for token in ('func capture', 'func breadcrumb', 'func store', 'Logger(', 'SentrySDK'):
            self.assertNotIn(token, source)

    def test_real_socket_and_local_failure_paths_remain(self):
        source = (ROOT / 'CLI/cmux.swift').read_text()
        for token in ('guard !capturesSocketErrorsInsideCommand else { throw error }',
                      'var operationCompleted = false', 'if !operationCompleted {',
                      'operationCompleted = true', 'CLIVersionSkew.diagnose(',
                      'func claimAgentHookFailureReport(', 'agentHookFailureReportTimestamps'):
            self.assertIn(token, source)
        environment = (ROOT / 'CLI/CLISocketEnvironment.swift').read_text()
        self.assertIn('static func socketPath(', environment)
        self.assertIn('static func socketPathForTelemetry(', environment)
        report = (ROOT / 'CLI/CMUXCLI+AgentHookFailureReporting.swift').read_text()
        self.assertLess(report.index('guard !isExpectedAgentHookFailure('), report.index('store.claimAgentHookFailureReport('))
        self.assertLess(report.index('store.claimAgentHookFailureReport('), report.index('agentHookDeliveryLogger.error('))
        journal = (ROOT / 'CLI/CMUXCLI+AgentJournalEmission.swift').read_text()
        self.assertIn('if let store, let classificationContext {', journal)
        self.assertIn('appendAgentJournalDeadLetter(draft: draft, message: message)', journal)


if __name__ == '__main__':
    unittest.main()
