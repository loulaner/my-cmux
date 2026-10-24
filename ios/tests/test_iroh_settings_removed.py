"""iOS networking settings retire without losing local diagnostics."""
import hashlib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UI = ROOT / 'Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI'


class IrohSettingsRemovedTests(unittest.TestCase):
    def test_exclusive_ui_owners_retired(self):
        for name in ('IrohSettingsControllerEnvironment', 'MobileIrohSettingsView',
                     'MobileIrohCustomRelayEditor', 'MobileIrohCustomPrivatePathEditor',
                     'MobileIrohConnectionCheckSection', 'MobileIrohSettingsModel'):
            self.assertFalse((UI / f'{name}.swift').exists(), name)
        for name in ('MobileSettingsView', 'MacComputerDetailView'):
            source = (UI / f'{name}.swift').read_text()
            for retired in ('irohSettingsController', 'MobileIrohSettingsModel',
                            'upsertCustomPrivatePath', 'clearDiagnosticReport'):
                self.assertNotIn(retired, source)

    def test_local_model_is_injected_not_network_or_global_state(self):
        path = UI / 'MobileLocalDiagnosticSettingsModel.swift'
        self.assertTrue(path.exists())
        source = path.read_text()
        for forbidden in ('CmxIroh', 'UserDefaults', '.shared', 'observe(', 'clear('):
            self.assertNotIn(forbidden, source)
        for required in ('@Observable', '@MainActor', 'setFileLogging',
                         '.permissionDenied', '.verboseDiagnosticLoggingChanged'):
            self.assertIn(required, source)

    def test_clear_order_and_export_owner_remain(self):
        source = (UI / 'MobileSettingsView.swift').read_text()
        self.assertIn('diagnosticLog != nil || appLog != nil', source)
        self.assertIn('localDiagnosticSettingsModel == nil', source)
        self.assertIn('UserDefaults.standard.bool(forKey: MobileDebugLog.verboseLogDefaultsKey)', source)
        self.assertIn('await MobileDebugLog.shared.setFileLogging(enabled: enabled)', source)
        positions = [source.index(text) for text in (
            'let verboseLogWasEnabled = localDiagnosticSettingsModel?.verboseLogEnabled == true',
            'await MobileDebugLog.shared.clearPersistedLog()',
            'await localDiagnosticSettingsModel?.setVerboseLog(false)',
            'await diagnosticLog?.clear()', 'await appLog?.clear()')]
        self.assertEqual(positions, sorted(positions))
        self.assertIn('logExportTask?.cancel()', source)
        self.assertIn('logExportTaskID = nil', source)
        detail = (UI / 'MacComputerDetailView.swift').read_text()
        for retained in ('saveDirectAddress()', 'computerHasUsableTailscaleAuthorization',
                         'connectionMethodSection', 'forgetComputer()'):
            self.assertIn(retained, detail)

    def test_export_and_ordinary_detail_bodies_preserved(self):
        settings = (UI / 'MobileSettingsView.swift').read_text()
        marker = '    @MainActor\n    private func startLogExport()'
        self.assertEqual(hashlib.sha256(settings[settings.index(marker):].encode()).hexdigest(),
                         '515fd0e57bbdd4064e1784ecd05aa48293c051ce3f451cb91d23f24365317a8c')
        detail = (UI / 'MacComputerDetailView.swift').read_text()
        marker = '    private var listAuthEntry:'
        self.assertEqual(hashlib.sha256(detail[detail.index(marker):].encode()).hexdigest(),
                         'c3036dc4a0cff44ad77b922fa2dd5d4a64ebc94decd2dc96c020ac7842f01350')
        start = settings.index('                    let verboseLogWasEnabled =')
        end = settings.index('                }\n            }\n            Button(L10n.string("mobile.common.cancel"', start)
        body = settings[start:end].replace('localDiagnosticSettingsModel', 'irohSettingsModel')
        self.assertEqual(hashlib.sha256(body.encode()).hexdigest(),
                         'c72c2b2157250b25fb431a85922ca401430441df39af39dbdeef7abf76fa16af')


if __name__ == '__main__':
    unittest.main()
