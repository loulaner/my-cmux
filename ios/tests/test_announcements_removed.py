"""Announcement product boundary; not a live network/UI or user-cache audit."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UI = 'Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI'


class AnnouncementsRemovalTests(unittest.TestCase):
    def test_dedicated_owners_catalog_and_web_broker_are_deleted(self):
        self.assertFalse(list((ROOT / UI).rglob('MobileWhatsNew*.swift')))
        self.assertFalse((ROOT / UI / 'WebSession/MobileWebAppSessionBroker.swift').exists())
        self.assertFalse((ROOT / 'Packages/iOS/CmuxMobileShellModel/Sources/CmuxMobileShellModel/MobileWhatsNewChannelPolicy.swift').exists())

    def test_no_announcement_requests_owners_or_cache_access(self):
        forbidden = re.compile(r'\bMobileWhatsNew\w*|/api/whats-new|dev\.cmux\.mobile\.whatsNew\.|MobileWebAppSessionBroker|mobileWebAppSession|whatsNewPreviewEnabled|suppressWhatsNewLaunch')
        for directory in ('ios/cmux', 'ios/cmuxPackage/Sources',
                          'Packages/iOS/CmuxMobileShellUI/Sources',
                          'Packages/iOS/CmuxMobileSupport/Sources'):
            for path in (ROOT / directory).rglob('*.swift'):
                self.assertIsNone(forbidden.search(path.read_text()), str(path))

    def test_retained_pairing_loading_settings_and_common_loader(self):
        shell = (ROOT / UI / 'WorkspaceShellView.swift').read_text()
        self.assertIn('await store.loadPairedMacs()', shell)
        self.assertIn('guard !Task.isCancelled else { return }', shell)
        settings = (ROOT / UI / 'MobileSettingsView.swift').read_text()
        self.assertIn('MobileSettingsDiagnosticsSection()', settings)
        self.assertIn('AppVersionInfo.current().displayString', settings)
        self.assertTrue((ROOT / UI / 'OnboardingPairingSettingsScreenshot.swift').exists())
        self.assertTrue((ROOT / UI / 'MobileRemoteJSONLoader.swift').exists())
        self.assertIn('mobileRemoteJSONLoader', (ROOT / UI / 'MobileMacCompatCenter.swift').read_text())

    def test_no_launch_suppression_or_preview_fixtures(self):
        for name in ('scripts/mobile-dev-launch.sh', '.github/workflows/ios-e2e.yml',
                     'ios/cmuxUITests/cmuxUITests.swift'):
            source = (ROOT / name).read_text()
            self.assertNotIn('CMUX_UITEST_SUPPRESS_WHATS_NEW', source)
            self.assertNotIn('CMUX_UITEST_WHATS_NEW_PREVIEW', source)


if __name__ == '__main__':
    unittest.main()
