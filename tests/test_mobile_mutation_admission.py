"""Compile verbatim production admission logic in controlled shells; no real auth/network proof.

Set CMUX_MUTATION_ADMISSION_LOG_DIR to an explicitly owned evidence parent to run.
CMUX_MUTATION_ADMISSION_MUTATE=1 bypasses only the final registry identity check.
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
OWNER = ROOT / "Sources/Mobile/MobileHostService.swift"
AUTH = ROOT / "Sources/Mobile/MobileHostTransportAuthorization.swift"


def extract():
    host, authorization = OWNER.read_text(), AUTH.read_text()
    return {
        "AUTHORIZATION": (AUTH, unique_slice(authorization, "enum MobileHostConnectionAuthorizationContext:", "/// Immutable trust context")),
        "CONTEXT": (AUTH, unique_slice(authorization, "struct MobileHostRPCExecutionContext:", "\n\nenum MobileHostEventTransport:")),
        "REGISTRY": (AUTH, unique_slice(authorization, "final class MobileHostConnectionRegistry:", "\nenum MobileHostPublicStatusCache")),
        "CONNECTION_METHOD": (OWNER, unique_slice(host, "    func isMutationAdmissionCurrent()", "    func close(\n")),
    }


class MutationAdmissionTests(unittest.TestCase):
    def test_actual_registry_capture_and_old_authorization_unchanged(self):
        source = OWNER.read_text()
        self.assertEqual(source.count("executionContext: MobileHostRPCExecutionContext("), 1)
        context = unique_slice(source, "                    executionContext: MobileHostRPCExecutionContext(",
                               "                await MobileHostService.shared.recordCreatedResourcesIfNeeded(")
        self.assertIn("mutationAdmissionValidator: { await registry.isLocalDirectMutationAdmissionCurrent(id: id) }", context)
        self.assertNotIn(".shared", context)
        self.assertNotIn("session", context)
        self.assertNotIn("params", context)
        response = unique_slice(source, "    private func successResponsePayload(", "    private func handleSubscriptionRPC(")
        authorization = unique_slice(source, "            isAuthorizationCurrent: {", "            handleRequest: {")
        self.assertEqual(hashlib.sha256(response.encode()).hexdigest(), "34c7e2d80833ab9cfdc859e5d4f17fcd3188b696f59062ef76659393d7349725")
        self.assertEqual(hashlib.sha256(authorization.encode()).hexdigest(), "0c52e62b068a7e5808d1e6bf0f52be6bfaa44c872ff07f5b917f0d2da7d9f868")
        self.assertEqual(source.count("await successResponsePayload(for:"), 2)
        self.assertIn("await successResponsePayload(for: decoded)", source)
        self.assertIn("await successResponsePayload(for: request)", source)

    def test_new_gates_are_snapshots_without_lock_across_await(self):
        snippets = extract()
        context = snippets["CONTEXT"][1]
        self.assertIn("mutationAdmissionValidator: (@Sendable () async -> Bool)? = nil", context)
        self.assertIn("guard case .localDirect = authorization, !Task.isCancelled, let mutationAdmissionValidator", context)
        self.assertIn("return authorized && !Task.isCancelled", context)
        registry = snippets["REGISTRY"][1]
        lookup = unique_slice(registry, "    private func localDirectConnection(", "    /// Revalidates")
        self.assertIn("lock.lock()", lookup)
        self.assertIn("defer { lock.unlock() }", lookup)
        self.assertIn("case .localDirect = entry.authorization", lookup)
        gate = unique_slice(registry, "    func isLocalDirectMutationAdmissionCurrent(", "    func snapshot(irohBindingID:")
        self.assertIn("return localDirectConnection(id: id) === connection && !Task.isCancelled", gate)
        for text in [gate, snippets["CONNECTION_METHOD"][1]]:
            for forbidden in ["lock.lock", "NotificationCenter", "Task {", "close(", "remove(", "send("]:
                self.assertNotIn(forbidden, text)

    @unittest.skipUnless(sys.platform == "darwin", "Requires macOS Swift 6")
    def test_real_admission_runtime(self):
        parent = os.environ.get("CMUX_MUTATION_ADMISSION_LOG_DIR")
        if not parent:
            self.skipTest("Set CMUX_MUTATION_ADMISSION_LOG_DIR to an explicitly owned evidence parent")
        parent = Path(parent).resolve(strict=True)
        compiler = shutil.which("swiftc")
        if compiler is None:
            self.skipTest("swiftc unavailable")
        directory = Path(tempfile.mkdtemp(prefix="mobile-mutation-admission-", dir=parent))
        print(f"Full mutation admission evidence: {directory}", flush=True)
        template_path = ROOT / "tests/fixtures/mobile_mutation_admission_runtime.swift"
        template = template_path.read_text()
        records: dict[str, object] = {"fixtureSHA256": hashlib.sha256(template.encode()).hexdigest()}
        mutation = None
        for name, (path, body) in extract().items():
            full = path.read_text()
            offset = full.index(body)
            records[name] = {"path": str(path.relative_to(ROOT)), "startByte": len(full[:offset].encode()),
                             "endByte": len(full[:offset + len(body)].encode()), "sha256": hashlib.sha256(body.encode()).hexdigest()}
            if name == "REGISTRY" and os.environ.get("CMUX_MUTATION_ADMISSION_MUTATE") == "1":
                old = "return localDirectConnection(id: id) === connection && !Task.isCancelled"
                self.assertEqual(body.count(old), 1)
                body = body.replace(old, "return !Task.isCancelled")
                mutation = {"before": old, "after": "return !Task.isCancelled"}
            token = f"/*__{name}__*/"
            self.assertEqual(template.count(token), 1)
            template = template.replace(token, body)
        result = {}
        try:
            output = run_swift_variant(directory / "runtime", template, compiler, result)
            self.assertEqual(result.get("compileExit"), 0, directory)
            self.assertEqual(result.get("runExit"), 0, directory)
            self.assertRegex(output, r"ASSERTIONS [1-9][0-9]* FAILURES 0")
        finally:
            (directory / "receipt.json").write_text(json.dumps({"sources": records, "mutation": mutation, "result": result}, indent=2))


if __name__ == "__main__":
    unittest.main()
