"""Run: python3 tests/test_mobile_artifact_registry_runtime.py -v

macOS + swiftc only (explicit skip otherwise). Executes verbatim registry/identity
and value types using private, self-created six-byte files and real POSIX metadata.
Peer equality and injected clock/policy/ID generation are test doubles: no TLS,
account admission, real managed preferences, AppHost, network or transfer coverage.
Baseline and three source-copy mutants share the existing isolated Swift 6 runner.
Full logs/provenance remain under a unique temp root, optionally within
CMUX_ARTIFACT_POLICY_TEST_LOG_DIR. Does not execute the imported stream TestCase.
"""

import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

if __package__:
    from .test_mobile_artifact_policy_runtime import (
        replace_once,
        run_swift_variant,
        unique_slice,
    )
else:
    from test_mobile_artifact_policy_runtime import (
        replace_once,
        run_swift_variant,
        unique_slice,
    )

ROOT = Path(__file__).resolve().parents[1]
SOURCES = {
    "router": "Sources/Mobile/MobileHostIrohApplicationLaneRouter.swift",
    "owner": "Packages/macOS/CmuxCloud/Sources/CmuxCloud/Environment/ManagedCapabilityPolicy.swift",
    "resourceID": "Packages/Shared/CmuxIrohTransport/Sources/CmuxIrohTransport/CmxIrohResourceID.swift",
    "resourceError": "Packages/Shared/CmuxIrohTransport/Sources/CmuxIrohTransport/CmxIrohResourceIDError.swift",
    "descriptor": "Packages/Shared/CmuxAgentChat/Sources/CmuxAgentChat/Artifacts/ChatArtifactLaneDescriptor.swift",
}
EXPECTED_ASSERTIONS = {
    "issue-priority", "claim-priority", "live-policy-0", "live-policy-1", "live-policy-2",
    "descriptor-size-expiry", "lease-real-identity-offset", "pause-ten-refusals",
    "wrong-peer", "invalid-offset", "budget-eight", "budget-ninth-refused",
    "active-lease-serial", "wrong-release-still-active", "correct-release-resumes",
    "expired-while-disabled", "reallow-still-expired", "registry-isolation",
    "capacity-128", "capacity-overflow", "capacity-expiry-prune",
    "identity-regular-file", "identity-directory-refused", "identity-missing-refused",
}


def complete_value(source, anchor):
    # These dedicated files each have exactly one top-level type closing brace.
    ending = "\n}\n"
    return unique_slice(source, anchor, ending) + ending


def extract(sources):
    router = sources["router"]
    owner = unique_slice(sources["owner"], "public enum ManagedFileTransferPolicy: Sendable {", "public enum ManagedCloudPolicy:")
    return {
        "REGISTRY": ("router", unique_slice(router, "actor MobileHostIrohArtifactTransferRegistry {", "\nstruct MobileHostIrohArtifactFileIdentity")),
        "IDENTITY": ("router", unique_slice(router, "struct MobileHostIrohArtifactFileIdentity:", "\n/// Random-access file reader")),
        "ISSUE_FAILURE": ("router", unique_slice(router, "enum MobileHostIrohArtifactTransferIssueFailure:", "\n/// Runtime-scoped, peer-bound")),
        "OWNER": ("owner", unique_slice(owner, "    public static var disabledMessage: String {", "    /// Tells the user why")),
        "RESOURCE_ID": ("resourceID", complete_value(sources["resourceID"], "public struct CmxIrohResourceID:")),
        "RESOURCE_ID_ERROR": ("resourceError", complete_value(sources["resourceError"], "public enum CmxIrohResourceIDError:")),
        "DESCRIPTOR": ("descriptor", complete_value(sources["descriptor"], "public struct ChatArtifactLaneDescriptor:")),
    }


def render(template, snippets):
    for name, (_, text) in snippets.items():
        template = replace_once(template, f"/*__{name}__*/", text)
    if re.search(r"/\*__[A-Z_]+__\*/", template):
        raise AssertionError("Unresolved fixture placeholder")
    return template


def mutants(snippets):
    changes = (
        ("issue", "    ) throws -> ChatArtifactLaneDescriptor {\n        try checkFileTransferPolicy()\n",
         "    ) throws -> ChatArtifactLaneDescriptor {\n", "issue-priority"),
        ("claim", "    ) throws -> Lease {\n        try checkFileTransferPolicy()\n",
         "    ) throws -> Lease {\n", "claim-priority"),
        ("budget", "        entry.remainingClaims -= 1", "        entry.remainingClaims -= 2", "budget-eight"),
    )
    for label, before, after, expected in changes:
        changed = dict(snippets)
        source, text = snippets["REGISTRY"]
        changed["REGISTRY"] = (source, replace_once(text, before, after))
        yield label, changed, expected, {"snippet": "REGISTRY", "before": before, "after": after}


@unittest.skipUnless(sys.platform == "darwin", "Registry runtime fixture requires macOS Foundation/Darwin")
class MobileArtifactRegistryRuntimeTests(unittest.TestCase):
    def test_complete_registry_and_three_mutations(self):
        compiler = shutil.which("swiftc")
        if compiler is None:
            self.skipTest("swiftc is unavailable")
        root = Path(tempfile.mkdtemp(
            prefix="cmux-artifact-registry-runtime-", dir=os.environ.get("CMUX_ARTIFACT_POLICY_TEST_LOG_DIR")
        ))
        print(f"\nFull artifact-registry runtime evidence: {root}", flush=True)
        sources = {key: (ROOT / path).read_text() for key, path in SOURCES.items()}
        hashes = {key: hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for key, path in SOURCES.items()}
        records = []
        try:
            snippets = extract(sources)
            provenance = {}
            for key, (owner, text) in snippets.items():
                self.assertEqual(sources[owner].count(text), 1, key)
                start = sources[owner].index(text)
                provenance[key] = {
                    "path": SOURCES[owner], "sourceSHA256": hashes[owner],
                    "startLine": sources[owner].count("\n", 0, start) + 1,
                    "endLine": sources[owner].count("\n", 0, start + len(text)) + 1,
                    "snippetSHA256": hashlib.sha256(text.encode()).hexdigest(),
                }
            (root / "provenance.json").write_text(json.dumps(provenance, indent=2))
            template = (ROOT / "tests/fixtures/mobile_artifact_registry_runtime.swift").read_text()
            for name, variant, expected_failure, mutation in [("baseline", snippets, None, None), *mutants(snippets)]:
                with self.subTest(variant=name):
                    directory = root / name
                    record = {"variant": name, "expectedFailure": expected_failure, "mutation": mutation}
                    records.append(record)
                    output = run_swift_variant(directory, render(template, variant), compiler, record)
                    self.assertEqual(record["compileExit"], 0, f"Swift 6 compilation failed: {directory / 'compile.log'}")
                    self.assertIn("ISOLATION home=", output, f"Isolation proof missing: {directory}")
                    self.assertIn("FIXTURES root=", output, f"Synthetic fixtures missing: {directory}")
                    self.assertFalse(list((directory / "home").glob("registry-fixtures-*")), f"Fixture cleanup failed: {directory}")
                    summary = re.search(r"^SUMMARY assertions=24 failures=(\d+)$", output, re.MULTILINE)
                    if summary is None:
                        self.fail(f"Incomplete assertions/crash: {directory}")
                    labels = re.findall(r"^(?:PASS|FAIL) (.+)$", output, re.MULTILINE)
                    self.assertEqual(len(labels), len(EXPECTED_ASSERTIONS), f"Duplicate/missing assertions: {directory}")
                    self.assertEqual(set(labels), EXPECTED_ASSERTIONS, f"Unexpected throw/missing case: {directory}")
                    if expected_failure is None:
                        self.assertEqual(record["runExit"], 0, f"Baseline failed: {directory / 'run.log'}")
                        self.assertEqual(summary.group(1), "0")
                        self.assertNotRegex(output, r"(?m)^FAIL ")
                    else:
                        self.assertEqual(record["runExit"], 1, f"Mutation must fail assertions, not crash: {directory}")
                        self.assertGreater(int(summary.group(1)), 0)
                        self.assertIn(f"FAIL {expected_failure}\n", output, f"Wrong mutation boundary: {directory}")
                    record["verified"] = True
        finally:
            unchanged = {key: hashlib.sha256((ROOT / path).read_bytes()).hexdigest() == hashes[key] for key, path in SOURCES.items()}
            (root / "results.json").write_text(json.dumps({"variants": records, "productionUnchanged": unchanged}, indent=2))
            self.assertTrue(all(unchanged.values()), f"Production inputs changed: {root}")


if __name__ == "__main__":
    unittest.main()
