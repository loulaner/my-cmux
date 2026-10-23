"""Static cloud-push boundary guard; not a live zero-network assertion."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class PushRemovalTests(unittest.TestCase):
    def test_composition_and_ui_cannot_construct_cloud_push(self):
        banned = re.compile(r'\b(?:MobilePushCoordinator|PushRegistrationService|PhonePushKeyMaterial|PhonePushActiveAccountStore|SystemReplyRelayClient|DeferredSignInHook)\b|registerForRemoteNotifications\(')
        for directory in ('ios/cmux', 'ios/cmuxPackage/Sources', 'Packages/iOS/CmuxMobileShellUI/Sources'):
            for path in (ROOT / directory).rglob('*.swift'):
                self.assertIsNone(banned.search(path.read_text()), str(path))
        self.assertFalse((ROOT / 'ios/cmux/CmuxAppDelegate.swift').exists())
        self.assertFalse((ROOT / 'Packages/macOS/CmuxPhonePush/Package.swift').exists())

    def test_no_phone_push_rpc_producers(self):
        for directory in ('Packages/iOS/CmuxMobileShell/Sources', 'Packages/iOS/CmuxMobileRPC/Sources'):
            for path in (ROOT / directory).rglob('*.swift'):
                self.assertNotRegex(path.read_text(), r'method:\s*"phone_push\.')

    def test_package_and_project_do_not_link_removed_service(self):
        for name in ('ios/cmuxPackage/Package.swift', 'Packages/iOS/CmuxMobileShellUI/Package.swift',
                     'ios/cmux-ios.xcodeproj/project.pbxproj', 'cmux.xcworkspace/contents.xcworkspacedata'):
            self.assertNotIn('CmuxPhonePush', (ROOT / name).read_text())


if __name__ == '__main__':
    unittest.main()
