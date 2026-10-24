"""Settings-only retirement boundary; not proof of live UI or server behavior."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UI = ROOT / 'Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI'


class AccountSettingsRemovalTests(unittest.TestCase):
    def test_settings_has_no_account_actions_or_team_producer(self):
        text = (UI / 'MobileSettingsView.swift').read_text()
        self.assertIsNone(re.search(
            r'\b(?:MobileSettingsAccountSection|DeleteAccountFailureKind|signOut|'
            r'deleteAccount|selectTeam|teamSelection|teamSelectionTask|'
            r'teamSelectionFailed|pendingTeamID|pendingTeamRequestID)\b|'
            r'MobileSettings(?:AccountRow|SignOut|DeleteAccount|TeamPicker|TeamSwitchError)|'
            r'ssh\.settings\.signIn', text))
        for name in ('MobileSettingsAccountSection.swift', 'MobileSettingsDeleteAccountFailureKind.swift'):
            self.assertFalse((UI / name).exists(), name)

    def test_settings_callers_do_not_pass_retired_action(self):
        count = 0
        for path in UI.rglob('*.swift'):
            text = path.read_text()
            for match in re.finditer(r'\bMobileSettingsView\(', text):
                count += 1
                start = match.end()
                depth, end = 1, start
                while depth and end < len(text):
                    depth += (text[end] == '(') - (text[end] == ')')
                    end += 1
                self.assertEqual(depth, 0, str(path))
                self.assertNotRegex(text[start:end], r'\bsignOut\s*:')
        self.assertGreater(count, 0)

    def test_real_auth_diagnostics_and_other_settings_remain(self):
        text = (UI / 'MobileSettingsView.swift').read_text()
        for token in ('@Environment(AuthCoordinator.self)', 'accountID: authManager.currentUser?.id',
                      'teamID: authManager.resolvedTeamID', '.settingsOpened', '.settingsClosed',
                      'MobileSettingsAllComputers', 'SetupHelpView(', 'TerminalShortcutsSettingsView('):
            self.assertIn(token, text)
        root = (UI / 'CMUXMobileRootView.swift').read_text()
        self.assertIn('store.signOut()', root)
        self.assertIn('authManager.signOut(onSignedOut: serverTeardown)', root)
        self.assertTrue((UI / 'SignInView.swift').is_file())
        settings = (UI / 'MobileDisplaySettings.swift').read_text()
        self.assertIn('self.forceRebuildKeyboardDock = defaults.cmuxForceRebuildKeyboardDock', settings)
        self.assertIn('forKey: UserDefaults.cmuxForceRebuildKeyboardDockKey', settings)


if __name__ == '__main__':
    unittest.main()
