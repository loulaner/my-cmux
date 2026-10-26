"""Direct file-list source contract and real-source Swift control-flow spies.

The runtime substitutes UI lookup, transport values and asynchronous filesystem
results, not the production handler/parser/policy/quota. No AppHost or real MDM.
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
LEAF = ROOT / "Sources/TerminalController+MobileWorkspaceFiles.swift"
PARSER = ROOT / "Packages/macOS/CmuxMobileHost/Sources/CmuxMobileHost/WorkspaceFiles/MobileWorkspaceFileListRequest.swift"
POLICY = ROOT / "Sources/Mobile/MobileLocalDirectRPCPolicy.swift"
CAP = ROOT / "Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/CmxLocalDirectCapabilities.swift"
QUOTA = ROOT / "Packages/macOS/CmuxMobileHost/Sources/CmuxMobileHost/TaskDirectory/MobileTaskFilesystemJobQuota.swift"

class SourceContract(unittest.TestCase):
    def test_dispatch_passes_trust_and_quota(self):
        source = (ROOT / "Sources/TerminalController.swift").read_text()
        marker = 'case "mobile.workspace.files.list":'
        self.assertEqual(source.count(marker), 1)
        block = source.split(marker)[1].split('\n        case ')[0]
        for value in ['v2MobileWorkspaceFilesList(', 'authorization: executionContext?.authorization',
                      'filesystemJobQuota: mobileTaskFilesystemJobQuota']:
            self.assertIn(value, block)

    def test_narrow_surface_and_shared_parser(self):
        self.assertIn('workspaceFilesList = "workspace.files.list.v1"', CAP.read_text())
        self.assertIn('MobileWorkspaceFileListRequest(params:', POLICY.read_text())
        self.assertTrue(LEAF.exists())
        source = LEAF.read_text()
        for value in ['MobileWorkspaceFileListRequest(params:', 'case .localDirect = authorization',
                      'Task.checkCancellation()', '=== workspace', 'defer { filesystemJobQuota.release() }']:
            self.assertIn(value, source)
        self.assertEqual(source.count('Self.mobileFileTransferPolicyError()'), 3)
        self.assertEqual(source.count('v2ResolveWorkspace(params: routingParams'), 2)
        for forbidden in ['selectedTab', 'mobileTaskComposer', 'standardizedFileURL', 'resolvingSymlinks',
                          'FileManager', 'readlink', 'Process(']:
            self.assertNotIn(forbidden, source)
        self.assertNotIn('mobile.workspace.files.list', (ROOT / 'Packages/macOS/CmuxRemoteWorkspace/Sources/CmuxRemoteWorkspace/Relay/RemoteRelayCommandPolicy.swift').read_text())

class RuntimeContract(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin', 'Requires macOS Swift 6')
    def test_actual_handler_parser_policy_and_quota(self):
        compiler = shutil.which('swiftc')
        if compiler is None:
            self.skipTest('swiftc unavailable')
        root = Path(tempfile.mkdtemp(prefix='workspace-files-rpc-', dir=os.environ.get('CMUX_FILES_RPC_LOG_DIR')))
        print(f'Full runtime evidence: {root}', flush=True)
        template = (ROOT / 'tests/fixtures/mobile_workspace_file_list_rpc_runtime.swift').read_text()
        records = {}
        for token, path in [('LEAF', LEAF), ('PARSER', PARSER),
                            ('PREVIEW_PARSER', PARSER.with_name('MobileWorkspaceFilePreviewRequest.swift')), ('POLICY', POLICY), ('CAP', CAP), ('QUOTA', QUOTA)]:
            source = path.read_text()
            # Preserve complete declarations; only unavailable module-import lines are omitted.
            body = '\n'.join(line for line in source.splitlines() if not line.startswith(('import ', 'public import ')))
            self.assertEqual(template.count(f'/*__{token}__*/'), 1)
            template = template.replace(f'/*__{token}__*/', body)
            records[token] = {'path': str(path.relative_to(ROOT)), 'sourceSHA256': hashlib.sha256(source.encode()).hexdigest()}
        host = ROOT / 'Packages/macOS/CmuxMobileHost/Sources/CmuxMobileHost/WorkspaceFiles'
        snippets = {}
        for token, name in [('ENTRY', 'MobileWorkspaceFileListEntry'), ('PAGE', 'MobileWorkspaceFileListPage'),
                            ('ERROR', 'MobileWorkspaceFileListError')]:
            path = host / (name + '.swift')
            snippets[token] = (path, path.read_text())
        helper = ROOT / 'Sources/TerminalController+MobileTaskAttachments.swift'
        text = helper.read_text()
        snippets['HELPER'] = (helper, text[text.index('    /// The refusal'):text.index('    /// Handles')])
        controller = ROOT / 'Sources/TerminalController.swift'
        text = controller.read_text()
        snippets['RESULT'] = (controller, text[text.index('    enum V2CallResult {'):text.index('    nonisolated func v2Result(')])
        owner = ROOT / 'Packages/macOS/CmuxCloud/Sources/CmuxCloud/Environment/ManagedCapabilityPolicy.swift'
        text = owner.read_text().split('public enum ManagedFileTransferPolicy: Sendable {')[1].split('public enum ManagedCloudPolicy:')[0]
        snippets['OWNER'] = (owner, text[text.index('    public static var disabledMessage: String {'):text.index('    /// Tells the user why')])
        for token, (path, body) in snippets.items():
            self.assertEqual(path.read_text().count(body), 1)
            self.assertEqual(template.count(f'/*__{token}__*/'), 1)
            template = template.replace(f'/*__{token}__*/', body)
            records[token] = {'path': str(path.relative_to(ROOT)), 'snippetSHA256': hashlib.sha256(body.encode()).hexdigest()}
        suites = []
        for name in ['MobileLocalDirectWorkspaceFilesPolicyTests', 'MobileLocalDirectChangesPolicyTests']:
            path = ROOT / 'cmuxTests' / (name + '.swift')
            source = path.read_text()
            body = source[source.index('struct ' + name):]
            body = '@MainActor ' + body.replace('@Test ', '').replace('#expect(', 'Harness.check(')
            suites.append(body)
            records[name] = {'path': str(path.relative_to(ROOT)), 'sourceSHA256': hashlib.sha256(source.encode()).hexdigest(),
                             'adapter': 'Drop module imports/Test attributes; route expect to fatal assertion; MainActor fixture only.'}
        template = template.replace('/*__APP_POLICY_TESTS__*/', '\n'.join(suites))
        result = {}
        try:
            output = run_swift_variant(root / 'baseline', template, compiler, result)
            self.assertEqual(result.get('compileExit'), 0, root)
            self.assertEqual(result.get('runExit'), 0, root)
            self.assertIn('PASS handler/policy/parser/quota', output)
        finally:
            (root / 'receipt.json').write_text(json.dumps({'sources': records, 'result': result}, indent=2))

if __name__ == '__main__':
    unittest.main()
