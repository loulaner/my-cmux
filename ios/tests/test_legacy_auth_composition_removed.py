"""Legacy composition retirement; no assertion of device reachability or live traffic."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FEATURE = ROOT / 'ios/cmuxPackage/Sources/cmuxFeature'


class LegacyAuthCompositionRemovalTests(unittest.TestCase):
    def test_concrete_owners_and_product_are_retired(self):
        for name in ('CMUXMobileRootScene', 'MobileAuthComposition', 'CMUXMobileRuntime',
                     'MobileIrxRuntimeComposition', 'MobileIrohTerminalLane', 'IrxArtifactLane'):
            self.assertFalse((FEATURE / f'{name}.swift').exists(), name)
        self.assertFalse(list(FEATURE.glob('MobileIrx*.swift')))
        self.assertFalse(list(FEATURE.glob('MobileIroh*.swift')))
        self.assertFalse((ROOT / 'ios/cmux/AppCompositionRoot.swift').exists())
        for path in ('ios/cmuxPackage/Package.swift', 'ios/cmux-ios.xcodeproj/project.pbxproj'):
            self.assertNotIn('CmuxIrohReleaseGateSupport', (ROOT / path).read_text())

    def test_direct_and_shared_contracts_remain(self):
        app = (ROOT / 'ios/cmux/cmuxApp.swift').read_text()
        self.assertIn('MobileLocalDirectRootScene(', app)
        self.assertIn('MobileKeyboardFrameTracker()', app)
        self.assertNotRegex(app, r'\b(?:MobileAuthComposition|AppCompositionRoot|MobileIrxRuntimeComposition)\(')
        for name in ('MobileLocalDirectRootScene', 'ProtectedDataAvailability',
                     'MobileKeychainAccessGroupPolicy', 'TailscaleStatusMonitorAdapter', 'MobileFeedbackStamp+Current'):
            self.assertTrue((FEATURE / f'{name}.swift').is_file())
        rpc = ROOT / 'Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC'
        self.assertIn('MobileArtifactLaneProvider', (rpc / 'MobileArtifactLaneConnection.swift').read_text())
        self.assertIn('terminalLaneProvider', (rpc / 'MobileSyncRuntime.swift').read_text())
        self.assertFalse((ROOT / 'Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShellReleaseGateSupport').is_dir())
        self.assertTrue((ROOT / 'Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+IrohReleaseGate.swift').is_file())
        self.assertTrue((ROOT / 'Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/MobileIrohReleaseGateTargetTests.swift').is_file())

    def test_only_simulator_gate_lane_is_retired(self):
        workflow = (ROOT / '.github/workflows/iroh-release-gate.yml').read_text()
        self.assertNotIn('  simulator-e2e:', workflow)
        for job in ('resolve-ref', 'runner', 'tailscale-version-skew'):
            self.assertIn(f'  {job}:', workflow)
        for name in ('verify-iroh-release-gate-builds.sh', 'iroh-release-gate-targets.sh'):
            self.assertTrue((ROOT / 'scripts/lib' / name).is_file())


if __name__ == '__main__':
    unittest.main()
