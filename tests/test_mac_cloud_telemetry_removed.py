"""Producer absence guards complement real-source behavior tests, not zero-network proof."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLOUD = ROOT / 'Packages/macOS/CmuxCloud/Sources/CmuxCloud'


class MacCloudTelemetryRemovedTests(unittest.TestCase):
    def test_concrete_owner_and_composition_are_absent(self):
        for name in ('CloudTelemetryUploader.swift', 'CloudTelemetryUploader+StackRateLimit.swift'):
            self.assertFalse((CLOUD / 'Telemetry' / name).exists())
        source = (ROOT / 'Sources/AppDelegate.swift').read_text()
        for token in ('CloudTelemetryUploader(', 'cloudUploader.attach(', 'cloudUploader.resumePending()'):
            self.assertNotIn(token, source)
        self.assertIn('CloudOperationRecorder(identity: { [weak coordinator = auth.coordinator]', source)

    def test_nil_exporter_does_not_construct_payload(self):
        source = (CLOUD / 'Operations/CloudOperationRecorder.swift').read_text()
        start = source.index('    public func finish(')
        end = source.index('    public func perform', start)
        body = source[start:end]
        gate = body.index('if let uploader, let identity = context.identity {')
        self.assertLess(gate, body.index('let start = Int64('))
        self.assertLess(gate, body.index('let span = CloudTelemetrySpan('))
        self.assertLess(body.index('await uploader.enqueue('), body.rindex('trim()'))
        self.assertIn('uploader: (any CloudTelemetrySending)? = nil', source)

    def test_sharing_ui_search_and_palette_are_absent(self):
        paths = ('Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Sections/AppSection.swift',
                 'Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Navigation/CuratedSettingEntry+Default.swift',
                 'Sources/SettingsSearchIndex.swift', 'Sources/SettingsSearchAliases.swift',
                 'Sources/CommandPalette/CommandPaletteSettingsToggle.swift')
        for path in paths:
            text = (ROOT / path).read_text()
            self.assertNotIn('settings.app.telemetry', text, path)
            self.assertNotIn('app.sendAnonymousTelemetry', text, path)

    def test_real_local_and_cloud_contracts_remain(self):
        app = (ROOT / 'Sources/AppDelegate.swift').read_text()
        self.assertIn('if !isRunningUnderXCTest, !ManagedDevicePolicy().isEnforced(.disableTelemetry) {\n            _ = CmuxFeatureFlags.shared', app)
        self.assertIn('"telemetry": telemetryEnabled ? "1" : "0"', app)
        vm = (CLOUD / 'VMClient/VMClient.swift').read_text()
        for token in ('pollOperationProgress', 'api/observability/cloud/operations/', 'Idempotency-Key', 'X-Cmux-Operation-Id'):
            self.assertIn(token, vm)
        for path in ('Sources/CmuxSettingsFileStore+SupportedPaths.swift', 'Sources/CmuxSettingsJSONPathSupport.swift',
                     'Sources/KeyboardShortcutSettingsFileStore+Template.swift'):
            self.assertIn('sendAnonymousTelemetry', (ROOT / path).read_text())


if __name__ == '__main__':
    unittest.main()
