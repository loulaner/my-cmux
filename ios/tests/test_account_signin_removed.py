"""Retire account request UI without authenticating the legacy root."""
import hashlib
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UI = ROOT / 'Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI'

DIRECT_ROOT_HASHES = {
    'ios/cmux/cmuxApp.swift': (
        '266f53352b93f15e1f98b6c85e8ff2fda2955ae96b8637a77f5b96635b396fa8'
    ),
    'ios/cmux-ios.xcodeproj/project.pbxproj': (
        '2ab609b352ce300d6c640e32056707d106e8cf9cf3dfd7ec553659ed458843f1'
    ),
    'ios/cmuxPackage/Sources/cmuxFeature/MobileLocalDirectRootScene.swift': (
        '7fe554f78faedef72b1568867384f891995720118a0c6ebcde12383855459429'
    ),
}


class AccountSignInRemovedTests(unittest.TestCase):
    def test_exclusive_account_ui_retired(self):
        for name in ('SignInView', 'OAuthSignInProvider', 'SignInAuthRestoreStatusView',
                     'SignInBillingRecoveryActions', 'SignInEmailCodeFailurePolicy', 'SignInErrorPresentation'):
            self.assertFalse((UI / f'{name}.swift').exists(), name)
        self.assertFalse((UI.parent.parent / 'Tests/CmuxMobileShellUITests'
                          / 'SignInErrorPresentationTests.swift').exists())

    def test_unavailable_view_has_no_actions_or_auth_work(self):
        path = UI / 'MobileAccountSignInUnavailableView.swift'
        self.assertTrue(path.is_file())
        source = path.read_text()
        self.assertIn('ContentUnavailableView', source)
        self.assertIn('mobile.signIn.unavailable.title', source)
        self.assertIn('mobile.signIn.unavailable.message', source)
        calls = set(re.findall(r'\b([A-Za-z_]\w*(?:\.\w+)*)\s*\(', source))
        self.assertLessEqual(calls, {'available', 'ContentUnavailableView', 'Label', 'L10n.string', 'Text'})
        for forbidden in ('Button', 'Link(', '.task', 'Task', '.onAppear', '.onChange', 'AuthCoordinator',
                          'UserDefaults', 'URLSession', '@Environment', '@State', 'signOut', 'revalidate'):
            self.assertNotIn(forbidden, source)

    def test_root_only_changes_the_signin_surface(self):
        source = (UI / 'CMUXMobileRootView.swift').read_text()
        self.assertEqual(source.count('MobileAccountSignInUnavailableView()'), 1)
        canonical = source.replace('MobileAccountSignInUnavailableView()', 'SignInView()')
        canonical = canonical.replace('// Entering onboarding uses a',
                                      '// Sign-in hands directly into onboarding, so the swap reads as a')
        self.assertEqual(hashlib.sha256(canonical.encode()).hexdigest(), '3b8b1bb690a7478985ffd79ec61adfe0796d6ced2253e9ff788a62b864b44d7c')
        for argument in ('stackAuthenticated: authManager.isAuthenticated',
                         'attachTicketAuthenticated: hasActiveAttachTicketAuthentication',
                         'isRestoringSession: authManager.isRestoringSession',
                         'onboardingPending: isOnboardingPending', 'MobileRootAuthGate.shellSurface('):
            self.assertIn(argument, source)

    def test_direct_roots_and_shared_auth_contracts_remain(self):
        for path, expected in DIRECT_ROOT_HASHES.items():
            self.assertEqual(hashlib.sha256((ROOT / path).read_bytes()).hexdigest(), expected, path)
        for path in (
            'Packages/Shared/CmuxAuthRuntime/Sources/CmuxAuthRuntime/Coordinator/AuthCoordinator.swift',
            'ios/cmuxPackage/Sources/cmuxFeature/MobileKeychainAccessGroupPolicy.swift',
            'Packages/iOS/CmuxMobileWorkspace/Sources/CmuxMobileWorkspace/MobileRootAuthGate.swift',
            'Packages/iOS/CmuxMobileWorkspace/Tests/CmuxMobileWorkspaceTests/MobileRootAuthGateTests.swift',
            'Packages/iOS/CmuxMobileWorkspace/Sources/CmuxMobileWorkspace/SignInCodeInputPolicy.swift',
            'Packages/iOS/CmuxMobileWorkspace/Sources/CmuxMobileWorkspace/SignInCodeInputChangeAction.swift',
        ):
            self.assertTrue((ROOT / path).is_file(), path)
        for name in ('GameOfLifeHeader', 'RestoringSessionView', 'OnboardingBackdrop', 'PairingView'):
            self.assertTrue((UI / f'{name}.swift').is_file(), name)


if __name__ == '__main__':
    unittest.main()
