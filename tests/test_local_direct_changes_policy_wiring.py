"""Source-only guardrails; not authentication, runtime MDM or AppHost evidence."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class LocalDirectChangesPolicyWiringTests(unittest.TestCase):
    def test_fresh_policy_and_real_default_owners(self):
        host = (ROOT / "Sources/Mobile/MobileHostService.swift").read_text()
        self.assertIn("return MobileLocalDirectRPCPolicy().authorizationError(for: request)", host)
        self.assertIn('"capabilities": MobileLocalDirectRPCPolicy().capabilities', host)
        policy = (ROOT / "Sources/Mobile/MobileLocalDirectRPCPolicy.swift").read_text()
        self.assertIn("CmuxFeatureFlags.offMainEffectiveValue(for: CmuxFeatureFlags.mobileWorkspaceChangesFlag)", policy)
        self.assertIn("fileTransferDisabled: Bool = ManagedFileTransferPolicy.isDisabled", policy)
        self.assertIn("CmxLocalDirectCapabilities.workspaceChangesRead", policy)
        self.assertNotIn('"workspace.changes.v1"', policy)
        self.assertEqual(set(re.findall(r'"(mobile\.workspace\.changes\.[^"]+)"', policy)),
                         {"mobile.workspace.changes.files", "mobile.workspace.changes.file_diff"})

    def test_shared_diff_guards_surround_actual_read(self):
        source = (ROOT / "Sources/TerminalController+MobileWorkspaceChanges.swift").read_text()
        body = source.split("func v2MobileWorkspaceChangesFileDiff(params:", 1)[1].split("/// Returns artifact-compatible", 1)[0]
        guard = "if let error = Self.mobileFileTransferPolicyError() { return error }"
        self.assertEqual(body.count(guard), 2)
        self.assertLess(body.index(guard), body.index("explicitMobileWorkspaceChangesID(params: params)"))
        self.assertLess(body.index("try await MobileHostService.shared.workspaceChangesService.fileDiff("), body.rindex(guard))
        self.assertLess(body.rindex(guard), body.index("var payload:"))
        self.assertIn("guard case .local(let directory) = resolution", body)
        self.assertIn("mobileWorkspaceChangesDirectoryResolution(workspaceID: workspaceID)", body)
        self.assertIn("path: path,", body)
        self.assertIn("min(max($0, 6_000), 1_000_000)", body)

    def test_repository_path_owner_remains(self):
        service = (ROOT / "Packages/macOS/CmuxGit/Sources/CmuxGit/Changes/WorkspaceChangesService+FileDiff.swift").read_text()
        self.assertIn("pathValidator.validatedPath(path, repoRoot: scope.repoRoot)", service)
        self.assertIn("snapshot.files.first(where: { $0.path == normalizedPath })", service)
        sources = "\n".join(p.read_text() for p in (ROOT / "Packages/macOS/CmuxGit/Sources").rglob("*.swift"))
        self.assertIn("--no-ext-diff", sources)
        self.assertIn("--no-textconv", sources)
        self.assertIn("GIT_NO_LAZY_FETCH", sources)
        self.assertIn("core.fsmonitor=false", sources)


if __name__ == "__main__":
    unittest.main()
