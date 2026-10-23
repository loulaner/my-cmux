"""iOS Simulator product boundary; not a device or live-traffic verification."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SHELL = 'Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell'
UI = 'Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI'


class SimulatorStreamRemovalTests(unittest.TestCase):
    def test_package_and_dedicated_owners_are_deleted(self):
        self.assertFalse((ROOT / 'Packages/iOS/CmuxMobileSimulatorStream').exists())
        for directory, pattern in ((SHELL, '*Simulator*.swift'), (UI, '*SimulatorStream*.swift')):
            self.assertFalse(list((ROOT / directory).glob(pattern)))
        for name in ('SimulatorFramePresentationPipeline.swift', 'SimulatorPresentedImage.swift'):
            self.assertFalse((ROOT / UI / name).exists())

    def test_no_ios_runtime_requests_lanes_subscriptions_or_panes(self):
        forbidden = re.compile(
            r'mobile\.simulator\.|"simulator\.(?:frame|state|closed)"|simstream:|'
            r'\b(?:MobileSimulatorStream\w*|SimulatorStream\w*|MobileIrohSimulatorStreamLane|'
            r'simulatorStreamLaneProvider|activeSimulatorStream|supportsSimulatorStream|'
            r'startMobileSimulatorStream|openSimulatorStreamLane)\b'
        )
        roots = [ROOT / 'ios/cmux', ROOT / 'ios/cmuxPackage/Sources']
        roots += list((ROOT / 'Packages/iOS').glob('*/Sources'))
        for directory in roots:
            for path in directory.rglob('*.swift'):
                self.assertIsNone(forbidden.search(path.read_text()), str(path))

    def test_package_references_are_removed(self):
        for name in ('ios/cmuxPackage/Package.swift',
                     'Packages/iOS/CmuxMobileShellUI/Package.swift',
                     'cmux.xcworkspace/contents.xcworkspacedata'):
            self.assertNotIn('CmuxMobileSimulatorStream', (ROOT / name).read_text())
        self.assertNotIn('CmuxSimulatorStreamKit', (ROOT / 'Packages/iOS/CmuxMobileShellUI/Package.swift').read_text())

    def test_retired_memory_is_handled_before_supported_restore(self):
        source = (ROOT / SHELL / 'MobileShellComposite.swift').read_text()
        restore = source.split('private func restoreLastOpenedTab(', 1)[1].split('// MARK:', 1)[0]
        self.assertLess(restore.index('[.simulatorStream, .browserStream, .localBrowser]'),
                        restore.index('switch remembered.kind'))
        self.assertIn('case unsupportedPreservingMemory', source)
        self.assertIn('case .unsupportedPreservingMemory:', source)
        self.assertNotIn('startMobileSimulatorStream', restore)

    def test_compatibility_and_other_products_remain(self):
        model = ROOT / 'Packages/iOS/CmuxMobileShellModel/Sources/CmuxMobileShellModel'
        self.assertIn('case simulatorStream', (model / 'MobileWorkspaceLastTabStore.swift').read_text())
        self.assertIn('simulators: [MobileSimulatorPanelDescriptor]', (model / 'MobileWorkspacePreview.swift').read_text())
        for package in ('Packages/macOS/CmuxSimulator', 'Packages/Shared/CmuxSimulatorStreamKit',
                        'Packages/iOS/CmuxMobileSSH',
                        'Packages/iOS/CmuxMobileTerminal'):
            self.assertTrue((ROOT / package / 'Package.swift').exists())
        source = (ROOT / SHELL / 'MobileShellComposite.swift').read_text()
        self.assertIn('restartTerminalLanesForMountedSurfaces()', source)


if __name__ == '__main__':
    unittest.main()
