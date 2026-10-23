#!/usr/bin/env python3
"""The retired store distribution entry points fail closed, without Apple tools."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ENTRY_POINTS = ('upload-testflight.sh', 'cloud-testflight.sh', 'upload-app-store.sh')


def assert_unsupported(case, script, arguments, help_only=False):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        home = root / 'home'
        home.mkdir()
        fakebin = root / 'bin'
        fakebin.mkdir()
        calls = root / 'tool-calls'
        for tool in ('xcodebuild', 'security', 'codesign', 'xcrun', 'curl', 'git',
                     'python', 'python3', 'ssh', 'scp', 'cmux', 'plutil', 'rm',
                     'mkdir', 'dirname', 'find', 'cat', 'asc', 'fleet'):
            path = fakebin / tool
            path.write_text('#!/bin/bash\nprintf "%s\\n" "$0" >> "$TOOL_CALLS"\nexit 97\n')
            path.chmod(0o755)
        # Existing user data must neither be removed nor migrated by a retired command.
        for name in ('AppStoreConnect.local.plist', 'old.mobileprovision', 'old-app', 'private-key.p8'):
            (home / name).write_text('fixture; do not read or modify\n')
        snapshot = lambda: {str(p.relative_to(root)): p.read_bytes()
                            for p in root.rglob('*') if p.is_file()}
        before = snapshot()
        environment = {
            'HOME': str(home), 'TMPDIR': str(home), 'PATH': str(fakebin),
            'TOOL_CALLS': str(calls), 'ASC_API_KEY_ID': 'FAKE',
            'ASC_API_ISSUER_ID': 'FAKE', 'ASC_API_KEY_PATH': str(home / 'private-key.p8'),
            'IOS_DISTRIBUTION_IDENTITY': 'Fake Distribution',
            'IOS_APPSTORE_PROVISIONING_PROFILE_NAME': 'Fake',
            'IOS_BETA_PROVISIONING_PROFILE_NAME': 'Fake',
            'CMUX_ALLOW_UNAUTHENTICATED_INSTALL': '1',
            'PRODUCT_BUNDLE_IDENTIFIER': 'com.loulaner.mycmux.ios',
            'CMUX_IOS_UPLOAD_DIR': str(home / 'upload'),
        }
        result = subprocess.run(['/bin/bash', str(ROOT / 'ios/scripts' / script), *arguments],
                                cwd=home, env=environment, capture_output=True, text=True)
        case.assertEqual(result.returncode, 0 if help_only else 64, result.stderr)
        case.assertIn('旧官方发布已从MyCMUX移除', result.stdout + result.stderr)
        case.assertFalse(calls.exists(), 'retired entry called an external tool')
        case.assertEqual(snapshot(), before, 'retired entry wrote or deleted user data')


class RetiredDistributionTests(unittest.TestCase):
    def test_business_invocations_are_unsupported_without_side_effects(self):
        for script in ENTRY_POINTS:
            for arguments in ([], ['--no-upload'], ['--prepare-only'],
                              ['--archive-path', '/never/archive'], ['--lane', 'appstore'],
                              ['--bundle-id', 'com.cmux.app'],
                              ['--bundle-id', 'com.loulaner.mycmux.ios'],
                              ['--help', '--prepare-only'], ['--export-only'],
                              ['--signing', 'manual']):
                with self.subTest(script=script, arguments=arguments):
                    assert_unsupported(self, script, arguments)

    def test_help_is_explanation_only(self):
        for script in ENTRY_POINTS:
            with self.subTest(script=script):
                assert_unsupported(self, script, ['--help'], help_only=True)


if __name__ == '__main__':
    unittest.main()
