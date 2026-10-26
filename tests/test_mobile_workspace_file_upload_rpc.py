"""Actual-source bounded upload RPC guard, not real filesystem/auth/network proof.

Baseline-safe RED: python3 tests/test_mobile_workspace_file_upload_rpc.py UploadRPC.test_policy -v
CMUX_UPLOAD_MUTATE=1 removes only the beforeCommit admission check in an independent evidence copy.
"""
import hashlib
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

from test_mobile_artifact_policy_runtime import run_swift_variant
import test_mobile_workspace_file_preview_rpc as preview_fixture

ROOT = Path(__file__).resolve().parents[1]
HOST = ROOT / 'Packages/macOS/CmuxMobileHost/Sources/CmuxMobileHost/WorkspaceFiles'
LEAF = ROOT / 'Sources/TerminalController+MobileWorkspaceFileUpload.swift'
POLICY_PROOF = '''
@main @MainActor struct PolicyProof {
    static func main() {
        var failures = 0
        for changes in [false, true] {
            let policy = MobileLocalDirectRPCPolicy(workspaceChangesEnabled: changes, fileTransferDisabled: false)
            let request = MobileHostRPCRequest(id: "synthetic", method: "mobile.workspace.files.upload",
                params: ["workspace_id": "2B6D9163-FE8B-44B1-8509-2A62D96688E9", "path": "literal%2e%2e/~", "root_id": String(repeating: "a", count: 64), "file_name": "file", "data_base64": "", "byte_count": 0, "sha256": String(repeating: "b", count: 64)], auth: nil)
            if policy.authorizationError(for: request) != nil {
                failures += 1; print("FAIL valid upload rejected (changes=\\(changes))")
            }
        }
        print("policy assertions=2 failures=\\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
'''


def source_fixture(integration):
    template, records = preview_fixture.source_fixture(False)
    suffix = '\nimport Darwin\n' + preview_fixture.POLICY_PROOF
    assert template.endswith(suffix), 'Known baseline fixture proof changed'
    template = template[:-len(suffix)]
    if not integration:
        return template + '\nimport Darwin\n' + POLICY_PROOF, records
    template = template.replace('enum MobileHostConnectionAuthorizationContext { case localDirect; case stackBearer; case irohAdmission }', '')
    # Match the real Workspace's non-Sendable shape; never hide capture errors behind global actor isolation.
    template = template.replace('@MainActor final class Workspace {', 'final class Workspace {')
    template += '\n' + (ROOT / 'tests/fixtures/mobile_workspace_file_upload_rpc_runtime.swift').read_text()
    auth_path = ROOT / 'Sources/Mobile/MobileHostTransportAuthorization.swift'
    auth_source = auth_path.read_text()
    start = auth_source.index('enum MobileHostConnectionAuthorizationContext:')
    end = auth_source.index('enum MobileHostEventTransport:')
    body = auth_source[start:end]
    template = template.replace('/*__CONTEXT__*/', body)
    records['CONTEXT'] = {'path': str(auth_path), 'startByte': len(auth_source[:start].encode()),
                          'endByte': len(auth_source[:end].encode()), 'sha256': hashlib.sha256(body.encode()).hexdigest()}

    for placeholder, path in {'UPLOAD': HOST / 'MobileWorkspaceFileUpload.swift',
                              'UPLOAD_ERROR': HOST / 'MobileWorkspaceFileUploadError.swift', 'LEAF': LEAF}.items():
        source = path.read_text()
        body = '\n'.join(line for line in source.splitlines() if not line.startswith(('import ', 'public import ')))
        records[placeholder] = {'path': str(path), 'sha256': hashlib.sha256(source.encode()).hexdigest()}
        if placeholder == 'LEAF' and os.environ.get('CMUX_UPLOAD_MUTATE') == '1':
            old = '                try await Self.validateMobileWorkspaceUploadAdmission(context)\n'
            assert body.count(old) == 1
            body = body.replace(old, '')
            records['mutation'] = {'before': old, 'after': ''}
        template = template.replace(f'/*__{placeholder}__*/', body)
    path = ROOT / 'Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/MobileSyncProtocol.swift'
    source = path.read_text()
    start = source.index('public enum MobileSyncFrameCodecError:')
    body = source[start:source.index('private struct DynamicCodingKey:')]
    template = template.replace('/*__FRAME__*/', body)
    records['FRAME'] = {'path': str(path), 'startByte': len(source[:start].encode()), 'sha256': hashlib.sha256(body.encode()).hexdigest()}
    return template, records


@unittest.skipUnless(sys.platform == 'darwin', 'Requires macOS Swift 6')
class UploadRPC(unittest.TestCase):
    def run_source(self, integration):
        compiler = shutil.which('swiftc')
        if not compiler:
            self.skipTest('swiftc unavailable')
        if not os.environ.get('CMUX_UPLOAD_LOG_DIR'):
            self.skipTest('Explicit owned CMUX_UPLOAD_LOG_DIR required')
        directory = Path(tempfile.mkdtemp(prefix='workspace-upload-rpc-', dir=os.environ.get('CMUX_UPLOAD_LOG_DIR')))
        print(f'Full upload evidence: {directory}', flush=True)
        source, records = source_fixture(integration)
        result = {}
        try:
            output = run_swift_variant(directory / 'runtime', source, compiler, result)
            self.assertEqual(result.get('compileExit'), 0, directory)
            self.assertEqual(result.get('runExit'), 0, directory)
            self.assertIn('upload' if integration else 'failures=0', output)
        finally:
            (directory / 'receipt.json').write_text(json.dumps({'sources': records, 'result': result}, indent=2))

    def test_policy(self):
        self.run_source(False)

    def test_handler(self):
        if not LEAF.exists():
            self.skipTest('Upload handler not implemented on baseline')
        self.run_source(True)

    def test_dispatch_and_relay(self):
        if not LEAF.exists():
            self.skipTest('Upload handler not implemented on baseline')
        source = (ROOT / 'Sources/TerminalController.swift').read_text()
        branch = source.split('case "mobile.workspace.files.upload":')[1].split('\n        case ')[0]
        for text in ['result = await v2MobileWorkspaceFileUpload(', 'params: request.params', 'executionContext: executionContext', 'filesystemJobQuota: mobileTaskFilesystemJobQuota']:
            self.assertIn(text, branch)
        relay = (ROOT / 'Packages/macOS/CmuxRemoteWorkspace/Sources/CmuxRemoteWorkspace/Relay/RemoteRelayCommandPolicy.swift').read_text()
        self.assertNotIn('mobile.workspace.files.upload', relay)
        self.assertIn('RemoteRelayRoutingSchema().parameters(for: method) != nil', relay)
        schema = (ROOT / 'Packages/macOS/CmuxRemoteWorkspace/Sources/CmuxRemoteWorkspace/Relay/RemoteRelayRoutingSchema.swift').read_text()
        self.assertNotIn('mobile.workspace.files.upload', schema)


if __name__ == '__main__':
    unittest.main()
