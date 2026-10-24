"""Official iOS network owners retire; local identity and stores remain real."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell'


class DevicePresenceBackupRemovedTests(unittest.TestCase):
    def test_network_owners_and_hooks_retired(self):
        for name in ('PresenceClient', 'PresenceMap', 'PresenceSubscribing', 'PresenceTokenSource',
                     'PairedMacBackupClient', 'BackingUpPairedMacStore', 'MobilePairedMacBackup',
                     'PairedMacRestore', 'UserDefaultsPairedMacPendingDeleteStore'):
            self.assertFalse((SOURCE / f'{name}.swift').exists(), name)
        shell = (SOURCE / 'MobileShellComposite.swift').read_text()
        for symbol in ('PresenceSubscribing', 'presenceMap', 'PairedMacBackupRefreshing',
                       'refreshBackupBeforeDial', 'pairedMacRestoreBoundary', 'applyPresenceUpdate'):
            self.assertNotIn(symbol, shell)

    def test_local_directory_and_auth_boundaries_remain(self):
        shell = (SOURCE / 'MobileShellComposite.swift').read_text()
        for text in ('func evaluateDirectoryObservation()', 'discovery.directoryUpdates()',
                     'self.isSignedIn', 'self.isScopeCurrent(scope)',
                     'pairedMacStore.loadAll(', 'return .failed(.authorizationFailed)',
                     'retainSecondaryAggregationRetryEvidence(', 'func scheduleSecondaryPresenceAggregation('):
            self.assertIn(text, shell)
        for name in ('TeamScopedPairedMacStore', 'IOSBuildScopedPairedMacStore',
                     'MobileMacCompatiblePairedMacStore', 'PairedMacMutationGate'):
            self.assertTrue((SOURCE / f'{name}.swift').is_file())
        for path in ('Packages/iOS/CmuxMobilePairedMac/Sources/CmuxMobilePairedMac/MobilePairedMacStore.swift',
                     'ios/cmuxPackage/Sources/cmuxFeature/MobileLocalDirectRootScene.swift',
                     'scripts/lib/verify-ios-release-origins.sh'):
            self.assertTrue((ROOT / path).is_file())

    def test_unknown_is_not_fake_capability_or_online(self):
        source = (SOURCE / 'MobileShellComposite+TaskAttachments.swift').read_text()
        body = source.split('public func supportsTaskAttachments(', 1)[1].split('\n    }', 1)[0]
        self.assertIn('matchesForegroundPairing(', body)
        self.assertIn('controlSubscriptionMatching(', body)
        self.assertIn('return false', body)
        self.assertNotIn('presenceMap', body)
        ui = (ROOT / 'Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/MacComputerSnapshot+Store.swift').read_text()
        self.assertIn('presence: nil', ui)
        self.assertIn('lastSeenAt: mac.lastSeenAt', ui)
        self.assertIn('connectionStatus: exactConnectionStatus', ui)


if __name__ == '__main__':
    unittest.main()
