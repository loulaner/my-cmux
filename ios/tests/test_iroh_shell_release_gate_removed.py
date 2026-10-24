"""Retire executable release-gate probes, not ordinary reconnect/selection."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SHELL = ROOT / 'Packages/iOS/CmuxMobileShell'


class IrohShellReleaseGateRemovedTests(unittest.TestCase):
    def test_executable_support_target_retired(self):
        self.assertFalse((SHELL / 'Sources/CmuxMobileShellReleaseGateSupport').exists())
        for suffix in ('ArtifactPreparation', 'ResponseValidator', 'TerminalProbe', 'TerminalSession'):
            self.assertFalse((SHELL / 'Tests/CmuxMobileShellTests' /
                              f'MobileIrohReleaseGate{suffix}Tests.swift').exists())

    def test_package_edges_retired(self):
        manifest = (SHELL / 'Package.swift').read_text()
        self.assertNotIn('CmuxMobileShellReleaseGateSupport', manifest)
        self.assertIn('name: "CmuxMobileShell"', manifest)
        self.assertIn('name: "CmuxMobileShellTests"', manifest)

    def test_ordinary_reconnect_uses_real_actions(self):
        source = (SHELL / 'Tests/CmuxMobileShellTests/IrohConnectionRecoveryOwnerTests.swift').read_text()
        self.assertNotIn('CmuxMobileShellReleaseGateSupport', source)
        self.assertNotIn('runIrohSoakUsageStep', source)
        self.assertIn('explicitDisconnectThenRetryReplacesAnAlreadyHealthyConnection', source)
        self.assertIn('fixture.store.disconnectLiveConnection()', source)
        self.assertIn('fixture.store.retryActiveMacReconnect(stackUserID: nil, force: true)', source)
        for contract in ('replacement !== originalClient', 'fixture.store.connectionState == .connected',
                         'fixture.factory.attemptedKinds() == [.iroh, .iroh]',
                         'fixture.store.irohReleaseGateForegroundTarget()'):
            self.assertIn(contract, source)

    def test_pure_selection_and_direct_contracts_remain(self):
        self.assertTrue((SHELL / 'Sources/CmuxMobileShell/MobileShellComposite+IrohReleaseGate.swift').is_file())
        self.assertTrue((SHELL / 'Tests/CmuxMobileShellTests/MobileIrohReleaseGateTargetTests.swift').is_file())
        self.assertTrue((ROOT / 'ios/cmuxPackage/Sources/cmuxFeature/MobileLocalDirectRootScene.swift').is_file())
        self.assertIn('MobileLocalDirectRootScene(', (ROOT / 'ios/cmux/cmuxApp.swift').read_text())


if __name__ == '__main__':
    unittest.main()
