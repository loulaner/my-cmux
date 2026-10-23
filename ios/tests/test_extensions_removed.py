"""Static personal-build extension boundary; does not probe system VPN state."""
import importlib.util
import plistlib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('pbx', ROOT / 'scripts/check-pbxproj-group-membership.py')
assert spec is not None and spec.loader is not None
pbx = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pbx)


class ExtensionsRemovedTests(unittest.TestCase):
    def test_project_has_no_extension_targets_embed_phases_or_orphans(self):
        project = pbx.parse((ROOT / 'ios/cmux-ios.xcodeproj/project.pbxproj').read_text())
        objects = project['objects']
        self.assertFalse(pbx.orphans(project))
        for obj in objects.values():
            self.assertNotEqual(obj.get('productType'), 'com.apple.product-type.app-extension')
            if obj.get('productType') == 'com.apple.product-type.application':
                self.assertEqual(obj['dependencies'], [])
                self.assertFalse(any(objects[p]['isa'] == 'PBXCopyFilesBuildPhase' for p in obj['buildPhases']))
        for path in ['CloudVPN', 'NotificationService', 'Config/CloudVPN.entitlements', 'Config/NotificationService.entitlements']:
            self.assertFalse((ROOT / 'ios' / path).exists())

    def test_app_metadata_and_entitlements_have_no_push_or_vpn(self):
        for name in ['Info', 'PersonalInfo', 'LocalDirectInfo']:
            info = plistlib.loads((ROOT / 'ios/Config' / (name + '.plist')).read_bytes())
            self.assertNotIn('CMUXCloudVPNProviderBundleIdentifier', info)
            self.assertNotIn('remote-notification', info.get('UIBackgroundModes', []))
        for name in ['cmux', 'cmux-release', 'cmux-personal', 'cmux-local-direct']:
            ent = plistlib.loads((ROOT / 'ios/Config' / (name + '.entitlements')).read_bytes())
            for key in ['aps-environment', 'com.apple.developer.networking.networkextension', 'com.apple.developer.usernotifications.time-sensitive']:
                self.assertNotIn(key, ent)

    def test_composition_does_not_construct_or_clean_up_system_vpn(self):
        feature = ROOT / 'ios/cmuxPackage/Sources/cmuxFeature'
        self.assertFalse((feature / 'MobileCloudComposition.swift').exists())
        source = (feature / 'CMUXMobileRootScene.swift').read_text()
        for forbidden in ['makeSystemVPNController', 'CloudSystemVPN', 'cloudSystemVPNController', 'removeFromPreferences', 'waitForPendingOperationAndGate']:
            self.assertNotIn(forbidden, source)


if __name__ == '__main__':
    unittest.main()
