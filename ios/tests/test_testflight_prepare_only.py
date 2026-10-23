"""Preparing a candidate is not a supported bypass of retired store publishing."""
import unittest
from test_cloud_vpn_distribution import ENTRY_POINTS, assert_unsupported


class PrepareCandidateTests(unittest.TestCase):
    def test_prepare_and_no_upload_never_claim_build_success(self):
        for script in ENTRY_POINTS:
            for arguments in (['--prepare-only', '--no-upload'],
                              ['--export-only', '--lane', 'beta'],
                              ['--archive-path', '/never/archive', '--no-upload']):
                with self.subTest(script=script, arguments=arguments):
                    assert_unsupported(self, script, arguments)


if __name__ == '__main__':
    unittest.main()
