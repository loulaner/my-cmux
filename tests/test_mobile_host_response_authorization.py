"""Real-source response authorization control flow, not authentication/network evidence.

CMUX_RESPONSE_AUTH_CASE=revoked selects a baseline-safe RED (no second-check wait).
CMUX_RESPONSE_AUTH_MUTATE=1 forces only the post-handler authorization snapshot true.
Complete generated sources, spans/hashes, compiler/runtime logs and exits are retained.
"""
import hashlib
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

from test_mobile_artifact_policy_runtime import run_swift_variant, unique_slice

ROOT = Path(__file__).resolve().parents[1]
OWNER = ROOT / 'Sources/Mobile/MobileHostService.swift'


def extracted(source):
    start = '    private func successResponsePayload('
    end = '    private func handleSubscriptionRPC('
    region = unique_slice(source, start, end)
    helper = '    private func authorizationExpiredResponse('
    if helper in region:
        method, tail = region.split(helper, 1)
        return method, helper + tail
    return region, ''


class ResponseAuthorizationTests(unittest.TestCase):
    def test_shared_entrypoints(self):
        source = OWNER.read_text()
        ordered = unique_slice(source, '    private func startResponseSendTask(', '    private func respond(')
        self.assertIn('response.readinessContribution', ordered)
        self.assertEqual(source.count('await successResponsePayload(for:'), 2)
        self.assertIn('await successResponsePayload(for: decoded)', source)
        self.assertIn('await successResponsePayload(for: request)', source)

    @unittest.skipUnless(sys.platform == 'darwin', 'Requires macOS Swift 6')
    def test_real_response_method(self):
        compiler = shutil.which('swiftc')
        if compiler is None:
            self.skipTest('swiftc unavailable')
        directory = Path(tempfile.mkdtemp(prefix='mobile-response-auth-', dir=os.environ.get('CMUX_RESPONSE_AUTH_LOG_DIR')))
        print(f'Full response authorization evidence: {directory}', flush=True)
        source_path = Path(os.environ.get('CMUX_RESPONSE_AUTH_SOURCE', OWNER))
        source = source_path.read_text()
        method, helper = extracted(source)
        snippets = {'METHOD': method, 'HELPER': helper,
                    'TYPES': unique_slice(source, '    private enum UsableSessionReadinessContribution:', '    private struct UsableEventSubscription:'),
                    'INTERACTIVE': unique_slice(source, '    private static func isInteractiveMobileRequest(', '    /// Add a subscription for this connection.')}
        records = {}
        for key, body in snippets.items():
            if body:
                offset = source.index(body)
                records[key] = {'path': str(source_path), 'startByte': len(source[:offset].encode()),
                                'endByte': len(source[:offset + len(body)].encode()),
                                'sha256': hashlib.sha256(body.encode()).hexdigest()}
        records['ownerSHA256'] = hashlib.sha256(source.encode()).hexdigest()
        mutation = None
        if os.environ.get('CMUX_RESPONSE_AUTH_MUTATE') == '1':
            old = 'let authorized = await isAuthorizationCurrent()'
            self.assertEqual(snippets['METHOD'].count(old), 1)
            snippets['METHOD'] = snippets['METHOD'].replace(old, 'let authorized = true')
            mutation = {'before': old, 'after': 'let authorized = true'}
        rpc = ROOT / 'Sources/Mobile/MobileHostRPC.swift'
        snippets['RPC'] = rpc.read_text()  # Entire production request/result/envelope, including real encoder.
        records['RPC'] = {'path': str(rpc.relative_to(ROOT)), 'sha256': hashlib.sha256(rpc.read_bytes()).hexdigest()}
        template_path = ROOT / 'tests/fixtures/mobile_host_response_authorization_runtime.swift'
        template = template_path.read_text()
        records['fixtureSHA256'] = hashlib.sha256(template.encode()).hexdigest()
        for key, body in snippets.items():
            token = f'/*__{key}__*/'
            self.assertEqual(template.count(token), 1)
            template = template.replace(token, body)
        focused = os.environ.get('CMUX_RESPONSE_AUTH_CASE') == 'revoked'
        template = template.replace('static let focusedOnly = false // __FOCUSED__',
                                    f'static let focusedOnly = {str(focused).lower()}')
        result = {}
        try:
            output = run_swift_variant(directory / 'runtime', template, compiler, result)
            self.assertEqual(result.get('compileExit'), 0, directory)
            self.assertEqual(result.get('runExit'), 0, directory)
            self.assertIn('PASS response authorization', output)
        finally:
            (directory / 'receipt.json').write_text(json.dumps({'sources': records, 'mutation': mutation, 'result': result}, indent=2))


if __name__ == '__main__':
    unittest.main()
