"""Run: python3 tests/test_mobile_artifact_policy_runtime.py -v

Requires macOS and swiftc; otherwise explicitly skips. Compiles verbatim production
handler/checker/refusal snippets with Swift 6 and no-business-I/O dependency spies.
Does not test real MDM, QUIC, files, registry allowed-path/TTL validation or AppHost.
Baseline plus six source-copy mutations run once each. Full logs/generated sources
remain in a private temp directory (optionally under CMUX_ARTIFACT_POLICY_TEST_LOG_DIR).
The .swift fixture is a template; its placeholder method headers are replaced before
compilation, not alternate implementations of the production checks.
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = {
    "router": "Sources/Mobile/MobileHostIrohApplicationLaneRouter.swift",
    "helper": "Sources/TerminalController+MobileTaskAttachments.swift",
    "result": "Sources/TerminalController.swift",
    "owner": "Packages/macOS/CmuxCloud/Sources/CmuxCloud/Environment/ManagedCapabilityPolicy.swift",
}


def unique_slice(source, start, end):
    """Both anchors must be unique within this explicitly bounded source region."""
    if source.count(start) != 1 or source.count(end) != 1:
        raise AssertionError(f"Non-unique or missing anchors: {start!r}, {end!r}")
    first = source.index(start)
    last = source.index(end)
    if last <= first:
        raise AssertionError(f"Reversed anchors: {start!r}, {end!r}")
    return source[first:last]


def extract(sources):
    router = sources["router"]
    registry = unique_slice(router, "actor MobileHostIrohArtifactTransferRegistry {", "\nstruct MobileHostIrohArtifactFileIdentity")
    issue = unique_slice(registry, "    func issue(", "\n    func claim(")
    claim = unique_slice(registry, "    func claim(", "\n    func release(")
    owner = unique_slice(sources["owner"], "public enum ManagedFileTransferPolicy: Sendable {", "public enum ManagedCloudPolicy:")
    return {
        "HANDLER": ("router", unique_slice(router, "struct MobileHostIrohArtifactLaneHandler:", "\n/// Separate credits")),
        "CHECKER": ("router", unique_slice(registry, "    func checkFileTransferPolicy() throws {", "\n\n    func issue(")),
        "ISSUE_PREFIX": ("router", unique_slice(issue, "    func issue(", "        let currentTime = now()")),
        "CLAIM_PREFIX": ("router", unique_slice(claim, "    func claim(", "        let currentTime = now()")),
        "HELPER": ("helper", unique_slice(sources["helper"], "    /// The refusal", "    /// Handles")),
        "RESULT_ENUM": ("result", unique_slice(sources["result"], "    enum V2CallResult {", "\n    nonisolated func v2Result(")),
        "OWNER": ("owner", unique_slice(owner, "    public static var disabledMessage: String {", "    /// Tells the user why")),
    }


def replace_once(source, before, after):
    if source.count(before) != 1:
        raise AssertionError(f"Mutation/placeholder must match exactly once: {before!r}")
    return source.replace(before, after, 1)


def render(template, snippets):
    for name, (_, snippet) in snippets.items():
        token = f"/*__{name}__*/"
        if name in ("ISSUE_PREFIX", "CLAIM_PREFIX"):
            method = "issue" if name == "ISSUE_PREFIX" else "claim"
            token += f"\n    func {method}Placeholder() {{"
        template = replace_once(template, token, snippet)
    if re.search(r"/\*__[A-Z_]+__\*/", template):
        raise AssertionError("Unresolved fixture placeholder")
    return template


def mutants(snippets):
    policy = "try await registry.checkFileTransferPolicy()"
    changes = (
        ("issue", "ISSUE_PREFIX", "        try checkFileTransferPolicy()\n", "", "issue-prefix"),
        ("claim", "CLAIM_PREFIX", "        try checkFileTransferPolicy()\n", "", "claim-prefix"),
        ("reader", "HANDLER", f"            {policy}\n            let reader", "            let reader", "after-claim"),
        ("read", "HANDLER", f"                {policy}\n                let remainingByteCount", "                let remainingByteCount", "after-first-send"),
        ("send", "HANDLER", f"                {policy}\n                try await stream.sendStream.send(data)", "                try await stream.sendStream.send(data)", "during-read"),
        ("finish", "HANDLER", f"            {policy}\n            try await stream.sendStream.finish()", "            try await stream.sendStream.finish()", "empty-before-finish"),
    )
    for label, key, before, after, expected in changes:
        changed = dict(snippets)
        source, text = snippets[key]
        changed[key] = (source, replace_once(text, before, after))
        yield label, changed, expected, {"snippet": key, "before": before, "after": after}


def run_swift_variant(directory, source_text, compiler, record):
    """Compile/run in a private environment; retain full logs and actual exits.

    Caller owns the record and assertions. A compile failure never runs a binary.
    Timeouts propagate with partial logs preserved; no shared environment changes.
    """
    directory.mkdir()
    home = directory / "home"
    tmp = directory / "tmp"
    cache = directory / "module-cache"
    for path in (home, tmp, cache, home / ".config", home / ".cache", home / ".local/share"):
        path.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(("CMUX_", "CMUXD_")):
            env.pop(key)
    env.update({
        "HOME": str(home), "CFFIXED_USER_HOME": str(home),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "XDG_CACHE_HOME": str(home / ".cache"),
        "XDG_DATA_HOME": str(home / ".local/share"),
        "TMPDIR": str(tmp) + "/", "SWIFT_MODULECACHE_PATH": str(cache),
        "CLANG_MODULE_CACHE_PATH": str(cache),
    })
    source = directory / "fixture.swift"
    source.write_text(source_text)
    binary = directory / "fixture"
    command = [compiler, "-swift-version", "6", "-parse-as-library", "-module-cache-path", str(cache), str(source), "-o", str(binary)]
    record["compileCommand"] = command
    with (directory / "compile.log").open("w") as log:
        compiled = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=180)
    record["compileExit"] = compiled.returncode
    (directory / "compile.exit").write_text(str(compiled.returncode) + "\n")
    if compiled.returncode != 0:
        return ""
    with (directory / "run.log").open("w") as log:
        ran = subprocess.run([str(binary)], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=60)
    record["runExit"] = ran.returncode
    (directory / "run.exit").write_text(str(ran.returncode) + "\n")
    return (directory / "run.log").read_text()


@unittest.skipUnless(sys.platform == "darwin", "Runtime fixture requires macOS Foundation")
class MobileArtifactPolicyRuntimeTests(unittest.TestCase):
    def test_baseline_and_six_boundary_mutations(self):
        compiler = shutil.which("swiftc")
        if compiler is None:
            self.skipTest("swiftc is unavailable")
        parent = os.environ.get("CMUX_ARTIFACT_POLICY_TEST_LOG_DIR")
        root = Path(tempfile.mkdtemp(prefix="cmux-artifact-policy-runtime-", dir=parent))
        print(f"\nFull artifact-policy runtime evidence: {root}", flush=True)
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
                    "path": SOURCES[owner],
                    "sourceSHA256": hashes[owner],
                    "startLine": sources[owner].count("\n", 0, start) + 1,
                    "endLine": sources[owner].count("\n", 0, start + len(text)) + 1,
                    "snippetSHA256": hashlib.sha256(text.encode()).hexdigest(),
                }
            (root / "provenance.json").write_text(json.dumps(provenance, indent=2))
            template = (ROOT / "tests/fixtures/mobile_artifact_policy_runtime.swift").read_text()
            variants = [("baseline", snippets, None, None), *mutants(snippets)]
            for name, variant, expected_failure, mutation in variants:
                with self.subTest(variant=name):
                    directory = root / name
                    record = {"variant": name, "expectedFailure": expected_failure, "mutation": mutation}
                    records.append(record)
                    output = run_swift_variant(directory, render(template, variant), compiler, record)
                    self.assertEqual(record["compileExit"], 0, f"Swift 6 compilation failed: {directory / 'compile.log'}")
                    self.assertIn("ISOLATION home=", output, f"Isolation proof missing: {directory}")
                    summary = re.search(r"^SUMMARY assertions=14 failures=(\d+)$", output, re.MULTILINE)
                    if summary is None:
                        self.fail(f"Incomplete assertions/crash: {directory}")
                    if expected_failure is None:
                        self.assertEqual(record["runExit"], 0, f"Baseline failed: {directory / 'run.log'}")
                        self.assertEqual(summary.group(1), "0")
                        self.assertNotRegex(output, r"(?m)^FAIL ")
                    else:
                        self.assertEqual(record["runExit"], 1, f"Mutation must fail assertions, not compilation/crash: {directory}")
                        self.assertGreater(int(summary.group(1)), 0)
                        self.assertIn(f"FAIL {expected_failure}\n", output, f"Wrong boundary failed: {directory}")
                    record["verified"] = True
        finally:
            unchanged = {key: hashlib.sha256((ROOT / path).read_bytes()).hexdigest() == hashes[key] for key, path in SOURCES.items()}
            (root / "results.json").write_text(json.dumps({"variants": records, "productionUnchanged": unchanged}, indent=2))
            self.assertTrue(all(unchanged.values()), f"Production inputs changed during runtime test: {root}")


if __name__ == "__main__":
    unittest.main()
