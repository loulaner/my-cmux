"""Actual-source preview policy/handler control-flow regression, not filesystem/network proof.

Baseline-safe RED: python3 tests/test_mobile_workspace_file_preview_rpc.py PreviewRPC.test_policy -v
CMUX_PREVIEW_MUTATE=1 bypasses only the post-read MDM snapshot in an evidence copy.
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

ROOT = Path(__file__).resolve().parents[1]
HOST = ROOT / 'Packages/macOS/CmuxMobileHost/Sources/CmuxMobileHost/WorkspaceFiles'
LEAF = ROOT / 'Sources/TerminalController+MobileWorkspaceFilePreview.swift'
POLICY_PROOF = '''
@main @MainActor struct PolicyProof {
    static func main() {
        var failures = 0
        for changes in [false, true] {
            let policy = MobileLocalDirectRPCPolicy(workspaceChangesEnabled: changes, fileTransferDisabled: false)
            let request = MobileHostRPCRequest(id: "synthetic", method: "mobile.workspace.files.preview",
                params: ["workspace_id": "2B6D9163-FE8B-44B1-8509-2A62D96688E9", "path": "literal%2e%2e/~", "root_id": String(repeating: "a", count: 64)], auth: nil)
            if policy.authorizationError(for: request) != nil {
                failures += 1; print("FAIL valid preview rejected (changes=\\(changes))")
            }
        }
        print("policy assertions=2 failures=\\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
'''


def source_fixture(integration):
    records = {}
    template = (ROOT / 'tests/fixtures/mobile_workspace_file_list_rpc_runtime.swift').read_text().split('// A continuation-controlled service spy;')[0]
    paths = {'PARSER': HOST / 'MobileWorkspaceFileListRequest.swift',
             'PREVIEW_PARSER': HOST / 'MobileWorkspaceFilePreviewRequest.swift',
             'POLICY': ROOT / 'Sources/Mobile/MobileLocalDirectRPCPolicy.swift',
             'CAP': ROOT / 'Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/CmxLocalDirectCapabilities.swift',
             'QUOTA': HOST.parent / 'TaskDirectory/MobileTaskFilesystemJobQuota.swift',
             'ENTRY': HOST / 'MobileWorkspaceFileListEntry.swift', 'PAGE': HOST / 'MobileWorkspaceFileListPage.swift',
             'ERROR': HOST / 'MobileWorkspaceFileListError.swift'}
    # The baseline has neither new parser nor its placeholder; no substitute parser.
    if paths['PREVIEW_PARSER'].exists() and '/*__PREVIEW_PARSER__*/' not in template:
        template += '\n/*__PREVIEW_PARSER__*/\n'
    snippets = {}
    for placeholder, path in paths.items():
        if path.exists():
            source = path.read_text()
            snippets[placeholder] = '\n'.join(line for line in source.splitlines() if not line.startswith(('import ', 'public import ')))
            records[placeholder] = {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
        else:
            snippets[placeholder] = ''
    slices = [('RESULT', ROOT / 'Sources/TerminalController.swift', '    enum V2CallResult {', '    nonisolated func v2Result('),
              ('HELPER', ROOT / 'Sources/TerminalController+MobileTaskAttachments.swift', '    /// The refusal', '    /// Handles'),
              ('OWNER', ROOT / 'Packages/macOS/CmuxCloud/Sources/CmuxCloud/Environment/ManagedCapabilityPolicy.swift', '    public static var disabledMessage: String {', '    /// Tells the user why')]
    for placeholder, path, start, end in slices:
        source = path.read_text()
        if placeholder == 'OWNER':
            source = source.split('public enum ManagedFileTransferPolicy: Sendable {')[1].split('public enum ManagedCloudPolicy:')[0]
        body = source[source.index(start):source.index(end)]
        snippets[placeholder] = body
        original = path.read_text()
        offset = original.index(body)
        records[placeholder] = {'path': str(path), 'startByte': len(original[:offset].encode()), 'sha256': hashlib.sha256(body.encode()).hexdigest()}
    for placeholder, body in snippets.items():
        template = template.replace(f'/*__{placeholder}__*/', body)
    if integration:
        template += '\n' + (ROOT / 'tests/fixtures/mobile_workspace_file_preview_rpc_runtime.swift').read_text()
        more = {'PREVIEW': HOST / 'MobileWorkspaceFilePreview.swift', 'PREVIEW_ERROR': HOST / 'MobileWorkspaceFilePreviewError.swift', 'LEAF': LEAF}
        for placeholder, path in more.items():
            source = path.read_text()
            body = '\n'.join(line for line in source.splitlines() if not line.startswith(('import ', 'public import ')))
            records[placeholder] = {'path': str(path), 'sha256': hashlib.sha256(source.encode()).hexdigest()}
            if placeholder == 'LEAF' and os.environ.get('CMUX_PREVIEW_MUTATE') == '1':
                old = '            if let error = Self.mobileFileTransferPolicyError() { return error }\n            try Task.checkCancellation()'
                assert body.count(old) == 1
                body = body.replace(old, '            try Task.checkCancellation()')
                records['mutation'] = {'before': old, 'after': '            try Task.checkCancellation()'}
            template = template.replace(f'/*__{placeholder}__*/', body)
        path = ROOT / 'Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/MobileSyncProtocol.swift'
        source = path.read_text()
        body = source[source.index('public enum MobileSyncFrameCodecError:'):source.index('private struct DynamicCodingKey:')]
        template = template.replace('/*__FRAME__*/', body)
        records['FRAME'] = {'path': str(path), 'sha256': hashlib.sha256(body.encode()).hexdigest()}
    else:
        template += '\nimport Darwin\n' + POLICY_PROOF
    return template, records


@unittest.skipUnless(sys.platform == 'darwin', 'Requires macOS Swift 6')
class PreviewRPC(unittest.TestCase):
    def run_source(self, integration):
        compiler = shutil.which('swiftc')
        if not compiler:
            self.skipTest('swiftc unavailable')
        directory = Path(tempfile.mkdtemp(prefix='workspace-preview-rpc-', dir=os.environ.get('CMUX_PREVIEW_LOG_DIR')))
        print(f'Full preview evidence: {directory}', flush=True)
        source, records = source_fixture(integration)
        result = {}
        try:
            output = run_swift_variant(directory / 'runtime', source, compiler, result)
            self.assertEqual(result.get('compileExit'), 0, directory)
            self.assertEqual(result.get('runExit'), 0, directory)
            self.assertIn('preview' if integration else 'failures=0', output)
        finally:
            (directory / 'receipt.json').write_text(json.dumps({'sources': records, 'result': result}, indent=2))

    def test_policy(self):
        self.run_source(False)

    def test_handler(self):
        if not LEAF.exists():
            self.skipTest('Preview handler not implemented on baseline')
        self.run_source(True)

    def test_dispatch_and_relay(self):
        if not LEAF.exists():
            self.skipTest('Preview handler not implemented on baseline')
        source = (ROOT / 'Sources/TerminalController.swift').read_text()
        branch = source.split('case "mobile.workspace.files.preview":')[1].split('\n        case ')[0]
        for text in ['v2MobileWorkspaceFilePreview(', 'params: request.params', 'authorization: executionContext?.authorization', 'filesystemJobQuota: mobileTaskFilesystemJobQuota']:
            self.assertIn(text, branch)
        relay = (ROOT / 'Packages/macOS/CmuxRemoteWorkspace/Sources/CmuxRemoteWorkspace/Relay/RemoteRelayCommandPolicy.swift').read_text()
        self.assertNotIn('mobile.workspace.files.preview', relay)
        self.assertIn('RemoteRelayRoutingSchema().parameters(for: method) != nil', relay)
        schema = (ROOT / 'Packages/macOS/CmuxRemoteWorkspace/Sources/CmuxRemoteWorkspace/Relay/RemoteRelayRoutingSchema.swift').read_text()
        self.assertNotIn('mobile.workspace.files.preview', schema)


if __name__ == '__main__':
    unittest.main()
