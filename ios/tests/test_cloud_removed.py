"""Product Cloud boundary guard; wire compatibility models are intentionally retained."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACKAGES = ('CmuxMobileCloud', 'CmuxMobileCloudBridge', 'CmuxMobileCloudUI')


def assert_cloud_product_absent(test, root=None):
    root = root or ROOT
    for name in PACKAGES:
        test.assertFalse((root / 'Packages/iOS' / name).exists())
    for name in ('MobileCloudTabContent', 'CloudComputerRow'):
        test.assertFalse((root / f'Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/{name}.swift').exists())
    test.assertFalse((root / 'ios/cmuxPackage/Sources/cmuxFeature/MobileCloudComposition.swift').exists())


class CloudRemovalTests(unittest.TestCase):
    def test_no_cloud_purchase_or_machine_creation_product(self):
        assert_cloud_product_absent(self)

    def test_no_manifest_workspace_or_project_consumers(self):
        for path in [*ROOT.glob('Packages/*/*/Package.swift'), ROOT / 'ios/cmuxPackage/Package.swift',
                     ROOT / 'cmux.xcworkspace/contents.xcworkspacedata',
                     ROOT / 'ios/cmux-ios.xcodeproj/project.pbxproj']:
            for name in PACKAGES:
                self.assertNotIn(name, path.read_text(), str(path))

    def test_no_runtime_composition_or_tab(self):
        for directory in ('ios/cmux', 'ios/cmuxPackage/Sources',
                          'Packages/iOS/CmuxMobileShellUI/Sources'):
            for path in (ROOT / directory).rglob('*.swift'):
                self.assertNotRegex(path.read_text(), r'\b(?:CloudVMService|CloudSessionController|CloudWorkspaceBridge|MobileCloudComposition|MobileCloudTabContent|CloudComputerRow)\b|createWorkspaceOnCloudMachine|cloudSessionController|mobileCloudTabContent')
        source = (ROOT / 'Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/MobilePrimaryTab.swift').read_text()
        self.assertNotIn('case cloud', source)
        for tab in ('workspaces', 'feed', 'notifications', 'search'):
            self.assertIn('case ' + tab, source)


if __name__ == '__main__':
    unittest.main()
