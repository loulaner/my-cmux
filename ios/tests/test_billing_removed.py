"""Personal-build architecture guard, not a UI/runtime billing test."""
import re
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from test_cloud_removed import assert_cloud_product_absent

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

    def test_cloud_purchase_and_machine_creation_entries_are_absent(self):
        assert_cloud_product_absent(self)


if __name__ == '__main__':
    unittest.main()
