"""Personal-build architecture guard, not a UI/runtime billing test."""
import re
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class BillingRemovalTests(unittest.TestCase):
    def test_no_storekit_implementation_or_composition_in_ios_sources(self):
        forbidden = re.compile(r'\b(?:CmuxMobileBilling(?:UI)?|BillingModel|MobileBillingComposition|MobilePlans(?:Sheet|View)|MobileSettingsPlanSection)\b|import StoreKit|Transaction\.updates')
        for base in ('ios/cmux', 'ios/cmuxPackage', 'Packages/iOS'):
            for path in (ROOT / base).rglob('*.swift'):
                if '.build' not in path.parts:
                    self.assertIsNone(forbidden.search(path.read_text()), str(path))
        self.assertFalse((ROOT / 'Packages/iOS/CmuxMobileBilling/Package.swift').exists())

    def test_workspace_and_schemes_do_not_reference_deleted_products(self):
        workspace = ET.parse(ROOT / 'cmux.xcworkspace/contents.xcworkspacedata')
        for ref in workspace.iter('FileRef'):
            self.assertNotIn('CmuxMobileBilling', ref.attrib.get('location', ''))
        for path in (ROOT / 'ios/cmux-ios.xcodeproj/xcshareddata/xcschemes').glob('*.xcscheme'):
            self.assertEqual(list(ET.parse(path).iter('StoreKitConfigurationFileReference')), [])
        self.assertFalse((ROOT / 'ios/Config/cmux-dev.storekit').exists())

    def test_cloud_locked_sizes_have_no_action(self):
        # Boundary guard: a locked row must not mutate selection or launch purchasing.
        source = (ROOT / 'Packages/iOS/CmuxMobileCloudUI/Sources/CmuxMobileCloudUI/CloudSectionView.swift').read_text()
        locked = source.split('ForEach(lockedMemoryOptions,', 1)[1].split('} label:', 1)[0]
        self.assertNotRegex(locked, r'\b(?:Button|NavigationLink|openPlans)\b|selectedMemoryMb\s*=')
        self.assertNotIn('CloudCreateMachineUpgrade', source)
        self.assertNotIn('isPlansSheetPresented', source)


if __name__ == '__main__':
    unittest.main()
