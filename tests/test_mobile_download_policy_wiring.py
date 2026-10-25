"""Source guards for bounded mobile byte responses, not real MDM or I/O tests.

Independent streaming artifact.fetch lanes and metadata methods are outside scope.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
METHODS = (
    ("MobileTerminalArtifacts", "v2MobileTerminalArtifactThumbnail", "let resolution = await mobileTerminalArtifactContext", "TerminalArtifactWire.result(thumbnail)", 3),
    ("MobileChatArtifacts", "v2MobileChatArtifactThumbnail", "let resolution = await mobileChatArtifactResolution", "ChatArtifactWire.result(thumbnail)", 3),
    ("MobileSurfaces", "v2MobilePanelArtifactThumbnail", "let resolution = mobilePanelArtifactCanonicalPath", "mobilePanelArtifactResult(thumbnail)", 2),
    ("MobileWorkspaceChanges", "v2MobileWorkspaceChangesFileFetch", "guard let context = mobileWorkspaceChangesContentContext", "mobileWorkspaceChangesWireResult(", 2),
)
REFUSAL = r"if let error = Self\.mobileFileTransferPolicyError\(\)\s*\{\s*return error\s*\}"


class MobileDownloadPolicyWiringTests(unittest.TestCase):
    def read(self, area):
        return (ROOT / f"Sources/TerminalController+{area}.swift").read_text()

    def body(self, area, method):
        source = self.read(area)
        start = f"func {method}(params: [String: Any]) async -> V2CallResult {{"
        self.assertIn(start, source)
        rest = source.split(start, 1)[1]
        self.assertIn("\n    }", rest)
        return rest.split("\n    }", 1)[0]

    def test_each_leaf_refuses_before_original_first_operation(self):
        for area, method, first, _, count in METHODS:
            with self.subTest(method=method):
                body = self.body(area, method)
                self.assertRegex(body, r"^\s*" + REFUSAL + r"\s*" + re.escape(first))
                self.assertEqual(body.count("Self.mobileFileTransferPolicyError()"), count)

    def test_async_contexts_recheck_before_thumbnail_work(self):
        for area, method, _, _, _ in METHODS[:2]:
            with self.subTest(method=method):
                self.assertRegex(
                    self.body(area, method),
                    r"return resolution\.failureResult\s*\}\s*" + REFUSAL + r"\s*let maxDimension",
                )

    def test_each_successful_read_rechecks_before_wire_result(self):
        for area, method, _, wire, _ in METHODS:
            with self.subTest(method=method):
                body = self.body(area, method)
                if method.endswith("FileFetch"):
                    boundary = r"length: length\s*\)"
                else:
                    boundary = r"\}\.value"
                self.assertRegex(body, boundary + r"\s*" + REFUSAL + r"\s*return " + re.escape(wire))

    def test_dispatchers_keep_shared_leaf_delegation(self):
        for area, method, wire_method in (
            ("MobileTerminalArtifacts", "mobile.terminal.artifact.thumbnail", "v2MobileTerminalArtifactThumbnail"),
            ("MobileChat", "mobile.chat.artifact.thumbnail", "v2MobileChatArtifactThumbnail"),
            ("MobileSurfaces", "mobile.panel.artifact.thumbnail", "v2MobilePanelArtifactThumbnail"),
            ("MobileWorkspaceChanges", "mobile.workspace.changes.file_fetch", "v2MobileWorkspaceChangesFileFetch"),
        ):
            with self.subTest(method=method):
                source = self.read(area)
                start = f'case "{method}":'
                self.assertIn(start, source)
                branch = re.split(r"\n        (?:case |default:)", source.split(start, 1)[1], maxsplit=1)[0]
                self.assertEqual(branch.strip(), f"return await {wire_method}(params: params)")


if __name__ == "__main__":
    unittest.main()
